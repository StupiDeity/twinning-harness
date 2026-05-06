#!/usr/bin/env bash
# Invoke the Claude Code CLI headlessly with a rendered prompt.
# Usage: dispatch.sh <stage> <prompt_file> [<log_file>]
# In PIPELINE_DRY_RUN=1, echoes what it would do without calling claude.
#
# CWD is the feature's worktree when called from run-local.sh (ENG-13 D-011),
# or the main repo root for legacy feature/* branches.
#
# Cost telemetry (ENG-26): when env var PIPELINE_ISSUE_ID is set, the
# stream-json renderer extracts the final `result` event and writes a
# six-field usage-<stage>.json into $issue_dir. Other callers (release,
# retrospective, mutex-test, dry-run-self-check) leave PIPELINE_ISSUE_ID
# unset and the renderer block is bypassed.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

CLAUDE_MUTEX_DIR="$HARNESS_STATE_DIR/.claude-mutex.lock"
CLAUDE_MUTEX_TIMEOUT="${CLAUDE_MUTEX_TIMEOUT:-600}"

acquire_claude_mutex() {
  local waited=0
  while ! mkdir "$CLAUDE_MUTEX_DIR" 2>/dev/null; do
    if (( waited == 0 )); then
      local holder=""
      [[ -f "$CLAUDE_MUTEX_DIR/pid" ]] && holder="$(cat "$CLAUDE_MUTEX_DIR/pid" 2>/dev/null || true)"
      log "[claude-mutex] waiting for lock held by ${holder:-<unknown>}"
    fi
    (( waited >= CLAUDE_MUTEX_TIMEOUT )) && die "[claude-mutex] timeout after ${CLAUDE_MUTEX_TIMEOUT}s"
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\n' "$$" > "$CLAUDE_MUTEX_DIR/pid"
}

release_claude_mutex() {
  rm -rf "$CLAUDE_MUTEX_DIR"
}

# ─── Transcript-based assertion (ENG-43) ─────────────────────────────────
# Single jq fork; reads NDJSON from $transcript line by line, finds tool_use
# blocks invoking Bash whose .input.command starts with $pattern, and prints
# the FIRST match on stdout (returning 1). Soft-fail (return 0) on
# empty/missing transcript so dry-run / planning-only paths never synthesize
# false positives. Pure: no harness ambient context (D-010).
assert_no_tool_invocation() {
  local transcript="$1" pattern="$2"
  [[ -s "$transcript" ]] || return 0
  local matched
  matched="$(jq -Rr --arg p "$pattern" '
    fromjson? // empty
    | select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Bash")
    | (.input.command // "")
    | select(startswith($p))
  ' "$transcript" 2>/dev/null | head -1)" || true
  if [[ -n "$matched" ]]; then
    printf '%s\n' "$matched"
    return 1
  fi
  return 0
}

# ─── Stream-json renderer (ENG-26 D-002) ─────────────────────────────────
# Reads NDJSON on stdin; emits prose-ish progress lines on STDOUT (so the
# caller's `tee "$log_file"` captures them); mirrors the raw NDJSON to a
# private capture file under $issue_dir; after the stream ends, extracts
# only six fields from the LAST type==result line and writes them to
# $usage_file at mode 0600 (umask 077).
#
# Args: $1 = usage_file, $2 = issue_dir.
#
# Tolerances:
#   - F2 (D-002): malformed NDJSON lines are silently dropped via
#     `fromjson? // empty`. One bad line cannot abort dispatch.
#   - D-010: missing result event → no usage file, soft-fail log line,
#     return 0. Cost telemetry is observability, not control flow.
#
# Defenses:
#   - SEC-001: tool_use input payloads never logged. Renderer emits
#     `[tool] <name>` only.
#   - SEC-002: usage file holds exactly six fields. session_id /
#     permission_denials / result text / modelUsage rollup never written.
#   - SEC-005: usage file written under `(umask 077; …)` so default-022
#     hosts cannot leave it world-readable.
#   - SEC-008: intermediate raw-NDJSON capture lives under $issue_dir
#     (per-issue trust scope), prefixed with `.` (artifact-scanner-invisible),
#     and is removed by a RETURN trap.
#   - SEC-010: C0 control chars stripped from agent text before logging
#     (defends against `\r[FAKE LOG]` log forging).
_render_and_capture_stream() {
  local usage_file="$1" issue_dir="$2" stage="${3:-}"
  local raw_capture="${issue_dir}/.raw-stream.ndjson.tmp"
  local violation_file="${issue_dir}/.transcript-violation-${stage}"
  rm -f "$violation_file"            # idempotent pre-clean (D-008)
  trap 'rm -f "$raw_capture"' RETURN
  mkdir -p "$issue_dir"

  # Single jq fork for the whole stream (F4 P0). `tee` mirrors raw NDJSON
  # to $raw_capture; jq -nRr --unbuffered reads via `inputs` and emits
  # raw (unquoted) prose lines on stdout, letting the caller's
  # `tee "$log_file"` catch them. `fromjson? // empty` silently drops
  # malformed lines. The `-r` flag is load-bearing — without it jq
  # emits JSON-encoded strings (`"[claude] session=…"` with literal
  # quote bytes), breaking the D-002 / F3 prose-on-STDOUT contract.
  tee "$raw_capture" \
    | jq -nRr --unbuffered '
        def strip_ctrl: gsub("[\u0000-\u001f]"; " ");
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

  # Post-stream: extract only the six required fields from the LAST
  # type==result line. Allowlist by construction (SEC-002). On parse
  # failure, remove any partial and log soft-fail (D-010).
  local last_result
  last_result="$(grep '"type":"result"' "$raw_capture" 2>/dev/null | tail -1 || true)"
  if [[ -n "$last_result" ]]; then
    if ( umask 077; printf '%s' "$last_result" \
         | jq -c '{
             tokens_in:    (.usage.input_tokens // 0),
             tokens_out:   (.usage.output_tokens // 0),
             cache_read:   (.usage.cache_read_input_tokens // 0),
             cache_create: (.usage.cache_creation_input_tokens // 0),
             cost_usd:     (.total_cost_usd // 0),
             model:        ((.modelUsage // {}) | keys | (.[0] // ""))
           }' > "$usage_file" ); then
      log "[cost] result event captured: cost=$(jq -r '.cost_usd' "$usage_file" 2>/dev/null)"
    else
      log "[cost] no result event found in stream (post-extract jq failed; usage-<stage>.json not written)"
      rm -f "$usage_file"
    fi
  else
    # ENG-65 D-003: SIGTERM (or any path leaving no result event) loses
    # cost telemetry pre-fix. Sum per-message assistant.message.usage
    # so the metrics stream isn't biased toward zero on watchdog kills.
    # cost_usd is set to JSON null because total_cost_usd is only on the
    # result event; downstream `_cost_flags_for` coerces null → 0 via
    # `// 0`. The `partial: true` field is the on-disk discriminator the
    # retrospective reads to separate "captured under SIGTERM" from
    # "clean zero-cost dispatch."
    local _partial_json
    _partial_json="$(jq -nR '
      [inputs | (fromjson? // empty)] as $events
      | ($events | map(select(.type=="system" and .subtype=="init"))[0].model // "") as $model
      | ($events | map(select(.type=="assistant") | (.message.usage // {}))) as $usages
      | { tokens_in:    ($usages | map(.input_tokens // 0)             | add // 0),
          tokens_out:   ($usages | map(.output_tokens // 0)            | add // 0),
          cache_read:   ($usages | map(.cache_read_input_tokens // 0)  | add // 0),
          cache_create: ($usages | map(.cache_creation_input_tokens // 0) | add // 0),
          cost_usd:     null,
          model:        $model,
          partial:      true }
    ' < "$raw_capture" 2>/dev/null || printf '')"
    local _partial_sum=0
    if [[ -n "$_partial_json" ]]; then
      _partial_sum="$(printf '%s' "$_partial_json" | jq -r '(.tokens_in + .tokens_out)' 2>/dev/null || printf 0)"
    fi
    if [[ -n "$_partial_json" && "$_partial_sum" =~ ^[0-9]+$ && "$_partial_sum" -gt 0 ]]; then
      ( umask 077; printf '%s' "$_partial_json" > "$usage_file" )
      log "[cost] partial usage captured (no result event; SIGTERM-style termination): tokens_in+out=${_partial_sum}"
    else
      log "[cost] no result event found in stream (soft fail; usage-<stage>.json not written)"
    fi
  fi

  # ENG-43: defense-in-depth assertion. Tool lane should already deny
  # Bash(gh:*) for implementing (allowed_tools_for case above); this is the
  # second line of defense if the lane is ever misconfigured. Gated on
  # stage == "implementing" only — other stages observe no behavior change.
  if [[ "$stage" == "implementing" ]]; then
    local _matched_cmd
    if _matched_cmd="$(assert_no_tool_invocation "$raw_capture" "gh pr create")"; then
      :   # rc 0: no match, fall through
    else
      printf '%s\n' "$_matched_cmd" > "$violation_file"
      log "[assert] implement-stage transcript invoked forbidden tool: ${_matched_cmd}"
      return 22
    fi
  fi
}

# ENG-48 isolation: platform tools whose call from a headless dispatch
# either demonstrated a runaway (ScheduleWakeup → 2026-04-28 ENG-45 7h
# wedge) or could enable one (subagent escape, plan-mode entry, cron
# creation, network egress not guarded by per-stage allowlists). The
# --allowed-tools flag is a permission allowlist, not an availability
# list — these tools are still callable unless explicitly denied.
disallowed_platform_tools() {
  # Excluded from this list: Task / WebFetch. Task may alias the Agent tool
  # that ui/review/qa/retrospective stages legitimately allow; WebFetch is
  # in brainstorm's allowed-tools. Denials win over allows in claude's
  # tool-resolution, so denying either would break working stages.
  printf 'ScheduleWakeup TodoWrite Skill EnterPlanMode ExitPlanMode EnterWorktree ExitWorktree RemoteTrigger PushNotification CronCreate CronDelete CronList Monitor WebSearch ToolSearch AskUserQuestion'
}

# ENG-51: read a per-stage tool-extension list from CONFIG and emit a
# comma-joined string ready to splice onto the hardcoded base. Returns
# empty string when the key is missing, the value isn't an array, or
# the array contains no strings. Defensive jq filter — non-string
# entries are silently dropped rather than poisoning the allowlist.
_dispatch_tools_extras() {
  local stage="$1"
  [[ -f "${CONFIG:-}" ]] || return 0
  jq -r --arg s "$stage" '
    (.dispatch.tools[$s] // []) as $arr
    | if ($arr | type) == "array"
      then $arr | map(select(type == "string")) | join(",")
      else "" end
  ' "$CONFIG" 2>/dev/null || true
}

allowed_tools_for() {
  # Every stage gets BOTH `Bash(bash .pipeline/bin/linear.sh:*)` AND
  # `Bash(bash bin/linear.sh:*)` so agents can post Linear comments
  # regardless of whether the worktree has the harness symlinked at
  # `.pipeline/` (target repos) or carries the harness scripts directly
  # at `bin/` (the harness driving itself). Without the second path, the
  # harness-self path leaves agents with no allowed way to post their
  # mandatory end-of-stage Linear comment, and they halt with a
  # protocol-violation/no-marker. MCP Linear remains available in
  # parallel; this guarantees a bash fallback works on either layout.
  # Same dual-path pattern applied to slug-aware bin/* invocations
  # (slack.sh, guards.sh, metrics.sh) for consistency.
  #
  # ENG-51: the hardcoded base preserves Tauri's behavior. Per-stage
  # extras come from config.json::dispatch.tools.<stage>[] and are
  # appended (not replaced) so a non-Tauri target can grant `pytest`,
  # `go test`, `bash bin/*-test.sh`, etc., without rewriting the base.
  local base
  case "$1" in
    # Canonical gerund-form stage names.
    brainstorming)  base='Read,Write,Edit,Grep,Glob,TaskCreate,WebFetch,Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
    planning)       base='Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git log:*),Bash(git diff:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
    implementing)   base='Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(rustc:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
    ui)             base='Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
    reviewing)      base='Read,Write,Grep,Glob,TaskCreate,Agent,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr list:*),Bash(gh pr review:*),Bash(gh pr comment:*),Bash(gh issue create:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
    qa)             base='Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh issue create:*),Bash(gh issue list:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
    building)       base='Read,Write,Grep,Glob,Bash(git fetch:*),Bash(git clone:*),Bash(git rebase:*),Bash(gh run:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr checks:*),Bash(gh pr edit:*),Bash(gh pr merge:*),Bash(jq:*),Bash(mktemp:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),Bash(bash .pipeline/bin/slack.sh:*),Bash(bash bin/slack.sh:*)' ;;
    released)       base='Read,Grep,Glob,Bash(git log:*),Bash(git show:*),Bash(git rev-list:*),Bash(git describe:*),Bash(gh release view:*),Bash(gh release list:*),Bash(jq:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
    retrospective)  base='Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git log:*),Bash(git diff:*),Bash(git show:*),Bash(git rev-list:*),Bash(git describe:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),Bash(bash .pipeline/bin/guards.sh:*),Bash(bash bin/guards.sh:*),Bash(bash .pipeline/bin/metrics.sh:*),Bash(bash bin/metrics.sh:*)' ;;
    *)              die "no allowed-tools profile for stage: $1" ;;
  esac
  local extras
  extras="$(_dispatch_tools_extras "$1")"
  if [[ -n "$extras" ]]; then
    printf '%s,%s' "$base" "$extras"
  else
    printf '%s' "$base"
  fi
}

main() {
  local stage="${1:-}" prompt_file="${2:-}" log_file="${3:-}"
  [[ -n "$stage" && -n "$prompt_file" ]] || die "usage: dispatch.sh <stage> <prompt_file> [<log_file>]"
  [[ -f "$prompt_file" ]] || die "prompt file not found: $prompt_file"

  local tools
  tools="$(allowed_tools_for "$stage")"

  # Resolve the per-stage usage-file path. Empty string when
  # PIPELINE_ISSUE_ID is unset (release / retrospective / dry-run-self-check
  # / mutex-test): the renderer block is then bypassed and the live pipe
  # keeps its pre-ENG-26 shape. Resolution lives inside main() because
  # $stage is local to main (D-012 / F-IT3-001).
  local usage_file=""
  local issue_state_dir=""
  if [[ -n "${PIPELINE_ISSUE_ID:-}" ]]; then
    issue_state_dir="$(issue_dir "$PIPELINE_ISSUE_ID")"
    usage_file="${issue_state_dir}/usage-${stage}.json"
    # Pre-emptive cleanup so a missing file is the canonical "no usage to
    # report" signal — applies to BOTH branches below (E-04 / D-006).
    rm -f "$usage_file"
  fi

  acquire_claude_mutex
  trap 'release_claude_mutex' EXIT

  local denies
  denies="$(disallowed_platform_tools)"

  # ENG-48/ENG-65 watchdog budget. Brainstorming/planning iterate through
  # ≤2 persona-review passes that legitimately span >30 min; everything
  # else stays at the historical 30-min cap. Resolution precedence:
  #   1. orchestrator.dispatch_timeout_minutes_per_stage[<stage>]  (ENG-65)
  #   2. orchestrator.dispatch_timeout_minutes                     (ENG-48)
  #   3. per-stage built-in default (60 for brainstorm/plan, 30 otherwise)
  # A non-integer value at layer 1 or 2 falls through. A 0 minute resolved
  # value would disable the wrapper (gtimeout's no-timeout sentinel) so it
  # is rejected explicitly, restoring the per-stage built-in default. The
  # CONFIG read is defensive — the mutex-test contract assumes dispatch.sh
  # needs TARGET_REPO only for the directory-existence check, not for a
  # real config.json.
  local timeout_minutes
  case "$stage" in
    brainstorming|planning) timeout_minutes=60 ;;
    *)                      timeout_minutes=30 ;;
  esac
  if [[ -f "$CONFIG" ]]; then
    local _cfg_minutes
    _cfg_minutes="$(jq -r --arg s "$stage" \
      '.orchestrator.dispatch_timeout_minutes_per_stage[$s] // empty' \
      "$CONFIG" 2>/dev/null || true)"
    if [[ -z "$_cfg_minutes" ]]; then
      _cfg_minutes="$(jq -r '.orchestrator.dispatch_timeout_minutes // empty' "$CONFIG" 2>/dev/null || true)"
    fi
    [[ -n "$_cfg_minutes" && "$_cfg_minutes" =~ ^[0-9]+$ ]] && timeout_minutes="$_cfg_minutes"
  fi
  if (( timeout_minutes < 1 )); then
    case "$stage" in
      brainstorming|planning) timeout_minutes=60 ;;
      *)                      timeout_minutes=30 ;;
    esac
  fi
  local timeout_seconds=$(( timeout_minutes * 60 ))

  if [[ "$PIPELINE_DRY_RUN" == "1" ]]; then
    log "[DRY_RUN] would invoke: gtimeout --signal=TERM --kill-after=10 ${timeout_seconds} claude -p --output-format stream-json --verbose --setting-sources project,local --disable-slash-commands --disallowed-tools \"$denies\" --allowed-tools \"$tools\" < $prompt_file"
    log "[DRY_RUN] prompt preview (first 500 chars):"
    head -c 500 "$prompt_file" >&2
    printf '\n' >&2
    return 0
  fi

  require_bin claude gtimeout
  # Auth: ANTHROPIC_API_KEY for CI/headless; claude CLI subscription session for local.
  # Don't require either here — claude errors at invocation time if no auth is available.
  # gtimeout: GNU coreutils. macOS operators install via `brew install coreutils`.

  # ENG-41 T3: set the agent lane only for the claude -p subprocess.
  # Any orchestrator-side Linear writes above (none currently, but guarding for
  # future additions) stay in the default orchestrator lane.
  # ENG-26: `--output-format stream-json --verbose` emits one NDJSON event
  # per message and a final `{"type":"result", …}` carrying total_cost_usd
  # and the aggregated `usage` block. The renderer extracts cost; the
  # operator-facing log keeps prose-ish progress lines via the renderer's
  # stdout (D-002 / F3 / F4).
  # ENG-48: --setting-sources project,local skips ~/.claude (so the
  # operator's installed plugins and SessionStart hooks don't fire);
  # --disable-slash-commands blocks skill auto-load (using-superpowers,
  # /loop, etc.); --disallowed-tools denies platform tools that aren't
  # in any stage's allowlist and could enable a runaway (ScheduleWakeup
  # was the demonstrated escape on 2026-04-28). gtimeout wraps claude
  # with a wall-clock budget — on expiry SIGTERM is sent, then SIGKILL
  # after 10s if claude ignores the term. gtimeout's exit 124 propagates
  # via the pipeline (set -o pipefail) so failure_outcome_for_exit can
  # classify it as dispatch-timeout.
  local cmd=(env PIPELINE_WRITER=agent
    gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
    claude -p
    --output-format stream-json --verbose
    --setting-sources project,local
    --disable-slash-commands
    --disallowed-tools "$denies"
    --allowed-tools "$tools"
  )
  if [[ -n "$log_file" ]]; then
    mkdir -p "$(dirname "$log_file")"
    log "dispatching stage=$stage, log=$log_file"
    # Renderer prose (and raw stream-json on the no-renderer branch) lands in
    # the per-stage log only. Letting it bubble up to local-*.log via `tee`
    # duplicates every [tool] / [tool-result] line into the orchestrator's
    # day-log, which (post-ENG-26 stream-json renderer) made local-*.log
    # nearly unreadable on busy days.
    if [[ -n "$usage_file" && -n "$issue_state_dir" ]]; then
      "${cmd[@]}" < "$prompt_file" \
        | _render_and_capture_stream "$usage_file" "$issue_state_dir" "$stage" \
        > "$log_file"
    else
      "${cmd[@]}" < "$prompt_file" > "$log_file"
    fi
  else
    log "dispatching stage=$stage"
    if [[ -n "$usage_file" && -n "$issue_state_dir" ]]; then
      "${cmd[@]}" < "$prompt_file" \
        | _render_and_capture_stream "$usage_file" "$issue_state_dir" "$stage"
    else
      "${cmd[@]}" < "$prompt_file"
    fi
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
