---
linear: ENG-69
title: Self-leak and per-issue agent failures should not trip the global circuit breaker
date: 2026-05-07
status: draft
---

# ENG-69 — Per-issue halt vs. harness-wide pause; right-size the circuit breaker

## 1. Overview

Today `bin/run-local.sh`'s tick-end failure handling funnels three
structurally-different failure classes into a single global counter
(`$PROJECT_STATE_DIR/.consecutive-failures`) and a single global pause
(`orchestrator.paused=true` via `trip_breaker`). Two of the three
classes don't belong there — they are per-issue agent quirks, not
harness-wide trouble — and the granularity mismatch let ENG-63's
self-leak block ENG-64 and ENG-65 for 5+ hours across 63 launchd ticks
on 2026-05-05.

This brainstorm splits the failure-routing decision into three
explicit lanes:

| Lane | Trigger | Effect | Polling |
|---|---|---|---|
| **per-issue halt** (new) | self-leak; leaked-in-scope at threshold; same-issue agent failure at threshold | `pipeline:halted` + `skip-until-human-acts` on THAT issue; per-issue `.consecutive-failures` reset | other issues continue to be polled |
| **harness-wide pause** (existing breaker, scoped down) | infrastructure exit (today: 24=`linear-post-failed`); 3 cross-issue failures of any kind on consecutive ticks | global `orchestrator.paused=true` | all issues blocked until operator resumes |
| **info-only telemetry** (unchanged) | observed bucketed out-of-scope (concurrent human work in tick-start snapshot) | `sweep-observed-out-of-scope` metric | unaffected |

The existing precedent is `run-stage.sh::scope_check` rc=3 (severe
scope violation, `bin/run-stage.sh:763-771`): it routes through
`classify_failure` with `skip-until-human-acts`, applies
`pipeline:halted`, posts a halt comment, and exits 21 — without
touching `trip_breaker`. ENG-69 generalises that pattern to the two
sweep-time failure modes (self-leak, leaked-in-scope) that today reach
straight for the global breaker.

**Scope flag (load-bearing).** AC #2 says "any other per-issue
agent-failure path increments the per-issue counter." The most
defensible interpretation is also the most surgical: leave
`run-stage.sh`'s already-classified failure paths (which call
`classify_failure` themselves at `bin/run-stage.sh:588, 665, 678,
683, 769, 775, 852, 875` — 8 sites total) UNCHANGED at the
run-stage level, and only re-route
the final rc-handler in `run-local.sh:249-260` so it bumps the
per-issue counter rather than the global one. The implement stage
should NOT add per-issue counter increments inside
`classify_failure` itself — that would duplicate the auto-escalation
already wired at `bin/classify-failure.sh:67-77`. This brainstorm's
verdict is **rewire run-local.sh's three failure branches; leave
classify_failure alone**. See D-1, D-2, D-3 for the rationale per
branch. On the clean-exit path of run-stage, `route_run_stage_exit`
clears BOTH counters (per-issue AND global) so successful issues
flush stale strikes from either lane on every clean tick.

**Out of scope.** ENG-69's literal AC list does NOT include refactoring
`classify_failure`, replacing the file-based `.consecutive-failures`
counter with a different state shape, or auditing every other place
in the harness that might consult `orchestrator.paused`. Those are
deferred to followup tickets if needed.

## 2. Goals

After this ticket lands:

1. **Self-leak does not pause the orchestrator.** A self-leak on
   ENG-X writes `issue-state.json` for ENG-X, applies `pipeline:halted`
   + `pipeline:skip-until-human-acts` on ENG-X's Linear labels, posts
   a halt comment naming the leaked path hashes, and the tick exits
   non-zero. The next tick polls a different issue normally.
2. **Leaked-in-scope counts per-issue.** The same per-issue counter
   path applies; threshold = 3, escalation route = same as self-leak.
   Other issues' counters are not affected.
3. **Run-stage failures count per-issue except for `linear-post-failed`.**
   Exit codes 10, 12, 13, 14, 20, 21, 22, 25, 124 increment the
   per-issue counter at `$(issue_dir "$issue_id")/.consecutive-failures`.
   Exit code **24** (linear-post-failed) is the sole infrastructure
   exit and continues to increment the global counter. Trip threshold
   3 unchanged.
4. **`pipeline.sh decide --action continue` clears the per-issue
   counter atomically.** The atomic-reset already clears the global
   counter (`bin/pipeline.sh:274`); add the per-issue file to that
   sweep so a single `--action continue` fully un-halts the issue
   without leaving stale counter state.
5. **Tests.** Three positive scenarios in
   `bin/run-local-helpers-adversarial-test.sh` (or a new sibling test;
   see D-7): self-leak per-issue routing, leaked-in-scope per-issue
   counter, cross-issue isolation. Plus one negative: 3 ticks of
   `linear-post-failed` on different issues still trips the global
   breaker.
6. **CLAUDE.md "Failure-mode quick reference" entry distinguishes
   per-issue halts from global breaker trips.** Replaces the existing
   "Breaker tripped" row at `CLAUDE.md:386` with one or two rows
   (D-6 lands two for tier-clarity) that distinguish the two tiers.

## 3. Architectural principle

There is no `docs/VISION.md` or `docs/ARCHITECTURE.md` (verified: `ls
docs/` returns `brainstorms/  pipeline-vocabulary.md
pipeline-vocabulary.template.md  plans/  runbooks/`). There is no
`docs/knowledge/decisions.md`. The governing constraints come from
`CLAUDE.md` and `learned-rules/harness/project-profile.md`.

The principles invoked here are existing CLAUDE.md commitments:

- **Per-issue scope; cross-issue independence.** `CLAUDE.md`
  "Per-issue state directory" §: "Per-issue scratch lives under
  `$PROJECT_STATE_DIR/ENG-N/`." The contract is that one issue's
  scratch state cannot affect another's. The global breaker today
  violates that contract because a per-issue agent quirk pauses
  every issue. This brainstorm makes the breaker honor it.
- **Existing classification taxonomy is canonical.** `CLAUDE.md`
  "When wiring a new script" §: "For exit codes, use the taxonomy
  in `failure_outcome_for_exit` (common.sh) — adding a new exit
  code without updating that switch routes it to `unknown-exit-N`
  and the retrospective's §1 filter will not classify it." This
  brainstorm adds **exit 26 = self-leak** and updates the table
  rather than inventing parallel typing.
- **Atomic resume contract.** `CLAUDE.md` "What `--action continue`
  clears" §: "Idempotent — safe to re-run." Adding the per-issue
  counter to the atomic reset preserves idempotence (rm -f shrugs
  at missing files) and matches the existing pattern of clearing
  related side-state in one call.
- **Source-and-stub testability.** `CLAUDE.md` "Tests" §: "When a
  new bash file is meant to be both executable and unit-testable,
  replicate the sentinel pattern; otherwise tests cannot source
  it without side effects." The new failure-routing functions live
  in `run-local-helpers.sh` (already source-friendly; no main),
  so tests can exercise them through stubbed `classify_failure` /
  `linear.sh` / `metrics.sh`.

## 4. Decisions

Each decision is **D-N: \<verdict\>** + a "Why" line citing the
constraint or principle motivating it + the rejected alternative(s).

### D-1: Self-leak halt is per-issue via `classify_failure` with `skip-until-human-acts`

**Verdict.** In `bin/run-local.sh:304-318` (the self-leak branch),
replace the existing `trip_breaker; exit 1` block with a call to
the new `halt_issue_for_self_leak` helper (D-8) that wraps
`classify_failure` against `$issue_id` / `$stage`:

```bash
# In bin/run-local-helpers.sh (added in D-8):
# halt_issue_for_self_leak <issue> <stage> <hash1> [<hash2> ...]
# Halts a single issue for self-leak. Does NOT trip the global
# breaker. Reason text passed to classify_failure carries ONLY
# sha12 hashes — never raw paths — so no pipeline-marker shape can
# leak into the halt comment body via a malicious basename.
halt_issue_for_self_leak() {
  local issue="$1" stage="$2"
  shift 2
  [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
    || die "halt_issue_for_self_leak: invalid issue id '$issue'"
  local hashes=("$@") count=${#}
  bash "$SCRIPT_DIR/metrics.sh" sweep-self-leak-out-of-scope "$issue" "$stage" \
    "self-leak" 0 "count=$count hashes=$(IFS=,; printf '%s' "${hashes[*]}")" \
    || log "metrics.sh sweep-self-leak-out-of-scope emission failed (non-blocking)"
  log "SELF-LEAK: $count bot-introduced out-of-scope path(s) on $issue; halting issue (in-scope paths NOT committed)"
  [[ "${PIPELINE_DRY_RUN:-}" == "1" ]] && return 0
  # First 5 hashes only — keep the halt comment scannable. Each hash
  # is sha12 output (12 hex chars; matches ^[0-9a-f]{12}$). No raw
  # paths flow into the comment body (security persona P1-1).
  local hash_lines="" h_count=0 h
  for h in "${hashes[@]}"; do
    (( h_count >= 5 )) && break
    hash_lines="${hash_lines}${hash_lines:+, }${h}"
    h_count=$((h_count + 1))
  done
  local suffix=""
  (( count > 5 )) && suffix=" (and $((count - 5)) more)"
  classify_failure "$issue" "$stage" "skip-until-human-acts" \
    "self-leak: $count bot-introduced out-of-scope path(s); leaked hashes: ${hash_lines}${suffix}" \
    26
}
```

Caller in `run-local.sh:304-318` becomes:

```bash
if (( ${#self_leak_hashes[@]} > 0 )); then
  halt_issue_for_self_leak "$issue_id" "$stage" "${self_leak_hashes[@]}"
  [[ "$PIPELINE_DRY_RUN" != "1" ]] && exit 1
fi
```

This requires sourcing `classify-failure.sh` from `run-local.sh`
(currently it is sourced only by `run-stage.sh` at `bin/run-stage.sh:20`).
Add at the top of `run-local.sh` after the existing `source` lines:

```bash
# shellcheck source=classify-failure.sh
source "$SCRIPT_DIR/classify-failure.sh"
```

And add **exit 26 = self-leak** to `failure_outcome_for_exit` in
`bin/common.sh:107-129`:

```bash
26) printf 'self-leak' ;;
```

**Why.** Direct match for AC #1's wording. `classify_failure`
already knows how to: write `issue-state.json` with policy
`skip-until-human-acts` (`bin/classify-failure.sh:106-114`), apply
`pipeline:halted` (`bin/classify-failure.sh:119`), apply
`pipeline:skip-until-human-acts` (`bin/classify-failure.sh:111-114`),
post a halt comment with the marker
`<!-- pipeline: verdict result=halt reason=agent-blocked -->`
(`bin/classify-failure.sh:121-146`), Slack-warn, and emit the
stage-end metric. Reuse beats reinvention. The leaked-path hash
list rides as the `reason` arg, which classify_failure renders
verbatim into the halt-comment body at
`bin/classify-failure.sh:131-132`.

**Why NOT trip_breaker.** ENG-69's central insight: a per-issue
worktree mishap (one stage's agent dropped a stray file) is
uncorrelated with whether the next dispatch on a different issue
will succeed. The global breaker should fire only when "the next
dispatch — for any issue — is also expected to fail." Per-issue
agent quirks fail that test by definition. The 2026-05-05 ENG-63
incident is the pre-existing cost evidence.

**Rejected alternative — call `trip_breaker` AND `classify_failure`.**
Belt-and-suspenders. Defeats the purpose: the global breaker still
blocks the next tick from polling other issues. Fails AC #1's
"Does NOT touch `orchestrator.paused`" clause. Rejected.

**Rejected alternative — emit a halt comment + apply labels inline,
without calling `classify_failure`.** ~25 LOC of duplication.
Loses the auto-escalation evidence trail (pipeline_content_hash,
branch_head_sha) that `classify_failure` writes to issue-state.json,
which `poll.sh` consumes to gate skip-until-X resumption (verified
at `bin/poll.sh` reads issue-state.json on every tick). Rejected.

**Rejected alternative — introduce a leaner `_halt_issue_only`
function that does what `classify_failure` does minus the stage-end
metric.** Avoids the double-stage-end wart noted in §10 OQ-1. But
requires duplicating ~80 LOC of classify_failure's body (label
apply, comment post, state-file write, evidence build). The
double-stage-end is a metric-shape blemish, not a control-flow
bug, and the retrospective's §1 stage-pairing logic is forgiving
of duplicates. Reuse wins. Rejected.

**Rejected alternative — exit code 21 (scope-violation) reused for
self-leak.** Self-leak is structurally different from scope-violation:
scope-violation = "agent edited a file outside the plan's File
Structure"; self-leak = "agent introduced a NEW file outside the
allowlist that wasn't there at tick-start." Different signals,
different operator response. The retrospective filter joins on
`outcome`; merging the two would obscure the failure-mode
breakdown. Rejected.

### D-2: Leaked-in-scope uses a per-issue counter

**Verdict.** In `bin/run-local.sh:320-341` (the leaked-in-scope
branch), replace `FAIL_COUNTER` (the global counter) with a per-issue
counter at `$(issue_dir "$issue_id")/.consecutive-failures`. At
threshold (still 3), call `classify_failure` with
`skip-until-human-acts` (typed outcome via new exit 27; see D-5)
and exit. Do NOT call `trip_breaker`. The increment goes through
`tally_leaked_in_scope_failure` (D-8) so the test in D-7 #2 can
source-and-stub it:

```bash
# In bin/run-local-helpers.sh (added in D-8):
tally_leaked_in_scope_failure() {
  local issue="$1" stage="$2" leaked_count="$3" leaked_hashes="$4"
  [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
    || die "tally_leaked_in_scope_failure: invalid issue id '$issue'"
  bash "$SCRIPT_DIR/metrics.sh" sweep-leaked-in-scope "$issue" "$stage" \
    "leak" 0 "count=${leaked_count} hashes=${leaked_hashes}" \
    || log "metrics.sh sweep-leaked-in-scope emission failed (non-blocking)"
  [[ "${PIPELINE_DRY_RUN:-}" == "1" ]] && return 0
  local pic_file pic
  pic_file="$(issue_dir "$issue")/.consecutive-failures"
  mkdir -p "$(dirname "$pic_file")"
  pic="$(cat "$pic_file" 2>/dev/null || printf '0')"
  pic="${pic//[^0-9]/}"; pic="${pic:-0}"
  pic=$((pic + 1))
  # Atomic write: temp + rename. Matches issue-state.json convention.
  printf '%s\n' "$pic" > "${pic_file}.tmp.$$"
  mv -f "${pic_file}.tmp.$$" "$pic_file"
  log "sweep-leaked-in-scope: $leaked_count path(s) on $issue; per-issue consecutive failures = $pic (in-scope paths NOT committed)"
  if (( pic >= FAIL_THRESHOLD )); then
    classify_failure "$issue" "$stage" "skip-until-human-acts" \
      "leaked-in-scope at threshold: $pic consecutive failures (last leak: $leaked_count path(s))" \
      27
  fi
}
```

The caller in `run-local.sh:320-341` becomes:

```bash
if (( leaked_count > 0 )); then
  leaked_hashes=""
  while IFS= read -r -d '' p; do
    h="$(sha12 "$p")"
    leaked_hashes="${leaked_hashes:+${leaked_hashes},}${h}"
  done < "$leaked_file"
  tally_leaked_in_scope_failure "$issue_id" "$stage" "$leaked_count" "$leaked_hashes"
  [[ "$PIPELINE_DRY_RUN" != "1" ]] && exit 1
fi
```

**Why.** Direct match for AC #2 ("Per-issue rejection counter").
Threshold-3 mirrors the existing global-counter behavior, so an
operator's mental model carries over. Escalation at threshold to
`skip-until-human-acts` (vs. just letting the per-issue counter
keep climbing) is the bridge to operator attention — matches the
self-leak path's halt-on-occurrence pattern at higher count.

The new exit code 27 (leaked-in-scope-threshold) is added to
`failure_outcome_for_exit` in D-5 so the retrospective slices
self-leak (26), leaked-in-scope-threshold (27), and scope-violation
(21) as three distinct outcomes. Iteration-1 design persona P1-1
flagged the original "exit 21 with subcode 4" framing as inconsistent
with D-5's "distinct codes preserve clean retrospective slicing"
argument; folded.

The integer-sanitization (`pic="${pic//[^0-9]/}"; pic="${pic:-0}"`)
plus atomic write (`> .tmp.$$ && mv -f`) guard against torn writes
and corrupted counter files (security persona P1-3).

**Rejected alternative — keep the global counter for leaked-in-scope.**
The whole point of ENG-69 is that mixing per-issue agent quirks
with a global counter pauses unrelated issues. AC #2 is explicit.
Rejected.

**Rejected alternative — escalate at threshold to
`skip-until-code-changes` instead of `skip-until-human-acts`.**
`skip-until-code-changes` would auto-resume when the harness or
branch HEAD changes; for a sticky leak (e.g. agent keeps
re-introducing the same file) that yields a fast retry loop with
no operator review. `skip-until-human-acts` forces operator
inspection — appropriate when the leak has happened 3 times
running. Rejected.

**Rejected alternative — separate per-issue counters per failure
class (one for leaked-in-scope, one for run-stage rc≠0).** Adds
state-file count without analytical benefit. The threshold question
is the same regardless of failure class. Rejected.

### D-3: Run-stage rc≠0 routes to per-issue counter except for `rc=24` (linear-post-failed)

**Verdict.** In `bin/run-local.sh:249-258` (the run-stage rc-handler),
extract the fork-on-rc logic into `route_run_stage_exit` (D-8) so
the test in D-7 #3 can source-and-stub it. Exit 24 increments the
global counter (existing behavior preserved); every other non-zero
exit increments the per-issue counter. On clean exit, BOTH counters
are cleared (the per-issue clear is also a `route_run_stage_exit`
case for symmetry):

```bash
# In bin/run-local-helpers.sh (added in D-8):
# route_run_stage_exit <issue> <stage> <rc>
# rc==0 → clear both counters; rc==24 → global counter; else →
# per-issue counter. Returns 0 (caller still does `exit $rc`).
route_run_stage_exit() {
  local issue="$1" stage="$2" rc="$3"
  [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
    || die "route_run_stage_exit: invalid issue id '$issue'"
  local pic_file; pic_file="$(issue_dir "$issue")/.consecutive-failures"
  if (( rc == 0 )); then
    rm -f "$FAIL_COUNTER"
    rm -f "$pic_file"
    return 0
  fi
  case "$rc" in
    24)
      # ENG-69: linear-post-failed is harness-wide infrastructure
      # trouble. Linear API outage will fail the next dispatch too,
      # for ANY issue. Stay in the global lane.
      local count
      count="$(cat "$FAIL_COUNTER" 2>/dev/null || printf '0')"
      count="${count//[^0-9]/}"; count="${count:-0}"
      count=$((count + 1))
      printf '%s\n' "$count" > "${FAIL_COUNTER}.tmp.$$"
      mv -f "${FAIL_COUNTER}.tmp.$$" "$FAIL_COUNTER"
      log "run-stage.sh exited $rc (infrastructure); global consecutive failures = $count"
      if (( count >= FAIL_THRESHOLD )); then
        trip_breaker
      fi
      ;;
    *)
      # ENG-69: per-issue agent failure. classify_failure has
      # already halted the issue with the appropriate policy from
      # inside run-stage.sh; this is the soft-tally for cumulative
      # escalation.
      mkdir -p "$(dirname "$pic_file")"
      local pic
      pic="$(cat "$pic_file" 2>/dev/null || printf '0')"
      pic="${pic//[^0-9]/}"; pic="${pic:-0}"
      pic=$((pic + 1))
      printf '%s\n' "$pic" > "${pic_file}.tmp.$$"
      mv -f "${pic_file}.tmp.$$" "$pic_file"
      log "run-stage.sh exited $rc; per-issue consecutive failures for $issue = $pic"
      if (( pic >= FAIL_THRESHOLD )); then
        classify_failure "$issue" "$stage" "skip-until-human-acts" \
          "exceeded $FAIL_THRESHOLD consecutive same-issue failures (last exit $rc)" \
          "$rc"
      fi
      ;;
  esac
}
```

Caller in `run-local.sh:249-260` becomes:

```bash
route_run_stage_exit "$issue_id" "$stage" "$rc"
[[ $rc -ne 0 ]] && exit $rc
# Successful run-stage path continues with the partition sweep.
```

**Why.** Direct match for AC #3 ("Global breaker reserved for
infrastructure failures"). The choice of `rc=24` as the sole infra
exit follows from a survey of the failure_outcome_for_exit table
(`bin/common.sh:107-129`):

| Exit | Outcome | Lane | Why |
|---|---|---|---|
| 10 | guards-tripped | per-issue | per-stage guard (e.g. `count_marker_since_last_transition`); not infra |
| 11 | paused | per-issue | already-paused mid-flight; rare; per-issue safe |
| 12 | stage-drift | per-issue | stage label changed during run; per-issue Linear-state event |
| 13 | lane-violation | per-issue | wrong PIPELINE_WRITER for a Linear write; per-issue mis-routing |
| 14 | legacy-marker-write | per-issue | code path exercising a removed marker shape; per-issue |
| 20 | dispatch-failed | per-issue | `claude` died for stage-specific reasons (prompt error, agent crash) |
| 21 | scope-violation | per-issue | agent edited files outside plan; per-issue agent behavior |
| 22 | pr-opened-too-early | per-issue | implement agent invoked `gh pr create`; per-issue contract violation |
| 24 | **linear-post-failed** | **global** | Linear API outage WILL fail the next dispatch too |
| 25 | agent-contract-missing | per-issue | agent emitted neither summary nor verdict; per-issue agent behavior |
| 124 | dispatch-timeout | per-issue | wall-clock timeout on a specific stage; the agent for THIS issue is wedged |

Note on rc=11 / rc=12: the pause check at `bin/run-local.sh:97-103`
fires only at tick start; if `orchestrator.paused` flips mid-tick,
run-stage actually does `return 11` from
`bin/run-stage.sh:261,267`, reaching the rc-handler. rc=12
(stage-drift) presently exits 0 at `bin/run-stage.sh:899` so it
does NOT reach the handler today. Either way, routing per-issue
is the correct policy: rc=11 means "this issue's tick coincided
with a pause" — local to the moment, not a harness-wide infra
event.

Pre-dispatch infra failures (gh-app-token mint, `require_env`
LINEAR_API_KEY, `require_bin shasum`, etc. at
`bin/run-local.sh:88-93`) crash run-local.sh under `set -e` BEFORE
reaching the rc-handler. They never enter the counter logic; the
script exits non-zero on its own and the lock is released by the
EXIT trap. Subsequent ticks retry. So the rc-handler only needs
to distinguish run-stage's exit codes.

**Rejected alternative — also include rc=20 (dispatch-failed) in
the global lane.** dispatch-failed is the catch-all "claude
crashed" code; it includes both stage-specific failures (corrupt
prompt, agent self-loop) AND environmental ones (claude binary
missing, mutex contention timeout). The mix means an issue-specific
crash on ENG-X would unfairly count toward global pause. Rejected.

**Rejected alternative — every exit code routes per-issue; remove
the global counter entirely.** Loses the cross-issue infrastructure
signal. If Linear API is down, three different issues will fail
sequentially with rc=24, and the harness should pause to avoid
running a 5-min loop banging against an outage. Keeping rc=24 in
the global lane is the minimum to preserve that signal. Rejected.

**Rejected alternative — auto-detect infra failures via a different
mechanism (e.g. wrap linear.sh writes with retry+backoff and bubble
a distinct outage exit).** Bigger surface change; the existing
linear.sh has retry inside `add-or-update-comment` but caller-level
retries are not coordinated. Out of scope; AC #3 explicitly asks
for an exit-code list. Rejected.

### D-4: Atomic reset on `decide --action continue` clears the per-issue counter

**Verdict.** In `bin/pipeline.sh::_pipeline_clear_breaker` (lines
268-276), keep the global counter clear (idempotent) and add a
per-issue counter clear in `cmd_decide`'s atomic-reset block at
`bin/pipeline.sh:319-362` (between `_pipeline_drain_issue_state`
and `_pipeline_post_operator_transition`):

```bash
# ENG-69: per-issue consecutive-failures counter, sibling of the
# global one cleared by _pipeline_clear_breaker. Clear unconditionally
# on continue — same idempotent posture as drain_wait_files etc.
rm -f "$(issue_dir "$issue")/.consecutive-failures" 2>/dev/null || true
```

Optionally roll into a small helper `_pipeline_drain_issue_counter`
for symmetry with the existing drain_* family; recommended but not
required.

Update `cmd_decide`'s log line at `bin/pipeline.sh:358` to include
`per_issue_counter_cleared=…` if the helper returns a count, OR
just rely on the unconditional `rm -f` (matches the existing
`compgen -G` early-exit pattern at `bin/pipeline.sh:184-189`).

**Why.** AC #1 says self-leak halts the issue and "Does NOT touch
the global `.consecutive-failures` counter." Symmetrically, the
operator's `--action continue` to resume that issue must not leave
the per-issue counter at its last value (or the next per-issue
failure starts pre-loaded near threshold). The atomic-reset
already clears the global counter (`bin/pipeline.sh:274`); adding
the per-issue file is the natural completion.

**Rejected alternative — leave the per-issue counter in place; let
the next clean tick clear it.** Two failure modes: (1) the
post-resume tick may not be a clean run on this issue (e.g.,
operator resumes mid-investigation); (2) the per-issue counter
could persist across an issue's whole lifetime and surprise a
much later operator. Idempotent reset is cheap insurance.
Rejected.

### D-5: New exit codes `26 = self-leak` and `27 = leaked-in-scope-threshold`

**Verdict.** Add to `bin/common.sh:107-129`:

```bash
    26) printf 'self-leak' ;;
    27) printf 'leaked-in-scope-threshold' ;;
```

Update the comment block at `bin/common.sh:96-106` to mention
"self-leak (exit 26) and leaked-in-scope-threshold (exit 27) are
emitted from run-local.sh's tick-end sweep, not from run-stage.sh."

**Why.** The retrospective's §1 filter and `status.sh`'s red/yellow
predicate consume the typed outcome string. A new exit code without
a mapping routes to `unknown-exit-N` and the retrospective will
not classify it (verified: `bin/common.sh:127`). Two new codes (26,
27) preserve clean retrospective slicing across the three failure
modes that route through the sweep: self-leak (26), leaked-in-scope
at threshold (27), and scope-violation in run-stage (21, unchanged).
The taxonomy addition is two lines and follows the existing pattern.

**Rejected alternative — reuse exit 21 (scope-violation) with a
new subcode for either of these.** Scope-violation and self-leak
are operationally distinct (see D-1's rejected-alternative
discussion). Folding leaked-in-scope-threshold into the same bucket
as scope-violation hides the cumulative-tally signal under the
single-event signal — both useful, both retrospective-relevant, both
should be sliceable. Rejected.

**Rejected alternative — pass exit 0 because the run-stage actually
succeeded.** Misleads `classify_failure`'s evidence-tracking
(`bin/classify-failure.sh:67-77`) which gates auto-escalation on
exit_code matching across retries. Rejected.

### D-6: Update CLAUDE.md "Failure-mode quick reference" table

**Verdict.** Replace the existing "Breaker tripped" row at
`CLAUDE.md:386` with two rows that distinguish per-issue halt from
the (now narrowed) global breaker. The headline value to the
operator is **single-command recovery**: per-issue halts no longer
require touching `orchestrator.paused`.

```markdown
| Per-issue halt (self-leak / leaked-in-scope at threshold / N×same-issue failure) | Linear comments under sig `halt/<stage>/<issue>` (verdict result=halt, reason=agent-blocked); `pipeline:halted` + `pipeline:skip-until-human-acts` labels; `$(issue_dir <issue>)/.consecutive-failures` carries the count. Other issues continue to be polled — do NOT touch `orchestrator.paused`. **One-command recovery:** `bash bin/pipeline.sh decide <ENG-N> --action continue` (clears halt label, skip labels, per-issue counter, issue-state, posts operator-resume waypoint). |
| Global breaker (infrastructure outage) | `$PROJECT_STATE_DIR/.consecutive-failures` ≥ 3 from rc=24 (linear-post-failed) accumulated across ticks; `orchestrator.paused=true` in `STATE_FILE`. Resolve with `set_orchestrator_paused false` (or any `decide --action continue`, which also clears the breaker via `_pipeline_clear_breaker`). The next clean tick clears the global counter. |
```

**Why.** AC #7 is explicit. The runbook is the durable operator
surface; without this update, an operator seeing `pipeline:halted`
will reach for `set_orchestrator_paused false` (the global
operation) instead of `decide --action continue` (the per-issue
operation), and the symptom will not match the reach.

### D-7: Tests in `bin/run-local-helpers-adversarial-test.sh`

**Verdict.** Append four test groups to
`bin/run-local-helpers-adversarial-test.sh` (the existing file with
the trip_breaker tests at lines 624-673; pattern-matched):

1. **`test_self_leak_routes_to_per_issue_halt_not_breaker`** —
   stub `classify_failure` as a capture function; invoke
   `halt_issue_for_self_leak ENG-X reviewing aabbccdd1122 ddeeff334455`;
   assert the capture file shows `policy=skip-until-human-acts`,
   `exit_code=26`, `issue=ENG-X`, reason contains both hashes
   (`aabbccdd1122`, `ddeeff334455`) and matches the regex
   `^[0-9a-f]{12}(, [0-9a-f]{12})*$` for the hash list (no raw paths
   in body — security persona P1-1); AND `is_orchestrator_paused`
   returns `false`; AND `$PROJECT_STATE_DIR/.consecutive-failures`
   does not exist; AND a second invocation on the same issue
   produces still exactly ONE captured `classify_failure` call per
   tick (idempotency). Truncation: invoking with 7 hashes asserts
   the comment body lists 5 + " (and 2 more)" (security P1-1, OQ
   for halt-spam DoS).
2. **`test_leaked_in_scope_increments_per_issue_counter`** — three
   sequential ticks, each emitting one leaked-in-scope path on the
   same issue. After tick 1: `$(issue_dir ENG-X)/.consecutive-failures`
   = 1, no halt. After tick 2: 2, no halt. After tick 3:
   `classify_failure` invoked with `skip-until-human-acts`, plus
   the per-issue counter at 3.
3. **`test_run_stage_rc_24_increments_global_counter`** — three
   ticks where run-stage exits 24; assert global counter increments
   to 3 and `trip_breaker` is invoked. Negative half: same scenario
   with rc=20 (dispatch-failed) — assert per-issue counter
   increments, global counter stays at 0.
4. **`test_cross_issue_isolation`** — tick 1: ENG-A self-leaks.
   Asserts global breaker NOT tripped; ENG-A's issue-state.json
   has policy=skip-until-human-acts. Tick 2: poll returns ENG-B
   (different issue, no halt) — dispatches normally. Tick 3:
   poll returns ENG-C — also normal. Reproduces the 2026-05-05
   ENG-63→ENG-64/65 incident as a regression lock.

The test stubs use the same source-and-stub pattern as the existing
file: stub `classify_failure` as a capture function (logs args to
a file in `STUB_DIR`), stub `linear.sh`, stub `metrics.sh`, stub
`set_orchestrator_paused` to write to a fake STATE_FILE under
`mktemp -d`. Subshell wrapping (`(...)`) for each tick so `set -e`
exits don't kill the harness.

**Why.** Direct match for AC #4-#6. The cross-issue test is the
specific regression lock for ENG-63's incident — write the test
before the fix so it fails on `main` and passes on the branch.

**Rejected alternative — new file `bin/run-local-failure-routing-test.sh`.**
Adds another sibling file when an existing one (`bin/run-local-helpers-adversarial-test.sh`)
already covers `trip_breaker`. The tests for D-1/D-2/D-3 are
trip_breaker's logical siblings. Rejected.

**Rejected alternative — black-box test that invokes `bash
bin/run-local.sh` end-to-end.** Requires a fake worktree, fake
LINEAR_API_KEY, fake gh-app-token, and a deterministic
`bin/poll.sh` answer for every tick. ~3-4× the LOC; brittle to
upstream changes. The function-level tests via source-and-stub
catch the same regressions at much lower complexity. Rejected.

### D-8: Extract failure-routing into `run-local-helpers.sh` functions (load-bearing for D-1, D-2, D-3, D-7)

**Verdict.** Move the three failure-routing inline blocks
(self-leak, leaked-in-scope, run-stage rc-fork) into named
functions in `run-local-helpers.sh`. Names follow the existing
verb-object cadence (`trip_breaker`, `partition_dirty_paths`,
`auto_commit_in_scope`, `acquire_lock`):

| Function | Replaces | Tested by |
|---|---|---|
| `halt_issue_for_self_leak` | `bin/run-local.sh:304-318` | D-7 #1 |
| `tally_leaked_in_scope_failure` | `bin/run-local.sh:320-341` | D-7 #2 |
| `route_run_stage_exit` | `bin/run-local.sh:249-260` | D-7 #3 |

Function bodies are shown inline in D-1, D-2, D-3 above. Keep the
run-local.sh body thin: each new function is called from the same
line range it replaces.

**Why required (not optional).** Two load-bearing reasons:

1. **Test reachability.** The adversarial test pattern in
   `bin/run-local-helpers-adversarial-test.sh` (the file D-7
   extends) consumes _functions_ sourced from a helpers file, not
   _inline blocks_ in `run-local.sh`. Without the extraction, D-7
   is forced into the black-box subprocess mode rejected in D-7's
   alternative.
2. **`local` keyword scope.** The D-1 / D-2 / D-3 snippets use
   `local`-scoped variables for cleanup safety; `local` is invalid
   outside a function body. Either every snippet must drop `local`
   (polluting `run-local.sh`'s top-level namespace; risk of name
   collisions with later code) or the snippets must live inside
   functions. Coherence persona (iter-1 F5) flagged this.

Total LOC delta: ~+90 in `run-local-helpers.sh`, ~-50 in
`run-local.sh` (~+40 net).

**Rejected alternative — keep code inline; drop `local` keywords;
black-box test.** Already rejected in D-7 for LOC bloat. The
`local`-removal also creates name-collision risk with the existing
top-level variables in `run-local.sh` (e.g. `count`, `pic`,
`rc`). Rejected.

**Rejected alternative — extract to a NEW file
`bin/failure-routing.sh`.** Premature granularity. The three
functions belong with `trip_breaker` and `partition_dirty_paths`
under the "post-tick decision logic" umbrella that
`run-local-helpers.sh` already covers. Rejected.

**Rejected alternative — bigger refactor (move acquire_lock,
sweep loop, partition into a single helpers file rewrite).** Pure
scope creep. ENG-69 is a bug fix; D-8 ships only the minimum
extraction needed to satisfy AC #4-#6's test requirements.
Rejected (scope persona iter-1 P1).

## 5. Architecture (where code goes)

| File | What changes | Decision |
|---|---|---|
| `bin/run-local.sh:25-28` | source `classify-failure.sh` after `run-local-helpers.sh` | D-1 |
| `bin/run-local.sh:249-260` | replace inline rc-handler with `route_run_stage_exit "$issue_id" "$stage" "$rc"` call; clean-tick double-clear collapses into route_run_stage_exit's `rc==0` arm | D-3, D-8 |
| `bin/run-local.sh:304-318` | replace inline self-leak block with `halt_issue_for_self_leak "$issue_id" "$stage" "${self_leak_hashes[@]}"` | D-1, D-8 |
| `bin/run-local.sh:320-341` | replace inline leaked-in-scope block with `tally_leaked_in_scope_failure "$issue_id" "$stage" "$leaked_count" "$leaked_hashes"` | D-2, D-8 |
| `bin/run-local-helpers.sh` (new functions, ~+90 LOC) | `halt_issue_for_self_leak`, `tally_leaked_in_scope_failure`, `route_run_stage_exit` (each with `[[ "$issue" =~ ^ENG-[0-9]+$ ]]` validation; integer sanitizer + atomic write on counter mutations) | D-8 |
| `bin/common.sh:107-129` | add `26) printf 'self-leak' ;;` and `27) printf 'leaked-in-scope-threshold' ;;` to `failure_outcome_for_exit` | D-5 |
| `bin/pipeline.sh:319-362` (cmd_decide continue block) | add `rm -f "$(issue_dir "$issue")/.consecutive-failures"` between `_pipeline_drain_issue_state` and `_pipeline_post_operator_transition` | D-4 |
| `bin/run-local-helpers-adversarial-test.sh` (append ~120 LOC) | four test groups per D-7 | D-7 |
| `CLAUDE.md:386` | replace "Breaker tripped" row with two rows distinguishing per-issue halt from global breaker | D-6 |

No other files change. No `AGENT_PROMPTS.md` changes. No new
`dispatch.sh::allowed_tools_for` case. No `linear.sh` changes.
No `metrics.sh` changes (existing `sweep-self-leak-out-of-scope`
and `sweep-leaked-in-scope` events keep their shape).

## 6. Data flow

The control-flow change is per-branch only; the overall tick shape
is unchanged.

```
run-local.sh tick
  ↓
acquire_lock + paused-check + env-load (unchanged)
  ↓
poll.sh → (issue_id, stage, entry_action) (unchanged)
  ↓
ensure_worktree + tick-start snapshot (unchanged)
  ↓
run-stage.sh "$issue_id" "$stage"   ← rc captured
  ↓
┌─ rc != 0 ─────────────────────────────┐
│ rc==24 → global counter += 1; trip   │  D-3
│         breaker at 3                  │
│ rc!=24 → per-issue counter += 1;     │  D-3
│         classify_failure halt at 3    │
│ exit $rc                              │
└───────────────────────────────────────┘
  ↓ (rc==0)
clear BOTH counters (D-3 cleanup)
  ↓
partition_dirty_paths (unchanged)
  ↓
┌─ self-leak hashes nonempty ───────────┐
│ emit sweep-self-leak metric           │
│ classify_failure skip-until-human-    │  D-1
│   acts (writes issue-state.json,      │
│   labels, halt comment)               │
│ exit 1                                │
└───────────────────────────────────────┘
  ↓ (no self-leak)
┌─ leaked count > 0 ────────────────────┐
│ emit sweep-leaked-in-scope metric     │
│ per-issue counter += 1                │  D-2
│ classify_failure skip-until-human-    │
│   acts at threshold                   │
│ exit 1                                │
└───────────────────────────────────────┘
  ↓ (no leaks)
commit + push in-scope (unchanged)
  ↓
release watcher + periodic cleanup (unchanged)
```

What changes in `events.jsonl`:

Before (self-leak path):
```json
{"event":"sweep-self-leak-out-of-scope","issue_id":"ENG-63","stage":"reviewing","outcome":"self-leak","notes":"count=1 hashes=abc..."}
{"event":"breaker-trip", ...}      // implicit via trip_breaker logging only; no metric
```
(then orchestrator pause; subsequent ticks silent)

After (self-leak path):
```json
{"event":"sweep-self-leak-out-of-scope","issue_id":"ENG-63","stage":"reviewing","outcome":"self-leak","notes":"count=1 hashes=abc..."}
{"event":"stage-end","issue_id":"ENG-63","stage":"reviewing","outcome":"self-leak","duration_ms":0,"notes":"exit=26 policy=skip-until-human-acts ..."}
```
(other issues continue normally; no orchestrator pause)

Note the deliberate double-event-on-self-leak: the legacy
`sweep-self-leak-out-of-scope` metric carries the leaked-paths
inventory; the new `stage-end` event (from classify_failure) carries
the typed outcome via failure_outcome_for_exit and the policy. Both
are useful to the retrospective. See §10 OQ-1.

## 7. Error handling

- **classify_failure itself fails** (linear.sh post fails, fs write
  fails). classify_failure's internal calls all carry `|| true`
  (`bin/classify-failure.sh:108-149`). The state-file write at
  `bin/classify-failure.sh:102` runs under `set -e` outside the
  function's local try-blocks; an fs failure would propagate. This
  is the same failure mode as today's run-stage call sites; no
  ENG-69 regression. (If the state-file write fails, the next tick
  re-classifies — idempotent.)
- **`issue_dir "$issue_id"` does not exist**. Today the directory
  is created on demand (`mkdir -p "$(issue_dir "$ident")"` at
  `bin/run-stage.sh:634`). Per-issue counter writes use
  `mkdir -p "$(dirname "$_pic_file")"` before `printf >`. Safe.
- **`PIPELINE_DRY_RUN=1`**. Today's behavior: `trip_breaker` and
  the counter increments are skipped under DRY_RUN. New behavior
  preserves this — the per-issue counter writes and `classify_failure`
  call live inside the `if [[ "$PIPELINE_DRY_RUN" != "1" ]]` block.
- **Concurrent ticks** (overlapping due to lock breakage). The
  POSIX-atomic lock at `bin/run-local-helpers.sh:349-367` already
  prevents this. Per-issue counter writes are file-level
  read-modify-write; in the unlikely event of a torn write, worst
  case is one undercount or one duplicate increment, neither of
  which corrupts state.
- **Counter file corrupted (non-integer body)**. The increment uses
  `_pic="$(cat "$_pic_file" 2>/dev/null || echo 0)"; _pic=$((_pic + 1))`
  — bash's `$(( ))` evaluates a non-integer string as 0 (or fails
  under `set -e`). The `|| echo 0` covers the empty-file case;
  the `_pic=$((_pic + 1))` would die on `set -e` if cat returned
  garbage. Mitigation: use `printf '%d' "$_pic" 2>/dev/null || _pic=0`
  before the increment. Add to D-2 / D-3 implementation hardening.
- **Per-issue counter persists across `--action abandon`.**
  `--action abandon` is the operator's "give up on this issue"
  signal. Today the per-issue side state is left in place
  (issue-state.json, etc. — `bin/pipeline.sh::cmd_decide` only
  drains state on `continue`). Out of scope for ENG-69; counter
  carries no risk in the abandoned state because the issue is
  abandoned. Flagged.
- **Self-leak hashes list >5**. classify_failure's reason field
  has no length limit, but the rendered halt comment can wrap.
  Truncate at 5 hashes (per AC #1 wording: "one line per hash,
  max 5") with a `...and N more` suffix when count exceeds 5.
- **Stage label changed during run** (rc=12 stage-drift). Today
  the rc=12 path does NOT increment the counter (it exits 0 from
  `bin/run-stage.sh:899` after emitting a stage-drift metric).
  ENG-69 doesn't change this. Verified: `bin/run-stage.sh:894-900`
  hits `exit 0`, not `exit 12`. The exit code 12 in the taxonomy
  is reserved for symmetry but is currently unused.

## 8. Edge cases

| Case | Behavior |
|---|---|
| Self-leak followed immediately by leaked-in-scope on the same tick | Today self-leak takes precedence (`bin/run-local.sh:301-302` comment: "self-leak (hard-fail) > leaked-in-scope"). New code preserves this — self-leak branch's `exit 1` short-circuits before leaked-in-scope is examined. Per-issue counter remains untouched on a self-leak tick due to short-circuit ordering (the leaked-in-scope branch where the counter increment lives is never reached). Side-effect of branch ordering, not a designed contract. |
| Self-leak on issue ENG-X, immediately followed by clean tick on ENG-Y | Tick N: ENG-X halted, per-issue counter for ENG-X NOT incremented (D-1: classify_failure handles halt; counter is for "soft accumulation toward halt"). Tick N+1: poll skips ENG-X (halted), polls ENG-Y; clean tick; ENG-Y's counter at 0 unaffected; both global and ENG-X-specific counters at 0. |
| Per-issue counter at 2, next tick exit code is 24 (rare: linear-post-failed on a previously-flaky issue) | rc=24 → global counter += 1 (now at 1, assuming previously clean globally); per-issue counter for that issue NOT incremented. Operator sees: "global breaker has 1 strike; per-issue ENG-X is at 2 strikes." Both signals are independent and informative. |
| `decide --action continue` on a halted issue with per-issue counter at 3 and global counter at 0 | D-4: `rm -f` clears the per-issue counter; global is left at 0 (unchanged); `pipeline:halted` and `skip-until-human-acts` cleared by existing helpers; transition waypoint posted. Issue resumes at 0/0. |
| `decide --action continue` when both global breaker tripped AND per-issue counter at 3 (unlikely; would require linear-post-failed in addition to per-issue trouble) | D-4 + existing _pipeline_clear_breaker: both counters cleared, paused unset, all per-issue side state cleared. Issue and orchestrator both reset. |
| Run-stage exits 11 (already-paused). | Today: counter increments. New: routes to per-issue counter. The increment is harmless because exit 11 means run-stage detected an external pause mid-flight (e.g. operator set `orchestrator.paused=true` while a tick was running). Next tick should hit the pause check at `bin/run-local.sh:97-103` and exit 0 before reaching the rc-handler. Counter rarely increments here in practice. Acceptable. |
| Run-stage emits its own `classify_failure` (e.g. on rc=21) AND run-local hits the threshold and emits another `classify_failure`. | Two classify_failure calls on the same issue+stage on the same tick. issue-state.json is over-written by the second one (atomic via `mv -f`). Halt comment is upserted via `add-or-update-comment` (idempotent — same sig, body updated). The second call's policy `skip-until-human-acts` is what survives. Acceptable; the threshold escalation is the intended override. |
| Brand-new issue with no `issue_dir` yet, leaked-in-scope on first tick. | `mkdir -p "$(dirname "$_pic_file")"` creates the dir on demand. Counter increments to 1; no halt. |
| Issue under `pipeline:abandoned` label (operator-applied). | Today: poll.sh skips abandoned issues. ENG-69 doesn't change poll behavior. The per-issue counter never increments for an abandoned issue because run-stage never runs against it. Stale counter file is harmless. |
| `compute_pipeline_content_hash` (called by classify_failure to record evidence) takes >1s on a slow disk. | Same behavior as today's classify_failure call sites in run-stage. Latency added per self-leak tick: ~100-500 ms. Below the 5-min tick budget. Acceptable. |

## 9. Persona review

Six personas dispatched. Verdicts and any folded P0/P1 findings are
recorded at the end of the brainstorming stage; if any P0 remained
after iteration 2, the gate sets status=`escalate`. The status line
in the stage summary names the final pass count and any unresolved
P0s.

(Slot intentionally pre-populated with structure; final verdicts and
folded findings are appended below by the iteration loop.)

### Iteration 1

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| design | PASS | 0 | 5 |
| security | PASS | 0 | 4 |
| scope | PASS | 0 | 2 (+2 P2) |
| coherence | PASS | 0 | 3 (+2 P2) |
| product | PASS | 0 | 3 (+2 P2) |
| feasibility | _pending_ | _ | _ |

**P1 findings folded for iteration 2:**

- design-P1-1 / coherence-F2 (D-2 exit-code subcode-vs-new-code
  inconsistency) → resolved by introducing **exit 27 =
  leaked-in-scope-threshold** in D-5; D-2 now passes 27 (not 21/4)
  to classify_failure.
- design-P1-2 (verb-naming asymmetry of new helpers) → renamed
  `handle_self_leak` → `halt_issue_for_self_leak`,
  `handle_leaked_in_scope` → `tally_leaked_in_scope_failure`,
  `handle_run_stage_failure` → `route_run_stage_exit`.
- design-P1-3 / coherence-F1 (clean-tick double-clear inline) →
  collapsed into `route_run_stage_exit`'s `rc==0` arm; §1 scope
  flag updated to clarify both counters reset on clean tick.
- design-P1-4 / product-P2-B (D-7 test 1 spec for double
  stage-end / hash-only contract) → D-7 test 1 spec now asserts
  the hash list matches `^[0-9a-f]{12}(, [0-9a-f]{12})*$`,
  truncation behavior, and dedup (one `classify_failure` call per
  tick, not two).
- design-P1-5 / scope-P1 (`reset-pipeline.sh` hedge) → §10 OQ-7
  hedge dropped; explicitly out-of-scope, flagged for separate
  followup; D-6 row no longer mentions reset-pipeline.sh.
- security-P1-1 (halt-comment marker injection) → resolved by
  D-1's explicit "no raw paths flow into the comment body"
  contract; D-7 #1 assertion locked.
- security-P1-2 (issue-id validation) → added
  `[[ "$issue" =~ ^ENG-[0-9]+$ ]]` guard at the top of every new
  helper.
- security-P1-3 (counter-file integrity) → integer sanitizer
  `pic="${pic//[^0-9]/}"; pic="${pic:-0}"` and atomic write
  `> .tmp.$$ && mv -f` baked into the D-1 / D-2 / D-3 snippets.
- security-P1-4 (dedup assertion) → D-7 #1 includes the "exactly
  one classify_failure call per tick" check.
- coherence-F3 (§8 row 1 framing) → row 1 now reads "due to
  short-circuit ordering" rather than implying an explicit AC
  contract.
- coherence-F4 (rc=11/12 vacuous routing) → reserved-but-unused
  status flagged inline in D-3's table.
- coherence-F5 (D-8 `local` keyword) → D-8 promoted from optional
  to load-bearing for D-1 / D-2 / D-3 / D-7.
- coherence-F6 (AC mapping double-mapping) → AC4 row split:
  AC1 row tests the contract; AC4 row tests the fixture/invocation.
- scope-P1 (D-8 minimal extraction) → D-8's "Rejected
  alternatives" now explicitly forbids broader helpers refactor.
- scope-P1 (D-6 reset-pipeline mention) → D-6 row drops
  reset-pipeline; uses set_orchestrator_paused only.
- product-P1-A (status.sh visibility) → flagged in §10 OQ-6 as
  visualization enhancement, separate ticket. Not folded into
  ENG-69 (scope persona objection upheld).
- product-P1-B (operator-win wording in CLAUDE.md row) → D-6
  row leads with "Other issues continue to be polled — do NOT
  touch `orchestrator.paused`. **One-command recovery:** ..."
- product-P1-C (reset-pipeline.sh promotion) → declined; §10
  OQ-7 hedging dropped; flagged as separate followup.

### Iteration 2

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| feasibility | PASS | 0 | 2 (+1 P2) |

Iteration 2 P1s (folded inline; non-load-bearing):
- feasibility-P1-1 (rc=11 commentary) → §4 D-3 paragraph on
  reserved exit codes rewritten to acknowledge that rc=11 DOES
  reach the rc-handler if `orchestrator.paused` flips mid-tick;
  routing remains per-issue (correct policy).
- feasibility-P1-2 (incomplete classify_failure call-site list in
  §1) → list expanded to 8 actual sites.
- feasibility-P2 (D-4 wording precision) → acknowledged; D-4's
  "between drain_issue_state and post_operator_transition" is
  imprecise (multiple steps fall in that range); plan stage may
  pick a more specific anchor.

**Status: Personas: 6/6 PASS · gate P0: 0 · proceeding to planning.**

## 10. Open questions / out of scope

1. **Double `stage-end` metric on self-leak ticks.** `classify_failure`
   emits a `stage-end` metric via `bin/classify-failure.sh:154-157`.
   On self-leak, run-stage.sh has already exited 0 — meaning
   `post_completion_comment` ran and run-stage.sh emitted its own
   `stage-end` metric (verified at `bin/run-stage.sh:917, 957` —
   stage-end is emitted in the success path). The sweep then calls
   classify_failure which emits ANOTHER `stage-end`. Net: two
   `stage-end` events per self-leak tick. The retrospective's §1
   stage-pairing logic tolerates duplicates (it joins by
   issue+stage, not 1-to-1 with stage-start). Wart, not bug. To
   eliminate: factor `classify_failure` into a stage-end-emitting
   path and a stage-end-skipping path. Out of scope for ENG-69;
   flagged as a followup (would benefit ENG-7's metric-shape
   work too).
2. **Sweep-emitted sweep-self-leak-out-of-scope outcome string is
   `"self-leak"`** (today, `bin/run-local.sh:310-311`) **and the
   new failure_outcome_for_exit table also returns `"self-leak"`
   for exit 26.** Coincidentally identical strings. Retrospective
   joins safely, but a future contributor changing one string
   could miss the other. Not a regression (today's setup is
   consistent); flagged.
3. **`--action abandon` does not clear per-issue counter.** Today
   it doesn't drain anything (`bin/pipeline.sh:cmd_decide` runs
   the atomic-reset block ONLY for `continue`). Counter persists
   for an abandoned issue. Harmless — abandoned issue never gets
   polled — but inconsistent. Out of scope; flagged.
4. **Cross-issue infrastructure detection beyond rc=24.** A future
   contributor may discover that rc=20 (dispatch-failed) is split
   into "agent crashed" vs "claude binary missing"; the latter is
   infra. Today the codes don't distinguish. Improving granularity
   would need new exit codes from dispatch.sh. Out of scope;
   flagged.
5. **Per-issue counter file is plain-text (single integer).** No
   schema versioning, no lock file. Concurrent writes (theoretically
   possible if tick-lock breaks) could corrupt the integer.
   Mitigation in §7. Acceptable for ENG-69; future hardening
   (atomic write via temp+rename, or jq-based JSON shape) is a
   separate ticket.
6. **`status.sh` and the dashboard — per-issue counter visibility.**
   `bin/status.sh` reads `events.jsonl` and prints red/yellow
   predicates. Today it reads the global `.consecutive-failures`
   counter; under ENG-69, the global counter is sparser (only
   rc=24). Operators looking at status.sh would not see "ENG-X
   is one strike from per-issue halt." Iteration-1 product persona
   (P1-A) flagged this as a real visibility gap. Improving
   status.sh to display per-issue counters is a visualization
   enhancement, ~10 LOC; out of scope strictly (no AC asks for
   it). **Flagged for separate followup ticket** (e.g. ENG-69.5).
   Without it, operators must `cat
   $PROJECT_STATE_DIR/<ident>/.consecutive-failures` directly to
   see the strikes. The per-issue halt comment posted at threshold
   is the operator's primary signal regardless.
7. **`bin/reset-pipeline.sh` does not clear per-issue counters.**
   Verified at `bin/reset-pipeline.sh:25-28` — it only clears the
   global counter file. For consistency with D-4, it could also
   clear all `$(PROJECT_STATE_DIR)/ENG-*/.consecutive-failures`
   files. Strictly out of scope (AC #4-#6 only require the change
   in `decide --action continue`). Flagged for a separate followup
   ticket; do NOT pull into ENG-69's plan.
8. **Per-issue counter leaks across stages.** A failure on ENG-X
   at `stage:reviewing` increments the counter; if the operator
   manually transitions ENG-X back to `stage:planning` and the
   plan stage fails again, the counter is at 2. That's "consecutive
   failures of this issue" semantically, regardless of stage. This
   matches the existing global counter semantics (also stage-agnostic).
   Not a defect; flagged because a future contributor might assume
   stage scoping.
9. **`partition_dirty_paths::D-004` and the brainstorm doc basename.**
   Verified that this brainstorm's filename `2026-05-07-eng-69-...-design.md`
   contains the literal `eng-69` token, satisfying the
   case-insensitive issue-id basename check at
   `bin/run-local-helpers.sh:181-182`. Without it, the post-stage
   sweep would classify the doc as leaked-in-scope and increment
   the per-issue counter (the very mechanism we're testing).
   Confirmed compliant.

## 11. Acceptance criteria

The Linear issue lists 7 acceptance criteria. All are verified by
the new tests (D-7) plus a doc edit (D-6).

| AC | Verifies | Verification |
|---|---|---|
| AC1 | Self-leak halt is per-issue: classify_failure with skip-until-human-acts, posts halt comment naming leaked paths (max 5), applies halt + skip-until-human-acts labels, exits 1, does NOT touch orchestrator.paused or global .consecutive-failures. | Behavior contract — verified by D-1 implementation + D-7 test 1's outcome assertions (capture file shows `policy=skip-until-human-acts`, `exit_code=26`; `is_orchestrator_paused` returns `false`; global counter file does not exist). |
| AC2 | Per-issue rejection counter at `$(issue_dir <issue>)/.consecutive-failures`; threshold 3; at threshold, route to per-issue skip-until-human-acts. Other issues continue to be polled. | D-2 implementation (leaked-in-scope) + D-3 implementation (run-stage rc≠0); D-7 test 2 (`test_leaked_in_scope_increments_per_issue_counter`); D-7 test 4 (`test_cross_issue_isolation`). |
| AC3 | Global breaker reserved for infrastructure failures: rc=24 enumerated explicitly; other exit codes per-issue only. | D-3 implementation; D-7 test 3 (`test_run_stage_rc_24_increments_global_counter`). |
| AC4 | Test (positive): synthetic ENG-X self-leak; after tick: orchestrator.paused=false, ENG-X has labels, halt comment names leaked path, no global counter. | Test infrastructure — D-7 test 1's fixture/invocation half: stub classify_failure as a capture function, invoke `halt_issue_for_self_leak ENG-X reviewing <hash> <hash>`, then read the capture file. AC1's outcome assertions ride on top of this fixture. |
| AC5 | Test (negative — breaker still works): 3 ticks of dispatch.sh dies with linear-post-failed (rc=24) on different issues; orchestrator.paused=true, breaker tripped. | D-7 test 3's negative half. |
| AC6 | Test (cross-issue isolation): ENG-A self-leaks tick 1; ENG-B normal tick 2; ENG-C normal tick 3. Reproduces ENG-63→ENG-64/65 incident. | D-7 test 4 directly. |
| AC7 | CLAUDE.md "Failure-mode quick reference" entry distinguishes per-issue halt from global breaker. | D-6 doc edit. |

## 12. Anti-bias checks

### ADR stress test

There is no `docs/knowledge/decisions.md` (verified: `ls docs/`
returns no `knowledge/` subdir). The architectural commitments to
interact with are:

- **ENG-10 D-002 (failure_outcome_for_exit taxonomy).** This
  brainstorm adds a new exit code (26 = self-leak) following the
  documented pattern. No pressure on the taxonomy; it's an extension.
- **ENG-58 / ENG-60 atomic reset.** D-4 extends the atomic-reset
  contract to clear the per-issue counter. The existing contract
  is "Idempotent — safe to re-run" (CLAUDE.md:400-402). Adding
  one more `rm -f` strengthens that contract; no pressure.
- **ENG-14 D-3 (3-stream partition sweep).** This brainstorm does
  not change `partition_dirty_paths` or the in-scope/leaked/observed
  classification. It only changes what happens AFTER classification.
  No pressure on ENG-14.
- **ENG-15 (per-issue state directory).** This brainstorm adds a
  new file (`<issue_dir>/.consecutive-failures`) under the existing
  per-issue state dir. Mirrors the existing `issue-state.json`,
  `wait-*.json`, etc. pattern. Strengthens ENG-15's
  per-issue-state-only contract; no pressure.
- **ENG-23 path-variable rename.** This brainstorm uses
  `$PROJECT_STATE_DIR` and `issue_dir(...)` correctly throughout.
  No pressure.
- **ENG-56 (orchestrator-owned `pipeline:halted` apply).**
  classify_failure already applies `pipeline:halted` (verified at
  `bin/classify-failure.sh:119`); this brainstorm reuses
  classify_failure unchanged. The orchestrator-owned property is
  preserved (run-local.sh's invocation IS the orchestrator).
- **ENG-65 brainstorm cap (60-min timeout, 2-iteration cap).**
  Unrelated. No pressure.

No ADR is destabilized.

### Simpler-alternative table

| Decision | Simpler alt | Why rejected |
|---|---|---|
| D-1 (classify_failure for self-leak) | Inline halt logic without classify_failure | ~80 LOC duplication; loses evidence trail; rejected |
| D-1 (classify_failure for self-leak) | Keep trip_breaker; add classify_failure on top | Defeats the purpose — global pause still blocks other issues |
| D-2 (per-issue counter for leaked-in-scope) | Keep global counter; just don't trip breaker | Issue's AC #2 is explicit; without per-issue counter, an issue can leak forever |
| D-3 (rc=24 → global; else per-issue) | Every exit code per-issue; remove global counter | Loses cross-issue infrastructure-outage signal |
| D-3 (rc=24 → global; else per-issue) | Add rc=20 (dispatch-failed) to global lane | Mixes per-issue agent crashes with infra; unfair counting |
| D-4 (clear per-issue counter on continue) | Let next clean tick clear it | Counter could persist if next tick isn't clean |
| D-5 (exit 26 = self-leak) | Reuse exit 21 (scope-violation) | Different operational signals; obscures retrospective slicing |
| D-7 (extend adversarial test file) | New file `bin/run-local-failure-routing-test.sh` | Sibling tests to trip_breaker belong with trip_breaker's tests |
| D-7 (function-level tests) | Black-box `bash bin/run-local.sh` test | 3-4× LOC; brittle |
| D-8 (extract to helpers functions) | Keep code inline | Tests can't reach inline blocks via source-and-stub |

### Assumption inventory (codebase-fact verification)

| # | Assumption | Status | Evidence |
|---|---|---|---|
| 1 | `bin/run-local.sh:304-318` is the self-leak branch; today calls `trip_breaker; exit 1`. | verified | `bin/run-local.sh:301-318` (read directly) |
| 2 | `bin/run-local.sh:320-341` is the leaked-in-scope branch; today increments the global `FAIL_COUNTER` and calls `trip_breaker` at threshold. | verified | `bin/run-local.sh:320-341` (read directly) |
| 3 | `bin/run-local.sh:249-258` is the run-stage rc-handler; today increments the global `FAIL_COUNTER` for any non-zero rc. | verified | `bin/run-local.sh:249-260` (read directly) |
| 4 | `bin/run-local.sh:32-33` defines `FAIL_COUNTER="$PROJECT_STATE_DIR/.consecutive-failures"` and `FAIL_THRESHOLD=3`. | verified | `bin/run-local.sh:32-33` (read directly) |
| 5 | `bin/run-local-helpers.sh:42-45` defines `trip_breaker` which calls `set_orchestrator_paused true`. | verified | `bin/run-local-helpers.sh:42-45` (read directly) |
| 6 | `bin/classify-failure.sh::classify_failure` accepts `<issue> <stage> <base_policy> <reason> <exit_code> [<subcode>]`, writes issue-state.json, applies halt + skip-until-* labels, posts halt comment, emits stage-end. | verified | `bin/classify-failure.sh:39-159` (read directly) |
| 7 | `bin/classify-failure.sh:106-114` applies `pipeline:halted` and `pipeline:skip-until-human-acts` for policy=skip-until-human-acts. | verified | `bin/classify-failure.sh:106-119` (read directly) |
| 8 | `bin/classify-failure.sh:121-146` posts a halt comment with marker `<!-- pipeline: verdict result=halt reason=agent-blocked -->` for policy=skip-until-human-acts. | verified | `bin/classify-failure.sh:127-128` (marker reason "agent-blocked") + 121-146 (body construction) |
| 9 | `bin/run-stage.sh:763-771` is the SEVERE scope-violation path that calls classify_failure with skip-until-human-acts and exits 21 — the precedent ENG-69 generalises. | verified | `bin/run-stage.sh:763-771` (read directly) |
| 10 | `failure_outcome_for_exit` in `bin/common.sh:107-129` is a case-switch with entries for codes 0,10,11,12,13,14,20,21,22,24,25,124, falling through to `unknown-exit-N`. | verified | `bin/common.sh:107-129` (read directly) — exit codes confirmed |
| 11 | `bin/pipeline.sh::_pipeline_clear_breaker` (lines 268-276) calls `set_orchestrator_paused false` and `rm -f "$PROJECT_STATE_DIR/.consecutive-failures"`. | verified | `bin/pipeline.sh:268-276` (read directly) |
| 12 | `bin/pipeline.sh::cmd_decide` for action=continue runs the atomic-reset block at lines 319-362, clearing wait files, skip labels, issue-state, breaker, then posting operator-resume waypoint. | verified | `bin/pipeline.sh:319-362` (read directly) |
| 13 | `bin/run-local.sh:310-313` emits `sweep-self-leak-out-of-scope` metric with outcome=`self-leak` and notes containing leaked hashes. | verified | `bin/run-local.sh:310-313` (read directly) |
| 14 | `bin/run-local-helpers-adversarial-test.sh:624-673` already contains `trip_breaker` tests using STATE_FILE override. The new tests can sit alongside in the same pattern. | verified | `bin/run-local-helpers-adversarial-test.sh:624-673` (read directly) |
| 15 | `bin/run-local-sweep-test.sh` exists as a sibling test for `partition_dirty_paths`; not modified by ENG-69. | verified | `ls bin/run-local-sweep-test.sh` returned the file |
| 16 | `bin/issue_dir <issue>` returns `$PROJECT_STATE_DIR/<issue>` (e.g. `…/test-slug/ENG-63`). | verified | `bin/common.sh:68-72` (read directly) |
| 17 | `bin/run-local.sh:24-28` sources `common.sh` and `run-local-helpers.sh`; does NOT source `classify-failure.sh` today. D-1 requires adding the source line. | verified | `bin/run-local.sh:24-28` (read directly); `grep -n classify-failure bin/run-local.sh` returns no matches |
| 18 | `bin/run-stage.sh:20` is the existing `source classify-failure.sh` site; pattern is `source "$SCRIPT_DIR/classify-failure.sh"`. | verified | `bin/run-stage.sh:19-20` (read directly) |
| 19 | `bin/run-local.sh:97-103` checks `is_orchestrator_paused` BEFORE polling; pre-dispatch infrastructure failures via `require_env LINEAR_API_KEY` etc. at lines 88-91 propagate via `set -e` and never reach the rc-handler. | verified | `bin/run-local.sh:88-103` (read directly) |
| 20 | `bin/run-local.sh:251-252` writes the global counter as `printf '%s\n' "$count" > "$FAIL_COUNTER"` — pattern to reuse for per-issue counter. | verified | `bin/run-local.sh:250-252` (read directly) |
| 21 | The 2026-05-05 ENG-63 incident left `orchestrator.paused=true` for 5h+; 63 launchd ticks fired between 06:10:22Z and 11:21:00Z logging "tick skipped". | verified (from issue body) | Linear issue ENG-69 description; not separately reproduced |
| 22 | The brainstorm doc basename `2026-05-07-eng-69-...-design.md` contains the `eng-69` token required by `partition_dirty_paths::D-004` to bucket as in-scope under brainstorming. | verified | `bin/run-local-helpers.sh:140-141, 178-184` (D-004 case-insensitive issue-id basename check) |
| 23 | `bin/poll.sh` skips issues with `pipeline:halted` label + fresh halt marker (so once classify_failure halts ENG-X, the next tick polls a different issue). | verified | `bin/poll.sh:217-233` (`_poll_classify_labels` halted branch): when `pipeline:halted` label is present and `find_fresh_verdict` returns a `pipeline-halt` marker, the issue is classified as `slot=vacate` (excluded from polling). classify_failure posts exactly that marker shape (`<!-- pipeline: verdict result=halt reason=agent-blocked -->`) at `bin/classify-failure.sh:131-132`. |
| 24 | `bin/classify-failure.sh:69-77` auto-escalates retry-immediately to skip-until-code-changes after 2 same-evidence retries — different escalation than the per-issue threshold-3 added by ENG-69. The two mechanisms coexist without interference because they test different conditions (same-evidence vs N-consecutive). | verified | `bin/classify-failure.sh:67-77` (read directly) |
| 25 | `bin/run-local-helpers.sh` is sourced as a function library (no main, no top-level side effects); test files source it directly. | verified | `bin/run-local-helpers.sh:1-5` (header comment) + `bin/run-local-helpers-adversarial-test.sh:24-25` (`source "$SCRIPT_DIR/run-local-helpers.sh"`) |
| 26 | `learned-rules/harness/brainstorm.md` does not exist (no learned brainstorm rules to follow). | verified | `ls learned-rules/harness/` returns `build.md  project-profile.md` only |
| 27 | There is no `docs/VISION.md`, `docs/ARCHITECTURE.md`, or `docs/knowledge/decisions.md` in this repo. | verified | `ls docs/` returns `brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md  plans/  runbooks/` — no `knowledge/`, no `VISION.md`, no `ARCHITECTURE.md` |
| 28 | `bin/run-stage.sh` exit code 24 is emitted at `bin/run-stage.sh:875-877` (post_completion_comment failure). It's the only call site that returns 24. | verified | `bin/run-stage.sh:875-877` (read directly); `grep -n 'exit 24' bin/run-stage.sh` returns `877` only |

All 28 assumptions verified against current code/repo state.

Codebase-fact verification per the ENG-5 anti-pattern guard:
every named function (`trip_breaker`, `classify_failure`,
`partition_dirty_paths`, `failure_outcome_for_exit`,
`_pipeline_clear_breaker`, `_pipeline_drain_*`, `issue_dir`,
`set_orchestrator_paused`, `is_orchestrator_paused`), file path,
line range, exit code, and metric event name in this brainstorm
has been opened and confirmed in the current `bin/` tree.
