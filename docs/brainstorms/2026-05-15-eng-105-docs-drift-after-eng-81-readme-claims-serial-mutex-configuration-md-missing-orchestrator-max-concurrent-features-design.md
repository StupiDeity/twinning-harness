---
linear: ENG-105
title: Docs drift after ENG-81 — README still claims serial mutex; configuration.md missing `orchestrator.max_concurrent_features`
date: 2026-05-15
status: draft
related: ENG-81, ENG-99
---

# ENG-105 — Docs drift after ENG-81: README/configuration.md/runbook gaps

## 1. Overview

ENG-81 (May 2026) shipped per-project parallel `claude -p` dispatch
(default K=2 from `orchestrator.max_concurrent_features`, backed by a
counting semaphore at `$HARNESS_STATE_DIR/.claude-semaphore/slot-<N>/`,
with per-issue `.in-flight.lock` preventing same-issue double-dispatch).
The mechanism is live; `CLAUDE.md` covers it fully (§ "Per-project
dispatch concurrency"); `docs/architecture.md`, `docs/install.md`,
`docs/operations.md`, `docs/assumptions.md` and
`docs/runbooks/operator-mental-model.md` all describe the
counting-semaphore mechanics correctly. But four operator-facing surfaces
still lag:

1. **README.md** — two "global mutex serializes dispatch" claims
   (§"Not for" line 30, §Assumptions line 416) that are post-ENG-81
   false. README has no mention of `orchestrator.max_concurrent_features`
   in the §Configuration prose (lines 332–354) even though it's now a
   primary throughput tunable.
2. **docs/configuration.md** — has zero mention of
   `orchestrator.max_concurrent_features` despite documenting every other
   `orchestrator.*` knob (`paused`, `dispatch_timeout_minutes`,
   `dispatch_timeout_minutes_per_stage`, `entry_conditions`). This is the
   canonical config reference and is the biggest gap — operators grep
   here to change the cap and find nothing.
3. **docs/runbooks/failure-modes.md** — lacks entries for the two
   ENG-81-era symptoms that `CLAUDE.md`'s quick-reference table already
   names: "Concurrent dispatches not running (expected K=2, observed K=1)"
   and "Issue stuck at one stage; `.in-flight.lock` present".
4. **docs/runbooks/recovery.md** — has no `CLAUDE_MAX_CONCURRENT=1`
   emergency-rollback recipe, although `CLAUDE.md` covers it under §
   "Per-project dispatch concurrency".

This is a **pure documentation sweep** in the same spirit as
ENG-99/Tauri-residue cleanup (already merged) — no code, no schema, no
mechanism, no test, no Linear-API change. Five files touched, all under
`README.md` + `docs/`. The acceptance criteria are inspectable by
`grep`.

**Load-bearing tradeoff.** Every documentation rewrite risks
*duplicating* content that already lives in `CLAUDE.md`. The trade-off
is operator reach vs. single-source-of-truth: `CLAUDE.md` is read by
every dispatched agent and by maintainers — operators reading the
public README or the canonical config reference do NOT read `CLAUDE.md`
first (it is a contributor-facing doc, not an operator manual). For
the four AC-driven sites, the right play is *operator-targeted prose*
that is consistent in terminology with `CLAUDE.md` but does NOT
duplicate the full mechanics; instead it links back where deep dives
live. Canonical phrasing locks (§4) keep the rewrites mutually
consistent.

## 2. Goal

After ENG-105 lands:

- `grep -rn 'global mutex' README.md docs/` returns **no live claims** —
  only deliberate historical-contrast prose in
  `docs/architecture.md` (lines 15–19, 345–366, 408, 414),
  `docs/runbooks/operator-mental-model.md` (lines 309–326), and
  `docs/assumptions.md` (lines 124–126). [AC#1 + AC#6]
- README §Configuration prose (332–354) names
  `orchestrator.max_concurrent_features` alongside the other typical
  knobs. [AC#2]
- `docs/configuration.md` has a dedicated
  `### orchestrator.max_concurrent_features` subsection mirroring the
  shape of the existing `### orchestrator.dispatch_timeout_minutes_per_stage`
  entry — covering: default (2), resolution precedence
  (`CLAUDE_MAX_CONCURRENT` env > config > default), validation rules,
  emergency-rollback recipe, and the dual role (per-tick dispatch cap
  AND WIP cap on `stage:*` labels). [AC#3]
- `docs/runbooks/failure-modes.md` gains two entries: "Concurrent
  dispatches not running" and "Issue stuck at one stage with
  `.in-flight.lock` present". Each follows the existing catalog's
  shape (Symptom / Diagnose / Recover / Root cause / Related). [AC#4]
- `docs/runbooks/recovery.md` documents the `CLAUDE_MAX_CONCURRENT=1`
  emergency-rollback path. [AC#5]

**Out of scope** (named explicitly to bound the sweep):

- `docs/brainstorms/`, `docs/plans/`, `learned-rules/` — historical
  artifacts; rewriting them erases the decision trail (same boundary
  ENG-99 used).
- `CLAUDE.md` — already authoritative on ENG-81; not re-touched.
- `docs/architecture.md`, `docs/install.md`, `docs/operations.md`,
  `docs/runbooks/operator-mental-model.md`, `docs/assumptions.md`
  (lines 120–134) — already describe the post-ENG-81 paradigm
  correctly per the ticket spec. *See Open Question §8.1 for a
  flagged scope-tension with three live "global mutex" prose lines
  (architecture.md:161/194/197 and assumptions.md:135) that the
  ticket lists as "already correct" but that AC#6 would have us
  rewrite as a strict reading.*
- No `bin/*-test.sh` regression test (the harness has no doc-content
  test pattern; AC#1/#6 verification is a one-line `grep` the
  reviewer can run, not a CI gate).

## 3. Architectural principle

This work extends the **single-source-of-truth + audience-targeted-mirror**
principle the harness already follows: deep mechanics live in
`CLAUDE.md` and `docs/architecture.md`; operator-facing prose
(`README.md`, `docs/configuration.md`, `docs/runbooks/*.md`) mirrors
those facts in audience-appropriate density, not deeper. ENG-105
closes a documentation gap that ENG-81 left open when it landed the
mechanism but only updated three of seven operator-facing surfaces.

The harness has no `docs/VISION.md` or formal ADR registry (verified:
`ls docs/` returns `architecture.md assumptions.md brainstorms/
configuration.md cost.md demos/ install.md operations.md
pipeline-vocabulary.md pipeline-vocabulary.template.md plans/
runbooks/ security.md` — no `VISION.md`, no `knowledge/decisions.md`).
Governing constraints come from `CLAUDE.md`, the project profile
addendum, and the ENG-81 design.

The closest analogues in brainstorm history:
- **ENG-99** (2026-05-13) — Tauri-residue doc sweep; same shape (no
  code, AC verified by grep, "what's already correct" carved out).
- **ENG-77 / ENG-71** stage-summary overwrite contract — informs the
  decision to use simple Edit operations rather than Write-replace
  (Edit preserves the rest of each file; Write would force a full
  rewrite and lose surrounding context).

## 4. Decisions

### D-1: Single canonical name for the cap, used identically across all four touched files

**Decision:** Use **`orchestrator.max_concurrent_features`** as the
canonical name. Use **`CLAUDE_MAX_CONCURRENT`** as the canonical env-var
override. Where prose names the dispatch primitive, use **"counting
semaphore"** (singular). Drop the word "mutex" entirely from new live
claims (it survives only as historical-contrast prose where existing
text already frames it as pre-ENG-81).

**Rationale:** `CLAUDE.md` § "Per-project dispatch concurrency" already
uses exactly these strings; consistency with the contributor-facing doc
prevents new drift. The pre-/post-ENG-81 history is named only where it
helps (the architecture.md historical-contrast paragraph), not in every
operator-facing site.

**Rejected alternative:** "concurrency cap" or "K" as the operator
shorthand. Rejected because the env var name (`CLAUDE_MAX_CONCURRENT`)
and the config key (`orchestrator.max_concurrent_features`) are what
operators actually grep — terms-of-art consistency outranks brevity.

**Principle reference:** `CLAUDE.md` § "Per-project dispatch
concurrency" (lines 623–671).

### D-2: README touches stay minimal — three small surface-level rewrites, not a §Concurrency rewrite

**Decision:** Three targeted edits in `README.md`:
- **Line 30** — replace "(a global mutex serializes dispatch)" with
  "(state directories are single-host; concurrency cap is per-host)"
  (keeps the §"Not for" semantics — still warns multi-operator readers
  off — without the false mechanism claim).
- **Line 416** — replace "Cross-tick concurrency is serialized via a
  global mutex; cross-machine concurrency is not supported." with
  "A counting semaphore at `$HARNESS_STATE_DIR/.claude-semaphore/`
  caps concurrent `claude -p` dispatches at
  `orchestrator.max_concurrent_features` (default 2); cross-machine
  concurrency is not supported." (Preserves the genuinely-true
  cross-machine half, fixes the intra-host claim.)
- **Lines 346–349** (§Configuration prose, the "Most operators only
  edit `config.json` for…" sentence) — append
  `orchestrator.max_concurrent_features` to the enumerated list of
  typical knobs ("per-stage dispatch timeouts…, the dispatch.tools
  allowlist…, entry-conditions…, or `orchestrator.max_concurrent_features`
  (the per-tick dispatch concurrency cap; default 2)"). One sentence,
  no new prose blocks.

**Rationale:** The README is the entry-point doc, deliberately tight
(429 lines). Adding a §Concurrency H2 would push other content down
and duplicate `CLAUDE.md` content the deep-dive `docs/configuration.md`
will now also host. The single-sentence touch in §Configuration is the
cheapest correct change that satisfies AC#2.

**Rejected alternative:** Add a §Concurrency H2 between §Configuration
and §"Artifacts and locations" with the full ENG-81 explainer.
Rejected because (a) `CLAUDE.md` and the new `docs/configuration.md`
subsection already cover the same ground in greater detail, and (b)
README length discipline matters for a "Is this for you" doc.

**Principle reference:** README §How it works opening sets the
"deep dives live in docs/" pattern; new content follows the existing
single-source-of-truth lattice.

### D-3: `docs/configuration.md` gains a dedicated `### orchestrator.max_concurrent_features` subsection mirroring `### orchestrator.dispatch_timeout_minutes_per_stage`

**Decision:** Insert the new subsection immediately AFTER
`### orchestrator.dispatch_timeout_minutes_per_stage` (which ends at
line ~116) and BEFORE `### orchestrator.entry_conditions (ENG-86)`
(which starts at line ~118). Subsection structure:

1. **One-sentence summary** — what the knob does (per-project per-tick
   dispatch cap AND WIP cap on `stage:*`-labelled issues).
2. **Default** — 2 (set by `bin/setup.sh::phase_config_defaults`).
3. **Resolution precedence** — explicit numbered list mirroring CLAUDE.md:
   1. `CLAUDE_MAX_CONCURRENT` env var (highest; set in the launchd
      plist's `EnvironmentVariables` block).
   2. `.orchestrator.max_concurrent_features` in target's `config.json`.
   3. Built-in default 2.
4. **Validation rules** — non-integer / `<1` falls through to the next
   layer with a `log` warning to stderr (visible in
   `$PROJECT_STATE_DIR/<slug>/logs/local-*.log`). Mirrors the per-stage
   timeout validation prose.
5. **Inspection command** —
   `ls $HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid` plus
   `bash bin/status.sh` for the aggregated view.
6. **Emergency rollback** — `CLAUDE_MAX_CONCURRENT=1` in the launchd
   plist + `launchctl bootstrap` (host-wide), or `config.json` edit
   (per-project). Cross-links to `docs/runbooks/recovery.md` (where
   the full recipe lands per D-5).
7. **The dual role** — explicit callout that the SAME key is also the
   WIP cap on `stage:*` labels (the pre-ENG-81 meaning, still in
   force).
8. **Cross-link to `CLAUDE.md` §"Per-project dispatch concurrency"**
   for the deep mechanics + slot-occupancy interaction. No copy of
   the mechanics — just the link.

Also: update the `config.json` schema example block (lines 33–52) to
include `"max_concurrent_features": 2,` under `"orchestrator"` so the
schema sketch matches what setup writes. Add one example block under
§Examples (after "Build cost-recovery enabled") titled "Constrained
concurrency (single-slot)" that sets `max_concurrent_features: 1` —
mirroring the existing pattern.

**Rationale:** AC#3 explicitly requests this shape. The existing
per-stage-timeout subsection is the local template — same structure,
same density, same validation-rules paragraph shape. Operators reading
top-to-bottom encounter `max_concurrent_features` alongside the other
`orchestrator.*` knobs, where they expect it.

**Rejected alternative:** A standalone `## Concurrency cap` H2.
Rejected because every other `orchestrator.*` knob is a single H3
subsection under `## config.json schema`; a top-level H2 breaks the
existing pattern and makes the knob feel special when it's just one
of many.

**Principle reference:** `docs/configuration.md` is the per-section
deep dive for each `orchestrator.*` knob; new knobs follow the
existing H3-subsection pattern.

### D-4: `docs/runbooks/failure-modes.md` gains two new entries that match the existing catalog's shape

**Decision:** Insert two new entries after the existing
"Brainstorm halts at `iteration-exhausted`" section (ends around
line 393) and BEFORE "scope-check halts on upstream merge files"
(starts around line 397). Each entry follows the same five-block
template the rest of the catalog uses: Symptom / Diagnose / Recover /
Root cause / Related.

**Entry A — "Concurrent dispatches not running (expected K=2,
observed K=1)":**

- *Symptom:* `bash bin/status.sh` "Concurrent dispatches active"
  shows 1 when expecting 2 (or 2 when expecting 3); pipeline appears
  to throttle. Per-tick dispatch volume below operator expectation.
- *Diagnose:* (i) Read resolved K from log:
  `grep 'scheduler: K=' "$PROJECT_STATE_DIR/<slug>/logs/local-$(date -u +%Y-%m-%d).log"`.
  (ii) Inspect plist env: `launchctl print "gui/$(id -u)/com.twinning.pipeline.<slug>" | grep -i CLAUDE_MAX_CONCURRENT`.
  (iii) Inspect config: `jq '.orchestrator.max_concurrent_features' .pipeline-config/config.json`.
  (iv) Inspect live slot occupancy: `ls $HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid`.
- *Recover:* Per cause:
  - Env-var override unintentionally set to 1 → `launchctl unsetenv
    CLAUDE_MAX_CONCURRENT` (or edit plist + `launchctl bootstrap`).
  - Config explicitly set to 1 → edit `config.json`.
  - Eligible-issue pool < cap → not a bug; expected when fewer
    issues are advanceable than the cap allows.
- *Root cause:* `_resolve_K`'s precedence is env > config > default;
  any non-integer or `<1` at the higher tier falls through silently
  with a `log` warning.
- *Related:* ENG-81 (the lifecycle inversion that introduced the
  concept), ENG-90 (slot-occupancy contract).

**Entry B — "Issue stuck at one stage; `.in-flight.lock` present":**

- *Symptom:* An issue with `stage:*` label hasn't advanced for one
  or more ticks; `$(issue_dir <issue>)/.in-flight.lock/` exists.
  Tick logs show the issue being repeatedly skipped.
- *Diagnose:* (i) Confirm lock present:
  `ls "$(bash bin/pipeline.sh issue-dir ENG-N)/.in-flight.lock"`.
  (ii) Inspect holder: `cat "$(bash bin/pipeline.sh issue-dir ENG-N)/.in-flight.lock/pid"`
  and `cat "$(bash bin/pipeline.sh issue-dir ENG-N)/.in-flight.lock/timestamp"`.
  (iii) Verify holder liveness: `ps -p $(cat .in-flight.lock/pid)`.
- *Recover:* `try_acquire_lock` (`bin/common.sh`) self-heals on the
  next tick: it writes the holder pid+timestamp on every acquire and
  reclaims the lock if `kill -0 $pid` fails. **No operator action
  needed for the common case.** If the holder pid IS alive but the
  issue still appears stuck (rare — implies the holder is hung
  rather than orphaned), `ps -p` and inspect the timestamp; a manual
  `rm -rf "$(bash bin/pipeline.sh issue-dir ENG-N)/.in-flight.lock"`
  is the override of last resort.
- *Root cause:* Pre-ENG-81 scheduler/worker-split leaked an orphan
  lock if the worker SIGKILLed or oomkilled between acquire and
  release. ENG-81's `try_acquire_lock` self-heals on next acquire.
- *Related:* ENG-81 (per-issue lock contract), `bin/common.sh::try_acquire_lock`.

**Rationale:** AC#4 lists exactly these two entries; the
five-block template is the existing convention in the catalog
(verified at every entry from "Tick is silent" through "scope-check
halts on upstream merge files"). Cross-links to `CLAUDE.md` §
"Per-project dispatch concurrency" for the conceptual model.

**Rejected alternative:** A single combined "ENG-81 failure modes"
section. Rejected because the catalog's organising principle is one
symptom = one entry; combining them defeats the diagnostic lookup
flow operators actually use (grep the symptom, jump to the entry).

**Principle reference:** `docs/runbooks/failure-modes.md` opening
("How to read this catalog") sets the five-block template; new
entries follow it.

### D-5: `docs/runbooks/recovery.md` gains a `CLAUDE_MAX_CONCURRENT=1` emergency-rollback recipe as a new top-level section

**Decision:** Insert a new section near the end of `recovery.md` (after
the ENG-87 forensic-asymmetry section, before the "Quick reference:
env var requirement" section). Title: `## Emergency: roll back concurrent dispatches to K=1`.
Body covers:
- **When to use it** — sudden Linear-API rate-limit symptoms,
  unexpected `claude` subscription quota burns, suspected race
  bug in a new ENG-81-adjacent change.
- **Host-wide rollback** (preferred — affects every project on this
  Mac immediately on next tick):
  ```bash
  # Edit ~/Library/LaunchAgents/com.twinning.pipeline.<slug>.plist
  # Add to <key>EnvironmentVariables</key>:
  #   <key>CLAUDE_MAX_CONCURRENT</key>
  #   <string>1</string>
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.twinning.pipeline.<slug>.plist
  ```
- **Per-project rollback** (use when one project's bug should not
  drag down healthy projects):
  ```bash
  jq '.orchestrator.max_concurrent_features = 1' \
    "$TARGET_REPO/.pipeline-config/config.json" \
    > /tmp/c && mv /tmp/c "$TARGET_REPO/.pipeline-config/config.json"
  ```
- **Verify** — next tick's log shows `scheduler: K=1`; only one slot
  dir under `.claude-semaphore/` is in use at a time.
- **Restore** — remove the env var (or revert the `config.json` edit)
  and `launchctl bootstrap` again.

**Rationale:** AC#5 explicitly requests this. `recovery.md` is the
correct host (it already covers other emergency-resume operations:
`halt.sh resolve --decision resume`, multi-stage-label cleanup,
`pipeline-halted` with stale-comment-timestamp). The recipe doesn't
fit the failure-modes "Symptom-driven catalog" template (it's
proactive, not diagnostic), so recovery.md is the right home.

**Rejected alternative:** Add the rollback to `failure-modes.md`
Entry A's Recover block. Rejected because operators using rollback
typically aren't responding to the "Concurrent dispatches not running"
symptom — they're responding to a broader incident (rate limits, cost
spike, suspected bug). Different operator entry-points → different
documentation locations.

**Principle reference:** `recovery.md`'s opening framing — "Quick
reference for fixing issues stuck in [recovery modes]" — applies
to proactive rollback as much as to stuck-issue rescue.

### D-6: Pure prose edits, no new tests, no AGENT_PROMPTS.md change

**Decision:** No `bin/*-test.sh` regression test gates this work. AC
verification is by `grep`:

```bash
grep -rn 'global mutex' README.md docs/      # only historical contrast
grep -n  'max_concurrent_features' README.md docs/configuration.md  # both present
grep -n  '\.in-flight\.lock' docs/runbooks/failure-modes.md         # present
grep -n  'CLAUDE_MAX_CONCURRENT=1' docs/runbooks/recovery.md        # present
```

**Rationale:** The harness has no doc-content test gate today
(precedent: ENG-99 used the same approach). Adding one for this
ticket would be scope creep — and a doc-content test that the
retrospective could maintain belongs in its own ticket.

**Rejected alternative:** Add `bin/docs-drift-test.sh` that greps the
in-scope files for known-stale tokens. Rejected because (a) ENG-99
established the precedent of grep-on-PR for doc sweeps, (b) a new test
is mechanism work and belongs in its own ticket, and (c) the
retrospective agent already reads doc updates and could propose this
pattern as a learned rule.

**Principle reference:** Project profile's "Build & test gates"
section names every test file; adding one without a separate ticket
violates the scope discipline ENG-99 set.

## 5. Architecture / where code goes

No code. Five files mutated:

| File | Touch shape | Lines (current) |
|---|---|---|
| `README.md` | Edit | 30 (single line), 332–354 (one-sentence append in 346–349), 416 (single line) |
| `docs/configuration.md` | Edit (schema example + new H3 subsection + new example block) | 33–52 schema block (one line added); new subsection between current line 116 and 118; new §Examples block after line 336 |
| `docs/runbooks/failure-modes.md` | Edit (two new entries) | Between lines 393–397 (Brainstorm halts ↔ scope-check halts) |
| `docs/runbooks/recovery.md` | Edit (one new section) | Near tail, before "Quick reference: env var requirement" |

All edits use the `Edit` tool with literal old_string / new_string
matches; no `Write` (which would force whole-file rewrites and risks
losing context across the 469-line and 631-line runbooks). The plan
agent will derive exact diffs.

## 6. Data flow / state changes

None. No code is added; no runtime state changes; no Linear
read/write; no metric is emitted; no config schema is changed (the
example block in configuration.md gains a line for documentation
purposes only — the orchestrator already reads
`max_concurrent_features` from config; `bin/setup.sh::phase_config_defaults`
already writes it).

## 7. Error handling

No new error paths. The doc sweep cannot fail at runtime; it can
only fail review (a missing edit caught by the AC#1/#6 grep, or a
stylistic inconsistency caught by the coherence persona). The
retrospective will catch any new drift on its weekly run.

## 8. Edge cases / open questions

### 8.1 — Open question: scope-tension between ticket's "do not re-touch" list and AC#6 grep

**The tension.** The ticket lists `docs/architecture.md` and
`docs/assumptions.md` as already correct (no re-touch), but
`grep -rn 'global mutex' README.md docs/` against the current worktree
finds **seven** live (non-historical-contrast) references — four in
files the ticket lists as "already correct" plus three in two files
the ticket leaves uncategorized (`docs/security.md`, `docs/cost.md`):

| File:line | Current text | Classification |
|---|---|---|
| `architecture.md:161` | "The only shared thing is the global Claude mutex." | Live claim; ticket says "do not re-touch" |
| `architecture.md:194` | "acquire global Claude mutex" (in dispatch-lifecycle diagram) | Live claim; ticket says "do not re-touch" |
| `architecture.md:197` | "release Claude mutex" (same diagram) | Live claim; ticket says "do not re-touch" |
| `assumptions.md:135` | "(the global mutex covers every project's dispatch)" | Live claim; ticket says "do not re-touch" |
| `security.md:20` | "Trigger arbitrary `claude -p` dispatches (subject to the global mutex)." | Live claim; **ticket uncategorized** |
| `cost.md:31` | "the global mutex + 5-minute tick is calibrated against subscription rate limits" | Live claim; **ticket uncategorized** |
| `cost.md:182` | "Multi-project setups serialize through the global mutex" | Live claim; **ticket uncategorized** |

A strict reading of AC#6 ("returns only deliberate historical-contrast
prose, never as a live claim") would require fixing all seven lines.
A strict reading of the ticket's "What's already correct (do not
re-touch)" list would leave the first four. The latter three sites
are mentioned in neither list — the ticket is silent on them. Both
strict readings cannot be satisfied simultaneously.

**Recommendation (proposed).** Fix all seven — they're one-token swaps
(`global Claude mutex` → `counting semaphore`; `(the global mutex
covers…)` → `(the counting semaphore covers…)`; `subject to the global
mutex` → `subject to the per-host concurrency cap`; `Multi-project
setups serialize through the global mutex` → `Multi-project setups
share the per-host counting semaphore`) that take seconds to make and
preserve the surrounding prose's intent. Scope creep is bounded (7
single-line edits in 4 files), and the AC#6 grep then passes cleanly
post-merge. The three uncategorized sites (security.md / cost.md) are
genuinely silent in the ticket — the brainstorm flags them so the
planner makes a deliberate choice rather than discovering them at
implement-time.

**Alternative (strict-scope).** Leave the four "do not re-touch" sites
AND the three uncategorized sites; document the tension in the
brainstorm; open a follow-up ticket. Cost: AC#6 grep returns
non-zero, the reviewer has to manually filter, and the next sweep
has more residual drift to chase.

**Decision deferred to plan stage** — the planner should pick one
path and document the choice in the plan doc's "scope deviations"
section. The brainstorm's stance is: prefer the proposed-recommendation
path; flag the tension; do not silently expand scope without operator
visibility.

### 8.2 — Pre-existing line-number drift in the ticket spec

The ticket cites `README.md:30`, `README.md:416`, and "lines 332–354".
Current worktree (verified 2026-05-15) matches: line 30 carries the
"global mutex serializes dispatch" claim; line 416 carries the
"serialized via a global mutex" claim; the §Configuration prose
runs 332–354. Configuration.md's
`### orchestrator.dispatch_timeout_minutes_per_stage` runs 92–116; the
insertion point for the new H3 is unambiguous. failure-modes.md's
"Brainstorm halts" → "scope-check halts" boundary at lines 393–397
is the insertion point for the two new entries. No drift to chase
in this case, but the planner should re-verify line numbers at plan
time (per ENG-99 precedent — Linear-issue line numbers are
time-of-filing snapshots).

### 8.3 — Cross-link discipline

Each touched file gets a cross-link to `CLAUDE.md` § "Per-project
dispatch concurrency" rather than copying mechanics. This means a
reader who hits the runbook entry can chase the deep dive in
`CLAUDE.md` without leaving their local checkout. (`CLAUDE.md` is
the contributor-facing doc; operators reading the README + runbooks
get back-references when they need depth.) No GitHub-blob-URL
references — relative paths only, since the docs ship together.

### 8.4 — Terminology: "K" vs `max_concurrent_features` vs "concurrency cap"

`CLAUDE.md` uses both "K=2" (shorthand) and
`orchestrator.max_concurrent_features` (canonical). The brainstorm's
D-1 lock says new prose uses the canonical form. Where "K" appears in
existing prose (failure-modes.md will reference it in Entry A's
symptom: "expected K=2, observed K=1"), keep the shorthand AS the
symptom phrasing (it's how the operator perceives the symptom — they
see "K=" in logs); use the canonical form for the underlying knob.

### 8.5 — Cost / risk

Cost: ~30–60 min implementation; one short PR; zero code; no test
regression risk. Risk: drift over time if a future ticket changes
the mechanism without updating these four files. Mitigation: the
retrospective agent's stage-summary surfaces stale-doc patterns when
they recur (precedent: ENG-99 was a retro-surfaced sweep).

### 8.6 — Why a counting semaphore and not a real job queue (out of scope for ENG-105 — but the doc rewrites should not relitigate it)

Already decided in ENG-81 §3.2 (rejected alternative): the binary
mutex → counting semaphore evolution is the smallest correct
intervention; a real job queue (Redis/SQS/...) is overkill for the
single-host scope and would be a much bigger change. The new
documentation in ENG-105 should not relitigate or even allude to the
job-queue alternative — that risks confusing operators who would then
ask why we didn't ship it. Stick to "counting semaphore, default K=2,
override precedence env > config > default."

## 9. Assumption inventory

Each assumption checked by reading the current worktree and recording
the file:line that proves it.

### Verified (code/docs match the brainstorm's claim)

| # | Claim | Verified at |
|---|---|---|
| 1 | `README.md:30` carries "global mutex serializes dispatch" claim. | `README.md:30` — `"Team-shared CI / multi-operator setups (a global mutex serializes dispatch)"` |
| 2 | `README.md:416` carries "serialized via a global mutex" claim. | `README.md:415-416` — `"Cross-tick concurrency is serialized via a global mutex; cross-machine concurrency is not supported."` |
| 3 | `README.md` §Configuration prose at lines 332–354 lists typical knobs without `max_concurrent_features`. | `README.md:346-349` lists "per-stage dispatch timeouts… the dispatch.tools allowlist… entry-conditions" — no `max_concurrent_features`. |
| 4 | `docs/configuration.md` documents `paused` (line 70), `dispatch_timeout_minutes` (line 83), `dispatch_timeout_minutes_per_stage` (line 92), `entry_conditions` (line 118) — but NOT `max_concurrent_features` (grep returns zero matches). | `docs/configuration.md` lines 70/83/92/118; grep `max_concurrent_features docs/configuration.md` returns nothing. |
| 5 | `docs/configuration.md` `### orchestrator.dispatch_timeout_minutes_per_stage` runs 92–116 — the structural template for the new subsection. | `docs/configuration.md:92-116`. |
| 6 | `docs/configuration.md` has a `## Examples` H2 with `### Minimal`, `### Tightened timeouts`, `### Build cost-recovery enabled`, `### Full harness-self profile` — the structural template for the new example block. | `docs/configuration.md:297-362`. |
| 7 | `docs/runbooks/failure-modes.md` follows a five-block template (Symptom / Diagnose / Recover / Root cause / Related). | `docs/runbooks/failure-modes.md:13-19` (How to read) + every entry conforms. |
| 8 | `docs/runbooks/failure-modes.md` has no entry for `.in-flight.lock` or "Concurrent dispatches not running" — grep returns zero matches. | grep `'in-flight\|max_concurrent_features\|CLAUDE_MAX_CONCURRENT' docs/runbooks/failure-modes.md` returns no matches. |
| 9 | `docs/runbooks/recovery.md` has no `CLAUDE_MAX_CONCURRENT` recipe — grep returns zero matches. | grep `'CLAUDE_MAX_CONCURRENT\|max_concurrent_features' docs/runbooks/recovery.md` returns no matches. |
| 10 | `CLAUDE.md` §"Per-project dispatch concurrency" exists at lines 623–671 and covers default (2), resolution precedence (env > config > default), validation rules, inspection command, emergency rollback. | `CLAUDE.md:623-671`. |
| 11 | `CLAUDE.md` quick-reference table includes both new failure-mode entries at lines 620 and 621. | `CLAUDE.md:620-621`. |
| 12 | `bin/dispatch.sh` historically held a binary mutex via `acquire_claude_mutex` (the pre-ENG-81 mechanism named in the architecture.md historical-contrast prose); ENG-81 replaced it with the counting semaphore. | Plan doc reference: `docs/plans/2026-05-14-eng-81-...md:26-27` (A-001/A-002 assumptions verified `bin/dispatch.sh:20-36`, `:475-476` pre-ENG-81). The current worktree's post-ENG-81 state is the counting semaphore. |
| 13 | The `try_acquire_lock` function lives in `bin/common.sh` and self-heals on the next acquire when the holder pid is dead. | `CLAUDE.md:621` references `try_acquire_lock` in `common.sh`; CLAUDE.md is the authoritative narrative since the brainstorm only references the function by name, not by line. |
| 14 | `docs/architecture.md:161` carries a live "global Claude mutex" claim. | `docs/architecture.md:161` — `"The only shared thing is the global Claude mutex."` |
| 15 | `docs/architecture.md:194` and `:197` carry live mutex acquire/release prose in the dispatch lifecycle diagram. | `docs/architecture.md:194` (`acquire global Claude mutex`), `:197` (`release Claude mutex`). |
| 16 | `docs/assumptions.md:135` carries the parenthetical "(the global mutex covers every project's dispatch)". | `docs/assumptions.md:135`. |
| 17 | `docs/architecture.md:15-19` and `:345-366` and `:408,:414` describe the counting semaphore correctly (the ticket-spec-correct lines). | `docs/architecture.md:15-19`, `:345-366`, `:408`, `:414`. |
| 18 | `docs/install.md:261` and `:274-275` describe the counting semaphore correctly. | `docs/install.md:261, 274-275`. |
| 19 | `docs/operations.md:216` describes the counting semaphore correctly. | `docs/operations.md:216`. |
| 20 | `docs/runbooks/operator-mental-model.md:20` and `:309-326` describe the counting semaphore correctly. | `docs/runbooks/operator-mental-model.md:20, 309-326`. |
| 21 | `README.md:367` (the directory tree under §"Artifacts and locations") describes `.claude-semaphore/` correctly. | `README.md:367`. |
| 22 | Ticket spec's stated insertion point for D-3 (between `dispatch_timeout_minutes_per_stage` and `entry_conditions`) is structurally unambiguous — there are no other `orchestrator.*` H3s in between. | `docs/configuration.md:92, 118` (boundary lines verified). |
| 23 | Three additional live "global mutex" claims exist in files the ticket leaves uncategorized: `docs/security.md:20`, `docs/cost.md:31`, `docs/cost.md:182`. AC#6 grep flags them; §8.1 enumerates them. | `docs/security.md:20`, `docs/cost.md:31`, `docs/cost.md:182` (all read inline during feasibility re-verification). |

### Assumed (load-bearing during plan/implementation, not verified by brainstorm)

| # | Claim | How to validate |
|---|---|---|
| A-1 | Plan agent will derive exact Edit diffs from the current line numbers at plan-time (not trust the brainstorm's snapshot). | Plan-stage re-grep of the four files (precedent: ENG-99 plan). |
| A-2 | Implement agent's Edit tool can produce idempotent patches against the four files without unrelated drift. | Standard implement-stage TDD evidence + scope-check. |
| A-3 | Coherence persona will catch any terminology drift between the four files at review time (no automated test). | Persona-review §6 (this brainstorm) + plan-stage cross-check. |
| A-4 | AC#1/#6 grep is the canonical reviewer command; no separate CI gate is added. | Plan stage names the grep in the verification step. |

## 10. Persona review

This section will be filled in iteratively by the document-review skill.
Order: design → security → scope → coherence → product → feasibility.
Gate: ≥5/6 PASS AND zero feasibility P0.

### Iteration 1

#### Persona 1 — Design

**Verdict:** PASS

**Findings:**
- The decision lattice (D-1..D-6) cleanly separates terminology (D-1)
  from each file's edit shape (D-2..D-5) from the no-test policy
  (D-6). Each decision has a rejected alternative and a principle
  reference.
- The §5 Architecture table makes the "where code goes" mapping
  explicit even for a pure-prose change.
- The Open Question §8.1 surfaces the ticket-vs-AC#6 scope tension
  *as a planner-time decision* rather than hiding it or unilaterally
  resolving it — design-correct behavior for a brainstorm.
- D-2's "no §Concurrency H2 in README" decision correctly resists
  duplication; the rejected alternative is articulated.

No P0 / P1 findings.

#### Persona 2 — Security

**Verdict:** PASS

**Findings:**
- Pure documentation work. No new code paths; no env-var reads; no
  Linear/GitHub writes; no `claude -p` invocation surface; no
  allowlist change.
- The §5 architecture table confirms zero functional surface area.
- The emergency-rollback recipe (D-5) recommends `launchctl bootstrap`
  which is the standard mechanism documented in `CLAUDE.md` —
  no new privilege escalation, no new secret material in scope.
- The §Configuration example block addition does not expose any new
  secret-bearing field; `max_concurrent_features` is an integer, not
  a credential.

No P0 / P1 findings.

#### Persona 3 — Scope

**Verdict:** PASS (with one P2 observation)

**Findings:**
- Five files in scope, all in `README.md` + `docs/`. Matches AC#1–#5
  exactly.
- Out-of-scope list (§2) explicitly carves out `CLAUDE.md`,
  `architecture.md`, `install.md`, `operations.md`,
  `operator-mental-model.md`, `assumptions.md:120-134`,
  `docs/brainstorms/`, `docs/plans/`, `learned-rules/`.
- Open Question §8.1 flags the AC#6-vs-ticket scope tension *without
  silently expanding scope*. Decision deferred to plan stage with
  brainstorm's stance (recommend the fix; flag the tension) — this
  is the correct discipline.
- **P2 observation:** The §Examples block addition in
  `docs/configuration.md` ("Constrained concurrency (single-slot)")
  is technically additive (no AC line says "add a new example"),
  but it mirrors the existing pattern (every other `orchestrator.*`
  knob has at least one example block) and is documentation-cohesion
  work, not scope creep. Keep, but note in plan that this is the
  one not-strictly-mandated touch.

No P0 / P1 findings.

#### Persona 4 — Coherence

**Verdict:** PASS

**Findings:**
- D-1's terminology lock (`orchestrator.max_concurrent_features`,
  `CLAUDE_MAX_CONCURRENT`, "counting semaphore", no new "mutex"
  prose) propagates consistently across D-2..D-5's prose specs.
- Cross-link discipline (§8.3) is explicit: each file links back to
  `CLAUDE.md` § "Per-project dispatch concurrency" rather than
  duplicating. The "K vs canonical name" subtlety in §8.4 is
  resolved with a rule (symptom-level → "K"; knob-level → canonical).
- The five-block failure-modes template (D-4) matches the existing
  catalog convention verbatim.
- The H3 subsection shape (D-3) matches
  `### orchestrator.dispatch_timeout_minutes_per_stage`'s shape
  exactly.
- The schema example block update is internally consistent — the
  config sketch at the top of `configuration.md` (lines 33–52)
  matches the new H3 subsection's contract.

No P0 / P1 findings.

#### Persona 5 — Product

**Verdict:** PASS

**Findings:**
- The operator value is explicit: operators grep
  `docs/configuration.md` for `max_concurrent_features` and find
  the canonical reference (AC#3); they grep `runbooks/failure-modes.md`
  for `.in-flight.lock` and find the diagnostic (AC#4); they grep
  `runbooks/recovery.md` for rollback recipes and find the K=1
  recipe (AC#5).
- README touch (D-2) is appropriately minimal — README is the
  first-impression doc, not the operator manual, and the three
  one-line / one-sentence touches respect that.
- The dual role (per-tick dispatch cap AND WIP cap) is called out
  in D-3's subsection structure — this is the load-bearing mental
  model operators upgrading from pre-ENG-81 most often miss.
- Cost section (§8.5) is realistic: ~30–60 min, no risk, no test
  regression. Proportional to value.

No P0 / P1 findings.

#### Persona 6 — Feasibility (gating)

**Verdict:** PASS

**P0 findings:** None.

**Codebase-fact verification (per anti-bias check):**

- **README.md:30** — verified `"Team-shared CI / multi-operator setups (a global mutex serializes dispatch)"` (read inline above).
- **README.md:416** — verified `"Cross-tick concurrency is serialized via a global mutex; cross-machine concurrency is not supported."` (read inline above).
- **README.md:346–349** — verified `"Most operators only edit config.json for: per-stage dispatch timeouts… the dispatch.tools allowlist… entry-conditions"` (no `max_concurrent_features` mention).
- **`docs/configuration.md:92`** — verified `### orchestrator.dispatch_timeout_minutes_per_stage` heading (insertion-point anchor).
- **`docs/configuration.md:118`** — verified `### orchestrator.entry_conditions (ENG-86)` heading (insertion-point boundary).
- **`docs/configuration.md:33-52`** — verified the `config.json` schema block; insertion point for the schema example line ("max_concurrent_features": 2) is unambiguous.
- **`docs/runbooks/failure-modes.md:393`** — verified the boundary between "Brainstorm halts at iteration-exhausted" (ends ~393) and "scope-check halts on upstream merge files" (starts ~397) — clean insertion point.
- **`docs/runbooks/recovery.md`** tail — verified §"ENG-87 forensic asymmetry" section ends before §"Quick reference: env var requirement" (line ~641 in the 663-line file based on tail read).
- **`CLAUDE.md:623–671`** — verified §"Per-project dispatch concurrency" section exists with default-2, env-var precedence, emergency-rollback recipe, slot inspection command.
- **`CLAUDE.md:620–621`** — verified the two failure-mode rows the brainstorm cites (Concurrent dispatches not running; `.in-flight.lock` present).
- **`docs/architecture.md:161, :194, :197`** — verified the three live "global Claude mutex" prose occurrences underlying Open Question §8.1.
- **`docs/assumptions.md:135`** — verified the parenthetical "(the global mutex covers every project's dispatch)" underlying Open Question §8.1.
- **`docs/architecture.md:15-19, :345-366, :408, :414`** — verified the post-ENG-81 counting-semaphore prose at the ticket-listed correct ranges.
- **`docs/runbooks/operator-mental-model.md:20, :309-326`** — verified counting-semaphore prose at the ticket-listed correct ranges.

No code symbols are referenced (this is a pure prose ticket). The
plan-stage line-number re-verification (Assumption A-1) is the
backstop for any post-brainstorm drift.

**Feasibility addendum (post-iteration-1 codebase re-grep):**
Re-running `grep -rn 'global mutex' README.md docs/` during feasibility
re-verification surfaced three additional live-claim sites that the
ticket spec leaves uncategorized (`docs/security.md:20`,
`docs/cost.md:31`, `docs/cost.md:182`). These are NOT in the ticket's
"already correct (do not re-touch)" list, NOR in its stale-segments
list — the ticket is silent on them. §8.1's table and recommendation
were updated to enumerate all seven live-claim sites; §9 gained
verified row #23. **No P0 / P1 change:** the gap is a brainstorm
completeness improvement, not a re-classification of the work. The
planner has a complete picture; the implement-time scope discipline
discussed in §8.1 is unchanged (planner picks one path, documents it
in the plan doc).

**Gate status:** 6/6 PASS · feasibility P0: 0 · proceeding to planning.
