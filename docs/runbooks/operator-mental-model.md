# Operator mental model — what looks weird and isn't

This is a reference for harness operators encountering apparent contradictions
between what Linear shows, what the harness does, and what's on disk. Each
entry below names one **invariant** that is silently load-bearing, the **how
to spot it** command, and the **how to fix** action.

If you find yourself staring at an issue thinking "this should be progressing
but isn't" or "this should have halted and didn't," start at §1 (slot
accounting) and walk down. Most blockers are one of these.

Filed as ENG-80 after a single session uncovered 17 such assumptions, each of
which had cost real operator time at least once.

## §1 — Slot accounting

**The harness sees `stage:*` labels, not Linear state.** An issue marked Done
in the Linear UI but still carrying `stage:building` (or any non-released
stage label) **occupies a concurrency slot**. The poll respects
`orchestrator.max_concurrent_features` (default 2) by counting active
`stage:*` labels — Linear state has no effect.

Spot it:

```bash
TARGET_REPO=/path/to/target bash -c '
[[ -f ~/.config/twinning-harness/secrets.env ]] && { set -a; source ~/.config/twinning-harness/secrets.env; set +a; }
bash bin/linear.sh query "query { issues(filter: { labels: { name: { startsWith: \"stage:\" } } }, first: 30) { nodes { identifier state { name } labels { nodes { name } } } } }" "{}"
' | jq -r '.data.issues.nodes[] | select(.labels.nodes | map(.name) | contains(["stage:released"]) | not) | "\(.identifier): state=\(.state.name) labels=\(.labels.nodes | map(.name) | join(","))"'
```

Anything in that list (other than what's actively in flight) is silently
holding a slot. If `state=Done` but the labels include a non-released
`stage:*`, the slot is wedged.

Fix:

```bash
bash bin/linear.sh remove-label ENG-N stage:building   # or whichever non-released stage
bash bin/linear.sh remove-label ENG-N pipeline:halted
bash bin/linear.sh add-label    ENG-N stage:released
```

`stage:released` is terminal and excluded from the held-slot count.

**`pipeline:halted` makes the poll skip the issue forever** even when
`issue-state.json::policy = retry-immediately`. The halt comment that says
*"will retry automatically on the next tick"* is verifiably false pre-ENG-78.
ENG-78 fixes the run-stage.sh post-dispatch hook to no longer apply
`pipeline:halted` for retry-immediately classifications, but old halts on
in-flight branches may still carry the stale label.

Spot it: any issue with `pipeline:halted` plus a `stage:*` label is dormant.
Fix: `bash bin/pipeline.sh decide ENG-N --action continue` (atomic — clears
halt label, skip-until-* labels, wait files, and posts an operator-resume
waypoint).

**Slot ordering is `stage_index DESC, priority DESC`.** When two issues are
held, the later-stage one is always dispatched first. An earlier-stage issue
will starve until the front-of-queue completes a stage or hits a wait. If
ENG-A is at `stage:reviewing` and ENG-B is at `stage:implementing`, ENG-A
gets every tick until it transitions or halts.

Spot it: in the held-slot list, the issue closer to released is the one
running. The earlier-stage one is starved.

After ENG-81 (K=2 parallel dispatch), this starvation applies only when
`held_count ≥ K` — the documented WIP cap (see CLAUDE.md "Per-project
dispatch concurrency"). At K=2 (the post-ENG-81 default), two earlier-stage
helds advance per tick; starvation re-emerges only when a third issue is
also held.

Fix: there's no per-issue priority bump today. Either let the front-of-queue
finish, or temporarily mark the front-of-queue with `pipeline:halted` to
push ENG-B forward (then unhalt). Heavy-handed; usually just wait.

## §2 — State invisible in Linear

**`issue-state.json` lives on disk** at
`$PROJECT_STATE_DIR/<issue>/issue-state.json` and carries the durable
skip-label dance state — `policy`, `retry_count`, `pipeline_content_hash`,
`branch_head_sha`, `last_classification`. Operators reading Linear see none
of this.

Spot it:

```bash
cat ~/.local/state/twinning-harness/<project-slug>/ENG-N/issue-state.json | jq
```

(Default project slug for harness-self is `harness`.)

**Stage-summary files** at
`$PROJECT_STATE_DIR/<issue>/stage-summary-<stage>.md`. The orchestrator
reads them after each agent dispatch and posts content as the Linear
`completion/<stage>/<issue>` comment. If the file is stale, the Linear
comment shows old content but updatedAt advances each iter, so the comment
*looks* fresh while the body is from hours/days ago. ENG-71 burned 9 hours
on this; ENG-77 / PR #61 fixed the contract by mandating
"overwrite on every dispatch" in §5 of AGENT_PROMPTS.md. Older issues whose
agents predate that rule may still produce stale files.

Spot it:

```bash
SUMMARY=~/.local/state/twinning-harness/<slug>/ENG-N/stage-summary-reviewing.md
ls -l "$SUMMARY"           # check mtime against the latest dispatch start
head -3 "$SUMMARY"         # confirm SHA references match current HEAD
```

If mtime is older than the latest dispatch, the agent skipped the write.

Fix: `rm $SUMMARY` then `bash bin/pipeline.sh decide ENG-N --action continue`.
Next dispatch will rewrite from scratch (the agent's `Write` tool is
unconditional).

**Wait files** at `$PROJECT_STATE_DIR/<issue>/wait-*.json` carry the
build-stage `awaiting-approval` state. `decide --action continue` clears
them; manual label removal does not.

**`.consecutive-failures` counter** at
`$PROJECT_STATE_DIR/.consecutive-failures` is the global circuit-breaker
counter. At 3, `orchestrator.paused` flips to `true` in `state.local.json`
and the next tick is skipped. Per-issue counters live at
`$PROJECT_STATE_DIR/<issue>/.consecutive-failures` (post-ENG-78 / ENG-69).

Spot it:

```bash
cat ~/.local/state/twinning-harness/<slug>/.consecutive-failures 2>/dev/null
jq -r '.orchestrator.paused' .pipeline-config/state.local.json
```

Fix: `bash bin/reset-pipeline.sh` (clears both).

## §3 — Comment chronology (append-only ledger) <a id="sig-dedup"></a>

Linear comments posted by the harness are append-only — each
emission is a fresh comment with its own `createdAt`. The
`<!-- meta: dedup key=<category>/<stage>/<issue>/d<NNNN> -->`
marker tags the dispatch that emitted the comment. The pre-ENG-150
"dedup-update rewrites chronology" failure mode is gone; ENG-63's
`<!-- meta: reapplied at=… -->` footer and ENG-111's
`<!-- meta: breadcrumb sig=… -->` breadcrumb survive on legacy
comments only (back-compat readable, never written by post-cutover
code).

Spot it (operator grep recipe — works for BOTH legacy and post-
cutover comment shapes; prefix-match excludes the `-->` closing
tag so the legacy `…ENG-N -->` AND post-cutover `…ENG-N/d0007 -->`
both match):

```bash
TARGET_REPO=/path/to/target bash bin/linear.sh get-comments ENG-N \
  | jq -r '.[] | select(.body | contains("<!-- meta: dedup key=halt/implementing/ENG-N"))
               | "\(.createdAt) \(.body[0:120])"' \
  | sort | tail -1
```

Halt fire-rate recovery: pre-ENG-150 the `<!-- meta: reapplied at=… -->`
footer encoded "this halt re-fired N times". Post-cutover use:

```bash
TARGET_REPO=/path/to/target bash bin/linear.sh get-comments ENG-N \
  | jq '[.[] | select(.body | contains("<!-- meta: dedup key=halt/implementing/ENG-N"))]
        | { count: length, first: .[0].createdAt, last: .[-1].createdAt }'
```

**Find the deferred-majors enumeration for an issue (ENG-191 selective
exit):**

```bash
TARGET_REPO=/path/to/target bash bin/linear.sh get-comments ENG-N \
  | jq -r '.[] | select(.body | test("dedup key=deferred-majors/ENG-N")) | .body'
```

Each match is one dispatch's deferred-majors comment; multi-dispatch issues
accumulate one comment per `ship-with-deferred-majors` exit. The body
carries the per-row five-question rubric values + ledger row provenance, so
the operator can cross-reference against
`$(issue_dir)/review-findings-ledger.jsonl`. See `docs/runbooks/recovery.md`
§13 for the full lifecycle.

**Find auto-created follow-up tickets for an issue (ENG-193):**

```bash
TARGET_REPO=/path/to/target bash bin/linear.sh query \
  'query { searchIssues(term: "follow-up-source dispatch=ENG-N", first: 50) { nodes { id identifier title state { name } } } }' '{}' \
  | jq '.data.searchIssues.nodes'
```

Each match is a follow-up auto-filed by the orchestrator's
`_create_follow_up_tickets_for_deferred_majors` hook. Group by
`dispatch_id` substring in the title (the `[deferred from ENG-N]`
prefix) or re-fetch the description via
`bash bin/linear.sh get-issue ENG-M` to see the finding details. The
marker line in the description is
`<!-- meta: follow-up-source dispatch=ENG-N-d<NNNN> finding_class_key=<key> -->`.

**`PIPELINE_WRITER` env var lane-fences writes.** If you run
`bash bin/linear.sh add-comment` from a shell without setting
`PIPELINE_WRITER=human`, comments containing certain marker shapes
(verdict, transition, decision) are rejected with rc=14. This is by
design (prevents operator impersonation of agent verdicts) but surprises
anyone trying to manually post a state-driving marker.

Fix: `PIPELINE_WRITER=human bash bin/linear.sh add-comment ENG-N "..."` for
operator-attributed posts. For verdict-shaped markers, use
`bash bin/pipeline.sh event ENG-N <event> ...` which sets the lane
correctly.

## §4 — Branch / git invariants

**Worktree branch MUST match `bin/branch-name.sh` output exactly.**
Pre-ENG-67 the orchestrator silently accommodated `feature/eng-N-…` drift
by checking out a `feature/...` branch if one existed. Post-ENG-67 (PR #62)
it dies on mismatch. ENG-79 / PR #65 fixed the prompt-side drift; agents
on long-lived branches that started under the old contract may still have
`feature/...` and need a manual `git branch -m` rename.

Spot it:

```bash
WT=~/.local/state/twinning-harness/<slug>/ENG-N/worktree
git -C "$WT" branch --show-current
bash bin/branch-name.sh ENG-N    # canonical resolver
# If they differ, the branch is non-canonical.
```

Fix:

```bash
git -C "$WT" branch -m feat/eng-N-canonical-slug
git -C "$WT" push --force-with-lease origin HEAD
```

**`core.bare=true` flips occur mysteriously on the harness checkout.** Root
cause investigated in ENG-68 but never confirmed. PR #48's pre-commit hook
+ run-local.sh both self-heal at tick start. If `git status` in the harness
checkout returns "not a work tree," that's the symptom.

Spot it:

```bash
git -C /path/to/twinning-harness config --get core.bare
```

If `true`: self-heal will fix on next tick. To force-fix immediately:

```bash
git -C /path/to/twinning-harness config core.bare false
```

**Build agent's `gh pr merge` always carries `--repo <owner>/<repo>`.**
Without `--repo`, gh's `--delete-branch` post-merge cleanup runs `git
checkout main` to delete the source branch locally; that errors with
"fatal: 'main' is already used by worktree at ..." because the
operator's main checkout in `~/code/<project>` already holds main as
a worktree. With `--repo`, gh treats the operation as cross-repo and
skips the local cleanup; the server-side merge fires unconditionally,
and `cleanup-worktrees.sh` handles the local worktree removal on a
subsequent tick. Operators reviewing build-stage Linear comments will
see `--repo <owner>/<repo>` in the merge command — that is by design
(ENG-83), not a debug artifact. Pinned in §7 of `AGENT_PROMPTS.md`
and `bin/agent-prompts-content-test.sh`.

## §5 — Process / runtime

**5-min launchd cadence with no "fire now" trigger.** A force-push at 12:01
isn't picked up until 12:05. There's no manual trigger for the running
launchd job; manual one-shot is `bash bin/run-local.sh` (different code
path; bypasses the launchd lock).

Spot it:

```bash
launchctl list | grep twinning
tail ~/.local/state/twinning-harness/<slug>/logs/local-$(date -u +%Y-%m-%d).log
```

The last `== tick start ==` line tells you when the next tick fires (+5min).

**`gtimeout` clock pauses during macOS sleep.** A 30-min budget can stretch
to hours of wall-clock if the laptop sleeps. The process is suspended, not
killed. On wake, it resumes mid-stream — including the timer countdown.

Spot it: `ps -o pid,etime,time,state,comm -p <claude_pid>`. If `ELAPSED`
significantly exceeds `TIME` (the CPU time), the process spent most of its
time suspended.

Fix: usually no action — the dispatch resumes correctly. If wedged for >1h
without log writes, kill and let next tick redispatch.

**Pre-commit hook runs ALL 32+ tests on every commit (~40s).** A
`KNOWN_BROKEN` allowlist inside `.githooks/pre-commit` exempts pre-existing
failures, surfacing them as `SKIP`. New operators see SKIP lines and may
think their commit broke something. Bypass with `git commit --no-verify`
for legitimate cases (e.g., committing a RED test as part of TDD).

Fix any KNOWN_BROKEN entry and remove from the allowlist; do not let it rot.

**`claude -p` uses the logged-in subscription, not `ANTHROPIC_API_KEY`.** If
your subscription expires, every dispatch fails with cryptic claude exit
codes (no clear "subscription expired" message). The harness intentionally
does NOT set `ANTHROPIC_API_KEY` — agents always run on the operator's
subscription session.

Spot it: dispatches consistently failing with `dispatch_rc=20` and
near-instant exits. Check `claude /status` in a regular shell.

## §6 — Per-target setup

**`.pipeline-config/config.json::dispatch.tools.<stage>` extras must be
locally applied** per-clone. The file is gitignored, so a fresh checkout
silently has none of the per-target tool grants. For the harness-self
target specifically, qa and implement need
`Bash(bash bin/*-test.sh:*)` to run the test suite — without it, agents
halt with `agent-blocked: This command requires approval`. Caused 4
agent-blocked halts in this session alone (ENG-65, ENG-69 twice, ENG-74).

Spot it:

```bash
jq '.dispatch.tools' .pipeline-config/config.json
```

Fix:

```bash
jq '.dispatch.tools = {
  "implement": ["Bash(bash bin/*-test.sh:*)"],
  "qa":        ["Bash(bash bin/*-test.sh:*)"]
}' .pipeline-config/config.json > /tmp/c && mv /tmp/c .pipeline-config/config.json
```

**`PROJECT_SLUG` is frozen at first setup.** Derived from
`config.json::project.slug`. Changing the config later silently breaks all
paths under `$HARNESS_STATE_DIR/<old-slug>/`. State files don't migrate.

Fix: rename the state directory manually if you must change the slug:

```bash
mv ~/.local/state/twinning-harness/<old> ~/.local/state/twinning-harness/<new>
```

Then update `config.json::project.slug`. Or just don't change the slug.

## §7 — Cross-project

**Global claude counting semaphore caps system-wide concurrent dispatches.**
`~/.local/state/twinning-harness/.claude-semaphore/slot-<N>/` slot dirs
are held during each `claude -p` dispatch (one slot per in-flight
dispatch). The cap defaults to 2 (`orchestrator.max_concurrent_features`,
since ENG-81; was a binary mutex pre-ENG-81). With 2 projects each at
2 slots, you can have up to 2 concurrent `claude -p` invocations
system-wide — additional ticks contend for a slot until one frees.

Spot it: `ls ~/.local/state/twinning-harness/.claude-semaphore/slot-*/pid`
— each present `pid` file is one in-flight dispatch. Empty listing
means no live dispatches. If a slot persists without a corresponding
`claude -p` process, the slot is stale.

Fix the stale slot (each slot dir contains a `pid` file written by
`acquire_claude_mutex` — `rmdir` would fail with "Directory not empty"):

```bash
rm -rf ~/.local/state/twinning-harness/.claude-semaphore/slot-1
```

Only remove if you've confirmed no `claude -p` is actually running:

```bash
ps -ef | grep -E 'claude -p|gtimeout' | grep -v grep
```

To inspect concurrency / resource baseline operationally, prefer
`bash bin/status.sh` over the raw `ls` form — it aggregates the live
slot count and the recent `dispatch-resource-sample` baseline.

## When in doubt

The harness's source-of-truth surfaces, in order of "where to look":

1. Linear labels — `bash bin/linear.sh query ...`
2. `$PROJECT_STATE_DIR/<issue>/issue-state.json` — durable skip-label state
3. `$PROJECT_STATE_DIR/<issue>/stage-summary-<stage>.md` — agent's last word
4. `$PROJECT_STATE_DIR/<slug>/logs/local-$(date -u +%Y-%m-%d).log` — tick log
5. `$PROJECT_STATE_DIR/<slug>/logs/ENG-N-<stage>-<TS>.log` — per-stage transcript
6. `$TARGET_REPO/.pipeline-config/state.local.json` — orchestrator paused
7. `$PROJECT_STATE_DIR/<slug>/.consecutive-failures` — global breaker count

When a Linear UI observation conflicts with harness behavior, the harness
won. Read the disk surfaces above to find out why.
