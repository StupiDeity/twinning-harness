---
linear: ENG-156
date: 2026-06-10
topic: Surface sandbox denials as a first-class signal — Phase A log-only detective + Phase B contract-halt (config-flag-gated)
---

# ENG-156 — Plan

## Anti-anchoring check

- **Problem restatement.** Tool-denial events of shape `may only list files in
  the allowed working directories` and `This command requires approval` land
  in `.envelope-transcript-<stage>.ndjson` as `tool_result.is_error:true`
  rows, get deleted on the next clean dispatch, and never reach
  `events.jsonl` / `bin/status.sh` / the retrospective. Five recent
  dispatches (ENG-130/115/124/125) silently accumulated denials until
  ENG-125 hard-halted.
- **Brainstorm alignment.** The brainstorm proposes one detective sibling
  to ENG-87's `_validate_dispatch_envelope` (Phase A log-only) plus a
  config-flag-gated halt arm (Phase B). Both phases share one function in
  `bin/run-stage.sh`; Phase B reuses rc=29 with a distinct halt-reason
  token. Direct match to the problem; no reframing.
- **Solution proportionality.** ~80 lines of bash across `bin/run-stage.sh`
  (one new function + 2 call-site lines + 1 `_clear_current_stage_slots`
  line), ~15 lines in `bin/render-prompt.sh` (resolved-paths sidecar
  writer), ~30 lines in `bin/status.sh` (new section function + main
  wiring), 1 line in `bin/pipeline-events.json`, ~3 test fixture groups.
  No new exit code, no schema migration, no new file under `bin/`.
  Proportional to the single-detective brainstorm decision.

## Goal

Add a post-dispatch detective in `bin/run-stage.sh` that scans
`.envelope-transcript-<stage>.ndjson` for `tool_result.is_error:true`
events matching a 2-entry sandbox-denial signature table, emits one
`events.jsonl::event=sandbox_denial` row per dispatch carrying
`count + signatures + paths + claude_version`, surfaces a "Sandbox
denials (last 7d)" section in `bin/status.sh`, registers
`sandbox-contract-violation` in `bin/pipeline-events.json::halt_reasons`,
and ships a config-flag-gated Phase B arm that promotes the detective to
rc=29 halt when a denied path matches a path resolved by
`PROMPT_RESOLVERS` (the harness contract told the agent to write there).

## Assumption Inventory

**Branch-base freshness.** `git log --oneline HEAD..origin/main` was
NON-EMPTY at plan time. The 20 commits ahead include ENG-151 (linear.sh
human-readable header + reapply bracket-header invariant), ENG-153
(guards.sh require `--reason` on bump), ENG-120 (Within-stage iteration
loop), ENG-138 (review-rejection trip gating on `implementing`), plus
documentation updates. Spot-checks of the files in this plan's File
Structure against the upstream commits:

- `bin/run-stage.sh` — ENG-151's reapply-bracket-header change is in
  `bin/linear.sh`, not `bin/run-stage.sh`. ENG-153 / ENG-138 changes are
  in `bin/guards.sh`. The detective sites at lines ~984 (function area)
  and ~1843 (call site) are unchanged on origin/main.
- `bin/dispatch.sh` — ENG-151 added a bracketed header line to
  `add_comment` / `add_or_update_comment` in `bin/linear.sh`; no overlap
  with the detective-resolved `cmd[]` area in dispatch.sh.
- `bin/render-prompt.sh` — no upstream change.
- `bin/status.sh` — no upstream change.
- `bin/pipeline-events.json` — no upstream change.
- `bin/run-stage-test.sh` / `bin/dispatch-test.sh` / `bin/render-prompt-test.sh`
  / `bin/pipeline-test.sh` — adversarial-coverage additions in ENG-151 /
  ENG-153 / ENG-120 (no removal of existing tokens).

Clean drift. Task 0 rebases onto `origin/main` before any other task
begins; Assumption Inventory line references are re-verified post-rebase
by the same Task. Subsequent tasks use content-anchored Edit boundaries
(comment headers, function signatures, distinctive surrounding tokens)
so the rebase cannot drift them.

| Assumption | Status | Verified at |
|---|---|---|
| `bin/run-stage.sh:984` defines `_validate_dispatch_envelope() { … }` — the function whose shape we mirror; sidecar path is `${d}/.envelope-transcript-${stage}` at line 989 | **verified** | `bin/run-stage.sh:984,988-989` |
| `bin/run-stage.sh:1068` is the closing `}` of `_validate_dispatch_envelope`; `bin/run-stage.sh:1070` opens the next function's comment `# ENG-122: plan-contract validator.` — content anchor for the new detective function's insertion point | **verified** | `bin/run-stage.sh:1068-1070` |
| `bin/run-stage.sh:1843-1862` is the post-dispatch site that gates on `if (( ! skip_dispatch ))`, runs the envelope validator with `_env_rc`, exits 29 on violation (preserving sidecar), then `rm -f`s the sidecar on clean exit at line 1860 | **verified** | `bin/run-stage.sh:1843-1862` |
| `bin/run-stage.sh::_clear_current_stage_slots` (line 934) clears the CURRENT stage's `stage-summary-${stage}.md` and `wait-${stage}.json`; comment at lines 924-933 enumerates "Cleared" vs "NOT cleared"; this is the natural co-site for the Phase B `.rendered-paths-${stage}` sidecar pre-clean | **verified** | `bin/run-stage.sh:924-942` |
| `bin/dispatch.sh::_render_and_capture_stream` at line 70 persists the transcript via `tee "$raw_capture"` and copies to the envelope sidecar at line 77 (`envelope_sidecar="${issue_dir}/.envelope-transcript-${stage}"`); pre-clean at line 78 (`rm -f "$violation_file" "$envelope_sidecar"`) is the only mutation of the file before the renderer writes it | **verified** | `bin/dispatch.sh:70,73-78` |
| `bin/dispatch.sh::main` at line 564 constructs the `cmd[]` argv array starting at line 713 (`local cmd=(env PIPELINE_WRITER=agent ...)`) and ends `--allowed-tools "$tools"` at line 749; this is the precedent site for the brainstorm's PIPELINE_CLAUDE_VERSION fork — but see plan-doc D-001 decision below for the resolved location | **verified** | `bin/dispatch.sh:564,713-750` |
| `bin/metrics.sh` accepts a free-string `event` (line 20: `local event="${1:-}"`); no schema enum — the new event name `sandbox_denial` requires zero schema change | **verified** | `bin/metrics.sh:19-75` (function body); `bin/metrics.sh:67` (jq object literal uses `--arg event`) |
| `bin/pipeline-events.json:10-21` is the `halt_reasons` array; current entries are 10 strings ending with `"plan-contract-invalid"` at line 20; adding `"sandbox-contract-violation"` is a one-line array-append | **verified** | `bin/pipeline-events.json:10-21` |
| `bin/render-prompt.sh:41-58` is the `PROMPT_RESOLVERS` registry as one heredoc-style string; path-shaped resolvers are `brainstorm_file`, `plan_file`, `stage_summary_path`, `learned_rules_dir`, `progress_md_path`, `plan_json` (six entries); non-path-shaped entries (`issue_id`, `date`, `slug`, etc.) must NOT be persisted to the sidecar | **verified** | `bin/render-prompt.sh:41-58` (registry); `bin/render-prompt.sh:482-484,496-497` (path-shaped resolver bindings); `bin/render-prompt.sh:309-340` (`_resolve_plan_json` is path-shaped — returns a file path) |
| `bin/render-prompt.sh::main` ends with `resolve_block_tokens "$block" \| append_project_profile "$stage"` at line 534, immediately preceded by `_RENDER_STAGE="$stage"` at line 532; insertion point for the sidecar writer is between line 533 (blank line) and line 534 | **verified** | `bin/render-prompt.sh:532-535` |
| `bin/render-prompt.sh::main`'s stdout becomes the prompt for the agent (consumed by `dispatch.sh` via `< $prompt_file`); the sidecar writer MUST redirect to `> $path`, never to stdout | **verified** | `bin/dispatch.sh:671` (`< $prompt_file`); `bin/render-prompt.sh:534` (stdout pipeline) |
| `bin/status.sh::show_resource_baseline` at lines 368-381 is the precedent for an `events.jsonl`-aggregating section function; `bin/status.sh::main` at lines 385-395 wires sections in order; `show_resource_baseline` is at line 390, `show_cost_summary` at line 391 — the insertion point is between them | **verified** | `bin/status.sh:368-381,385-395` |
| `bin/common.sh:68-72` defines `issue_dir <ident>`; `bin/common.sh:78-81` defines `progress_md_path <ident>`; both return `$PROJECT_STATE_DIR/$ident`-rooted paths | **verified** | `bin/common.sh:68-72,78-81` |
| `bin/common.sh:297` (or near) maps `29 → envelope-violation` in `failure_outcome_for_exit`; rc=29 is reused by ENG-87 (envelope-validator), ENG-109 (progress.md Write), ENG-155 D-003 (orchestrator-owned-files Write/Edit); Phase B promotes to the same code, distinct halt-reason token | **verified** | `bin/common.sh:305-337` per ENG-155 plan; `bin/run-stage.sh:1848` (`if (( _env_rc == 29 ))`) confirms current rc=29 semantics |
| `bin/run-stage-test.sh:4274-4400` is the ENG-87 `_validate_dispatch_envelope` test block — precedent shape for the Phase A detective fixtures (Case 87-F clean / 87-H violation pattern); `bin/run-stage-test.sh` already in the project-profile gate line | **verified** | `bin/run-stage-test.sh:4274-4400`; `learned-rules/harness/project-profile.md:17` |
| `bin/dispatch-test.sh:115-130` defines the `claude` argv-capture stub — precedent for any new dispatch.sh argv assertion (none required by this plan since `PIPELINE_CLAUDE_VERSION` resolves inside the metric helper, not in `dispatch.sh::main`) | **verified** | `bin/dispatch-test.sh:115-130` |
| `bin/render-prompt-test.sh:155-291` is the ENG-87 `PROMPT_RESOLVERS` registry-coverage block (Case 87-R1 + 87-R5); precedent for asserting the path-shaped allowlist | **verified** | `bin/render-prompt-test.sh:155-291` |
| `bin/pipeline-test.sh:69` (`PE3: bogus halt reason rejected`) is the precedent for asserting registry validation of a new halt-reason token | **verified** | `bin/pipeline-test.sh:69` |
| `learned-rules/harness/project-profile.md::## Build & test gates` Test line (line 17) enumerates `bin/dispatch-test.sh`, `bin/run-stage-test.sh`, `bin/render-prompt-test.sh`, `bin/common-test.sh` etc. — every test file modified by this plan is already in the gate; NO new `bin/*-test.sh` file is added by this plan → no project-profile gate-line update required (add-side test-gate closure: PASS) | **verified** | `learned-rules/harness/project-profile.md:17` |
| **Test-gate closure (remove-side).** This plan REMOVES no tokens from any test-pinned site. The new detective is purely additive (one new function, two new call-site lines, one array-append, one sidecar-writer block, one new status-section function). No existing assertion is invalidated; no helper rename; no enum value retirement | **verified** | grep audit of `bin/*-test.sh` for any name introduced by this plan — `_emit_sandbox_denial_metric` (new), `show_sandbox_denials` (new), `sandbox_denial` event (new), `sandbox-contract-violation` reason (new), `.rendered-paths-` sidecar (new) — all return zero matches in current test files |
| Live sandbox-denial body substring `may only list files in the allowed working directories` was observed verbatim in this plan-dispatch's own pre-plan exploration (`ls /Users/.../learned-rules/harness/` was blocked) — confirms the brainstorm §10 row 18 live-substring assumption | **verified — observed live in this plan dispatch** | this dispatch's transcript above; matches brainstorm §10 row 18 |
| `tool_result.content` is the canonical home for the denial body string in claude's stream-json (vs. a separate `error_message` field) | **assumed** | brainstorm §10 row 18 flagged "assumed"; Phase A jq selector below filters on `select(.type=="user") \| .message.content[]? \| select(.type=="tool_result" and .is_error==true) \| .content`. A genuine first-Phase-A-dispatch capture should be inspected (status.sh row will tell us — if `paths=` is consistently empty when denials are non-zero, the selector is wrong and needs correction). Recovery: if the assumption fails, the metric row still fires (count > 0) but `paths=` is empty; the operator inspects a real `.envelope-transcript-<stage>` and pins the correct selector in a follow-up. Non-blocking for the Phase A ship. |
| `bin/linear.sh add-comment` auto-injects the `<!-- meta: dispatch id=… stage=… -->` marker when `PIPELINE_DISPATCH_ID` is set, so the Phase B halt comment inherits the ENG-87 freshness contract without explicit token emission | **verified** | preamble at top of this plan-dispatch's prompt: "the chokepoint owns this marker"; ENG-87 brainstorm §"Per-medium primitives" |
| `learned-rules/harness/plan.md` does NOT exist (only `build.md` + `project-profile.md`); the plan-stage retrospective rules surface is absent — Step 7 of the dispatch prompt's preamble points there but the file is genuinely missing in this branch and on `origin/main` | **verified** | `ls learned-rules/harness/` returned `build.md` + `project-profile.md` only |

## File Structure

- `bin/run-stage.sh` — **modified** (D-001 new function `_emit_sandbox_denial_metric`; D-001 call-site addition between `_validate_dispatch_envelope` and `rm -f`; D-004 `_clear_current_stage_slots` adds `.rendered-paths-${stage}` pre-clean)
- `bin/render-prompt.sh` — **modified** (D-004 sidecar writer `_write_rendered_paths_sidecar` invoked from `main()` before `resolve_block_tokens`)
- `bin/status.sh` — **modified** (D-005 new section function `show_sandbox_denials`; `main()` wires between `show_resource_baseline` and `show_cost_summary`)
- `bin/pipeline-events.json` — **modified** (D-004 add `"sandbox-contract-violation"` to `halt_reasons` array)
- `docs/pipeline-vocabulary.md` — **modified** (regenerated via `bin/generate-vocabulary-doc.sh`; not hand-edited)
- `bin/run-stage-test.sh` — **modified** (Phase A detective fixtures: clean / denial-detected / Phase B contract-violation; `_clear_current_stage_slots` sidecar-removal fixture)
- `bin/render-prompt-test.sh` — **modified** (resolved-paths sidecar writer fixture: path-shaped allowlist coverage, dry-run safety, file path correctness)
- `bin/pipeline-test.sh` — **modified** (new fixture asserting `sandbox-contract-violation` is accepted by `pipeline.sh event verdict halt --reason`)

No new files. No new exit code (Phase B reuses rc=29). No new failure-outcome
taxonomy entry. No `learned-rules/<slug>/project-profile.md` change (the Test
command already covers every modified test file; no new gate-runnable file
added). No CLAUDE.md or `docs/architecture.md` update in this PR — those land
in the OQ-9 docs-debt follow-up (which also covers OQ-10's baseline-
interpretation guidance — "0–3 incidental, ≥5 suggests drift" — pinned
against real 7-day baseline data) after Phase B has fired at least once in
the wild (brainstorm §13 product persona; deferred per ENG-155 precedent).

**Brainstorm §6 architecture row override** (caught by coherence persona).
Brainstorm §6 row "D-003 — `PIPELINE_CLAUDE_VERSION` resolution" names
`bin/dispatch.sh::main` as the change site. This plan intentionally does
NOT touch `bin/dispatch.sh`: the brainstorm's `export PIPELINE_CLAUDE_VERSION`
proposal cannot work because `export` propagates env vars from parent to
child, but `dispatch.sh` is a child of `run-stage.sh` (the detective's
host process) — the export would never reach the parent. Plan-doc fix
(Task 1, "Decision — `claude_version` source"): resolve `claude --version`
inside `_emit_sandbox_denial_metric` only when `count > 0`. Strictly
cheaper than the brainstorm's per-dispatch fork; no propagation problem.

## API Contract

no new API surface (this is harness-internal bash plumbing; no FE↔BE handler
or RPC changes).

## Backend Tasks

### Task 0: Rebase onto origin/main
- `depends_on: []`
- `touches: (rebase-pull only — no edits authored by this plan)`
- [ ] Run `git fetch origin && git rebase origin/main` from the feature
  branch. Expected: clean rebase pulling in the 20 upstream commits listed
  in Assumption Inventory's "Branch-base freshness" section (ENG-151,
  ENG-153, ENG-120, ENG-138, plus docs updates). No conflicts expected —
  none of those commits touch `bin/run-stage.sh:984+`, `bin/run-stage.sh:1843+`,
  `bin/render-prompt.sh:407+`, `bin/status.sh:368+`, or `bin/pipeline-events.json`.
- [ ] Re-verify Assumption Inventory `path:line` references survived:
  `grep -n '_validate_dispatch_envelope() {' bin/run-stage.sh` should still
  hit a line in the 980-990 range (currently 984);
  `grep -n 'rm -f "$(issue_dir "$ident")/.envelope-transcript-' bin/run-stage.sh`
  should hit a line in the 1855-1865 range (currently 1860);
  `grep -n '^PROMPT_RESOLVERS=' bin/render-prompt.sh` should hit a line in
  the 38-44 range (currently 41); `grep -n '^show_resource_baseline()' bin/status.sh`
  should hit a line in the 365-375 range (currently 368). If any reference
  moved beyond its expected range, update this Assumption Inventory
  BEFORE continuing to Task 1.

### Task 1: Add Phase A detective `_emit_sandbox_denial_metric` to `bin/run-stage.sh`
- `depends_on: [0]`
- `touches: bin/run-stage.sh::_emit_sandbox_denial_metric (new), bin/run-stage.sh post-dispatch site`

**Decision — `claude_version` source (plan-doc resolution of brainstorm D-003 +
plan-doc OQ).** The brainstorm proposed setting `PIPELINE_CLAUDE_VERSION` in
`bin/dispatch.sh::main` and `export`ing it. That cannot work as written:
`export` propagates env vars DOWN to children, not UP to the parent
`run-stage.sh::main` process where the detective runs. Plan-doc fix:
resolve `claude --version` inside `_emit_sandbox_denial_metric` itself,
only when `count > 0` (so the ~10ms fork is paid only on dispatches that
actually had denials — strictly cheaper than the brainstorm's
per-dispatch fork). No `dispatch.sh` change required.

**Decision — signature table.** Hardcoded inside the function body, exactly as
brainstorm D-002 specified. Two entries: `sandbox-path` (`may only list files
in the allowed working directories`) and `bash-classifier` (`This command
requires approval`). Substring match (not regex); first-hit-wins per-denial;
output `signatures` field is the deduped comma-separated set across all
denials in the dispatch.

**Decision — paths attribution.** Use jq to walk the transcript twice:
first pass extracts `tool_use_id` → `(file_path // command)` map from
`assistant.message.content[]` `tool_use` entries; second pass joins each
denied `user.message.content[]` `tool_result` to its preceding `tool_use`
via `tool_use_id`. If the join finds a `file_path`, that's the denied
path. If it finds a `command` and the command is path-shaped (e.g.,
`ls /Users/…`), best-effort extracts the trailing path token via
`awk '{print $NF}'`. If neither yields a path, the empty string is
emitted for that denial (Phase A still reports the row; Phase B is a
no-op on that denial per brainstorm OQ-6).

**Implementation:**

- [ ] In `bin/run-stage.sh`, IMMEDIATELY AFTER the closing `}` of
  `_validate_dispatch_envelope` (~line 1068) AND BEFORE the comment block
  `# ENG-122: plan-contract validator.` opening `_validate_plan_contract`
  (~line 1070), insert a new function. Content anchor: the literal comment
  header `# ENG-122: plan-contract validator.` — insert the new function
  immediately above it, separated by a blank line:

  ```bash
  # ENG-156 D-001 (Phase A) + D-004 (Phase B): post-dispatch sandbox-denial
  # detective. Scans .envelope-transcript-<stage>.ndjson for
  # `tool_result.is_error:true` rows matching a 2-entry signature table.
  # Phase A: always log-only — one events.jsonl row per dispatch when
  # denial count > 0. Phase B: when orchestrator.sandbox_contract_halt is
  # true AND a denied path matches a path resolved by PROMPT_RESOLVERS
  # (read from .rendered-paths-<stage>), promotes to rc=29 halt with
  # reason=sandbox-contract-violation. Mirror of _validate_dispatch_envelope
  # at a different axis (tool_result vs tool_use). Sidecar fail-open: missing
  # or empty file returns 0 silently (matches the envelope-validator's
  # `[[ -s "$sidecar" ]] || return 0` shape).
  _emit_sandbox_denial_metric() {
    local PIPELINE_WRITER=orchestrator
    export PIPELINE_WRITER
    local ident="$1" stage="$2"
    local d; d="$(issue_dir "$ident")"
    local sidecar="${d}/.envelope-transcript-${stage}"
    [[ -s "$sidecar" ]] || return 0

    # Walk the transcript twice via a single jq invocation:
    #  Pass 1: build tool_use_id → (file_path // command-trailing-token) map.
    #  Pass 2: for each user.tool_result with is_error==true, classify
    #    content via the 2-entry signature table; emit one TSV row per
    #    denial: <signature>\t<path>.
    # Substring match (no regex compilation inside --arg-bound jq strings —
    # awkward to test). Aggregation to count + comma-separated signatures
    # + comma-separated paths happens in shell post-jq for clarity.
    local denials_tsv
    denials_tsv="$(jq -Rr '
      [inputs | (fromjson? // empty)] as $events
      | ($events
        | map(select(.type == "assistant")
              | .message.content[]?
              | select(.type == "tool_use")
              | {id: .id, path: (.input.file_path // (.input.command // "" | split(" ") | last // ""))})
        | from_entries) as $tu_map
      | $events[]
      | select(.type == "user")
      | .message.content[]?
      | select(.type == "tool_result" and (.is_error == true))
      | (.content // "" | if type == "array" then map(.text // "") | join(" ") else tostring end) as $body
      | (if ($body | contains("may only list files in the allowed working directories")) then "sandbox-path"
         elif ($body | contains("This command requires approval")) then "bash-classifier"
         else "" end) as $sig
      | select($sig != "")
      | ($tu_map[.tool_use_id] // {path: ""}).path as $p
      | "\($sig)\t\($p)"
    ' "$sidecar" 2>/dev/null)" || denials_tsv=""

    [[ -n "$denials_tsv" ]] || return 0
    local count signatures paths
    count="$(printf '%s\n' "$denials_tsv" | wc -l | awk '{print $1}')"
    signatures="$(printf '%s\n' "$denials_tsv" | awk -F'\t' '{print $1}' | sort -u | paste -sd, -)"
    paths="$(printf '%s\n' "$denials_tsv" | awk -F'\t' '$2 != "" {print $2}' | sort -u | paste -sd, -)"

    # Extract only the version token (first whitespace-delimited field).
    # `claude --version` emits e.g. `1.0.93 (Claude Code)` with an embedded
    # space + parenthesised suffix; without `awk '{print $1}'` the embedded
    # space would split the metric notes' space-delimited fields and
    # `show_sandbox_denials`'s `capture("claude_version=(?<v>\\S+)")` selector
    # would silently truncate, leaking `(Claude` into the next pseudo-field.
    local claude_version
    claude_version="$(claude --version 2>/dev/null | head -1 | awk '{print $1}' || true)"
    [[ -n "$claude_version" ]] || claude_version="unknown"

    # Phase B: read .rendered-paths-<stage> (if present) and check whether
    # any denied path contains a resolved path-string. Gated on the
    # orchestrator.sandbox_contract_halt config flag (default false).
    local phase_b_enabled=0
    if [[ -f "$CONFIG" ]]; then
      local _cfg
      _cfg="$(jq -r '.orchestrator.sandbox_contract_halt // false' "$CONFIG" 2>/dev/null || true)"
      [[ "$_cfg" == "true" ]] && phase_b_enabled=1
    fi

    local outcome="detected"
    local matched_token="" matched_path=""
    local rp="${d}/.rendered-paths-${stage}"
    if (( phase_b_enabled )) && [[ -s "$rp" ]] && [[ -n "$paths" ]]; then
      # paths is a comma-separated set; iterate denied paths against
      # each resolved-path line. First match wins.
      local _dp _tok _val
      while IFS=, read -ra _denied; do
        for _dp in "${_denied[@]}"; do
          [[ -n "$_dp" ]] || continue
          while IFS=$'\t' read -r _tok _val; do
            [[ -n "$_val" ]] || continue
            if [[ "$_dp" == *"$_val"* ]]; then
              matched_token="$_tok"
              matched_path="$_dp"
              break 3
            fi
          done < "$rp"
        done
      done <<< "$paths"
    fi

    if [[ -n "$matched_token" ]]; then
      outcome="contract-violation"
    fi

    # Always emit the metric row (Phase A behavior preserved even when
    # Phase B fires — operator gets both the halt comment and the
    # events.jsonl row for retrospective consumption).
    bash "$SCRIPT_DIR/metrics.sh" sandbox_denial "$ident" "$stage" "$outcome" 0 \
      "count=$count signatures=$signatures paths=$paths claude_version=$claude_version" \
      || log "[sandbox-denial] metric emit failed for $ident/$stage"

    if [[ -n "$matched_token" ]]; then
      # Phase B halt path. Sidecar carries the unsanitised matched_path
      # (operator-read only; never parsed by parse_pipeline_marker).
      # Linear comment body uses ONLY $matched_token (closed enumeration
      # from PROMPT_RESOLVERS path-shaped allowlist) and orchestrator-
      # generated $ident / $PIPELINE_DISPATCH_ID. Matches ENG-87
      # review-iter-7 Critical 3 / ENG-155 D-004 sanitisation precedent.
      printf 'sandbox-contract-violation: token=%s path=%s\n' \
        "$matched_token" "$matched_path" \
        > "${d}/.transcript-violation-${stage}"
      local body
      body="$(printf '<!-- pipeline: verdict result=halt reason=sandbox-contract-violation -->\n\nSandbox blocked agent write to a harness-contract path on dispatch_id=%s stage=%s.\n\nResolver token: `%s`\n\nThe orchestrator rendered this resolver value into the agent prompt and the sandbox denied the agent'\''s tool call against it. Inspect `%s/.transcript-violation-%s` for the denied path; expected fix is the project profile / `--add-dir` / tool-allowlist (NOT the agent prompt).\n\n**Resume:** fix the contract drift, then run `bash bin/pipeline.sh decide %s --action continue`.' \
        "${PIPELINE_DISPATCH_ID:-unknown}" "$stage" "$matched_token" "$d" "$stage" "$ident")"
      bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true
      return 29
    fi
    return 0
  }
  ```

- [ ] In `bin/run-stage.sh`, AFTER the existing envelope-validator clean-exit
  branch at line 1860 (`rm -f "$(issue_dir "$ident")/.envelope-transcript-${stage}" 2>/dev/null || true`)
  AND BEFORE the `;;` that closes the `case` arm at line 1861, insert the new
  detective call. Content anchor: the literal line
  `rm -f "$(issue_dir "$ident")/.envelope-transcript-${stage}" 2>/dev/null || true`
  — replace with the two-line block so the detective runs BEFORE the sidecar
  is removed (Phase A reads the sidecar; cleanup happens after):

  ```bash
          # ENG-156: Phase A detective (always log-only); Phase B halt
          # when config flag is on AND a PROMPT_RESOLVERS path is denied.
          local _sd_rc=0
          _emit_sandbox_denial_metric "$ident" "$stage" || _sd_rc=$?
          if (( _sd_rc == 29 )); then
            classify_failure "$ident" "$stage" "skip-until-human-acts" \
              "sandbox-contract-violation: orchestrator rendered a path the sandbox denied (inspect $(issue_dir "$ident")/.transcript-violation-${stage})" 29
            # ENG-87 review C3 precedent: preserve the envelope-transcript
            # sidecar on the halt path for forensic review (mirrors line 1851
            # comment block). The next clean dispatch's pre-clean removes it.
            exit 29
          fi
          rm -f "$(issue_dir "$ident")/.envelope-transcript-${stage}" 2>/dev/null || true
  ```

  Note: the `rm -f` line moves INSIDE the new block (after the rc==29 check).
  The replaced original `rm -f` line is the SAME line, now the trailing line
  of the inserted block.

### Task 2: Add `.rendered-paths-<stage>` sidecar writer to `bin/render-prompt.sh`
- `depends_on: [0]`
- `touches: bin/render-prompt.sh::main, bin/render-prompt.sh::_write_rendered_paths_sidecar (new)`

**Decision — path-shaped allowlist.** Six resolvers: `brainstorm_file`,
`plan_file`, `stage_summary_path`, `learned_rules_dir`, `progress_md_path`,
`plan_json`. Enumerated explicitly inside the writer; non-path resolvers
(`issue_id`, `date`, `slug`, `issue_title`, `issue_description`,
`branch_name`, `dispatch_id`, `review_findings`, `qa_findings`,
`issue_id_lower`) are NOT persisted.

**Decision — writer location.** New helper function
`_write_rendered_paths_sidecar` defined near other helpers (after
`AGENT_RUNTIME_TOKENS` block around line 78); called from `main()`
AFTER `_RENDER_*` globals are bound (line 532) and BEFORE
`resolve_block_tokens` runs (line 534). This guarantees the sidecar reflects
the same resolved values the agent's prompt receives.

**Decision — release-stage carve-out.** The `released` stage's main()
returns early at line 458 BEFORE the `_RENDER_*` binding block. The sidecar
writer therefore never runs on release dispatches. Phase B's gate on
`brainstorming|planning|implementing|ui|reviewing|qa|building` already
excludes release, so this is consistent — no contract held against
release-stage paths.

**Implementation:**

- [ ] In `bin/render-prompt.sh`, AFTER the `AGENT_RUNTIME_TOKENS=' file pr_number stage_failure_summary_path '`
  line (~line 78) AND BEFORE the `lookup_section() {` function (~line 80),
  insert a new helper function. Content anchor: the literal closing line
  `AGENT_RUNTIME_TOKENS=' file pr_number stage_failure_summary_path '`
  and the opening `lookup_section() {` — insert the new function between
  them, separated by blank lines:

  ```bash
  # ENG-156 D-004: persist the map of path-shaped resolver tokens →
  # resolved values to $(issue_dir "$ident")/.rendered-paths-<stage>
  # so the post-dispatch detective in run-stage.sh can match denied
  # paths against the harness contract surface. Six resolvers are
  # path-shaped; non-path resolvers (issue_id, date, slug, etc.) are
  # excluded by enumeration. Output format: one `<token>\t<value>`
  # line per resolver that returned a non-empty value. Caller passes
  # the absolute target file path; we redirect with `>` so the prompt
  # stdout pipeline at main() is untouched.
  _write_rendered_paths_sidecar() {
    local sidecar_path="$1"
    [[ -n "$sidecar_path" ]] || return 0
    {
      [[ -n "${_RENDER_BRAINSTORM_FILE:-}" ]] && printf 'brainstorm_file\t%s\n' "$_RENDER_BRAINSTORM_FILE"
      [[ -n "${_RENDER_PLAN_FILE:-}" ]]      && printf 'plan_file\t%s\n'      "$_RENDER_PLAN_FILE"
      [[ -n "${_RENDER_STAGE_SUMMARY_PATH:-}" ]] && printf 'stage_summary_path\t%s\n' "$_RENDER_STAGE_SUMMARY_PATH"
      [[ -n "${_RENDER_LEARNED_RULES_DIR:-}" ]]  && printf 'learned_rules_dir\t%s\n'  "$_RENDER_LEARNED_RULES_DIR"
      [[ -n "${_RENDER_PROGRESS_MD_PATH:-}" ]]   && printf 'progress_md_path\t%s\n'   "$_RENDER_PROGRESS_MD_PATH"
      # plan_json's resolver `_resolve_plan_json` (line ~309) returns the
      # FILE CONTENTS, not the path — so we cannot reuse it here. The path
      # this sidecar is named after is `${_RENDER_PLAN_FILE%.md}.json`
      # (the resolver derives the same way internally at line ~313). Only
      # write the line when the resolved file actually exists on disk;
      # otherwise the detective would match denials against a non-existent
      # contract surface.
      if [[ -n "${_RENDER_PLAN_FILE:-}" ]]; then
        local _pj_path="${_RENDER_PLAN_FILE%.md}.json"
        [[ -f "$_pj_path" ]] && printf 'plan_json\t%s\n' "$_pj_path"
      fi
    } > "$sidecar_path" 2>/dev/null || true
  }
  ```

- [ ] In `bin/render-prompt.sh::main`, AFTER the binding line
  `_RENDER_STAGE="$stage"` (~line 532) AND BEFORE the final pipeline
  line `resolve_block_tokens "$block" \| append_project_profile "$stage"` (~line 534),
  insert the writer invocation. Content anchor: the literal line
  `_RENDER_STAGE="$stage"` (no other occurrence of this exact assignment
  in the file) — insert the writer call immediately after it:

  ```bash
    # ENG-156 D-004: persist resolved path-shaped resolver values so the
    # post-dispatch sandbox-denial detective can match denied paths
    # against the harness contract surface. Best-effort — failures
    # leave Phase B with no sidecar to read (falls through to Phase A).
    _write_rendered_paths_sidecar "$(issue_dir "$issue_id")/.rendered-paths-${stage}"
  ```

### Task 3: Pre-clean `.rendered-paths-<stage>` in `_clear_current_stage_slots`
- `depends_on: [0]`
- `touches: bin/run-stage.sh::_clear_current_stage_slots`

- [ ] In `bin/run-stage.sh::_clear_current_stage_slots` (~line 934), AFTER
  the existing line `rm -f "$d/wait-${stage}.json"        2>/dev/null || true`
  (~line 940) AND BEFORE the `return 0` line (~line 941), insert one new
  removal line. Content anchor: the literal line
  `rm -f "$d/wait-${stage}.json"        2>/dev/null || true` (the only
  occurrence in the file inside `_clear_current_stage_slots`):

  ```bash
    rm -f "$d/.rendered-paths-${stage}" 2>/dev/null || true
  ```

  Also update the function-level documentation comment block above the
  function (lines 924-933) to add a line under "Cleared" for the new
  sidecar, content anchor: the existing line
  `#   wait-${stage}.json         (overwritten by _handle_wait when the`
  — insert immediately before it:

  ```bash
  #   .rendered-paths-${stage}   (rewritten by render-prompt.sh at dispatch
  #                               render; clearing here avoids stale-from-
  #                               prior-attempt contamination on retry —
  #                               OQ-5)
  ```

### Task 4: Register `sandbox-contract-violation` in `bin/pipeline-events.json::halt_reasons`
- `depends_on: [0]`
- `touches: bin/pipeline-events.json, docs/pipeline-vocabulary.md`

- [ ] In `bin/pipeline-events.json` (line 20), AFTER the line
  `"plan-contract-invalid"` (currently the last entry, with a trailing `,`
  needed to be added) AND BEFORE the closing `]` of the `halt_reasons`
  array on line 21, insert one new entry. Content anchor: the literal
  line `"plan-contract-invalid"` AND the closing `]` on line 21:

  ```diff
  -    "plan-contract-invalid"
  +    "plan-contract-invalid",
  +    "sandbox-contract-violation"
     ],
  ```

- [ ] Regenerate `docs/pipeline-vocabulary.md`:

  ```bash
  bash bin/generate-vocabulary-doc.sh > docs/pipeline-vocabulary.md
  ```

  Stage agent must commit the regenerated file in the same commit as the
  JSON edit (the file carries a generated-from-JSON header comment).

### Task 5: Add `show_sandbox_denials` section to `bin/status.sh`
- `depends_on: [1]`
- `touches: bin/status.sh::show_sandbox_denials (new), bin/status.sh::main`

- [ ] In `bin/status.sh`, AFTER the closing `}` of `show_resource_baseline`
  (~line 381) AND BEFORE the comment header
  `# ────────────────────────────────────────────────────────────────────────── main`
  (~line 383), insert a new section function. Content anchor: the literal
  comment header
  `# ────────────────────────────────────────────────────────────────────────── main`
  — insert the new function immediately above it, separated by blank lines:

  ```bash
  # ENG-156 D-005: aggregate events.jsonl::sandbox_denial rows over the last
  # 7 days, bucketed by claude_version × stage × signatures. Mirrors
  # show_resource_baseline's events.jsonl-reading shape. macOS-safe date
  # invocation (date -u -v-7d || date -u -d '7 days ago').
  show_sandbox_denials() {
    section "Sandbox denials (last 7d, by claude_version + stage + signatures)"
    local ev="$PROJECT_STATE_DIR/metrics/events.jsonl"
    [[ -f "$ev" ]] || { printf '  %s(no events.jsonl)%s\n' "$C_DIM" "$C_RST"; return 0; }
    local cutoff
    cutoff="$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)"
    local lines
    lines="$(jq -r --arg cutoff "$cutoff" '
      select(.event == "sandbox_denial" and .ts >= $cutoff)
      | (.notes // "") as $n
      | (($n | capture("claude_version=(?<v>\\S+)"; "g")).v // "?") as $ver
      | (($n | capture("signatures=(?<s>\\S+)"; "g")).s // "?") as $sigs
      | [$ver, .stage, $sigs] | @tsv
    ' "$ev" 2>/dev/null \
    | sort | uniq -c | sort -rn \
    | awk '{ printf "  %4s× v=%-15s stage=%-13s sigs=%s\n", $1, $2, $3, $4 }')"
    if [[ -z "$lines" ]]; then
      printf '  %s(no sandbox_denial events in last 7d)%s\n' "$C_DIM" "$C_RST"
    else
      printf '%s\n' "$lines"
    fi
  }
  ```

- [ ] In `bin/status.sh::main` (~line 385), AFTER the line
  `show_resource_baseline     || true` (~line 390) AND BEFORE
  `show_cost_summary          || true` (~line 391), insert the new
  invocation. Content anchor: the literal lines
  `show_resource_baseline     || true` (line 390) and
  `show_cost_summary          || true` (line 391):

  ```bash
    show_sandbox_denials       || true
  ```

### Task 6: Phase A detective tests in `bin/run-stage-test.sh`
- `depends_on: [1, 3]`
- `touches: bin/run-stage-test.sh::ENG-156 fixtures`

- [ ] In `bin/run-stage-test.sh`, AFTER the existing ENG-87
  `_validate_dispatch_envelope` block ends (after the last
  `pass_at "ENG-87 …"` / `fail_at "ENG-87 …"` line; locate by grepping
  for the `# ─── ENG-87:` heading at line 4274 and finding its block end
  — typically a blank line followed by the next `# ─── ENG-NNN:` heading
  or EOF), insert a new ENG-156 block. Content anchor: the line
  `# ─── ENG-87: _validate_dispatch_envelope (Task 9) ──────────────────────`
  (line 4274) — the new block goes after that block's last case ends:

  ```bash
  # ─── ENG-156: _emit_sandbox_denial_metric (Phase A + Phase B) ──────────
  # Sibling of ENG-87. Fixtures synthesise .envelope-transcript-<stage>
  # carrying tool_result.is_error:true rows; the metric helper buckets
  # them, emits one events.jsonl row, and (under Phase B flag) halts on
  # a PROMPT_RESOLVERS-resolved path match.
  printf '\n--- ENG-156: _emit_sandbox_denial_metric ---\n'

  # Case 156-A: empty/missing sidecar → returns rc=0, no events.jsonl row.
  # Case 156-B: one sandbox-path denial + one bash-classifier denial →
  #   rc=0, single events.jsonl row with count=2 signatures=bash-classifier,sandbox-path
  #   paths=<paths> outcome=detected.
  # Case 156-C: success tool_result with is_error:false → no row emitted.
  # Case 156-D: Phase B flag on AND denied path matches a .rendered-paths
  #   line → rc=29, halt comment carries reason=sandbox-contract-violation,
  #   sidecar .transcript-violation-<stage> carries the matched token + path.
  # Case 156-E: Phase B flag on but denied path matches no rendered-path
  #   → rc=0, Phase A behavior preserved.
  # Case 156-F: Phase B flag default (unset) → rc=0 even on a matching denial.
  ```

  Implement each `Case 156-*` as a self-contained block following the
  precedent shape at `bin/run-stage-test.sh:4300-4400` (synth sidecar,
  invoke helper, grep CAPTURE_FILE for assertions, `pass_at` / `fail_at`).
  Key assertion shapes:
  - 156-B: `grep -qE '"event":"sandbox_denial"' "$EVENTS_FILE"` AND
    `grep -qE '"count=2"' "$EVENTS_FILE"` AND
    `grep -qF 'signatures=bash-classifier,sandbox-path' "$EVENTS_FILE"`
  - 156-D: rc capture `_emit_sandbox_denial_metric ENG-156D planning || _rc=$?` →
    `[[ $_rc == 29 ]]` AND `grep -qF '<!-- pipeline: verdict result=halt reason=sandbox-contract-violation -->' "$CAPTURE_FILE"`
    AND `grep -qE '^sandbox-contract-violation: token=progress_md_path path=' "$(issue_dir ENG-156D)/.transcript-violation-planning"`

- [ ] In `bin/run-stage-test.sh`, add Case 156-G inside the existing
  `_clear_current_stage_slots` test block (locate by grepping for
  `_clear_current_stage_slots` invocations in the test file): synth a
  `.rendered-paths-planning` file, call `_clear_current_stage_slots
  ENG-156G planning`, assert the file is gone.

### Task 7: Sidecar-writer test in `bin/render-prompt-test.sh`
- `depends_on: [2]`
- `touches: bin/render-prompt-test.sh::ENG-156 fixtures`

- [ ] In `bin/render-prompt-test.sh`, AFTER the existing
  `# ─── ENG-87: PROMPT_RESOLVERS registry + render-time validator ─────────`
  block ends (locate by grepping for `Case 87-R5` and finding its
  trailing `pass_at`/`fail_at`), insert a new ENG-156 block. Content
  anchor: the existing heading line at `bin/render-prompt-test.sh:155`:

  ```bash
  # ─── ENG-156: _write_rendered_paths_sidecar (Phase B contract surface) ──
  # The sidecar is the harness contract surface the Phase B detective
  # matches denied paths against. Fixtures pin the path-shaped allowlist
  # exactly so that adding a new path-shaped PROMPT_RESOLVERS entry
  # without updating the writer fails loudly.
  printf '\n--- ENG-156: _write_rendered_paths_sidecar ---\n'
  ```

  Cases:
  - 156-W1: write with all six path-shaped resolver values bound →
    sidecar has exactly six TSV lines (count assertion via `wc -l`) AND
    contains lines `^progress_md_path\t.*progress\.md$`,
    `^stage_summary_path\t.*stage-summary-.*\.md$` etc.
  - 156-W2: write with some resolvers empty (e.g., `_RENDER_PLAN_FILE=""`) →
    sidecar omits that resolver's line (4 or 5 lines).
  - 156-W3: assert that NON-path-shaped resolvers are NOT written:
    `! grep -qE '^issue_id\t' "$sidecar"`, same for `date`, `slug`,
    `issue_title`, `branch_name`, `dispatch_id`.

### Task 8: Registry-validation test in `bin/pipeline-test.sh`
- `depends_on: [4]`
- `touches: bin/pipeline-test.sh`

- [ ] In `bin/pipeline-test.sh`, AFTER the existing `PE3: bogus halt reason
  rejected` test (line 69), insert a new case PE-156 asserting
  `sandbox-contract-violation` is accepted by `pipeline.sh event ENG-156T
  verdict halt --reason sandbox-contract-violation`. Content anchor: the
  literal line `[[ "$out" == *"not in halt_reasons"* ]] && pass_at "PE3:`:

  ```bash
  # ENG-156: sandbox-contract-violation is registry-valid.
  out="$(PIPELINE_DRY_RUN=1 bash "$SCRIPT_DIR/pipeline.sh" event ENG-156T verdict halt --reason sandbox-contract-violation 2>&1 || true)"
  [[ "$out" != *"not in halt_reasons"* ]] && pass_at "ENG-156: sandbox-contract-violation accepted by registry" \
    || fail_at "ENG-156: sandbox-contract-violation accepted by registry" "got: $out"
  ```

### Task 9: Smoke gate — full test suite green
- `depends_on: [6, 7, 8]`
- `touches: (none — verification only)`

- [ ] Run the project profile's Test gate (the long `&&` chain at
  `learned-rules/harness/project-profile.md:17`). Every test must pass.
  If any test fails, return to the originating task and fix — DO NOT mark
  the dispatch complete with a failing gate.
- [ ] Run `bash .githooks/pre-commit` (covers the same suite plus
  `secret-probe-lint.sh`). Must exit 0.
- [ ] Run `bash bin/pipeline-test.sh` (not in the gate line but added to
  by Task 8; sibling test convention). Must exit 0.

## Frontend Tasks

no frontend tasks (this is a harness-internal bash plumbing change; no UI or FE↔BE handler surface).

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Sidecar missing (dry-run, scope-approval-replay, release stage) | `$sidecar` not exists or empty | `_emit_sandbox_denial_metric` returns 0 silently, no events.jsonl row | unit | `bin/run-stage-test.sh::Case 156-A` |
| Two distinct denial classes co-occur in one dispatch | Sidecar carries one `sandbox-path` denial + one `bash-classifier` denial | One events.jsonl row, `count=2`, `signatures=bash-classifier,sandbox-path` (deduped), `paths=…`, outcome=detected | unit | `bin/run-stage-test.sh::Case 156-B` |
| Probe-and-recover (Read on missing file) | tool_result with `is_error:true` but content does NOT match signature table | No events.jsonl row, rc=0 | unit | `bin/run-stage-test.sh::Case 156-C` |
| Phase B halt on contract drift | Phase B flag on AND denied path matches a `.rendered-paths-<stage>` line | rc=29, halt comment carries `reason=sandbox-contract-violation`, sidecar `.transcript-violation-<stage>` carries `token=<resolver_name> path=<denied_path>` | unit | `bin/run-stage-test.sh::Case 156-D` |
| Phase B incidental probe stays log-only | Phase B flag on but denied path is NOT in rendered-paths | rc=0, outcome=detected (Phase A behavior preserved) | unit | `bin/run-stage-test.sh::Case 156-E` |
| Phase B disabled by default | `orchestrator.sandbox_contract_halt` unset or false | rc=0 even on a matching denial (Phase A only) | unit | `bin/run-stage-test.sh::Case 156-F` |
| Stale `.rendered-paths-<stage>` from prior attempt | `_clear_current_stage_slots` runs at dispatch start | The file is removed | unit | `bin/run-stage-test.sh::Case 156-G` |
| Sidecar writer round-trip | All six path-shaped resolver `_RENDER_*` globals bound | Sidecar has exactly six TSV lines covering every path-shaped resolver | unit | `bin/render-prompt-test.sh::Case 156-W1` |
| Sidecar writer partial-binding | Some path-shaped resolvers empty | Sidecar omits those resolver lines (4 or 5 lines) | unit | `bin/render-prompt-test.sh::Case 156-W2` |
| Sidecar writer must not leak non-path resolvers | Bind `_RENDER_ISSUE_ID="ENG-156T"`, write sidecar | `! grep -qE '^issue_id\t'` AND same for `date`, `slug`, `issue_title`, `branch_name`, `dispatch_id` | unit | `bin/render-prompt-test.sh::Case 156-W3` |
| Registry rejects unregistered halt-reason | `bash pipeline.sh event verdict halt --reason xyzzy` | Rejection with `not in halt_reasons` | unit | `bin/pipeline-test.sh::PE3` (existing) |
| Registry accepts `sandbox-contract-violation` | `bash pipeline.sh event verdict halt --reason sandbox-contract-violation` | Accepted, no `not in halt_reasons` substring in stderr | unit | `bin/pipeline-test.sh::ENG-156` |
| `claude --version` fork fails | CLI absent / non-zero exit | `claude_version=unknown` in the row; rest of row populates normally | unit | `bin/run-stage-test.sh::Case 156-B` (assert with stubbed `claude` returning non-zero) |
| `metrics.sh` invocation fails (disk full) | `metrics.sh` exits non-zero | `log "[sandbox-denial] metric emit failed"`, detective still returns 0 (non-blocking) — same shape as ENG-81 `dispatch-resource-sample` | (integration; covered by smoke gate via existing metrics-test.sh resiliency tests) | n/a (defensive — read by inspection of `\|\| log` pattern in code review) |
| Status section renders zero rows | No `sandbox_denial` events in last 7d | Section prints `(no sandbox_denial events in last 7d)` in dim, no error | smoke | manual `bash bin/status.sh` after Task 5 (no dedicated `bin/status-test.sh` exists — covered by inspection) |
| End-to-end smoke | All file edits and Task 6/7/8 fixtures pass | `bash .githooks/pre-commit` exits 0 | smoke | `bin/dispatch-test.sh && bin/run-stage-test.sh && bin/render-prompt-test.sh && bin/pipeline-test.sh && bin/common-test.sh && bin/metrics-test.sh` (the project profile's Test line) |

## Test Strategy

**Unit (sibling shell tests).** Six new test cases in `bin/run-stage-test.sh`
(156-A through 156-G), three new test cases in `bin/render-prompt-test.sh`
(156-W1 through 156-W3), one new case in `bin/pipeline-test.sh` (ENG-156).
All follow the established source-and-stub pattern (`STUB_DIR` mock for
`linear.sh` / `metrics.sh`; fixture `.envelope-transcript-<stage>` files
in a per-case temp dir).

**Integration / smoke.** The full project profile Test gate
(`bin/dispatch-test.sh && bin/run-stage-test.sh && bin/poll-slot-test.sh
&& bin/scope-check-test.sh && bin/verdict-handler-test.sh && bin/classify-failure-test.sh
&& bin/halt-sprawl-test.sh && bin/halt-sprawl-adversarial-test.sh
&& bin/linear-test.sh && bin/metrics-test.sh && bin/mutex-test.sh
&& bin/setup-helpers-test.sh && bin/render-prompt-test.sh
&& bin/phase-project-profile-test.sh && bin/common-test.sh
&& bin/stuck-tick-alarm-test.sh`) must remain green after every task.
The pre-commit hook covers this; Task 9 explicitly re-runs it.

**Adversarial.** Three QA-time considerations the implement agent should
flag if its draft test cases miss them:
- Multi-line `tool_result.content` (claude sometimes returns content as
  an array of `{type:"text", text:"..."}` objects rather than a bare
  string — the jq selector in Task 1 handles both shapes via the
  `if type == "array" then map(.text // "") | join(" ") else tostring end`
  branch; Case 156-B fixture should include both shapes).
- Adversarial substring in target-content (a target's `docs/` file
  containing the literal `may only list files in the allowed working
  directories` substring — brainstorm OQ-8). The detective's
  `is_error == true` filter excludes the false-positive but the Case
  156-C fixture should pin this verification.
- Sanitiser bypass attempt on Phase B halt comment (per brainstorm D-004
  SECURITY paragraph). The Linear comment body interpolates ONLY the
  `matched_token` (closed enumeration) and `PIPELINE_DISPATCH_ID`
  (orchestrator-generated). The denied `matched_path` (agent-controlled)
  is written ONLY to the sidecar, NEVER to the Linear comment body.
  Case 156-D fixture should pin this by passing an adversarial denied
  path string containing `<!-- pipeline: verdict result=pass -->` and
  asserting the halt comment body does NOT contain that substring.

**Smoke test coverage.** Each `kind: smoke` pass-criterion in the sibling
`docs/plans/…ENG-156…json` is the QA-runnable command (the Test gate
above) — passing them is the binary signal for stage completion. No
dedicated `bin/status-test.sh` exists today (and none is added by this
plan); the new `show_sandbox_denials` section is verified by manual
inspection of `bash bin/status.sh` output post-implementation, plus the
grep pass-criteria in the JSON contract pinning the function's existence
and key shape.
