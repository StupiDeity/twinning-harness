---
linear: ENG-105
date: 2026-05-15
topic: Sweep post-ENG-81 doc drift across 8 files — fix 7 live "global mutex" claims to "counting semaphore + per-host cap"; add canonical `orchestrator.max_concurrent_features` H3 to docs/configuration.md (mirroring `dispatch_timeout_minutes_per_stage`'s shape); land two failure-mode entries (`.in-flight.lock` self-heal + "Concurrent dispatches not running") and a `CLAUDE_MAX_CONCURRENT=1` rollback recipe; add `max_concurrent_features` mention to README §Configuration prose. No code, no tests, no schema bump.
---

# Plan — ENG-105 docs sweep for post-ENG-81 mutex residues

Implementation plan for the brainstorm at
`docs/brainstorms/2026-05-15-eng-105-docs-drift-after-eng-81-readme-claims-serial-mutex-configuration-md-missing-orchestrator-max-concurrent-features-design.md`.

## Goal

After implement lands on the feature branch:

1. **AC#1 (`README.md` mutex claims).** `grep -n 'global mutex' README.md` returns **0 matches**. Both pre-ENG-81 prose lines (currently at lines 30 and 416 in the pre-rebase tree; ~line 30 and ~417 post-rebase) are rewritten to describe the counting-semaphore + per-host cap, preserving the genuinely-true "cross-machine concurrency not supported" half of the §Assumptions line.
2. **AC#2 (`README.md` §Configuration mentions the knob).** `grep -n 'max_concurrent_features' README.md` returns **≥2 matches** (the existing `.claude-semaphore/` directory-tree line plus a new mention in the §Configuration prose's "Most operators only edit `config.json` for…" sentence).
3. **AC#3 (`docs/configuration.md` canonical reference).** `docs/configuration.md` gains a dedicated `### orchestrator.max_concurrent_features` H3 between the existing `### orchestrator.dispatch_timeout_minutes_per_stage` (currently line 92) and `### orchestrator.entry_conditions (ENG-86)` (currently line 118). The new H3 mirrors the per-stage-timeout H3's shape — one-sentence summary, default, resolution precedence (`CLAUDE_MAX_CONCURRENT` env > config > built-in 2), validation rules, inspection command, dual-role callout (per-tick dispatch cap AND WIP cap on `stage:*`), cross-link to `CLAUDE.md` §"Per-project dispatch concurrency". Plus: the schema example block (line 33–52) gains a `"max_concurrent_features": 2` line under `"orchestrator"`, and a new `### Constrained concurrency (single-slot)` example is added to §Examples.
4. **AC#4 (`docs/runbooks/failure-modes.md` two new entries).** Two new H2 entries — "Concurrent dispatches not running (expected K=2, observed K=1)" and "Issue stuck at one stage; `.in-flight.lock` present" — land between `## Brainstorm halts at iteration-exhausted` (ends ~393) and `## scope-check halts on upstream merge files` (starts ~397). Each entry follows the five-block template (Symptom / Diagnose / Recover / Root cause / Related) the catalog uses elsewhere.
5. **AC#5 (`docs/runbooks/recovery.md` rollback recipe).** A new H2 `## 9. Emergency: roll back concurrent dispatches to K=1` lands between `## 8. Dispatch envelope violation (ENG-87)` (ends with the `---` separator at line 548) and `## Quick reference: env var requirement` (line 550). Covers host-wide rollback (launchd plist + `launchctl bootstrap`), per-project rollback (`config.json` edit), verification (next-tick `scheduler: K=1` log), and restore.
6. **AC#6 (final grep gate).** `grep -rn 'global mutex' README.md docs/` returns **only out-of-scope historical artifacts** under `docs/brainstorms/` and `docs/plans/` — every live operator-facing claim in `README.md` + `docs/*.md` is rewritten. The deliberate historical-contrast prose at `docs/architecture.md:19` ("was a binary mutex in `.claude-mutex.lock/` pre-ENG-81") and `docs/architecture.md:351` ("Pre-ENG-81 this was a binary mutex (cap=1)") is preserved — those lines say "binary mutex" not "global mutex" so the AC#6 grep doesn't match them anyway, but they're the only remaining mutex-framed prose in the live docs and are explicitly post-marked. All nine currently-live "mutex"-flavoured operator-facing claims (`README.md:30,416` carrying `global mutex`; `docs/architecture.md:161,194,197` carrying `global Claude mutex` / `Claude mutex`; `docs/assumptions.md:135` carrying `global mutex`; `docs/security.md:20`, `docs/cost.md:31,182` carrying `global mutex`) are rewritten to canonical post-ENG-81 prose.

Verifiable: after implement lands,

```bash
grep -n 'global mutex' README.md                            # → 0 lines
grep -n 'max_concurrent_features' README.md                  # → ≥2 lines
grep -n 'max_concurrent_features' docs/configuration.md      # → ≥3 lines (schema example, H3, Examples block)
grep -n '\.in-flight\.lock' docs/runbooks/failure-modes.md   # → ≥1 line
grep -n 'CLAUDE_MAX_CONCURRENT=1\|CLAUDE_MAX_CONCURRENT' docs/runbooks/recovery.md  # → ≥1 line
grep -rn 'global mutex' README.md docs/ | grep -v '^docs/brainstorms/\|^docs/plans/\|pre-ENG-81\|was a binary mutex'  # → 0 lines
bash bin/dispatch-test.sh && bash bin/mutex-test.sh && bash bin/common-test.sh   # all PASS (no code touched; this is regression-coverage only)
```

## Anti-anchoring check

- **Problem (operator's words).** "ENG-81 shipped per-project parallel `claude -p` dispatch but two surfaces still describe the pre-ENG-81 binary-mutex world, and the canonical config reference is missing the load-bearing knob entirely. An operator reading the README or `docs/configuration.md` today will get a wrong mental model." (Linear ENG-105 Summary, verified inline.)
- **Brainstorm addresses it?** Yes. §2 Goal restates AC#1-#5 as concrete grep-verifiable outcomes; D-1 locks canonical terminology (`orchestrator.max_concurrent_features`, `CLAUDE_MAX_CONCURRENT`, "counting semaphore", drop new "mutex" prose); D-2 keeps README touches minimal (three small surgical rewrites); D-3 specs the canonical-reference H3 in `docs/configuration.md`; D-4 lays out the five-block failure-modes entries; D-5 lays out the recovery.md rollback recipe; D-6 declines a doc-content test.
- **Proportional?** Yes. Pure prose. No `bin/*` edits. No new code. No schema bump (the `config.json` example block in configuration.md gains one documented line; the orchestrator already reads `max_concurrent_features` from config since ENG-81). No test added.
- **Scope deviation (declared up front for §Goal coherence with AC#6).** The brainstorm's §8.1 surfaced a tension: the Linear ticket's "What's already correct (do not re-touch)" list cites `docs/architecture.md` and `docs/assumptions.md` as already correct, but a strict-reading AC#6 grep against the current worktree finds **nine** live mutex-framed operator-facing claims across six files. Six are literal `global mutex` matches (`README.md:30,416`, `docs/assumptions.md:135`, `docs/security.md:20`, `docs/cost.md:31,182`); three more in `docs/architecture.md` say `global Claude mutex` (line 161) and `Claude mutex` (lines 194, 197 in the ASCII dispatch-lifecycle diagram). All nine carry the same wrong-mental-model load. The plan follows the brainstorm's *recommended* path: **fix all nine sites as one-token swaps**. Justification:
  1. The ticket's "already correct" line ranges enumerate specific lines (`architecture.md:15-19, 226-227, 345-366, 408, 414` and `assumptions.md:124-126`) that ARE correct; the live-mutex sites at `architecture.md:161, 194, 197` and `assumptions.md:135` are NOT in those ranges and so are not actually excluded.
  2. The `security.md` / `cost.md` sites are genuinely silent in the ticket — the brainstorm's "decision deferred to plan stage" hands the call to me; the brainstorm's stated preference is the recommendation path.
  3. Single-token swaps (~9 lines across 4 files); no scope blast.
  4. Closing AC#6 cleanly avoids leaving the next sweep with residual drift to chase — the same shape ENG-99 used.
- **No reframe. No disproportion. Scope deviation documented above per the brainstorm's deferral. PROCEED with implementation.**

## Assumption Inventory

**Branch-base freshness.** `git fetch origin main && git log --oneline HEAD..origin/main` returns **2 commits ahead**:

```
06aa03b Merge pull request #101 from StupiDeity/fix/dispatch-trailing-gtime-cleanup-set-e-safe
9905326 fix(dispatch): trailing gtime cleanup must be set -e safe
```

Inspected `git show 9905326 -- README.md`: the merge added exactly **one line** to `README.md` at the `@@ -208,6 +208,7 @@` hunk (inside the §"Requirements" table, recommending `gtime` for the K-tuning metric). Other `README.md` content is unchanged. All four ENG-105 line targets (`README.md:30`, `README.md:332-354` (§Configuration prose), `README.md:416`) are EITHER above the addition (line 30 is unaffected) OR shift by exactly +1 after rebase (the §Configuration prose moves from 332-354 → 333-355; line 416 moves to 417). The merge added **7 lines** to `CLAUDE.md` (PATH-expectations §) but we do not modify `CLAUDE.md`. **This is a clean drift, not a dirty one.** Per the prompt's "Branch-base freshness check", **Task 0 (Rebase onto origin/main) is added** with `depends_on: []` and every subsequent task uses content anchors, not bare line numbers, so the +1 row shift in `README.md` does not break any boundary.

**branch-base freshness: `HEAD..origin/main = 2 commits` at plan time (origin/main = `06aa03b`). Task 0 (rebase) is REQUIRED.**

### Verified worktree facts (read at plan-time)

| # | Claim | Verified at |
|---|---|---|
| V-001 | `README.md:30` carries `- Team-shared CI / multi-operator setups (a global mutex serializes dispatch)`. | Read inline; matches brainstorm V-1. |
| V-002 | `README.md:416` carries `  serialized via a global mutex; cross-machine concurrency is not supported.` (the predecessor line 415 ends `Cross-tick concurrency is` per the §Assumptions list under "**Platform**"). | Read inline; matches brainstorm V-2. |
| V-003 | `README.md:346-349` lists the typical config knobs as "per-stage dispatch timeouts (if the default 30 min cap fires SIGTERM during legitimate persona-review work), the dispatch.tools allowlist (operator-curated extras on top of the profile-derived list), or entry-conditions (cost-recovery on build)." — no `max_concurrent_features`. | Read inline; matches brainstorm V-3. |
| V-004 | `README.md:367` (the §"Artifacts and locations" directory tree) ALREADY carries `.claude-semaphore/` + `max_concurrent_features` + ENG-81 — this is the existing in-tree correct mention; Task 2's AC#2 edit lives in the prose at line 346-349, NOT here. | Read inline. |
| V-005 | `docs/configuration.md:33-52` is the `config.json` schema example; the existing `orchestrator` block enumerates `paused`, `dispatch_timeout_minutes`, `dispatch_timeout_minutes_per_stage`, `entry_conditions` — no `max_concurrent_features`. | Read inline; matches brainstorm V-4. |
| V-006 | `docs/configuration.md:92` is the H3 `### orchestrator.dispatch_timeout_minutes_per_stage <a id="orchestratordispatch_timeout_minutes_per_stage"></a>`; runs through line 116. The boundary line 117 is blank; line 118 is the next H3 `### orchestrator.entry_conditions (ENG-86)`. Insertion point for Task 3's new H3 is the blank line between 116 and 118. | Read inline; matches brainstorm V-5. |
| V-007 | `docs/configuration.md` §Examples runs from line 297 `## Examples` through line 362 `}`, containing four H3 blocks: `### Minimal (defaults everywhere)`, `### Tightened timeouts (cost-bound)`, `### Build cost-recovery enabled`, `### Full harness-self profile`. Task 3 inserts a new `### Constrained concurrency (single-slot)` between `### Build cost-recovery enabled` (ends at line 336 `}`) and `### Full harness-self profile` (starts at line 338). | `grep -n "^### " docs/configuration.md` shows 299/309/324/338. |
| V-008 | `docs/runbooks/failure-modes.md:13-19` documents the five-block template `Symptom / Diagnose / Recover / Root cause / Related`. Every existing H2 entry conforms. | Read inline; matches brainstorm V-7. |
| V-009 | `docs/runbooks/failure-modes.md:348` is `## Brainstorm halts at iteration-exhausted`; the section's `### Related` block ends at line 393; the `---` separator is at line 395; the next H2 `## scope-check halts on upstream merge files` is at line 397. Insertion point for Task 4 is between line 395's `---` and line 397's H2. | `grep -n "^## \|^### " docs/runbooks/failure-modes.md` shows 391/393 boundary cleanly. |
| V-010 | `docs/runbooks/failure-modes.md` has **zero** existing mentions of `.in-flight.lock`, `CLAUDE_MAX_CONCURRENT`, `max_concurrent_features`, or `scheduler: K=`. | `grep -nE 'in-flight\.lock\|CLAUDE_MAX_CONCURRENT\|max_concurrent_features\|scheduler: K=' docs/runbooks/failure-modes.md` returns 0 matches. |
| V-011 | `docs/runbooks/recovery.md` has 11 existing H2 sections (per `grep -n "^## "`): "1. Issue with multiple `stage:*` labels" through "8. Dispatch envelope violation (ENG-87)" plus "Quick reference: env var requirement" (line 550) and "ENG-68 follow-up: `core.bare` recurrence after fix" (line 575). The brainstorm-named "ENG-87 forensic asymmetry" is an H3 *inside* §8 at line 522, not its own H2. Insertion point for Task 5's new H2 `## 9. …` lands between `---` at line 548 and `## Quick reference: env var requirement` at line 550. | `grep -n "^## " docs/runbooks/recovery.md` confirms; matches brainstorm V-8 (which mis-named the §8 H3 as a section). |
| V-012 | `docs/runbooks/recovery.md` has **zero** existing mentions of `CLAUDE_MAX_CONCURRENT` or `max_concurrent_features`. | `grep -nE 'CLAUDE_MAX_CONCURRENT\|max_concurrent_features' docs/runbooks/recovery.md` returns 0 matches. |
| V-013 | `CLAUDE.md:623-671` contains the post-ENG-81 §"Per-project dispatch concurrency" with default-2, resolution precedence (env > config > built-in), inspection command (`ls $HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid`), emergency-rollback note (`CLAUDE_MAX_CONCURRENT=1` + `launchctl bootstrap`). This is the source CLAUDE.md text the new H3 / runbook entries link to. | Read inline. |
| V-014 | `CLAUDE.md:620-621` are the two failure-mode quick-reference rows that Task 4's two new entries mirror in catalog form. Row 620 covers "Concurrent dispatches not running (expected K=2, observed K=1)"; row 621 covers "Issue stuck at one stage; `$(issue_dir <issue>)/.in-flight.lock` present". | Read inline. |
| V-015 | `bin/common.sh:575-598` declares `_resolve_K`, the K-resolution helper. Precedence (mirrors V-013): env `CLAUDE_MAX_CONCURRENT` (validated `^[0-9]+$` AND `>=1`, else `log "_resolve_K: invalid CLAUDE_MAX_CONCURRENT=…"`) > config `orchestrator.max_concurrent_features` (same validation, log line `_resolve_K: invalid orchestrator.max_concurrent_features=…`) > built-in `2`. The log line text is what Task 4 Entry A's Diagnose block greps for. | Read inline. |
| V-016 | `bin/run-local.sh:325` calls `K="$(_resolve_K)"` and the scheduler emits `scheduler: K=$K` to the per-tick log (the literal log line the brainstorm cites for Diagnose). | `grep -n '_resolve_K\|scheduler: K=' bin/run-local.sh` — line 325 + adjacent log lines. |
| V-017 | `bin/common.sh:405-452` defines `try_acquire_lock`. On dir-present, reads `$dir/pid`; if recorded pid is non-empty AND `kill -0` fails, reclaims via `rm -rf` + re-mkdir + post-mkdir pid-readback check; if recovery race lost, logs `try_acquire_lock: post-mkdir pid-readback mismatch …` and returns rc=1. Stale-recovery is automatic. | Read inline. |
| V-018 | The in-flight-lock failure surface is `$(issue_dir <issue>)/.in-flight.lock` (per CLAUDE.md:621); `bin/run-local.sh:419-422` is the call site that emits `scheduler: $issue_id .in-flight.lock held by prior tick worker; skipping this decision` on contention. | `grep -n 'in-flight\.lock' bin/run-local.sh` line 419-422. |
| V-019 | `docs/architecture.md:161` carries `The only shared thing is the global Claude mutex.` — live claim, NOT in the ticket's "already correct" line ranges (15-19, 226-227, 345-366, 408, 414). | Read inline. |
| V-020 | `docs/architecture.md:194` and `:197` carry `acquire global Claude mutex` and `release Claude mutex` inside the dispatch-lifecycle code-fenced diagram (`bin/dispatch.sh` block). Also outside the "already correct" ranges. | Read inline. |
| V-021 | `docs/assumptions.md:135` carries `- Cross-project ticks DO serialize correctly (the global mutex covers / every project's dispatch).` — line 135 + 136 with paragraph wrap; NOT in the "already correct" range 124-126 (which IS the post-ENG-81 counting-semaphore correct prose at 123-128). | Read inline. |
| V-022 | `docs/security.md:20` carries `- Trigger arbitrary \`claude -p\` dispatches (subject to the global mutex).` — uncategorized in the ticket; brainstorm flagged it. | Read inline. |
| V-023 | `docs/cost.md:31` carries `this** — the global mutex + 5-minute tick is calibrated against` (continuation of the line-29-30 sentence about subscription rate limits). Uncategorized in the ticket; brainstorm flagged it. | Read inline. |
| V-024 | `docs/cost.md:182` carries `global mutex, so throughput is bounded regardless of project count.` (continuation of line 181 `Multi-project setups serialize through the`). Uncategorized in the ticket; brainstorm flagged it. | Read inline. |
| V-025 | `docs/architecture.md:19` carries `(default 2 since ENG-81; was a binary mutex in \`.claude-mutex.lock/\` pre-ENG-81).` and `:351` carries `\`.claude-mutex.lock/\` (cap=1).` — both are deliberate historical-contrast prose that AC#6 preserves. | Read inline. |
| V-026 | The `[claude-mutex]` log-line text (e.g. `[claude-mutex] waiting for lock held by …`) is preserved verbatim in `bin/dispatch.sh` after ENG-81 (A-033 invariant from ENG-81 plan); `bin/mutex-test.sh:54-60` and `bin/common-test.sh:903` grep this exact text. **This plan does NOT touch `bin/`** — production code stays unchanged; only doc prose is rewritten. The log-line text in question is referenced only by tests, never by README/docs prose. No test-gate closure defect. | `grep -ln "claude-mutex" bin/*-test.sh` → `bin/common-test.sh`, `bin/mutex-test.sh`; both grep production log-line text, not docs. |

### Non-existence assertions (preserved from brainstorm)

| # | Claim | How to validate |
|---|---|---|
| N-001 | `docs/knowledge/` (no `decisions.md`, `gotchas.md`, `conventions.md`) does not exist; `docs/VISION.md` does not exist; `learned-rules/harness/plan.md` does not exist. | `ls docs/` lists `architecture.md assumptions.md brainstorms/ configuration.md cost.md demos/ install.md operations.md pipeline-vocabulary.md pipeline-vocabulary.template.md plans/ runbooks/ security.md` — no `knowledge/`, no `VISION.md`. `ls learned-rules/harness/` lists `build.md project-profile.md` — no `plan.md`. The prompt's preamble steps 2/4/5/6/7 are no-ops at plan time. |
| N-002 | The harness has no doc-content test (`bin/docs-*-test.sh` does not exist; no `bin/*-test.sh` greps README.md or docs/* for `global mutex`, `max_concurrent_features`, `.in-flight.lock`, or `CLAUDE_MAX_CONCURRENT`). | `ls bin/docs-*-test.sh 2>&1` → no matches. `grep -ln 'docs/configuration\|docs/runbooks\|README.md' bin/*-test.sh` returns files that REFERENCE those paths only in comments (e.g. `bin/agent-prompts-content-test.sh:789` is a `# docs/runbooks/operator-mental-model.md §4` comment, not an assertion). |

### Plan-stage-derived (load-bearing during implementation, not yet verified)

| # | Claim | How to validate at implement time |
|---|---|---|
| P-001 | Post-rebase, the line shift `README.md` `(>211)` is exactly `+1`. The cited line 30 stays line 30; line 346 → 347; line 416 → 417; line 367 → 368. The implement agent MUST re-grep for the literal token text after `git rebase origin/main` rather than trust pre-rebase line numbers. | Run `grep -n 'global mutex\|Most operators only edit\|Cross-tick concurrency is' README.md` after Task 0 rebase; confirm the three matches. |
| P-002 | The implement-stage `Edit` operations against `Read` tool's view of each file are idempotent and produce no unrelated-line drift. | Standard implement-stage TDD evidence in stage-summary; `bash bin/dispatch-test.sh && bash bin/mutex-test.sh && bash bin/common-test.sh` continues to pass (regression coverage; no production code touched, so no test should fail). |
| P-003 | The five-block template (Symptom / Diagnose / Recover / Root cause / Related) renders cleanly in the existing failure-modes.md TOC ordering. | Visual diff of `docs/runbooks/failure-modes.md` after Task 4 — two new H2 entries appear between `## Brainstorm halts at iteration-exhausted` and `## scope-check halts on upstream merge files`; each entry has all five H3s. |
| P-004 | The post-rebase line numbers for `docs/configuration.md`, `docs/runbooks/failure-modes.md`, `docs/runbooks/recovery.md`, `docs/architecture.md`, `docs/assumptions.md`, `docs/security.md`, `docs/cost.md` do NOT shift — the rebase's only README/CLAUDE additions are above each of those files' targets. The implement agent uses content anchors for all of them, so even unanticipated drift fails open (Grep finds the literal anchor text). | After Task 0, `git log --oneline HEAD~..HEAD -- docs/configuration.md docs/runbooks/ docs/architecture.md docs/assumptions.md docs/security.md docs/cost.md` returns empty. |

## File Structure

All eight files are **modified**; no new files; no `bin/*` touched; no schema bump.

- `README.md` — modified. **3 edit hunks across 3 content anchors.**
  1. Line ~30 (single-line rewrite in §"Not for"): replace "(a global mutex serializes dispatch)" with the counting-semaphore + per-host cap framing.
  2. Lines ~346-349 (single-sentence append in §Configuration prose): append `max_concurrent_features` to the enumerated list of typical knobs.
  3. Lines ~415-416 (single-line rewrite in §Assumptions "Platform"): replace "serialized via a global mutex" with the counting-semaphore prose, preserve "cross-machine concurrency is not supported".
- `docs/configuration.md` — modified. **3 edit hunks across 3 content anchors.**
  1. Lines 33-52 (schema example block under §"`config.json` schema"): add `"max_concurrent_features": 2,` to the `orchestrator` object.
  2. Insert new H3 `### orchestrator.max_concurrent_features (ENG-81)` between the closing `}` of existing H3 `### orchestrator.dispatch_timeout_minutes_per_stage` (line 116) and existing H3 `### orchestrator.entry_conditions (ENG-86)` (line 118). New H3 contains 7 prose blocks per D-3 + a cross-link to `CLAUDE.md`.
  3. Insert new H3 `### Constrained concurrency (single-slot)` between existing H3 `### Build cost-recovery enabled` (ends line 336 `}`) and existing H3 `### Full harness-self profile` (line 338).
- `docs/runbooks/failure-modes.md` — modified. **1 edit hunk** (one insertion block holding two new H2 entries).
  - Between `---` at line 395 and `## scope-check halts on upstream merge files` at line 397, insert two new H2 entries: `## Concurrent dispatches not running (expected K=2, observed K=1)` and `## Issue stuck at one stage; `.in-flight.lock` present`, each with the five-block template, terminated by `---`.
- `docs/runbooks/recovery.md` — modified. **1 edit hunk** (one new H2 between existing sections).
  - Between `---` at line 548 and `## Quick reference: env var requirement` at line 550, insert new H2 `## 9. Emergency: roll back concurrent dispatches to K=1` with body per D-5 + terminating `---`.
- `docs/architecture.md` — modified. **3 edit hunks across 3 content anchors.**
  - Line 161 single-line rewrite (live claim → canonical prose).
  - Line 194 single-line rewrite (dispatch-lifecycle ASCII diagram label).
  - Line 197 single-line rewrite (matching release label).
- `docs/assumptions.md` — modified. **1 edit hunk** (one-line rewrite at line 135).
- `docs/security.md` — modified. **1 edit hunk** (one-line rewrite at line 20).
- `docs/cost.md` — modified. **2 edit hunks** (one-line rewrites at lines 31 and 182).

No new files. No bin/* changes. No `learned-rules/` changes. No `AGENT_PROMPTS.md` change. No schema migration.

## API Contract

no new API surface

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (rebase only; no file edit)`
- [ ] Run `git fetch origin main && git rebase origin/main`. Resolve no conflicts expected (the rebased commits touched `README.md:208-212` adding one row to the §"Requirements" table; this branch has only the brainstorm doc on `docs/brainstorms/`, so there is no overlap).
- [ ] Post-rebase, re-verify Assumption Inventory `path:line` citations survive. Run these three greps and confirm exactly one match each:
  ```bash
  grep -cn 'global mutex serializes dispatch' README.md      # → 1 (line ~30, unaffected)
  grep -cn 'serialized via a global mutex' README.md         # → 1 (line ~417, shifted +1)
  grep -cn 'Most operators only edit' README.md              # → 1 (line ~347, shifted +1)
  ```
- [ ] If any of the three greps returns a count other than 1, **halt with a Linear comment** describing the mismatch and request `pipeline:supersede` — an upstream sibling change has materially shifted the targets.
- **Why this task is first:** `HEAD..origin/main` is 2 commits ahead at plan time (verified). Subsequent tasks use **content anchors**, but the implement agent should still rebase first so the post-implement diff is a clean fast-forward when the PR opens. Every subsequent task's content anchors are unique enough to survive the +1 shift, so if rebase fails the recovery path is still anchored.

### Task 1: Rewrite README.md "global mutex" live claims + append `max_concurrent_features` to §Configuration prose

- `depends_on: [0]`
- `touches: README.md` (3 edit hunks; content anchors below)
- [ ] **Hunk 1 (§"Not for" line, single-line rewrite, ~line 30 post-rebase).** Inside the §"Is this for you" H2, under the bold `**Not for:**` list, locate the bullet whose body contains `(a global mutex serializes dispatch)`. Replace the whole bullet line.
  - Content anchor: AFTER the bold `**Not for:**` line BEFORE the bullet line `- Non-Linear / non-GitHub workflows`.
  - FROM: `- Team-shared CI / multi-operator setups (a global mutex serializes dispatch)`
  - TO: `- Team-shared CI / multi-operator setups (state dirs are single-host; concurrent dispatches share a per-host cap)`

- [ ] **Hunk 2 (§Configuration prose, single-sentence append, ~lines 346-349 post-rebase).** Inside the §Configuration H2, locate the paragraph starting `Most operators only edit \`config.json\` for:` (currently three knobs listed). Append `, or \`orchestrator.max_concurrent_features\` (the per-tick concurrent-dispatch cap; default 2; see [\`docs/configuration.md\`](docs/configuration.md#orchestratormax_concurrent_features))` before the trailing `.` of the sentence (the sentence currently ends `entry-conditions (cost-recovery on build).`).
  - Content anchor: AFTER the `## Configuration` H2 AFTER the literal substring `Most operators only edit` BEFORE the next H2 `## Artifacts and locations`.
  - FROM: `entry-conditions (cost-recovery on build).`
  - TO: `entry-conditions (cost-recovery on build), or \`orchestrator.max_concurrent_features\` (the per-tick concurrent-dispatch cap; default 2; see [\`docs/configuration.md\`](docs/configuration.md#orchestratormax_concurrent_features)).`

- [ ] **Hunk 3 (§Assumptions "Platform" line, single-line rewrite, ~line 416 → 417 post-rebase).** Inside the §Assumptions H2, locate the `**Platform**:` bullet. The bullet currently runs across two lines (415-416 pre-rebase): `**Platform**: macOS, \`launchd\`, single operator. Cross-tick concurrency is / serialized via a global mutex; cross-machine concurrency is not supported.` Replace the second-half text after `single operator.` through the period at the end.
  - Content anchor: AFTER the bullet beginning `- **Doc ownership**:` AFTER the literal substring `**Platform**: macOS, \`launchd\`, single operator.` BEFORE the next bullet beginning `- **Auth**:`.
  - FROM (across two source lines): `Cross-tick concurrency is\n  serialized via a global mutex; cross-machine concurrency is not supported.`
  - TO (single content sentence, prose-wrapped however the source wraps): `Concurrent \`claude -p\` dispatches are capped per-host by a counting semaphore at \`$HARNESS_STATE_DIR/.claude-semaphore/\` (default cap 2 via \`orchestrator.max_concurrent_features\` since ENG-81); cross-machine concurrency is not supported.`

- [ ] **Post-task verification.** Run:
  ```bash
  grep -cn 'global mutex' README.md                          # → 0
  grep -cn 'max_concurrent_features' README.md               # → ≥2 (Hunk 2 + the existing line ~367/368 .claude-semaphore tree line)
  grep -cn 'counting semaphore' README.md                    # → ≥1 (new Hunk 3 prose)
  grep -cn '\.claude-semaphore' README.md                    # → ≥1 (existing line ~367/368; unchanged)
  ```

### Task 2: Add `### orchestrator.max_concurrent_features` H3 + Examples block + schema-example line to docs/configuration.md

- `depends_on: [0]`
- `touches: docs/configuration.md` (3 edit hunks; content anchors below)
- [ ] **Hunk 1 (schema example block, single-line insert, line 33-52 area).** Inside the fenced `json` block under `## \`config.json\` schema` (the block opens with `\`\`\`json` and the inner `"orchestrator"` object spans the lines starting with `"paused": false,`), add a new line `"max_concurrent_features": 2,` immediately AFTER the `"paused": false,` line and BEFORE the `"dispatch_timeout_minutes": 30,` line.
  - Content anchor: AFTER the fenced-block opener `\`\`\`json` AFTER the literal `"orchestrator": {` line AFTER the literal `"paused": false,` line BEFORE the literal `"dispatch_timeout_minutes": 30,` line.
  - Insertion: `    "max_concurrent_features": 2,`
  - **The two-space-then-four-space indentation matches the existing `"paused"` / `"dispatch_timeout_minutes"` lines (verify by Read).**

- [ ] **Hunk 2 (new H3 between `dispatch_timeout_minutes_per_stage` and `entry_conditions`, ~lines 116-118).** Insert a new H3 block. Use **literal** anchor matching to find the boundary.
  - Content anchor: AFTER the closing prose line `After applying an override, grep \`gtimeout ... <seconds>\` in the per-stage` ... `transcript at \`$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log\` to confirm` ... `it took effect.` (the closing paragraph of `### orchestrator.dispatch_timeout_minutes_per_stage`, ending at line 116) BEFORE the next H3 line `### \`orchestrator.entry_conditions\` (ENG-86)` (line 118). Insert a blank line then the new H3 block then a blank line.
  - Insert the following block verbatim (anchor `<a id="orchestratormax_concurrent_features"></a>` so the link from `README.md` Task 1 Hunk 2 resolves):

    ```markdown
    ### `orchestrator.max_concurrent_features` (ENG-81) <a id="orchestratormax_concurrent_features"></a>

    Per-project cap on **simultaneous `claude -p` dispatches per tick**.
    Also the WIP cap on issues in any `stage:*` label (pre-ENG-81 was the
    only role; ENG-81 added the per-tick dispatch role on top).

    **Default:** `2`.

    **Resolution precedence** (mirrors `dispatch_timeout_minutes_per_stage`):

    1. `CLAUDE_MAX_CONCURRENT` env var (set in
       `~/Library/LaunchAgents/com.twinning.pipeline.<slug>.plist`'s
       `EnvironmentVariables` block + `launchctl bootstrap`) — highest.
    2. `.orchestrator.max_concurrent_features` in target's
       `.pipeline-config/config.json`.
    3. Built-in default `2`.

    **Validation rules:**
    - Values must be **integers**. `"2"`, `"K=2"`, `"2 "` all fail the
      `^[0-9]+$` regex guard at `bin/common.sh::_resolve_K` and fall
      through to the next layer.
    - A resolved value `< 1` falls through (cap=0 would disable every
      dispatch).
    - Invalid values log a `_resolve_K: invalid …` warning to stderr,
      visible in `$PROJECT_STATE_DIR/<slug>/logs/local-$(date -u +%Y-%m-%d).log`.

    **Inspect live concurrency:**

    ```bash
    ls $HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid
    bash bin/status.sh   # "Concurrent dispatches active" row
    ```

    Each slot dir carries the owning `dispatch.sh` PID; an empty listing
    means no live dispatches.

    **Emergency rollback** — see
    [`docs/runbooks/recovery.md`](runbooks/recovery.md#9-emergency-roll-back-concurrent-dispatches-to-k1)
    for the host-wide / per-project K=1 recipe.

    **Dual role.** The SAME knob is also the WIP cap on `stage:*`-labelled
    issues (the pre-ENG-81 meaning, still in force). A target with
    `max_concurrent_features=2` allows up to 2 issues simultaneously in
    any active-development stage AND up to 2 simultaneous `claude -p`
    dispatches per tick. Setting it to 1 reverts to the pre-ENG-81
    behaviour for both.

    For the full mechanism (counting-semaphore mkdir loop, slot reclaim,
    cross-project semantics), see `CLAUDE.md` §"Per-project dispatch
    concurrency".
    ```

- [ ] **Hunk 3 (new Examples block, between `### Build cost-recovery enabled` and `### Full harness-self profile`, ~lines 336-338).** Inside `## Examples` (line 297), insert a new H3 between the closing `}` of `### Build cost-recovery enabled` (the closing `\`\`\`` fence at line 336) and the next `### Full harness-self profile` H3 (line 338).
  - Content anchor: AFTER the closing fence `\`\`\`` that terminates `### Build cost-recovery enabled` BEFORE the H3 line `### Full harness-self profile`.
  - Insert (with a blank line before and after):

    ```markdown
    ### Constrained concurrency (single-slot)

    Roll the per-project concurrent-dispatch cap back to 1 (the
    pre-ENG-81 behaviour) for incident response, cost-bounding, or a
    suspected race bug in an ENG-81-adjacent change. For host-wide
    emergency rollback (affects every project on this Mac immediately),
    use `CLAUDE_MAX_CONCURRENT=1` per
    [`runbooks/recovery.md` §9](runbooks/recovery.md#9-emergency-roll-back-concurrent-dispatches-to-k1).

    ```json
    {
      "orchestrator": {
        "max_concurrent_features": 1
      }
    }
    ```
    ```

- [ ] **Post-task verification.** Run:
  ```bash
  grep -cn 'max_concurrent_features' docs/configuration.md       # → ≥3 (schema example + new H3 anchor + Examples block)
  grep -cn '<a id="orchestratormax_concurrent_features"></a>' docs/configuration.md  # → 1 (anchor for README link)
  grep -c '^### ' docs/configuration.md                          # was 14 H3s; +1 for new `### orchestrator.max_concurrent_features (ENG-81)` + 1 for new `### Constrained concurrency (single-slot)` = 16.
  ```

### Task 3: Add two failure-mode entries to docs/runbooks/failure-modes.md

- `depends_on: [0]`
- `touches: docs/runbooks/failure-modes.md` (1 edit hunk holding two new H2 entries)
- [ ] **Hunk 1 (insert two new H2 entries between Brainstorm-halts and scope-check-halts entries, ~lines 395-397).**
  - Content anchor: AFTER the `### Related` of `## Brainstorm halts at iteration-exhausted` (its closing line is `ENG-65 (per-stage timeouts + iteration cap).`) AFTER the `---` separator at line 395 BEFORE the H2 line `## scope-check halts on upstream merge files` (line 397).
  - Insert the following block verbatim (preserves the five-block template; closes each entry with its own `---`):

    ```markdown
    ## Concurrent dispatches not running (expected K=2, observed K=1)

    ### Symptom

    `bash bin/status.sh` shows fewer concurrent dispatches than the cap
    you configured — e.g. only 1 `slot-*/pid` directory under
    `$HARNESS_STATE_DIR/.claude-semaphore/` despite
    `orchestrator.max_concurrent_features=2`. Per-tick dispatch volume
    is half what you'd expect.

    ### Diagnose

    ```bash
    # 1. What did _resolve_K resolve to on the most recent tick?
    grep 'scheduler: K=' \
      "$PROJECT_STATE_DIR/$(jq -r .project.slug "$TARGET_REPO/.pipeline-config/config.json")/logs/local-$(date -u +%Y-%m-%d).log" \
      | tail -3

    # 2. Is CLAUDE_MAX_CONCURRENT set in the launchd plist? (env wins over config)
    launchctl print "gui/$(id -u)/com.twinning.pipeline.<slug>" \
      | grep -i CLAUDE_MAX_CONCURRENT

    # 3. What does config say?
    jq '.orchestrator.max_concurrent_features' \
      "$TARGET_REPO/.pipeline-config/config.json"

    # 4. Are there live slots right now?
    ls "$HARNESS_STATE_DIR/.claude-semaphore/"slot-*/pid 2>/dev/null
    ```

    Cross-check `bin/common.sh::_resolve_K`'s precedence (env >
    config > built-in 2) against what you read above; a
    `_resolve_K: invalid …` line in the same log file flags any
    non-integer or `<1` value that fell through.

    ### Recover

    By cause:

    - **`CLAUDE_MAX_CONCURRENT` unintentionally `1`** → edit the launchd
      plist's `EnvironmentVariables` block (or `launchctl unsetenv`),
      then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.twinning.pipeline.<slug>.plist`.
    - **Config explicitly `1`** → `jq '.orchestrator.max_concurrent_features = 2' "$TARGET_REPO/.pipeline-config/config.json" > /tmp/c && mv /tmp/c "$TARGET_REPO/.pipeline-config/config.json"`.
    - **Non-integer / `<1` resolved value silently fell through** → fix
      the offending value at whichever tier emitted the
      `_resolve_K: invalid …` warning (env or config).
    - **Eligible-issue pool smaller than the cap** → not a bug. The
      scheduler only dispatches issues whose `slot:hold, advanceable:true`
      classification fires; when fewer issues are advanceable than the
      cap allows, observed concurrency is the smaller of the two.

    ### Root cause

    `bin/common.sh::_resolve_K` resolves the cap with env > config >
    built-in precedence and is fail-soft on invalid values (logs a
    warning and falls through). Operators upgrading from pre-ENG-81 may
    leave a stale `CLAUDE_MAX_CONCURRENT=1` in the plist from a prior
    rollback; non-integer values get silently dropped.

    ### Related

    ENG-81 (per-project parallel dispatch + counting semaphore),
    ENG-90 (slot-occupancy contract). See `CLAUDE.md` §"Per-project
    dispatch concurrency" for the full resolution-precedence model.

    ---

    ## Issue stuck at one stage; `.in-flight.lock` present

    ### Symptom

    An issue with a `stage:*` label hasn't advanced for one or more
    ticks. `bin/status.sh` shows it as held but no dispatch fires. A
    directory `$(bash bin/pipeline.sh issue-dir ENG-N)/.in-flight.lock/`
    exists with `pid` and `timestamp` files inside.

    ### Diagnose

    ```bash
    issue_dir="$(bash bin/pipeline.sh issue-dir ENG-N)"

    # 1. Confirm the lock dir is present
    ls "$issue_dir/.in-flight.lock"

    # 2. Inspect the holder pid + timestamp
    cat "$issue_dir/.in-flight.lock/pid"          # pid that claimed it
    cat "$issue_dir/.in-flight.lock/timestamp"    # ISO-8601 UTC

    # 3. Is the holder pid actually alive?
    holder=$(cat "$issue_dir/.in-flight.lock/pid")
    if kill -0 "$holder" 2>/dev/null; then echo "alive"; else echo "DEAD"; fi
    ```

    ### Recover

    **Common case (holder pid is dead).** No operator action is
    required. `bin/common.sh::try_acquire_lock` self-heals on the next
    acquire attempt: it reads `$dir/pid`, sees `kill -0 $pid` fails,
    and reclaims via `rm -rf $dir` + re-mkdir + post-mkdir
    pid-readback. The next tick (≤ 5 min) picks the issue up
    automatically. Inspect the local log on the next tick for a
    `try_acquire_lock: reclaiming stale lock at …` line — confirms
    the self-heal fired.

    **Rare case (holder pid IS alive but issue still appears stuck).**
    Implies the holder is hung rather than orphaned. Inspect:

    ```bash
    ps -fp "$holder"   # what is the holder doing?
    cat "$issue_dir/.in-flight.lock/timestamp"   # how long has it held?
    ```

    If the holder is a runaway `dispatch.sh` or `gtimeout claude -p`
    that has exceeded its per-stage cap, `kill $holder` first; the
    next tick reclaims via `try_acquire_lock`.

    **Override of last resort.** Only if both the holder is dead AND
    something has broken `try_acquire_lock`'s self-heal (rare;
    typically an interrupted pid-readback that left the dir in a weird
    state):

    ```bash
    rm -rf "$issue_dir/.in-flight.lock"
    ```

    ### Root cause

    Pre-ENG-81's scheduler/worker split could leak an orphan
    `.in-flight.lock/` if the worker was SIGKILLed / oomkilled /
    host-rebooted between `mkdir` and `release_lock`. ENG-81 added
    self-healing recovery to `try_acquire_lock`: every acquire attempt
    that finds the dir present reads the recorded holder pid and
    reclaims if `kill -0 $pid` fails. The pid-readback after re-mkdir
    handles concurrent reclaim races.

    ### Related

    ENG-81 (per-issue lock contract + self-heal recovery),
    `bin/common.sh::try_acquire_lock` (the helper). See `CLAUDE.md`
    §"Failure-mode quick reference" row "Issue stuck at one stage;
    `.in-flight.lock` present".

    ---
    ```

- [ ] **Post-task verification.** Run:
  ```bash
  grep -cn '^## Concurrent dispatches not running' docs/runbooks/failure-modes.md    # → 1
  grep -cn '^## Issue stuck at one stage; .in-flight.lock' docs/runbooks/failure-modes.md  # → 1
  grep -cn 'try_acquire_lock\|scheduler: K=' docs/runbooks/failure-modes.md           # → ≥2 (one per entry's Diagnose / Recover)
  grep -c '^## ' docs/runbooks/failure-modes.md            # was 11 H2s + 2 new = 13 (How to read, Tick is silent, Per-issue halt, Global breaker, Issue stuck in stage:X, Wrong-target Linear writes, Build idles, Brainstorm halts, Concurrent dispatches NEW, In-flight lock NEW, scope-check halts, Common-cause table, When to escalate)
  ```

### Task 4: Add `## 9. Emergency: roll back concurrent dispatches to K=1` to docs/runbooks/recovery.md

- `depends_on: [0]`
- `touches: docs/runbooks/recovery.md` (1 edit hunk)
- [ ] **Hunk 1 (insert new H2 between §8 Dispatch envelope violation and Quick reference, ~lines 548-550).**
  - Content anchor: AFTER the H3 line `### Forensic asymmetry post-resume` (line 522) AFTER its closing paragraph `start/end rows for the d0007 dispatch survive the / \`--action continue\`.` AFTER the `---` separator at line 548 BEFORE the H2 line `## Quick reference: env var requirement` (line 550).
  - Insert the following block verbatim (closes with `---` so the next H2 stays separated):

    ```markdown
    ## 9. Emergency: roll back concurrent dispatches to K=1

    Roll the per-host (or per-project) `claude -p` concurrency cap back
    to 1 — the pre-ENG-81 binary-mutex behaviour. Use this when:

    - **Linear API rate-limit symptoms** — sudden cascade of `linear-post-failed`
      halts across multiple projects.
    - **Unexpected `claude` subscription quota burns** — 5-hour rolling
      window saturated faster than budgeted.
    - **Suspected race or bug in an ENG-81-adjacent change** — slot
      collision, lock-recovery loop, or new `_resolve_K` regression.

    No deploy is required for either path.

    ### Host-wide rollback (preferred under acute incident)

    Affects every project on this Mac immediately on next tick (each
    project's plist injects the same env var):

    ```bash
    # 1. Edit the plist for each project to add CLAUDE_MAX_CONCURRENT
    plist="$HOME/Library/LaunchAgents/com.twinning.pipeline.<slug>.plist"

    # Inside <key>EnvironmentVariables</key>'s <dict>, add:
    #   <key>CLAUDE_MAX_CONCURRENT</key>
    #   <string>1</string>

    # 2. Reload the launchd job
    launchctl bootstrap "gui/$(id -u)" "$plist"
    ```

    Repeat per slug if you run multiple projects.

    ### Per-project rollback (when one project's bug should not affect others)

    ```bash
    jq '.orchestrator.max_concurrent_features = 1' \
      "$TARGET_REPO/.pipeline-config/config.json" \
      > /tmp/c && mv /tmp/c "$TARGET_REPO/.pipeline-config/config.json"
    ```

    The next tick (≤ 5 min) picks this up automatically.

    ### Verify

    On the next tick, the local log MUST show `scheduler: K=1`:

    ```bash
    grep 'scheduler: K=' \
      "$PROJECT_STATE_DIR/logs/local-$(date -u +%Y-%m-%d).log" \
      | tail -1
    ```

    Only one `slot-*/pid` directory should exist under
    `$HARNESS_STATE_DIR/.claude-semaphore/` at any moment:

    ```bash
    ls "$HARNESS_STATE_DIR/.claude-semaphore/"slot-*/pid 2>/dev/null | wc -l
    # → 0 or 1
    ```

    ### Restore (post-incident)

    Host-wide: remove the `CLAUDE_MAX_CONCURRENT` entry from each plist
    `EnvironmentVariables` block + `launchctl bootstrap` again.
    Per-project: `jq '.orchestrator.max_concurrent_features = 2' …`
    (or delete the key for the built-in default 2).

    ### Why this is the right primitive

    `bin/common.sh::_resolve_K`'s precedence is `CLAUDE_MAX_CONCURRENT`
    env > `orchestrator.max_concurrent_features` config > built-in 2.
    Setting the env var to 1 wins over every project's config; setting
    one project's config to 1 only affects that project. Both paths
    avoid touching the underlying counting semaphore at
    `$HARNESS_STATE_DIR/.claude-semaphore/`, which continues to work
    correctly at any cap including 1.

    See `CLAUDE.md` §"Per-project dispatch concurrency" for the full
    resolution-precedence model + slot-occupancy interaction; see
    [`configuration.md` §`orchestrator.max_concurrent_features`](../configuration.md#orchestratormax_concurrent_features)
    for the canonical config reference.

    ---
    ```

- [ ] **Post-task verification.** Run:
  ```bash
  grep -cn '^## 9. Emergency: roll back concurrent dispatches to K=1' docs/runbooks/recovery.md  # → 1
  grep -cn 'CLAUDE_MAX_CONCURRENT' docs/runbooks/recovery.md                                    # → ≥3 (host-wide + restore + Why)
  grep -cn 'launchctl bootstrap' docs/runbooks/recovery.md                                      # → ≥2 (existing references + new ones)
  grep -c '^## ' docs/runbooks/recovery.md                                                      # was 11 H2s; +1 = 12
  ```

### Task 5: Rewrite four "global mutex" live claims in docs/architecture.md + docs/assumptions.md

- `depends_on: [0]`
- `touches: docs/architecture.md docs/assumptions.md` (4 edit hunks)
- [ ] **Hunk 1 (`docs/architecture.md:161`).** Inside the bullet list under §"Harness vs target — the load-bearing distinction" (H2 at line 100), locate the bullet that ends `The only shared thing is the global Claude mutex.`
  - Content anchor: AFTER the bullet beginning `- **No cross-target state leakage**:` AFTER the literal substring `its own pair of / launchd jobs.` (the prose-wrapped phrase that immediately precedes the target sentence) BEFORE the next H2 `## Dispatch lifecycle (one tick)`.
  - FROM: `The only shared thing is the global Claude mutex.`
  - TO: `The only shared thing is the global Claude counting semaphore at \`$HARNESS_STATE_DIR/.claude-semaphore/\` (default cap 2 since ENG-81; see "Cross-cutting: the Claude counting semaphore" below).`

- [ ] **Hunk 2 (`docs/architecture.md:194`).** Inside the dispatch-lifecycle ASCII diagram (the fenced-block running ~line 165-207), locate the line `      │   ├─ acquire global Claude mutex` (the indentation matches the rest of the diagram).
  - Content anchor: AFTER the literal line `      │   ├─ bin/dispatch.sh` BEFORE the next adjacent diagram line `      │   │   ├─ gtimeout <stage-cap> claude -p --allowed-tools <list>`.
  - FROM: `      │   │   ├─ acquire global Claude mutex`
  - TO: `      │   │   ├─ acquire slot in counting semaphore (.claude-semaphore/slot-<N>/)`

- [ ] **Hunk 3 (`docs/architecture.md:197`).** Same fenced-block. Locate the line `      │   │   └─ release Claude mutex`.
  - Content anchor: AFTER the line `      │   │   ├─ stream-json renderer: prose to log, raw to capture, usage-<stage>.json on result` BEFORE the line `      │   ├─ bin/scope-check.sh                            [post-agent]`.
  - FROM: `      │   │   └─ release Claude mutex`
  - TO: `      │   │   └─ release slot`

- [ ] **Hunk 4 (`docs/assumptions.md:135`).** Inside the bullet list under §"Single operator, single host" (H3 at line 121), locate the bullet ending `(the global mutex covers / every project's dispatch).`
  - Content anchor: AFTER the bullet `- Two machines cannot share a harness state directory — there's no / cross-host coordination.` BEFORE the bold-prefixed paragraph `**Failure mode:**`.
  - FROM (prose-wraps across two lines): `- Cross-project ticks DO serialize correctly (the global mutex covers\n  every project's dispatch).`
  - TO (matching wrap): `- Cross-project ticks share the per-host counting semaphore at\n  \`$HARNESS_STATE_DIR/.claude-semaphore/\` (cap from\n  \`orchestrator.max_concurrent_features\`, default 2 since ENG-81), so\n  cross-project concurrent dispatch is bounded by that cap rather than\n  fully serialized.`

- [ ] **Post-task verification.** Run:
  ```bash
  grep -cn 'global Claude mutex\|global mutex' docs/architecture.md   # → 0 (the historical line 19 says "binary mutex", not "global mutex"; the historical line 351 says "binary mutex" too — both retained)
  grep -cn 'global mutex' docs/assumptions.md                          # → 0
  grep -cn 'counting semaphore' docs/architecture.md                   # → ≥3 (existing + new Hunks 1 + 2/3 reframing)
  grep -cn 'counting semaphore' docs/assumptions.md                    # → ≥2 (existing line 124 + new Hunk 4)
  ```

### Task 6: Rewrite three "global mutex" live claims in docs/security.md + docs/cost.md

- `depends_on: [0]`
- `touches: docs/security.md docs/cost.md` (3 edit hunks)
- [ ] **Hunk 1 (`docs/security.md:20`).** Inside the bullet list (line 19-24) under "Anyone with shell access to the host can:", locate the first bullet ending `(subject to the global mutex).`
  - Content anchor: AFTER the line `Anyone with shell access to the host can:` BEFORE the next bullet starting `- Read every secret in \`$HARNESS_CONFIG_DIR\``.
  - FROM: `- Trigger arbitrary \`claude -p\` dispatches (subject to the global mutex).`
  - TO: `- Trigger arbitrary \`claude -p\` dispatches (subject to the per-host concurrency cap from \`orchestrator.max_concurrent_features\`, default 2).`

- [ ] **Hunk 2 (`docs/cost.md:31`).** Inside the prose paragraph that explains why the harness is calibrated for subscription mode (line 29-33), locate the substring `the global mutex + 5-minute tick is calibrated`.
  - Content anchor: AFTER the literal substring `**The harness is not designed for / this**` BEFORE the next paragraph or H3 line.
  - FROM (prose-wraps): `this** — the global mutex + 5-minute tick is calibrated against\nsubscription rate limits, and you'll see throughput throttle on the\nAPI without any benefit.`
  - TO (matching wrap): `this** — the per-host counting semaphore (default cap 2) + 5-minute tick\nis calibrated against subscription rate limits, and you'll see throughput\nthrottle on the API without any benefit.`

- [ ] **Hunk 3 (`docs/cost.md:182`).** Inside the prose paragraph about subscription tier caps (line 175-182), locate the sentence ending `... so throughput is bounded regardless of project count.`
  - Content anchor: AFTER the literal substring `Multi-project setups serialize through the` (which currently wraps to line 182's `global mutex, …`) BEFORE the H2 line `## Cost telemetry on disk` (line 184).
  - FROM (prose-wraps across lines 181-182): `Multi-project setups serialize through the\nglobal mutex, so throughput is bounded regardless of project count.`
  - TO (matching wrap): `Multi-project setups share the per-host counting semaphore (default\ncap 2 via \`orchestrator.max_concurrent_features\`), so throughput is\nbounded by the cap regardless of project count.`

- [ ] **Post-task verification.** Run:
  ```bash
  grep -cn 'global mutex' docs/security.md docs/cost.md       # → 0
  grep -cn 'counting semaphore' docs/security.md docs/cost.md  # → ≥3
  ```

### Task 7: Final AC#6 sweep + integration verification

- `depends_on: [1, 2, 3, 4, 5, 6]`
- `touches: (verification only; no file edits)`
- [ ] **Final grep sweep.** Run:
  ```bash
  grep -rn 'global mutex' README.md docs/ \
    | grep -v '^docs/brainstorms/\|^docs/plans/\|pre-ENG-81\|was a binary mutex'
  # → MUST return zero lines (all live claims rewritten)

  grep -rn '\.claude-mutex' README.md docs/ \
    | grep -v '^docs/brainstorms/\|^docs/plans/\|pre-ENG-81\|was a binary mutex'
  # → MUST return zero lines (only historical-contrast prose remains)
  ```
- [ ] **Cross-link integrity.** Verify the new anchor link from Task 1 Hunk 2 resolves to Task 2 Hunk 2's H3 anchor:
  ```bash
  grep -n 'orchestratormax_concurrent_features' README.md docs/configuration.md
  # → at least one line in each file; the README hyperlink target = the configuration.md anchor
  ```
- [ ] **AC#1-#5 in-tree gate.** Run:
  ```bash
  grep -cn 'global mutex' README.md                                   # → 0  (AC#1)
  grep -cn 'max_concurrent_features' README.md                        # → ≥2 (AC#2)
  grep -cn 'orchestratormax_concurrent_features\|max_concurrent_features' docs/configuration.md  # → ≥4 (AC#3)
  grep -cn '\.in-flight\.lock' docs/runbooks/failure-modes.md          # → ≥1 (AC#4)
  grep -cn 'CLAUDE_MAX_CONCURRENT=1\|CLAUDE_MAX_CONCURRENT' docs/runbooks/recovery.md # → ≥1 (AC#5)
  ```
- [ ] **Regression-coverage gate (defensive — no code touched, so all bin/* tests should pass unchanged).** Run the full `bin/*-test.sh` suite via the pre-commit hook:
  ```bash
  bash .githooks/pre-commit
  ```
  Any FAIL is a blocker.

## Frontend Tasks

No UI work. The harness has no frontend; this is a pure-prose doc sweep.

## Failure Mode → Test Map

This is a pure-prose doc sweep — no runtime code is added or modified. The "tests" therefore are **manual `grep` gates** (per the brainstorm's D-6 decision: no `bin/*-test.sh` regression test gates this work; AC verification is by `grep` per the ENG-99 precedent). The harness's existing `bin/*-test.sh` suite continues to pass unchanged (regression coverage; the suite does NOT grep any doc file for tokens this plan removes — see Assumption V-026 and N-002).

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Implement agent leaves a residual "global mutex" live claim | `Edit` boundary missed a content anchor, or rebase shifted a target so far the implement-agent's content anchor finds the wrong site | AC#6 final grep returns ≥1 line; review-stage agent hard-rejects | smoke | `grep -rn 'global mutex' README.md docs/ \| grep -v 'pre-ENG-81\|was a binary mutex'` (Task 7) |
| README's new §Configuration sentence breaks the existing prose flow | Hunk 2 inserts mid-sentence in the wrong spot | Visual inspection: the rendered Configuration section reads naturally; the markdown link to `docs/configuration.md#orchestratormax_concurrent_features` works | smoke | manual visual diff + click-through test in a markdown previewer |
| New `### orchestrator.max_concurrent_features` H3 is missing the anchor `<a id="orchestratormax_concurrent_features"></a>` | Task 2 Hunk 2 forgets the anchor; the README cross-link from Task 1 Hunk 2 dangles | `grep -n 'orchestratormax_concurrent_features' docs/configuration.md` returns ≥1 line | smoke | grep in Task 7's "Cross-link integrity" step |
| One of the two new failure-mode entries has a missing block of the five-block template | Task 3 Hunk 1 inserts incomplete content | Each entry has H3 sub-blocks for Symptom / Diagnose / Recover / Root cause / Related (5 H3s per entry × 2 entries = 10 new H3s) | smoke | `awk '/^## Concurrent dispatches/,/^---$/' docs/runbooks/failure-modes.md \| grep -c '^### '` → 5; same for `## Issue stuck at one stage` |
| K=1 rollback recipe instructions reference a non-existent path or command | Operator follows recipe and `launchctl bootstrap` fails because the plist path is wrong | Recipe references `$HOME/Library/LaunchAgents/com.twinning.pipeline.<slug>.plist`, the same path `bin/install-launchd.sh` writes | smoke | `grep -n 'com.twinning.pipeline' bin/install-launchd.sh docs/runbooks/recovery.md` — confirm same shape |
| Architecture.md dispatch-lifecycle ASCII diagram alignment broken | Hunk 2/3 substitutions change the prose length and break the box-drawing characters' column alignment | Diagram column alignment preserved (`│` chars line up vertically) | smoke | visual diff of the fenced-block in `docs/architecture.md` lines ~165-207 |
| Doc-content drift recurs (some future ticket reframes the mechanism again without updating these 8 files) | Future ticket changes K resolution / semaphore shape | Retrospective agent surfaces the pattern; AC#6 grep is the operator-runbook way to detect | n/a (test-gate is the future ticket's own) | (no test today; retrospective is the soft gate) |
| Pre-commit hook fails (regression risk) | Some learned-rules / AGENT_PROMPTS / bin/* test file unexpectedly tripped by doc text changes | All `bin/*-test.sh` continue to pass; the suite does not grep README.md or docs/* for tokens this plan removes (V-026, N-002) | regression | `bash .githooks/pre-commit` (Task 7's last step) |

## Test Strategy

### What this plan tests against

- **Unit / regression — no new tests.** Per brainstorm D-6 and the ENG-99 precedent (same shape, same disposition), the harness has no doc-content test gate today. Adding one for this ticket would be scope creep. The retrospective agent can propose a `bin/docs-drift-test.sh` as a learned rule if 3+ future tickets regress; that lands in its own ticket.
- **Test-gate closure sweep (per the prompt's feasibility instructions).** This plan REMOVES exactly two doc-prose token classes:
  1. `global mutex` (literal substring) — 6 occurrences in live operator-facing prose: `README.md` (2), `docs/assumptions.md` (1), `docs/security.md` (1), `docs/cost.md` (2). Plus the variant `global Claude mutex` / `Claude mutex` at `docs/architecture.md` (3 — lines 161/194/197) which carries identical operator-facing pre-ENG-81 framing. Total: **9 live-claim lines across 6 files**, all rewritten. After implementation, only the deliberate historical-contrast prose at `docs/architecture.md:19` ("was a binary mutex in `.claude-mutex.lock/` pre-ENG-81") and `docs/architecture.md:351` ("Pre-ENG-81 this was a binary mutex (cap=1)") remains — neither matches the `global mutex` substring the AC#6 grep targets — plus the out-of-scope `docs/brainstorms/` and `docs/plans/` historical artifacts.
  2. **No production-code token removed.** The `[claude-mutex]` log-line text in `bin/dispatch.sh` and `bin/setup.sh` is preserved (A-033 invariant from ENG-81). The tests that grep this text (`bin/mutex-test.sh:54`, `bin/common-test.sh:903`) keep passing because production code is untouched.
- **Sibling test file sweep result.** `grep -ln 'docs/configuration\|docs/runbooks\|README.md.*mutex\|README.md.*concurrent' bin/*-test.sh` returns only comment lines (`bin/agent-prompts-content-test.sh:789` and `bin/run-stage-test.sh:4204`), never assertion lines. **No sibling test file pins any token this plan removes.** Test-gate closure is clean — no P0 plan-completeness defect.
- **Adversarial coverage.** The eight in-scope files have no functional behavior to adversarially test. The closest analogue is "what happens if the implement agent gets two anchors wrong?" — the answer is the AC#6 final grep at Task 7 catches it; the review stage hard-rejects unmet ACs.
- **Smoke coverage (manual).** The Failure Mode → Test Map table above lists 7 manual grep / visual-diff smoke checks bound to Task 7's verification block; the review-stage agent runs the same greps to gate.
- **Integration coverage.** The cross-link from `README.md` (Hunk 2 of Task 1) into `docs/configuration.md` (Hunk 2 of Task 2's H3 anchor) and from `docs/configuration.md` Hunk 3's Examples block into `docs/runbooks/recovery.md` (Task 4's new H2 `#9-emergency-roll-back-concurrent-dispatches-to-k1` anchor) are link-integrity checks; Task 7's "Cross-link integrity" greps gate them. GitHub markdown rendering of these anchors uses kebab-case slugification; the chosen anchor texts conform.
- **What this plan deliberately does NOT test.**
  - Doc-rendering correctness in any specific markdown viewer (GitHub, Linear, local IDE preview) — these all render commonmark + GitHub-flavored markdown; the existing docs use the same idioms.
  - The runbook recipes' actual operational behaviour (e.g. running `launchctl bootstrap` against a real plist). Those exercise the recovery path itself, not this doc.
  - The retrospective agent's behaviour against these doc changes; it runs weekly and surfaces drift patterns as learned rules in its own PR cycle.
