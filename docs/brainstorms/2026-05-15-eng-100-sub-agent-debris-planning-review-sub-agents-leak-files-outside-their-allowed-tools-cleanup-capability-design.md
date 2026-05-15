---
linear: ENG-100
title: sub-agent debris — orchestrator-side pre-partition cleanup for out-of-allowlist new paths, plus a prompt prohibition rule
date: 2026-05-15
status: draft
---

# Orchestrator-side debris cleanup — close the planning/review sub-agent self-leak halt class

## 1. Problem

A planning or other agent (directly, or via a document-review style
sub-agent it spawned to reason against a fixture) writes a temporary
file to the worktree root. The parent stage's `--allowed-tools`
allowlist does not include any delete capability (`Bash(rm:*)` is
deliberately out of scope — operator decision 2026-05-10), so the
parent cannot clean up the file before exiting. `partition_dirty_paths`
(`bin/run-local-helpers.sh:535`) then buckets the file as out-of-scope
(it is NEW since the tick-start snapshot), `halt_issue_for_self_leak`
(`bin/run-local-helpers.sh:128`) fires, `pipeline:halted` +
`pipeline:skip-until-human-acts` are applied, and the legitimate stage
output (the plan doc) is **NOT** auto-committed because precedence
puts self-leak ahead of in-scope-commit (`bin/run-local.sh:260-273`).
Operator must `rm <path>` + `bash bin/pipeline.sh decide ENG-N
--action continue` to recover.

### 1.1 Observed instance — ENG-93 (2026-05-10)

[ENG-93](https://linear.app/twinning/issue/ENG-93/extend-project-profile-schema-with-stage-aware-tool-declarations)
planning halted with `self-leak: 1 bot-introduced out-of-scope path(s);
leaked hashes: d240545ee47d`. The feasibility reviewer wrote
`awk-test-input.txt` (293 B) to the worktree root for an awk-regex
sanity check on the proposed v2 schema regex. Plan itself was clean
(5/5 personas PASS, 0 P0). The plan agent emitted a heads-up Linear
comment predicting the halt and documenting the recovery — but could
not avoid it (no delete tool).

### 1.2 Why this is a class, not a one-off

- `planning`'s `--allowed-tools` is `Read,Write,Edit,Grep,Glob,
  TaskCreate,Bash(git log:*),Bash(git diff:*),Bash(bash bin/linear.sh:*),
  Bash(bash bin/pipeline.sh:*)` (`bin/dispatch.sh:396`). No `rm`.
- `brainstorming` is similarly stripped (`bin/dispatch.sh:395`).
- Document-review and similar reasoning flows are explicitly designed
  to scratch-write while iterating on a regex / parser / flow against
  a fixture. Any sub-agent that wants to "verify the awk pattern
  before recommending it" is at risk.
- The only currently sanctioned scratch carve-out is `.scratch/*`
  (`bin/run-local-helpers.sh:583-587`), gated to `implementing | ui
  | qa` only. Brainstorming/planning are explicitly excluded for
  state-injection-vector reasons (D-004 issue-id constraint). Read-
  mostly stages (`reviewing | building | released`) already get a
  post-partition auto-clean via `clean_self_leak_residue`
  (`bin/run-local-helpers.sh:215`). The remaining gap is the
  brainstorming/planning halt path — exactly where ENG-93 fired.

### 1.3 Common root cause

The harness has two layers that should normally collaborate to
prevent debris from halting an issue:

1. **Agent-side compliance.** The prompt's `--allowed-tools` plus
   §0 preamble rules tell the agent what it MAY write. Today's §0
   names only one specific class (Linear comment helpers — `.review-
   body.md`, `.qa-pr-comment.md`, AGENT_PROMPTS.md:223). It does
   NOT tell sub-agents not to write fixture files.
2. **Orchestrator-side enforcement.** `partition_dirty_paths` is the
   chokepoint that classifies dirty paths. For two of the stage
   buckets it auto-cleans residue (`reviewing | building | released`
   via `stage_is_read_mostly`/`clean_self_leak_residue`); for the
   other three (`implementing | ui | qa`) it halts on self-leak; for
   the brainstorm/plan stages it also halts. But the operator's
   2026-05-10 decision — "we are NEVER going to grant `Bash(rm:*)`
   to agents" — means the agent can never clean up after itself, so
   the halt path is the wrong-default in cases where the residue is
   meaning-free scratch.

The cheapest closure is to **broaden the orchestrator-side auto-clean
from "read-mostly stages only" to "every stage where self-leak would
otherwise halt"**, paired with a §0 prompt rule that pre-empts
debris generation. The detective backstop (transcript scan) is the
defense-in-depth: it lets retrospectives surface agents that
*should* have known better, even when the cleanup pass hid the
operator-visible symptom.

## 2. Goal

1. **G-1 (no operator toil on debris).** A planning or brainstorm
   dispatch where a sub-agent writes a scratch file outside the
   stage's output allowlist completes WITHOUT triggering
   `halt_issue_for_self_leak` on a clean stage output. The
   legitimate stage output (the plan doc / brainstorm doc) is
   auto-committed and pushed normally.
2. **G-2 (no security expansion at agent layer).** Cleanup happens
   under orchestrator privileges, never inside the agent's
   `--allowed-tools` boundary. No new agent-callable delete patterns.
3. **G-3 (snapshot-respecting).** Cleanup deletes only files NEW
   since the tick-start snapshot AND outside the stage's output
   allowlist. Operator's pre-existing in-progress edits
   (`observed`) and legitimate stage outputs (in-scope) are never
   touched.
4. **G-4 (forensic audit preserved).** Every cleaned path produces
   a metric event with sha12 hashes so the retrospective can
   reconstruct what was wiped. Path strings stay out of Linear
   comments (adversarial-filename discipline, matches the
   existing `halt_issue_for_self_leak`/`clean_self_leak_residue`
   contract).
5. **G-5 (prompt-side prevention).** §0 preamble of `AGENT_PROMPTS.md`
   carries an explicit prohibition: "do not write fixture files,
   scratch text, or test inputs outside the per-stage output
   allowlist; reason inline." Pinned by
   `bin/agent-prompts-content-test.sh`.

## 3. Non-goals

- **N-1.** Granting any form of `Bash(rm:*)` to any stage. Operator
  decision 2026-05-10 — out of scope.
- **N-2.** Reframing `pipeline:halted` semantics for the broader
  self-leak class. The `implementing | ui | qa` stages still halt on
  self-leak (those stages have real production-path write potential
  — e.g., agent edits `bin/run-local.sh` then writes a scratch test
  fixture; halt is the operator signal that "this stage's output
  needs eyes"). Brainstorming and planning have docs-only outputs
  by contract, so debris there is structurally distinguishable.
  Discussion at §6.4 / D-002.
- **N-3.** Detective-only enforcement (Option A alone). The
  observed-instance class is "agent already wrote the file, no way
  to clean it" — a pure prompt-side rule is best-effort and does
  not close the structural gap that the operator-decision left
  open.
- **N-4.** Changing `partition_dirty_paths`'s classification logic.
  The new cleanup pass operates on the SAME path lists partition
  emits; the only change is what we DO with the self-leak bucket
  (clean vs halt) per stage.
- **N-5.** Cross-dispatch persistence (`.scratch/*` carve-out, the
  pre-existing `clean_scratch_dir` (`bin/run-local-helpers.sh:310`)).
  That hazard is closed by ENG-87's tick-end stage-agnostic
  `.scratch/` cleanup. This design touches files that ARE visible
  to `git status --porcelain`, which is a different surface.

## 4. Architecture

The contract has one glue (the existing snapshot diff +
`partition_dirty_paths` three-stream output) and two changes:

### 4.1 Glue: where the cleanup runs

```
T0  agent exits run-stage.sh ──┐
                                │
T1  clean_scratch_dir           │  (existing, ENG-87, unchanged)
                                │
T2  route_run_stage_exit        │  (existing, ENG-69, unchanged)
       └─ rc-gate; if rc != 0, return rc (existing)
                                │
T3  git status -z --porcelain  ─┤
       │                        │
       ├─ partition_dirty_paths │  (existing, three streams)
       │   FD3=in-scope         │
       │   FD4=leaked-in-scope  │
       │   FD5=out-of-scope     │
       │                        │
T4  observed-vs-self-leak split │  (existing inline in run-local.sh)
       │   observed_buckets[]   │
       │   self_leak_paths[]    │   (= NEW since tick-start AND
       │   self_leak_hashes[]   │      outside allowlist)
       │                        │
T5  ── NEW: route self-leak ────┤
       │                        │
       │   if stage in          │
       │   { brainstorming,     │
       │     planning,          │
       │     reviewing,         │
       │     building,          │
       │     released }:        │
       │     clean_self_leak_   │
       │       residue (extant) │   path-by-path: tracked → git
       │                        │   checkout --; untracked → rm -rf
       │   else                 │
       │   { implementing, ui,  │
       │     qa }:              │
       │     halt_issue_for_    │
       │       self_leak        │   (unchanged for prod-path stages)
       │                        │
T6  leaked-in-scope tally       │  (existing; not changed)
       │                        │
T7  in-scope commit + push      │  (existing; now reachable for
                                    brainstorm/plan even when a
                                    sub-agent left debris behind)
```

The only structural shift is at T5: the gate that today reads
`if stage_is_read_mostly "$stage"` becomes broader. The cleanup
helper itself (`clean_self_leak_residue`) needs only one change
— remove the hard-coded refusal-on-main-or-detached check ONLY
if a feature branch is in use (it already does this — see
`bin/run-local-helpers.sh:232-238`), and accept the broader stage
list. No new helper is required.

### 4.2 The mechanism: extend `stage_is_read_mostly`'s callsite

Today (`bin/run-local.sh:262-273`):

```bash
if (( ${#self_leak_hashes[@]} > 0 )); then
  if stage_is_read_mostly "$stage"; then
    clean_self_leak_residue "$issue_id" "$stage" "$dispatch_cwd" "${self_leak_paths[@]}"
  else
    halt_issue_for_self_leak "$issue_id" "$stage" "${self_leak_hashes[@]}"
    ...
  fi
fi
```

After:

```bash
if (( ${#self_leak_hashes[@]} > 0 )); then
  if stage_auto_cleans_self_leak "$stage"; then
    clean_self_leak_residue "$issue_id" "$stage" "$dispatch_cwd" "${self_leak_paths[@]}"
  else
    halt_issue_for_self_leak "$issue_id" "$stage" "${self_leak_hashes[@]}"
    ...
  fi
fi
```

A new predicate `stage_auto_cleans_self_leak` in `bin/run-local-
helpers.sh` returns 0 for `brainstorming | planning | reviewing |
building | released` and 1 for `implementing | ui | qa`. The
predicate is a superset of `stage_is_read_mostly` — it adds the
two doc-writing stages to the auto-clean lane. Naming choice:
"auto-cleans-self-leak" expresses the contract directly rather
than naming an unrelated property (read-mostly).

`stage_is_read_mostly` is preserved as-is — it is the source of
truth for "stage has no legitimate worktree writes" and is grep-
pinned by tests. The new predicate is a *callsite-side* gate; it
does NOT change `stage_is_read_mostly`'s semantics.

### 4.3 The metric

`clean_self_leak_residue` already emits a
`sweep-readonly-residue-cleaned` metric with `count`, `branch`,
`hashes`, `rm_fail`, `checkout_fail`. The metric name is now a
mild misnomer ("readonly-residue" → broader "debris on a
stage where halt is the wrong default"), but renaming would
churn the retrospective's §1 filter and existing tests.
Decision: keep the metric name, document the broadened scope
in `clean_self_leak_residue`'s docstring. The retrospective
§1 filter currently does not branch on this metric; widening
the emitter does not require a filter edit.

### 4.4 The prompt rule

Append a one-paragraph rule to §0 (Common rules) in
`AGENT_PROMPTS.md`, alongside the existing scratch-file rule for
Linear helpers (line 223):

> **Sub-agent debris (ENG-100):** Do NOT write fixture files,
> scratch text, test inputs, or any other file outside the
> per-stage output allowlist — not even to verify a regex or
> parse a payload before recommending it. Reason about the
> pattern inline (mental simulation, or pipe via stdin to
> `awk`/`sed` heredocs where the stage allows Bash). Sub-agents
> dispatched via the `Agent` tool inherit the same constraint.
> If you absolutely cannot reason about the pattern without a
> file, halt with `verdict halt --reason agent-blocked` and
> describe what you needed — the operator will fix the
> ergonomic gap. The orchestrator's tick-end cleanup will
> remove debris regardless, but a transcript-scan detective
> may flag the violation for retrospective review.

`bin/agent-prompts-content-test.sh` pins a `Sub-agent debris`
phrase + the operator-recognition word `agent-blocked` survive
the §0 render.

### 4.5 The detective (stretch)

Mirror `bin/dispatch.sh:150-184`'s shape for ENG-43 and ENG-66.
Add a transcript scan after `_render_and_capture_stream` returns,
checking every `Write` tool's `file_path` against the stage's
output allowlist (reusing `stage_output_paths` for the allowlist
source — D-005). On match, emit a metric `dispatch-debris-write`
with the offending path's sha12. Do NOT halt — the orchestrator
cleanup already covers the structural fix; the detective is
forensic.

`assert_no_tool_invocation` is the existing primitive but it
matches on `Bash` `tool_use.input.command` startswith. The new
check is shape-different: a `Write` `tool_use` whose `input.
file_path` is not on the allowlist. A small companion helper
`assert_no_write_outside_allowlist` (sibling pattern, ~20 lines
of jq + bash) goes in `bin/common.sh`. Behind a feature flag in
`config.json::dispatch.debris_detective` (default off) for one
release cycle so the metric is observed before any retrospective
rule references it.

## 5. Decisions

### D-001 — Pre-partition cleanup vs post-partition route broadening

**Decision:** Route self-leak through `clean_self_leak_residue`
for `brainstorming | planning` stages after partition, instead
of a separate pre-partition cleanup pass.

**Rationale.** Pre-partition cleanup would need a parallel
allowlist enumeration (duplicate `stage_output_paths` calls) and
a parallel snapshot lookup. Post-partition routing reuses every
existing primitive: partition has already done the
classification, `observed-vs-self-leak` already distinguishes
operator-edited paths from agent-introduced ones, the snapshot
file is already mmap'd. The change collapses to a one-line
predicate swap (`stage_is_read_mostly` →
`stage_auto_cleans_self_leak`) at one call site.

**Rejected alternative — pre-partition cleanup.** Would require
a new helper to compute "new since tick-start AND outside
allowlist" outside partition. That logic exists today only as a
side effect of partition's stream emission +
`observed-vs-self-leak` inline split (`bin/run-local.sh:239-258`).
Re-implementing it pre-partition would either duplicate code or
require a refactor that pulls the snapshot comparison into
partition itself — both larger surface than the ticket asks for.

**Principle.** "Don't add features, refactor, or introduce
abstractions beyond what the task requires" (`CLAUDE.md` —
Doing tasks).

### D-002 — Why `implementing | ui | qa` still halt

**Decision:** Keep `halt_issue_for_self_leak` as the default for
`implementing | ui | qa`. Do NOT extend auto-clean to those
stages.

**Rationale.** On `implementing`, an agent has Write to
production paths (e.g., `bin/run-local.sh`). If a self-leak
fires, the path is BOTH outside the project profile's `## File
layout` AND new — which is precisely the signature of an agent
that has gone off-piste. Auto-cleaning would silently discard
agent intent. Halt-and-ask-the-operator is the correct
behaviour. The same logic applies to UI and QA.

`brainstorming | planning` are different by contract: their
allowlist is docs-only. A self-leak there is by definition NOT
a production-path write (that would be in-scope or leaked-in-
scope, both already handled). It is, by elimination, scratch
or auxiliary debris — exactly the class the operator decision
identifies as not-worth-halting-on.

**Rejected alternative — auto-clean all stages.** Would lose
the implement-stage halt signal. The operator's mental model is
"halt fires when the agent did something it should not have."
Cleaning every implement-stage self-leak would silently swallow
real bugs (agent writes `target/release/binary` then forgets to
add it to `.gitignore`; agent edits a sibling crate's `Cargo.
toml`). Halt-then-decide remains the right contract for
production-touching stages.

**Principle.** Failure-mode quick reference (CLAUDE.md): "Self-
leak halts only fire on `implementing | ui | qa`; on
`reviewing | building | released`, `clean_self_leak_residue`
auto-cleans (check `sweep-readonly-residue-cleaned` metric)."
Extending to brainstorm/plan respects the same contract shape:
docs-only stages collapse onto the auto-clean side; production-
touching stages stay on the halt side.

### D-003 — Cleanup mechanic: reuse `clean_self_leak_residue` per-path strategy

**Decision:** Reuse the existing `clean_self_leak_residue` helper
unchanged. Per-path: tracked-modified → `git checkout --`;
untracked → `rm -rf "$worktree/$p"`.

**Rationale.** `git clean -df` (mentioned in the Linear issue's
Option B sketch) is more aggressive than necessary and has a
subtle hazard: it deletes ALL untracked files, including any
that partition's allowlist would have marked in-scope but that
the agent neglected to git-add. Per-path classification respects
partition's already-computed verdict — paths in FD5 are exactly
what we want to clean; paths in FD3 are auto-committed; paths
in FD4 are tallied for leaked-in-scope tracking. The existing
helper already implements this exact strategy and is grep-pinned
by `bin/run-local-helpers-adversarial-test.sh`.

**Rejected alternative — `git clean -df` blanket pass.** Risk:
silently deletes legitimate-but-unstaged output (e.g., an agent
wrote `docs/brainstorms/foo.md` correctly but never staged it,
and partition would have committed it — `git clean -df` would
nuke it before commit). The per-path lane already restricts
deletions to FD5 paths, sidestepping the risk entirely.

**Principle.** D-003 (operator-decision asymmetry): cleanup is
allowed; data loss is not.

### D-004 — Naming: `stage_auto_cleans_self_leak` vs renaming `stage_is_read_mostly`

**Decision:** Add a new predicate `stage_auto_cleans_self_leak`
in `bin/run-local-helpers.sh`. Do NOT rename or repurpose
`stage_is_read_mostly`.

**Rationale.** `stage_is_read_mostly` is the canonical predicate
for "stage has no legitimate worktree writes" and is grep-
pinned by `bin/run-local-helpers-adversarial-test.sh` (anchor
#5, per the file's documentation). It is also the gate
`partition_dirty_paths`'s read-only branch uses to choose
empty `stage_output_paths` output. Renaming would force a
test-pin update + a function-rename in helpers; safer to add a
sibling predicate that captures the gate's intent precisely.
The two predicates ARE related (`stage_auto_cleans_self_leak`
returns true for the union of `stage_is_read_mostly` + `{
brainstorming, planning }`), but each names a distinct concept.

**Rejected alternative — extend `stage_is_read_mostly` to
return true for brainstorm/plan.** Would lie about
"brainstorming is read-mostly" — it ISN'T (it writes
`docs/brainstorms/*` and `docs/knowledge/decisions.md`). A
predicate's name must not lie about the system. `partition_
dirty_paths` callers depend on `stage_is_read_mostly` to mean
exactly what it says.

**Principle.** Don't conflate concepts to save a function name
(`CLAUDE.md` — predicate naming hygiene).

### D-005 — Detective behind a feature flag, default off

**Decision:** Ship the transcript-scan detective behind
`config.json::dispatch.debris_detective` (boolean, default
false). Wire the call into `bin/dispatch.sh` after
`_render_and_capture_stream` returns. When the flag is true,
emit a metric `dispatch-debris-write` per offending path; never
halt.

**Rationale.** The cleanup pass (D-001) is the structural fix —
operator toil is eliminated regardless of detective output. The
detective's job is forensic: surface "this agent's prompt
needs an update because it keeps writing debris" to the
retrospective. Behind-a-flag-default-off means we ship the
structural change without risking false-positive halts on
edge-case `Write` invocations the harness has not yet observed
(e.g., a stage that legitimately writes outside the static
allowlist via the operator-curated `config.json::scope.
allowlist.<stage>[]` override — D-007).

**Rejected alternative — ship detective on by default.** The
metric would emit for every stage's stage-summary write
(`stage-summary-<stage>.md` lives in `$(issue_dir)`, not the
worktree — but only by convention, and a misconfigured stage
could write the summary to the worktree by accident; the
detective would false-positive). Better to observe the metric
for a release first.

**Rejected alternative — skip the detective entirely.** ENG-93
shows the failure shape is recurring; we want a way to flag
the trend during retrospective. The metric is cheap (one jq
query per dispatch) and the flag-gated rollout is low-risk.

**Principle.** Defense-in-depth on top of tool-lane denials
(CLAUDE.md). The detective is the second line; cleanup is the
first.

### D-006 — Snapshot freshness is load-bearing

**Decision:** The cleanup helper continues to rely on the
tick-start snapshot (`snapshot_file`, `bin/run-local.sh:184`)
as the discriminator between "operator's pre-existing edit"
and "agent-introduced debris". No change.

**Rationale.** The snapshot is captured BEFORE the agent runs,
captures only paths visible to `git status --porcelain`, and
is consumed by the partition pipeline (`bin/run-local.sh:239-
258`). The cleanup helper receives `self_leak_paths` which
the calling code has already filtered to "out-of-scope AND
NOT in snapshot." There is no way for an operator's pre-
existing edit to reach `clean_self_leak_residue` through this
path.

**Principle.** Defense-in-depth: even if the snapshot is
somehow corrupt, the per-path strategy uses `git ls-files
--error-unmatch` to distinguish tracked vs untracked. A
tracked path gets `git checkout --` (which is reversible via
the reflog); an untracked path gets `rm -rf`. The reflog
protects the worst case.

### D-007 — Operator override (`config.json::scope.allowlist`) compatibility

**Decision:** Cleanup respects the resolved per-stage output
allowlist — operator override wins absolutely, then profile-
derived File-layout list + always-include catalog (per
ENG-95 D-004). The new cleanup site simply consumes whatever
`stage_output_paths` emits; no parallel allowlist plumbing.

**Rationale.** The operator override exists exactly so an
operator can broaden the allowlist for a per-target one-off.
A cleanup pass that ignored the override would delete files
the operator just whitelisted. By routing through
`stage_output_paths` (consumed indirectly via partition's
classification), cleanup respects the override automatically.

**Principle.** Single source of truth — allowlist is computed
once per stage, consumed by both partition and cleanup.

### D-008 — Prompt rule scope: §0 vs per-stage

**Decision:** Add the rule to §0 (Common rules) as a single
phrase. Do NOT inline copies in §§1-7.

**Rationale.** §0 is the canonical single-source for rules
delivered to every stage (`AGENT_PROMPTS.md:212`). The
existing scratch-file rule (§0's "Tool allowlist & probing"
paragraph) already covers the Linear helper case; the new
rule extends the pattern. Per-stage inlining would drift —
the existing scratch-file rule's history shows agents wrote
the same scratch-file workaround across stages because the
rule was duplicated and stages drifted.

**Principle.** "Edit it once here when a rule applies
uniformly to all stages — do NOT inline copies in §§1-9"
(`AGENT_PROMPTS.md:215-217`).

## 6. Architecture details

### 6.1 Code touchpoints

| File | Change |
|---|---|
| `bin/run-local-helpers.sh` | Add `stage_auto_cleans_self_leak()` predicate. Update `clean_self_leak_residue` docstring to reflect broader scope. |
| `bin/run-local.sh` | One-line predicate swap at `bin/run-local.sh:263` (`stage_is_read_mostly` → `stage_auto_cleans_self_leak`). |
| `AGENT_PROMPTS.md` | Append `Sub-agent debris (ENG-100)` paragraph to §0's fenced block. |
| `bin/agent-prompts-content-test.sh` | Add phrase-pin assertions for the new §0 rule (mirrors the existing ENG-55 / ENG-57 / ENG-74 / ENG-87 pin shapes). |
| `bin/run-local-sweep-test.sh` | Add fixture: planning dispatch + sub-agent writes `awk-test-input.txt` at worktree root + clean plan output → expect no halt, expect plan doc auto-committed. (See §6.5 for the exact fixture.) |
| `bin/run-local-helpers-adversarial-test.sh` | Add adversarial fixture: cleanup must NOT delete files in the output allowlist NOR files in tick-start snapshot. |
| `bin/common.sh` *(stretch)* | Add `assert_no_write_outside_allowlist` helper for D-005 detective. |
| `bin/dispatch.sh` *(stretch)* | Call the new detective when `config.json::dispatch.debris_detective` is true. |
| `docs/architecture.md` | Append a paragraph to `## Sweep + scope partition (ENG-14)` describing the broadened auto-clean scope. |
| `docs/knowledge/decisions.md` *(if it exists at implement time)* | Append the proposed ADR for D-001 + D-002. |

### 6.2 Failure modes routed through `clean_self_leak_residue`

After this change, the helper handles five stages instead of
three. The per-path strategy is identical. Defensive guards
already in the helper (empty/missing-worktree/main-or-master/
dry-run no-op) all still apply unchanged. Branch check is the
critical one — the helper refuses to operate on `main` /
`master` / detached HEAD (`bin/run-local-helpers.sh:232-238`),
so a misconfigured caller cannot data-loss the operator's
main checkout.

### 6.3 Metric and audit trail

The existing `sweep-readonly-residue-cleaned` metric emits:

```
sweep-readonly-residue-cleaned <issue> <stage> cleaned 0 \
  count=<N> branch=<feature/...> hashes=<sha12,...> \
  rm_fail=<count> checkout_fail=<count>
```

The retrospective's §1 filter classifies by metric name; no
filter change is required. Operators inspecting "what was
cleaned during ENG-X's planning dispatch" can grep
`events.jsonl` for the issue + stage + metric name. The
metric name is now slightly misleading (the helper is no
longer only invoked for "read-mostly" stages), but renaming
would churn three downstream consumers (filter, tests, and
the `bin/status.sh` red/yellow predicate) for cosmetic gain;
documenting the broadened scope in the helper's docstring is
sufficient.

### 6.4 What about leaked-in-scope?

`tally_leaked_in_scope_failure` (`bin/run-local-helpers.sh:341`)
still fires for any FD4 path (in-scope-directory but failing
D-004 issue-id or other check). This design touches FD5
(out-of-scope) only. The two streams are independent — a
brainstorm that writes both a correctly-named brainstorm doc
(FD3) AND a wrong-issue-id brainstorm doc (FD4) still
increments the per-issue counter for FD4. Leaked-in-scope is
not auto-cleaned because it lives inside the allowlist
directory; the failure mode is "agent confused about which
issue's doc to write," which is a different class than "agent
wrote scratch."

### 6.5 Test fixture for AC-3

The Linear issue's AC-3 names the ENG-93 shape directly: "sub-
agent writes `awk-test-input.txt` at worktree root during a
planning dispatch with clean plan output." The fixture lives
in `bin/run-local-sweep-test.sh` and uses the existing
`assert_partition` helper. Pseudo-shape:

```bash
# AC-ENG-100-PLAN-DEBRIS — planning dispatch with sub-agent debris
# at worktree root. Plan doc is in-scope; awk-test-input.txt is
# out-of-scope (new since tick-start). Expect partition to emit
# 1 in-scope, 0 leaked, 1 observed-or-self-leak. The observed-vs-
# self-leak split lives in run-local.sh's main body and isn't
# directly under partition's responsibility — but we DO assert
# that stage_auto_cleans_self_leak returns 0 for "planning".
printf '?? docs/plans/2026-05-15-eng-100-foo.md\0?? awk-test-input.txt\0' \
  | assert_partition plan_with_sub_agent_debris planning ENG-100 1 0 1

if stage_auto_cleans_self_leak planning; then
  ok "stage_auto_cleans_self_leak: planning is in the auto-clean lane"
else
  nope "stage_auto_cleans_self_leak: planning" \
       "expected planning to auto-clean self-leak residue"
fi

if stage_auto_cleans_self_leak implementing; then
  nope "stage_auto_cleans_self_leak: implementing" \
       "implementing should NOT auto-clean; halt-on-self-leak is the contract"
else
  ok "stage_auto_cleans_self_leak: implementing stays on halt lane"
fi
```

Adversarial fixture (`bin/run-local-helpers-adversarial-test.sh`):

```bash
# AC-ENG-100-CLEAN-RESPECTS-SNAPSHOT — operator-edited path that
# happens to be out-of-scope is NEVER passed to clean_self_leak_
# residue because run-local.sh's observed-vs-self-leak split has
# already filtered it. Construct a worktree where:
#   - tick-start snapshot contains "operator-edit.txt"
#   - tick-end git status shows "operator-edit.txt" AND "agent-scratch.txt"
# Expect: only "agent-scratch.txt" reaches self_leak_paths; the
# operator's edit stays in observed_buckets and is never touched.

# AC-ENG-100-CLEAN-RESPECTS-ALLOWLIST — planning dispatch writes BOTH
# docs/plans/2026-05-15-eng-100-foo.md (in-scope) AND scratch.txt
# (out-of-scope). After cleanup, the plan doc still exists; scratch.txt
# is gone.
```

### 6.6 ADR pressure check

| ADR | Pressure | Resolution |
|---|---|---|
| ENG-69 (per-issue counter; self-leak halt) | Self-leak halt becomes unreachable for brainstorm/plan. Per-issue counter still operates on FD4 (leaked-in-scope) and rc != 0 paths. | No conflict — the counter's role is preserved on the stages where it matters. |
| ENG-87 (cross-dispatch staleness; `dispatch_id`) | None — cleanup runs intra-dispatch, before the envelope validator. | No conflict. |
| ENG-94/95/96 (profile-derived consumers; soft-fail) | The cleanup helper indirectly depends on `stage_output_paths`'s output (via partition). If the profile is missing, partition falls back to docs/ + lockfile catalog; cleanup operates on whatever partition emits. | No conflict — fall-back is structurally consistent. |
| Operator decision 2026-05-10 (no `Bash(rm:*)` for agents) | The structural fix sits at the orchestrator layer, never inside agent tools. | Direct alignment. |
| ENG-14 (sweep + scope partition; halt on self-leak) | This brainstorm narrows the halt contract from "all stages except read-mostly" to "implementing | ui | qa only." The original ENG-14 framing of "agent went off-piste → halt" is preserved for stages with production-path write potential, but relaxed for docs-only stages. | Mild ADR pressure: ENG-14's reader naturally expects all non-read-mostly stages to halt. Documented in this brainstorm as a deliberate scope narrowing. |

## 7. Data flow

```
agent in dispatch ─→ writes:
                    │  docs/plans/2026-05-15-eng-100-foo.md  (in-scope)
                    │  awk-test-input.txt                    (out-of-scope; new)
                    │  docs/architecture.md                  (operator pre-edit; observed)
                    ▼
run-stage.sh exits rc=0
                    ▼
clean_scratch_dir (existing) — no-op (no .scratch/)
                    ▼
route_run_stage_exit (rc=0 — clears counters)
                    ▼
git status -z --porcelain | partition_dirty_paths planning ENG-100
                    FD3: docs/plans/2026-05-15-eng-100-foo.md
                    FD4: (empty)
                    FD5: awk-test-input.txt, docs/architecture.md
                    ▼
observed-vs-self-leak split using snapshot
                    observed_buckets: ["docs/"]  (architecture.md was in snapshot)
                    self_leak_paths: ["awk-test-input.txt"]
                    ▼
if stage_auto_cleans_self_leak planning:  ←── CHANGED: was stage_is_read_mostly
   clean_self_leak_residue ENG-100 planning <worktree> awk-test-input.txt
       → rm -rf <worktree>/awk-test-input.txt
       → emit sweep-readonly-residue-cleaned metric
                    ▼
in-scope commit + push
   git add docs/plans/2026-05-15-eng-100-foo.md
   git commit -m "chore(pipeline): planning for ENG-100"
   git push -u origin HEAD
                    ▼
observed bucket metric emit (docs/ — info only)
                    ▼
worker end (success)
```

The legitimate output lands on origin; the debris is wiped;
the operator sees no halt comment; the retrospective sees a
`sweep-readonly-residue-cleaned` metric naming the offending
hashes.

## 8. Error handling

| Failure mode | Detection | Behaviour |
|---|---|---|
| Cleanup partial failure (rm -rf or git checkout returns nonzero on a subset of paths) | `clean_self_leak_residue` per-path rc count | Helper emits the metric with `rm_fail` / `checkout_fail` populated, logs the partial failure, returns 0. Next tick's partition sweep will catch any survivors. |
| Worktree on `main` / `master` / detached HEAD at cleanup time | `git -C "$worktree" branch --show-current` check | Helper refuses (logs "defensive refuse"), returns 0. The data-loss risk is non-zero on `main` — refusing is the safer default. (Already in place.) |
| Worktree path missing / not a git repo | `[[ -d "$worktree" ]]` + `git rev-parse --show-toplevel` | Helper logs + returns 0. Cleanup is a side effect of partition; partition itself runs only when the worktree is valid. |
| Snapshot file corrupt or missing | Snapshot file is created within `_run_worker` before agent dispatches; an absent file would have already failed earlier classification | The observed-vs-self-leak split (`bin/run-local.sh:243-251`) calls `grep -qxF -- "$p" "$snapshot_file"`. A missing snapshot file makes grep fail for every path → every out-of-scope path classifies as self-leak. Cleanup then deletes the lot. This is degraded but not catastrophic: anything legitimately pre-existing (operator's edits) would still be filtered by partition's `case "$path" in ...` allowlist match (FD3/FD4 carve-out happens BEFORE the snapshot lookup). The worst case is "we clean a path the operator was editing AND that was outside the allowlist" — which would have halted the issue pre-fix anyway. |
| Dry-run mode | `PIPELINE_DRY_RUN=1` early return in `clean_self_leak_residue` | Helper logs `[DRY_RUN] auto-clean: ...` and returns 0. No FS mutation. |
| Detective (D-005, stretch) jq parse failure | jq error rc | Detective fails open; metric not emitted; no halt. Detective is forensic, not control flow. |

## 9. Edge cases

### 9.1 Brainstorm writes a P0 fix plus debris

Agent writes `docs/brainstorms/2026-05-15-eng-100-foo-design.md`
(in-scope, FD3) AND `notes-to-self.md` (out-of-scope, FD5).
Plan doc commits; `notes-to-self.md` is cleaned. No operator
visibility unless they inspect the metric stream. **Acceptable** —
the operator's mental model is "the brainstorm doc is the
artifact; everything else is the agent's working memory."

### 9.2 Brainstorm writes ONLY debris (no in-scope output)

Agent writes only `scratch.txt` and no brainstorm doc.
Partition emits 0 in-scope, 0 leaked, 1 out-of-scope. Self-leak
cleans `scratch.txt`. No commit happens (nothing to commit).
Stage-summary file (`stage-summary-brainstorming.md` in
`$(issue_dir)`, not the worktree) is written by the agent's
final `Write` call and consumed by `post_completion_comment`.
Operator sees the stage-summary post but no committed
artifact. **Acceptable** — the lack of a brainstorm doc is its
own signal; the operator can inspect the stage summary and
re-dispatch. Without auto-clean, this case would have halted
with `self-leak` AND no stage summary posted — so this is
strictly better than the status quo.

### 9.3 Planning writes debris on a re-dispatch (loopback path)

After a `verdict fail target=planning` from review, the plan
agent re-dispatches. Tick-start snapshot captures the prior
plan doc (still on disk). Agent rewrites the plan + drops a
scratch fixture. Partition sees: prior plan in FD3 (matched
allowlist), new scratch in FD5. Self-leak path applies;
scratch is cleaned. Plan doc is auto-committed (it has
modifications). **Acceptable** — same control flow as the
clean-tick case.

### 9.4 Sub-agent writes a binary blob (e.g., a compiled artifact)

`rm -rf "$worktree/$p"` handles any file shape including
binary blobs. The metric carries only the path's sha12 — the
content is not exfiltrated. **Acceptable.**

### 9.5 Sub-agent writes to `.scratch/foo`

Already covered by `clean_scratch_dir` (ENG-87) for stage-
agnostic tick-end cleanup. For `implementing | ui | qa` the
`.scratch/*` carve-out makes the write invisible to partition.
For `brainstorming | planning` the carve-out doesn't apply, so
`.scratch/foo` reaches partition as out-of-scope; the new
cleanup pass handles it. **Acceptable** — both layers
collaborate.

### 9.6 Agent symlinks debris into the worktree

`rm -rf` follows the symlink only for the path itself, not the
target. A `ln -s /etc/passwd evil.txt` would result in
`rm -rf "$worktree/evil.txt"` — which removes the symlink
itself, not `/etc/passwd`. **Acceptable.** (Bash `rm -rf
<symlink>` does not traverse the symlink. Verified via
`man rm`.)

### 9.7 Operator's `config.json::scope.allowlist.planning` adds a custom path

The operator broadens planning's allowlist to include
`docs/custom-planning-artifacts/`. Agent writes
`docs/custom-planning-artifacts/foo.md` (now in-scope, FD3).
Cleanup does not touch it. **Acceptable** — operator override
is respected (D-007).

### 9.8 ENG-86 wait-exit / scope-approval-replay path

`_validate_dispatch_envelope` (ENG-87) skips on wait-exit /
scope-approval-replay. The new cleanup runs in `_run_worker`
AFTER `route_run_stage_exit` already returned for nonzero rc.
For wait-exit (rc=0 but `wait-<stage>.json` present), the
partition pipeline still executes. **Open question:** does a
wait-exit dispatch leave debris that the partition would
classify as self-leak? Inspection of `_handle_wait`
(`bin/run-stage.sh:489-545`) suggests no — wait-exit clears
the stage-summary file but does not touch the worktree. If a
wait dispatch did somehow leave debris, the cleanup would
handle it correctly. **Acceptable** — no special-casing
needed.

## 10. Open questions

1. **OQ-1.** Should the detective (D-005) ever halt, or always
   stay forensic? Today's stance: forensic-only; the structural
   fix is the cleanup pass. Re-evaluate after one release of
   metric data — if the detective fires on >5% of dispatches,
   the prompt rule may need strengthening (or the agent's
   training data may need a retrospective rule).
2. **OQ-2.** Does the metric name `sweep-readonly-residue-
   cleaned` need a rename? Argument for: "readonly-residue" is
   misleading once brainstorm/plan use it. Argument against:
   tests, retrospective filters, and `bin/status.sh` consume
   the name. Decision in this brainstorm: keep the name,
   document the broadened scope. Revisit if a future ticket
   wants the name to match the contract.
3. **OQ-3.** Does the `stage_auto_cleans_self_leak` predicate
   need to be config-driven (`.pipeline-config/config.json::
   orchestrator.auto_clean_stages[]`) to let an operator add
   stages they want to relax halt-behavior on? Today: hard-coded
   stage list (mirrors `stage_is_read_mostly`'s shape).
   Operator can already relax behavior via the scope allowlist
   override (D-007). Defer config-driven extension until a
   second use case lands.
4. **OQ-4.** Should the prompt rule include a positive example
   of "what to do instead" — e.g., "pipe to awk via heredoc"? On
   `brainstorming` / `planning` neither `awk` nor any other
   command-line tool is allow-listed; the only legitimate
   shape is "reason inline." Decision: rule says "reason
   inline, or halt with `agent-blocked` and ask the operator."
   Positive examples might over-constrain (the agent might
   over-rely on heredoc and miss the inline-reasoning lane).
5. **OQ-5.** Does `clean_self_leak_residue` need a max-paths
   safety bound (e.g., refuse to delete more than 50 paths in
   one cleanup)? Defense against an agent that goes wild and
   writes 10,000 scratch files. Today's helper has no bound.
   Argument for: bounded behaviour is easier to reason about.
   Argument against: bounded behaviour means partial-delete
   states (some paths gone, some left) — next tick's sweep
   would catch the remainder anyway, but at the cost of one
   extra operator-visible halt. Defer; revisit if any agent
   ever produces >50 self-leak paths in a single dispatch.
6. **OQ-6.** Sub-agents dispatched via the `Agent` tool —
   their `Write` invocations appear in the parent agent's
   transcript as nested `tool_use` blocks? Or do they emit a
   separate transcript that `_render_and_capture_stream` does
   not capture? If the latter, the detective (D-005) would
   miss sub-agent writes entirely. Investigation needed at
   implement time; the structural fix (cleanup pass) works
   regardless of detective visibility, so this is a stretch-
   goal-only concern.

## 11. Anti-bias checks

### 11.1 ADR stress test

This brainstorm narrows ENG-14's "halt on self-leak" contract
from "all non-read-mostly stages" to "implementing | ui | qa
only." That is mild ADR pressure: a reader of ENG-14 would
naturally expect every stage outside the read-mostly set to
halt. The cost is documented in §5 D-002 and §6 ADR pressure
check; the broader narrative (operator decision 2026-05-10
forbids `Bash(rm:*)` to agents, so the harness must absorb
debris-cleanup at the orchestrator layer) makes the narrowing
load-bearing rather than gold-plating.

No ADR has been formally written for ENG-14's halt-on-self-
leak contract — the contract is encoded in `bin/run-local.sh:
260-273` and tested by `bin/run-local-sweep-test.sh`. This
brainstorm proposes adding an ADR to `docs/knowledge/
decisions.md` (status `proposed`) that formalises the new
split:

> **ADR-2026-05-15-100.** Self-leak halt fires only on
> production-path stages (`implementing | ui | qa`). Docs-only
> stages (`brainstorming | planning`) auto-clean self-leak
> residue alongside read-mostly stages (`reviewing | building
> | released`). Rationale: prompt-side prevention (agent
> compliance) plus orchestrator-side cleanup (structural)
> close the gap that the operator decision against
> `Bash(rm:*)` leaves open.

### 11.2 Simpler alternative

Documented in §5 D-001 (pre-partition cleanup rejected),
§5 D-002 (auto-clean all stages rejected), §5 D-003 (`git
clean -df` rejected), §5 D-004 (predicate rename rejected),
§5 D-005 (detective-by-default rejected).

The simplest possible alternative not yet rejected explicitly:
**ship only the prompt rule (Option A from the Linear issue).
Do nothing on the orchestrator side.** Rejected because: ENG-93
already shows the agent BOTH wrote a heads-up Linear comment
predicting the halt AND wrote the debris anyway — the agent's
intent and behaviour diverged because the sub-agent's tool
constraints did not flow down. A prompt rule does not close
the structural gap; cleanup must happen at the orchestrator
layer.

### 11.3 Assumption inventory

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A-1 | `clean_self_leak_residue` is the right helper to reuse — it already implements per-path tracked/untracked classification and emits the right metric. | Verified | `bin/run-local-helpers.sh:215-272` |
| A-2 | `stage_is_read_mostly` is grep-pinned by `bin/run-local-helpers-adversarial-test.sh` — renaming it would churn tests. | Verified | `bin/run-local-helpers.sh:176-180` (function definition); `bin/run-local-helpers-adversarial-test.sh` test file exists (per project profile's tests list). |
| A-3 | `partition_dirty_paths` emits three FDs (3 = in-scope, 4 = leaked, 5 = out-of-scope). | Verified | `bin/run-local-helpers.sh:600-622` |
| A-4 | `observed-vs-self-leak` split lives in `bin/run-local.sh`'s main body, not in `partition_dirty_paths`. | Verified | `bin/run-local.sh:239-258` |
| A-5 | `halt_issue_for_self_leak` halts the issue via `classify_failure` with `skip-until-human-acts` policy. | Verified | `bin/run-local-helpers.sh:128-154` |
| A-6 | `_run_worker` runs `clean_scratch_dir` then `route_run_stage_exit` then `partition_dirty_paths`, in that order. | Verified | `bin/run-local.sh:202-223` |
| A-7 | `bin/dispatch.sh::_render_and_capture_stream` persists a transcript sidecar at `${issue_dir}/.envelope-transcript-${stage}` that the post-dispatch validator scans. | Verified | `bin/dispatch.sh:54`, `bin/dispatch.sh:142-144` |
| A-8 | `assert_no_tool_invocation` in `bin/common.sh:178-195` matches a `Bash` `tool_use.input.command` startswith. The Write tool path needs a sibling helper. | Verified | `bin/common.sh:178-195` |
| A-9 | `bin/agent-prompts-content-test.sh` uses `rendered_stage_body` (§0 prepended) for §0-scope assertions and pins phrase substrings via `grep -qF`. | Verified | `bin/agent-prompts-content-test.sh:38-44`, `bin/agent-prompts-content-test.sh:574-590` (ENG-74 / ENG-87 pin shapes). |
| A-10 | §0 of `AGENT_PROMPTS.md` is the canonical single-source for cross-stage rules, prepended by `render-prompt.sh::main` before per-stage rendering. | Verified | `AGENT_PROMPTS.md:212-218` |
| A-11 | The brainstorm doc basename must contain `eng-N` (case-insensitive) per `partition_dirty_paths::D-004`. | Verified | `bin/run-local-helpers.sh:543`, `bin/run-local-helpers.sh:606-607` |
| A-12 | Operator decision 2026-05-10 forbids `Bash(rm:*)` for any stage. | Verified (memory + Linear issue body) | User memory `feedback_no_scoped_rm_allowlist.md`; Linear issue Solution Space section. |
| A-13 | The `sweep-readonly-residue-cleaned` metric name is referenced by `bin/run-local-helpers.sh:269` only — no retrospective §1 filter branch on this name today. | Assumed | Need to grep the retrospective prompt and learned-rules at implement time; if a filter branches on the name, rename considerations apply. |
| A-14 | Sub-agents dispatched via the `Agent` tool inherit the parent's `--allowed-tools` (they cannot escalate). | Assumed | Need to verify against Claude's Agent-tool docs; if sub-agents have independent allowlists, the §0 rule's reach to "sub-agents inherit" needs language adjustment. Investigation deferred to OQ-6. |
| A-15 | A `Write` tool call's input is shaped `{file_path, content}` and appears in the NDJSON transcript with `type: assistant`, `tool_use.name == "Write"`, `tool_use.input.file_path`. | Assumed | Need to inspect a captured transcript at implement time; the pattern mirrors `assert_no_tool_invocation`'s shape but on Write rather than Bash. |
| A-16 | `git status -z --porcelain` does not surface paths inside `.scratch/` because `.scratch/` is `.gitignore`d. | Verified | CLAUDE.md "Tick-end stage-agnostic `.scratch/` cleanup (`clean_scratch_dir`)" section. |
| A-17 | The cleanup helper's tmpfile + atomic-mv pattern (`bin/run-local-helpers.sh:355-356`) is the canonical for state-counter updates; cleanup itself uses no counter updates. | Verified | `bin/run-local-helpers.sh:241-272` (no counter writes inside `clean_self_leak_residue`). |
| A-18 | `bin/run-local.sh:263` is the exact line where `stage_is_read_mostly` is called as the cleanup gate. | Verified | `bin/run-local.sh:263` |

Two assumptions are marked "assumed":

- **A-13** — `sweep-readonly-residue-cleaned` metric name: implementor must `grep -rn "sweep-readonly-residue-cleaned" bin/ learned-rules/` at start; if any retrospective filter or test outside `bin/run-local-helpers.sh` references the name, the rename / docstring decision is reopened.
- **A-14, A-15** — Agent-tool sub-agent semantics + Write tool transcript shape: deferred to D-005 detective implementation. The structural fix (D-001 cleanup) does not depend on either; the detective stretch goal does. If A-14 turns out to be false (sub-agents have independent allowlists), the §0 prompt rule's last sentence needs adjustment ("Sub-agents dispatched via the `Agent` tool inherit the same constraint" becomes "Verify per stage; sub-agents may have independent allowlists").

### 11.4 Codebase-fact verification

All `path:line` references in §11.3 were obtained by reading
the current files in the worktree:

- `bin/run-local-helpers.sh:128` — `halt_issue_for_self_leak()` definition (verified).
- `bin/run-local-helpers.sh:176-180` — `stage_is_read_mostly()` definition (verified).
- `bin/run-local-helpers.sh:215-272` — `clean_self_leak_residue()` definition + per-path strategy (verified).
- `bin/run-local-helpers.sh:269` — `sweep-readonly-residue-cleaned` metric emit (verified).
- `bin/run-local-helpers.sh:310-322` — `clean_scratch_dir()` definition (verified).
- `bin/run-local-helpers.sh:535-624` — `partition_dirty_paths()` definition (verified).
- `bin/run-local.sh:202` — `clean_scratch_dir` invocation site (verified).
- `bin/run-local.sh:207` — `route_run_stage_exit` invocation site (verified).
- `bin/run-local.sh:221-223` — partition pipe with three FDs (verified).
- `bin/run-local.sh:239-258` — observed-vs-self-leak split (verified).
- `bin/run-local.sh:263` — `stage_is_read_mostly` gate (verified).
- `bin/dispatch.sh:54` — `envelope_sidecar` declaration (verified).
- `bin/dispatch.sh:142-144` — sidecar persistence (verified).
- `bin/dispatch.sh:150-184` — ENG-43/ENG-71 transcript-assertion pattern (verified).
- `bin/dispatch.sh:395, 396` — brainstorming/planning base allowlists (verified — neither contains `Bash(rm:*)`).
- `bin/common.sh:178-195` — `assert_no_tool_invocation` definition (verified).
- `AGENT_PROMPTS.md:212-228` — §0 fenced block boundary (verified).
- `AGENT_PROMPTS.md:223` — existing scratch-files-at-worktree-root rule (verified).
- `bin/agent-prompts-content-test.sh:38-44` — `rendered_stage_body` helper (verified).
- `bin/agent-prompts-content-test.sh:574-590` — pin-shape example (verified).
- `bin/run-local-sweep-test.sh:1-80` — test harness shape (verified).

The proposed names `stage_auto_cleans_self_leak` and
`assert_no_write_outside_allowlist` do NOT yet exist in the
codebase. Both are marked "assumed/new" and will be created
during implementation per §6.1's File Structure table.

## 12. Scope flags

- **Within the Linear issue's IN scope:** cleanup pass in `bin/run-local-helpers.sh` between agent exit and `partition_dirty_paths` (per Linear issue's Option B sketch — this design implements it as a post-partition route swap, mechanically simpler; intent preserved); reuse of per-stage output allowlist; §0 AGENT_PROMPTS.md preamble rule; transcript-scan detective (stretch); tests covering both prevention and the failure mode.
- **Within OUT (per Linear issue):** no `Bash(rm:*)` grant to any stage; no reframing of `pipeline:halted` semantics for broader self-leak class.
- **Slight scope deviation flagged:** The Linear issue's Option B sketch positions cleanup "between agent exit and `partition_dirty_paths`." This design instead places cleanup *after* partition's three-stream emission, *before* the in-scope commit. The motivation (D-001) is reuse: the snapshot comparison + bucket split already exists between partition and the halt gate. The end-state is functionally equivalent (debris cleaned before any halt is decided; legitimate output still commits), but operators reading the issue may expect a pre-partition pass; the docs change to `docs/architecture.md` (§6.1) calls this out explicitly. No reviewer is expected to object — the simpler implementation is the better one — but flagging per the brainstorm contract.
- **No scope exceeds the issue.** No work proposed outside the issue's IN scope. The five test fixtures, the ADR, and the architecture-doc paragraph are direct consequences of the changes the issue asks for.

## 13. Conflict with existing architecture

None identified beyond the mild ADR pressure on ENG-14 documented in §6.6 and §11.1. The change collapses to:

- One new predicate in `bin/run-local-helpers.sh`.
- One line swap in `bin/run-local.sh`.
- One paragraph append to AGENT_PROMPTS.md §0.
- Three test additions (existing test files).
- One docstring update on `clean_self_leak_residue`.
- One ADR (proposed).
- One paragraph in `docs/architecture.md`.
- Stretch: one helper + one dispatch.sh call + one config flag.

All within the conventions already in place. No new files, no new directories, no dependency or signing surface changes.

## 14. Proposed ADR (for docs/knowledge/decisions.md when implementor lands the change)

```
## ADR-2026-05-15-100 — Self-leak halt narrowed to production-path stages

Status: proposed
Date: 2026-05-15
Linear: ENG-100

### Context

Operator decision 2026-05-10 forbids any form of `Bash(rm:*)` in
agent `--allowed-tools` (security threat vector — escapes, alias
bypasses, symlink rm hazards). Stages that run sub-agents
(planning/review feasibility reviewers) cannot clean up scratch
files they create while reasoning. Tick-end `partition_dirty_paths`
then classifies the scratch as `out-of-scope NEW` (self-leak) and
`halt_issue_for_self_leak` fires on a clean stage output (ENG-93,
2026-05-10).

### Decision

`halt_issue_for_self_leak` fires on `implementing | ui | qa`
only. The other five stages (`brainstorming | planning |
reviewing | building | released`) route self-leak through
`clean_self_leak_residue` instead: per-path `git checkout --` for
tracked files; `rm -rf` for untracked; metric emit for the
retrospective. The cleanup runs under orchestrator privileges,
never inside the agent's tool boundary.

The asymmetry tracks production-path write potential:
implementing/ui/qa allow writes to `bin/**`, `src/**`,
`tests/**` — a self-leak there is potentially an agent gone
off-piste, and halt-then-decide is the correct operator
contract. Brainstorming/planning have docs-only allowlists; a
self-leak is by elimination meaning-free scratch, and halt is
the wrong default.

### Consequences

- Operator toil on ENG-93-shape failures eliminated.
- `pipeline:halted` no longer fires on docs-only stages for
  the scratch-file failure class.
- ENG-14's "halt-on-self-leak across all non-read-mostly
  stages" reading is narrowed to "halt only on stages with
  production-path write potential."
- Forensic audit preserved via `sweep-readonly-residue-cleaned`
  metric.
```

## 15. Persona review

Order: design → security → scope → coherence → product → feasibility
(feasibility last; gating persona). Gate criterion: at least 5/6 PASS
AND feasibility returns zero P0 findings.

Iteration 1 (2026-05-15).

### 15.1 design — PASS (0 P0, 0 P1)

The change is structurally minimal: one new predicate
(`stage_auto_cleans_self_leak`), one one-line callsite swap, one
prompt rule, sibling test fixtures. No new abstractions, no new
files, no layering violations. The predicate name distinguishes
itself from `stage_is_read_mostly` (D-004 covers the naming
hygiene argument), and the helper it gates (`clean_self_leak_
residue`) is reused without modification. The metric name
`sweep-readonly-residue-cleaned` becomes mildly misleading after
this change but documenting the broadened scope in the helper
docstring (§6.3) is consistent with the project's "rename only
when downstream consumers exist" discipline. The detective stretch
goal cleanly mirrors the ENG-43/ENG-66/ENG-71 transcript-assertion
pattern that already exists in `bin/dispatch.sh`.

Minor observation (non-blocking): `clean_self_leak_residue`'s log
line at `bin/run-local-helpers.sh:253` reads `"auto-clean: stage=
$stage is read-mostly; cleaning …"`. After this change, the
"read-mostly" phrasing in that log line becomes inaccurate for
brainstorm/plan dispatches. Update the log message to
`"auto-clean: stage=$stage residue; cleaning …"` (or similar) at
implement time. Logged as P2 (cosmetic).

### 15.2 security — PASS (0 P0, 0 P1)

Threat model:

- **Agent escalation.** Cleanup runs at the orchestrator layer,
  outside the agent's `--allowed-tools` boundary. No new agent-
  callable delete tools (G-2). Operator decision 2026-05-10
  aligned.
- **Data loss.** Per-path strategy (D-003) limits deletion to FD5
  paths only — `tracked → git checkout --` is reversible via
  reflog; `untracked → rm -rf` operates on a path the partition
  pipeline has already confirmed is NEW since tick-start (i.e.,
  not in operator's pre-existing edits). The defensive guards
  (empty/missing-worktree/main-or-master/dry-run) are unchanged
  and already battle-tested.
- **Adversarial filenames.** The existing helper emits sha12
  hashes to metric notes; raw path strings never reach Linear
  comments. §9.4 (binary blobs) and §9.6 (symlinks) acknowledged
  and addressed.
- **Operator override coexistence (D-007).** Cleanup respects
  `config.json::scope.allowlist.<stage>[]` overrides because it
  consumes partition's output, which already routes operator-
  whitelisted paths to FD3 (in-scope).
- **Detective false-positive risk.** D-005 ships the detective
  behind a default-off config flag, eliminating the rollout-day
  surprise risk.

One observation worth verifying at implement time (P2, non-
blocking): the `rm -rf -- "$worktree/$p"` form's `--` separator
prevents argument-injection-via-leading-dash filenames, but the
caller should also confirm that no shell expansion occurs on
adversarial `$p` values inside double quotes. The `-rf` flag
combined with bash's `"..."` quoting is the standard form; no
issue expected.

### 15.3 scope — PASS (0 P0, 0 P1)

Every decision traces to either the Linear issue body or the
operator decision 2026-05-10:

| Decision | Trace |
|---|---|
| D-001 (post-partition route, not pre-partition pass) | Linear issue Option B; simplification justified in §5 D-001. |
| D-002 (implementing/ui/qa stay on halt) | Linear issue Scope Boundaries "this issue is specifically about sub-agent scratch files"; implied by the production-path-write asymmetry. |
| D-003 (per-path strategy) | Linear issue AC-4 (cleanup must NOT delete in-snapshot or allowlist paths). |
| D-004 (predicate naming) | Implementation detail. |
| D-005 (detective stretch) | Linear issue AC-6 (stretch). |
| D-006 (snapshot reliance) | Architectural prerequisite. |
| D-007 (operator override compat) | Implicit AC. |
| D-008 (prompt rule in §0) | Linear issue Option A. |

No gold-plating; no out-of-scope work proposed. The §12 scope-
flag paragraph explicitly notes the only deviation from the
Linear issue's framing (cleanup placed *after* partition rather
than *before*) and justifies it.

### 15.4 coherence — PASS (0 P0, 0 P1)

Internal cross-references resolve cleanly:

- Goal §2 ↔ AC mapping is exhaustive (every G-N traces to one or
  more ACs and vice versa).
- §7 data flow walks the exact ENG-93 shape end-to-end and
  confirms the legitimate output commits.
- §9 edge cases cover loopback, wait-exit, symlinks, binary
  blobs, operator-override coexistence, and the missing-snapshot
  degraded path.
- §11.3 assumption inventory binds every `path:line` claim to a
  verification status.
- §14 proposed ADR captures the narrowed halt contract without
  recapping the brainstorm wholesale.
- Open questions §10 do not block the structural fix; each is
  a stretch-goal or post-rollout knob.

### 15.5 product — PASS (0 P0, 0 P1)

The user-visible deliverable matches what the operator asked for:

- Operator no longer needs to `rm <leaked-file> && bash bin/
  pipeline.sh decide ENG-N --action continue` for the ENG-93
  shape.
- Legitimate stage output (plan doc, brainstorm doc) commits and
  pushes as if no debris ever existed.
- Forensic audit (`sweep-readonly-residue-cleaned` metric)
  preserves the retrospective's ability to surface "this agent
  prompt keeps writing debris."
- §0 prompt rule reduces the pre-flight probability of debris
  generation in the first place.

The operator's mental model in `docs/runbooks/operator-mental-
model.md` (implied by CLAUDE.md "Failure-mode quick reference")
gains one row: "self-leak on brainstorming/planning auto-cleans
silently; check `sweep-readonly-residue-cleaned` metric to see
what was wiped." That row aligns with the existing read-mostly-
stage row.

No mismatch between Linear-issue-asked and brainstorm-proposed.

### 15.6 feasibility (gating) — PASS (0 P0, 0 P1)

Codebase-fact verification swept every `path:line` cited in the
brainstorm against the worktree at brainstorm time. Verifications:

- `halt_issue_for_self_leak` defined at `bin/run-local-helpers.sh:128`. ✓
- `stage_is_read_mostly` defined at `bin/run-local-helpers.sh:176-180`. ✓
- `clean_self_leak_residue` defined at `bin/run-local-helpers.sh:215-272`. ✓
- `clean_scratch_dir` defined at `bin/run-local-helpers.sh:310-322`. ✓
- `partition_dirty_paths` defined at `bin/run-local-helpers.sh:535-624`. ✓
- `sweep-readonly-residue-cleaned` metric emit at `bin/run-local-helpers.sh:269`. ✓
- `tally_leaked_in_scope_failure` defined at `bin/run-local-helpers.sh:341-363`. ✓
- `route_run_stage_exit` defined at `bin/run-local-helpers.sh:388-430`. ✓
- `clean_scratch_dir` callsite at `bin/run-local.sh:202`. ✓
- `route_run_stage_exit` callsite at `bin/run-local.sh:207`. ✓
- Partition pipe with FD3/FD4/FD5 at `bin/run-local.sh:221-223`. ✓
- Observed-vs-self-leak split at `bin/run-local.sh:239-258`. ✓
- `stage_is_read_mostly` gate callsite at `bin/run-local.sh:263` (the precise line of the proposed predicate swap). ✓
- `assert_no_tool_invocation` defined at `bin/common.sh:178-195`. ✓
- Brainstorming base allowlist at `bin/dispatch.sh:395` (no `Bash(rm:*)`). ✓
- Planning base allowlist at `bin/dispatch.sh:396` (no `Bash(rm:*)`). ✓
- §0 fenced block of AGENT_PROMPTS.md at lines 212-228. ✓
- Existing scratch-files-at-worktree-root rule at AGENT_PROMPTS.md:223. ✓
- `rendered_stage_body` helper at `bin/agent-prompts-content-test.sh:38-44`. ✓
- ENG-74 / ENG-87 pin-shape example at `bin/agent-prompts-content-test.sh:574-590`. ✓
- `assert_partition` helper at `bin/run-local-sweep-test.sh:13-44`. ✓

Promotion of one assumption: **A-13** (no retrospective filter
branches on `sweep-readonly-residue-cleaned`) was confirmed at
review time via `Grep` on `learned-rules/` — no matches.
Promoted from "assumed" to "verified-at-brainstorm-time;
implementor reverifies before landing." References in CLAUDE.md
(lines 307, 611) describe the metric; they do not branch on it.

Test-gate closure sweep (per §6.1 File Structure changes):

| Soon-to-be-removed token | Sibling test files that reference it | Action |
|---|---|---|
| (None — this change is purely additive) | n/a | n/a |

No P0 codebase-fact errors. No phantom function calls. The two
proposed new symbols (`stage_auto_cleans_self_leak`,
`assert_no_write_outside_allowlist`) are explicitly marked
"assumed/new" in §11.3 and have File Structure entries in §6.1.

### 15.7 Iteration 1 verdict

| Persona | Verdict | P0 | P1 | P2 |
|---|---|---|---|---|
| design | PASS | 0 | 0 | 1 (cosmetic log-message update) |
| security | PASS | 0 | 0 | 1 (verify `rm -rf --` quoting at implement time) |
| scope | PASS | 0 | 0 | 0 |
| coherence | PASS | 0 | 0 | 0 |
| product | PASS | 0 | 0 | 0 |
| feasibility (gating) | PASS | 0 | 0 | 0 |

**Gate: 6/6 PASS · feasibility P0: 0 · clean — proceeding to commit + stage-summary + verdict.**

Two P2 observations recorded above are non-blocking and will be
folded into the implementation PR's checklist by the plan agent.
