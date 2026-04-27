---
linear: ENG-26
date: 2026-04-27
topic: Track per-stage token counts, USD cost, and cache-hit stats from each `claude -p` invocation
spec: docs/brainstorms/2026-04-27-track-tokens-cost-and-cache-stats-per-stage-design.md
status: draft
---

# Track tokens, cost, and cache stats per stage — implementation plan

## Anti-anchoring check

- **Problem restatement.** The harness has no per-stage visibility into token use
  or USD cost from `claude -p`, so the operator cannot tell which stages are
  expensive or whether cache is warm.
- **Solution proportionality.** All work lives inside four existing `bin/*.sh`
  scripts plus two new `*-test.sh` siblings. No new crates, no schema migrations,
  no new exit codes, no new orchestrator surface. Stream-json + a six-field
  usage file is the smallest change that captures the four token counters,
  cost, and model.
- **Outcome.** Both checks pass. The brainstorm narrows the issue's "stage-grain
  visibility" goal explicitly (§1) and the proposed surface area is the same
  files the issue body lists ("Files likely to change").

## Goal

After this lands, every successful `claude -p` invocation under the harness
writes the four token counters + `total_cost_usd` + model into
`metrics/events.jsonl`, `bash bin/status.sh` prints a today/7d/MTD cost line
plus a per-stage breakdown, and every per-stage Linear comment ends with a
`cost: $X · in Yk · out Zk · cache N%` footer.

## Assumption inventory (codebase-fact verification)

Per learned rule P-002, every assumption that names code is verified against
current code with a quoted `path:line`. Every entry is a load-bearing fact for
the implementation; "assumed/new" is reserved for files this plan creates.

| ID | Assumption | Status | Evidence |
|---|---|---|---|
| A-01 | `bin/dispatch.sh::main` (`bin/dispatch.sh:55-87`) is the only chokepoint that runs `claude -p`. The `cmd` array is at `:78`; the live `tee` is at `:82`; the dry-run guard is at `:66-72`; `local tools` resolves at `:60-61`. | verified | `bin/dispatch.sh:55-87` (read in full). |
| A-02 | `bin/dispatch.sh` ends with the test-friendly sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`. | verified | `bin/dispatch.sh:89-91`. |
| A-03 | The cross-project claude mutex `acquire_claude_mutex` body spans `bin/dispatch.sh:17-30`; `release_claude_mutex` at `:32-34`; constants at `:14-15`; the trap is set at `:64`. Renderer work runs INSIDE the critical section. | verified | `bin/dispatch.sh:14-34, 63-64`. |
| A-04 | `bin/dispatch.sh::main` takes only `<stage> <prompt_file> [<log_file>]` — no positional issue_id. Five callers exist: `bin/run-stage.sh:276`, `bin/run-release-observer.sh:39`, `bin/run-retrospective-local.sh:72`, `bin/mutex-test.sh:33`, `bin/dry-run.sh:129`. Of these, only `run-stage.sh` has a Linear issue_id in scope. D-012 resolves this via env var `PIPELINE_ISSUE_ID`. | verified | `grep -n dispatch.sh bin/*.sh` enumerates the five sites. |
| A-05 | `bin/metrics.sh::main` (`bin/metrics.sh:10-33`) parses positional args and `notes="${*:-}"` at `:13` swallows ALL trailing args. The flag-pair parser MUST run before `notes` is computed (D-004). | verified | `bin/metrics.sh:10-33`. |
| A-06 | `bin/metrics.sh` ends with the test-friendly sentinel. | verified | `bin/metrics.sh:35-37`. |
| A-07 | `bin/run-stage.sh::post_completion_comment` (`:69-131`) is the single point where the per-stage Linear comment is built. The 32 KiB `head -c 32768` truncation at `:101` operates on `body` BEFORE composition; `pr_tail` is a local declared at `:77` and the surrounding `case`/`esac` block runs through `:88`; `comment_body` is composed at `:108-123`. The cost footer slots between `body` and `pr_tail` at the composition step (D-008). | verified | `bin/run-stage.sh:69-131`; specifically `:77-88` (pr_tail block), `:101` (truncate), `:122` (composition). |
| A-08 | `bin/run-stage.sh` calls `metrics.sh stage-end` at five sites, four of which ran claude: `:226` (paused — claude NOT run), `:341` (scope-approval-pending — claude ran), `:451` (success — claude ran), `:467` (halt-for-human — claude ran), `:471` (protocol-violation — claude ran). Cost flags attach to the four claude-ran sites. | verified | `grep -n "metrics.sh.*stage-end\|metrics.sh.*stage-start" bin/run-stage.sh` confirms the five sites. |
| A-09 | `bin/run-stage.sh:250-258` is the `skip_dispatch=1` decision; the `else` branch at `:283-285` emits `scope-approval-replay`. D-011's stale-usage-file `rm -f` belongs INSIDE the `else` branch BEFORE the `metrics.sh stage-start` at `:284`. | verified | `bin/run-stage.sh:250-285` read in full. |
| A-10 | `bin/run-stage.sh:276` is the existing dispatch invocation. D-012's `PIPELINE_ISSUE_ID="$ident"` export goes immediately before this line. | verified | `bin/run-stage.sh:276`. |
| A-11 | `bin/common.sh::issue_dir` (`:61-65`) returns `$PROJECT_STATE_DIR/<issue>` and is the canonical helper for per-issue paths. | verified | `bin/common.sh:61-65`. |
| A-12 | `bin/common.sh::PIPELINE_DRY_RUN` is exported at `:171-172` as the canonical ambient-context env-var pattern. D-012 follows this pattern for `PIPELINE_ISSUE_ID`. | verified | `bin/common.sh:171-172`. |
| A-13 | `bin/common.sh::failure_outcome_for_exit` (`:100-118`) is the exit-code → outcome switch the retrospective relies on. D-010 explicitly adds NO new exit codes, so this switch is unchanged. | verified | `bin/common.sh:100-118`. |
| A-14 | `bin/status.sh::main` (`:228-235`) calls four `show_*` helpers. Adding a fifth (`show_cost_summary`) is mechanical and matches the section pattern. The `events.jsonl` path is `$PROJECT_STATE_DIR/metrics/events.jsonl` (`:146`); the existing `show_metrics` reads it via `tail -n 10` (`:151`). | verified | `bin/status.sh:144-152, 226-235`. |
| A-15 | `bin/run-stage-test.sh:1-80` is the canonical STUB_DIR + heredoc + post-source-override pattern. The sourced sentinel pattern in run-stage.sh (`:477-479`) lets the test source the file without firing `main`. New `bin/dispatch-test.sh` and `bin/metrics-test.sh` follow this pattern. | verified | `bin/run-stage-test.sh:1-80`; `bin/run-stage.sh:477-479`. |
| A-16 | `bin/dispatch.sh:78` does not currently include `--output-format` or `--verbose` flags. They are additions to the `cmd` array. | verified | `bin/dispatch.sh:78` reads `local cmd=(claude -p --allowed-tools "$tools")`. |
| A-17 | The verified shape of `claude -p --output-format stream-json --verbose`'s final `result` event is fixed in brainstorm A-04: top-level `total_cost_usd`, nested `usage.{input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens}`, and model name as the FIRST key of `modelUsage` object. The renderer extracts model via `.modelUsage \| keys \| .[0]`. | verified via brainstorm A-04 live capture | `docs/brainstorms/2026-04-27-track-tokens-cost-and-cache-stats-per-stage-design.md:73-89`. |
| A-18 | New `bin/dispatch-test.sh` and `bin/metrics-test.sh` files. | assumed/new | Created by Task 5 and Task 6 of this plan. |
| A-19 | `events.jsonl` is append-only, written via `bin/metrics.sh:32`'s `>> "$jsonl_file"`. Adding optional fields is forward- and backward-compatible: legacy lines (no cost fields) read fine because the consumer side uses `jq '.cost_usd // 0'`. | verified | `bin/metrics.sh:32`. |
| A-20 | `bin/run-stage-test.sh:561-565` already stubs `dispatch.sh` as a no-op `exit 0`; new test cases that exercise cost-flag propagation set the usage file directly inside `issue_dir` and assert downstream metrics-call args, since the dispatch stub never runs the renderer. | verified | `bin/run-stage-test.sh:561-565`. |
| A-21 | `bin/dry-run.sh:135-138` sources `bin/dispatch.sh` with `TARGET_REPO=` already set; the new `USAGE_FILE` resolution in `main()` is conditional on `PIPELINE_ISSUE_ID` and is a no-op when sourcing happens for the allowed-tools regression check. | verified | `bin/dry-run.sh:135-141`. |
| A-22 | The renderer's intermediate `.raw-stream.ndjson.tmp` file lives at `$issue_dir` (per brainstorm SEC-008). `issue_dir "$ident"` resolves there via `bin/common.sh:61-65`; for non-issue callers (release / retrospective / mutex-test / dry-run) `PIPELINE_ISSUE_ID` is unset and the renderer block is skipped. | verified | `bin/common.sh:61-65`. |
| A-23 | macOS system bash is 3.2.57; no existing harness script uses `mapfile`/`readarray` (bash 4+ builtins). The cost-flags collection MUST use a portable `while IFS= read -r` accumulator into a `cost_flags+=()` array, not `mapfile -t`. | verified | `bash --version` reports `3.2.57(1)-release`; `grep -rn 'mapfile\|readarray' bin/` returns no matches. |

No assumed/new entry except A-18 (the two new test files this plan creates).
Every modified file's load-bearing function range is quoted with line numbers.
Per learned rule P-002, no "follows the existing pattern" claim is made
without an exact code excerpt above.

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `bin/metrics.sh` | Modify | Replace `notes="${*:-}"` (`:13`) with an explicit flag-pair parser that recognises `--tokens-in / --tokens-out / --cache-read / --cache-create / --cost-usd / --model`; conditionally include the six fields in the `jq -cn` body at `:23-31` (omit when unset, never `null`/`0`). |
| `bin/dispatch.sh` | Modify | Add `--output-format stream-json --verbose` to `cmd` (`:78`); insert `_render_and_capture_stream` between cmd and `tee` (`:79-86`); resolve `USAGE_FILE` from `PIPELINE_ISSUE_ID` env var inside `main()` AFTER `local tools=…` (`:60-61`) and BEFORE the dry-run guard (`:66`); `rm -f "$USAGE_FILE"` at function entry on both real and dry-run branches when set; `umask 077` for the post-stream usage-file write. |
| `bin/run-stage.sh` | Modify | Add `_cost_flags_for` and `_cost_footer` private helpers; `mapfile -t cost_flags < <(_cost_flags_for …)` and pass `"${cost_flags[@]}"` quoted into the four `metrics.sh stage-end` invocations at `:341, :451, :467, :471`; export `PIPELINE_ISSUE_ID="$ident"` immediately before the dispatch invocation at `:276`; append `_cost_footer` output in `post_completion_comment::comment_body` (`:122`) BETWEEN `$body` and `$pr_tail`; D-011 stale-file `rm -f` at the `else` branch of `skip_dispatch` (BEFORE `:284`). |
| `bin/status.sh` | Modify | Add `show_cost_summary` helper (called from `main` at `:230` between `show_active_issues` and `show_metrics`); add internal `_aggregate_cost_by_stage` consumed only by `show_cost_summary`; both read `$PROJECT_STATE_DIR/metrics/events.jsonl` (the same path `show_metrics` reads at `:146`). |
| `bin/dispatch-test.sh` | Create | Test the renderer + usage-file write path. Inline NDJSON heredoc fixtures, STUB_DIR `claude` that `cat`s a fixture, post-source override of globals. Asserts six-field shape, malformed-line tolerance, no-result soft fail, file mode `0600`. |
| `bin/metrics-test.sh` | Create | Test the flag-pair parser. Asserts: all six flags present produces a 13-key line; flags absent produces the existing 7-key line (no `null`s, no zeroes); flag-after-notes parses correctly; mixed flag + trailing-notes parses in any order. |
| `bin/run-stage-test.sh` | Modify | Extend in place. New cases: cost flags propagate when `usage-<stage>.json` is present in `issue_dir`; do not propagate when absent; `skip_dispatch` branch removes the file (D-011 regression). Hooks the existing capture-file pattern. |

No other files in the repo are touched. `AGENT_PROMPTS.md`, `render-prompt.sh`,
`linear.sh`, `verdict-handler.sh`, `scope-check.sh`, `classify-failure.sh`,
`guards.sh`, `poll.sh`, `reconcile.sh`, `run-local.sh`, `dry-run.sh`,
`run-release-observer.sh`, `run-retrospective-local.sh`, all `learned-rules/<slug>/*.md`,
and every other test sibling stay unchanged. Cost telemetry is observability;
it does not affect routing, scope partitioning, verdict markers, or label
transitions.

## Command API contract

No new command API. This is a bash harness; there is no Tauri / SvelteKit
surface in this repo. The only public-ish CLI changes are:

- `bash bin/metrics.sh <event> <issue> <stage> <outcome> <duration_ms> [notes…] [--tokens-in N --tokens-out N --cache-read N --cache-create N --cost-usd F --model S]`
  — the trailing flag pairs are new; the existing positional contract is
  unchanged. All current callers continue to work without modification (D-004).
- `bash bin/status.sh` — output gains a new `Cost summary (subscription proxy):`
  section between active-issues and last-events. No flag changes.
- `bin/dispatch.sh` — recognises the env var `PIPELINE_ISSUE_ID`. Unset is the
  no-op default; `run-stage.sh` is the only caller that sets it (D-012).

## Backend tasks

> All tasks operate on bash files only. Each task ends with running the
> repo's existing test sweep and verifying it still passes.

### Task 1: Extend `bin/metrics.sh` with explicit flag-pair parser
- `depends_on: []`
- `touches: bin/metrics.sh::main`

- [ ] In `bin/metrics.sh::main` (currently `:10-33`), replace `local notes="${*:-}"` (`:13`) with a flag-pair parser that consumes the six `--key value` pairs anywhere in the trailing args, and a `notes_parts` accumulator that absorbs the remaining non-flag tokens. Existing positional contract (event, issue, stage, outcome, duration_ms) stays at `:11`.
- [ ] In the `jq -cn` body at `:23-31`, conditionally extend the object literal so each of the six fields is only emitted when its corresponding flag was set. Use `jq`'s `(if ($v | length) > 0 then {k: ($v | tonumber)} else {} end)` form for numeric fields and the same shape with `$model` (string, no `tonumber`).
- [ ] Verify the legacy 7-key line shape on a no-flag call: `bash bin/metrics.sh stage-end ENG-T1 plan success 0 "branch=foo"` must produce a JSONL line with exactly `{ts, event, issue_id, stage, outcome, duration_ms, notes}` keys.
- [ ] Run `bash bin/metrics-test.sh` (Task 6) AND every existing `bash bin/*-test.sh` and `bash bin/dry-run.sh`; both must still pass.

```bash
# Skeleton — see brainstorm D-004 for the full code.
main() {
  local event="${1:-}" issue_id="${2:-}" stage="${3:-}" outcome="${4:-}" duration_ms="${5:-0}"
  shift 5 || true
  local tokens_in="" tokens_out="" cache_read="" cache_create="" cost_usd="" model=""
  local notes_parts=()
  while (( $# > 0 )); do
    case "$1" in
      --tokens-in)    tokens_in="$2";    shift 2 ;;
      --tokens-out)   tokens_out="$2";   shift 2 ;;
      --cache-read)   cache_read="$2";   shift 2 ;;
      --cache-create) cache_create="$2"; shift 2 ;;
      --cost-usd)     cost_usd="$2";     shift 2 ;;
      --model)        model="$2";        shift 2 ;;
      *)              notes_parts+=("$1"); shift ;;
    esac
  done
  local notes="${notes_parts[*]:-}"
  …
}
```

### Task 2: Add stream-json renderer + usage-file writer to `bin/dispatch.sh`
- `depends_on: []`
- `touches: bin/dispatch.sh::main, bin/dispatch.sh::_render_and_capture_stream`

- [ ] In `bin/dispatch.sh::main` AFTER `local tools=…` at `:60-61` and BEFORE the dry-run guard at `:66`, resolve `local USAGE_FILE=""`; if `${PIPELINE_ISSUE_ID:-}` is set, set `USAGE_FILE="$(issue_dir "$PIPELINE_ISSUE_ID")/usage-${stage}.json"` and `rm -f "$USAGE_FILE"`. (Inside `main` because `$stage` is local to `main`; cf. brainstorm §4.1, F-IT3-001.)
- [ ] Apply the same `rm -f "$USAGE_FILE"` to the dry-run branch (`:66-72`) so a stale file from a prior real run does not survive into a dry run (E-04).
- [ ] Modify `local cmd=(...)` at `:78` to append `--output-format stream-json --verbose`.
- [ ] Add a private helper `_render_and_capture_stream <usage_file> <issue_dir>` defined ABOVE `main` in the file (between `release_claude_mutex` at `:32-34` and `allowed_tools_for` at `:36`). Each bullet below is followed by the brainstorm-decision ID it implements (per scope-persona feedback — these are NOT implementer-discretion details, they are binding):
  - **[SEC-008]** Sets a `trap 'rm -f "$raw_capture"' RETURN` to clean up the intermediate NDJSON capture file under `$issue_dir/.raw-stream.ndjson.tmp`.
  - **[D-002 / F4]** Pipes its stdin through `tee "$raw_capture"` AND through a single `jq -nR --unbuffered` invocation (ONE fork — not per-line) that emits prose lines on stdout. Caught by the existing `tee "$log_file"` at `:82` (D-002 / F3).
  - **[D-002 / F2]** Silently drops malformed NDJSON via `fromjson? // empty` so a single bad line cannot abort dispatch.
  - **[SEC-010]** Strips C0 control chars (`gsub("[\\u0000-\\u001f]"; " ")`) from agent text before logging.
  - **[SEC-001]** Emits only event-type-derived prose: `[claude] session=…`, assistant text + `[tool] <name>`, `[tool-result] <id8>`. Does NOT log tool-use input bytes or anything else from the tool_use object beyond the name.
  - **[SEC-002 / D-003]** After the streaming pass, `grep '"type":"result"' "$raw_capture" | tail -1` extracts the final result event; if found, write the six required fields ONLY (no `session_id`, `permission_denials`, `result` text, `modelUsage` rollup, or provider metadata) to `$usage_file`.
  - **[SEC-005]** Wrap the write in a `(umask 077; … > "$usage_file")` subshell so the file is mode `0600` even on a default-022 host.
  - **[DL-201]** On success, log `[cost] result event captured: cost=$…` so `grep cost <log>` returns evidence.
  - **[D-010]** If no result event is found OR the post-stream `jq` parse fails, log `[cost] no result event found in stream (soft fail; usage-<stage>.json not written)`, `rm -f "$usage_file"` to clear any partial, return 0. NOT a stage failure.
- [ ] Modify the live-pipe at `:82` to insert the renderer between `cmd` and `tee`. The shape becomes:
  ```bash
  if [[ -n "$USAGE_FILE" && -n "${PIPELINE_ISSUE_ID:-}" ]]; then
    local issue_dir; issue_dir="$(issue_dir "$PIPELINE_ISSUE_ID")"
    "${cmd[@]}" < "$prompt_file" \
      | _render_and_capture_stream "$USAGE_FILE" "$issue_dir" \
      | tee "$log_file"
  else
    "${cmd[@]}" < "$prompt_file" | tee "$log_file"
  fi
  ```
  The fall-through (`USAGE_FILE` empty) keeps the four non-issue callers (release, retrospective, mutex-test, dry-run) on the unchanged code path.
- [ ] If `log_file` is empty (`:84-86` else branch), the renderer is bypassed too — those callers don't write usage files. Mirror the env-var guard.
- [ ] Verify the file mode of a successful write is `0600`: `stat -f '%p' "$usage_file"` ends in `0600`.
- [ ] Run `bash bin/dispatch-test.sh` (Task 5) AND `bash bin/dry-run.sh` AND `bash bin/mutex-test.sh`; all must still pass.

### Task 3: Wire cost-flag emission and footer in `bin/run-stage.sh`
- `depends_on: [1, 2]`
- `touches: bin/run-stage.sh::_cost_flags_for, bin/run-stage.sh::_cost_footer, bin/run-stage.sh::post_completion_comment, bin/run-stage.sh::main`

- [ ] Add private helper `_cost_flags_for <issue> <stage>` near the top of `bin/run-stage.sh`, alongside `_stage_artifacts_footer` (`:28-55`). The helper reads `$(issue_dir "$issue")/usage-${stage}.json`; if the file is missing or empty, returns 0 with no output. Otherwise emits ONE per line:
  ```
  --tokens-in
  <number>
  --tokens-out
  <number>
  --cache-read
  <number>
  --cache-create
  <number>
  --cost-usd
  <number>
  --model
  <string>
  ```
  via a single `jq -r` filter. Newline-delimited output is the contract for the caller's `mapfile` (DL-202 / SEC-007 — the model name `claude-opus-4-7[1m]` contains glob chars).
- [ ] Add private helper `_cost_footer <issue> <stage>` near `_cost_flags_for`. Reads the same usage file; if missing/empty, prints empty string and returns 0. Otherwise prints exactly:
  ```
  cost: $<cost_usd:%.2f> · in <tokens_in/1000:%.1fk> · out <tokens_out/1000:%.1fk>[ · cache <pct>%]
  ```
  Cache% formula: `cache_pct = round(100 * cache_read / max(1, cache_read + cache_create))` (D-007). When `cache_read + cache_create == 0`, OMIT the `· cache N%` segment (do NOT print `0%`). Format as a leading newline so the caller can append unconditionally.
- [ ] **Footer-format note (product-persona F1):** The brainstorm D-008 reformatted the issue body's literal `cost: $X · Yk in / Zk out · cache N%` to `cost: $X · in Yk · out Zk · cache N%`. Rationale (D-008): "`/` reads as division at a glance; `·` separators preserve visual rhythm." This deviation is intentional. If the operator who wrote the issue prefers the original wording, the format string is one line in `_cost_footer` and trivial to flip.
- [ ] In `post_completion_comment` (`:69-131`), insert the cost-footer call between the `body` block (`:99-106`) and the `comment_body` composition at `:122`. Specifically: compute `local cost_footer; cost_footer="$(_cost_footer "$issue" "$stage")"` after `body` is final, then change line `:122` from `printf '%s\n\n%s%s' "$header" "$body" "$pr_tail"` to `printf '%s\n\n%s%s%s' "$header" "$body" "$cost_footer" "$pr_tail"`. The fallback branch (`:119-120`) does NOT receive the footer (no usage to report on a fallback path; symmetric with `_stage_artifacts_footer`'s artifact-tail-only-on-fallback design).
- [ ] In `main` immediately before `bash "$SCRIPT_DIR/dispatch.sh" …` at `:276`, export `PIPELINE_ISSUE_ID="$ident"` so dispatch.sh can resolve the usage-file path (D-012). One-line addition.
- [ ] In the `else` branch of the `skip_dispatch` decision (currently `:283-285`), add `rm -f "$(issue_dir "$ident")/usage-${stage}.json"` BEFORE the `metrics.sh stage-start` call at `:284` (D-011). Replay metrics omit cost fields by construction.
- [ ] At each of the four cost-emit sites, replace the existing `metrics.sh stage-end` call with a portable `while IFS= read -r` accumulator (NOT `mapfile -t` — `mapfile` is a bash-4 builtin and macOS system bash is 3.2; A-23). Pattern:
  ```bash
  local cost_flags=()
  local _cf_line
  while IFS= read -r _cf_line; do
    cost_flags+=("$_cf_line")
  done < <(_cost_flags_for "$ident" "$stage")
  bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "<outcome>" \
    "$duration" "<existing notes>" "${cost_flags[@]+"${cost_flags[@]}"}"
  ```
  Sites: `:341` (scope-approval-pending), `:451` (success), `:467` (halt-for-human), `:471` (protocol-violation). The `${cost_flags[@]+"${cost_flags[@]}"}` expansion is the bash-3.2-safe form for "expand-if-set" under `set -u`; an empty array adds zero args, preserving the legacy positional shape when the file is absent. Quoting around `"$_cf_line"` and `"${cost_flags[@]+...}"` prevents glob expansion of `[1m]` in the model name (DL-202 / SEC-007).
- [ ] Do NOT touch the paused-path `metrics.sh stage-end` at `:226` — that path runs without invoking claude (verify_preconditions failed); no cost to report (D-005 table).
- [ ] Run `bash bin/run-stage-test.sh` (after Task 7's extensions) AND `bash bin/dry-run.sh`; both must still pass.

### Task 4: Add `show_cost_summary` + `_aggregate_cost_by_stage` to `bin/status.sh`
- `depends_on: [1]`
- `touches: bin/status.sh::show_cost_summary, bin/status.sh::_aggregate_cost_by_stage, bin/status.sh::main`

- [ ] Add `show_cost_summary` between `show_metrics` (currently `:144-169`) and `show_markers` (currently `:173-224`). The helper:
  - Prints `section "Cost summary (subscription proxy)"` (the parenthetical disambiguates from literal billing per E-02).
  - Reads `$PROJECT_STATE_DIR/metrics/events.jsonl`; if absent, prints `(no events.jsonl yet)` and returns 0.
  - Computes today / 7d / MTD sums of `cost_usd` over events with `event == "stage-end"` and a present `cost_usd` field. UTC boundaries (per D-007 — UTC stated in the section header).
  - Prints `today=$X.XX · 7d=$X.XX · MTD=$X.XX  (legacy events: M/N)` where `M` = stage-end events without `cost_usd` in the 7d window; `N` = total stage-end events in 7d.
  - Calls `_aggregate_cost_by_stage` to print the per-stage breakdown (right-aligned columns: stage, events, cost, in (k), out (k), cache%; sorted by cost desc; `--` for cache% when the cache_read+cache_create denominator is zero).
- [ ] Add `_aggregate_cost_by_stage` immediately above `show_cost_summary`. Reads the same `events.jsonl`, groups stage-end events by `.stage`, and emits one row per stage with `events, cost, tokens_in/1000, tokens_out/1000, cache_pct`. Implementation is `jq -s` over the file with a `group_by(.stage)` reducer; cache_pct uses the formula from D-007.
- [ ] In `main` at `:228-235`, insert `show_cost_summary || true` between `show_active_issues || true` (`:231`) and `show_metrics || true` (`:232`).
- [ ] Verify the breakdown handles zero events (no stage-end events present): cost summary line prints zeros, breakdown prints `(no stage-end events with cost data)` and returns 0.
- [ ] Verify with a temp-dir `events.jsonl` containing two stage-end lines (one cost-bearing, one legacy) that the legacy counter `M/N` reports `1/2`.
- [ ] Run `bash bin/dry-run.sh`; it must still pass. (No bin/status-test.sh in v1; manual verification per brainstorm §4.2.)

### Task 5: Create `bin/dispatch-test.sh`
- `depends_on: [2]`
- `touches: bin/dispatch-test.sh`

- [ ] Create `bin/dispatch-test.sh` following the convention from `bin/run-stage-test.sh:1-80`: `set -euo pipefail`, `STUB_DIR="$(mktemp -d)"`, `export PIPELINE_DRY_RUN=0` (the renderer is exercised in real-mode), stub `claude` as a script that `cat`s an inline NDJSON fixture, override `HARNESS_STATE_DIR` and `PROJECT_STATE_DIR` and `PROJECT_SLUG` AFTER sourcing, source `bin/dispatch.sh` to expose `_render_and_capture_stream`, run inline assertions.
- [ ] Fixture A — success path. Inline a heredoc NDJSON of: one `system` init event, one `assistant` text event, one `assistant` tool_use event, one `user` tool_result event, one final `result` event with the verified A-04 shape. Pipe through `_render_and_capture_stream "$usage_file" "$issue_dir"`. Assert:
  - The function's stdout contains a `[claude] session=` line, an assistant text line, a `[tool]` line, a `[tool-result]` line.
  - `$usage_file` exists, has mode `0600` (`stat -f '%A' "$usage_file"` returns `600` on macOS), and contains exactly the six keys: `tokens_in`, `tokens_out`, `cache_read`, `cache_create`, `cost_usd`, `model`. No `session_id`, no `permission_denials`, no `result`, no `modelUsage`. Use `jq -r 'keys | length'` and `jq -r 'has("session_id")' == "false"`.
  - The intermediate `.raw-stream.ndjson.tmp` is gone (RETURN trap).
- [ ] Fixture B — no-result path. NDJSON ends mid-stream (no `type:"result"` event). Pipe through. Assert: `$usage_file` does NOT exist; the log captured `[cost] no result event found in stream`.
- [ ] Fixture C — malformed-line tolerance. Insert a literal garbage line (`{not json{`) between two valid events that include a final result event. Pipe through. Assert: `$usage_file` exists with the six fields (the garbage was silently dropped by `fromjson?`).
- [ ] Fixture D — log-forge defense. The fixture's assistant text contains an embedded `\r[FAKE LOG] root pwned` byte sequence. Pipe through. Assert: the renderer's stdout does NOT contain a literal `\r`; the C0 stripping replaced it with a space (or removed) before reaching stdout.
- [ ] Fixture E — dry-run stale-file removal. Pre-create a `usage-<stage>.json` with known content; set `PIPELINE_DRY_RUN=1` and `PIPELINE_ISSUE_ID="$ident"`; invoke `bash bin/dispatch.sh <stage> <prompt_file>` (which short-circuits at `:66` per D-006). Assert: the pre-existing file is gone, no new file written, no NDJSON consumed (no claude binary needed since the dry-run guard returns before `acquire_claude_mutex`/the live pipe).
- [ ] All five fixtures must complete in <2s wall-time on a non-loaded macOS host (a smoke check that the single-jq-fork constraint F4 holds).

### Task 6: Create `bin/metrics-test.sh`
- `depends_on: [1]`
- `touches: bin/metrics-test.sh`

- [ ] Create `bin/metrics-test.sh` following the same `STUB_DIR` + post-source-override pattern. Override `PROJECT_STATE_DIR="$(mktemp -d)"`, `mkdir -p "$PROJECT_STATE_DIR/metrics"`. Source `bin/common.sh` then exec the metrics.sh `main` function via `bash bin/metrics.sh stage-end …`.
- [ ] Case A — no flags. `bash bin/metrics.sh stage-end ENG-T1 plan success 100 "branch=foo"` produces a JSONL line with exactly `{ts, event, issue_id, stage, outcome, duration_ms, notes}` keys (7). Assert via `jq -r 'keys | length' = 7` and `jq -r '.notes' = "branch=foo"`.
- [ ] Case B — all six flags. `bash bin/metrics.sh stage-end ENG-T2 plan success 100 "branch=foo" --tokens-in 5 --tokens-out 6 --cache-read 20773 --cache-create 17419 --cost-usd 0.119 --model claude-opus-4-7[1m]` produces a 13-key line; numeric fields are typed numbers (`jq 'type' == "number"`), `model` is the literal string with the `[1m]` glob bytes preserved.
- [ ] Case C — flags before notes. `… stage-end ENG-T3 plan success 100 --cost-usd 0.42 --tokens-in 500 "branch=foo"` — assert `notes == "branch=foo"` AND `cost_usd == 0.42` AND `tokens_in == 500`. The flag parser must consume the flag pairs anywhere in the trailing args.
- [ ] Case D — notes-only stage-start (legacy callers): `… stage-start ENG-T4 plan dispatching 0` produces a 7-key line with empty `.notes`; no cost fields (the flag parser left `tokens_in` etc. empty so the `jq -cn` body omits them).
- [ ] Case E — partial flags. `… stage-end ENG-T5 plan success 100 --cost-usd 0.42` produces a line with `cost_usd` ONLY (8 keys total); the other five cost fields are ABSENT (not `null`, not `0`). Assert via `jq -r 'has("tokens_in")' == "false"`.
- [ ] All five cases produce one JSONL line each via append to the temp `events.jsonl`; the test asserts line count, key-count, and field values for each.

### Task 7: Extend `bin/run-stage-test.sh` with cost-flag propagation cases
- `depends_on: [3]`
- `touches: bin/run-stage-test.sh`

- [ ] Add a `metrics.sh` capture stub to `STUB_DIR` (the existing test currently relies on `bash "$STUB_DIR/metrics.sh"`-style replacements via the existing per-stub pattern at `:561-565`). Mirror it: capture every metrics.sh invocation with all args to `$STUB_DIR/metrics.capture`.
- [ ] Case A — `usage-<stage>.json` present. Write a six-field JSON file to `$(issue_dir "ENG-T-COST")/usage-plan.json` with known values; invoke the success-path metrics emit (or call `_cost_flags_for` directly via `mapfile` and inspect the array). Assert the captured metrics call args include `--cost-usd 0.42 --tokens-in 5 …` and the `--model claude-opus-4-7[1m]` value is preserved verbatim (no glob expansion inside the bash array).
- [ ] Case B — usage file absent. Invoke the same metrics emit; assert the captured args include only the existing positional args + notes (no `--`-prefixed flags).
- [ ] Case C — D-011 stale-file removal. Pre-create a `usage-<stage>.json` with cost data. Trigger the `skip_dispatch=1` code path (set `MOCK_SCOPE_RC=0` and pre-populate `$(issue_dir)/scope-approval` so the existing scope-approval test fixtures fire). Assert the file is gone after the helper runs and the resulting metrics call has NO cost flags.
- [ ] Case D — `_cost_footer` shape. Pin fixture values upfront: `cost_usd=0.42, tokens_in=18000, tokens_out=4000, cache_read=20773, cache_create=17419, model="claude-opus-4-7[1m]"`. Call `_cost_footer ENG-T-COST plan` directly; assert stdout matches the literal `cost: $0.42 · in 18.0k · out 4.0k · cache 54%`. (Cache% computation: `100 * 20773 / (20773 + 17419) = 54.39…` → rounds to 54.)
- [ ] Case E — cache-zero footer omission. Set both `cache_read=0` and `cache_create=0`; assert stdout matches `^cost: \$.+ · in .+ · out .+$` (no trailing `· cache` segment).
- [ ] All cases use the existing `pass_at`/`fail_at` style; one line per case in the existing TEST_PHASE accumulator.

## Frontend tasks

No frontend tasks. This is a bash harness; there is no UI surface in this
repo. The Linear-comment footer is rendered by `bin/run-stage.sh` (already
covered by Task 3); the status-line UI is the terminal output of
`bin/status.sh` (already covered by Task 4).

## Failure mode → test map

Every row from the brainstorm's §6 (Error handling) and §7 (Edge cases) is
bound to a concrete test layer + test name below. QA generates / verifies
tests against this exact mapping.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `claude` exits nonzero mid-stream | dispatch returns non-zero through pipefail | Existing exit-20 path unchanged; renderer's `fromjson? // empty` tolerates partial NDJSON | unit | `bin/dispatch-test.sh::Fixture B (no-result)` |
| Stream contains no `result` event | NDJSON ends mid-stream | Renderer logs warning, writes no usage file; soft fail (D-010) | unit | `bin/dispatch-test.sh::Fixture B (no-result)` |
| Stream contains malformed NDJSON line | inline `{not json{` between valid events | Renderer drops the line silently (`fromjson? // empty`); valid result still extracted | unit | `bin/dispatch-test.sh::Fixture C (malformed-line tolerance)` |
| Tool-use input bytes leak into log | assistant tool_use event with `input` payload | Renderer emits `[tool] <name>` only — never the `input` field bytes (SEC-001) | unit | `bin/dispatch-test.sh::Fixture A (success path)` — assert no `input` substring in renderer stdout |
| ANSI / CR log forging in agent text | assistant text contains `\r[FAKE LOG]…` | C0 control-char `gsub` strips before logging (SEC-010) | unit | `bin/dispatch-test.sh::Fixture D (log-forge defense)` |
| Verbatim result event leaks `session_id` / final assistant text | success path produces full `result` event | usage file holds exactly six fields — no `session_id`, no `result` text, no `modelUsage` rollup (SEC-002) | unit | `bin/dispatch-test.sh::Fixture A (success path)` — assert `has("session_id") == false` |
| Usage file world-readable on default-022 host | renderer writes file under default umask | `(umask 077; …)` subshell forces mode `0600` (SEC-005) | unit | `bin/dispatch-test.sh::Fixture A (success path)` — assert `stat -f '%A' = "600"` |
| `usage-<stage>.json` exists but jq parse fails | malformed JSON written by a hypothetical previous run | `_cost_flags_for` returns empty; metrics omit cost flags | integration | `bin/run-stage-test.sh::Case B (usage file absent)` — extended to cover malformed file |
| Concurrent dispatch on same issue (mutex held) | two ticks for same issue | Cross-project `acquire_claude_mutex` at `bin/dispatch.sh:14-30` already serialises | integration | `bin/mutex-test.sh` (existing — verify still passes) |
| Stale `usage-<stage>.json` on dry-run after real dispatch | prior real run wrote file; current run is `PIPELINE_DRY_RUN=1` | `dispatch.sh` `rm -f` at function entry on dry-run branch | unit | `bin/dispatch-test.sh::Fixture E (dry-run stale-file removal)` |
| Stale `usage-<stage>.json` on scope-approval replay | `skip_dispatch=1` with an earlier real-run usage file | `run-stage.sh` `rm -f` at the `else` branch before `:284` (D-011) | integration | `bin/run-stage-test.sh::Case C (D-011 stale-file removal)` |
| Cache% denominator is zero | `cache_read + cache_create == 0` | Footer omits `· cache N%` segment; status.sh per-stage table renders `--` | unit + integration | `bin/run-stage-test.sh::Case E (cache-zero footer omission)` AND status.sh manual verification |
| Model name contains glob chars | `claude-opus-4-7[1m]` | `mapfile -t` array preserves verbatim across function boundary; no glob expansion (DL-202 / SEC-007) | integration | `bin/run-stage-test.sh::Case A (usage file present)` — assert `--model claude-opus-4-7[1m]` literal in capture |
| status.sh asked for cost summary before any cost-tagged event exists | empty events.jsonl | Section prints `today=$0.00 · 7d=$0.00 · MTD=$0.00 (legacy events: 0/0)` | manual smoke | `bin/status.sh` invoked against tempdir `events.jsonl` |
| Legacy events present without cost fields | events.jsonl mixed with pre-feature lines | Per-stage breakdown still aggregates cost-bearing ones; `legacy events: M/N` counter tracks ratio | manual smoke | `bin/status.sh` invoked against tempdir with mixed line types |
| `metrics.sh` called without flags (legacy callers) | `bash bin/metrics.sh stage-end ENG-T1 plan success 100 "branch=foo"` | Existing 7-key JSONL line shape preserved (no `null`s, no `0`s for cost fields) | unit | `bin/metrics-test.sh::Case A (no flags)` |
| `metrics.sh` called with flags before notes | `… --cost-usd 0.42 "branch=foo"` | Parser cleanly separates flags from notes; both fields land correctly | unit | `bin/metrics-test.sh::Case C (flags before notes)` |
| `metrics.sh` called with partial flags | `… --cost-usd 0.42` only | Only `cost_usd` field emitted; other five ABSENT (not `null`, not `0`) | unit | `bin/metrics-test.sh::Case E (partial flags)` |
| `dispatch.sh` invoked without `PIPELINE_ISSUE_ID` (release / retrospective / mutex-test / dry-run) | env var unset | `USAGE_FILE` empty; renderer block skipped; existing pipe shape unchanged | integration | `bin/mutex-test.sh` AND `bin/dry-run.sh::dispatch.sh: dry-run prints prompt preview` (existing — verify still pass) |

## Test strategy

- **Unit (new): `bin/dispatch-test.sh`** — Drives `_render_and_capture_stream` with five fixtures (A success, B no-result, C malformed-line, D log-forge, E dry-run stale-file removal). Asserts six-field shape, no-leak, mode 0600, soft-fail on no-result, malformed-line tolerance, log-forge defense, dry-run-removes-stale-file.
- **Unit (new): `bin/metrics-test.sh`** — Exercises five flag-pair cases (no flags, all six flags, flags before notes, legacy stage-start, partial flags). Asserts JSONL key counts and field values.
- **Integration (extended): `bin/run-stage-test.sh`** — Five new cases (cost flags propagate, do-not-propagate, D-011 stale-file removal, _cost_footer shape, cache-zero footer omission). Hooks the existing capture-file pattern at `:561-565` and a new `metrics.sh` capture stub.
- **Integration (existing — must still pass): `bin/mutex-test.sh`** — Verifies dispatch.sh's mutex semantics survive the new env-var path and renderer.
- **Smoke (existing — must still pass): `bin/dry-run.sh`** — Verifies all 9 stages have allowed-tools profiles AND dispatch.sh dry-run prints prompt preview without firing the renderer.
- **Manual smoke**: `bash bin/status.sh` against a tempdir `events.jsonl` populated with mixed cost-bearing and legacy lines; verify the `Cost summary (subscription proxy)` section renders, `today/7d/MTD` math is correct, the per-stage breakdown sorts by cost desc, cache% column shows `--` when denominator is zero, and `legacy events: M/N` counter reports correctly.
- **Adversarial (no new file)**: the existing `bin/halt-sprawl-adversarial-test.sh` and `bin/run-local-helpers-adversarial-test.sh` remain unchanged — cost telemetry does not affect halt sprawl or sweep partitioning. Their continued green state is the regression check.
- **Order of landing (per A-19, single PR)**: metrics.sh first (parser is backward-compat); dispatch.sh second (writes usage file but no caller reads it yet); run-stage.sh third (reads usage file + writes footer); status.sh fourth (read-only aggregation); test files alongside their respective producers. Each landing point leaves the system functional; bisect-friendly within the PR.

## Persona review

This section records the verdicts and findings of each `compound-engineering:document-review` persona run against this plan. Each iteration ends with a gate decision (≥4/5 PASS AND zero P0 findings).

### Iteration 1

| Persona | PASS / FAIL | Highest-severity finding (resolution) |
|---|---|---|
| feasibility | **PASS** (P2 only) | F1.P2: `mapfile` is bash 4+; macOS system bash is 3.2 (`bash --version` returns 3.2.57; no existing harness script uses `mapfile`/`readarray`). RESOLVED: Task 3 reworded to use the portable `while IFS= read -r` accumulator pattern with `${cost_flags[@]+"${cost_flags[@]}"}` empty-array-safe expansion. New A-23 added documenting the bash-version constraint. F4.P2: Fixture B (real-mode no-result) cannot exercise the dry-run-branch `rm -f`. RESOLVED: added Fixture E (dry-run stale-file removal) to Task 5 explicitly setting `PIPELINE_DRY_RUN=1`. F2.P3 / F3.P3: line-range cosmetics (A-03, A-07). RESOLVED: A-03 split into body / constants ranges; A-07 corrected `:77-87` → `:77-88`. |
| scope | **PASS** (P2 only) | Renderer prescriptiveness in Task 2 exceeds brainstorm §4.4's "illustrative-but-binding on three points" disclaimer. RESOLVED: each prescriptive bullet in Task 2 now carries the brainstorm decision ID (SEC-001 / SEC-002 / SEC-005 / SEC-008 / SEC-010 / DL-201 / D-002 / D-003 / D-010 / F2 / F3 / F4) that elevates it from implementer-discretion to binding contract. |
| coherence | **PASS** (no findings) | All 12 brainstorm decisions (D-001..D-012) are realised by the seven tasks; the failure-mode → test map names tests that the test-strategy section actually creates; cross-task `depends_on` edges are sound and acyclic; no terminology drift. |
| design | **PASS** (P2/P3 only) | P2: footer format consistency vs `_stage_artifacts_footer` not justified (the artifacts footer uses bullet-list shape, the cost footer uses inline middot). ADVISORY: cost is single-line by D-008 design (one footer line per Linear comment); artifacts footer is list-shaped because it enumerates files. The two are stylistically different on purpose; no fix. P2: legacy/dry-run/replay interaction states under-specified for the status table. RESOLVED inline: Task 4 already specifies `legacy events: M/N` counter and `--` rendering when cache denominator is zero; the three-state distinction (no events vs all-legacy vs mixed) is operationally equivalent in v1 (operator reads `M/N` to disambiguate). P3 advisories on assumption-inventory ceremony and section-ordering rationale accepted as-is — the inventory is a hard requirement of the plan template, and `show_cost_summary` placement (above `show_metrics`) puts the time-horizon rollup first per D-007's status-section header rule. |
| product | **PASS** (P2 only) | F1.P2: footer format reorders the issue body's literal `Yk in / Zk out` to `in Yk · out Zk`. RESOLVED: Task 3 now carries an explicit footer-format note citing D-008's rationale and a one-line revert path if the operator prefers the original wording. F2.P2: `cost-by-stage` is a private helper, not a callable CLI sub-command. ACCEPTED per D-007 (rejected alternative — scope-guardian explicitly demoted CLI sub-command in iteration 2 of the brainstorm); the issue body's "aggregation function" wording is satisfied by the helper that produces the per-stage breakdown inside `bash bin/status.sh`. |

### Final gate

- Iteration 1: **5/5 PASS, 0 P0**. Gate threshold (≥4/5 PASS AND zero P0) MET.
- No iteration 2 required.
