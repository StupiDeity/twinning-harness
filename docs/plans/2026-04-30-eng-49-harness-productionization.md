---
linear: ENG-49
topic: Harness productionization — generalize for any target stack (8 gaps)
date: 2026-04-30
status: draft
---

# Plan — ENG-49 harness productionization

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Implementation plan for the design in
`docs/brainstorms/2026-04-30-eng-49-harness-productionization-design.md`.

## Goal

Land a single PR off `main` (`eng-49-harness-productionization`) with **8 commits**, one per gap, that:

1. Makes `state.local.json::orchestrator.paused` override actually take effect (Gap #6).
2. Stops emitting `FATAL: state not in cache: null` from `apply_transition` (Gap #5).
3. Adds Linear `released → Done` native-state hook to `apply_transition` (Gap #4).
4. Adds the `render_pr_body` helper for orchestrator-assembled PR bodies (foundational).
5. Moves PR creation out of the UI agent and into `apply_transition`'s `to == reviewing` path (Gap #1).
6. Aligns stage allowlists with prompt instructions per a new `dispatch-test` contract (Gap #7).
7. Wires `halt.sh resolve --decision resume` to call `verdict_handler` first (Gap #2).
8. Adds `bin/post-verdict.sh` helper for safe operator marker posting (Gap #3).

After merge, any harness-self ticket should reach Done with at most one operator approval review and (optionally) one `halt.sh resolve --decision resume`.

## Architecture

Side effects of stage transitions are centralized in `verdict-handler::apply_transition`. The same primitive that today owns label swaps, `pipeline:halted` removal, and the `to == reviewing → In Review` Linear-state hook gains two new responsibilities: `to == released → Done` and `gh pr create` on `to == reviewing`. Stage agents (implement, UI) stop owning PR creation entirely. Their prompts and allowlists shrink correspondingly.

## Tech Stack

- Bash 3+ (Darwin default; harness target).
- `jq` for JSON parsing.
- `gh` CLI for GitHub API (PR creation, listing).
- Harness scripts: `verdict-handler.sh`, `dispatch.sh`, `halt.sh`, `linear.sh`, `common.sh`, `run-local.sh`, `poll.sh`, `setup.sh`.
- Test pattern: sentinel-guarded `*-test.sh` files, source target script, override `SCRIPT_DIR` / `TARGET_REPO` post-source, stub `linear.sh` / `gh` via `STUB_DIR`.

## Assumption inventory

- **A-001:** `bin/verdict-handler.sh` is sentinel-guarded (line 282-end: `export -f` only at top level after function defs). Sourcing from `halt.sh` is safe.
- **A-002:** `apply_transition` line 167 already calls `bash linear.sh remove-label "$issue" "pipeline:halted"`. After a successful transition, the halt label is removed by `apply_transition`; `halt.sh::resolve` does not need to re-remove.
- **A-003:** `bin/dispatch.sh::allowed_tools_for` (lines 138-162) is the single switch statement for stage allowlists. Tests in `dispatch-test.sh` Group 1 already parse it.
- **A-004:** `AGENT_PROMPTS.md` has exactly 9 numbered H2 sections, each with exactly one fenced ``` block. `render-prompt.sh::STAGE_TO_SECTION` keys this map. Edits must keep fence count at exactly 2 per section.
- **A-005:** `linear.sh transition-state` at line 311 reads `state_uuid="$(state_id "$state_name")"` and dies if null. `state_id` reads `$IDS_CACHE` (Linear IDs cache, populated by `bin/linear.sh refresh-cache`).
- **A-006:** `is_orchestrator_paused` in `common.sh:126-136` reads `STATE_FILE` first then `CONFIG`. Already exported (line 151). NB during Task 1 implementation: the original jq expression `.orchestrator.paused // empty` discarded boolean `false` (jq's `//` operator treats `false` as falsy), so the regression test for Gap #6 required also rewriting that expression to `if .orchestrator.paused != null then .orchestrator.paused else empty end`. Task 1's actual commit therefore touches `bin/common.sh` in addition to the planned files.
- **A-007:** Stage-summary Linear comments use sigs `completion/<stage>/<issue>` (per AGENT_PROMPTS.md line 34). The orchestrator posts these from the agent's stage-summary file, so by the time `apply_transition` runs for `to == reviewing`, `completion/implement/<issue>` and `completion/ui/<issue>` exist as Linear comments.
- **A-008:** Brainstorm and plan docs live at `$TARGET_REPO/docs/brainstorms/*.md` and `$TARGET_REPO/docs/plans/*.md` with `linear: ENG-N` frontmatter. The `reconcile.sh` doc-resolution pattern is the reference for finding them.
- **A-009:** GitHub App installation token is minted in `run-local.sh:87` and exported as `GITHUB_TOKEN`. `apply_transition` runs in the same process tree and inherits it.
- **A-010:** `bin/halt.sh` is short (~52 lines) and sentinel-guarded; `resolve()` is a single function and the only behavior change in this work.
- **A-011:** `verdict_handler` returns 0 (transitioned), 1 (halt-marker preserved), or 2 (protocol violation). Document at line 7.

## File Structure

```
bin/
  verdict-handler.sh                   modified  — defensive guard, released hook, PR-create hook (Tasks 2, 3, 5)
  verdict-handler-test.sh              modified  — new test cases per Tasks 2, 3, 5
  setup.sh                             modified  — require linear.native_states.done at bootstrap (Task 2)
  setup-test.sh                        modified  — assert config requirement (Task 2)
  poll.sh                              modified  — use is_orchestrator_paused (Task 1)
  run-local.sh                         modified  — use is_orchestrator_paused (Task 1)
  run-local-helpers-adversarial-test.sh  modified — paused-override regression (Task 1)
  render-pr-body.sh                    NEW       — body assembler helper (Task 4)
  render-pr-body-test.sh               NEW       — unit tests for renderer (Task 4)
  dispatch.sh                          modified  — UI loses gh pr*, QA gains gh pr list (Tasks 5, 6)
  dispatch-test.sh                     modified  — prompt↔allowlist contract (Tasks 5, 6)
  halt.sh                              modified  — resolve calls verdict_handler first (Task 7)
  halt-test.sh                         NEW       — covers Gap #2 rc paths (Task 7)
  post-verdict.sh                      NEW       — operator marker helper (Task 8)
  post-verdict-test.sh                 NEW       — covers Gap #3 (Task 8)
  agent-prompts-content-test.sh        NEW       — prompt-content invariants (Tasks 3, 5)

AGENT_PROMPTS.md                       modified  — §3 + §4 PR-creation removed; §8 wording updated (Tasks 3, 5)
CLAUDE.md                              modified  — post-verdict.sh under Common commands (Task 8)
```

No changes to: `metrics.sh`, `slack.sh`, `scope-check.sh`, `classify-failure.sh`, `reconcile.sh`, `gh-app-token.sh`, `learned-rules/*`, `launchd/*`, `.github/`, `docs/knowledge/*`.

## Command API contract

No CLI argv changes to existing scripts. Two new scripts (`render-pr-body.sh` is internal/source-able only, not invoked directly; `post-verdict.sh` and `halt.sh` get user-facing changes). `halt.sh resolve` now exits non-zero when `verdict_handler` reports protocol violation; this is a deliberate breaking-change for the failing case, with a clear stderr message naming the violation.

---

## Task 1 — Gap #6: respect `state.local.json::orchestrator.paused` override

**depends_on:** []

**Files:**
- Modify: `bin/poll.sh:351`
- Modify: `bin/run-local.sh:91`
- Modify: `bin/run-local-helpers-adversarial-test.sh` (append new case)

- [ ] **Step 1.1: Write failing regression case in `run-local-helpers-adversarial-test.sh`**

Append at the end of `bin/run-local-helpers-adversarial-test.sh`, before the final `printf 'RESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"` summary block:

```bash
# ─── Gap #6: state.local.json paused override is honored ──────────────
# Reproducer for ENG-49 Gap #6. config.json::orchestrator.paused=true must
# be overridden by state.local.json::orchestrator.paused=false so the
# orchestrator can resume after a manual paused-state edit. Both poll.sh
# and run-local.sh must consult is_orchestrator_paused (not config_get).
test_paused_override_honored() {
  local tdir; tdir="$(mktemp -d -t twinning-paused.XXXXXX)"
  local cfg="$tdir/config.json" sf="$tdir/state.local.json"
  jq -n '{orchestrator:{paused:true}}' > "$cfg"
  jq -n '{orchestrator:{paused:false}}' > "$sf"
  local got
  CONFIG="$cfg" STATE_FILE="$sf" got="$(is_orchestrator_paused)"
  assert_eq "paused-override state.local wins" "false" "$got"
  rm -rf "$tdir"
}
test_paused_override_honored
```

- [ ] **Step 1.2: Run the test, verify it PASSES (override helper already correct)**

```
bash bin/run-local-helpers-adversarial-test.sh 2>&1 | tail -10
```

Expected: includes `OK: paused-override state.local wins` *after* the Step 1.5/1.6/A-006 jq fix has landed. NB: the test will FAIL against the pristine `is_orchestrator_paused` because `.orchestrator.paused // empty` in jq discards boolean `false`. If you see the test fail at this step, that is the latent bug A-006 documents — apply the jq rewrite from A-006 (also in `bin/common.sh::is_orchestrator_paused`) along with the call-site swaps in Steps 1.5/1.6.

- [ ] **Step 1.3: Add a second case asserting the *call sites* use the helper**

Append immediately after the previous block:

```bash
# Verify poll.sh and run-local.sh USE is_orchestrator_paused, not the
# bypass call config_get '.orchestrator.paused'. This is a static check:
# fail if the bypass appears outside common.sh (its definitional home).
test_paused_callsites_use_helper() {
  local bypass_count
  bypass_count="$(grep -nE "config_get[[:space:]]+'\.orchestrator\.paused'" \
    "$SCRIPT_DIR/poll.sh" "$SCRIPT_DIR/run-local.sh" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "no config_get bypass in poll.sh/run-local.sh" "0" "$bypass_count"
}
test_paused_callsites_use_helper
```

- [ ] **Step 1.4: Run, verify it FAILS (the bypass is still in place)**

```
bash bin/run-local-helpers-adversarial-test.sh 2>&1 | tail -10
```

Expected: includes `FAIL: no config_get bypass in poll.sh/run-local.sh` with `expected: 0  got: 2`.

- [ ] **Step 1.5: Fix `bin/poll.sh:351`**

In `bin/poll.sh::main`, change line 351:

```bash
  paused="$(config_get '.orchestrator.paused')"
```

to:

```bash
  paused="$(is_orchestrator_paused)"
```

- [ ] **Step 1.6: Fix `bin/run-local.sh:91`**

In `bin/run-local.sh`, change line 91:

```bash
paused="$(config_get '.orchestrator.paused')"
```

to:

```bash
paused="$(is_orchestrator_paused)"
```

Also update the operator-rescue hint at line 94 (which suggests editing `$CONFIG`):

```bash
  log "tick skipped: orchestrator.paused=true"
  log "reset with: jq '.orchestrator.paused=false' $CONFIG > /tmp/c && mv /tmp/c $CONFIG"
```

to:

```bash
  log "tick skipped: orchestrator.paused=true"
  log "reset with: bash $HARNESS_ROOT/bin/reset-pipeline.sh   # writes state.local.json (preferred)"
  log "             OR: jq '.orchestrator.paused=false' \$CONFIG > /tmp/c && mv /tmp/c \$CONFIG (legacy)"
```

- [ ] **Step 1.7: Run regression suite for both helper test and full suite**

```
bash bin/run-local-helpers-adversarial-test.sh 2>&1 | tail -5
```

Expected: ends with `RESULTS: <N> passed, 0 failed`.

```
for t in bin/*-test.sh; do bash "$t" >/dev/null 2>&1 && printf 'PASS %s\n' "$t" || printf 'FAIL %s\n' "$t"; done
```

Expected: every line starts with `PASS`.

- [ ] **Step 1.8: Commit**

NB: include `bin/common.sh` in the `git add` because the jq fix from A-006 must land in the same commit as the call-site swaps and regression test. Without it, the regression test fails.

```
git add bin/poll.sh bin/run-local.sh bin/common.sh bin/run-local-helpers-adversarial-test.sh
git commit -m "$(cat <<'EOF'
fix(ENG-49): respect state.local.json paused override in poll and tick

bin/poll.sh:351 and bin/run-local.sh:91 read .orchestrator.paused
directly via config_get, bypassing the is_orchestrator_paused helper
that respects STATE_FILE. Switch both call sites to the helper so the
documented runtime override actually takes effect. Also fix a latent
jq bug in is_orchestrator_paused: `.orchestrator.paused // empty`
discards boolean `false` (jq's `//` treats false as falsy), preventing
state.local.json overrides where paused=false from taking effect.
Update the run-local.sh reset-hint to point at reset-pipeline.sh
(which writes state.local.json, the preferred path).

Closes Gap #6 of ENG-49.
EOF
)"
```

---

## Task 2 — Gap #5: defensive guard for native-state hook in `apply_transition`

**depends_on:** []

**Files:**
- Modify: `bin/verdict-handler.sh:151-155` (existing native-state hook)
- Modify: `bin/verdict-handler-test.sh` (new case)
- Modify: `bin/setup.sh` (add config requirement post-bootstrap)
- Modify: `bin/setup-test.sh` (assert config requirement)

- [ ] **Step 2.1: Write failing test for defensive guard in `verdict-handler-test.sh`**

Append a new case before the `printf '\nRESULTS:'` line:

```bash
# ─── ENG-49 Gap #5: defensive guard — null/empty state name does not die ──
# Repro: config.linear.native_states.in_review missing → state_name="null".
# apply_transition's |reviewing| hook must skip the transition-state call
# and emit a single log line, NOT die (no FATAL output, transition still
# completes the label swap).
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/config.json" <<'JSON'
{
  "orchestrator": {"paused": false},
  "linear": {"native_states": {}}
}
JSON
ORIG_CONFIG="$CONFIG"
CONFIG="$STUB_DIR/config.json"
export CONFIG

apply_transition_log="$(apply_transition "ENG-950" "ui" "reviewing" "" 2>&1)"
CONFIG="$ORIG_CONFIG"
export CONFIG

if printf '%s\n' "$apply_transition_log" | grep -q 'FATAL: state not in cache'; then
  fail_at "Gap-5 defensive guard: no FATAL on missing in_review" \
    "log contained FATAL — defensive guard not in place"
elif printf '%s\n' "$apply_transition_log" | grep -q 'skipping native-state hook'; then
  pass_at "Gap-5 defensive guard: missing in_review logs and skips"
else
  fail_at "Gap-5 defensive guard: missing in_review logs and skips" \
    "log neither FATAL nor skip-message: $apply_transition_log"
fi
```

(Use the test's existing `pass_at` / `fail_at` helpers; if the file uses different names, adapt — read the top of `verdict-handler-test.sh` first.)

- [ ] **Step 2.2: Run, verify it FAILS**

```
bash bin/verdict-handler-test.sh 2>&1 | grep -E 'Gap-5|RESULTS:' | tail -5
```

Expected: `FAIL: Gap-5 defensive guard: ...` (because today the `transition-state` call dies on the null state name).

- [ ] **Step 2.3: Implement the defensive guard in `apply_transition`**

In `bin/verdict-handler.sh`, replace the existing native-state hook block at lines 151-155:

```bash
  if [[ "$to" == "reviewing" ]]; then
    local in_review_state
    in_review_state="$(config_get '.linear.native_states.in_review')"
    bash "$_VH_SCRIPT_DIR/linear.sh" transition-state "$issue" "$in_review_state" || true
  fi
```

with:

```bash
  if [[ "$to" == "reviewing" ]]; then
    local in_review_state
    in_review_state="$(config_get '.linear.native_states.in_review')"
    if [[ -n "$in_review_state" && "$in_review_state" != "null" ]]; then
      bash "$_VH_SCRIPT_DIR/linear.sh" transition-state "$issue" "$in_review_state" || true
    else
      log "verdict-handler: skipping native-state hook to In Review (config.linear.native_states.in_review not set)"
    fi
  fi
```

- [ ] **Step 2.4: Run, verify it PASSES**

```
bash bin/verdict-handler-test.sh 2>&1 | grep -E 'Gap-5|RESULTS:' | tail -5
```

Expected: `OK: Gap-5 defensive guard: ...` and `RESULTS: <N> passed, 0 failed`.

- [ ] **Step 2.5: Add config-requirement assertion to `setup.sh`**

In `bin/setup.sh`, find the config-bootstrap section near line 494 (the `if (.orchestrator.paused // null) == null then ... end` jq block). Below the orchestrator.paused defaulting, add:

```bash
# ENG-49 Gap #5: native_states must be populated. Setup dies loudly if
# either is missing post-bootstrap so verdict-handler's hooks have valid
# state names to look up.
require_native_states() {
  local cfg="$1" key
  for key in in_review done; do
    local v
    v="$(jq -r ".linear.native_states.${key} // empty" "$cfg")"
    [[ -n "$v" ]] || die "config.linear.native_states.${key} not set in $cfg — populate before re-running setup"
  done
}
```

Then, near the end of the config-bootstrap step (after the file is written), call:

```bash
require_native_states "$CONFIG"
```

(Find the right insertion point by reading 50 lines around line 525 — the `(.orchestrator.paused != null) and ...` validation block — and add the call adjacent to it.)

- [ ] **Step 2.6: Add a corresponding test in `setup-test.sh`**

Append at the end of `bin/setup-test.sh` before its summary block:

```bash
# ─── ENG-49 Gap #5: setup requires linear.native_states.{in_review,done} ──
test_setup_requires_native_states() {
  local tdir; tdir="$(mktemp -d -t twinning-setup-states.XXXXXX)"
  local cfg="$tdir/config.json"
  jq -n '{orchestrator:{paused:false}, linear:{native_states:{in_review:null}}}' > "$cfg"
  if (set -e; require_native_states "$cfg") 2>/dev/null; then
    fail_at "require_native_states rejects missing 'done' key" "accepted bad config"
  else
    pass_at "require_native_states rejects missing 'done' key"
  fi
  rm -rf "$tdir"
}
test_setup_requires_native_states
```

(`pass_at` / `fail_at` are the existing helpers in `setup-test.sh:11-12`.)

- [ ] **Step 2.7: Run setup-test, verify PASS**

```
bash bin/setup-test.sh 2>&1 | tail -10
```

Expected: includes the new OK line; final `RESULTS:` shows 0 failed.

- [ ] **Step 2.8: Manually populate `linear.native_states.done` in the live config**

```
jq '.linear.native_states.done = "Done"' "$TARGET_REPO/.pipeline-config/config.json" > /tmp/c && mv /tmp/c "$TARGET_REPO/.pipeline-config/config.json"
```

(`Done` is the canonical Linear state name; `state_id` resolves it via `$IDS_CACHE`. Re-run `bash bin/linear.sh refresh-cache` if needed.)

- [ ] **Step 2.9: Run full regression suite**

```
for t in bin/*-test.sh; do bash "$t" >/dev/null 2>&1 && printf 'PASS %s\n' "$t" || printf 'FAIL %s\n' "$t"; done
```

Expected: every line starts with `PASS`.

- [ ] **Step 2.10: Commit**

```
git add bin/verdict-handler.sh bin/verdict-handler-test.sh bin/setup.sh bin/setup-test.sh
git commit -m "$(cat <<'EOF'
fix(ENG-49): defensive guard for native-state hook in apply_transition

apply_transition's to==reviewing hook called transition-state with a
state name that was 'null' when config.linear.native_states.in_review
was missing, dying with FATAL inside linear.sh:316. The || true at the
caller swallowed the exit but the FATAL log still fired.

Defensively guard the call: skip and log if the resolved state name is
empty/null. Also require config.linear.native_states.{in_review,done}
at setup time; setup dies loudly if either is missing.

Closes Gap #5 of ENG-49.
EOF
)"
```

---

## Task 3 — Gap #4: native-state hook for `released → Done`

**depends_on:** [2]

**Files:**
- Modify: `bin/verdict-handler.sh::apply_transition` (extend native-state hook block)
- Modify: `bin/verdict-handler-test.sh` (new case)
- Modify: `AGENT_PROMPTS.md §8` (wording)
- Create: `bin/agent-prompts-content-test.sh`

- [ ] **Step 3.1: Write failing test for `to == released` Linear-state transition**

Append to `bin/verdict-handler-test.sh` before the summary block:

```bash
# ─── ENG-49 Gap #4: to==released transitions Linear status to Done ─────
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/config.json" <<'JSON'
{
  "orchestrator": {"paused": false},
  "linear": {"native_states": {"in_review": "In Review", "done": "Done"}}
}
JSON
ORIG_CONFIG="$CONFIG"
CONFIG="$STUB_DIR/config.json"
export CONFIG

# Capture transition-state calls made by apply_transition.
TRANSITION_CALLS="$STUB_DIR/transition-state-calls.log"
: > "$TRANSITION_CALLS"
# Modify the linear.sh stub to capture transition-state calls.
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  transition-state) printf '%s\\t%s\\n' "\$2" "\$3" >> "$TRANSITION_CALLS" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"
ORIG_VH_DIR="$_VH_SCRIPT_DIR"
_VH_SCRIPT_DIR="$STUB_DIR"

apply_transition "ENG-960" "building" "released" "" >/dev/null 2>&1 || true

CONFIG="$ORIG_CONFIG"
_VH_SCRIPT_DIR="$ORIG_VH_DIR"
export CONFIG

if grep -qE '^ENG-960\sDone$' "$TRANSITION_CALLS"; then
  pass_at "Gap-4 to==released transitions to Done"
else
  fail_at "Gap-4 to==released transitions to Done" \
    "captured: $(cat "$TRANSITION_CALLS" 2>/dev/null || echo '<empty>')"
fi
```

- [ ] **Step 3.2: Run, verify it FAILS**

```
bash bin/verdict-handler-test.sh 2>&1 | grep -E 'Gap-4|RESULTS:' | tail -5
```

Expected: `FAIL: Gap-4 to==released transitions to Done`.

- [ ] **Step 3.3: Extend the native-state hook in `apply_transition`**

In `bin/verdict-handler.sh`, extend the block from Task 2 (now at the same lines 151-160 after Task 2's edit). The reviewing-only `if` becomes an `if/elif`:

```bash
  if [[ "$to" == "reviewing" ]]; then
    local in_review_state
    in_review_state="$(config_get '.linear.native_states.in_review')"
    if [[ -n "$in_review_state" && "$in_review_state" != "null" ]]; then
      bash "$_VH_SCRIPT_DIR/linear.sh" transition-state "$issue" "$in_review_state" || true
    else
      log "verdict-handler: skipping native-state hook to In Review (config.linear.native_states.in_review not set)"
    fi
  elif [[ "$to" == "released" ]]; then
    local done_state
    done_state="$(config_get '.linear.native_states.done')"
    if [[ -n "$done_state" && "$done_state" != "null" ]]; then
      bash "$_VH_SCRIPT_DIR/linear.sh" transition-state "$issue" "$done_state" || true
    else
      log "verdict-handler: skipping native-state hook to Done (config.linear.native_states.done not set)"
    fi
  fi
```

- [ ] **Step 3.4: Run, verify it PASSES**

```
bash bin/verdict-handler-test.sh 2>&1 | grep -E 'Gap-4|RESULTS:' | tail -5
```

Expected: `OK: Gap-4 to==released transitions to Done` and `RESULTS: <N> passed, 0 failed`.

- [ ] **Step 3.5: Update `AGENT_PROMPTS.md §8` wording**

In `AGENT_PROMPTS.md`, replace lines 1303-1305:

```
   Do NOT change Linear state here — the `pipeline-release.yml` sweep already swapped
   `stage:building` → `stage:released` + status → Done. You are adding context, not
   advancing state.
```

with:

```
   Do NOT change Linear state here — the orchestrator (`verdict-handler::apply_transition`)
   advances `stage:building` → `stage:released` and Linear native status → Done as
   transition side-effects. You are adding context, not advancing state.
```

- [ ] **Step 3.6: Create `bin/agent-prompts-content-test.sh`**

Write a new file `bin/agent-prompts-content-test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# ENG-49: Invariants on AGENT_PROMPTS.md content.
#
# Asserts prompt-content rules that this PR introduces and that future
# edits must preserve. Reads AGENT_PROMPTS.md directly; no external stubs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMPTS="$HARNESS_ROOT/AGENT_PROMPTS.md"
[[ -f "$PROMPTS" ]] || { printf 'FATAL: not found: %s\n' "$PROMPTS" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  reason: %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# Helpers — extract a single H2 section's body (between its line and the next H2).
section_body() {
  local heading="$1"
  awk -v h="$heading" '
    BEGIN{in_section=0}
    /^## /{ if (in_section) exit; if (index($0, h)) {in_section=1; next} }
    in_section{print}
  ' "$PROMPTS"
}

s3="$(section_body "## 3. Implementation Agent (Backend)")"
s4="$(section_body "## 4. UI Agent (Frontend)")"
s8="$(section_body "## 8. Release Agent")"

# §3 — implement does not own PR creation.
if printf '%s\n' "$s3" | grep -q 'Do NOT create a PR'; then
  ok "§3 contains 'Do NOT create a PR'"
else
  nope "§3 contains 'Do NOT create a PR'" "phrase missing"
fi
if printf '%s\n' "$s3" | grep -qE 'gh pr create'; then
  nope "§3 lacks 'gh pr create'" "string 'gh pr create' present"
else
  ok "§3 lacks 'gh pr create'"
fi

# §4 — UI does not own PR creation.
if printf '%s\n' "$s4" | grep -qE 'gh pr create'; then
  nope "§4 lacks 'gh pr create'" "string 'gh pr create' present"
else
  ok "§4 lacks 'gh pr create'"
fi
if printf '%s\n' "$s4" | grep -qE '^[[:space:]]*PR creation'; then
  nope "§4 lacks 'PR creation' heading" "heading present"
else
  ok "§4 lacks 'PR creation' heading"
fi

# §4 pass-through clause is preserved verbatim (regression — must not tighten).
if printf '%s\n' "$s4" | grep -qF 'this stage is a pass-through: skip implementation, write a stage summary noting the no-op, post `<!-- pipeline-stage-summary: ui -->`, and exit'; then
  ok "§4 pass-through clause preserved"
else
  nope "§4 pass-through clause preserved" "phrase missing or altered"
fi

# §8 — no longer attributes state-swap to pipeline-release.yml.
if printf '%s\n' "$s8" | grep -qE 'pipeline-release\.yml sweep already swapped'; then
  nope "§8 lacks obsolete 'pipeline-release.yml sweep' phrase" "phrase still present"
else
  ok "§8 lacks obsolete 'pipeline-release.yml sweep' phrase"
fi

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
```

- [ ] **Step 3.7: Run the new test**

```
chmod +x bin/agent-prompts-content-test.sh
bash bin/agent-prompts-content-test.sh
```

Expected: `RESULTS: 5 passed, 0 failed`.

The §4 PR-creation block is not yet removed (that's Task 5), so the two §4 assertions in the test draft above (`§4 lacks 'gh pr create'`, `§4 lacks 'PR creation' heading`) would fail in this commit. Stub them now and Task 5 re-enables them. Replace the two §4-PR-creation assertions with placeholder pass lines:

```bash
# §4 PR-creation removal asserted in Task 5 (this commit only seeds §3/§8).
ok "§4 PR-creation removal — asserted in Task 5"
ok "§4 'PR creation' heading removal — asserted in Task 5"
```

(Task 5 will replace these two lines with the real assertions from the original draft above.)

- [ ] **Step 3.8: Run full regression suite**

```
for t in bin/*-test.sh; do bash "$t" >/dev/null 2>&1 && printf 'PASS %s\n' "$t" || printf 'FAIL %s\n' "$t"; done
```

Expected: every line starts with `PASS`.

- [ ] **Step 3.9: Commit**

```
git add bin/verdict-handler.sh bin/verdict-handler-test.sh AGENT_PROMPTS.md bin/agent-prompts-content-test.sh
git commit -m "$(cat <<'EOF'
feat(ENG-49): native-state hook for released → Done

Extends apply_transition's native-state hook with a `to == released`
branch that transitions Linear native status to the configured 'done'
state, mirroring the existing `to == reviewing → In Review` branch.
Eliminates the need for the Tauri target's pipeline-release.yml
state-swap on the harness; verdict-handler is now the single source of
truth for stage→state mapping.

Also seeds bin/agent-prompts-content-test.sh, a test file dedicated to
prompt-content invariants. Two assertions for §4 PR-creation removal
are stubbed and re-enabled in Task 5.

Closes Gap #4 of ENG-49.
EOF
)"
```

---

## Task 4 — `render-pr-body.sh` helper

**depends_on:** []

**Files:**
- Create: `bin/render-pr-body.sh`
- Create: `bin/render-pr-body-test.sh`

- [ ] **Step 4.1: Write the failing test first — full-stack fixture**

Create `bin/render-pr-body-test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# ENG-49 Gap #1 helper: render-pr-body assembles a PR body from
# brainstorm + plan + Linear stage-summary comments.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

# Allocate temp roots ENG-20-style (only platform tmp dirs allowed).
_TEST_TARGET="$(mktemp -d -t twinning-rpb-target.XXXXXX)"
_TEST_STUB="$(mktemp -d -t twinning-rpb-stub.XXXXXX)"
case "$_TEST_TARGET" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) echo "REFUSING bad tmp" >&2; exit 99 ;; esac
case "$_TEST_STUB"   in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) echo "REFUSING bad tmp" >&2; exit 99 ;; esac
trap 'rm -rf "$_TEST_TARGET" "$_TEST_STUB"' EXIT

# Stub TARGET_REPO with brainstorm + plan docs.
mkdir -p "$_TEST_TARGET/docs/brainstorms" "$_TEST_TARGET/docs/plans" "$_TEST_TARGET/.pipeline-config/schemas"
cat > "$_TEST_TARGET/docs/brainstorms/2026-04-30-eng-999-design.md" <<'MD'
---
linear: ENG-999
title: Test feature
date: 2026-04-30
---

# Test feature

## Overview

- First overview bullet
- Second overview bullet
- Third overview bullet

## Other section
Should not appear in PR body.
MD

cat > "$_TEST_TARGET/docs/plans/2026-04-30-eng-999.md" <<'MD'
---
linear: ENG-999
---

# Plan

## Failure Mode → Test Map
- F-001 → bin/foo-test.sh::test_foo
- F-002 → bin/bar-test.sh::test_bar
MD

cat > "$_TEST_TARGET/.pipeline-config/config.json" <<'JSON'
{"project":{"slug":"test-slug"}, "orchestrator":{"paused":false}}
JSON

# Stub linear.sh to return canned stage-summary comments.
cat > "$_TEST_STUB/linear.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  get-comments)
    cat <<'JSON'
[
  {"id":"c1","createdAt":"2026-04-30T10:00:00Z","body":"**implement summary**\n\n[branch-compare](https://example.com)\n\n**TL;DR** Backend: added widget storage layer with migration.\n\nNotes: none.\n"},
  {"id":"c2","createdAt":"2026-04-30T11:00:00Z","body":"**ui summary**\n\n[branch-compare](https://example.com)\n\n**TL;DR** Frontend: pass-through (no-op).\n\nNotes: none.\n"}
]
JSON
    ;;
  get-issue)
    printf '%s' '{"data":{"issue":{"identifier":"ENG-999","title":"Test feature","state":{"name":"In Progress"},"labels":{"nodes":[{"name":"Bug"}]}}}}'
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/linear.sh"

# Source target script with overridden roots.
export TARGET_REPO="$_TEST_TARGET"
PROJECT_SLUG="test-slug"
HARNESS_STATE_DIR="$(mktemp -d -t twinning-rpb-state.XXXXXX)"
case "$HARNESS_STATE_DIR" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
trap 'rm -rf "$_TEST_TARGET" "$_TEST_STUB" "$HARNESS_STATE_DIR"' EXIT
PROJECT_STATE_DIR="$HARNESS_STATE_DIR/$PROJECT_SLUG"
mkdir -p "$PROJECT_STATE_DIR"
export HARNESS_STATE_DIR PROJECT_STATE_DIR

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=render-pr-body.sh
source "$SCRIPT_DIR/render-pr-body.sh"
# Override post-source so render_pr_body uses our stub.
_RPB_LINEAR_SH="$_TEST_STUB/linear.sh"
export _RPB_LINEAR_SH

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# ─── Case 1: full-stack fixture ───────────────────────────────────────
body="$(render_pr_body ENG-999 eng-999-feature)"

if printf '%s\n' "$body" | grep -q '## Summary'; then ok "case-1 has Summary header"; else nope "case-1 has Summary header" "no header"; fi
if printf '%s\n' "$body" | grep -q 'First overview bullet'; then ok "case-1 includes brainstorm Overview bullet"; else nope "case-1 includes Overview bullet" "missing"; fi
if printf '%s\n' "$body" | grep -qE '## Linear'; then ok "case-1 has Linear section"; else nope "case-1 has Linear" "missing"; fi
if printf '%s\n' "$body" | grep -q 'ENG-999 — Test feature'; then ok "case-1 Linear line"; else nope "case-1 Linear line" "missing"; fi
if printf '%s\n' "$body" | grep -q '## Changes'; then ok "case-1 has Changes header"; else nope "case-1 has Changes" "missing"; fi
if printf '%s\n' "$body" | grep -q 'Backend: added widget storage layer with migration'; then ok "case-1 Backend bullet"; else nope "case-1 Backend bullet" "missing"; fi
if printf '%s\n' "$body" | grep -q 'Frontend: pass-through (no-op)'; then ok "case-1 Frontend bullet"; else nope "case-1 Frontend bullet" "missing"; fi
if printf '%s\n' "$body" | grep -q '## Test plan'; then ok "case-1 has Test plan header"; else nope "case-1 has Test plan" "missing"; fi
if printf '%s\n' "$body" | grep -q 'F-001'; then ok "case-1 includes plan F-001"; else nope "case-1 plan F-001" "missing"; fi
if printf '%s\n' "$body" | grep -q '## Screenshots'; then ok "case-1 has Screenshots header"; else nope "case-1 has Screenshots" "missing"; fi

# ─── Case 2: missing brainstorm Overview falls back to Linear title ───
rm "$_TEST_TARGET/docs/brainstorms/2026-04-30-eng-999-design.md"
body2="$(render_pr_body ENG-999 eng-999-feature 2>/dev/null)"
if printf '%s\n' "$body2" | grep -q 'Test feature'; then ok "case-2 fallback uses Linear issue title"; else nope "case-2 fallback" "no title"; fi

# ─── Case 3: dry-run produces output, no Linear writes ────────────────
PIPELINE_DRY_RUN=1 body3="$(render_pr_body ENG-999 eng-999-feature 2>/dev/null)"
[[ -n "$body3" ]] && ok "case-3 dry-run produces output" || nope "case-3 dry-run" "empty body"

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
```

- [ ] **Step 4.2: Run, verify it FAILS**

```
chmod +x bin/render-pr-body-test.sh
bash bin/render-pr-body-test.sh 2>&1 | tail -5
```

Expected: `FATAL: not found: render-pr-body.sh` (or similar — the source line will fail).

- [ ] **Step 4.3: Implement `bin/render-pr-body.sh`**

Create `bin/render-pr-body.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# ENG-49 Gap #1: render-pr-body — assemble a canonical PR body from
# brainstorm doc Overview, plan doc Failure Mode → Test Map, and Linear
# stage-summary comments. Source-able; sentinel-guarded for testing.
#
# Usage:
#   render_pr_body <issue> <branch>   # prints body markdown to stdout

set -euo pipefail
_RPB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$_RPB_SCRIPT_DIR/common.sh"

# Default linear.sh path, override in tests.
_RPB_LINEAR_SH="${_RPB_LINEAR_SH:-$_RPB_SCRIPT_DIR/linear.sh}"

# Resolve the brainstorm doc whose YAML frontmatter `linear: <issue>` matches.
# Returns the doc path on stdout, or "" if not found.
_rpb_find_doc() {
  local issue="$1" subdir="$2"
  local dir="$TARGET_REPO/docs/$subdir"
  [[ -d "$dir" ]] || { printf ''; return 0; }
  local f
  for f in "$dir"/*.md; do
    [[ -f "$f" ]] || continue
    head -20 "$f" | grep -qE "^linear:[[:space:]]+${issue}[[:space:]]*$" && { printf '%s' "$f"; return 0; }
  done
  printf ''
}

# Extract the body of an H2 section by name. Stops at the next H2 or EOF.
_rpb_section_body() {
  local file="$1" heading="$2"
  [[ -f "$file" ]] || { printf ''; return 0; }
  awk -v h="$heading" '
    BEGIN{in_section=0}
    /^## /{ if (in_section) exit; if (index($0, h)) {in_section=1; next} }
    in_section{print}
  ' "$file"
}

# Extract bullet lines (leading -) from a section's body, up to N items.
_rpb_bullets() {
  local body="$1" max="${2:-3}" n=0 line
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
      printf '%s\n' "$line"
      n=$((n+1))
      (( n >= max )) && return 0
    fi
  done <<<"$body"
}

# Pull the most recent stage-summary comment for a given stage from
# the issue's comment stream.
_rpb_stage_summary() {
  local issue="$1" stage="$2" comments
  comments="$(bash "$_RPB_LINEAR_SH" get-comments "$issue" 2>/dev/null || printf '[]')"
  [[ -z "$comments" || "$comments" == "null" ]] && { printf ''; return 0; }
  jq -r --arg stage "$stage" '
    [.[] | select(.body | contains("**" + $stage + " summary**"))]
    | sort_by(.createdAt) | last | (.body // "")' <<<"$comments"
}

# Extract the TL;DR line from a stage-summary comment body.
_rpb_tldr() {
  local body="$1"
  printf '%s\n' "$body" | awk '
    /\*\*TL;DR\*\*/{
      sub(/^.*\*\*TL;DR\*\*[[:space:]]*/, "")
      print; exit
    }'
}

# Resolve the PR title type from the Linear issue's labels.
# Bug → fix; Feature/Improvement → feat; default → fix.
_rpb_title_type() {
  local issue="$1" labels_json
  labels_json="$(bash "$_RPB_LINEAR_SH" get-issue "$issue" 2>/dev/null \
    | jq -r '.data.issue.labels.nodes[].name' 2>/dev/null || true)"
  if grep -qiE 'feature|improvement' <<<"$labels_json"; then printf 'feat'
  else printf 'fix'
  fi
}

# Resolve the Linear issue title.
_rpb_title() {
  local issue="$1"
  bash "$_RPB_LINEAR_SH" get-issue "$issue" 2>/dev/null \
    | jq -r '.data.issue.title // empty' 2>/dev/null || true
}

render_pr_body() {
  local issue="$1" branch="$2"
  [[ -n "$issue" && -n "$branch" ]] || die "render_pr_body: usage <issue> <branch>"

  local title b_doc p_doc
  title="$(_rpb_title "$issue")"
  [[ -z "$title" ]] && title="$issue"
  b_doc="$(_rpb_find_doc "$issue" brainstorms)"
  p_doc="$(_rpb_find_doc "$issue" plans)"

  # ── Summary ──
  local summary_body summary_bullets
  summary_body="$(_rpb_section_body "$b_doc" "## Overview")"
  summary_bullets="$(_rpb_bullets "$summary_body" 3)"
  if [[ -z "$summary_bullets" ]]; then
    summary_bullets="- $title"
  fi

  # ── Changes ──
  local impl_summary ui_summary impl_tldr ui_tldr
  impl_summary="$(_rpb_stage_summary "$issue" "implement")"
  ui_summary="$(_rpb_stage_summary "$issue" "ui")"
  impl_tldr="$(_rpb_tldr "$impl_summary")"
  ui_tldr="$(_rpb_tldr "$ui_summary")"
  [[ -z "$impl_tldr" ]] && impl_tldr="see commit log"
  [[ -z "$ui_tldr" ]]   && ui_tldr="pass-through (no-op)"

  # ── Test plan ──
  local plan_body test_map_body test_map_bullets
  plan_body="$(_rpb_section_body "$p_doc" "## Failure Mode → Test Map")"
  test_map_bullets="$(_rpb_bullets "$plan_body" 5)"
  [[ -z "$test_map_bullets" ]] && test_map_bullets="- Every gate from the Project profile's \"Build & test gates\" section"

  # ── Render ──
  cat <<MD
## Summary
${summary_bullets}

## Linear
- ${issue} — ${title}

## Changes
- Backend: ${impl_tldr}
- Frontend: ${ui_tldr}

## Test plan
${test_map_bullets}

## Screenshots
N/A — added by review if user-visible changes

## Notes
See stage-summary comments on Linear ${issue} for deviations.
MD
}

export -f render_pr_body

# Sentinel — runnable for ad-hoc rendering.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  [[ $# -eq 2 ]] || die "usage: render-pr-body.sh <issue> <branch>"
  render_pr_body "$1" "$2"
fi
```

- [ ] **Step 4.4: Run, verify it PASSES**

```
chmod +x bin/render-pr-body.sh
bash bin/render-pr-body-test.sh 2>&1 | tail -15
```

Expected: `RESULTS: <N> passed, 0 failed`. (`<N>` should be 12: 10 case-1 OKs, 1 case-2, 1 case-3.)

- [ ] **Step 4.5: Run full regression suite**

```
for t in bin/*-test.sh; do bash "$t" >/dev/null 2>&1 && printf 'PASS %s\n' "$t" || printf 'FAIL %s\n' "$t"; done
```

Expected: every line starts with `PASS`.

- [ ] **Step 4.6: Commit**

```
git add bin/render-pr-body.sh bin/render-pr-body-test.sh
git commit -m "$(cat <<'EOF'
feat(ENG-49): render-pr-body helper for orchestrator-assembled PR bodies

bin/render-pr-body.sh defines render_pr_body <issue> <branch>, returning
the canonical PR body markdown by reading:
- brainstorm doc Overview section bullets (Summary)
- Linear issue title (Linear section)
- implement / ui stage-summary Linear comments TL;DRs (Changes)
- plan doc Failure Mode → Test Map rows (Test plan)
- "N/A — added by review if user-visible changes" placeholder (Screenshots)

Helper is source-able and sentinel-guarded for unit testing. Used by
the next commit's apply_transition PR-creation hook.

Foundational change for Gap #1 of ENG-49.
EOF
)"
```

---

## Task 5 — Gap #1: orchestrator opens PR on `to == reviewing`

**depends_on:** [3, 4]

**Files:**
- Modify: `bin/verdict-handler.sh::apply_transition` (add PR-create hook)
- Modify: `bin/verdict-handler-test.sh` (new cases)
- Modify: `AGENT_PROMPTS.md §3` and §4 (PR-creation language)
- Modify: `bin/dispatch.sh::allowed_tools_for ui` (drop `gh pr create/view/edit`)
- Modify: `bin/dispatch-test.sh` (allowlist drop assertion)
- Modify: `bin/agent-prompts-content-test.sh` (un-stub §4 PR-creation assertions from Task 3)

- [ ] **Step 5.1: Write the failing tests in `verdict-handler-test.sh`**

Append to `bin/verdict-handler-test.sh` before the summary block:

```bash
# ─── ENG-49 Gap #1: to==reviewing opens PR when none exists ───────────
# Stub gh and capture invocations.
GH_CALLS="$STUB_DIR/gh-calls.log"
: > "$GH_CALLS"
cat > "$STUB_DIR/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALLS"
case "\$1 \$2" in
  "pr list")
    # Default to "no PR exists"; tests can override via $GH_PR_LIST_RESULT.
    printf '%s' "\${GH_PR_LIST_RESULT:-0}" ;;
  "pr create") printf '%s' "https://example.com/pr/new" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/gh"

# Stub render-pr-body.sh too, to avoid the real one trying to read fixture docs.
cat > "$STUB_DIR/render-pr-body.sh" <<'SH'
render_pr_body() { printf '<stubbed body for %s>\n' "$1"; }
export -f render_pr_body
SH
ORIG_PATH="$PATH"
PATH="$STUB_DIR:$PATH"
export PATH

ORIG_VH_DIR="$_VH_SCRIPT_DIR"
_VH_SCRIPT_DIR="$STUB_DIR"

# Case A: no PR exists → gh pr create is invoked.
GH_PR_LIST_RESULT=0 apply_transition "ENG-970" "ui" "reviewing" "" >/dev/null 2>&1 || true
if grep -q 'pr create' "$GH_CALLS"; then
  pass_at "Gap-1 to==reviewing + no PR → gh pr create invoked"
else
  fail_at "Gap-1 no PR → create" "no 'pr create' in $(cat "$GH_CALLS")"
fi

# Case B: PR already exists → gh pr create is NOT invoked.
: > "$GH_CALLS"
GH_PR_LIST_RESULT=1 apply_transition "ENG-971" "ui" "reviewing" "" >/dev/null 2>&1 || true
if grep -q 'pr create' "$GH_CALLS"; then
  fail_at "Gap-1 idempotent: PR exists → no create" "found 'pr create' in $(cat "$GH_CALLS")"
else
  pass_at "Gap-1 idempotent: PR exists → no create"
fi

# Case C: to != reviewing → no gh pr calls at all.
: > "$GH_CALLS"
apply_transition "ENG-972" "implementing" "ui" "" >/dev/null 2>&1 || true
if grep -q 'pr ' "$GH_CALLS"; then
  fail_at "Gap-1 hook only fires on to==reviewing" "calls: $(cat "$GH_CALLS")"
else
  pass_at "Gap-1 hook only fires on to==reviewing"
fi

PATH="$ORIG_PATH"
_VH_SCRIPT_DIR="$ORIG_VH_DIR"
export PATH
```

- [ ] **Step 5.2: Run, verify the cases FAIL**

```
bash bin/verdict-handler-test.sh 2>&1 | grep -E 'Gap-1|RESULTS:' | tail -8
```

Expected: at least Case A fails (the hook doesn't exist yet).

- [ ] **Step 5.3: Add the PR-create hook in `apply_transition`**

In `bin/verdict-handler.sh::apply_transition`, *after* the native-state hook block (the `if/elif` from Task 3), and *before* the `if [[ -n "$side_labels" ]]; then` block (around line 157 post-Task-3), insert:

```bash
  # ENG-49 Gap #1: orchestrator opens PR when transitioning to reviewing.
  # Idempotent — skipped if a PR already exists on the branch. Failure
  # logs and proceeds; resume_in_progress_transition re-enters next tick.
  #
  # ENG-49 Gap #8 (out-of-scope): the PR is opened by the same GitHub
  # App identity that runs the review stage, so `gh pr review` is
  # blocked. Fix needs a separate bot identity; tracked as a follow-up.
  if [[ "$to" == "reviewing" ]]; then
    local branch pr_count
    branch="$(bash "$_VH_SCRIPT_DIR/linear.sh" get-issue "$issue" 2>/dev/null \
      | jq -r '.data.issue.gitBranchName // empty' 2>/dev/null || true)"
    if [[ -z "$branch" ]]; then
      log "verdict-handler: skipping PR-create hook (no branch on $issue)"
    else
      pr_count="$(gh pr list --head "$branch" --state open --json number --jq 'length' 2>/dev/null || printf '0')"
      if (( pr_count == 0 )); then
        local title body type linear_title
        # Source render-pr-body.sh on demand; allow override via PATH for tests.
        if [[ -z "${_RPB_LOADED:-}" ]]; then
          local rpb
          rpb="$(command -v render-pr-body.sh || true)"
          [[ -z "$rpb" ]] && rpb="$_VH_SCRIPT_DIR/render-pr-body.sh"
          # shellcheck source=render-pr-body.sh
          source "$rpb"
          _RPB_LOADED=1
        fi
        linear_title="$(bash "$_VH_SCRIPT_DIR/linear.sh" get-issue "$issue" 2>/dev/null \
          | jq -r '.data.issue.title // empty' 2>/dev/null || true)"
        [[ -z "$linear_title" ]] && linear_title="$issue"
        if bash "$_VH_SCRIPT_DIR/linear.sh" get-issue "$issue" 2>/dev/null \
          | jq -r '.data.issue.labels.nodes[].name' 2>/dev/null \
          | grep -qiE 'feature|improvement'; then
          type=feat
        else
          type=fix
        fi
        title="$(printf '%s(%s): %s' "$type" "$issue" "$linear_title")"
        body="$(render_pr_body "$issue" "$branch" 2>/dev/null || printf '%s\n' "Linear: $issue")"
        if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
          log "verdict-handler: [DRY_RUN] would gh pr create --head $branch --title '$title'"
        else
          gh pr create --head "$branch" --title "$title" --body "$body" >/dev/null 2>&1 \
            || log "verdict-handler: gh pr create failed for $issue (next tick will retry idempotently)"
        fi
      else
        log "verdict-handler: PR already open for $issue on $branch — skipping create"
      fi
    fi
  fi
```

- [ ] **Step 5.4: Run, verify the cases PASS**

```
bash bin/verdict-handler-test.sh 2>&1 | grep -E 'Gap-1|RESULTS:' | tail -8
```

Expected: all three Gap-1 cases pass; final `RESULTS:` shows 0 failed.

- [ ] **Step 5.5: Edit `AGENT_PROMPTS.md §3` line 511**

In `AGENT_PROMPTS.md §3 Implementation Agent`, replace line 511:

```
- Do NOT create a PR. The UI agent opens the combined backend+frontend PR (or, on backend-only stacks, the review agent does — per the profile).
```

with:

```
- Do NOT create a PR. The orchestrator opens the PR on transition to `reviewing` as a side-effect of `apply_transition`.
```

- [ ] **Step 5.6: Edit `AGENT_PROMPTS.md §4` PR-creation block**

In `AGENT_PROMPTS.md §4 UI Agent`, locate the `PR creation (at exit — UI stage owns PR creation for this branch):` section (around line 683) and the entire block through line 720 (`<any deviations from plan, dep additions, gotcha trailers>`). Replace this entire ~37-line block with:

```
PR creation: Do NOT create or edit the PR. The orchestrator opens it on transition to `reviewing` (verdict-handler::apply_transition).
```

Also remove the now-obsolete "Open the PR per the template above" line in the `Output:` section (around line 723) — replace with `- Commit any remaining work on `{branch_name}` and push. Do NOT call gh pr create.`.

- [ ] **Step 5.7: Drop `gh pr create/view/edit` from UI allowlist**

In `bin/dispatch.sh::allowed_tools_for`, change the `ui)` case at line 154:

From:

```
    ui)             printf 'Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(gh pr create:*),Bash(gh pr view:*),Bash(gh pr edit:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*)' ;;
```

To:

```
    ui)             printf 'Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*)' ;;
```

- [ ] **Step 5.8: Un-stub the §4 PR-creation assertions in `agent-prompts-content-test.sh`**

In `bin/agent-prompts-content-test.sh`, replace the two stubbed lines from Task 3:

```bash
ok "§4 PR-creation removal — asserted in Task 5"
ok "§4 'PR creation' heading removal — asserted in Task 5"
```

with the real assertions:

```bash
if printf '%s\n' "$s4" | grep -qE 'gh pr create'; then
  nope "§4 lacks 'gh pr create'" "string 'gh pr create' present"
else
  ok "§4 lacks 'gh pr create'"
fi
if printf '%s\n' "$s4" | grep -qE '^[[:space:]]*PR creation'; then
  nope "§4 lacks 'PR creation' heading" "heading present"
else
  ok "§4 lacks 'PR creation' heading"
fi
```

- [ ] **Step 5.9: Run agent-prompts-content-test, verify PASS**

```
bash bin/agent-prompts-content-test.sh
```

Expected: `RESULTS: 7 passed, 0 failed`.

- [ ] **Step 5.10: Add dispatch-test assertion that UI no longer has gh pr create**

In `bin/dispatch-test.sh`, add a new case asserting the UI allowlist no longer contains `gh pr create`. Find the Group 1 / allowlist test cases and append:

```bash
# ENG-49 Gap #1: UI allowlist no longer contains gh pr create.
ui_tools="$(allowed_tools_for ui)"
if [[ "$ui_tools" != *"gh pr create"* ]]; then
  pass_at "ENG-49: ui allowlist drops gh pr create"
else
  fail_at "ENG-49: ui allowlist drops gh pr create" "ui tools: $ui_tools"
fi
```

(`pass_at` / `fail_at` are the existing helpers in `dispatch-test.sh:74-75`.)

- [ ] **Step 5.11: Run dispatch-test, verify PASS**

```
bash bin/dispatch-test.sh 2>&1 | tail -10
```

Expected: includes the new pass line; `RESULTS:` shows 0 failed.

- [ ] **Step 5.12: Run full regression suite**

```
for t in bin/*-test.sh; do bash "$t" >/dev/null 2>&1 && printf 'PASS %s\n' "$t" || printf 'FAIL %s\n' "$t"; done
```

Expected: every line starts with `PASS`.

- [ ] **Step 5.13: Commit**

```
git add bin/verdict-handler.sh bin/verdict-handler-test.sh AGENT_PROMPTS.md bin/dispatch.sh bin/dispatch-test.sh bin/agent-prompts-content-test.sh
git commit -m "$(cat <<'EOF'
feat(ENG-49): orchestrator opens PR on transition to reviewing

apply_transition gains an idempotent gh pr create hook on `to ==
reviewing`. Body comes from render_pr_body (assembled from brainstorm
Overview, plan Failure Mode → Test Map, and Linear stage-summary
comments). Title format <type>(ENG-N): <linear-title> with type
derived from Linear labels. Branch read from Linear issue's
gitBranchName.

UI agent §4 prompt loses the entire 'PR creation' block; §3
implement prompt updated to point at the orchestrator. UI allowlist
drops gh pr create/view/edit. agent-prompts-content-test.sh now
asserts the §4 changes.

Gap #8 (bot self-review) is acknowledged in a comment near the new
hook; a separate ticket fixes it via a second bot identity.

Closes Gap #1 of ENG-49.
EOF
)"
```

---

## Task 6 — Gap #7: align stage allowlists with prompt instructions

**depends_on:** [5]

**Files:**
- Modify: `bin/dispatch.sh::allowed_tools_for qa` (add `gh pr list`)
- Modify: `bin/dispatch-test.sh` (prompt↔allowlist contract)

- [ ] **Step 6.1: Write the failing contract test in `dispatch-test.sh`**

Append a new contract block to `bin/dispatch-test.sh` (find Group 1 — the existing allowlist tests — and append after them):

```bash
# ─── ENG-49 Gap #7: prompt↔allowlist contract ─────────────────────────
# For each stage, every `gh pr <verb>` token appearing in
# AGENT_PROMPTS.md §S must be allowlisted in allowed_tools_for(S).
# Token regex matches shell-shaped instances: line-start whitespace
# (or backtick) + `gh pr ` + one verb word.
contract_check_stage() {
  local stage="$1" section="$2"
  local section_body verbs missing=""
  section_body="$(awk -v h="$section" '
    /^## /{ if (in_section) exit; if (index($0, h)) {in_section=1; next} }
    in_section{print}
  ' "$HARNESS_ROOT/AGENT_PROMPTS.md")"
  verbs="$(printf '%s\n' "$section_body" \
    | grep -oE '(`|^[[:space:]]+)gh pr [a-z]+' \
    | grep -oE 'gh pr [a-z]+' \
    | sort -u)"
  local tools; tools="$(allowed_tools_for "$stage")"
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    [[ "$tools" == *"$v"* ]] || missing+="$v "
  done <<<"$verbs"
  if [[ -z "$missing" ]]; then
    pass_at "Gap-7 contract: $stage allowlist covers all gh pr verbs in §$section"
  else
    fail_at "Gap-7 contract: $stage allowlist missing: $missing" "tools: $tools"
  fi
}
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

contract_check_stage implement     "## 3. Implementation Agent (Backend)"
contract_check_stage ui            "## 4. UI Agent (Frontend)"
contract_check_stage review        "## 5. Review Agent"
contract_check_stage qa            "## 6. QA Agent"
contract_check_stage build         "## 7. Build Agent"
```

- [ ] **Step 6.2: Run, verify failure for QA**

```
bash bin/dispatch-test.sh 2>&1 | grep -E 'Gap-7|RESULTS:' | tail -10
```

Expected: `FAIL: Gap-7 contract: qa allowlist missing: gh pr list` (because §6 QA Agent currently mentions `gh pr` operations the QA prompt instructs but the allowlist hasn't kept up).

If no QA prompt mentions `gh pr list`, the test passes — in which case skip Step 6.3 and document the no-op result. (Verify by `grep -nE 'gh pr [a-z]+' AGENT_PROMPTS.md` and inspecting the QA section.)

- [ ] **Step 6.3: Add `gh pr list` to QA allowlist**

In `bin/dispatch.sh::allowed_tools_for`, change the `qa)` case at line 156:

From:

```
    qa)             printf 'Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh issue create:*),Bash(gh issue list:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*)' ;;
```

To:

```
    qa)             printf 'Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh issue create:*),Bash(gh issue list:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*)' ;;
```

- [ ] **Step 6.4: Run, verify PASS**

```
bash bin/dispatch-test.sh 2>&1 | grep -E 'Gap-7|RESULTS:' | tail -10
```

Expected: all Gap-7 contract cases pass.

- [ ] **Step 6.5: Run full regression suite**

```
for t in bin/*-test.sh; do bash "$t" >/dev/null 2>&1 && printf 'PASS %s\n' "$t" || printf 'FAIL %s\n' "$t"; done
```

Expected: all PASS.

- [ ] **Step 6.6: Commit**

```
git add bin/dispatch.sh bin/dispatch-test.sh
git commit -m "$(cat <<'EOF'
fix(ENG-49): align stage allowlists with prompt instructions

dispatch-test.sh gains a contract assertion: for each stage, every
`gh pr <verb>` token mentioned in AGENT_PROMPTS.md must be
allowlisted in allowed_tools_for(S). Catches future drift between
prompt and sandbox.

QA allowlist gains `gh pr list` for parity with review/build (all
read PR state). UI allowlist already lost gh pr create/view/edit
in the previous commit (1b moots them).

Closes Gap #7 of ENG-49.
EOF
)"
```

---

## Task 7 — Gap #2: `halt.sh resolve` invokes verdict-handler before clearing halt

**depends_on:** []

**Files:**
- Modify: `bin/halt.sh::resolve`
- Create: `bin/halt-test.sh`

- [ ] **Step 7.1: Write the failing test in `halt-test.sh`**

Create `bin/halt-test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# ENG-49 Gap #2: halt.sh resolve --decision resume calls verdict-handler
# before clearing pipeline:halted.
set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

_TEST_TARGET="$(mktemp -d -t twinning-halt-target.XXXXXX)"
_TEST_STUB="$(mktemp -d -t twinning-halt-stub.XXXXXX)"
case "$_TEST_TARGET" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
case "$_TEST_STUB"   in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
trap 'rm -rf "$_TEST_TARGET" "$_TEST_STUB"' EXIT

mkdir -p "$_TEST_TARGET/.pipeline-config"
cat > "$_TEST_TARGET/.pipeline-config/config.json" <<'JSON'
{"project":{"slug":"test-slug"},"orchestrator":{"paused":false},"linear":{"native_states":{"in_review":"In Review","done":"Done"}}}
JSON
export TARGET_REPO="$_TEST_TARGET"

LINEAR_CALLS="$_TEST_STUB/linear-calls.log"
: > "$LINEAR_CALLS"
cat > "$_TEST_STUB/linear.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LINEAR_CALLS"
case "\$1" in
  add-comment|remove-label|add-label) exit 0 ;;
  stage-of) printf 'stage:ui' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/linear.sh"

# Stub verdict-handler — return-code controllable via VH_RC env var.
cat > "$_TEST_STUB/verdict-handler.sh" <<'SH'
verdict_handler() { return "${VH_RC:-0}"; }
export -f verdict_handler
SH

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# Source halt.sh post-config so it sees TARGET_REPO. Override SCRIPT_DIR
# AFTER sourcing so internal calls point at stubs.
# shellcheck source=halt.sh
source "$SCRIPT_DIR_REAL/halt.sh"
SCRIPT_DIR="$_TEST_STUB"

# Case A: --decision resume + verdict-handler returns 0 → halt.sh skips remove-label.
: > "$LINEAR_CALLS"
VH_RC=0 resolve "ENG-980" "resume" >/dev/null 2>&1 || true
remove_count="$(grep -c "^remove-label ENG-980 pipeline:halted$" "$LINEAR_CALLS" || true)"
[[ "$remove_count" == "0" ]] \
  && ok "Gap-2 rc=0: halt.sh skips its own remove-label" \
  || nope "Gap-2 rc=0 skip remove-label" "remove-label called $remove_count time(s)"

# Case B: --decision resume + verdict-handler returns 1 → halt.sh removes halt.
: > "$LINEAR_CALLS"
VH_RC=1 resolve "ENG-981" "resume" >/dev/null 2>&1 || true
remove_count="$(grep -c "^remove-label ENG-981 pipeline:halted$" "$LINEAR_CALLS" || true)"
[[ "$remove_count" == "1" ]] \
  && ok "Gap-2 rc=1: halt.sh removes halt label" \
  || nope "Gap-2 rc=1 remove halt label" "remove-label called $remove_count time(s)"

# Case C: --decision resume + verdict-handler returns 2 → halt.sh exits non-zero, halt preserved.
: > "$LINEAR_CALLS"
exit_code=0
( VH_RC=2 resolve "ENG-982" "resume" >/dev/null 2>&1 ) || exit_code=$?
remove_count="$(grep -c "^remove-label ENG-982 pipeline:halted$" "$LINEAR_CALLS" || true)"
if [[ "$exit_code" -ne 0 && "$remove_count" == "0" ]]; then
  ok "Gap-2 rc=2: halt.sh exits non-zero, halt preserved"
else
  nope "Gap-2 rc=2: halt.sh exits non-zero, halt preserved" \
    "exit=$exit_code remove-count=$remove_count"
fi

# Case D: --decision scope-approved → no verdict-handler involvement, current behavior.
: > "$LINEAR_CALLS"
VH_RC=99 resolve "ENG-983" "scope-approved" >/dev/null 2>&1 || true
remove_count="$(grep -c "^remove-label ENG-983 pipeline:halted$" "$LINEAR_CALLS" || true)"
[[ "$remove_count" == "1" ]] \
  && ok "Gap-2 scope-approved: current behavior preserved (rm halt)" \
  || nope "Gap-2 scope-approved" "remove-label called $remove_count time(s)"

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
```

- [ ] **Step 7.2: Run, verify FAILS**

```
chmod +x bin/halt-test.sh
bash bin/halt-test.sh 2>&1 | tail -10
```

Expected: at least Cases A and C fail (current `halt.sh::resolve` doesn't call verdict-handler).

- [ ] **Step 7.3: Modify `bin/halt.sh::resolve`**

Replace the entire `resolve()` function in `bin/halt.sh` (lines 16-29):

```bash
resolve() {
  local issue="$1" decision="$2"
  [[ -n "$issue" && -n "$decision" ]] \
    || die "usage: halt.sh resolve <ENG-XX> --decision <scope-approved|scope-rejected|resume>"
  case "$decision" in
    scope-approved|scope-rejected|resume) ;;
    *) die "unknown decision: $decision" ;;
  esac
  local body
  body="$(printf '<!-- pipeline-decision: %s -->\n\nHalt resolved by human via halt.sh (decision=%s).' "$decision" "$decision")"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
  bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
  log "halt resolved: $issue decision=$decision"
}
```

with the new flow:

```bash
resolve() {
  local issue="$1" decision="$2"
  [[ -n "$issue" && -n "$decision" ]] \
    || die "usage: halt.sh resolve <ENG-XX> --decision <scope-approved|scope-rejected|resume>"
  case "$decision" in
    scope-approved|scope-rejected|resume) ;;
    *) die "unknown decision: $decision" ;;
  esac

  local body
  body="$(printf '<!-- pipeline-decision: %s -->\n\nHalt resolved by human via halt.sh (decision=%s).' "$decision" "$decision")"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"

  if [[ "$decision" == "resume" ]]; then
    # ENG-49 Gap #2: invoke verdict-handler BEFORE clearing pipeline:halted
    # so any fresh forward verdict marker actually advances the stage.
    # shellcheck source=verdict-handler.sh
    source "$SCRIPT_DIR/verdict-handler.sh"
    local current_stage rc=0
    current_stage="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue")"
    current_stage="${current_stage#stage:}"
    verdict_handler "$issue" "$current_stage" || rc=$?
    case "$rc" in
      0)
        # apply_transition already removed pipeline:halted as part of the transition.
        log "halt resolved: $issue decision=resume (verdict-handler transitioned)"
        return 0
        ;;
      1)
        # No fresh forward verdict; halt-marker is preserved. Proceed with manual halt clear.
        bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
        log "halt resolved: $issue decision=resume (no fresh forward verdict; halt label cleared)"
        return 0
        ;;
      2)
        # Protocol violation — verdict-handler re-applied pipeline:halted.
        # Do NOT clear it; operator must address the violation.
        printf 'halt.sh: verdict-handler reported protocol violation on %s; halt label preserved.\n' "$issue" >&2
        printf 'halt.sh: see Linear comment with sig protocol-violation/<case_id>/%s for details.\n' "$issue" >&2
        return 2
        ;;
      *)
        die "verdict_handler returned unknown rc=$rc"
        ;;
    esac
  fi

  bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
  log "halt resolved: $issue decision=$decision"
}
```

- [ ] **Step 7.4: Run, verify PASS**

```
bash bin/halt-test.sh 2>&1 | tail -10
```

Expected: `RESULTS: 4 passed, 0 failed`.

- [ ] **Step 7.5: Run full regression suite**

```
for t in bin/*-test.sh; do bash "$t" >/dev/null 2>&1 && printf 'PASS %s\n' "$t" || printf 'FAIL %s\n' "$t"; done
```

Expected: all PASS.

- [ ] **Step 7.6: Commit**

```
git add bin/halt.sh bin/halt-test.sh
git commit -m "$(cat <<'EOF'
fix(ENG-49): halt.sh resolve invokes verdict-handler before clearing halt

When the operator runs halt.sh resolve --decision resume on an issue
that has a fresh forward verdict marker, verdict-handler must transition
the stage BEFORE pipeline:halted is removed — otherwise poll.sh
classifies the issue as 'held slot' and re-dispatches the same stage
on the next tick, wasting a dispatch.

Three rc paths:
- rc=0 (transitioned): apply_transition already removed pipeline:halted;
  halt.sh skips its own remove-label.
- rc=1 (halt-marker is the freshest verdict): halt.sh removes the halt
  label as before.
- rc=2 (protocol violation): halt.sh exits non-zero and the halt label
  is NOT removed; operator must address the violation per the Linear
  protocol-violation comment.

scope-approved and scope-rejected paths are unchanged.

Closes Gap #2 of ENG-49.
EOF
)"
```

---

## Task 8 — Gap #3: `bin/post-verdict.sh` operator helper

**depends_on:** []

**Files:**
- Create: `bin/post-verdict.sh`
- Create: `bin/post-verdict-test.sh`
- Modify: `CLAUDE.md` (point at the helper under "Common commands")

- [ ] **Step 8.1: Write the failing test first**

Create `bin/post-verdict-test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# ENG-49 Gap #3: post-verdict.sh constructs marker via heredoc and
# validates against verdict-handler regex before posting.
set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

_TEST_TARGET="$(mktemp -d -t twinning-pv-target.XXXXXX)"
_TEST_STUB="$(mktemp -d -t twinning-pv-stub.XXXXXX)"
case "$_TEST_TARGET" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
case "$_TEST_STUB"   in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
trap 'rm -rf "$_TEST_TARGET" "$_TEST_STUB"' EXIT

mkdir -p "$_TEST_TARGET/.pipeline-config"
cat > "$_TEST_TARGET/.pipeline-config/config.json" <<'JSON'
{"project":{"slug":"test-slug"},"orchestrator":{"paused":false}}
JSON
export TARGET_REPO="$_TEST_TARGET"

# Stub linear.sh: capture add-comment payloads.
LINEAR_CALLS="$_TEST_STUB/linear-calls.log"
: > "$LINEAR_CALLS"
cat > "$_TEST_STUB/linear.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  add-comment) printf '%s\n' "\$3" >> "$LINEAR_CALLS"; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/linear.sh"

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# source post-verdict.sh, override SCRIPT_DIR to point at stubs.
# shellcheck source=post-verdict.sh
source "$SCRIPT_DIR_REAL/post-verdict.sh"
SCRIPT_DIR="$_TEST_STUB"

# Case 1: valid stage-summary → marker matches regex, posted.
: > "$LINEAR_CALLS"
post_verdict ENG-990 stage-summary ui "test reason" >/dev/null 2>&1
posted="$(cat "$LINEAR_CALLS")"
[[ "$posted" == *'<!-- pipeline-stage-summary: ui -->'* ]] \
  && ok "case-1 valid stage-summary marker posted" \
  || nope "case-1 stage-summary" "posted: $posted"

# Case 2: invalid kind dies.
exit_code=0
(post_verdict ENG-991 bogus-kind ui >/dev/null 2>&1) || exit_code=$?
[[ "$exit_code" -ne 0 ]] \
  && ok "case-2 invalid kind dies" \
  || nope "case-2 invalid kind" "exit=$exit_code"

# Case 3: invalid stage dies.
exit_code=0
(post_verdict ENG-992 stage-summary not-a-stage >/dev/null 2>&1) || exit_code=$?
[[ "$exit_code" -ne 0 ]] \
  && ok "case-3 invalid stage dies" \
  || nope "case-3 invalid stage" "exit=$exit_code"

# Case 4: heredoc construction — the literal `<!--` survives as-is.
: > "$LINEAR_CALLS"
post_verdict ENG-993 stage-summary building "release ready" >/dev/null 2>&1
posted="$(cat "$LINEAR_CALLS")"
[[ "$posted" == *"<!--"* ]] \
  && ok "case-4 heredoc preserves literal <!--" \
  || nope "case-4 heredoc <!--" "posted: $posted"

# Case 5: rejection marker shape.
: > "$LINEAR_CALLS"
post_verdict ENG-994 rejection reviewing "rework needed" >/dev/null 2>&1
posted="$(cat "$LINEAR_CALLS")"
[[ "$posted" == *'<!-- pipeline-rejection: reviewing -->'* ]] \
  && ok "case-5 rejection marker shape" \
  || nope "case-5 rejection" "posted: $posted"

# Case 6: halt marker shape (uses kind 'halt').
: > "$LINEAR_CALLS"
post_verdict ENG-995 halt agent-blocked "manual halt" >/dev/null 2>&1
posted="$(cat "$LINEAR_CALLS")"
[[ "$posted" == *'<!-- pipeline-halt: agent-blocked -->'* ]] \
  && ok "case-6 halt marker shape" \
  || nope "case-6 halt" "posted: $posted"

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
```

- [ ] **Step 8.2: Run, verify FAILS**

```
chmod +x bin/post-verdict-test.sh
bash bin/post-verdict-test.sh 2>&1 | tail -10
```

Expected: `FATAL: not found ... post-verdict.sh` or similar (file doesn't exist yet).

- [ ] **Step 8.3: Implement `bin/post-verdict.sh`**

Create `bin/post-verdict.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# ENG-49 Gap #3: bin/post-verdict.sh — operator-facing helper for safely
# posting verdict markers to Linear. Constructs the marker body via
# heredoc (immune to bash history expansion of `<!--`) and validates the
# constructed body against verdict-handler.sh::find_fresh_verdict's
# grep regex before sending.
#
# Usage:
#   post-verdict.sh <issue> <kind> <stage> [<reason>]
#     kind  ∈ stage-summary | rejection | halt
#     stage ∈ brainstorming|planning|implementing|ui|reviewing|qa|building|released
#             OR (for kind=halt) any halt-reason word matching [a-z-]+
#
# Examples:
#   bin/post-verdict.sh ENG-45 stage-summary building "release shipped"
#   bin/post-verdict.sh ENG-46 rejection reviewing "rework needed"
#   bin/post-verdict.sh ENG-47 halt agent-blocked "operator stop"

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ENG-41 T3: human lane — operator CLI; Linear writes are unrestricted.
export PIPELINE_WRITER=human

_PV_KNOWN_STAGES='brainstorming planning implementing ui reviewing qa building released'

post_verdict() {
  local issue="$1" kind="$2" stage="$3" reason="${4:-Manual marker post by operator.}"
  [[ -n "$issue" && -n "$kind" && -n "$stage" ]] \
    || die "usage: post-verdict.sh <issue> <kind> <stage> [<reason>]"
  case "$kind" in
    stage-summary|rejection|halt) ;;
    *) die "unknown kind: $kind (expected stage-summary|rejection|halt)" ;;
  esac
  if [[ "$kind" != "halt" ]]; then
    grep -qw -- "$stage" <<<"$_PV_KNOWN_STAGES" \
      || die "unknown stage: $stage (expected one of: $_PV_KNOWN_STAGES)"
  else
    [[ "$stage" =~ ^[a-z][a-z-]*$ ]] \
      || die "halt reason must match [a-z-]+, got: $stage"
  fi

  local marker
  case "$kind" in
    stage-summary) marker="<!-- pipeline-stage-summary: ${stage} -->" ;;
    rejection)     marker="<!-- pipeline-rejection: ${stage} -->" ;;
    halt)          marker="<!-- pipeline-halt: ${stage} -->" ;;
  esac

  local body
  body="$(cat <<EOF
${marker}

${reason}
EOF
)"

  # Validate against verdict-handler's regexes (one per kind).
  local re
  case "$kind" in
    stage-summary) re='<!-- pipeline-stage-summary: [a-z]+ -->' ;;
    rejection)     re='<!-- pipeline-rejection: [a-z]+ -->' ;;
    halt)          re='<!-- pipeline-halt: [a-z-]+ -->' ;;
  esac
  grep -qE -- "$re" <<<"$body" \
    || die "constructed body did not match verdict-handler regex: $re"

  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
  log "post-verdict: posted $kind:$stage on $issue"
}

export -f post_verdict

# Sentinel — runnable as a CLI.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  post_verdict "$@"
fi
```

- [ ] **Step 8.4: Run, verify PASS**

```
chmod +x bin/post-verdict.sh
bash bin/post-verdict-test.sh 2>&1 | tail -10
```

Expected: `RESULTS: 6 passed, 0 failed`.

- [ ] **Step 8.5: Update `CLAUDE.md`**

In `CLAUDE.md`, find the "Common commands" section. After the existing `bash bin/halt.sh resolve …` line, add:

```bash
# Post a verdict marker manually (heredoc-constructed; safe from bash !-expansion):
bash bin/post-verdict.sh ENG-N stage-summary <stage> [<reason>]
bash bin/post-verdict.sh ENG-N rejection <target-stage> [<reason>]
bash bin/post-verdict.sh ENG-N halt <reason-token> [<reason>]
```

- [ ] **Step 8.6: Run full regression suite**

```
for t in bin/*-test.sh; do bash "$t" >/dev/null 2>&1 && printf 'PASS %s\n' "$t" || printf 'FAIL %s\n' "$t"; done
```

Expected: all PASS.

- [ ] **Step 8.7: Commit**

```
git add bin/post-verdict.sh bin/post-verdict-test.sh CLAUDE.md
git commit -m "$(cat <<'EOF'
feat(ENG-49): bin/post-verdict.sh helper for safe marker posting

Operator-facing CLI that constructs verdict markers (stage-summary,
rejection, halt) via heredoc — immune to bash history expansion of
`<!--`. Validates the constructed body matches verdict-handler's
regex before posting. Validates kind and stage args; rejects unknown
values with die.

CLAUDE.md updated with usage under Common commands.

Closes Gap #3 of ENG-49.
EOF
)"
```

---

## Pre-PR final verification

- [ ] **Step F.1: Full-suite test from clean state**

```
for t in bin/*-test.sh; do bash "$t" >/dev/null 2>&1 && printf 'PASS %s\n' "$t" || { printf 'FAIL %s\n' "$t"; bash "$t" 2>&1 | tail -20; }; done
```

Expected: every line starts with `PASS`. No FAIL.

- [ ] **Step F.2: Smoke render-prompt.sh on each stage to verify §3, §4, §8 prompt edits didn't break the fence-count contract**

```
for stage in brainstorm plan implement ui review qa build release retrospective; do
  bash bin/render-prompt.sh "$stage" /dev/null >/dev/null 2>&1 \
    && printf 'PASS render-prompt %s\n' "$stage" \
    || printf 'FAIL render-prompt %s\n' "$stage"
done
```

Expected: every line starts with `PASS`.

- [ ] **Step F.3: Open the PR**

```
git push -u origin eng-49-harness-productionization
gh pr create --title "fix(ENG-49): generalize harness for any target stack (8 gaps)" --body "$(cat <<'EOF'
## Summary

Productionizes the harness for any target stack (backend-only,
frontend-only, full-stack, harness-self) by removing target-shape
assumptions baked in for the original Tauri target. 8 commits, one per
gap; design doc at
`docs/brainstorms/2026-04-30-eng-49-harness-productionization-design.md`.

## Linear

- ENG-49 — harness-self productionization: 5 gaps surfaced shipping ENG-45

## Changes

- Backend: 8 commits — paused-override fix; defensive native-state
  guard; released → Done hook; render-pr-body helper; orchestrator
  opens PR on transition to reviewing; allowlist alignment;
  halt.sh + verdict-handler integration; post-verdict.sh helper.
- Frontend: N/A — backend-only stack.

## Test plan

- [x] Every gate from the harness profile's "Build & test gates"
  section (every `bin/*-test.sh` passes).
- [x] `render-prompt.sh` smoke for all 9 stages (fence-count contract
  intact).
- [x] Manual: `state.local.json::orchestrator.paused=false` override
  takes effect after a breaker trip.
- [ ] Manual (post-merge): take next harness-self ticket through
  Todo → Done; PR author = bot identity; no manual marker posts;
  Linear status auto-transitions to Done on stage:released.

## Screenshots

N/A — backend-only.

## Notes

- Gap #8 (bot self-review) is intentionally unfixed; followup ticket
  to be filed under project `harness`, blocked-on ENG-49.
- Sweep for other Tauri-target assumptions in the harness: also
  followup, blocked-on ENG-49.
- AC4's mechanism changed from `.github/workflows/pipeline-release.yml`
  to a `verdict-handler::apply_transition` hook (single source of truth
  for stage→state mapping; no per-target workflow file needed).
EOF
)"
```

- [ ] **Step F.4: File the two follow-up Linear tickets**

```
# Followup 1: Gap #8 — separate bot identities
bash bin/linear.sh save-issue --team Engineering --project Harness --title "Separate bot identities for PR-creator vs reviewer (ENG-49 Gap #8)" --description "..."

# Followup 2: Sweep for remaining Tauri-target assumptions
bash bin/linear.sh save-issue --team Engineering --project Harness --title "Audit harness for remaining Tauri-target assumptions (post-ENG-49 sweep)" --description "..."
```

(Use the actual command shape `bin/linear.sh` exposes; if there is no `save-issue` subcommand, file via Linear MCP `mcp__plugin_linear_linear__save_issue` per the harness convention. Both blocked-on ENG-49.)

---

## Failure Mode → Test Map

| ID | Failure mode | Test layer | Test |
|---|---|---|---|
| F-001 | `state.local.json::orchestrator.paused=false` is silently ignored when `config.json::paused=true` | unit | `bin/run-local-helpers-adversarial-test.sh::test_paused_override_honored`, `::test_paused_callsites_use_helper` |
| F-002 | `apply_transition` dies with FATAL when native_states.in_review is missing | unit | `bin/verdict-handler-test.sh` (Gap-5 case) |
| F-003 | Setup completes with native_states.done unpopulated | unit | `bin/setup-test.sh::test_setup_requires_native_states` |
| F-004 | `to == released` does not transition Linear status to Done | unit | `bin/verdict-handler-test.sh` (Gap-4 case) |
| F-005 | `render_pr_body` produces empty body when brainstorm Overview is missing | unit | `bin/render-pr-body-test.sh` case-2 |
| F-006 | `apply_transition` opens duplicate PR when one already exists | unit | `bin/verdict-handler-test.sh` Gap-1 case B |
| F-007 | `apply_transition` PR-create hook fires on non-reviewing transitions | unit | `bin/verdict-handler-test.sh` Gap-1 case C |
| F-008 | UI agent allowlist still grants `gh pr create` after PR-create moved to orchestrator | unit | `bin/dispatch-test.sh` Gap-1 allowlist case + Gap-7 contract |
| F-009 | QA stage prompt mentions a `gh pr` verb its allowlist denies | unit | `bin/dispatch-test.sh` Gap-7 contract |
| F-010 | `halt.sh resolve --decision resume` removes halt before verdict-handler can act | unit | `bin/halt-test.sh` cases A, B |
| F-011 | `halt.sh resolve --decision resume` clears halt despite verdict-handler protocol violation | unit | `bin/halt-test.sh` case C |
| F-012 | `halt.sh resolve --decision scope-approved` accidentally triggers verdict-handler | unit | `bin/halt-test.sh` case D |
| F-013 | `post-verdict.sh` posts a malformed marker that fails the verdict-handler regex | unit | `bin/post-verdict-test.sh` (regex assertion) |
| F-014 | `post-verdict.sh` accepts an unknown kind or stage | unit | `bin/post-verdict-test.sh` cases 2, 3 |
| F-015 | AGENT_PROMPTS.md §3 still instructs implement to open PR | static | `bin/agent-prompts-content-test.sh` §3 cases |
| F-016 | AGENT_PROMPTS.md §4 still contains a PR-creation block | static | `bin/agent-prompts-content-test.sh` §4 cases |
| F-017 | AGENT_PROMPTS.md §8 still attributes state-swap to `pipeline-release.yml` | static | `bin/agent-prompts-content-test.sh` §8 case |
| F-018 | render-prompt.sh fence-count contract broken by §3/§4/§8 edits | smoke | `bin/render-prompt.sh <stage>` for each of 9 stages (Step F.2) |

## api-contract

N/A — bash harness, no FE↔BE API surface in this PR.

## Risks (terse, per task)

| Task | Risk | Mitigation |
|---|---|---|
| 1 | Override change makes a stuck breaker harder to clear | reset-pipeline.sh and `set_orchestrator_paused false` both still work; reset hint updated |
| 2 | Setup gains a required key that breaks existing installs | Single-machine blast radius; loud error names the missing key |
| 3 | `to == released` introduces a new Linear write per build commit | Idempotent transition; `\|\| true` swallows API flakes |
| 4 | render_pr_body parsing is brittle to stage-summary drift | Graceful fallbacks ensure body is always producible; agent-prompts-content-test.sh asserts the contract |
| 5 | apply_transition gains GitHub-API dependency in the hot path | Idempotent re-entry via resume_in_progress_transition; gh pr list correctly skips re-creation |
| 6 | Allowlist contract regex hits false positives in code examples | Token regex scoped to shell-shape; dry-run parse before commit |
| 7 | halt.sh sourcing verdict-handler introduces import side-effects | verdict-handler is sentinel-guarded; only function definitions at top level |
| 8 | post-verdict.sh accepts edge-case stage names that bypass regex | Stage allowlist is hardcoded; halt-reason regex `[a-z-]+` matches verdict-handler's own |

## Acceptance criteria

Reproduced from spec §7. All eight ACs are validated by the tests in this plan plus AC8's live post-merge check.

| AC | Validated by |
|---|---|
| AC1 (orchestrator opens PR) | Task 5 verdict-handler-test cases + post-merge AC8 |
| AC2 (halt.sh + verdict-handler) | Task 7 halt-test.sh |
| AC3 (post-verdict.sh) | Task 8 post-verdict-test.sh |
| AC4 (released → Done) | Task 3 verdict-handler-test case + post-merge AC8 |
| AC5 (no FATAL state-not-in-cache) | Task 2 verdict-handler-test case + setup-test.sh |
| AC6 (paused override) | Task 1 run-local-helpers-adversarial-test cases |
| AC7 (allowlist contract) | Task 6 dispatch-test.sh contract block |
| AC8 (end-to-end) | Manual; capture timing for retrospective on first harness-self ticket post-merge |
