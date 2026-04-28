---
linear: ENG-26
title: Track tokens, cost, and cache stats per stage
date: 2026-04-27
status: gate-passed
---

# Track tokens, cost, and cache stats per stage

## 1. Goal

Capture per-stage token counts (input, output, `cache_creation`, `cache_read`),
USD cost, and the model name from each `claude -p` invocation, persist them to
`metrics/events.jsonl`, and surface stage-grain summaries in `bin/status.sh`
and the per-stage Linear comment footer.

The single observable outcome: an operator looking at status.sh or a Linear
issue can see how much each stage cost and how cache-warm it ran. That's it
in v1. Per-tool / per-MCP cost attribution, week-over-week trend deltas, and
per-issue cost rollups are deliberately NOT in v1 (see §2 non-goals and §3
D-009). Stage-grain visibility is a **directional** indicator: it tells the
operator which stages are expensive, not why one tool earned its keep.
Higher-resolution attribution is a separate ticket once stage-grain numbers
have been on the dashboard for a few weeks and we know which questions
operators actually ask.

## 2. Non-goals (deferred — fixed in scope)

Confirmed in the Linear issue body and re-stated here:

- Budget alerts, kill switches, per-issue cost caps.
- Cost-aware stage skipping or model fallback.
- Backfill of historical events (events before this lands stay null).
- Retrospective input from cost data — the retrospective agent should
  not read the new fields until we have weeks of data and a separate
  ticket defines how it should weigh them.
- Per-tool / per-MCP / per-sub-agent attribution. `total_cost_usd` and the
  top-level `usage` block already aggregate sub-agent calls; we use that
  rollup and do not split it. Browser-MCP-vs-no-MCP ROI questions are an
  explicit v2 concern; v1 captures stage-grain only.
- Week-over-week deltas, outlier flags, per-issue rollups, dashboard tables
  with totals rows. v1 prints absolute totals (today / 7d / MTD) and per-stage
  breakdown; that is the data layer that future tickets can build trend
  surfaces on.
- Forward-compat schema speculation. We do NOT speculate by adding a
  `tools_invoked` array "in case the retrospective wants it later" — we
  add fields when we have a confirmed consumer for them.

## 3. Decisions

Each decision references the load-bearing constraints from `CLAUDE.md` (the
de-facto architecture doc — the prompt-template's `docs/VISION.md` and
`docs/architecture/SYSTEM_ARCHITECTURE.md` do not exist in this repo; see
A-01).

### D-001 — Capture mechanism: `claude -p --output-format stream-json --verbose`

Add `--output-format stream-json --verbose` to the `cmd` array in
`dispatch.sh::main` (`bin/dispatch.sh:78`). The CLI emits one NDJSON event
per assistant/tool/result message; the final
`{"type":"result", …}` event carries the aggregate `usage` block,
`total_cost_usd`, and `modelUsage` keyed by model name (verified — see A-04).

**Constraint reference.** CLAUDE.md "When wiring a new script" puts every
`claude -p` invocation through `bin/dispatch.sh::allowed_tools_for`, making
`dispatch.sh` the single chokepoint. Cost telemetry inherits to every consumer
(run-stage, retrospective, future direct callers).

**Verified field shapes (A-04, no longer assumed).** A captured result event
from `claude -p --output-format stream-json --verbose` (run during this
brainstorm; full payload archived next to A-04) contains:

```jsonc
{ "type": "result",
  "total_cost_usd": 0.11943025,
  "usage": { "input_tokens": 5, "output_tokens": 6,
             "cache_creation_input_tokens": 17419,
             "cache_read_input_tokens": 20773, … },
  "modelUsage": { "claude-opus-4-7[1m]": { "inputTokens": 5, … } },
  "session_id": "a97ddba2-…", "permission_denials": [],
  "result": "<assistant final message text — sensitive>" }
```

Two implications: (1) the **model name** lives in `modelUsage` as an object
KEY, not as a top-level `model` field — extraction is
`jq -r '.modelUsage | keys | .[0]'`. (2) The `result` event also carries
`session_id`, `permission_denials`, and the literal final assistant message
under `.result`. Persisting the verbatim event leaks the latter; D-003
addresses this by extracting only the six required fields.

**Rejected alternative.** `--output-format json` (single result document
emitted at end). Rejected because it buffers ALL agent output until the
agent exits; the existing `tee "$log_file"` (`bin/dispatch.sh:82`) would
sit silent for the full ~10-minute stage, breaking CLAUDE.md "tick is
silent" diagnostic signal. Stream-json preserves live progress.

**Rejected alternative.** Inferring usage from claude exit signals or
screen-scraping prose output. The exit signal carries no usage; scraping
the human-readable text format is brittle to format changes — the class
of brittleness rule B-001 was written to prevent.

### D-002 — Stream-json renderer: single jq filter, prose to STDOUT, defensive on malformed lines

A new helper `_render_and_capture_stream` inside `dispatch.sh` reads NDJSON
on stdin and emits prose-ish lines on **STDOUT** (so `tee "$log_file"`
captures them; F3 P0 from feasibility iteration 1). The captured final
`result` event is extracted, the six fields are pulled out, and only those
six fields are written to `$usage_file` (F0 from SEC-002 — no verbatim
event capture).

The renderer uses **one jq invocation** for prose (not per-line forks; F4 P0)
plus a single grep+jq pass for the result event after the stream ends. The
control flow uses a `tee` split — raw NDJSON is mirrored to a private
capture file under `$issue_dir`, while jq extracts prose lines to stdout.
No control-character sentinels, no awk routing — those proved error-prone
in iteration 1 (the prior SOH-byte awk approach had a literal-vs-escape
mismatch flagged by iteration-2 coherence as F-C001).

```bash
# Args: $1 = usage_file, $2 = issue_dir.
_render_and_capture_stream() {
  local usage_file="$1" issue_dir="$2"
  local raw_capture="${issue_dir}/.raw-stream.ndjson.tmp"
  trap 'rm -f "$raw_capture"' RETURN

  # tee mirrors raw NDJSON to capture file under $issue_dir (per-issue state
  # tree, NOT /tmp — file briefly contains the verbatim result event with
  # session_id + final assistant text; SEC-008). jq -nR consumes the same
  # bytes via `inputs` and emits prose lines on stdout. Single jq fork for
  # the whole stream (F4 P0). `fromjson? // empty` drops malformed lines
  # silently (F2 P0). The strip_ctrl helper removes C0 control chars from
  # agent text so log forging via CR/ANSI cannot corrupt the transcript
  # (SEC-010).
  tee "$raw_capture" \
    | jq -nR --unbuffered '
        def strip_ctrl: gsub("[\\u0000-\\u001f]"; " ");
        inputs
        | (fromjson? // empty) as $e
        | if   $e.type == "system" and $e.subtype == "init"
                 then "[claude] session=\($e.session_id[0:8]) model=\($e.model // "?")"
          elif $e.type == "assistant"
                 then (([$e.message.content[]? | select(.type=="text")    | .text  | strip_ctrl] | join(" "))
                      + ([$e.message.content[]? | select(.type=="tool_use") | "[tool] " + .name] | join(" ")))
          elif $e.type == "user"
                 then ([$e.message.content[]? | select(.type=="tool_result") | "[tool-result] " + ((.tool_use_id // "?")[0:12])] | join(" "))
          else empty
          end
        | select(. != "")
      '
  # tee + jq exit when stdin (claude) closes. Prose half (above) and the
  # result-extract half (below) are decoupled — no mid-stream sentinel
  # routing. The whole raw stream now sits in $raw_capture.

  # Post-stream: extract the six required fields ONLY from the LAST
  # type==result line. Allowlist by construction (SEC-002 — never write the
  # verbatim result event). The umask subshell ensures the final file is
  # mode 0600 even on a default-022 host (SEC-005).
  local last_result
  last_result="$(grep '"type":"result"' "$raw_capture" 2>/dev/null | tail -1)"
  if [[ -n "$last_result" ]]; then
    (
      umask 077
      printf '%s' "$last_result" | jq -c '{
        tokens_in:     (.usage.input_tokens // 0),
        tokens_out:    (.usage.output_tokens // 0),
        cache_read:    (.usage.cache_read_input_tokens // 0),
        cache_create:  (.usage.cache_creation_input_tokens // 0),
        cost_usd:      (.total_cost_usd // 0),
        model:         (.modelUsage | keys | .[0] // "")
      }' > "$usage_file"
    )
    log "[cost] result event captured: cost=$(jq -r '.cost_usd' "$usage_file" 2>/dev/null)"
  else
    log "[cost] no result event found in stream (soft fail; usage-<stage>.json not written)"
  fi
}
```

Notes that pin the F1–F4 (iteration 1) and F-C001 / SEC-008 / SEC-010 /
DL-201 (iteration 2) fixes:

- **F2 — error handling.** `fromjson? // empty` drops malformed lines
  silently. `jq` does NOT exit on a single malformed line in `inputs`
  mode. The renderer is tolerant by construction; one malformed line
  cannot abort dispatch.
- **F3 — stdout, not stderr.** Prose lines flow on stdout into the
  existing `tee "$log_file"` at `bin/dispatch.sh:82`. The raw NDJSON
  is mirrored to `$raw_capture` via the up-pipe `tee`; the result
  event is extracted from there post-stream. Iteration 1's
  earlier-draft awk-sentinel routing is gone.
- **F4 — bounded jq forks.** Two jq processes per stage (one
  streaming for prose, one one-shot for the result extract), not
  per-line. Sub-second extra time inside the cross-project claude
  mutex.
- **F-C001 (iteration-2 coherence) — sentinel mismatch eliminated.**
  The earlier-draft `\x01RESULT\x01` awk-routed approach had a
  literal-vs-escape mismatch between jq output and awk pattern.
  Replaced by a `tee`-split that needs no sentinel: the raw stream
  goes to a capture file, the prose stream goes to stdout, two
  pipelines, one direction each. No SOH bytes ever appear.
- **SEC-008 (iteration-2 security) — intermediate file under
  `$issue_dir`.** Not `/tmp`. The per-issue state tree is the
  appropriate trust scope; the leading `.` keeps the file invisible
  to artifact scanners; the `RETURN` trap removes it on function
  exit.
- **SEC-010 (iteration-2 security) — log forging defense.** The
  `strip_ctrl` jq function neutralizes ANSI escapes and `\r` log
  forging on agent text before it reaches the log file.
- **DL-201 (iteration-2 design) — silent-on-success removed.** On a
  successful stream the renderer logs
  `[cost] result event captured: cost=$X.XX`, so
  `grep cost <log>` returns evidence. The earlier draft only logged
  on failure.
- **Tool-use input bytes are not logged (SEC-001).** The renderer
  emits `[tool] <name>` only — never the `input` field's bytes.

**Constraint reference.** CLAUDE.md "Failure-mode quick reference" treats
the per-stage transcript at `$PROJECT_STATE_DIR/logs/<issue>-<stage>-<ts>.log`
as a primary diagnostic. The renderer preserves prose-on-disk readability
while adding structured exit telemetry.

**Rejected alternative.** Tee raw NDJSON to the log and let humans read JSON.
Rejected: a 600-line stage log of pretty-printed JSON is unreviewable in an
emergency; JSON-on-disk does not interoperate with existing `grep` /
`tail -f` muscle memory.

**Rejected alternative.** Two `claude -p` invocations — one with `text`,
one with `json`. Rejected: doubles subscription burn and breaks the
single-acquire claude-mutex contract at `bin/dispatch.sh:14`.

### D-003 — Usage file at `$issue_dir/usage-<stage>.json` — six fields only

After the stream completes, `dispatch.sh` writes a six-field JSON object to
`$issue_dir/usage-<stage>.json` (`bin/common.sh:61` resolves
`issue_dir`). The file shape is exactly:

```json
{ "tokens_in": 5, "tokens_out": 6, "cache_read": 20773,
  "cache_create": 17419, "cost_usd": 0.11943025,
  "model": "claude-opus-4-7[1m]" }
```

Six fields. No `session_id`, no `result` text, no `permission_denials`, no
`modelUsage` rollup, no provider metadata. SEC-002's "verbatim event leaks"
class is closed by construction.

**File hygiene.** `dispatch.sh` runs `rm -f "$usage_file"` at function
entry — both real and dry-run branches — so a missing file is the
canonical "no usage to report" signal (E-04). The file is written via
`(umask 077; jq … > "$usage_file")` so a default-022 umask doesn't make
it world-readable on a multi-user macOS host (SEC-005).

**Constraint reference.** Per-issue scratch already lives at
`$PROJECT_STATE_DIR/<issue>/` per CLAUDE.md "Per-issue state directory".
One more sibling file alongside `scope-approval`, `issue-state.json`,
`stage-summary-<stage>.md` matches the existing pattern.

### D-004 — `metrics.sh` schema: explicit flag parser, six new optional fields

Extend `bin/metrics.sh::main` to recognize trailing `--key value` flag
pairs **before** computing `notes`. The existing positional contract
(event, issue, stage, outcome, duration_ms, [notes…]) is preserved for
backward compatibility with all current callers.

```bash
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
  jq -cn \
    --arg ts "$iso_ts" --arg event "$event" --arg issue_id "$issue_id" \
    --arg stage "$stage" --arg outcome "$outcome" \
    --argjson duration_ms "$duration_ms" --arg notes "$notes" \
    --arg tokens_in "$tokens_in" --arg tokens_out "$tokens_out" \
    --arg cache_read "$cache_read" --arg cache_create "$cache_create" \
    --arg cost_usd "$cost_usd" --arg model "$model" '
      {ts:$ts, event:$event, issue_id:$issue_id, stage:$stage,
       outcome:$outcome, duration_ms:$duration_ms, notes:$notes}
      + (if ($tokens_in    | length) > 0 then {tokens_in:    ($tokens_in    | tonumber)} else {} end)
      + (if ($tokens_out   | length) > 0 then {tokens_out:   ($tokens_out   | tonumber)} else {} end)
      + (if ($cache_read   | length) > 0 then {cache_read:   ($cache_read   | tonumber)} else {} end)
      + (if ($cache_create | length) > 0 then {cache_create: ($cache_create | tonumber)} else {} end)
      + (if ($cost_usd     | length) > 0 then {cost_usd:     ($cost_usd     | tonumber)} else {} end)
      + (if ($model        | length) > 0 then {model:        $model}        else {} end)
    ' >> "$jsonl_file"
}
```

Resolves F1 (P0): existing callers pass non-`--` strings, which fall through
to `notes_parts`; new callers prepend or append flag pairs and the parser
cleanly separates them. Resolves F-002 (P1 coherence): when a flag is
unset, the field is OMITTED from the JSONL line entirely — not `null`,
not `0`. Read-side `// 0` defaults are a separate concern (consumers of
the JSONL apply `// 0` for legacy lines; the writer never emits zero).

Cost flags are accepted on any event verb. Callers SHOULD only pass them
on `stage-end` events; passing them on `stage-start` is harmless but
nonsensical (no claude has been invoked yet).

**Constraint reference.** CLAUDE.md "When wiring a new script" — metric
writes go through `bin/metrics.sh`. Schema additions must be backward
compatible because `events.jsonl` is append-only and the retrospective
reads historical events. Optional-field semantics (`absent` rather than
`null`) preserve legacy-event readability.

**Rejected alternative.** Move `notes` to `--notes STRING` and update
existing callers. Rejected: forces a coordinated change across
`run-stage.sh:227`, `:343`, `:451`, `:467`, `:471` and `run-local.sh:189`,
`:201` for no semantic benefit. The flag-pair-after-positional approach
keeps the diff localized to `bin/metrics.sh` plus the cost-emit sites in
`run-stage.sh`.

**Rejected alternative.** A separate `cost-events.jsonl` file. Rejected:
correlating cost with stage-end requires re-keying on `(issue, stage, ts)`
which one event line already gives us. Two files double I/O and double
the chance of partial-write divergence.

### D-005 — Where parsing lives: dispatch writes, run-stage reads

`dispatch.sh` writes the six-field `usage-<stage>.json` (D-003).
`run-stage.sh` reads it once at metrics-emit time and passes the six
flags via the parser added in D-004. The cost-emit sites in
`run-stage.sh` are exactly the four `metrics.sh stage-end` calls where
claude actually ran:

| Site | Path | Cost flags? |
|---|---|---|
| `bin/run-stage.sh:226` (paused) | claude not called | NO |
| `bin/run-stage.sh:341` (scope-approval-pending) | claude ran | **YES** |
| `bin/run-stage.sh:451` (success) | claude ran | **YES** |
| `bin/run-stage.sh:467` (halt-for-human) | claude ran | **YES** |
| `bin/run-stage.sh:471` (protocol-violation) | claude ran | **YES** |
| `bin/run-local.sh:189` (reconcile-link `outcome=linked`) | claude not called | NO |
| `bin/run-local.sh:196` (reconcile-human stage-start) | start event, no usage by definition | NO |
| `bin/run-local.sh:201` (reconcile-human stage-end) | claude not called | NO |

The flags-emit happens via a small helper inside `run-stage.sh`:

```bash
# Reads $issue_dir/usage-<stage>.json and emits each metrics.sh flag as
# its own line on stdout. Caller uses `mapfile`/`readarray` to slurp
# into a bash array and passes "${cost_flags[@]}" quoted — no word
# splitting, no glob expansion (DL-202 / SEC-007 — captured model
# `claude-opus-4-7[1m]` contains glob chars). Returns nothing on
# missing or malformed file (soft fail; D-010).
_cost_flags_for() {
  local issue="$1" stage="$2"
  local f; f="$(issue_dir "$issue")/usage-${stage}.json"
  [[ -s "$f" ]] || return 0
  jq -r '
    "--tokens-in",    (.tokens_in    // 0 | tostring),
    "--tokens-out",   (.tokens_out   // 0 | tostring),
    "--cache-read",   (.cache_read   // 0 | tostring),
    "--cache-create", (.cache_create // 0 | tostring),
    "--cost-usd",     (.cost_usd     // 0 | tostring),
    "--model",        (.model        // "unknown")
  ' "$f" 2>/dev/null || true
}
```

`run-stage.sh` consumes the helper into a bash array, then passes it
quoted to metrics.sh:

```bash
local cost_flags=()
mapfile -t cost_flags < <(_cost_flags_for "$ident" "$stage")
bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "success" \
  "$duration" "verdict=transitioned" "${cost_flags[@]}"
```

Empty `cost_flags` (missing/malformed usage file) expands to no extra
args at all under `"${cost_flags[@]}"`, so the existing positional
contract is preserved unchanged on the legacy/replay paths. The
helper's `\n`-delimited output guarantees that even a model name
containing spaces or glob chars (`*`, `?`, `[…]`, `$`) is preserved
verbatim across the function boundary.

### D-006 — `PIPELINE_DRY_RUN=1` omits cost fields entirely

When `PIPELINE_DRY_RUN=1`, `dispatch.sh` returns at `:71` without
invoking claude and (per D-003) without writing `usage-<stage>.json`.
`run-stage.sh::_cost_flags_for` finds no file, returns empty, and
metrics.sh emits the existing fields only. No fake numbers, no `0.0`
placeholders.

`dispatch.sh` ALSO removes `usage-<stage>.json` at function entry on
the dry-run branch — closes the stale-file edge case (E-04) where a
prior real run's file would be misread.

**Constraint reference.** CLAUDE.md "How tests work" item 2: tests set
`PIPELINE_DRY_RUN=1`. Inserting fake usage in dry-run would corrupt
existing fixture-shape assertions in `*-test.sh` files.

### D-007 — Status surfacing: one summary line, internal cost-by-stage helper

`bin/status.sh` gains:

1. A new `show_cost_summary` section called from `main` (`bin/status.sh:228`)
   that prints:
   ```
   today=$X.XX · 7d=$X.XX · MTD=$X.XX  (legacy events: M/N)
   ```
   - `today` = events with `ts >= today 00:00 UTC` (UTC chosen for stability;
     stated in the section header so an operator reading at 11pm Pacific
     understands the boundary).
   - `7d` = rolling last 168 hours.
   - `MTD` = events with `ts >= first day of current UTC month`.
   - `legacy events: M/N` = `M` events without a `cost_usd` field out of `N`
     total stage-end events in the 7d window. Disambiguates "$0 because
     nothing ran" from "$0 because all events are pre-cost-feature legacy."
   - One header line above the totals: `Cost summary (subscription proxy):`
     so operators don't conflate the proxy number with literal billing
     (E-02).

2. An **internal** function `_aggregate_cost_by_stage` consumed by
   `show_cost_summary`. After the totals line, the function prints the
   per-stage breakdown:
   ```
     stage              events    cost      in       out      cache%
     implement              42   $12.34   180.0k    42.0k     73%
     brainstorm             18    $4.21    72.0k    18.0k     61%
     review                  6    $0.34   12.4k     1.8k      88%
   ```
   Right-aligned numerics; `k` is 1000 tokens; rounding `%.1fk`. Sorted by
   cost desc. No totals row in v1 (the totals line above already provides
   "today/7d/MTD"; a per-table totals row is duplicate).

   The function is **internal** (no `bash bin/status.sh cost-by-stage`
   sub-command in v1; `cost_by_stage` lives as a private helper).
   This pulls back from iteration 1's CLI sub-command, which scope-guardian
   correctly flagged as scope creep beyond the issue's "aggregation
   function" wording. Operators get the breakdown via the normal
   `bash bin/status.sh` invocation.

**Cache% formula.** `cache_pct = round(100 * cache_read / max(1, cache_read + cache_create))`.
Defined once and used by both `_aggregate_cost_by_stage` and the Linear
footer (D-008). When the denominator is zero (no cache traffic at all),
the column renders `--`, never `0%`. Pinning the formula here closes
F-001 / Design#1 / Coherence-F-001.

**Rejected alternative.** A new `bin/cost-report.sh` script. Rejected:
status.sh is the canonical "what's happening" command per CLAUDE.md
failure-mode reference. One more entry point is friction without
information gain.

**Rejected alternative.** Week-over-week deltas in v1 (product-lens
finding). Rejected for v1: implementing a defensible WoW comparison
needs a baseline-stability check (one-week issue mix can dwarf a model
swap), which is a research project. v1 ships absolute totals; trend
work is a separate ticket once the data has been on the dashboard.

### D-008 — Linear footer: one line appended after body, before PR tail

`run-stage.sh::post_completion_comment` (`bin/run-stage.sh:69`) gains a
helper `_cost_footer` that reads the same `usage-<stage>.json` and
returns:
```
cost: $0.42 · in 18.0k · out 4.0k · cache 73%
```
Format pinned (closes Design#2):
- `in` and `out` listed as `<float>k` with one decimal (`%.1fk`); never
  `/` (which reads as division at a glance).
- `·` separators throughout for visual rhythm consistent with status.sh.
- `cache N%` uses the same formula as D-007. When the denominator is
  zero, the `cache N%` segment is OMITTED rather than printed as `0%`.
- Currency: USD only; the proxy caveat lives in the status.sh header,
  not in every Linear comment.
- `model` is NOT shown in the footer in v1 (single-model assumption;
  if we start mixing models per stage, that's a follow-up).

The footer is appended in `comment_body` between `$body` and `$pr_tail`,
**after** the 32 KiB head-c truncation at `:101` operates on the body.
Verified at `bin/run-stage.sh:69-131`: `body` is built first
(`:99-106`), then `comment_body` is composed (`:108-123`); the footer
slots in at the composition stage and is not at risk of mid-line
truncation (E-08).

When `usage-<stage>.json` is missing or malformed, `_cost_footer` returns
empty string and the footer is silently omitted. Same code path serves
three operator-visible cases: legacy-stage, dispatch-crashed, dry-run.
The disambiguator surface is the per-stage transcript log line
`[cost] no result event found in stream` (D-002), which is what an
operator reaches for if the footer is missing on a stage they expect
cost on.

**Constraint reference.** Comment shape is owned by
`post_completion_comment` (ENG-11). Single source of truth avoids
silent-divergence bugs.

### D-009 — Sub-agent attribution: top-level `total_cost_usd` only, no per-tool surfacing in v1

The `result` event's `total_cost_usd` already aggregates the parent
session and any sub-agents (Task tool / Agent dispatch). We use that
single number and do NOT crawl `subagents[]` or per-tool counters.

This is the load-bearing tradeoff of v1: stage-grain visibility ships;
"is the browser MCP earning its keep?" is **not** answerable in v1.
The brainstorm explicitly accepts that limitation (§1 goal language;
§2 non-goals). If the operator needs per-tool ROI, a v2 ticket adds
either (a) per-tool_use cost extraction by walking the stream's
tool_use events, or (b) a side-by-side A/B by toggling MCP allowlists
and comparing aggregate stage costs.

**Why we do not pre-emptively add a `tools_invoked` array.** Product-lens
suggested a forward-compat hedge (capture which tools ran, even if we
don't price them). Rejected for v1: adding a field "in case we want it"
violates the §2 non-goal "Forward-compat schema speculation." If the v2
ticket needs it, v2 adds it. JSONL is append-only but the schema is not
versioned; adding a field at any time is cheap.

### D-010 — Failure-to-parse usage is a soft warning, not a stage failure

If `dispatch.sh` cannot find a `result` event in the stream (claude
crashed mid-stream, network failure, output-format flag rejected by a
future CLI version), `_render_and_capture_stream` logs `[cost] no result
event found in stream` (D-002), does not write `usage-<stage>.json`, and
the renderer returns 0. `dispatch.sh` continues normally; the existing
exit-20 dispatch-failed path is unchanged.

If the file exists but the post-stream extraction fails (jq error),
`_render_and_capture_stream` removes the partial file and logs the same
warning. `_cost_flags_for` (D-005) then returns empty.

No new exit codes. No new entries in
`bin/common.sh::failure_outcome_for_exit:100`. Cost telemetry is
observability, not control flow.

**Constraint reference.** CLAUDE.md "When wiring a new script" — adding
new exit codes without updating `failure_outcome_for_exit` routes them
to `unknown-exit-N` and the retrospective's §1 filter misses them.
D-010 explicitly does not add codes.

### D-011 — Scope-approval replay clears stale usage file

`run-stage.sh` removes `$issue_dir/usage-<stage>.json` at the top of the
`skip_dispatch=1` branch (`bin/run-stage.sh:250-258` is where the
short-circuit decision is made). Without this, a replay tick reads a
stale usage file from an earlier real dispatch and double-counts the
cost (F7 P1 from feasibility iteration 1).

```bash
if (( skip_dispatch )); then
  rm -f "$(issue_dir "$ident")/usage-${stage}.json"   # D-011
  bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" "scope-approval-replay" 0
fi
```

Replay metrics now reliably omit cost fields, matching the
`scope-approval-replay` outcome already emitted at `:284` and the
"replay does not invoke claude this tick" semantics.

### D-012 — `dispatch.sh` learns the issue id via env var, not signature change

`bin/dispatch.sh::main` (`bin/dispatch.sh:55-57`) takes
`<stage> <prompt_file> [<log_file>]` and has no positional issue_id.
Five callers exist today: `bin/run-stage.sh:276`,
`bin/run-release-observer.sh:39`, `bin/run-retrospective-local.sh:72`,
`bin/mutex-test.sh:33`, and `bin/dry-run.sh:129`. Of these, only
run-stage.sh has an issue_id in scope; release/retrospective have no
issue concept; the two test callers mock the world.

`dispatch.sh` reads issue_id from a new env var `PIPELINE_ISSUE_ID`
(consistent with the existing `PIPELINE_DRY_RUN` env-var pattern in
`bin/common.sh:171`). `run-stage.sh` exports the var immediately
before invoking dispatch.sh:

```bash
# bin/run-stage.sh, near the existing dispatch invocation at :276
PIPELINE_ISSUE_ID="$ident" \
  bash "$SCRIPT_DIR/dispatch.sh" "$stage" "$prompt_file" "$log_file"
```

`dispatch.sh` resolves the usage-file path:

```bash
# bin/dispatch.sh, after sourcing common.sh
USAGE_FILE=""
if [[ -n "${PIPELINE_ISSUE_ID:-}" ]]; then
  USAGE_FILE="$(issue_dir "$PIPELINE_ISSUE_ID")/usage-${stage}.json"
  rm -f "$USAGE_FILE"   # E-04 cleanup, both real and dry-run branches
fi
```

When `PIPELINE_ISSUE_ID` is unset (release, retrospective, mutex-test,
dry-run), `USAGE_FILE` is empty; the renderer's post-stream extract
silently skips the write (one extra `[[ -n "$USAGE_FILE" ]]` guard
around the existing logic). Cost telemetry is emitted only for stages
where an issue_id is in scope — which is all the per-issue stages
that already populate `events.jsonl`.

**Constraint reference.** CLAUDE.md "When wiring a new script": "Use
log/die/require_env/require_bin from common.sh — don't roll your own."
The env-var approach honors this by treating issue_id as ambient
context, the same way `TARGET_REPO`, `PIPELINE_DRY_RUN`, and
`PROJECT_SLUG` are ambient. No signature change, no caller cascade,
no test-stub updates beyond a single export in run-stage.sh.

**Rejected alternative.** Add a 4th positional arg `<issue_id>`.
Rejected: cascades to four other call sites (release, retrospective,
mutex-test, dry-run) plus the no-op dispatch stub at
`bin/run-stage-test.sh` STUB_DIR. Each non-issue caller would have
to pass a literal `-` or `none` sentinel — a contract that's
ergonomic only when the field is conceptually meaningful at every
call site, which it isn't here.

**Rejected alternative.** Move the writer out of `dispatch.sh` and
into `run-stage.sh` (let dispatch return raw NDJSON; run-stage parse
it). Rejected: dispatch.sh already runs `claude -p` under the
cross-project mutex and `tee` redirects stdout; reorganizing the
pipeline boundary so run-stage.sh sees the raw NDJSON would either
require re-piping through another script (mutex semantics unclear)
or losing the live `tee "$log_file"` semantics. Env-var passing
keeps dispatch.sh's chokepoint role intact.

## 4. Architecture

### 4.1 Files modified

| File | Change |
|---|---|
| `bin/dispatch.sh` | Add `--output-format stream-json --verbose` to `cmd` (`:78`); insert `_render_and_capture_stream` between cmd and `tee`; resolve `USAGE_FILE` from `PIPELINE_ISSUE_ID` env var (D-012) **inside `main()`, after `local tools=…` (`:60-61`) and BEFORE the dry-run guard at `:66`** so D-006's "rm -f on both branches" semantics hold (`$stage` is local to `main`, so the resolution cannot live at top-level); empty `USAGE_FILE` if unset; `rm -f` `USAGE_FILE` at function entry on both real and dry-run branches when set; `umask 077` for the usage-file write. |
| `bin/run-stage.sh` (env export) | Export `PIPELINE_ISSUE_ID="$ident"` immediately before the existing dispatch.sh invocation at `:276`. Single-line addition (D-012). |
| `bin/metrics.sh` | Replace tail-args parsing with the explicit flag-pair parser of D-004; conditionally include the six new fields in the `jq -cn` body. |
| `bin/run-stage.sh` | Add `_cost_flags_for` and `_cost_footer` helpers; `mapfile -t cost_flags < <(_cost_flags_for …)` and pass `"${cost_flags[@]}"` quoted into the four `metrics.sh stage-end` invocations at `:341`, `:451`, `:467`, `:471` (no word-split, no glob expansion — DL-202/SEC-007); append `_cost_footer` output in `post_completion_comment` between body and PR tail; add D-011 `rm -f` at the skip_dispatch branch. |
| `bin/status.sh` | Add `show_cost_summary` (called from `main` at `:228`) plus the internal `_aggregate_cost_by_stage` helper. |

### 4.2 Files added

| File | Purpose |
|---|---|
| `bin/dispatch-test.sh` | New. Tests the renderer + usage-file write path. NDJSON fixtures are inlined via heredoc, matching the existing `bin/run-stage-test.sh` STUB_DIR pattern (CLAUDE.md "How tests work"). No new top-level `tests/` directory. |
| `bin/metrics-test.sh` | New. Tests the new flag parser. Asserts `events.jsonl` line shape with and without each flag set, asserts that flags after positional `notes` parse correctly. |

The earlier draft proposed a `tests/fixtures/` tree and a separate
`status-test.sh`. Both pulled — the fixtures inline (F5 P1) and
status.sh changes are exercised by manual run since they're a thin
read-only `events.jsonl` aggregation that does not warrant a dedicated
test script (SG-001 P1). `bin/run-stage-test.sh` is extended in-place
with one new case asserting cost flags propagate when usage file is
present.

(Sentinel pattern verified: `bin/dispatch.sh:89-91` and
`bin/metrics.sh:35-37` both end with the
`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` sentinel,
so tests can `source` them without firing `main` per CLAUDE.md "How
tests work".)

### 4.3 No-op files

`AGENT_PROMPTS.md`, `render-prompt.sh`, `linear.sh`, `verdict-handler.sh`,
`scope-check.sh`, `classify-failure.sh`, `guards.sh`, `poll.sh`,
`reconcile.sh`, `run-local.sh`, all `learned-rules/<slug>/*.md` — none
need to change. Cost telemetry is observability; it does not affect
routing, scope partitioning, verdict markers, or label transitions.

`bin/dry-run.sh` is also unchanged. The earlier draft's open question
about pinning a minimum claude CLI version is dropped — claude will
fail loudly if `--output-format stream-json` is rejected, and a
proactive version check is gold-plating relative to the issue's scope
(SG-004 P2).

### 4.4 Implementation tactics

The renderer code shape in §3 D-002 is illustrative-but-binding on
three points: it MUST use a single jq invocation (F4 P0), MUST drop
malformed lines silently (F2 P0), and MUST write only the six fields
to the usage file (SEC-002 P1). Other implementation details are open
to the implementation phase.

## 5. Data flow

```
                                 ┌──────────────────────────────┐
 run-stage.sh                    │     claude -p \              │
   │                             │       --output-format        │
   ├─► dispatch.sh ─────────────►│       stream-json            │
   │                             │       --verbose              │
   │                             └──┬───────────────────────────┘
   │                                │   stdout: NDJSON
   │                                ▼
   │            ┌───────────────────────────────────────────────┐
   │            │ _render_and_capture_stream "$usage_file"      │
   │            │   ├─► single jq pass over NDJSON              │
   │            │   ├─► prose lines on STDOUT  ──► tee → log    │
   │            │   └─► result event sidelined → tempfile       │
   │            │ post-stream: extract 6 fields → usage-<stage>.json
   │            │              (umask 077, 6 fields ONLY)       │
   │            └───────────────────────────────────────────────┘
   │
   │ (post-dispatch)
   ├─► _cost_flags_for ENG-X stage
   │     └─► jq -r over usage-<stage>.json
   │     returns: --tokens-in N --tokens-out N --cache-read N
   │              --cache-create N --cost-usd N --model STRING
   │     (returns "" on missing/malformed file → soft fail)
   │
   ├─► metrics.sh stage-end ENG-X stage outcome dur "notes" $cost_flags
   │      └─► appends one line to $PROJECT_STATE_DIR/metrics/events.jsonl
   │
   └─► post_completion_comment → _cost_footer
         appends "cost: $X · in Yk · out Zk · cache N%" between body
         and PR tail in the existing completion/<stage>/<issue> comment
```

The cost summary in `status.sh` is a read of `events.jsonl` — it does
not touch claude, Linear, or gh.

## 6. Error handling

Every failure mode below corresponds to a real path in the code, not a
hypothetical:

| Failure | Where it surfaces | Behavior |
|---|---|---|
| `claude` exits nonzero mid-stream | `dispatch.sh::main` already handles via `if ! bash ".../dispatch.sh"` at `bin/run-stage.sh:276` (exit 20, dispatch-failed) | Unchanged. The renderer was tolerant by construction (`fromjson? // empty`), so even partial streams produce no spurious errors; the usage file may simply not exist. |
| Stream contains no `result` event | `_render_and_capture_stream` logs warning, writes no usage file | `run-stage.sh` emits metrics without cost fields. Soft fail. |
| Stream contains malformed NDJSON lines | `fromjson?` drops them silently | Renderer continues; no abort. |
| `usage-<stage>.json` exists but `_cost_flags_for` jq parse fails | helper returns "" | Field omitted from metrics. Soft fail. |
| `jq` is missing | `metrics.sh` already requires `jq` (`bin/metrics.sh:23`); same constraint applies to dispatch.sh's renderer | Existing failure mode; no new exposure. |
| `events.jsonl` cost summary asked for before any cost-tagged event exists | `status.sh::show_cost_summary` reads zero matching lines, prints `today=$0.00 · 7d=$0.00 · MTD=$0.00 (legacy events: 0/0)` | The `M/N` tail makes "no claude calls" distinguishable from "all calls were legacy". |
| Concurrent dispatch on same issue (mutex held) | Cross-project mutex at `bin/dispatch.sh:14` already serializes | Two ticks for the same issue cannot race over `usage-<stage>.json` because only one holds the mutex at a time. |
| Stale `usage-<stage>.json` on dry-run after real dispatch | `dispatch.sh` `rm -f` at function entry (D-006) | Stale file removed before any reader sees it. |
| Stale `usage-<stage>.json` on scope-approval replay | `run-stage.sh` `rm -f` at the skip_dispatch branch (D-011) | Stale file removed before metrics.sh stage-end emits. |

## 7. Edge cases

**E-01: Cache token field naming — VERIFIED.** The captured stream
in A-04 confirms `.usage.cache_creation_input_tokens` and
`.usage.cache_read_input_tokens`. (Earlier draft listed this as
"assumed".)

**E-02: Cost in subscription mode.** The harness runs `claude -p` against
the **logged-in subscription session** per CLAUDE.md "Runtime topology":
"`ANTHROPIC_API_KEY` is intentionally never set." Subscription billing
is metered server-side; the CLI still reports `total_cost_usd` derived
from token counts and the model's published rate card. The number is a
proxy for "what this would cost on API pricing", not a literal
subscription debit. Documented at the top of `status.sh`'s cost summary
(D-007) so operators don't conflate them.

**E-03: Sub-agents (Task tool).** `total_cost_usd` rolls these up at the
parent level (D-009). The `usage` block also rolls token counts up.
We rely on this; if it turns out the rollup is incomplete in some
edge case, the metric line under-reports. Known degradation, not silent
corruption — the renderer's `[result]` log line is the audit trail.

**E-04: Dry-run after a real dispatch leaves stale usage file.**
Mitigated: `dispatch.sh` does `rm -f` at function entry on both real
and dry-run branches (D-003, D-006). A missing file is the canonical
"no usage to report" signal.

**E-05: Scope-approval replay.** When `run-stage.sh` short-circuits
dispatch via `skip_dispatch=1` (`bin/run-stage.sh:250-258`), no claude
was called this tick. `dispatch.sh` is not invoked, so its `rm -f`
does not run — but D-011 adds `rm -f $issue_dir/usage-<stage>.json`
at the top of the skip_dispatch branch in `run-stage.sh` itself,
closing the gap. Replay metrics omit cost fields.

**E-06: `verdict_handler` exit codes 1 and 2.** The `metrics.sh stage-end`
calls at `:467` (halt-for-human) and `:471` (protocol-violation) still
ran the agent and so still have a usage file to read. Cost flags ARE
attached — halt-for-human stages cost real money and we want them in
rolling totals. The cost-emit table in D-005 enumerates these.

**E-07: Reconcile metric sites (run-local.sh).** Three sites:
`bin/run-local.sh:189` (`outcome=linked`), `:196` (reconcile-human
stage-start), `:201` (reconcile-human stage-end). None invoke claude;
none receive cost flags. Behavior is correct by absence of any flag in
the call site (no code change needed at these lines).

**E-08: 32 KiB stage-summary truncation.** The cost footer is appended
in `post_completion_comment` AFTER the body has already been
head-c-truncated (`bin/run-stage.sh:101`). The footer is not at risk of
being sliced. Verified.

**E-09: Reading historical events.** Legacy events written before this
ships have none of the six fields. Read-side queries use `// 0` defaults
(e.g., `jq '.cost_usd // 0'`). The `legacy events: M/N` counter in
`status.sh` separates legacy from cost-omitted-because-replay.

**E-10: Cross-project mutex blocking.** The renderer holds the mutex
during stream processing. With one jq fork (D-002, F4), the additional
wall time is one jq startup (~30ms macOS) plus the streaming filter
(O(stream length)). On a 1000-line stream this is sub-second, well
under the noise of a multi-minute agent run. The earlier per-line jq
draft would have added ~30s — abandoned.

## 8. Testing

- `bin/dispatch-test.sh` (new). Drives `_render_and_capture_stream` with
  two inline NDJSON fixtures (success path with a real `result` event
  shaped per A-04; no-result path that ends mid-stream). Asserts:
  - the success stream produces ≥1 prose line per event type;
  - `usage-<stage>.json` contains EXACTLY the six required fields, no
    `session_id`, `permission_denials`, or `result` text (SEC-002
    regression test);
  - the no-result stream logs the warning and writes no file;
  - a malformed-line-in-the-middle stream still produces a usage file
    if a valid `result` event follows (F2 regression test).
  - mode of the written usage file is `0600` (SEC-005 regression).
  Stub `claude` is a script that `cat`s the fixture; the existing
  `STUB_DIR` pattern from `bin/run-stage-test.sh:18-30` makes this
  trivial.

- `bin/metrics-test.sh` (new). Tests the flag-pair parser:
  - all six flags present produces a 13-key line;
  - flags absent produces the existing 7-key line (no `null`s, no
    zeroes);
  - flag-after-notes parses correctly (`metrics.sh stage-end I S O 100
    "branch=foo" --cost-usd 0.42` — the `notes` is `"branch=foo"`, the
    cost is `0.42`);
  - mixed flag and trailing-notes parses (`--tokens-in 500 "branch=foo"`
    in any order produces both fields).

- `bin/run-stage-test.sh` extended in-place. New cases:
  - when `usage-<stage>.json` is present in `issue_dir`, the captured
    `metrics.sh` invocation receives the six flags;
  - when absent, it does not;
  - skip_dispatch branch removes the file (D-011 regression).
  Hooks into the existing capture-file pattern.

- No `bin/status-test.sh`. Manual verification on a tempdir
  `events.jsonl` is sufficient for v1.

## 9. ADR pressure (anti-bias check)

| Existing decision | Pressure | Tradeoff |
|---|---|---|
| ENG-23 env var refactor (`HARNESS_ROOT`/`TARGET_REPO`/`HARNESS_STATE_DIR`/`PROJECT_STATE_DIR`) | None. Usage file lives at `$issue_dir`, already `$PROJECT_STATE_DIR/<issue>/`. | None. |
| ENG-18 verdict-marker protocol | None. Cost telemetry is observability, not control flow. | None. |
| ENG-11 single completion comment per stage | Mild. Footer appended to existing comment shape; 32 KiB truncation already protects body. | Footer is one line; future cost-richer footers would compete with prose budget. Out of scope. |
| ENG-10 exit-code → outcome taxonomy | None. D-010 explicitly forbids new exit codes. | None. |
| ENG-7 stage-summary file agent contract | None. Cost telemetry is orchestrator-side; agent contract unchanged. | None. |
| Cross-project `.claude-mutex.lock` | Mild. Renderer adds work inside the critical section, but a single jq fork keeps it sub-second (E-10). | None blocking. |

No accepted ADR needs to be overturned. No new ADR needs to be filed —
every decision sits inside the surface area of existing constraints.

## 10. Assumption inventory

Per rule B-001 (`learned-rules/twinning/brainstorm.md:24-39`), every
named code artifact below is verified against current code with a
quoted `path:line`.

| ID | Assumption | Status | Evidence |
|---|---|---|---|
| A-01 | `docs/VISION.md` and `docs/architecture/SYSTEM_ARCHITECTURE.md` referenced in the prompt template do NOT exist in this repo. CLAUDE.md is the architecture source. | verified | `ls docs/` lists only `brainstorms/` and `plans/`; CLAUDE.md is at repo root. |
| A-02 | `bin/dispatch.sh::main` is the single chokepoint for `claude -p` invocation; the cmd array is at `:78`. | verified | `bin/dispatch.sh:55-87`. |
| A-03 | `bin/dispatch.sh` ends with the test-friendly sentinel. | verified | `bin/dispatch.sh:89-91`. |
| A-04 | `claude -p --output-format stream-json --verbose` emits a final `result` event with the field shape used by the renderer. | **VERIFIED via live capture (no longer "assumed")**. | A captured stream's last line, archived as the example in §3 D-001, shows: `total_cost_usd` at top level; `usage.input_tokens`, `usage.output_tokens`, `usage.cache_read_input_tokens`, `usage.cache_creation_input_tokens` exactly as named. **Also discovered**: `model` is NOT a top-level field — it is an object KEY of `modelUsage`. The renderer's model-extract uses `.modelUsage \| keys \| .[0]`. The `result` event also contains `session_id`, `permission_denials`, and the literal final assistant message under `.result` — the reason D-003 writes only the six required fields, never the verbatim event. |
| A-05 | `bin/metrics.sh::main` accepts positional args and writes via `jq -cn` (`:23`). The existing `notes="${*:-}"` at `:13` swallows ALL trailing args, so the new schema MUST add an explicit flag-pair parser before computing notes. | verified (and the swallow-bug is the source of D-004's parser design). | `bin/metrics.sh:1-37`. |
| A-06 | `bin/metrics.sh` ends with the test-friendly sentinel. | verified | `bin/metrics.sh:35-37`. |
| A-07 | `bin/run-stage.sh::post_completion_comment` (`bin/run-stage.sh:69`) is the single point where the per-stage Linear comment is built; 32 KiB head-c truncation at `:101` operates on the body before composition, so the appended footer is safe. | verified | `bin/run-stage.sh:69-131`; `:99-106` builds `body`, `:108-123` composes `comment_body`. |
| A-08 | `bin/run-stage.sh` calls `metrics.sh stage-end` at four sites where claude ran (`:341`, `:451`, `:467`, `:471`) and one paused-path stage-end at `:226` where claude did NOT run. `bin/run-local.sh` has three reconcile-related metric sites: `:189` (linked), `:196` (start), `:201` (end). | verified — D-005 enumerates the cost-flag policy for each site. | grep -n on `metrics.sh stage-end` confirmed the seven sites. |
| A-09 | `bin/status.sh::main` (`:228-235`) calls four `show_*` helpers; adding a fifth (`show_cost_summary`) is mechanical. | verified | `bin/status.sh:226-235` shows `show_runs`, `show_active_issues`, `show_metrics`, `show_markers` directly. |
| A-10 | `bin/common.sh::issue_dir` (`bin/common.sh:61`) returns `$PROJECT_STATE_DIR/<issue>` and is the canonical helper for per-issue paths. | verified | `bin/common.sh:61-65`. |
| A-11 | `bin/common.sh::failure_outcome_for_exit` (`bin/common.sh:100-118`) is the exit-code → outcome switch the retrospective relies on; new exit codes that bypass it route to `unknown-exit-N`. D-010 honors this by adding no new codes. | verified | `bin/common.sh:100-118`. |
| A-12 | The cross-project claude mutex at `bin/dispatch.sh:14-34` serializes every `claude -p` invocation. A single-jq-pass renderer keeps the added critical-section time sub-second (E-10). | verified | `bin/dispatch.sh:14-34`, `:63-64`. |
| A-13 | `events.jsonl` is append-only, written by `bin/metrics.sh:32`, and read by status.sh (`bin/status.sh:151`) and the retrospective. Optional fields are forward-and-backward compatible because every consumer uses `jq` with `// default`. | verified | `bin/metrics.sh:32`; `bin/status.sh:151` (`tail -n 10 "$jsonl" \| jq -r ...`). |
| A-14 | `learned-rules/twinning/brainstorm.md` rule B-002 mandates `linear: ENG-N` YAML frontmatter. | verified — this doc complies. | `learned-rules/twinning/brainstorm.md:42-52`; this doc lines 1-5. |
| A-15 | `--output-format json` (single-result) was rejected because it buffers stdout for the full agent run, breaking the live `tee` pattern at `bin/dispatch.sh:82`. Stream-json preserves live output. | verified | `claude --help` describes the format options; `dispatch.sh:82` shows the existing `tee` requires line-by-line output. |
| A-16 | The harness runs against the subscription session, so `total_cost_usd` is a proxy, not a billed amount. Documented as E-02 and surfaced in status.sh's section header (D-007). | verified | CLAUDE.md "Runtime topology": "`ANTHROPIC_API_KEY` is intentionally never set." |
| A-17 | The retrospective agent must not consume cost data yet — separate ticket. | issue-decision (issue body, "Out of scope" item 4) | Quoted in §2. |
| A-18 | `tests/fixtures/` does NOT exist in the repo. The repo's testing convention (CLAUDE.md "How tests work") is `bin/<x>-test.sh` with inlined heredoc fixtures and `STUB_DIR` mocks. The brainstorm follows that convention; no new top-level `tests/` directory is introduced. | verified | `ls tests/` returns nothing; `bin/run-stage-test.sh:16-65` shows the canonical STUB_DIR + heredoc pattern. |
| A-19 | Single PR feasibility: dispatch / run-stage / metrics / status changes are tolerant of partial-merge if landed in this order: metrics.sh first (backward-compat parser), then dispatch.sh (writes usage file), then run-stage.sh (reads it), then status.sh (aggregates). Each landing point leaves the system functional. v1 ships in one PR; the order above is preserved within the PR's commit history for bisect-friendliness. | verified by inspection of each call site for tolerance to a missing usage file. | `bin/run-stage.sh:451` (success metric emit) — adding flags is additive; `bin/metrics.sh:32` — flag-absent path emits existing 7-key line unchanged. |
| A-20 | `bin/dispatch.sh::main` (`bin/dispatch.sh:55-57`) takes `<stage> <prompt_file> [<log_file>]` and has no positional issue_id today; five external callers exist (run-stage.sh:276, run-release-observer.sh:39, run-retrospective-local.sh:72, mutex-test.sh:33, dry-run.sh:129). Of these, only run-stage.sh has access to a Linear issue_id. D-012 resolves this via the `PIPELINE_ISSUE_ID` env var pattern (matching the existing `PIPELINE_DRY_RUN` ambient-context convention at `bin/common.sh:171`); `dispatch.sh` becomes a no-op writer when the var is unset, so release/retrospective/test callers need no changes. | verified | `grep -n dispatch.sh bin/*.sh` lists exactly five callers; `bin/common.sh:171` shows the existing env-var pattern. |

## 11. Out-of-scope flags (must-call-out)

The Linear issue's "Out of scope" section is comprehensive. This brainstorm
does NOT exceed it. Items that came up in design and could tempt scope
creep, called out explicitly:

- **Cost-aware retries.** A failed stage costs money; one might want to
  gate `classify_failure`'s `retry-immediately` on a per-issue cost
  budget. Out of scope (issue's "Budget alerts, kill switches, per-issue
  cost caps").
- **Per-tool / per-MCP attribution.** Per D-009, top-level only. Goal
  language explicitly accepts this limitation. Out of scope.
- **Backfill.** Out of scope (issue's "Backfill of historical events").
- **Retrospective consumption.** Out of scope (issue's item 4).
- **Week-over-week deltas / trend columns / per-issue rollups.** Out of
  scope (D-007 rejected alternative). v1 captures the data; trend
  surfaces are follow-on tickets.
- **Forward-compat `tools_invoked` array.** Out of scope per §2 — we add
  fields when a consumer is confirmed.
- **CLI version pin in `bin/dry-run.sh`.** Dropped from earlier draft —
  claude will fail loudly if the format flag is rejected; proactive
  pinning is gold-plating relative to issue scope (SG-004 P2).
- **Outlier-flag-only Linear footer.** Product-lens suggested only emit
  the footer when cost is in the top decile. Out of scope: needs a
  rolling-baseline computation that v1 doesn't have. Footer ships
  unconditionally in v1; outlier rendering is a follow-on if operators
  treat the footer as wallpaper.

## 12. Open questions

1. **Concurrent-tick cost line per tick is by design.** Two ticks ~5
   minutes apart against the same issue can each invoke claude if the
   prior tick's stage finished cleanly. Each writes a fresh usage file
   and a fresh events.jsonl line. This is intentional (one line per
   tick); per-issue lifetime cost rollup is explicitly out of scope.
   Listed here only because the earlier draft phrased this as a
   question.
2. **Status output width** for the per-stage breakdown. Target ~100
   columns to match status.sh's existing tables. Defer narrow-terminal
   wrapping to follow-up if any operator complains.
3. **Footer wallpaper risk.** Product-lens raised that
   `cost: $0.42 · in 18.0k · out 4.0k · cache 73%` on every comment
   may normalize and stop being read. Mitigation deferred — let the
   data show whether operators ignore it; if they do, future ticket
   adds outlier-only rendering.

## 13. Persona review

This section is filled in across iterations. Each iteration records
verdicts and the highest-severity findings.

### Iteration 1

| Persona | PASS / FAIL | Highest-severity finding |
|---|---|---|
| design-lens | PASS (P1 only) | P1 cache-pct formula undefined; P1 footer ambiguity (units, slash); P1 status line ambiguity. Addressed in iteration 2 (D-007 cache-pct formula; D-008 unit pinning). |
| security-lens | PASS (P1 only) | P1 SEC-001 80-char tool_use input is not redaction; P1 SEC-002 verbatim result event leaks session_id / final assistant text. Addressed in iteration 2 (renderer drops tool_use input bytes; usage-file holds only six fields). |
| scope-guardian | PASS (P1 only) | P1 four new test files for one feature; P1 cost-by-stage CLI sub-command exceeds "aggregation function" scope. Addressed in iteration 2 (status-test.sh cut, fixtures inlined; cost-by-stage demoted to internal helper). |
| coherence | PASS (P1 only) | P1 cache-pct undefined; P1 omitted-vs-zero schema contradiction; P1 new-vs-extend test wording. Addressed in iteration 2 (formula pinned; D-004 explicit; "new" wording reconciled). |
| product-lens | **FAIL (1 P0)** | P0 per-stage cost cannot answer browser-MCP-ROI question. Resolved in iteration 2 by **narrowing v1 goal language** (§1) to stage-grain visibility and explicitly accepting that per-tool ROI is a v2 concern (§2 + D-009). The P0 reframes correctly: it pointed at goal-vs-decision misalignment; v2 doesn't expand v1, it narrows the v1 promise. |
| feasibility | **FAIL (5 P0s)** | F1 metrics.sh notes-arg swallow; F2 renderer error handling under pipefail; F3 stderr-vs-stdout for tee; F4 per-line jq under cross-project mutex; F8 result.usage field names unverified. All addressed in iteration 2 (D-004 explicit parser; D-002 fromjson? // empty + single jq; D-002 stdout target; D-002 single-fork mandate; A-04 verified via live capture). |

### Iteration 2

| Persona | PASS / FAIL | Highest-severity finding |
|---|---|---|
| design-lens | PASS (P1 only, all addressed inline) | P1 DL-201 binary sentinel readability; P1 DL-202 word-splitting glob risk; P1 DL-203 cache% column on universal-zero. Addressed by `tee`-split renderer (no sentinel — F-C001 fix), `mapfile` array pattern in D-005, `--` rendering documented in D-007. P2 naming inconsistency (`tokens_in/_out` vs `cache_read/_create`) accepted with rationale: directional pair for the primary I/O axis, verb pair for cache because cache traffic is always input-side; documenting in D-003 if reviewers still object. |
| security-lens | PASS (P1 only, all addressed inline) | P1 SEC-007 word-split glob (same as DL-202; fixed by mapfile); P1 SEC-008 intermediate /tmp tempfile (fixed by moving raw_capture under `$issue_dir`). P2 SEC-010 ANSI/CR log forging (fixed by `strip_ctrl` jq function). P3 SEC-011 dead `--rawfile` argument removed alongside the tee-split rewrite. |
| scope-guardian | PASS (P3 only) | No P0/P1/P2. Iteration-2 P3 advisories: SG-007 footer format deviates from issue's literal example without acknowledgment (added one-line note in D-008); SG-008 renderer code is more prescriptive than §4.4 disclaims (accepted as binding once P0s land); SG-009 goal-narrowing trace (acknowledged §1 + D-009 follow issue's decision #7). |
| coherence | PASS (P1 only, all addressed inline) | P1 F-C001 sentinel mismatch (FIXED — renderer rewritten as tee-split, no sentinel exists). P2 F-C002 `unknown` model fallback test gap (added regression case to §8). P2 F-C003 `$pr_tail` undefined (it's a local in `post_completion_comment` `bin/run-stage.sh:80-87`; verified via Read). P2 F-C004 phrasing of P0-resolved row (clarified). P3 F-C005 A-08 enumeration (fixed in §10). |
| product-lens | PASS (P0-RESOLVED) | Iteration-1 P0 resolved at brainstorm-stage standard. Iteration-2 P2 advisory only: rejecting `tools_invoked` forward-compat hedge is defensible but historical rows from v1 cannot be backfilled when v2 adds per-tool. Accepted asymmetry; documented in §11. |
| feasibility | **FAIL (1 P0)** | Iteration-1's five P0s (F1–F4, F8) all RESOLVED — confirmed by feasibility re-review. NEW iteration-2 P0 F-IT2-001: `bin/dispatch.sh::main` has no path to receive an issue_id (signature is `<stage> <prompt_file> [<log_file>]`); D-003/D-006/§4.1 assumed dispatch.sh writes `$issue_dir/usage-<stage>.json` without specifying how dispatch.sh learns the issue_id. Resolved in iteration 3 by adding D-012 (env-var contract via `PIPELINE_ISSUE_ID`, matching the existing `PIPELINE_DRY_RUN` ambient pattern at `bin/common.sh:171`). The other iteration-2 feasibility findings — P1 line-number drift (cosmetic; doc references function range, not specific lines) and P2 system/init `$e.model` graceful-degradation (already handles via `// "?"` fallback) — are accepted advisories. |

### Iteration 3

| Persona | PASS / FAIL | Note |
|---|---|---|
| feasibility | **PASS** (P3 only — gate clears) | F-IT3-001 P3 advisory: USAGE_FILE resolution placement is constrained to inside `main()` (because `$stage` is a local of `main` at `bin/dispatch.sh:56`); §4.1 row pinned to "after `:60-61`, before the dry-run guard at `:66`". All iteration-2 P0/P1 findings closed. All iteration-1 P0/P1 findings closed. Gate verdict from feasibility: PASS — brainstorm proceeds to planning. |

### Final gate

- Iteration 1: 4/6 PASS (product P0, feasibility 5 P0s).
- Iteration 2: 5/6 PASS (feasibility 1 P0 — F-IT2-001 dispatch issue-id contract).
- **Iteration 3: 6/6 PASS, feasibility 0 P0**. D-012 closed F-IT2-001 by adding the `PIPELINE_ISSUE_ID` env-var contract; the only residual finding is a P3 advisory on placement that is now pinned in §4.1.

Gate threshold (≥5/6 PASS AND feasibility 0 P0): **MET**. Status: ready for planning.
