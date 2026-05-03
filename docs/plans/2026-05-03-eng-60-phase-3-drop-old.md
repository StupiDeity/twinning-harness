---
linear: ENG-60
topic: Pipeline vocabulary simplification — Phase 3 (drop old)
date: 2026-05-03
status: draft
---

# Plan — ENG-60 Phase 3: drop old

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Implementation plan for Phase 3 of the design in
`docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md`,
following Phase 2 (writers + agent prompts + glossary).

## Goal

Remove every legacy code path the harness no longer needs. After Phase 3,
`parse_pipeline_marker` only handles the new shape; `bin/halt.sh` and
`bin/post-verdict.sh` no longer exist; verb-form stage aliases are gone;
`legacy_halt_reason_aliases` is removed from the registry. The codebase has
exactly one vocabulary, end-to-end.

## Architecture

Phase 3 is mostly mechanical deletions of code that became dead-weight after
Phase 2's prompt rewrite (T2.11) and the four carryover fixes (T2.0–T2.3).
Tasks are sequenced so each removal happens after every consumer has stopped
needing it; the test suite stays green at every commit.

The final cleanup work (registry alias removal, parser alias-normalization
removal, doc migration-notes removal) happens last, after the parser stops
seeing legacy tokens entirely.

## Tech Stack

Same as Phase 2 — bash, jq, harness scripts. No new dependencies.

## Plan horizon

This document fully details Phase 3 (12 tasks). After Phase 3 ships, ENG-60
is closed.

## Assumption inventory

- **A-001:** No agent or operator emits old-shape markers anymore. Phase 2's
  T2.11 rewrote AGENT_PROMPTS.md; T2.9 and T2.10 made `halt.sh` and
  `post-verdict.sh` deprecation wrappers that emit new-shape via `bin/pipeline.sh`.
  Therefore old-shape markers in `parse_pipeline_marker` are pure regression
  protection for in-flight Linear comments — once those drain, removal is
  safe.
- **A-002:** Phase 2's deploy gate (T2.16) confirmed in-flight issues drained
  to new-shape comments. **This plan assumes T2.16 has been executed and
  passed.** If the operator is shipping Phase 1+2+3 as one PR (skipping the
  soak), they must accept that Phase 3 is irreversible without restoring
  legacy parsing — the migration window collapses to zero.
- **A-003:** All five legacy pipeline-namespace labels (`paused`,
  `scope-approval-needed`, `supersede`, `skip-until-code-changes`,
  `skip-until-human-acts`) are drained from issues via T2.13's transition
  hook on every pipeline tick. The migration script (T3.9) is a one-time
  sweep for issues that have not transitioned during the soak.
- **A-004:** `bin/post-verdict-test.sh` exists only to test the wrapper.
  Once the wrapper is deleted, the test has no subject; deleting both
  together preserves the test/source contract.
- **A-005:** The `_normalize_stage` helper in `bin/render-prompt.sh` and the
  in-line case block in `bin/run-stage.sh::main` were both added in T2.12.
  They translate verb-form CLI args (`brainstorm`, `plan`, etc.) to gerund.
  Once the verb-form alias removal lands, every CLI invocation must use the
  gerund form — operators with muscle memory may need to update local
  scripts and aliases.

## File structure (Phase 3)

**Modify:**
- `bin/common.sh` — remove old-shape branch from `parse_pipeline_marker`;
  later remove the alias-normalization step too.
- `bin/common-test.sh` — drop fixtures P4–P10 (legacy-shape tests).
- `bin/verdict-handler.sh` — remove `rejection_src` grep block in
  `find_fresh_verdict` (dead after old-shape parser removal).
- `bin/scope-check.sh` — remove defensive `scope-deviation` case in
  `has_scope_approval` (dead after parser alias removal).
- `bin/render-prompt.sh` — remove `_normalize_stage` + STAGE_VERB_TO_GERUND
  alias map.
- `bin/run-stage.sh` — remove verb-form alias case block in `main()`.
- `bin/dispatch.sh` — remove verb-form arms from `allowed_tools_for`; remove
  verb-form key fallback in `_dispatch_tools_extras`.
- `bin/run-local.sh` — collapse `brainstorm|brainstorming` arms to gerund
  only.
- `bin/run-local-helpers.sh` — collapse dual-form arms in
  `stage_output_paths`, `assert_stage_allowlist_coverage`,
  `partition_dirty_paths`.
- `bin/reconcile.sh` — collapse dual-form arms.
- `bin/render-pr-body.sh` — remove `impl_summary` verb-form fallback.
- `bin/pipeline-events.json` — remove `legacy_halt_reason_aliases` map.
- `CLAUDE.md` — remove `halt.sh` and `post-verdict.sh` lines from
  Common commands section.
- `docs/pipeline-vocabulary.md` — remove "Migration notes" section
  (regenerated from updated template).
- `docs/pipeline-vocabulary.template.md` — remove "Migration notes" section.

**Create:**
- `bin/migrate-labels.sh` — one-time admin script to drain legacy
  pipeline-namespace labels from any straggler issues.

**Delete:**
- `bin/halt.sh` (the wrapper).
- `bin/post-verdict.sh` (the wrapper, including the `post_verdict` shim).
- `bin/post-verdict-test.sh` (no subject without the wrapper).

## Phase 3 task plan

### Task 3.1: Remove old-shape branch from `parse_pipeline_marker`; drop legacy fixtures

**Files:**
- Modify: `bin/common.sh::parse_pipeline_marker` (remove second `marker=...|sed...|case` block).
- Modify: `bin/common-test.sh` (delete P4–P10 fixtures).

- [ ] **Step 1: Identify the old-shape branch boundaries**

```bash
cd /Users/rajatgoyal/code/twinning-harness
grep -n '# New shape\|# Old shape\|# Apply legacy_halt_reason_aliases\|return 0$' bin/common.sh | head -20
```

The old-shape branch starts at `# Old shape:` (around line 182) and runs through the `case "$kind" in stage-summary|rejection|...` block, ending just before `printf ''; return 1` (the final no-marker fallthrough). Identify exact line range.

- [ ] **Step 2: Delete the old-shape branch**

Remove the entire block from `# Old shape:` through the closing `}` of its `case "$kind"` statement. The function should now have just one regex match (`<!-- pipeline: <event> [k=v ...] -->`) followed by the final `printf ''; return 1` no-match path.

- [ ] **Step 3: Delete fixtures P4–P10 from `bin/common-test.sh`**

P4 (old stage-summary), P5 (old rejection), P6 (old halt + alias), P7 (old decision scope-approved), P8 (old decision resume), P9 (old transition), P10 (old sig). Delete all of them.

P11 (multi-line body with new-shape marker), P12 (no-marker), P13 (new-shape halt with legacy reason — added in T2.0) all stay.

NOTE: P13 still tests the new-shape alias normalization. That step is removed in T3.7; for now, keep P13 as the regression guard.

- [ ] **Step 4: Run tests**

```bash
TARGET_REPO=$(pwd) bash bin/common-test.sh
TARGET_REPO=$(pwd) bash bin/verdict-handler-test.sh
TARGET_REPO=$(pwd) bash bin/scope-check-test.sh
```

Expected: P4–P10 are gone; P1–P3, P11, P12, P13 all pass; verdict-handler still passes (its FV4 fixture uses the OLD-shape — that fixture needs deletion in this commit too).

If FV4 fails (`old-shape stage-summary still detected`), delete it from `bin/verdict-handler-test.sh` — it explicitly tests the old-shape path that we just removed. Its successor coverage is provided by FV1 (new-shape stage-summary).

Same for HSA3 in `bin/scope-check-test.sh` (`pure-old shape regression`). Delete it.

- [ ] **Step 5: Commit**

```bash
git add bin/common.sh bin/common-test.sh bin/verdict-handler-test.sh bin/scope-check-test.sh
git commit -m "feat(ENG-60-T3.1): drop old-shape branch from parse_pipeline_marker

After Phase 2 deployment, no agent or operator emits old-shape markers.
The parser's old-shape branch in bin/common.sh is now dead code.
Remove it. Delete the corresponding fixtures (P4-P10 in common-test.sh,
FV4 in verdict-handler-test.sh, HSA3 in scope-check-test.sh) — their
coverage is now redundant with the new-shape fixtures.

P13 (new-shape halt with legacy reason scope-deviation → scope-violation)
still passes via the new-shape alias-normalization step added in T2.0;
T3.7 removes that step too once the registry alias map is removed (T3.8).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.2: Remove `rejection_src` grep in `find_fresh_verdict`

**Files:**
- Modify: `bin/verdict-handler.sh::find_fresh_verdict`.

After T3.1, `parse_pipeline_marker` never returns an old-shape rejection.
The `rejection_src` grep in `find_fresh_verdict` (added in Phase 1 T1.3 to
recover the source stage from old-shape two-marker rejections) is dead.

- [ ] **Step 1: Locate and delete the grep block**

```bash
grep -n 'rejection_src\|grep -oE.*pipeline-rejection' bin/verdict-handler.sh
```

Remove the `rejection_src` variable + its grep + the `--arg rsrc` jq
argument in the projection. The `--argjson e "$ev_json"` is enough; the
projection's `fail` branch reads `$e.target` directly and sets
`source_stage:""` — the T2.2 fallback in `apply_transition` then derives
source from the issue's `stage:*` label.

- [ ] **Step 2: Run tests**

```bash
TARGET_REPO=$(pwd) bash bin/verdict-handler-test.sh
TARGET_REPO=$(pwd) bash bin/verdict-adversarial-test.sh
TARGET_REPO=$(pwd) bash bin/halt-sprawl-test.sh
```

Expected: all PASS. FB1 (the T2.2 fallback fixture) still works because the
fallback reads `stage:*` directly. Cases 2 and 3 (loopback fixtures using
the OLD-shape two-marker rejection — `<!-- pipeline-rejection: qa --><!-- pipeline-rejection-target: implementing -->`) need updating to use the new shape, OR deleting if FB1 covers the same path.

If cases 2 / 3 fail: rewrite their fixtures to use the new shape
(`<!-- pipeline: verdict result=fail target=implementing -->` plus
`VH_CURRENT_STAGE_LABEL="stage:qa"` to provide the source via the T2.2
fallback path).

- [ ] **Step 3: Commit**

```bash
git add bin/verdict-handler.sh bin/verdict-handler-test.sh
git commit -m "feat(ENG-60-T3.2): drop rejection_src grep in find_fresh_verdict

After T3.1 removed the old-shape parser branch, parse_pipeline_marker
no longer produces a body that the rejection_src grep would match.
Remove the dead grep block. New-shape rejections rely on the T2.2
stage:* label fallback in apply_transition for source recovery.

Cases 2/3 in verdict-handler-test.sh updated/removed to use new-shape
rejection bodies (or rely on FB1's coverage of the same path).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.3: Remove defensive `scope-deviation` case in `has_scope_approval`

**Files:**
- Modify: `bin/scope-check.sh::has_scope_approval`.

The case statement currently accepts both `scope-violation` and
`scope-deviation` (defensive double-coverage from T2.0 era). Once the
registry alias map is removed (T3.8) and `parse_pipeline_marker`'s
alias-normalization step is removed (T3.7), agents only emit canonical
`scope-violation`. The defensive `scope-deviation` arm is dead.

- [ ] **Step 1: Replace the case statement**

```bash
grep -n 'scope-violation|scope-deviation' bin/scope-check.sh
```

Change:
```bash
case "$reason" in scope-violation|scope-deviation) ;; *) continue ;; esac
```
to:
```bash
[[ "$reason" == "scope-violation" ]] || continue
```

Also update the inline comment block above the case to remove the
"Phase 2 carryover" language (now resolved).

- [ ] **Step 2: Run tests**

```bash
TARGET_REPO=$(pwd) bash bin/scope-check-test.sh
TARGET_REPO=$(pwd) bash bin/run-stage-test.sh
```

Expected: all PASS. HSA1 / HSA2 (new-shape decision after halt) still pass.

- [ ] **Step 3: Commit**

```bash
git add bin/scope-check.sh
git commit -m "feat(ENG-60-T3.3): drop defensive scope-deviation case in has_scope_approval

Agents only emit canonical scope-violation post-Phase 2. The defensive
scope-deviation acceptance was a Phase 2 carryover; it is dead code
once the registry alias map and parser alias-normalization step are
both removed (T3.7, T3.8).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.4: Remove verb-form stage aliases everywhere

**Files (all of):**
- Modify: `bin/render-prompt.sh` (remove `_normalize_stage` + `STAGE_VERB_TO_GERUND`).
- Modify: `bin/run-stage.sh::main` (remove verb-form normalization case).
- Modify: `bin/dispatch.sh::allowed_tools_for` (remove `brainstorm)`, `plan)`, `implement)`, `review)`, `build)`, `release)` recursion arms).
- Modify: `bin/dispatch.sh::_dispatch_tools_extras` (remove verb-form key fallback).
- Modify: `bin/run-local.sh` (`brainstorm|brainstorming` → `brainstorming` only).
- Modify: `bin/run-local-helpers.sh::{stage_output_paths,assert_stage_allowlist_coverage,partition_dirty_paths}`.
- Modify: `bin/reconcile.sh`.
- Modify: `bin/render-pr-body.sh::impl_summary` (drop `implement` fallback).

This task touches many files but each edit is mechanical. Group as one
commit because the changes are functionally cohesive (all the verb-form
shims land or get removed together).

- [ ] **Step 1: Audit verb-form references**

```bash
cd /Users/rajatgoyal/code/twinning-harness
grep -rn 'brainstorm)\|plan)\|implement)\|review)\|build)\|release)' bin/*.sh \
  | grep -vE '\b(brainstorming|planning|implementing|reviewing|building|released|brainstorm-|plan-|implement-|review-|build-|release-)\b' \
  | grep -v _test\.sh \
  | head -30
```

Build a checklist of every verb-form site to remove.

- [ ] **Step 2: Apply removals file-by-file**

For each file:
- Remove the verb-form arm from any `case` statement.
- Remove the `STAGE_VERB_TO_GERUND` map and `_normalize_stage` helper from `bin/render-prompt.sh`; update its `main()` to not call `_normalize_stage`.
- Remove the equivalent normalization shim from `bin/run-stage.sh::main`.
- Remove the `verb_form` lookup case + the chained `// (if $v != "" then .dispatch.tools[$v] else null end)` from `bin/dispatch.sh::_dispatch_tools_extras`.
- Remove the `// _rpb_stage_summary "implement"` fallback in `bin/render-pr-body.sh`.

- [ ] **Step 3: Run all impacted test suites**

```bash
TARGET_REPO=$(pwd) bash bin/render-prompt-test.sh
TARGET_REPO=$(pwd) bash bin/dispatch-test.sh
TARGET_REPO=$(pwd) bash bin/run-stage-test.sh
TARGET_REPO=$(pwd) bash bin/run-local-sweep-test.sh
TARGET_REPO=$(pwd) bash bin/run-local-helpers-adversarial-test.sh
TARGET_REPO=$(pwd) bash bin/reconcile-test.sh
TARGET_REPO=$(pwd) bash bin/poll-slot-test.sh
```

Expected: all PASS. If any test fixture invokes a verb-form stage name, update it to gerund.

- [ ] **Step 4: Verify verb-form CLI is now rejected**

```bash
TARGET_REPO=$(pwd) bash bin/render-prompt.sh implement 2>&1 || echo "rejected as expected"
TARGET_REPO=$(pwd) bash bin/run-stage.sh ENG-1 implement 2>&1 || echo "rejected as expected"
```

Expected: both reject with a clear "unknown stage" or equivalent message.

- [ ] **Step 5: Commit**

```bash
git add bin/render-prompt.sh bin/run-stage.sh bin/dispatch.sh bin/run-local.sh bin/run-local-helpers.sh bin/reconcile.sh bin/render-pr-body.sh
git commit -m "feat(ENG-60-T3.4): drop verb-form stage aliases everywhere

T2.12 introduced verb-form aliases (brainstorm → brainstorming, etc.) as
a one-release migration shim with [deprecated] log lines on use. After
Phase 2 + soak, every caller uses the gerund form. Drop the shims:

- render-prompt.sh: remove _normalize_stage + STAGE_VERB_TO_GERUND.
- run-stage.sh: remove verb-form normalization case in main().
- dispatch.sh::allowed_tools_for: remove brainstorm)/plan)/implement)/
  review)/build)/release) recursion arms.
- dispatch.sh::_dispatch_tools_extras: remove verb-form key fallback
  for .dispatch.tools[\$verb_form].
- run-local.sh: collapse brainstorm|brainstorming arms to gerund only.
- run-local-helpers.sh: same in stage_output_paths,
  assert_stage_allowlist_coverage, partition_dirty_paths.
- reconcile.sh: same.
- render-pr-body.sh::impl_summary: drop \`implement\` fallback after
  \`implementing\` returned empty.

Verb-form CLI invocations now reject with "unknown stage" — operators
must use gerund (brainstorming/planning/implementing/reviewing/building/
released).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.5: Delete `halt.sh`, `post-verdict.sh`, `post-verdict-test.sh`

**Files:**
- Delete: `bin/halt.sh`, `bin/post-verdict.sh`, `bin/post-verdict-test.sh`.

- [ ] **Step 1: Confirm nothing else depends on these files**

```bash
cd /Users/rajatgoyal/code/twinning-harness
grep -rn 'halt\.sh\|post-verdict' bin/ AGENT_PROMPTS.md CLAUDE.md docs/ \
  | grep -v 'halt-sprawl\|halt_\|halted\|halt-' \
  | head -30
```

The grep should return only:
- T2.10's deprecation message text in a few places ("bin/halt.sh resolve will be removed in Phase 3" — that text is IN halt.sh itself, so being deleted with it).
- Possibly internal test-only references (acceptable).
- CLAUDE.md's Common commands section (T3.6 will clean those up).

If any other script invokes `halt.sh` or `post-verdict.sh`, STOP and update those callers to use `bin/pipeline.sh` directly.

- [ ] **Step 2: Delete the files**

```bash
rm bin/halt.sh bin/post-verdict.sh bin/post-verdict-test.sh
```

- [ ] **Step 3: Run tests**

```bash
TARGET_REPO=$(pwd) bash bin/run-stage-test.sh
TARGET_REPO=$(pwd) bash bin/halt-sprawl-test.sh
TARGET_REPO=$(pwd) bash bin/halt-sprawl-adversarial-test.sh
TARGET_REPO=$(pwd) bash bin/dispatch-test.sh
```

Expected: all PASS. The `halt-sprawl-test*` tests do NOT depend on `halt.sh` (they exercise `poll.sh::_poll_emit_halt_sprawl_alert` — verified during T2.9). Other tests don't invoke `halt.sh` or `post-verdict.sh`.

If anything fails, the deletion needs an additional caller update first.

- [ ] **Step 4: Commit**

```bash
git add bin/halt.sh bin/post-verdict.sh bin/post-verdict-test.sh
git commit -m "feat(ENG-60-T3.5): delete halt.sh, post-verdict.sh, post-verdict-test.sh

Phase 2 made these into deprecation wrappers around bin/pipeline.sh.
Phase 3 removes the wrappers entirely. Operators and agents must use
bin/pipeline.sh directly:

  halt.sh resolve <issue> --decision X
    → bin/pipeline.sh decide <issue> --action <continue|approve|abandon>
                                     [--gate <gate>]

  post-verdict.sh <issue> stage-summary <stage>
    → bin/pipeline.sh event <issue> verdict pass --stage <stage>
  post-verdict.sh <issue> rejection <target>
    → bin/pipeline.sh event <issue> verdict fail --target <target>
  post-verdict.sh <issue> halt <reason>
    → bin/pipeline.sh event <issue> verdict halt --reason <reason>

post-verdict-test.sh deleted alongside its subject.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.6: Update CLAUDE.md Common commands section

**Files:**
- Modify: `CLAUDE.md`.

- [ ] **Step 1: Replace the deleted-binary lines**

In `CLAUDE.md`'s "Common commands" section, replace:
```bash
# Resolve a halted issue (see docs/pipeline-vocabulary.md for decision tokens):
bash bin/halt.sh resolve ENG-XX --decision <scope-approved|scope-rejected|resume>

# Post a verdict marker manually (heredoc-constructed; safe from bash !-expansion):
bash bin/post-verdict.sh ENG-N stage-summary <stage> [<reason>]
bash bin/post-verdict.sh ENG-N rejection <target-stage> [<reason>]
bash bin/post-verdict.sh ENG-N halt <reason-token> [<reason>]
```

with:
```bash
# Resolve a halted issue (see docs/pipeline-vocabulary.md for decision tokens):
bash bin/pipeline.sh decide ENG-XX --action <continue|approve|abandon> [--gate <gate>]

# Post a verdict marker manually (registry-validated; lane-fenced):
bash bin/pipeline.sh event ENG-N verdict pass --stage <stage>
bash bin/pipeline.sh event ENG-N verdict fail --target <stage>
bash bin/pipeline.sh event ENG-N verdict halt --reason <reason-token>
bash bin/pipeline.sh event ENG-N verdict wait --reason <reason-token>     # build only

# Read-only event log for an issue:
bash bin/pipeline.sh status ENG-N
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(ENG-60-T3.6): CLAUDE.md Common commands uses bin/pipeline.sh

After T3.5 deleted the legacy wrappers, the Common commands section
must point at bin/pipeline.sh directly. Adds the status subcommand
and the wait variant (build only).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.7: Remove new-shape alias-normalization step in `parse_pipeline_marker`

**Files:**
- Modify: `bin/common.sh::parse_pipeline_marker` (remove the alias block T2.0 added).
- Modify: `bin/common-test.sh` (delete P13 fixture — tests the alias step about to be removed).

Once `legacy_halt_reason_aliases` is removed from the registry (T3.8), the
alias-normalization step in the new-shape branch becomes a no-op. Remove
the step in this task; remove the registry key in T3.8.

- [ ] **Step 1: Delete the alias block**

```bash
grep -n 'Apply legacy_halt_reason_aliases\|canon_reason' bin/common.sh
```

Remove the `if [[ "$event" == "verdict" ]] && jq -e '.reason' <<<"$json" >/dev/null 2>&1; then ... fi` block from the new-shape branch (added in T2.0, around lines 170-180).

- [ ] **Step 2: Delete P13 fixture**

P13 in `common-test.sh` (added in T2.0) tests the alias normalization
specifically. Delete it.

- [ ] **Step 3: Run tests**

```bash
TARGET_REPO=$(pwd) bash bin/common-test.sh
TARGET_REPO=$(pwd) bash bin/scope-check-test.sh
```

Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add bin/common.sh bin/common-test.sh
git commit -m "feat(ENG-60-T3.7): drop new-shape alias-normalization in parse_pipeline_marker

T2.0 added an alias-normalization step in parse_pipeline_marker's
new-shape branch to handle hand-crafted markers with legacy reason
tokens (e.g., scope-deviation). After Phase 2 deployment, only
bin/pipeline.sh emits new-shape markers; it validates against the
registry and rejects unknown tokens. The alias step is dead code.

P13 fixture deleted (it explicitly tested the now-removed step).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.8: Remove `legacy_halt_reason_aliases` from registry

**Files:**
- Modify: `bin/pipeline-events.json`.

- [ ] **Step 1: Remove the key**

```bash
jq 'del(.legacy_halt_reason_aliases)' bin/pipeline-events.json > /tmp/pe.json && mv /tmp/pe.json bin/pipeline-events.json
jq empty bin/pipeline-events.json
```

- [ ] **Step 2: Re-generate the vocabulary doc**

```bash
bash bin/generate-vocabulary-doc.sh
```

The generator's `legacy_halt_reason_aliases` section will now be empty
(or the generator's `jq` call will fail gracefully on the missing key —
verify by running and checking the output).

If the generator crashes on the missing key, update it to skip the
section when the key is absent:

```bash
# In bin/generate-vocabulary-doc.sh:
if jq -e '.legacy_halt_reason_aliases' "$REG" >/dev/null 2>&1; then
  printf '### `legacy_halt_reason_aliases`\n\n'
  jq -r '.legacy_halt_reason_aliases | to_entries[] | "- `" + .key + "` → `" + .value + "`"' "$REG"
  printf '\n'
fi
```

- [ ] **Step 3: Commit**

```bash
git add bin/pipeline-events.json bin/generate-vocabulary-doc.sh docs/pipeline-vocabulary.md
git commit -m "feat(ENG-60-T3.8): drop legacy_halt_reason_aliases from registry

T3.7 removed the new-shape alias-normalization step in
parse_pipeline_marker. With no consumer reading the alias map, it can
go from the registry. Generator updated to skip the section when the
key is absent. docs/pipeline-vocabulary.md regenerated.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.9: Create `bin/migrate-labels.sh` admin script

**Files:**
- Create: `bin/migrate-labels.sh`.

This is a one-time admin script that drains legacy pipeline-namespace
labels from any straggler issue that didn't transition during the soak.
Idempotent — safe to run multiple times.

- [ ] **Step 1: Write the script**

```bash
cat > bin/migrate-labels.sh <<'EOF'
#!/usr/bin/env bash
# bin/migrate-labels.sh — one-time legacy pipeline-namespace label drain.
#
# Iterates every Linear issue in the harness's project and removes the five
# legacy labels (paused, scope-approval-needed, supersede,
# skip-until-code-changes, skip-until-human-acts). Idempotent. Safe to re-run.
#
# Usage:
#   TARGET_REPO=/path/to/target bash bin/migrate-labels.sh [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

LEGACY_LABELS=(
  pipeline:paused
  pipeline:scope-approval-needed
  pipeline:supersede
  pipeline:skip-until-code-changes
  pipeline:skip-until-human-acts
)

# List every issue in the harness Linear project with any of the legacy labels.
# linear.sh list-issues --project <slug> --label <name> returns one ENG-N per line.
total=0
removed=0
for legacy in "${LEGACY_LABELS[@]}"; do
  log "scanning for issues with label '$legacy'"
  while IFS= read -r issue; do
    [[ -z "$issue" ]] && continue
    total=$((total + 1))
    if (( DRY_RUN == 1 )); then
      log "[DRY_RUN] would remove $legacy from $issue"
    else
      bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "$legacy" 2>/dev/null || true
      removed=$((removed + 1))
    fi
  done < <(bash "$SCRIPT_DIR/linear.sh" list-issues --label "$legacy" 2>/dev/null || true)
done

log "migrate-labels: found=$total removed=$removed (dry_run=$DRY_RUN)"
EOF
chmod +x bin/migrate-labels.sh
```

NOTE: `bin/linear.sh list-issues --label <name>` may not exist as-is.
Verify the actual API before relying on it. If absent, fall back to
listing every issue and filtering client-side via `jq` on each issue's
labels.

- [ ] **Step 2: Smoke (dry-run)**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/migrate-labels.sh --dry-run 2>&1 | head -20
```

Expected: prints scan-and-would-remove lines for any issues currently
carrying legacy labels; exits 0.

- [ ] **Step 3: Commit**

```bash
git add bin/migrate-labels.sh
git commit -m "feat(ENG-60-T3.9): one-time legacy-label drain script

bin/migrate-labels.sh iterates every Linear issue in the harness's
project and removes the five legacy pipeline-namespace labels (paused,
scope-approval-needed, supersede, skip-until-code-changes,
skip-until-human-acts). Idempotent — safe to re-run. Supports --dry-run.

This script is a one-time complement to T2.13's per-transition drain;
it cleans up issues that haven't transitioned during the Phase 2 soak.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.10: Update `docs/pipeline-vocabulary.md` — remove "Migration notes" section

**Files:**
- Modify: `docs/pipeline-vocabulary.template.md`.
- Regenerate: `docs/pipeline-vocabulary.md`.

- [ ] **Step 1: Remove the migration notes section from the template**

Edit `docs/pipeline-vocabulary.template.md` to delete the entire
"## Migration notes (Phase 2 only)" section (and its body). The
`<!-- GENERATED:registry -->` block stays; the worked-example section
stays; only the migration-notes section goes.

- [ ] **Step 2: Regenerate**

```bash
bash bin/generate-vocabulary-doc.sh
```

- [ ] **Step 3: Commit**

```bash
git add docs/pipeline-vocabulary.template.md docs/pipeline-vocabulary.md
git commit -m "docs(ENG-60-T3.10): drop Migration notes section from vocabulary doc

The migration notes section described the dual-shape parsing window
(Phase 2 only). After Phase 3, there is only one vocabulary; the
migration-notes prose is no longer accurate. Remove from template,
regenerate the published doc.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.11: Operator-driven label migration (manual)

This is a manual step.

- [ ] **Operator runs the migration script in dry-run first to inventory:**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/migrate-labels.sh --dry-run
```

Review the output. If the count is nonzero and unexpected, investigate
why those issues didn't drain through normal transitions.

- [ ] **Operator runs the migration for real:**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/migrate-labels.sh
```

- [ ] **Operator confirms post-migration state:**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/migrate-labels.sh --dry-run
```

Expected: `found=0`. If any legacy labels remain, the migration didn't
catch them — investigate the API path.

### Task 3.12: Final regression sweep

- [ ] **Step 1: Run every test suite**

```bash
cd /Users/rajatgoyal/code/twinning-harness
for t in common-test verdict-handler-test scope-check-test run-stage-test halt-sprawl-test halt-sprawl-adversarial-test classify-failure-test reconcile-test poll-slot-test run-local-sweep-test run-local-helpers-adversarial-test pipeline-test agent-prompts-content-test render-prompt-test dispatch-test; do
  printf '%-45s ' "$t"
  TARGET_REPO=$(pwd) bash bin/${t}.sh 2>&1 | grep -E 'passed|PASS|FAIL|RESULTS' | tail -1
done
```

Expected: every suite green. NOTE: `post-verdict-test` is no longer in the
list (deleted in T3.5).

- [ ] **Step 2: Confirm no legacy-shape strings in functional code**

```bash
grep -rn 'pipeline-stage-summary\|pipeline-rejection:\|pipeline-rejection-target\|pipeline-halt:\|pipeline-wait:\|pipeline-decision:\|pipeline-sig:\|pipeline-metric:' bin/ docs/ AGENT_PROMPTS.md CLAUDE.md \
  | grep -v 'commit message\|legacy' \
  | head -20
```

Expected: matches only in changelog/commit-message-style strings, never in
functional code paths.

- [ ] **Step 3: Verify the deleted binaries are gone**

```bash
ls bin/halt.sh bin/post-verdict.sh bin/post-verdict-test.sh 2>&1 || echo "all deleted"
```

Expected: "No such file or directory" for each (or "all deleted").

- [ ] **Step 4: Verify verb-form CLI is rejected**

```bash
TARGET_REPO=$(pwd) bash bin/render-prompt.sh implement 2>&1 | tail -2 || echo "rejected"
```

Expected: rejection message.

- [ ] **Step 5: Document Phase 3 closure**

After all the above pass, the work is complete. No additional commit
required for the regression sweep itself — it's pure verification.

## Cross-phase considerations

### Backwards compatibility

After Phase 3, the harness has one vocabulary and one entry point.
Operators with shell aliases for `halt.sh`/`post-verdict.sh`/verb-form
stage names must update them. There is no compatibility shim left.

### Rollback

Phase 3 is mostly deletions. To roll back:
- Revert each commit in reverse order.
- The migration-script run (T3.11) is one-way (labels removed); to restore
  legacy labels would require re-applying them by hand.

### Test discipline

Every code change in Phase 3 is paired with running the relevant test
suites. Commits land only on green.

## Self-review checklist (executed inline)

- **Spec coverage:** Every Phase 3 outline item from the parent plan
  (T3.1–T3.7) is covered. The 10 Phase 2 carryovers (C-T3.A through
  C-T3.J) all map to tasks in this sub-plan:
  - C-T3.A → T3.4
  - C-T3.B → T3.4
  - C-T3.C → T3.4
  - C-T3.D → T3.4
  - C-T3.E → T3.2
  - C-T3.F → T3.3
  - C-T3.G → T3.5
  - C-T3.H → T3.5
  - C-T3.I → T3.8
  - C-T3.J → T3.7
- **Placeholder scan:** No "TBD" or "TODO" in concrete tasks. T3.11 is
  explicitly manual.
- **Type consistency:** Field names (stages, halt reasons, decision actions)
  unchanged from Phase 2.

## References

- Spec: `docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md`
- Phase 1 plan: `docs/plans/2026-05-02-eng-60-pipeline-vocabulary-simplification.md`
- Phase 2 plan: `docs/plans/2026-05-03-eng-60-phase-2-write-new.md`
- Linear: ENG-60
