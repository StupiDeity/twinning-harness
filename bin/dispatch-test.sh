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
export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
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
done

# ─── Group 2: PIPELINE_WRITER env propagation ───────────────────────────
printf '\n--- PIPELINE_WRITER=agent propagated to claude -p invocation ---\n'

# Create a stub for 'claude' that captures its environment.
ENV_CAPTURE="$_TEST_STUB_DIR/env.capture"
: > "$ENV_CAPTURE"

cat > "$_TEST_STUB_DIR/claude" <<SH
#!/usr/bin/env bash
# Stub: capture PIPELINE_WRITER from the environment into a file, then exit 0.
printf 'PIPELINE_WRITER=%s\n' "\${PIPELINE_WRITER:-<unset>}" >> "$ENV_CAPTURE"
# Consume stdin (like real claude would) so the caller's pipe doesn't break.
cat > /dev/null
exit 0
SH
chmod +x "$_TEST_STUB_DIR/claude"

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

# ─── Summary ────────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
