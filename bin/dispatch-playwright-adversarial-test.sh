#!/usr/bin/env bash
# Adversarial tests for ENG-27: coverage gaps identified during qa review.
# Extends bin/dispatch-playwright-test.sh; mirrors its source-and-stub pattern.
# Gaps closed:
#   ADV-1: retrospective stage omitted from T_other_stages_no_mcp loop.
#   ADV-2: non-boolean enabled values (0, "false", null) → enabled contract pin.
#   ADV-3: malformed config.json → fail-open (jq error → printf 'false' → enabled).
#   ADV-4: PLAYWRIGHT_HEADFUL non-"1" truthy strings → headless config selected.
#
# Run: bash bin/dispatch-playwright-adversarial-test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
export CLAUDE_MAX_CONCURRENT="${CLAUDE_MAX_CONCURRENT:-2}"
export _PIPELINE_GTIME_DISABLED=1

# ─── Temp dirs ───────────────────────────────────────────────────────────────
_TEST_TARGET_DIR="$(mktemp -d -t twinning-eng27adv.XXXXXX)"
_TEST_STUB_DIR="$(mktemp -d -t twinning-eng27adv.XXXXXX)"

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
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$path" ;;
    *) printf 'SAFETY: trap refusing rm -rf %q (not a temp dir)\n' "$path" >&2 ;;
  esac
}
trap '_test_safe_rm "$_TEST_STUB_DIR"; _test_safe_rm "$_TEST_TARGET_DIR"' EXIT

# ─── Minimal target-repo scaffold ────────────────────────────────────────────
export TARGET_REPO="$_TEST_TARGET_DIR"
mkdir -p "$TARGET_REPO/.pipeline-config/schemas"
jq -n '{ labels: {}, states: {} }' > "$TARGET_REPO/.pipeline-config/schemas/linear-ids.json"

_cfg="$TARGET_REPO/.pipeline-config/config.json"

write_target_config() {
  local enabled="$1"
  if [[ "$enabled" == "null" ]]; then
    jq -n '{
      project: { slug: "test-slug" },
      linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:",
                native_states: { inbox: "Todo", active: "In Progress", done: "Done" },
                workflow_stages: [] },
      orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5 }
    }' > "$_cfg"
  else
    jq -n --argjson e "$enabled" '{
      project: { slug: "test-slug" },
      linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:",
                native_states: { inbox: "Todo", active: "In Progress", done: "Done" },
                workflow_stages: [] },
      orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5 },
      mcp: { playwright: { enabled: $e } }
    }' > "$_cfg"
  fi
}
write_target_config null

export HARNESS_STATE_DIR="$_TEST_STUB_DIR/state"
export PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
mkdir -p "$PROJECT_STATE_DIR"

REAL_HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Source dispatch.sh (sentinel-protected main) ────────────────────────────
# shellcheck source=dispatch.sh
source "$SCRIPT_DIR/dispatch.sh"

# ─── Assertion helpers ────────────────────────────────────────────────────────
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }
ng()   { printf '  FAIL %s\n      %s\n' "$1" "$2" >&2
         FAIL=$((FAIL+1)); FAILED+=("$1"); }
contains()    { if [[ "$3" == *"$2"* ]]; then ok "$1"; else ng "$1" "expected contains: $2 | got: $3"; fi }
notcontains() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else ng "$1" "expected absent: $2 | got: $3"; fi }

# ─── Stubs: claude + gtimeout ─────────────────────────────────────────────────
cat > "$_TEST_STUB_DIR/claude" <<'SH'
#!/usr/bin/env bash
if [[ -n "${_TEST_CAPTURE_CLAUDE_ARGV:-}" ]]; then
  {
    printf 'argv:'
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
  } >> "$_TEST_CAPTURE_CLAUDE_ARGV"
fi
cat > /dev/null
exit 0
SH
chmod +x "$_TEST_STUB_DIR/claude"

export PATH="$_TEST_STUB_DIR:$PATH"

cat > "$_TEST_STUB_DIR/gtimeout" <<'SH'
#!/usr/bin/env bash
while (( $# > 0 )); do
  case "$1" in
    --signal=*|--kill-after=*) shift ;;
    *) break ;;
  esac
done
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then shift; fi
exec "$@"
SH
chmod +x "$_TEST_STUB_DIR/gtimeout"

_PROMPT_FILE="$_TEST_STUB_DIR/prompt.txt"
printf 'test prompt\n' > "$_PROMPT_FILE"

# ─── Behavioral helper (mirrors dispatch-playwright-test.sh) ─────────────────
run_main_behavioral() {
  local stage="$1" harness="$2" prefix="$3" headful="${4-}"
  : > "$prefix.argv"; : > "$prefix.stderr"; : > "$prefix.stdout"
  local rc=0
  (
    HARNESS_ROOT="$harness"
    PIPELINE_DRY_RUN=0
    PLAYWRIGHT_HEADFUL="$headful"
    _TEST_CAPTURE_CLAUDE_ARGV="$prefix.argv"
    export HARNESS_ROOT PIPELINE_DRY_RUN PLAYWRIGHT_HEADFUL _TEST_CAPTURE_CLAUDE_ARGV
    unset PIPELINE_ISSUE_ID
    main "$stage" "$_PROMPT_FILE"
  ) 2>"$prefix.stderr" >"$prefix.stdout" || rc=$?
  printf '%d' "$rc"
}

# ─── ADV-1: retrospective stage must be excluded from MCP ────────────────────
# T_other_stages_no_mcp in dispatch-playwright-test.sh covers
# brainstorming/planning/implementing/reviewing/building/released but omits
# retrospective (nine-stage arm in dispatch.sh's case block). The reviewing
# stage flagged this gap (cross-cutting note, non-blocking). Two surfaces:
#   1. allowed_tools_for() must not include mcp__playwright__* for retrospective
#      regardless of the config flag.
#   2. main()'s real cmd argv must not carry --mcp-config for retrospective.
T_retrospective_no_mcp() {
  printf '\n--- T_retrospective_no_mcp ---\n'

  for cfg_val in true false null; do
    write_target_config "$cfg_val"
    local tools
    tools="$(CONFIG="$_cfg" allowed_tools_for retrospective)"
    notcontains "stage=retrospective (config=$cfg_val): no mcp__playwright__* in allowed-tools" \
      'mcp__playwright__*' "$tools"
  done

  write_target_config true
  local prefix="$_TEST_STUB_DIR/retro-behavioral"
  local rc
  rc="$(run_main_behavioral retrospective "$REAL_HARNESS_ROOT" "$prefix")"
  notcontains "stage=retrospective: cmd argv omits --mcp-config (behavioral)" \
    '--mcp-config' "$(cat "$prefix.argv")"
  notcontains "stage=retrospective: cmd argv omits mcp/playwright.json (behavioral)" \
    'mcp/playwright.json' "$(cat "$prefix.argv")"

  write_target_config null
}

# ─── ADV-2: non-boolean enabled values default to enabled ────────────────────
# The gate uses `.mcp.playwright.enabled == false` (strict JSON equality).
# Integers (0), strings ("false"), and explicit JSON null are NOT equal to JSON
# boolean false — all three default to enabled. This pins the non-bool passthrough
# contract so a change from `== false` to a looser predicate is machine-visible.
T_enabled_nonbool_passthrough() {
  printf '\n--- T_enabled_nonbool_passthrough ---\n'

  # Integer 0 — not JSON false, so default-enabled.
  printf '%s\n' '{
    "project": {"slug":"test-slug"},
    "linear":{"team_id":"t","project_id":"p","stage_label_prefix":"stage:",
               "native_states":{"inbox":"Todo","active":"In Progress","done":"Done"},
               "workflow_stages":[]},
    "orchestrator":{"paused":false,"max_concurrent_features":2,"alert_on_halted_over":5},
    "mcp":{"playwright":{"enabled":0}}
  }' > "$_cfg"
  local tools
  tools="$(CONFIG="$_cfg" allowed_tools_for ui)"
  contains "enabled=0 (integer zero): ui allowed-tools carries mcp__playwright__* (default-enabled)" \
    'mcp__playwright__*' "$tools"
  tools="$(CONFIG="$_cfg" allowed_tools_for qa)"
  contains "enabled=0 (integer zero): qa allowed-tools carries mcp__playwright__* (default-enabled)" \
    'mcp__playwright__*' "$tools"

  # String "false" — not JSON boolean false, so default-enabled.
  printf '%s\n' '{
    "project": {"slug":"test-slug"},
    "linear":{"team_id":"t","project_id":"p","stage_label_prefix":"stage:",
               "native_states":{"inbox":"Todo","active":"In Progress","done":"Done"},
               "workflow_stages":[]},
    "orchestrator":{"paused":false,"max_concurrent_features":2,"alert_on_halted_over":5},
    "mcp":{"playwright":{"enabled":"false"}}
  }' > "$_cfg"
  tools="$(CONFIG="$_cfg" allowed_tools_for ui)"
  contains "enabled=\"false\" (string): ui allowed-tools carries mcp__playwright__* (default-enabled)" \
    'mcp__playwright__*' "$tools"

  # Explicit JSON null — distinct from absent key, still not JSON false, default-enabled.
  printf '%s\n' '{
    "project": {"slug":"test-slug"},
    "linear":{"team_id":"t","project_id":"p","stage_label_prefix":"stage:",
               "native_states":{"inbox":"Todo","active":"In Progress","done":"Done"},
               "workflow_stages":[]},
    "orchestrator":{"paused":false,"max_concurrent_features":2,"alert_on_halted_over":5},
    "mcp":{"playwright":{"enabled":null}}
  }' > "$_cfg"
  tools="$(CONFIG="$_cfg" allowed_tools_for qa)"
  contains "enabled=null (explicit null): qa allowed-tools carries mcp__playwright__* (default-enabled)" \
    'mcp__playwright__*' "$tools"

  write_target_config null
}

# ─── ADV-3: malformed config.json falls through to enabled (fail-open) ────────
# When CONFIG exists but is unparseable JSON, jq exits non-zero. The
# `|| printf 'false'` fallback in _dispatch_mcp_enabled_for sets
# explicit_false="false" → [[ "false" == "true" ]] is false → gate returns 0
# (enabled). This documents the fail-open contract so a flip of `|| printf 'false'`
# to `|| printf 'true'` is machine-visible.
T_malformed_config_failopen() {
  printf '\n--- T_malformed_config_failopen ---\n'
  printf '%s\n' 'this is not valid JSON {{{' > "$_cfg"

  local tools
  tools="$(CONFIG="$_cfg" allowed_tools_for ui 2>/dev/null)"
  contains "malformed config: ui allowed-tools carries mcp__playwright__* (fail-open)" \
    'mcp__playwright__*' "$tools"
  tools="$(CONFIG="$_cfg" allowed_tools_for qa 2>/dev/null)"
  contains "malformed config: qa allowed-tools carries mcp__playwright__* (fail-open)" \
    'mcp__playwright__*' "$tools"
  # Non-ui/qa stages are still blocked regardless of config parseability.
  tools="$(CONFIG="$_cfg" allowed_tools_for implementing 2>/dev/null)"
  notcontains "malformed config: implementing still has no mcp__playwright__*" \
    'mcp__playwright__*' "$tools"

  write_target_config null
}

# ─── ADV-4: PLAYWRIGHT_HEADFUL non-"1" strings pick headless config ───────────
# The selector is `[[ "${PLAYWRIGHT_HEADFUL-}" == "1" ]]` — exact string "1".
# Other truthy-looking strings ("yes", "true", "on", "TRUE") do NOT trigger the
# headful branch. This pins the exact-"1" contract so a change to a broader
# truthy check is machine-visible.
T_headful_nonone_picks_headless() {
  printf '\n--- T_headful_nonone_picks_headless ---\n'
  write_target_config true

  for headful_val in yes true on TRUE YES 1x; do
    local prefix="$_TEST_STUB_DIR/headful-nonone-${headful_val}"
    local rc
    rc="$(run_main_behavioral ui "$REAL_HARNESS_ROOT" "$prefix" "$headful_val")"
    if [[ "$rc" == "0" ]]; then
      ok "PLAYWRIGHT_HEADFUL=$headful_val: main exits 0"
    else
      ng "PLAYWRIGHT_HEADFUL=$headful_val: main exits 0" \
        "rc=$rc; stderr=$(head -3 "$prefix.stderr" 2>/dev/null)"
    fi
    local argv_body
    argv_body="$(cat "$prefix.argv")"
    contains "PLAYWRIGHT_HEADFUL=$headful_val: argv names mcp/playwright.json (headless default)" \
      '/mcp/playwright.json' "$argv_body"
    notcontains "PLAYWRIGHT_HEADFUL=$headful_val: argv does NOT name playwright-headful.json" \
      'playwright-headful.json' "$argv_body"
  done

  write_target_config null
}

# ─── Drive the suite ─────────────────────────────────────────────────────────
T_retrospective_no_mcp
T_enabled_nonbool_passthrough
T_malformed_config_failopen
T_headful_nonone_picks_headless

# ─── Summary ─────────────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed cases:\n'
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
