#!/usr/bin/env bash
# Tests for ENG-27: Playwright MCP wiring on ui/qa dispatch.
#
# The plan's System invariants table maps to T_* assertions here:
#   I-1 (gate coherence)       → T_mcp_gate_coherent
#   I-2 (dry-run separation)   → T_dry_run_keeps_allowlist + T_dry_run_skips_mcp_config
#   I-3 (only ui/qa)           → T_other_stages_no_mcp
#   I-5 (missing config dies)  → T_missing_config_dies
#   D-7 headful selector       → T_headful_picks_sibling_config
#
# Test discipline mirrors bin/dispatch-test.sh: source-and-stub pattern,
# claude + gtimeout stubs, PIPELINE_DRY_RUN gated harness.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"

# ─── Temp dirs ──────────────────────────────────────────────────────────
_TEST_TARGET_DIR="$(mktemp -d -t twinning-eng27.XXXXXX)"
_TEST_STUB_DIR="$(mktemp -d -t twinning-eng27.XXXXXX)"
_TEST_HARNESS_DIR="$(mktemp -d -t twinning-eng27.XXXXXX)"

_test_assert_temp_path() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
    *) printf 'REFUSING: path %q is not a platform temp dir\n' "$1" >&2; exit 99 ;;
  esac
}
_test_assert_temp_path "$_TEST_TARGET_DIR"
_test_assert_temp_path "$_TEST_STUB_DIR"
_test_assert_temp_path "$_TEST_HARNESS_DIR"

_test_safe_rm() {
  local path="$1"
  case "$path" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$path" ;;
    *) printf 'SAFETY: trap refusing rm -rf %q (not a temp dir)\n' "$path" >&2 ;;
  esac
}
trap '_test_safe_rm "$_TEST_STUB_DIR"; _test_safe_rm "$_TEST_TARGET_DIR"; _test_safe_rm "$_TEST_HARNESS_DIR"' EXIT

# ─── Minimal target-repo scaffold ────────────────────────────────────────
export TARGET_REPO="$_TEST_TARGET_DIR"
mkdir -p "$TARGET_REPO/.pipeline-config/schemas"

write_target_config() {
  # $1 = mcp.playwright.enabled value (true|false|null=absent)
  local enabled="$1"
  local cfg="$TARGET_REPO/.pipeline-config/config.json"
  if [[ "$enabled" == "null" ]]; then
    jq -n '{
      project: { slug: "test-slug" },
      linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:",
                native_states: { inbox: "Todo", active: "In Progress", done: "Done" },
                workflow_stages: [] },
      orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5 }
    }' > "$cfg"
  else
    jq -n --argjson e "$enabled" '{
      project: { slug: "test-slug" },
      linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:",
                native_states: { inbox: "Todo", active: "In Progress", done: "Done" },
                workflow_stages: [] },
      orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5 },
      mcp: { playwright: { enabled: $e } }
    }' > "$cfg"
  fi
}

write_target_config null
jq -n '{ labels: {}, states: {} }' > "$TARGET_REPO/.pipeline-config/schemas/linear-ids.json"

export HARNESS_STATE_DIR="$_TEST_STUB_DIR/state"
export PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
mkdir -p "$PROJECT_STATE_DIR"

# Default: real harness's mcp/ has both config files; tests can override
# HARNESS_ROOT to a fixture dir to exercise the missing-config case.
REAL_HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Source dispatch.sh (sentinel-protected main) ────────────────────────
# shellcheck source=dispatch.sh
source "$SCRIPT_DIR/dispatch.sh"

# ─── Assertion helpers ───────────────────────────────────────────────────
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }
ng()   { printf '  FAIL %s\n      %s\n' "$1" "$2" >&2
         FAIL=$((FAIL+1)); FAILED+=("$1"); }
contains()    { if [[ "$3" == *"$2"* ]]; then ok "$1"; else ng "$1" "expected contains: $2 | got: $3"; fi }
notcontains() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else ng "$1" "expected absent: $2 | got: $3"; fi }

# ─── Prepare claude / gtimeout stubs ─────────────────────────────────────
cat > "$_TEST_STUB_DIR/claude" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
exit 0
SH
chmod +x "$_TEST_STUB_DIR/claude"

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

# ─── Capture dry-run argv echo for a given stage + harness root ─────────
# Dispatch's dry-run logs `[DRY_RUN] would invoke: ...` on stderr; we grep
# that string from a per-call output file.
run_dryrun() {
  # $1 = stage, $2 = HARNESS_ROOT, $3 = output path, optional: $4=PLAYWRIGHT_HEADFUL value
  local stage="$1" harness="$2" out="$3" headful="${4-}"
  PIPELINE_DRY_RUN=1 \
  HARNESS_ROOT="$harness" \
  PLAYWRIGHT_HEADFUL="$headful" \
    bash "$SCRIPT_DIR/dispatch.sh" "$stage" "$_PROMPT_FILE" 2>"$out" >/dev/null || true
}

# ─── T_mcp_gate_coherent ─────────────────────────────────────────────────
# Four-cell matrix: (stage ∈ {ui, qa}) × (config ∈ {missing, true, false}).
# Dry-run cells split into T_dry_run_keeps_allowlist + T_dry_run_skips_mcp_config.
T_mcp_gate_coherent() {
  printf '\n--- T_mcp_gate_coherent ---\n'

  # Cell A: stage=ui, config absent → MCP enabled by default.
  write_target_config null
  local tools
  tools="$(CONFIG="$TARGET_REPO/.pipeline-config/config.json" allowed_tools_for ui)"
  contains "ui+config=absent: allowed-tools carries mcp__playwright__*" 'mcp__playwright__*' "$tools"

  # Cell B: stage=ui, config=true.
  write_target_config true
  tools="$(CONFIG="$TARGET_REPO/.pipeline-config/config.json" allowed_tools_for ui)"
  contains "ui+config=true:  allowed-tools carries mcp__playwright__*" 'mcp__playwright__*' "$tools"

  # Cell C: stage=ui, config=false → MCP suppressed.
  write_target_config false
  tools="$(CONFIG="$TARGET_REPO/.pipeline-config/config.json" allowed_tools_for ui)"
  notcontains "ui+config=false: allowed-tools omits mcp__playwright__*" 'mcp__playwright__*' "$tools"

  # Cell D: stage=qa, config=true.
  write_target_config true
  tools="$(CONFIG="$TARGET_REPO/.pipeline-config/config.json" allowed_tools_for qa)"
  contains "qa+config=true:  allowed-tools carries mcp__playwright__*" 'mcp__playwright__*' "$tools"

  # Cell E: stage=qa, config=false.
  write_target_config false
  tools="$(CONFIG="$TARGET_REPO/.pipeline-config/config.json" allowed_tools_for qa)"
  notcontains "qa+config=false: allowed-tools omits mcp__playwright__*" 'mcp__playwright__*' "$tools"

  # Reset to default-enabled for downstream tests.
  write_target_config null
}

# ─── T_other_stages_no_mcp ───────────────────────────────────────────────
# Stages other than ui/qa must NEVER carry the MCP allowlist entry, and the
# dry-run argv echo must NEVER include --mcp-config — regardless of the
# config flag's value.
T_other_stages_no_mcp() {
  printf '\n--- T_other_stages_no_mcp ---\n'

  # Toggle config across true/false so the gate predicate is exercised both ways.
  for cfg in true false null; do
    write_target_config "$cfg"
    for stage in brainstorming planning implementing reviewing building released; do
      local tools
      tools="$(CONFIG="$TARGET_REPO/.pipeline-config/config.json" allowed_tools_for "$stage")"
      notcontains "stage=$stage (config=$cfg): no mcp__playwright__* in allowed-tools" \
        'mcp__playwright__*' "$tools"
    done
  done
  write_target_config null
}

# ─── T_dry_run_keeps_allowlist ───────────────────────────────────────────
# PIPELINE_DRY_RUN=1 echoes --allowed-tools containing mcp__playwright__* on
# ui/qa (the allowlist computation runs BEFORE the dry-run early return).
T_dry_run_keeps_allowlist() {
  printf '\n--- T_dry_run_keeps_allowlist ---\n'
  write_target_config true
  local out="$_TEST_STUB_DIR/dryrun-ui.out"
  run_dryrun ui "$REAL_HARNESS_ROOT" "$out"
  local line
  line="$(grep -E '^\[DRY_RUN\] would invoke' "$out" | head -1)"
  contains "ui dry-run argv contains mcp__playwright__*" 'mcp__playwright__*' "$line"

  out="$_TEST_STUB_DIR/dryrun-qa.out"
  run_dryrun qa "$REAL_HARNESS_ROOT" "$out"
  line="$(grep -E '^\[DRY_RUN\] would invoke' "$out" | head -1)"
  contains "qa dry-run argv contains mcp__playwright__*" 'mcp__playwright__*' "$line"
}

# ─── T_dry_run_skips_mcp_config ──────────────────────────────────────────
# Dry-run argv echo MUST NOT include --mcp-config (no MCP child process is
# spawned in dry-run; D-5).
T_dry_run_skips_mcp_config() {
  printf '\n--- T_dry_run_skips_mcp_config ---\n'
  write_target_config true
  local out="$_TEST_STUB_DIR/dryrun-ui-nomcp.out"
  run_dryrun ui "$REAL_HARNESS_ROOT" "$out"
  local line
  line="$(grep -E '^\[DRY_RUN\] would invoke' "$out" | head -1)"
  notcontains "ui dry-run argv omits --mcp-config" '--mcp-config' "$line"

  out="$_TEST_STUB_DIR/dryrun-qa-nomcp.out"
  run_dryrun qa "$REAL_HARNESS_ROOT" "$out"
  line="$(grep -E '^\[DRY_RUN\] would invoke' "$out" | head -1)"
  notcontains "qa dry-run argv omits --mcp-config" '--mcp-config' "$line"
}

# ─── T_missing_config_dies ───────────────────────────────────────────────
# Live (non-dry-run) ui dispatch with HARNESS_ROOT pointed at a tree where
# mcp/playwright.json is intentionally MISSING → dispatch dies with a
# stderr message naming the missing path. Headful path covered by setting
# PLAYWRIGHT_HEADFUL=1 with the headful file absent.
T_missing_config_dies() {
  printf '\n--- T_missing_config_dies ---\n'
  write_target_config true

  # Empty fixture harness: HARNESS_ROOT with NO mcp/ directory.
  local fix="$_TEST_HARNESS_DIR/empty"
  mkdir -p "$fix"

  # Override PATH so the stub claude + gtimeout shadow the real ones.
  local out="$_TEST_STUB_DIR/missing-headless.out"
  PATH="$_TEST_STUB_DIR:$PATH" \
  PIPELINE_DRY_RUN=0 \
  HARNESS_ROOT="$fix" \
  TARGET_REPO="$TARGET_REPO" \
  PROJECT_SLUG="$PROJECT_SLUG" \
  HARNESS_STATE_DIR="$HARNESS_STATE_DIR" \
  PROJECT_STATE_DIR="$PROJECT_STATE_DIR" \
  LINEAR_API_KEY="$LINEAR_API_KEY" \
    bash "$SCRIPT_DIR/dispatch.sh" ui "$_PROMPT_FILE" 2>"$out" >/dev/null
  local rc=$?
  if (( rc != 0 )); then
    ok "headless ui dispatch exits non-zero when mcp/playwright.json missing (rc=$rc)"
  else
    ng "headless ui dispatch should die when mcp/playwright.json missing" "rc=0; out: $(cat "$out")"
  fi
  contains "headless ui die message names the missing path" 'MCP config missing at' "$(cat "$out")"
  contains "headless ui die message names playwright.json" 'playwright.json' "$(cat "$out")"

  # Headful variant: only playwright.json present, no playwright-headful.json.
  local fix2="$_TEST_HARNESS_DIR/headless-only"
  mkdir -p "$fix2/mcp"
  printf '{"mcpServers":{"playwright":{}}}\n' > "$fix2/mcp/playwright.json"
  out="$_TEST_STUB_DIR/missing-headful.out"
  PATH="$_TEST_STUB_DIR:$PATH" \
  PIPELINE_DRY_RUN=0 \
  HARNESS_ROOT="$fix2" \
  TARGET_REPO="$TARGET_REPO" \
  PROJECT_SLUG="$PROJECT_SLUG" \
  HARNESS_STATE_DIR="$HARNESS_STATE_DIR" \
  PROJECT_STATE_DIR="$PROJECT_STATE_DIR" \
  LINEAR_API_KEY="$LINEAR_API_KEY" \
  PLAYWRIGHT_HEADFUL=1 \
    bash "$SCRIPT_DIR/dispatch.sh" qa "$_PROMPT_FILE" 2>"$out" >/dev/null
  rc=$?
  if (( rc != 0 )); then
    ok "headful qa dispatch exits non-zero when playwright-headful.json missing (rc=$rc)"
  else
    ng "headful qa dispatch should die when playwright-headful.json missing" "rc=0; out: $(cat "$out")"
  fi
  contains "headful qa die message names playwright-headful.json" 'playwright-headful.json' "$(cat "$out")"
}

# ─── T_headful_picks_sibling_config ──────────────────────────────────────
# PLAYWRIGHT_HEADFUL=1 selects mcp/playwright-headful.json; unset picks
# mcp/playwright.json. Both fixture files exist for this test.
T_headful_picks_sibling_config() {
  printf '\n--- T_headful_picks_sibling_config ---\n'
  write_target_config true

  local fix="$_TEST_HARNESS_DIR/both"
  mkdir -p "$fix/mcp"
  printf '{"mcpServers":{"playwright":{"command":"npx","args":["--headless"]}}}\n' \
    > "$fix/mcp/playwright.json"
  printf '{"mcpServers":{"playwright":{"command":"npx","args":[]}}}\n' \
    > "$fix/mcp/playwright-headful.json"

  # Headful=1 → headful path.
  local out="$_TEST_STUB_DIR/headful-on.out"
  PATH="$_TEST_STUB_DIR:$PATH" \
  PIPELINE_DRY_RUN=0 \
  HARNESS_ROOT="$fix" \
  TARGET_REPO="$TARGET_REPO" \
  PROJECT_SLUG="$PROJECT_SLUG" \
  HARNESS_STATE_DIR="$HARNESS_STATE_DIR" \
  PROJECT_STATE_DIR="$PROJECT_STATE_DIR" \
  LINEAR_API_KEY="$LINEAR_API_KEY" \
  PIPELINE_TRACE_ARGV=1 \
  PLAYWRIGHT_HEADFUL=1 \
    bash -x "$SCRIPT_DIR/dispatch.sh" ui "$_PROMPT_FILE" 2>"$out" >/dev/null || true
  contains "PLAYWRIGHT_HEADFUL=1 selects playwright-headful.json" \
    'playwright-headful.json' "$(cat "$out")"

  # Unset → headless path.
  out="$_TEST_STUB_DIR/headful-off.out"
  PATH="$_TEST_STUB_DIR:$PATH" \
  PIPELINE_DRY_RUN=0 \
  HARNESS_ROOT="$fix" \
  TARGET_REPO="$TARGET_REPO" \
  PROJECT_SLUG="$PROJECT_SLUG" \
  HARNESS_STATE_DIR="$HARNESS_STATE_DIR" \
  PROJECT_STATE_DIR="$PROJECT_STATE_DIR" \
  LINEAR_API_KEY="$LINEAR_API_KEY" \
    bash -x "$SCRIPT_DIR/dispatch.sh" ui "$_PROMPT_FILE" 2>"$out" >/dev/null || true
  local body
  body="$(cat "$out")"
  contains "PLAYWRIGHT_HEADFUL unset selects playwright.json" 'mcp/playwright.json' "$body"
  notcontains "PLAYWRIGHT_HEADFUL unset does NOT select headful sibling" \
    'playwright-headful.json' "$body"
}

# ─── Drive the suite ─────────────────────────────────────────────────────
T_mcp_gate_coherent
T_other_stages_no_mcp
T_dry_run_keeps_allowlist
T_dry_run_skips_mcp_config
T_missing_config_dies
T_headful_picks_sibling_config

# ─── Summary ─────────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed cases:\n'
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
