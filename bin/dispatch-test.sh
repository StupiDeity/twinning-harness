#!/usr/bin/env bash
# Tests for dispatch.sh.
#
# Group 1 (ENG-41 T7): allowed-tools-linear-mcp — verify no stage's allowed-tools
#   list includes mcp__*linear* tool names (A-002 assumption).
# Group 2 (ENG-41 T7): PIPELINE_WRITER env-propagation — verify dispatch.sh
#   overrides parent PIPELINE_WRITER to "agent" when invoking claude -p
#   (A-003 assumption).
# Group 3 (ENG-26 Task 5 / brainstorm D-002): _render_and_capture_stream
#   stream-json renderer fixtures A-E. See block comments above each fixture.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"

# ─── Temp dirs ──────────────────────────────────────────────────────────
_TEST_TARGET_DIR="$(mktemp -d)"
_TEST_STUB_DIR="$(mktemp -d)"

_test_assert_temp_path() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
    *) printf 'REFUSING: path %q is not a platform temp dir\n' "$1" >&2; exit 99 ;;
  esac
}
_test_assert_temp_path "$_TEST_TARGET_DIR"
_test_assert_temp_path "$_TEST_STUB_DIR"

_test_safe_rm() {
  local path="$1"
  case "$path" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*)
      rm -rf "$path" ;;
    *)
      printf 'SAFETY: trap refusing rm -rf %q (not a temp dir)\n' "$path" >&2 ;;
  esac
}
trap '_test_safe_rm "$_TEST_STUB_DIR"; _test_safe_rm "$_TEST_TARGET_DIR"' EXIT

# ─── Minimal target-repo scaffold ────────────────────────────────────────
export TARGET_REPO="$_TEST_TARGET_DIR"
mkdir -p "$TARGET_REPO/.pipeline-config/schemas"

jq -n '{
  project: { slug: "test-slug" },
  linear: {
    team_id: "team-test",
    project_id: "proj-test",
    stage_label_prefix: "stage:",
    native_states: { inbox: "Todo", active: "In Progress", done: "Done" },
    workflow_stages: ["brainstorming","planning","implementing","ui","reviewing","qa","building","released"]
  },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5 }
}' > "$TARGET_REPO/.pipeline-config/config.json"

jq -n '{ labels: {}, states: {} }' > "$TARGET_REPO/.pipeline-config/schemas/linear-ids.json"

export HARNESS_STATE_DIR="$_TEST_STUB_DIR/state"
export PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
mkdir -p "$PROJECT_STATE_DIR"
ISSUE_DIR="${PROJECT_STATE_DIR}/ENG-T-COST"
mkdir -p "$ISSUE_DIR"

# ─── Source dispatch.sh (no main due to sentinel) ────────────────────────
# shellcheck source=dispatch.sh
source "$SCRIPT_DIR/dispatch.sh"

# ─── Assertion helpers ───────────────────────────────────────────────────
PASS=0; FAIL=0
fail_at() { printf '  FAIL %s\n      %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }
pass_at() { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }

# ─── Group 1: allowed-tools exclude Linear MCP ──────────────────────────
printf '\n--- allowed-tools: no mcp__*linear* in any stage ---\n'

for stage in brainstorm plan implement ui review qa build release; do
  tools="$(allowed_tools_for "$stage" 2>/dev/null)"
  # Check for any mcp__*linear* substring (case-insensitive match for safety)
  if printf '%s' "$tools" | grep -qi 'mcp__.*linear'; then
    fail_at "stage=$stage: allowed-tools must not include mcp__*linear* tools" \
      "found: $(printf '%s' "$tools" | grep -oi 'mcp__[^,]*linear[^,]*' || true)"
  else
    pass_at "stage=$stage: no mcp__*linear* in allowed-tools"
  fi

  # Both linear.sh paths must be present so harness-self (bin/) and
  # target-symlinked (.pipeline/bin/) layouts both work.
  if ! printf '%s' "$tools" | grep -q 'Bash(bash \.pipeline/bin/linear\.sh:\*)'; then
    fail_at "stage=$stage: missing Bash(bash .pipeline/bin/linear.sh:*) in allowed-tools" \
      "tools=$tools"
  elif ! printf '%s' "$tools" | grep -q 'Bash(bash bin/linear\.sh:\*)'; then
    fail_at "stage=$stage: missing Bash(bash bin/linear.sh:*) in allowed-tools" \
      "tools=$tools"
  else
    pass_at "stage=$stage: both linear.sh paths present (.pipeline/ + harness-self)"
  fi
done

# ENG-49 Gap #1: UI allowlist no longer contains gh pr create.
ui_tools="$(allowed_tools_for ui)"
if [[ "$ui_tools" != *"gh pr create"* ]]; then
  pass_at "ENG-49: ui allowlist drops gh pr create"
else
  fail_at "ENG-49: ui allowlist drops gh pr create" "ui tools: $ui_tools"
fi

# ─── Group 2: PIPELINE_WRITER env propagation ───────────────────────────
printf '\n--- PIPELINE_WRITER=agent propagated to claude -p invocation ---\n'

# Create a stub for 'claude' that captures its environment AND its argv.
ENV_CAPTURE="$_TEST_STUB_DIR/env.capture"
ARGV_CAPTURE="$_TEST_STUB_DIR/argv.capture"
: > "$ENV_CAPTURE"
: > "$ARGV_CAPTURE"

cat > "$_TEST_STUB_DIR/claude" <<SH
#!/usr/bin/env bash
# Stub: capture PIPELINE_WRITER from the environment, capture argv (one arg
# per line) for ENG-48 isolation-flag assertions, then exit 0.
printf 'PIPELINE_WRITER=%s\n' "\${PIPELINE_WRITER:-<unset>}" >> "$ENV_CAPTURE"
printf '%s\n' "\$@" > "$ARGV_CAPTURE"
# Consume stdin (like real claude would) so the caller's pipe doesn't break.
cat > /dev/null
exit 0
SH
chmod +x "$_TEST_STUB_DIR/claude"

# ENG-48 watchdog: the production cmd wraps claude with `gtimeout
# --signal=TERM --kill-after=10 <seconds> claude ...`. Provide a thin
# pass-through stub so the existing claude stub still receives the inner
# argv unchanged for Group 2 / Group 4 assertions.
cat > "$_TEST_STUB_DIR/gtimeout" <<'SH'
#!/usr/bin/env bash
# Skip --signal=…, --kill-after=… flags, then the seconds arg, then exec
# the inner command.
while (( $# > 0 )); do
  case "$1" in
    --signal=*|--kill-after=*) shift ;;
    *) break ;;
  esac
done
# Next arg is the timeout in seconds — eat it.
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then shift; fi
exec "$@"
SH
chmod +x "$_TEST_STUB_DIR/gtimeout"

# Create a minimal prompt file.
_PROMPT_FILE="$_TEST_STUB_DIR/test-prompt.txt"
printf 'test prompt\n' > "$_PROMPT_FILE"

# Override PATH so our stub 'claude' is found first.
# Also set PIPELINE_WRITER to a value that must NOT propagate — dispatch.sh
# must override it to "agent" before invoking claude.
OLD_PATH="$PATH"
export PATH="$_TEST_STUB_DIR:$PATH"

# Set a canary value in the parent; dispatch.sh must override it.
export PIPELINE_WRITER="canary-parent-lane"

# Run dispatch main in a subshell to isolate mutex and PATH side effects.
# Set PIPELINE_DRY_RUN=0 (not unset) so dispatch.sh's [[ "$PIPELINE_DRY_RUN" == "1" ]]
# check works correctly under set -euo pipefail without triggering the unbound-var guard.
# Suppress the "dispatching stage=..." log line.
( PIPELINE_DRY_RUN=0 PIPELINE_WRITER="canary-parent-lane" main "brainstorm" "$_PROMPT_FILE" 2>/dev/null ) || true

export PATH="$OLD_PATH"

# Check what PIPELINE_WRITER value the stub saw.
if [[ -f "$ENV_CAPTURE" ]]; then
  captured_val="$(grep '^PIPELINE_WRITER=' "$ENV_CAPTURE" | head -1 | cut -d= -f2 || true)"
else
  captured_val=""
fi

if [[ "$captured_val" == "agent" ]]; then
  pass_at "PIPELINE_WRITER=agent was set in claude -p environment (parent had 'canary-parent-lane')"
else
  fail_at "PIPELINE_WRITER=agent was set in claude -p environment" \
    "claude saw PIPELINE_WRITER='${captured_val:-<nothing captured>}' (parent had 'canary-parent-lane')"
fi

# ─── Group 4 (ENG-48): isolation flags reach claude -p invocation ────────
# A 2026-04-28 wedged tick traced to the operator's superpowers plugin's
# SessionStart hook firing inside `claude -p`. Headless dispatches must
# neutralize user-level config:
#   --setting-sources project,local  → skip ~/.claude (plugins, hooks)
#   --disable-slash-commands         → block skill auto-load
#   --disallowed-tools <list>        → deny platform tools that aren't
#                                       in any stage's allowed-tools list
#                                       and whose call would let the agent
#                                       self-loop (ScheduleWakeup), self-
#                                       coordinate (TodoWrite), enter plan
#                                       mode (EnterPlanMode), etc.
# This group asserts the constructed claude argv carries those flags,
# using the argv capture seeded by the stub above.
printf '\n--- ENG-48: isolation flags reach claude -p invocation ---\n'

# --setting-sources project,local
if grep -Fxq -- '--setting-sources' "$ARGV_CAPTURE" \
   && grep -Fxq -- 'project,local' "$ARGV_CAPTURE"; then
  pass_at "--setting-sources project,local present in claude argv"
else
  fail_at "--setting-sources project,local missing from claude argv" \
    "argv: $(tr '\n' ' ' < "$ARGV_CAPTURE")"
fi

# --disable-slash-commands
if grep -Fxq -- '--disable-slash-commands' "$ARGV_CAPTURE"; then
  pass_at "--disable-slash-commands present in claude argv"
else
  fail_at "--disable-slash-commands missing from claude argv" \
    "argv: $(tr '\n' ' ' < "$ARGV_CAPTURE")"
fi

# --disallowed-tools must list every platform tool that demonstrated or
# could enable a runaway in a headless dispatch. The value follows the
# flag as the next arg.
disallowed_idx="$(grep -nFx -- '--disallowed-tools' "$ARGV_CAPTURE" | head -1 | cut -d: -f1 || true)"
if [[ -z "$disallowed_idx" ]]; then
  fail_at "--disallowed-tools flag missing from claude argv" \
    "argv: $(tr '\n' ' ' < "$ARGV_CAPTURE")"
else
  disallowed_value="$(sed -n "$((disallowed_idx + 1))p" "$ARGV_CAPTURE")"
  # Task / WebFetch deliberately excluded: Task may alias the Agent tool
  # used by ui/review/qa/retrospective stages, and brainstorm's allowed-
  # tools includes WebFetch. Denials win over allows in claude's tool-
  # resolution.
  required_denies=(
    ScheduleWakeup TodoWrite Skill
    EnterPlanMode ExitPlanMode EnterWorktree ExitWorktree
    RemoteTrigger PushNotification
    CronCreate CronDelete CronList Monitor
    WebSearch ToolSearch AskUserQuestion
  )
  missing_denies=()
  for required in "${required_denies[@]}"; do
    grep -qw -- "$required" <<<"$disallowed_value" || missing_denies+=("$required")
  done
  if (( ${#missing_denies[@]} == 0 )); then
    pass_at "--disallowed-tools denies all required platform tools (${#required_denies[@]} entries)"
  else
    fail_at "--disallowed-tools missing required denies" \
      "missing: ${missing_denies[*]} | value: $disallowed_value"
  fi
fi

# Regression: --allowed-tools must STILL appear (the existing per-stage
# allowlist contract from Group 1 must not be silently dropped during
# the isolation-flag refactor).
if grep -Fxq -- '--allowed-tools' "$ARGV_CAPTURE"; then
  pass_at "--allowed-tools regression: per-stage allowlist contract preserved"
else
  fail_at "--allowed-tools regression: flag dropped from claude argv" \
    "argv: $(tr '\n' ' ' < "$ARGV_CAPTURE")"
fi

# ─── Group 5 (ENG-48): wall-clock watchdog wraps claude -p ──────────────
# A dispatch that enters a self-loop (e.g. ScheduleWakeup re-firing) must
# be SIGTERM'd by the orchestrator within a bounded budget — operator
# intervention should never be required to free the run-local lock. The
# wrapper is `gtimeout` (GNU coreutils on macOS via brew); the budget is
# read from config.json::orchestrator.dispatch_timeout_minutes (default
# 30 min = 1800s). The dispatched cmd's exit 124 (gtimeout's SIGTERM
# convention) will be mapped by failure_outcome_for_exit in a separate
# commit.
printf '\n--- ENG-48: gtimeout watchdog wraps claude -p ---\n'

DRYRUN_OUT="$_TEST_STUB_DIR/dryrun.out"
PIPELINE_DRY_RUN=1 \
  bash "$SCRIPT_DIR/dispatch.sh" brainstorm "$_PROMPT_FILE" 2>"$DRYRUN_OUT" >/dev/null || true

# Default budget (config has no override): 30 min = 1800s.
if grep -qE 'gtimeout.*\b1800\b' "$DRYRUN_OUT"; then
  pass_at "dry-run log: gtimeout wrapper with default 30-min (1800s) budget"
else
  fail_at "dry-run log missing gtimeout wrapper or default budget" \
    "log: $(cat "$DRYRUN_OUT")"
fi

# --signal=TERM and --kill-after=10 must both be present so the wrapper
# escalates from SIGTERM to SIGKILL after 10s if the dispatched claude
# refuses to exit (defensive escalation, not the common case).
if grep -qE 'gtimeout.*--signal=TERM' "$DRYRUN_OUT" \
   && grep -qE 'gtimeout.*--kill-after=10' "$DRYRUN_OUT"; then
  pass_at "dry-run log: gtimeout uses --signal=TERM --kill-after=10 escalation"
else
  fail_at "dry-run log missing gtimeout signal/kill-after escalation flags" \
    "log: $(cat "$DRYRUN_OUT")"
fi

# Custom budget — when orchestrator.dispatch_timeout_minutes is overridden
# (e.g. to 5 for a stage that legitimately runs short), the wrapper
# picks it up.
TARGET_REPO_CUSTOM="$_TEST_STUB_DIR/target-custom"
mkdir -p "$TARGET_REPO_CUSTOM/.pipeline-config/schemas"
jq -n '{
  project: { slug: "custom-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5, dispatch_timeout_minutes: 5 }
}' > "$TARGET_REPO_CUSTOM/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$TARGET_REPO_CUSTOM/.pipeline-config/schemas/linear-ids.json"

DRYRUN_OUT_C="$_TEST_STUB_DIR/dryrun-custom.out"
PIPELINE_DRY_RUN=1 \
TARGET_REPO="$TARGET_REPO_CUSTOM" \
PROJECT_SLUG="custom-slug" \
HARNESS_STATE_DIR="$HARNESS_STATE_DIR" \
PROJECT_STATE_DIR="$HARNESS_STATE_DIR/custom-slug" \
LINEAR_API_KEY="$LINEAR_API_KEY" \
  bash "$SCRIPT_DIR/dispatch.sh" brainstorm "$_PROMPT_FILE" 2>"$DRYRUN_OUT_C" >/dev/null || true

if grep -qE 'gtimeout.*\b300\b' "$DRYRUN_OUT_C"; then
  pass_at "dry-run log honors config orchestrator.dispatch_timeout_minutes=5 (300s)"
else
  fail_at "dry-run log did not pick up custom dispatch_timeout_minutes" \
    "log: $(cat "$DRYRUN_OUT_C")"
fi

# ─── Group 3: stream-json renderer fixtures (ENG-26 Task 5) ──────────────
# Five fixtures:
#   A — success path: NDJSON with a final `result` event yields the six-field
#       usage file at mode 0600, with no leaked session_id / result text.
#   B — no-result path: NDJSON ends mid-stream; no usage file, soft-fail log.
#   C — malformed-line tolerance: a literal `{not json{` between valid events
#       does not abort the renderer; the result event is still extracted.
#   D — log-forge defense: a `\r[FAKE LOG]` byte in agent text is stripped
#       to a space before reaching renderer stdout (SEC-010).
#   E — dry-run stale-file removal: a pre-existing usage file is removed by
#       the dry-run branch's `rm -f` at function entry (E-04 / D-006).

printf '\n--- _render_and_capture_stream renderer fixtures (A-E) ---\n'

if ! declare -f _render_and_capture_stream >/dev/null 2>&1; then
  fail_at "precondition: _render_and_capture_stream is defined in dispatch.sh" \
          "function not found after sourcing — Task 2 implementation missing"
  printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# Renderer needs PIPELINE_DRY_RUN=0 so it actually exercises the code path
# (the dry-run guard short-circuits dispatch::main before the renderer).
PIPELINE_DRY_RUN=0
export PIPELINE_DRY_RUN

# ─── Fixture A: success path ───────────────────────────────────────────────
USAGE_A="$ISSUE_DIR/usage-plan.json"
RAW_A="$ISSUE_DIR/.raw-stream.ndjson.tmp"
rm -f "$USAGE_A" "$RAW_A"
RENDER_OUT_A="$(
  _render_and_capture_stream "$USAGE_A" "$ISSUE_DIR" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"a97ddba2-aaaa-bbbb-cccc-dddddddddddd","model":"claude-opus-4-7[1m]"}
{"type":"assistant","message":{"content":[{"type":"text","text":"hello world"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"path":"/etc/passwd","SECRET_BYTES":"do-not-log"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_01abcd1234ef","content":"file contents"}]}}
{"type":"result","total_cost_usd":0.11943025,"usage":{"input_tokens":5,"output_tokens":6,"cache_creation_input_tokens":17419,"cache_read_input_tokens":20773},"modelUsage":{"claude-opus-4-7[1m]":{"inputTokens":5}},"session_id":"a97ddba2-aaaa-bbbb-cccc-dddddddddddd","permission_denials":[],"result":"VERBATIM_FINAL_ASSISTANT_TEXT_DO_NOT_LEAK"}
NDJSON
)"

# Six-field usage file, no leaks.
keys_a="$(jq -r 'keys | sort | join(",")' "$USAGE_A" 2>/dev/null || printf '')"
expected_keys="cache_create,cache_read,cost_usd,model,tokens_in,tokens_out"
mode_a="$(stat -f '%A' "$USAGE_A" 2>/dev/null || stat -c '%a' "$USAGE_A" 2>/dev/null || printf '')"
has_session="$(jq -r 'has("session_id")' "$USAGE_A" 2>/dev/null || printf 'true')"
has_result_text="$(jq -r 'has("result")' "$USAGE_A" 2>/dev/null || printf 'true')"
model_a="$(jq -r '.model' "$USAGE_A" 2>/dev/null || printf '')"

if [[ "$keys_a" == "$expected_keys" ]] \
   && [[ "$mode_a" == "600" ]] \
   && [[ "$has_session" == "false" ]] \
   && [[ "$has_result_text" == "false" ]] \
   && [[ "$model_a" == "claude-opus-4-7[1m]" ]]; then
  pass_at "fixture-A success: six fields, mode 600, no session_id/result leak, model literal preserved"
else
  fail_at "fixture-A success" "keys=$keys_a mode=$mode_a session=$has_session result=$has_result_text model=$model_a"
fi

# Renderer stdout shape — prose lines must NOT be JSON-quoted (jq -r contract).
# Each non-empty line must not begin with a `"` (which is what would happen
# if `jq -nR` ran without `-r`).
prose_unquoted="yes"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  if [[ "${line:0:1}" == '"' ]]; then
    prose_unquoted="no:$line"
    break
  fi
done <<<"$RENDER_OUT_A"

if   [[ "$prose_unquoted" == "yes" ]] \
  && grep -q '\[claude\] session=a97ddba2'      <<<"$RENDER_OUT_A" \
  && grep -q 'hello world'                       <<<"$RENDER_OUT_A" \
  && grep -q '\[tool\] Read'                     <<<"$RENDER_OUT_A" \
  && grep -q '\[tool-result\]'                   <<<"$RENDER_OUT_A" \
  && ! grep -q 'SECRET_BYTES'                    <<<"$RENDER_OUT_A" \
  && ! grep -q 'do-not-log'                      <<<"$RENDER_OUT_A" \
  && ! grep -q 'VERBATIM_FINAL_ASSISTANT_TEXT'   <<<"$RENDER_OUT_A"; then
  pass_at "fixture-A stdout: prose lines emitted unquoted, tool_use input bytes never logged (SEC-001)"
else
  fail_at "fixture-A stdout" "unquoted=$prose_unquoted out=$RENDER_OUT_A"
fi

# Renderer stdout shape — raw vs JSON-quoted (D-002 / F3 contract).
# `jq -n` without `-r` emits string outputs as JSON-encoded values, so
# `[claude] session=...` becomes `"[claude] session=..."` (literal
# surrounding double-quote bytes) on stdout. The downstream
# `tee "$log_file"` then captures JSON-quoted prose, breaking the
# brainstorm's "prose-ish progress lines on STDOUT" contract.
# Catch the regression by asserting no prose line begins with `"`.
if ! grep -qE '^"' <<<"$RENDER_OUT_A"; then
  pass_at "fixture-A stdout: prose lines emitted raw, not JSON-quoted (D-002 / F3)"
else
  fail_at "fixture-A stdout JSON-quoted" "rendered prose line starts with '\"' (missing -r flag on jq?); first offending=$(grep -m1 -E '^"' <<<"$RENDER_OUT_A")"
fi

# Intermediate raw-capture cleaned by RETURN trap.
if [[ ! -e "$RAW_A" ]]; then
  pass_at "fixture-A trap: .raw-stream.ndjson.tmp removed on RETURN"
else
  fail_at "fixture-A trap" "raw_capture still exists: $RAW_A"
fi

# ─── Fixture B: no result event (mid-stream end) ──────────────────────────
USAGE_B="$ISSUE_DIR/usage-plan-B.json"
rm -f "$USAGE_B" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
RENDER_OUT_B="$(
  _render_and_capture_stream "$USAGE_B" "$ISSUE_DIR" 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"deadbeef-no-result","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}
NDJSON
)"

if [[ ! -e "$USAGE_B" ]] && grep -q 'no result event found in stream' <<<"$RENDER_OUT_B"; then
  pass_at "fixture-B no-result: usage file not written; soft-fail warning logged"
else
  fail_at "fixture-B no-result" "exists=$([[ -e $USAGE_B ]] && echo y || echo n) out=$RENDER_OUT_B"
fi

# ─── Fixture C: malformed line tolerance ───────────────────────────────────
USAGE_C="$ISSUE_DIR/usage-plan-C.json"
rm -f "$USAGE_C" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
_render_and_capture_stream "$USAGE_C" "$ISSUE_DIR" >/dev/null 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"01234567","model":"claude-opus-4-7"}
{not json{
{"type":"assistant","message":{"content":[{"type":"text","text":"after garbage"}]}}
{"type":"result","total_cost_usd":0.5,"usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON

keys_c="$(jq -r 'keys | sort | join(",")' "$USAGE_C" 2>/dev/null || printf '')"
cost_c="$(jq -r '.cost_usd' "$USAGE_C" 2>/dev/null || printf '')"
if [[ "$keys_c" == "$expected_keys" ]] && [[ "$cost_c" == "0.5" ]]; then
  pass_at "fixture-C malformed-line: garbage NDJSON line silently dropped; result still extracted"
else
  fail_at "fixture-C malformed-line" "keys=$keys_c cost=$cost_c"
fi

# ─── Fixture D: log-forge defense (SEC-010) ───────────────────────────────
# Embed a literal CR byte in agent text. The renderer's strip_ctrl jq
# function must replace C0 control chars with " " before they reach stdout.
USAGE_D="$ISSUE_DIR/usage-plan-D.json"
rm -f "$USAGE_D" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
RENDER_OUT_D="$(
  _render_and_capture_stream "$USAGE_D" "$ISSUE_DIR" <<NDJSON
{"type":"system","subtype":"init","session_id":"cafebabecafebabe","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"text","text":"safe text\rPWNED"}]}}
{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON
)"

# `safe text\rPWNED` after C0-strip becomes `safe text PWNED`. Assert no
# raw CR byte made it to stdout.
if ! printf '%s' "$RENDER_OUT_D" | grep -q $'\r'; then
  pass_at "fixture-D log-forge: CR byte stripped from renderer stdout (SEC-010)"
else
  fail_at "fixture-D log-forge" "stdout still contains raw CR"
fi

# ─── Fixture E: dry-run stale-file removal (E-04 / D-006) ─────────────────
USAGE_E="$ISSUE_DIR/usage-plan-E.json"
printf '{"stale":true}' > "$USAGE_E"
[[ -s "$USAGE_E" ]] || die "fixture-E setup failed (could not seed stale file)"

PROMPT_FILE="$_TEST_STUB_DIR/dry-prompt.txt"
printf 'irrelevant\n' > "$PROMPT_FILE"

# Run dispatch.sh in dry-run mode against a stage that maps onto USAGE_E.
# dispatch.sh dies on an unknown stage's allowed_tools_for, so use a real
# stage and rename the seed file to match `usage-${stage}.json`.
mv "$USAGE_E" "$ISSUE_DIR/usage-plan.json"
USAGE_E="$ISSUE_DIR/usage-plan.json"
[[ -s "$USAGE_E" ]] || die "fixture-E rename failed"

PIPELINE_DRY_RUN=1 \
PIPELINE_ISSUE_ID="ENG-T-COST" \
HARNESS_STATE_DIR="$HARNESS_STATE_DIR" \
PROJECT_STATE_DIR="$PROJECT_STATE_DIR" \
PROJECT_SLUG="$PROJECT_SLUG" \
TARGET_REPO="$TARGET_REPO" \
LINEAR_API_KEY="$LINEAR_API_KEY" \
  bash "$SCRIPT_DIR/dispatch.sh" plan "$PROMPT_FILE" >/dev/null 2>&1 || true

if [[ ! -e "$USAGE_E" ]]; then
  pass_at "fixture-E dry-run: pre-existing usage-plan.json removed at dispatch entry"
else
  fail_at "fixture-E dry-run" "stale file still present: $(cat "$USAGE_E")"
fi

# ─── QA-authored adversarial fixtures (NOT in plan's Failure Mode → Test Map) ─

# ─── Fixture F: multiple result events — last wins ─────────────────────────
# A reconnect or partial-write scenario can theoretically emit two top-level
# result events (e.g. claude restarts a subagent run). The renderer's
# `grep | tail -1` contract MUST select the LAST result event, not the
# first. Pin the behavior so a future refactor (e.g. switching to `head -1`
# or to a streaming jq filter that keeps the first match) fails this test.
USAGE_F="$ISSUE_DIR/usage-plan-F.json"
rm -f "$USAGE_F" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
_render_and_capture_stream "$USAGE_F" "$ISSUE_DIR" >/dev/null 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"00000001","model":"claude-opus-4-7"}
{"type":"result","total_cost_usd":0.10,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"first-model":{}}}
{"type":"result","total_cost_usd":0.99,"usage":{"input_tokens":2,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"second-model":{}}}
NDJSON

cost_f="$(jq -r '.cost_usd' "$USAGE_F" 2>/dev/null || printf '')"
model_f="$(jq -r '.model' "$USAGE_F" 2>/dev/null || printf '')"
if [[ "$cost_f" == "0.99" && "$model_f" == "second-model" ]]; then
  pass_at "fixture-F multiple result events: last wins (cost=0.99, model=second-model)"
else
  fail_at "fixture-F multiple result events" "cost=$cost_f model=$model_f"
fi

# ─── Fixture G: result event missing the `usage` block ─────────────────────
# A degraded result event (e.g. a CLI version that drops the usage rollup
# under failure) MUST still produce a six-field file with `// 0` defaults
# rather than crash. cost_usd and model survive even when usage is gone.
USAGE_G="$ISSUE_DIR/usage-plan-G.json"
rm -f "$USAGE_G" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
_render_and_capture_stream "$USAGE_G" "$ISSUE_DIR" >/dev/null 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"00000002","model":"claude-opus-4-7"}
{"type":"result","total_cost_usd":2.50,"modelUsage":{"degraded-model":{}}}
NDJSON

keys_g="$(jq -r 'keys | sort | join(",")' "$USAGE_G" 2>/dev/null || printf '')"
ti_g="$(jq -r '.tokens_in' "$USAGE_G" 2>/dev/null || printf '')"
# Numeric-equal compare (jq preserves the input's textual form: 2.50 stays 2.50,
# 2.5 stays 2.5 — both are numerically equal to 2.5).
co_eq_g="$(jq -r '.cost_usd == 2.5' "$USAGE_G" 2>/dev/null || printf 'false')"
mo_g="$(jq -r '.model' "$USAGE_G" 2>/dev/null || printf '')"
if [[ "$keys_g" == "$expected_keys" ]] \
   && [[ "$ti_g" == "0" ]] \
   && [[ "$co_eq_g" == "true" ]] \
   && [[ "$mo_g" == "degraded-model" ]]; then
  pass_at "fixture-G missing usage: six-field file written with token=0 defaults; cost+model survive"
else
  fail_at "fixture-G missing usage" "keys=$keys_g tokens_in=$ti_g cost_eq_2.5=$co_eq_g model=$mo_g"
fi

# ─── Fixture H: empty stdin (claude died before emitting anything) ─────────
# The renderer reads zero bytes; tee writes nothing; jq's `inputs` consumes
# nothing; grep finds no result event. Soft-fail: no usage file written.
USAGE_H="$ISSUE_DIR/usage-plan-H.json"
rm -f "$USAGE_H" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
RENDER_OUT_H="$(_render_and_capture_stream "$USAGE_H" "$ISSUE_DIR" </dev/null 2>&1)"
if [[ ! -e "$USAGE_H" ]] && grep -q 'no result event found in stream' <<<"$RENDER_OUT_H"; then
  pass_at "fixture-H empty stdin: usage file not written; soft-fail warning logged"
else
  fail_at "fixture-H empty stdin" "exists=$([[ -e $USAGE_H ]] && echo y || echo n) out=$RENDER_OUT_H"
fi

# ─── Fixture I: type:"result" substring inside assistant text (FALSE POSITIVE) ─
# An agent debugging this very feature could legitimately emit the literal text
# `{"type":"result","total_cost_usd":99999}` inside an assistant text payload
# (e.g. transcribing a stream-json sample for the user). The renderer's
# extraction is `grep '"type":"result"' raw_capture | tail -1` — a naive
# substring grep that matches anywhere on the line, including inside JSON-
# encoded `text` fields. The current renderer's tee writes one NDJSON event
# per line, so an inline `type":"result"` substring DOES appear on the
# assistant event's line, and `tail -1` would pick the LAST line — which is
# the real result event. Confirm the real cost is extracted (0.42), NOT the
# fake $99999 from the assistant's debug transcript. A future refactor that
# changes the extraction to "first match" or to a JSON-path filter that
# crawls .text fields would silently leak the fake value.
USAGE_I="$ISSUE_DIR/usage-plan-I.json"
rm -f "$USAGE_I" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
_render_and_capture_stream "$USAGE_I" "$ISSUE_DIR" >/dev/null 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"deadbeef","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Here is a fake stream-json sample I am debugging: {\"type\":\"result\",\"total_cost_usd\":99999,\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0},\"modelUsage\":{\"fake-model\":{}}}"}]}}
{"type":"result","total_cost_usd":0.42,"usage":{"input_tokens":5,"output_tokens":6,"cache_creation_input_tokens":17,"cache_read_input_tokens":20},"modelUsage":{"real-model":{}}}
NDJSON
cost_i="$(jq -r '.cost_usd' "$USAGE_I" 2>/dev/null || printf '')"
model_i="$(jq -r '.model' "$USAGE_I" 2>/dev/null || printf '')"
if [[ "$cost_i" == "0.42" ]] && [[ "$model_i" == "real-model" ]]; then
  pass_at "fixture-I substring false-positive: real result wins over inline 'type:\"result\"' in assistant text"
else
  fail_at "fixture-I substring false-positive" "cost=$cost_i (expected 0.42) model=$model_i (expected real-model)"
fi

# ─── Fixture J: zero-byte usage file race window (post-truncate, pre-write) ──
# A theoretical race: dispatch.sh's renderer truncates `>` the file but
# crashes before jq writes the body. A subsequent reader (`_cost_flags_for`
# or `_cost_footer`) MUST treat a zero-byte usage file the same as missing
# (soft-fail D-010), not as a parse error that bubbles up to the operator.
# Pin the renderer's behavior on a pre-existing zero-byte file: it should
# overwrite cleanly when a new stream arrives.
USAGE_J="$ISSUE_DIR/usage-plan-J.json"
rm -f "$USAGE_J" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
: > "$USAGE_J"  # zero-byte seed file
_render_and_capture_stream "$USAGE_J" "$ISSUE_DIR" >/dev/null 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"00000003","model":"claude-opus-4-7"}
{"type":"result","total_cost_usd":0.55,"usage":{"input_tokens":3,"output_tokens":4,"cache_creation_input_tokens":1,"cache_read_input_tokens":1},"modelUsage":{"recovered-model":{}}}
NDJSON
keys_j="$(jq -r 'keys | sort | join(",")' "$USAGE_J" 2>/dev/null || printf '')"
cost_j="$(jq -r '.cost_usd' "$USAGE_J" 2>/dev/null || printf '')"
if [[ "$keys_j" == "$expected_keys" ]] && [[ "$cost_j" == "0.55" ]]; then
  pass_at "fixture-J zero-byte seed: renderer overwrites cleanly with six-field payload"
else
  fail_at "fixture-J zero-byte seed" "keys=$keys_j cost=$cost_j"
fi

# ─── Fixture K: unknown future field in result event (forward-compat) ─────
# A future claude release may add fields like `thinking_tokens`, `priority`,
# or `request_id` to the result event. The renderer's six-field allowlist
# extraction (.usage.input_tokens, etc.) MUST silently ignore unknown top-
# level fields and unknown nested usage fields — never panic, never leak.
USAGE_K="$ISSUE_DIR/usage-plan-K.json"
rm -f "$USAGE_K" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
_render_and_capture_stream "$USAGE_K" "$ISSUE_DIR" >/dev/null 2>&1 <<'NDJSON'
{"type":"result","total_cost_usd":0.07,"usage":{"input_tokens":2,"output_tokens":3,"cache_creation_input_tokens":4,"cache_read_input_tokens":5,"thinking_tokens":999,"future_nested_field":"x"},"modelUsage":{"future-model":{}},"request_id":"req_abc","priority":"high","new_top_level_field":[1,2,3]}
NDJSON
keys_k="$(jq -r 'keys | sort | join(",")' "$USAGE_K" 2>/dev/null || printf '')"
has_request_id_k="$(jq -r 'has("request_id")' "$USAGE_K" 2>/dev/null || printf 'true')"
has_thinking_k="$(jq -r 'has("thinking_tokens")' "$USAGE_K" 2>/dev/null || printf 'true')"
if [[ "$keys_k" == "$expected_keys" ]] \
   && [[ "$has_request_id_k" == "false" ]] \
   && [[ "$has_thinking_k" == "false" ]]; then
  pass_at "fixture-K forward-compat: unknown future fields ignored; six-field allowlist enforced"
else
  fail_at "fixture-K forward-compat" "keys=$keys_k request_id=$has_request_id_k thinking=$has_thinking_k"
fi

# ─── Group 7: assert_no_tool_invocation fixtures (ENG-43, AS1-AS6) ────
# AS1-AS6 deliver the issue's fixtures E-J (renamed per brainstorm
# D-009 to avoid colliding with existing fixtures A-K above). Each
# fixture writes (or does not write) an NDJSON file under
# $_TEST_STUB_DIR/, calls assert_no_tool_invocation directly, and
# asserts the (rc, stdout) tuple. No claude invocation, no real renderer.
printf '\n--- assert_no_tool_invocation fixtures (AS1-AS6, ENG-43; issue fixtures E-J) ---\n'

if ! declare -f assert_no_tool_invocation >/dev/null 2>&1; then
  fail_at "precondition: assert_no_tool_invocation defined in dispatch.sh" \
          "function not found after sourcing — Task 1 implementation missing"
  printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# AS1 — issue fixture E: tool_use invoking gh pr create matches
TX_AS1="$_TEST_STUB_DIR/tx-as1.ndjson"
cat > "$TX_AS1" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"as1","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr create --title foo --body bar"}}]}}
NDJSON
out_as1="$(assert_no_tool_invocation "$TX_AS1" "gh pr create")" && rc_as1=0 || rc_as1=$?
if [[ "$rc_as1" == "1" && "$out_as1" == "gh pr create --title foo --body bar" ]]; then
  pass_at "AS1: tool_use match returns 1 + matched command on stdout"
else
  fail_at "AS1" "rc=$rc_as1 out=$out_as1"
fi

# AS2 — issue fixture F: only allowed tools (git, gh pr list, Read, Edit); rc=0
TX_AS2="$_TEST_STUB_DIR/tx-as2.ndjson"
cat > "$TX_AS2" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"as2","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git log --oneline -5"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr list --state open"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"path":"README.md"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"x"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}
NDJSON
out_as2="$(assert_no_tool_invocation "$TX_AS2" "gh pr create")" && rc_as2=0 || rc_as2=$?
if [[ "$rc_as2" == "0" && -z "$out_as2" ]]; then
  pass_at "AS2: only allowed tools (git/gh pr list/Read/Edit/empty) → rc=0, empty stdout"
else
  fail_at "AS2" "rc=$rc_as2 out=$out_as2"
fi

# AS3 — issue fixture G: text block with literal `gh pr create` prose ignored
TX_AS3="$_TEST_STUB_DIR/tx-as3.ndjson"
cat > "$TX_AS3" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"as3","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"text","text":"I considered gh pr create but used git instead."}]}}
NDJSON
out_as3="$(assert_no_tool_invocation "$TX_AS3" "gh pr create")" && rc_as3=0 || rc_as3=$?
if [[ "$rc_as3" == "0" && -z "$out_as3" ]]; then
  pass_at "AS3: text block prose with literal pattern → rc=0 (text blocks ignored)"
else
  fail_at "AS3" "rc=$rc_as3 out=$out_as3"
fi

# AS4 — issue fixture H: JSON-escaped quoted "gh pr create" inside text block ignored
TX_AS4="$_TEST_STUB_DIR/tx-as4.ndjson"
cat > "$TX_AS4" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"as4","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"text","text":"The doc says \"gh pr create\" is forbidden here."}]}}
NDJSON
out_as4="$(assert_no_tool_invocation "$TX_AS4" "gh pr create")" && rc_as4=0 || rc_as4=$?
if [[ "$rc_as4" == "0" && -z "$out_as4" ]]; then
  pass_at "AS4: JSON-escaped quoted pattern in text block → rc=0 (text blocks ignored)"
else
  fail_at "AS4" "rc=$rc_as4 out=$out_as4"
fi

# AS5 — issue fixture I: malformed JSON line skipped via fromjson?, subsequent match returned
TX_AS5="$_TEST_STUB_DIR/tx-as5.ndjson"
cat > "$TX_AS5" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"as5","model":"claude-opus-4-7"}
{not json{
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr create --draft"}}]}}
NDJSON
out_as5="$(assert_no_tool_invocation "$TX_AS5" "gh pr create")" && rc_as5=0 || rc_as5=$?
if [[ "$rc_as5" == "1" && "$out_as5" == "gh pr create --draft" ]]; then
  pass_at "AS5: malformed line skipped via fromjson?; subsequent match returns 1"
else
  fail_at "AS5" "rc=$rc_as5 out=$out_as5"
fi

# AS6 — issue fixture J: missing transcript file → rc=0 (soft-fail per D-005)
TX_AS6="$_TEST_STUB_DIR/tx-as6-missing-do-not-create.ndjson"
rm -f "$TX_AS6"
out_as6="$(assert_no_tool_invocation "$TX_AS6" "gh pr create")" && rc_as6=0 || rc_as6=$?
if [[ "$rc_as6" == "0" && -z "$out_as6" ]]; then
  pass_at "AS6: missing transcript → rc=0 (soft-fail)"
else
  fail_at "AS6" "rc=$rc_as6 out=$out_as6"
fi

# ─── ENG-49 Gap #7: prompt↔allowlist contract ─────────────────────────
# For each stage, every `gh pr <verb>` token appearing in
# AGENT_PROMPTS.md §S must be allowlisted in allowed_tools_for(S).
# Token regex matches shell-shaped instances: line-start whitespace
# (or backtick) + `gh pr ` + one verb word.
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
    | sort -u || true)"
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

printf '\n--- ENG-49 Gap #7: prompt<->allowlist contract ---\n'
contract_check_stage implement     "## 3. Implementation Agent (Backend)"
contract_check_stage ui            "## 4. UI Agent (Frontend)"
contract_check_stage review        "## 5. Review Agent"
contract_check_stage qa            "## 6. QA Agent"
contract_check_stage build         "## 7. Build Agent"

# ─── ENG-53 #8: harness target's dispatch.tools populated ──────────────
# Per the ENG-44 dogfood post-mortem: the implement and qa stages on
# harness-self had no allowlisted way to invoke `bash bin/<name>-test.sh`
# (the harness's testing convention per learned-rules/harness/project-
# profile.md). Implement shipped a broken `read -r cfg sf` test that
# pass-by-accident; qa explicitly flagged "harness sandbox blocked
# direct `bash bin/<test>.sh` execution" before proceeding. The fix is
# pure config — populate harness's own .pipeline-config/config.json::
# dispatch.tools.{implement,qa}[] with the test-runner pattern. ENG-51's
# dispatch.tools mechanism does the rest.
#
# This assertion is a static check on the committed config — if a future
# edit drops the entries, this trips.
printf '\n--- ENG-53 #8: harness profile populates dispatch.tools test-runner ---\n'
# .pipeline-config/ is gitignored — config.json is per-operator. This
# assertion warns the operator running tests against TARGET_REPO=harness
# if their local config drifts from the recommended dispatch.tools
# population. CI / other-target operators (file missing) skip silently.
HARNESS_CONFIG="$HARNESS_ROOT/.pipeline-config/config.json"
if [[ -f "$HARNESS_CONFIG" ]]; then
  for stage in implement qa; do
    has_runner="$(jq -r --arg s "$stage" '
      (.dispatch.tools[$s] // []) as $arr
      | if ($arr | type) == "array"
        then $arr | any(. == "Bash(bash bin/*-test.sh:*)")
        else false end
    ' "$HARNESS_CONFIG" 2>/dev/null || printf 'false')"
    if [[ "$has_runner" == "true" ]]; then
      pass_at "ENG-53#8: harness config.json::dispatch.tools.${stage} includes Bash(bash bin/*-test.sh:*)"
    else
      current="$(jq -c --arg s "$stage" '.dispatch.tools[$s] // null' "$HARNESS_CONFIG" 2>/dev/null || printf 'null')"
      fail_at "ENG-53#8: harness config.json::dispatch.tools.${stage} missing Bash(bash bin/*-test.sh:*)" \
        "current: ${current} — see CLAUDE.md or run: jq '.dispatch.tools.${stage} = [\"Bash(bash bin/*-test.sh:*)\"]' \$CONFIG > /tmp/c && mv /tmp/c \$CONFIG"
    fi
  done
else
  printf 'SKIP ENG-53#8: %s not present (CI or non-harness target) — skipping config drift check\n' "$HARNESS_CONFIG"
fi

# ─── Summary ────────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
