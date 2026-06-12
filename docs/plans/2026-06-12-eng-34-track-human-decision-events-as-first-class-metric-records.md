---
linear: ENG-34
date: 2026-06-12
topic: Emit a `human-decision` metric event on every `bin/pipeline.sh decide` invocation, capturing actor / action / before-state
---

# ENG-34 — Track human-decision events as first-class metric records

## 1. Goal

Emit one new `human-decision` event row to `$PROJECT_STATE_DIR/metrics/events.jsonl`
on every successful `bin/pipeline.sh decide … --action {continue|approve|abandon}`
invocation, capturing `actor` (from `git config user.email` with `$USER` fallback),
`action`, the resolved `current_stage`, an `outcome` token (`resumed | approved |
abandoned`), and a coarse `before_state` token (`halted | skip-until-human-acts |
skip-until-code-changes | none`) — without touching `metrics.sh`'s schema, the
pipeline-events.json registry, or the existing `halt-resume` emission.

## 2. Assumption Inventory

Every fact below is verified at the cited `path:line` in this worktree.
Branch-base freshness: `HEAD..origin/main` empty at plan time
(origin/main = `c6722bc`; HEAD = `87bd94b`). No Task 0 rebase needed.

### Codebase facts (verified against HEAD)

- `bin/pipeline.sh::cmd_decide` is the single chokepoint for `continue | approve |
  abandon`; defined at **L472–575**, dispatched from `main` at **L583**. Verified
  `bin/pipeline.sh:472-575,583`.
- `cmd_decide`'s `add-comment` success line — the load-bearing emission anchor — is
  the last statement of the function:
  ```bash
  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
  ```
  at `bin/pipeline.sh:574`. The new `human-decision` emission will be inserted
  AFTER this call, gated on the same `PIPELINE_DRY_RUN != 1` predicate used at
  `bin/pipeline.sh:569-572`.
- The `continue` branch already computes `current_stage` via
  `bash "$SCRIPT_DIR/linear.sh" stage-of "$issue"` at **L511–515**, sanitising via
  `current_stage="${current_stage#stage:}"` then `[[ "$current_stage" =~ ^[a-z]+$ ]] ||
  current_stage="unknown"`. This plan **hoists** that block above the
  `if [[ "$action" == "continue" ]]` arm so all three actions share the same
  resolution (D-004 in the brainstorm). Verified `bin/pipeline.sh:503,511-515`.
- The existing `_pipeline_emit_resume_metric` helper at **L463–469** calls
  `bash "$SCRIPT_DIR/metrics.sh" halt-resume "$issue" "$stage" "atomic-reset" 0
  "$stats" || true`. The new `_pipeline_emit_human_decision` will mirror this
  shape verbatim (same `|| true` swallow-failure pattern). Verified
  `bin/pipeline.sh:462-469`.
- `bin/metrics.sh::main` accepts ANY non-empty string for `event`; the only
  validation is `[[ -n "$event" && -n "$outcome" ]] || die …` at
  `bin/metrics.sh:41`. Notes is collected via `notes_parts+=("$1")` for unknown
  positional args (`bin/metrics.sh:35`) and serialised as a single string via
  `--arg notes`, then jq-escaped (`bin/metrics.sh:60,67`) — log-injection safe by
  inheritance. Verified `bin/metrics.sh:19-75`.
- `bin/linear.sh has-label "$issue" "$label"` is usable as an `if`-predicate
  (returns 0 on present, non-zero on absent / network failure). Already exercised
  by `cmd_decide`'s halt-label check at `bin/pipeline.sh:523`. Verified.
- `bin/linear.sh stage-of "$issue"` returns the literal `stage:*` label; on
  failure the existing `|| printf 'unknown'` fallback at `bin/pipeline.sh:512`
  pins the contract. Verified.
- The `PIPELINE_DRY_RUN` dry-run gate inside `cmd_decide` already suppresses the
  Linear `add-comment` call (`bin/pipeline.sh:569-572`); the new metric emission
  will sit BELOW that early `return 0` (i.e. only fires on the live path), so the
  dry-run-suppresses-everything invariant holds without a second explicit gate.
- `bin/pipeline.sh::_validate_registry decision_actions "$action"` at **L486** and
  `decision_gates` at **L494** already reject bogus tokens before the emission
  site is reached. The new code can therefore trust `action` ∈ `{continue,
  approve, abandon}` and `gate` ∈ `{scope, build-cap, ""}` without re-validation.
- `bin/pipeline-test.sh` has the in-process test harness for `cmd_decide` —
  `_ar_decide` at **L240–243**, `_ar_seed`/`_ar_clear` at **L246–255**, the
  `_AR_METRICS_CALLS` capture stub at **L209–214**, and the canonical
  precedent test PR-N (`halt-resume` metric capture) at **L320–334**. New
  PR-HD-* cases will mirror PR-N's shape.
- `bin/metrics-test.sh:211-228` (`Case ENG-120`) pins the
  free-form-event-name contract via the literal `impl_iteration` event;
  removing or tightening `metrics.sh:41` would already break that case, so
  the new `human-decision` token rides on an existing invariant rather than
  introducing a new one.
- `bin/halt.sh` does NOT exist in this worktree. The ticket's
  "Files likely to change: bin/halt.sh" is stale — resolve logic was merged
  into `bin/pipeline.sh::cmd_decide` per the brainstorm's §"Honest scope notes"
  (ENG-58 / ENG-60). Verified by `ls bin/halt*.sh` → only
  `halt-sprawl-test.sh` and `halt-sprawl-adversarial-test.sh`. The brainstorm
  D-006 (test surface lives in `bin/pipeline-test.sh`, not
  `halt-sprawl-test.sh`) follows from the same observation.
- `bin/pipeline-events.json` carries `decision_actions` at **L41–45** and
  `decision_gates` at **L46–49** but NO `metric_names` entry for
  `human-decision`; brainstorm D-008 keeps it that way (registry validates
  Linear comment markers, not metric event names — verified
  `bin/metrics.sh:41` accepts any string). No `bin/pipeline-events.json`
  edit in this plan.

### Test-gate closure sweep — removal side

This plan removes ZERO tokens, symbols, or substrings from production
code. The change is purely additive (new helpers, new call site, no
deletions). Therefore the removal-side closure sweep is vacuous; no
sibling test files need to appear in File Structure for the removal
reason.

### Test-gate closure sweep — add side

This plan adds NO new files under any gate-runnable glob
(`bin/*-test.sh`). The two test additions land inside the EXISTING
`bin/pipeline-test.sh` file. Therefore
`learned-rules/harness/project-profile.md` does NOT need to appear in
File Structure — verified by reading the profile's `## Build & test
gates` Test command line, which already runs `bash bin/pipeline-test.sh`
implicitly via the `.githooks/pre-commit` sweep (the full file list is
in CLAUDE.md, and `pipeline-test.sh` is one of the canonical
self-contained sibling tests).

### Branch-base freshness

`git log --oneline HEAD..origin/main` empty at plan time
(origin/main = `c6722bc7b147cca2a9611d560332211cd845d021`; HEAD =
`87bd94babf5caff017aff760c856a757a4312925`). No drift; all `path:line`
references above are pinned against this HEAD.

## System invariants

- `bin/metrics.sh` accepts an arbitrary non-empty string as the `event`
  positional arg; tightening this to an enum would break consumers that
  currently emit free-form event names. **verified_by:**
  `bin/metrics-test.sh:Case ENG-120`.
- `bin/pipeline.sh::_pipeline_emit_resume_metric` continues to emit the
  legacy `halt-resume` event on `continue` decisions (D-007 — the new
  `human-decision` event is purely additive). **verified_by:**
  `bin/pipeline-test.sh:PR-N`.
- `bin/pipeline.sh::cmd_decide` is the single CLI chokepoint for all
  three decision actions (`continue | approve | abandon`); the new
  emission lives behind this chokepoint, never threaded through the
  per-medium `_pipeline_drain_*` helpers. **verified_by:**
  `bin/pipeline-test.sh:PD1`.
- `PIPELINE_DRY_RUN=1` suppresses every Linear / filesystem / metric
  side-effect of `cmd_decide`; the new metric emission sits below the
  dry-run `return 0` early-exit gate. **verified_by:**
  `bin/pipeline-test.sh:PR-dry-run`.
- The `human-decision` emission must produce exactly ONE JSONL row per
  `decide` invocation that reaches `linear.sh add-comment` successfully
  (no row on dry-run, no row on registry rejection, no row on
  add-comment failure). **verified_by:** `task:T2`.
- Actor token is restricted to `[A-Za-z0-9._@+-]` and capped at 64
  bytes before reaching the JSONL writer (defence in depth above
  metrics.sh's `--arg notes` jq-escape). **verified_by:** `task:T2`.

## 3. File Structure

Modify (production):
- `bin/pipeline.sh` — three new private helpers near the existing
  `_pipeline_emit_resume_metric` (~L462–469): `_pipeline_resolve_actor`,
  `_pipeline_resolve_before_state`, `_pipeline_emit_human_decision`. Inside
  `cmd_decide` (~L472–575): hoist the `current_stage` resolution out of the
  `continue` arm so all three actions share it, and add ONE call to
  `_pipeline_emit_human_decision` AFTER the existing `add-comment` line
  (`bin/pipeline.sh:574`) on the non-dry-run path.

Modify (tests):
- `bin/pipeline-test.sh` — three new test cases (PR-HD-1 / PR-HD-2 /
  PR-HD-3) appended after the existing PR-dry-run block (~L627) and
  BEFORE the `printf '\n--- bin/pipeline.sh: ENG-112 schema validator
  ---\n'` header at L629. Each invokes `_ar_decide` for one of
  `{continue, approve, abandon}`, asserts a `human-decision` row appears
  in `_AR_METRICS_CALLS`, and asserts the notes payload carries the
  expected `actor=`, `action=`, `before_state=` tokens. One additional
  case PR-HD-DRY confirms dry-run suppresses the emission, and one
  PR-HD-SAN confirms the actor sanitiser strips shell metas.

Modify (docs):
- `CLAUDE.md` — a single-line addition under the existing
  "Failure-mode quick reference" section (or a sibling location near the
  "When wiring a new script" guidance — see Task 5 for exact anchor),
  documenting the `human-decision` event name + its scope limitation
  (harness-mediated explicit decisions only; Linear-UI direct edits are
  not captured).

No new files. No production changes outside `bin/pipeline.sh`. No
changes to `bin/metrics.sh`, `bin/pipeline-events.json`, or
`bin/halt-sprawl-test.sh` (the ticket's references to those files are
stale or mis-targeted; see Assumption Inventory and brainstorm D-006 /
D-008).

## 4. API Contract

No new API surface. The harness has no FE↔BE contract; the only "API"
affected is `bin/metrics.sh`'s positional CLI, and this plan adds a new
event-name value to that CLI's free-form `event` arg without changing
its argv shape or its JSONL row schema (the new row uses the existing
7-key flat object plus the standard optional flag-pairs, all unused
here). The new row's `notes` field carries
`actor=<sanitised> action=<continue|approve|abandon>[ gate=<scope|build-cap>]
before_state=<halted|skip-until-human-acts|skip-until-code-changes|none>`
as space-separated `key=value` tokens — the same convention
`halt-resume` already uses (verified `bin/pipeline.sh:466`).

## 5. Backend Tasks

### Task 1: Add three helpers + one call site to `bin/pipeline.sh::cmd_decide`

- `depends_on: []`
- `touches: bin/pipeline.sh::_pipeline_resolve_actor,
  bin/pipeline.sh::_pipeline_resolve_before_state,
  bin/pipeline.sh::_pipeline_emit_human_decision,
  bin/pipeline.sh::cmd_decide`

- [ ] **Step 1 — add the three helpers.** Content anchor: the existing
  helper `_pipeline_emit_resume_metric()` at `bin/pipeline.sh:463-469`,
  bounded above by the comment `# _pipeline_emit_resume_metric <issue>
  <stage> <wf> <sl> <sf> <waypoint_posted> [<breaker_was_paused>]
  [<auto_commit_count>]` and below by the function's closing `}` (the
  next non-blank line after the closing `}` is `# cmd_decide …` at
  L471). Insert the new helpers IMMEDIATELY AFTER the closing `}` of
  `_pipeline_emit_resume_metric` and IMMEDIATELY BEFORE the `# cmd_decide
  <issue> --action …` comment header at L471:

  ```bash
  # ENG-34: actor resolver for human-decision metric events.
  # `git config user.email` with $USER fallback; sanitised to a
  # conservative char-class and 64-byte cap before reaching the JSONL
  # writer. Defence in depth above metrics.sh's `--arg notes` jq-escape.
  # `git -C "$HARNESS_ROOT"` makes the resolver worktree-independent
  # (operators run `bin/pipeline.sh` from anywhere; HARNESS_ROOT resolves
  # via common.sh).
  _pipeline_resolve_actor() {
    local raw
    raw="$(git -C "$HARNESS_ROOT" config user.email 2>/dev/null || true)"
    [[ -z "$raw" ]] && raw="${USER-}"
    raw="$(printf '%s' "$raw" | tr -dc 'A-Za-z0-9._@+-' | head -c 64)"
    [[ -z "$raw" ]] && raw="unknown"
    printf '%s' "$raw"
  }

  # ENG-34: coarse before-state token for human-decision metric.
  # Returns the highest-priority halt-class label present on the issue,
  # or `none` when none of the three are set. Iterates a fixed priority
  # list so the result is deterministic when multiple labels are set
  # (rare but legal). Network failure of `linear.sh has-label` is
  # absorbed silently — best-effort audit, not load-bearing.
  _pipeline_resolve_before_state() {
    local issue="$1"
    local pair label token
    for pair in \
      "pipeline:halted halted" \
      "pipeline:skip-until-human-acts skip-until-human-acts" \
      "pipeline:skip-until-code-changes skip-until-code-changes"; do
      label="${pair% *}"
      token="${pair#* }"
      if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "$label" 2>/dev/null; then
        printf '%s' "$token"
        return 0
      fi
    done
    printf 'none'
  }

  # ENG-34: emit one human-decision event per cmd_decide invocation.
  # Mirrors _pipeline_emit_resume_metric's shape: `|| true` swallows
  # metric-write failures so the operator never sees a halted decide.
  # `action` is already registry-validated upstream (L486); switch arm
  # is exhaustive over the three valid values plus a safety fall-through.
  _pipeline_emit_human_decision() {
    local issue="$1" stage="$2" action="$3" gate="${4-}"
    local actor before_state outcome notes
    actor="$(_pipeline_resolve_actor)"
    before_state="$(_pipeline_resolve_before_state "$issue")"
    case "$action" in
      continue) outcome="resumed"   ;;
      approve)  outcome="approved"  ;;
      abandon)  outcome="abandoned" ;;
      *)        outcome="unknown"   ;;
    esac
    notes="actor=$actor action=$action"
    [[ -n "$gate" ]] && notes+=" gate=$gate"
    notes+=" before_state=$before_state"
    bash "$SCRIPT_DIR/metrics.sh" human-decision "$issue" "$stage" \
      "$outcome" 0 "$notes" || true
  }

  ```

  Rationale anchored at brainstorm decisions: D-001 (single emission
  site at `cmd_decide`), D-002 (no schema change — notes-tokens),
  D-003 (actor resolver with `git -C HARNESS_ROOT`), D-005 (4-token
  before_state enum), D-007 (`halt-resume` left untouched). Position is
  load-bearing — the helpers MUST be defined before `cmd_decide` is
  defined so bash's source-order parse sees them. Anchoring after
  `_pipeline_emit_resume_metric` keeps the helper cluster contiguous.

- [ ] **Step 2 — hoist `current_stage` resolution out of the `continue`
  arm.** Content anchor: the `if [[ "$action" == "continue" ]]; then`
  block opener at `bin/pipeline.sh:503`, bounded above by the comment
  `# ENG-58 atomic reset (ported from halt.sh::resolve, ENG-60 merge).`
  block ending at L502, and the comment-line beginning
  `# `continue` is the only action that may omit --gate; approve and
  abandon` at L488 (above the `case "$action" in` switch at L490).

  Locate the existing block currently at L504-515 inside the `if [[
  "$action" == "continue" ]]` arm:

  ```bash
      if [[ "${PIPELINE_DRY_RUN:-}" != "1" ]]; then
        # Issue-id validation: guard rm -f path-interpolation (D-014).
        # Only needed on the live path where we perform filesystem writes;
        # dry-run skips all FS ops so the guard is not required there.
        [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
          || die "decide: invalid issue id '$issue' (expected ENG-<digits>)"

        local current_stage
        current_stage="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue" 2>/dev/null || printf 'unknown')"
        current_stage="${current_stage#stage:}"
        # Sanitize: only lowercase alpha (D-014). Falls back to 'unknown'.
        [[ "$current_stage" =~ ^[a-z]+$ ]] || current_stage="unknown"
  ```

  Leave that block IN PLACE (the issue-id validation is `continue`-arm
  specific because it gates `rm -f` writes — D-014). Immediately below
  the closing `}`/`fi` of the entire `if [[ "$action" == "continue" ]];
  then ... fi` arm (content anchor: the line `fi` followed by a blank
  line followed by the comment `# ENG-112: schema-driven validation +
  body render.` at `bin/pipeline.sh:556-557`), add a SEPARATE
  resolution block that computes `current_stage` for the
  approve/abandon paths too. The two computations CAN coexist (the
  one inside the `continue` arm is local to that arm; the new one is a
  function-scoped fallback). Use the same regex sanitisation, but skip
  the issue-id `^ENG-[0-9]+$` guard (no FS writes outside the `continue`
  arm).

  Content anchor for insertion: AFTER the closing `fi` of the
  `if [[ "$action" == "continue" ]]` block at `bin/pipeline.sh:555`
  AND BEFORE the `# ENG-112: schema-driven validation + body render.`
  comment at L557. Insert:

  ```bash
    # ENG-34: resolve current_stage for ALL actions so the
    # human-decision emission below carries a stable stage token.
    # The continue arm above already computed `current_stage`
    # locally; this re-resolution is for the approve/abandon paths
    # and overwrites the previous local on continue (harmless — the
    # stage value is identical since neither arm has mutated labels
    # between the two calls). One extra `linear.sh stage-of` per
    # decide invocation; the call is cheap and the live-path
    # branching makes a hoist of the existing computation awkward.
    local current_stage_hd
    current_stage_hd="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue" 2>/dev/null || printf 'unknown')"
    current_stage_hd="${current_stage_hd#stage:}"
    [[ "$current_stage_hd" =~ ^[a-z]+$ ]] || current_stage_hd="unknown"
  ```

  Using `current_stage_hd` (a distinct local) avoids any aliasing
  hazard with the `continue`-arm `current_stage` variable; the
  emission helper at Step 3 reads `current_stage_hd` directly.

- [ ] **Step 3 — add the call site after the existing `add-comment`
  line.** Content anchor: the LAST line of `cmd_decide`, which is

  ```bash
    bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
  ```

  at `bin/pipeline.sh:574`. Immediately AFTER that line and IMMEDIATELY
  BEFORE the closing `}` of `cmd_decide` at L575, insert:

  ```bash

    # ENG-34: record a human-decision metric event for downstream
    # calibration. Best-effort — failure is swallowed inside the
    # helper (mirrors _pipeline_emit_resume_metric's `|| true`
    # contract). Sits past the add-comment success line so we only
    # record decisions that landed on Linear; the dry-run early-exit
    # above at L569-572 ensures this code is unreachable on dry-run.
    _pipeline_emit_human_decision "$issue" "$current_stage_hd" "$action" "$gate"
  ```

  Note: the `$gate` variable is already in `cmd_decide`'s scope
  (declared at L476 `local action="" gate=""`); empty on `continue`,
  non-empty on `approve | abandon` per the case-validation at L490-495.
  The helper's `[[ -n "$gate" ]] && notes+=" gate=$gate"` (Step 1) is
  what handles the conditional.

- [ ] **Step 4 — syntax check.**
  ```bash
  bash -n bin/pipeline.sh
  ```
  Expect exit 0.

### Task 2: Add five test cases to `bin/pipeline-test.sh`

- `depends_on: [1]`
- `touches: bin/pipeline-test.sh`

- [ ] **Step 1 — locate insertion anchor.** Content anchor: the line
  `_ar_clear "ENG-5807"` (closing the PR-dry-run block) at
  `bin/pipeline-test.sh:627`, followed by a blank line, followed by
  `printf '\n--- bin/pipeline.sh: ENG-112 schema validator ---\n'`
  at L629. Insert the five new cases IMMEDIATELY AFTER the
  `_ar_clear "ENG-5807"` line and IMMEDIATELY BEFORE the
  `printf '\n--- bin/pipeline.sh: ENG-112 schema validator ---\n'`
  header.

- [ ] **Step 2 — append the five PR-HD-* cases.** Each case follows the
  PR-N precedent at `bin/pipeline-test.sh:320-334` (reset captures,
  seed wait + issue-state via `_ar_seed`, run `_ar_decide` with
  `LABELS_ON=…` + `STAGE_OF=…` to control the stubbed `linear.sh`,
  grep `_AR_METRICS_CALLS` for the expected row shape):

  ```bash
  # ── PR-HD-1 (ENG-34): continue emits human-decision with before_state=halted
  : > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
  _ar_seed "ENG-5840" "skip-until-human-acts"
  LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
    STAGE_OF="stage:building" \
    _ar_decide "ENG-5840" --action continue || true
  hd_line="$(grep "^human-decision ENG-5840 building resumed 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
  if [[ -n "$hd_line" \
        && "$hd_line" == *"action=continue"* \
        && "$hd_line" == *"actor="* \
        && "$hd_line" == *"before_state=halted"* ]]; then
    pass_at "PR-HD-1: continue emits human-decision (outcome=resumed, before_state=halted)"
  else
    fail_at "PR-HD-1: human-decision continue" "line='$hd_line'"
  fi
  _ar_clear "ENG-5840"

  # ── PR-HD-2 (ENG-34): approve --gate scope emits with outcome=approved
  : > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
  _ar_seed "ENG-5841" "skip-until-human-acts"
  LABELS_ON="pipeline:skip-until-human-acts" \
    STAGE_OF="stage:implementing" \
    _ar_decide "ENG-5841" --action approve --gate scope || true
  hd_line="$(grep "^human-decision ENG-5841 implementing approved 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
  if [[ -n "$hd_line" \
        && "$hd_line" == *"action=approve"* \
        && "$hd_line" == *"gate=scope"* \
        && "$hd_line" == *"before_state=skip-until-human-acts"* ]]; then
    pass_at "PR-HD-2: approve --gate scope emits human-decision (outcome=approved, gate=scope)"
  else
    fail_at "PR-HD-2: human-decision approve" "line='$hd_line'"
  fi
  _ar_clear "ENG-5841"

  # ── PR-HD-3 (ENG-34): abandon --gate build-cap emits with outcome=abandoned
  : > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
  _ar_seed "ENG-5842" "skip-until-human-acts"
  # No halt-class labels set: before_state should resolve to `none`.
  LABELS_ON="" STAGE_OF="stage:building" \
    _ar_decide "ENG-5842" --action abandon --gate build-cap || true
  hd_line="$(grep "^human-decision ENG-5842 building abandoned 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
  if [[ -n "$hd_line" \
        && "$hd_line" == *"action=abandon"* \
        && "$hd_line" == *"gate=build-cap"* \
        && "$hd_line" == *"before_state=none"* ]]; then
    pass_at "PR-HD-3: abandon --gate build-cap emits human-decision (outcome=abandoned, gate=build-cap, before_state=none)"
  else
    fail_at "PR-HD-3: human-decision abandon" "line='$hd_line'"
  fi
  _ar_clear "ENG-5842"

  # ── PR-HD-DRY (ENG-34): dry-run suppresses human-decision emission
  : > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
  _ar_seed "ENG-5843" "skip-until-human-acts"
  PIPELINE_DRY_RUN=1 PIPELINE_WRITER=human \
    cmd_decide "ENG-5843" --action continue >/dev/null 2>&1 || true
  PIPELINE_DRY_RUN=""
  hd_count="$(grep -c "^human-decision ENG-5843 " "$_AR_METRICS_CALLS" || true)"
  if [[ "$hd_count" == "0" ]]; then
    pass_at "PR-HD-DRY: PIPELINE_DRY_RUN=1 suppresses human-decision emission"
  else
    fail_at "PR-HD-DRY: dry-run suppression" "expected 0 human-decision rows, got $hd_count"
  fi
  _ar_clear "ENG-5843"

  # ── PR-HD-SAN (ENG-34): actor resolver strips shell metas and length-caps.
  # Override the git config + USER env to inject a payload with shell metas
  # and a length > 64 chars, then assert the emitted actor token contains
  # ONLY chars in [A-Za-z0-9._@+-] and is <= 64 bytes.
  : > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
  _ar_seed "ENG-5844" "skip-until-human-acts"
  # Cannot easily override `git config user.email` from the harness,
  # so we instead set USER to a malicious payload and unset git's
  # user.email by pointing HARNESS_ROOT at a fresh empty repo.
  _HD_SAN_REPO="$(mktemp -d -t hd-san.XXXXXX)"
  ( cd "$_HD_SAN_REPO" && git init --quiet -b main ) >/dev/null 2>&1
  _OLD_HARNESS_ROOT="$HARNESS_ROOT"
  HARNESS_ROOT="$_HD_SAN_REPO"
  # 80-char payload mixing valid chars with shell metas + newlines.
  USER='evil$(rm -rf /);name@example.com;echo PWNED;aaaaaaaaaaaaaaaaaaaa' \
  LABELS_ON="pipeline:halted" STAGE_OF="stage:building" \
    _ar_decide "ENG-5844" --action continue || true
  HARNESS_ROOT="$_OLD_HARNESS_ROOT"
  rm -rf "$_HD_SAN_REPO"
  hd_line="$(grep "^human-decision ENG-5844 building resumed 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
  # Extract just the actor= token value (up to the next space).
  actor_val="${hd_line#*actor=}"
  actor_val="${actor_val%% *}"
  san_ok=1
  # Reject if any char outside the allow-set survived.
  [[ "$actor_val" =~ ^[A-Za-z0-9._@+-]+$ ]] || san_ok=0
  # Reject if longer than 64 bytes.
  (( ${#actor_val} <= 64 )) || san_ok=0
  if [[ "$san_ok" == "1" && -n "$actor_val" ]]; then
    pass_at "PR-HD-SAN: actor sanitiser strips shell metas + caps length (got '$actor_val', ${#actor_val} bytes)"
  else
    fail_at "PR-HD-SAN: actor sanitiser" "actor_val='$actor_val' len=${#actor_val} line='$hd_line'"
  fi
  _ar_clear "ENG-5844"

  ```

- [ ] **Step 3 — verify only the new cases run cleanly.**
  ```bash
  bash bin/pipeline-test.sh 2>&1 | grep -E 'PR-HD|FAIL'
  ```
  Expect: five `✅ PR-HD-*` lines, zero `❌` lines, zero `FAIL` lines.

### Task 3: Document the new event in `CLAUDE.md`

- `depends_on: [1]`
- `touches: CLAUDE.md`

- [ ] **Step 1 — locate insertion anchor.** Content anchor: the
  paragraph that begins `- Metric writes go through \`bin/metrics.sh\`
  (lands in \`events.jsonl\`).` inside the `## When wiring a new
  script` section of `CLAUDE.md`. Locate that bullet (search for the
  literal string `Metric writes go through`).

- [ ] **Step 2 — append a sibling bullet immediately AFTER the
  `Metric writes go through bin/metrics.sh (lands in events.jsonl).`
  bullet** (content anchor) and BEFORE the next bullet (`- Per-stage
  allowed tool lists are centralized in`). Insert:

  ```
  - `bin/pipeline.sh decide` emits a `human-decision` metric event
    (post-`add-comment` success) capturing
    `actor=<git-user-email-or-USER> action=<continue|approve|abandon>
    [gate=<scope|build-cap>] before_state=<halted|skip-until-human-acts
    |skip-until-code-changes|none>` in the JSONL `notes` field, with
    `outcome ∈ {resumed, approved, abandoned}`. This is the audit trail
    for harness-mediated explicit human decisions; **direct Linear-UI
    label or state edits by humans are NOT captured** (known v1
    limitation; calibration shape accepts the imperfect signal).
  ```

  No multi-row table edit, no header changes, no other bullets touched.

### Task 4: Full gate + commit

- `depends_on: [1, 2, 3]`
- `touches: (verification + commit only)`

- [ ] **Step 1 — run the pre-commit sweep:**
  ```bash
  bash .githooks/pre-commit
  ```
  Expect: every test file passes. Pay particular attention to
  `bin/pipeline-test.sh` (the only file with new assertions). The new
  PR-HD-* cases share fixtures with the existing PR-N/PR-X family; if
  the `_ar_seed`/`_ar_clear` helpers regress, the new cases will surface
  it.

- [ ] **Step 2 — confirm tree shape:**
  ```bash
  git status --short
  ```
  Expect only `bin/pipeline.sh`, `bin/pipeline-test.sh`, `CLAUDE.md`
  modified.

- [ ] **Step 3 — commit:**
  ```bash
  git add bin/pipeline.sh bin/pipeline-test.sh CLAUDE.md
  git commit -m "feat(ENG-34): emit human-decision metric event from cmd_decide

  Adds a new free-form event 'human-decision' to events.jsonl on every
  successful bin/pipeline.sh decide invocation, capturing actor (from
  git config user.email with \$USER fallback), action, current_stage,
  outcome (resumed/approved/abandoned), and a coarse before_state token
  (halted | skip-until-human-acts | skip-until-code-changes | none).

  No schema changes: metrics.sh already accepts free-form event names
  (pinned by metrics-test.sh Case ENG-120). Notes-tokens follow the
  halt-resume precedent. halt-resume is left untouched (continues to
  fire on continue) — human-decision is purely additive.

  Known limitation: Linear-UI direct label/state edits by humans are NOT
  captured (v1 covers harness-mediated decisions only).

  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
  ```

## 6. Frontend Tasks

No frontend surface. The harness has no UI; this plan changes only bash
orchestration scripts and one Markdown documentation file.

## 7. Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Operator runs `decide … --action continue` on a `pipeline:halted` issue | `cmd_decide` reaches add-comment success | `human-decision` row with `outcome=resumed`, `action=continue`, `before_state=halted`, no `gate=` token | integration | `PR-HD-1` |
| Operator runs `decide … --action approve --gate scope` on a skip-until-human-acts issue | `cmd_decide` reaches add-comment success | `human-decision` row with `outcome=approved`, `action=approve`, `gate=scope`, `before_state=skip-until-human-acts` | integration | `PR-HD-2` |
| Operator runs `decide … --action abandon --gate build-cap` on an issue with no halt-class label | `cmd_decide` reaches add-comment success | `human-decision` row with `outcome=abandoned`, `action=abandon`, `gate=build-cap`, `before_state=none` | integration | `PR-HD-3` |
| `PIPELINE_DRY_RUN=1` short-circuits `cmd_decide` | dry-run early-exit at `bin/pipeline.sh:569-572` | ZERO `human-decision` rows in `events.jsonl` | integration | `PR-HD-DRY` |
| Actor token contains shell metas / overlong payload | `_pipeline_resolve_actor` strips `tr -dc 'A-Za-z0-9._@+-'` + `head -c 64` | `notes::actor=` value matches `^[A-Za-z0-9._@+-]+$` and ≤ 64 bytes | integration | `PR-HD-SAN` |
| `linear.sh has-label` returns non-zero (network outage) | `_pipeline_resolve_before_state` falls through every priority entry | `before_state=none` (no error surfaced) | integration | `PR-HD-3` — predicate-equivalent: the resolver branches solely on `has-label`'s return code (see Task 1 Step 1 — `if bash "$SCRIPT_DIR/linear.sh" has-label …; then`). PR-HD-3 sets `LABELS_ON=""` which makes the test stub at `bin/pipeline-test.sh:200-202` return 1 for every label check — the EXACT return-code path that a real network outage would take through the resolver. There is no internal branch in the resolver that distinguishes "label absent" from "network failure," so a dedicated network-failure case would assert nothing additional. |
| `linear.sh stage-of` fails | hoisted `current_stage_hd` fallback at Task 1 Step 2 sets `unknown` | row's `stage` column is `unknown`; covered structurally by `PR-HD-*` where stub returns `STAGE_OF="stage:building"` (the unknown path is symmetric and the existing PR-N case already pins the same fallback) | integration | precedent in `PR-N`; no new case |
| `metrics.sh` exits non-zero (disk full, jq missing) | `_pipeline_emit_human_decision`'s trailing `\|\| true` swallows | decide CLI exits 0; covered structurally by the `\|\| true` contract being identical to the existing `halt-resume` emission, pinned by PR-N | integration | precedent in `PR-N`; no new case |
| Operator passes invalid `--action banana` | `_validate_registry decision_actions` at `bin/pipeline.sh:486` rejects upstream | `cmd_decide` dies before emission site; no row written; covered by existing PD6 (bogus gate) which exercises the symmetric registry-rejection path | integration | precedent in `PD6`; no new case |

## 8. Test Strategy

**Unit-level coverage** is absent for this change — the new helpers are
naturally integration boundaries (they shell to `git`, `linear.sh`, and
`metrics.sh` stubs). The closest unit-pattern would be standalone
coverage of `_pipeline_resolve_actor`'s sanitiser; this plan covers it
via the PR-HD-SAN integration case (Task 2 Step 2) rather than
introducing a separate unit harness — the sanitiser is one `tr` + one
`head` and adding a unit file just for it would over-build.

**Integration coverage** is the canonical layer:

- happy path × 3 actions (PR-HD-1 / PR-HD-2 / PR-HD-3): every action
  produces a registry-stable `outcome` token, the expected `notes`
  payload, and (for approve/abandon) the `gate=` token.
- dry-run suppression (PR-HD-DRY): pins the load-bearing invariant
  that `PIPELINE_DRY_RUN=1` produces ZERO metric rows.
- actor sanitisation (PR-HD-SAN): pins the defence-in-depth char-class
  filter + 64-byte cap; verifies that shell metas in `$USER` cannot
  survive into `events.jsonl`.

**Smoke / e2e coverage:** the `bin/*-test.sh` sweep via the
`.githooks/pre-commit` gate (run as Task 4 Step 1) acts as the smoke
layer. No new e2e fixtures are needed — the orchestrator's
verdict-handler / apply_transition path is not exercised by this change
(the new emission is purely on the operator CLI side).

**Adversarial coverage:** PR-HD-SAN doubles as adversarial coverage for
the actor sanitiser. The `before_state` priority resolver is
deterministically iterated (no race surface); the metric emission's
`|| true` failure-swallow is the same shape as `halt-resume`'s and is
not re-exercised here.

**Test-gate closure (re-stated):** no new file is added under any
gate-runnable glob; the only test changes land in the existing
`bin/pipeline-test.sh`. No token is removed from production code, so
the removal-side sweep is vacuous. No update to
`learned-rules/harness/project-profile.md` is required.
