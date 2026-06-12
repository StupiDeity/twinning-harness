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

# Behavioral subshell tests below set PIPELINE_DRY_RUN=0 and invoke
# main() directly (sourced, not bash-bin/dispatch.sh-in-subshell — the
# latter re-derives HARNESS_ROOT via common.sh:9's unguarded assignment
# and silently discards any override). The mutex acquire writes a slot
# under $CLAUDE_SEMAPHORE_DIR (= $HARNESS_STATE_DIR/.claude-semaphore)
# bound at source time; pin K=2 here so the path doesn't depend on
# config.json lookup for cap resolution.
export CLAUDE_MAX_CONCURRENT="${CLAUDE_MAX_CONCURRENT:-2}"
# Disable gtime discovery so the resource-sample block does not need a
# brewed gnu-time install (and so the metric-emit path doesn't fire on
# the test PROJECT_STATE_DIR which lacks a real metrics.sh wiring).
export _PIPELINE_GTIME_DISABLED=1

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
# The claude stub records its argv to $_TEST_CAPTURE_CLAUDE_ARGV when set
# (behavioral subshell tests) and otherwise behaves as a quiet sink. env
# propagates the variable through the `env PIPELINE_WRITER=agent …` chain
# in dispatch.sh::main's cmd array (env preserves the parent environment
# and only ADDS the explicit VAR=val assignments).
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

# Prepend stubs to PATH so claude/gtimeout (and any other shim) resolve
# to the test sandbox before the real binaries — load-bearing for the
# behavioral subshell tests below.
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

# ─── Behavioral: invoke main() directly post-source ──────────────────────
# Subshell wrapper around `main` so:
#   - HARNESS_ROOT override survives (common.sh:9 re-derives in a fresh
#     subshell+source — that's the workaround critical findings #1 / #2
#     called out. Sourcing once at file load + subshell invocation keeps
#     the override intact across the subshell boundary).
#   - die() in main exits the subshell only.
#   - acquire_claude_mutex's EXIT trap releases the slot on subshell
#     exit, so subsequent runs re-acquire cleanly.
# Writes:
#   $4.argv   — one-line `argv: -p --output-format ...` capture from
#               the claude stub (empty when main died before exec).
#   $4.stderr — main's stderr (greppable for the die message).
#   $4.stdout — main's stdout (typically empty).
# Returns rc on stdout (printf '%d').
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
# Stages other than ui/qa must NEVER carry the MCP allowlist entry, and
# the cmd argv must NEVER include --mcp-config — regardless of the
# config flag's value. Two surfaces are checked:
#   1. allowed_tools_for() output (compile-time tool string).
#   2. main()'s REAL cmd argv composed in a behavioral subshell, via
#      the claude stub's capture (the major-finding F-10 gap pre-loopback:
#      a future refactor that split the gate predicate could regress one
#      surface without the other).
T_other_stages_no_mcp() {
  printf '\n--- T_other_stages_no_mcp ---\n'

  # Surface 1: allowed_tools_for() output across config toggles.
  for cfg in true false null; do
    write_target_config "$cfg"
    for stage in brainstorming planning implementing reviewing building released; do
      local tools
      tools="$(CONFIG="$TARGET_REPO/.pipeline-config/config.json" allowed_tools_for "$stage")"
      notcontains "stage=$stage (config=$cfg): no mcp__playwright__* in allowed-tools" \
        'mcp__playwright__*' "$tools"
    done
  done

  # Surface 2: behavioral cmd argv on each non-ui/qa stage with config
  # default-enabled. The stage-gate predicate at the helper's first arm
  # (case ui|qa) must keep --mcp-config out of argv even when the
  # config-side gate would otherwise pass.
  write_target_config true
  local stage prefix rc
  for stage in brainstorming planning implementing reviewing building released; do
    prefix="$_TEST_STUB_DIR/other-stage-$stage"
    rc="$(run_main_behavioral "$stage" "$REAL_HARNESS_ROOT" "$prefix")"
    if [[ "$rc" == "0" ]]; then
      ok "stage=$stage: main exits 0 (behavioral)"
    else
      ng "stage=$stage: main exits 0 (behavioral)" "rc=$rc; stderr=$(cat "$prefix.stderr" 2>/dev/null | head -3)"
    fi
    notcontains "stage=$stage: cmd argv omits --mcp-config (behavioral)" \
      '--mcp-config' "$(cat "$prefix.argv")"
    notcontains "stage=$stage: cmd argv omits mcp/playwright.json (behavioral)" \
      'mcp/playwright.json' "$(cat "$prefix.argv")"
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
  line="$(grep -E '\[DRY_RUN\] would invoke' "$out" | head -1 || true)"
  contains "ui dry-run argv contains mcp__playwright__*" 'mcp__playwright__*' "$line"

  out="$_TEST_STUB_DIR/dryrun-qa.out"
  run_dryrun qa "$REAL_HARNESS_ROOT" "$out"
  line="$(grep -E '\[DRY_RUN\] would invoke' "$out" | head -1 || true)"
  contains "qa dry-run argv contains mcp__playwright__*" 'mcp__playwright__*' "$line"
}

# ─── T_dry_run_skips_mcp_config ──────────────────────────────────────────
# Dry-run argv echo MUST NOT include --mcp-config (no MCP child process is
# spawned in dry-run; D-5). Pre-loopback this test was tautological — the
# dry-run echo at bin/dispatch.sh:740 is hand-rolled and never composes
# `--mcp-config` regardless of code state, so a regression in the real
# splice (lines 825-830) would pass invisibly. The fix: ALSO assert that
# the REAL cmd argv composed in main() — captured via the claude stub
# from a behavioral subshell run — DOES contain `--mcp-config` on
# non-dry-run ui/qa with config files present. The pair of assertions
# (present in non-dry-run argv, absent from dry-run echo) is the
# load-bearing structural pin for I-2 / F-8.
T_dry_run_skips_mcp_config() {
  printf '\n--- T_dry_run_skips_mcp_config ---\n'
  write_target_config true

  # Dry-run absence (pre-loopback assertion, retained).
  local out="$_TEST_STUB_DIR/dryrun-ui-nomcp.out"
  run_dryrun ui "$REAL_HARNESS_ROOT" "$out"
  local line
  line="$(grep -E '\[DRY_RUN\] would invoke' "$out" | head -1)"
  notcontains "ui dry-run argv omits --mcp-config" '--mcp-config' "$line"

  out="$_TEST_STUB_DIR/dryrun-qa-nomcp.out"
  run_dryrun qa "$REAL_HARNESS_ROOT" "$out"
  line="$(grep -E '\[DRY_RUN\] would invoke' "$out" | head -1)"
  notcontains "qa dry-run argv omits --mcp-config" '--mcp-config' "$line"

  # Non-dry-run presence (behavioral): the only structural counterweight
  # to the dry-run absence check. If the splice at dispatch.sh:825-830
  # is silently deleted, this assertion regresses; the dry-run absence
  # alone would still pass.
  local prefix="$_TEST_STUB_DIR/behavioral-ui-present"
  local rc
  rc="$(run_main_behavioral ui "$REAL_HARNESS_ROOT" "$prefix")"
  contains "ui non-dry-run argv carries --mcp-config (behavioral)" \
    '--mcp-config' "$(cat "$prefix.argv")"
  contains "ui non-dry-run argv names mcp/playwright.json (behavioral)" \
    'mcp/playwright.json' "$(cat "$prefix.argv")"
  if [[ "$rc" == "0" ]]; then
    ok "ui non-dry-run main exits 0 (behavioral)"
  else
    ng "ui non-dry-run main exits 0 (behavioral)" "rc=$rc; stderr=$(cat "$prefix.stderr" 2>/dev/null | head -3)"
  fi

  prefix="$_TEST_STUB_DIR/behavioral-qa-present"
  rc="$(run_main_behavioral qa "$REAL_HARNESS_ROOT" "$prefix")"
  contains "qa non-dry-run argv carries --mcp-config (behavioral)" \
    '--mcp-config' "$(cat "$prefix.argv")"
  contains "qa non-dry-run argv names mcp/playwright.json (behavioral)" \
    'mcp/playwright.json' "$(cat "$prefix.argv")"
}

# ─── T_missing_config_dies ───────────────────────────────────────────────
# Behavioral: drive main() against a HARNESS_ROOT fixture that
# intentionally does NOT contain mcp/playwright.json, assert main exits
# non-zero with the operator-actionable hint on stderr. Pre-loopback
# this test was a content-pin grep — meaningful as a typo guard but
# silent on a regression that flipped `||` to `&&` or removed the [[ -f ]]
# guard entirely. The behavioral path closes I-5 / F-1 / F-6. Approach:
# source-and-invoke-main per the test file header — `bash bin/dispatch.sh`
# in a fresh subshell would re-source common.sh and re-derive
# HARNESS_ROOT to the real repo (silently undoing the no-mcp override).
T_missing_config_dies() {
  printf '\n--- T_missing_config_dies ---\n'
  write_target_config true

  # _TEST_HARNESS_DIR is an empty mktemp — no mcp/ subdir exists, so
  # the [[ -f $mcp_cfg_path ]] guard at dispatch.sh:828 trips into die().
  local prefix="$_TEST_STUB_DIR/missing-ui"
  local rc
  rc="$(run_main_behavioral ui "$_TEST_HARNESS_DIR" "$prefix")"
  if [[ "$rc" != "0" ]]; then
    ok "ui missing-config: main exits non-zero (behavioral)"
  else
    ng "ui missing-config: main exits non-zero (behavioral)" \
      "rc=0 — die path did not fire; argv=$(cat "$prefix.argv" 2>/dev/null | head -1)"
  fi
  contains "ui missing-config: stderr names 'MCP config missing at'" \
    'MCP config missing at' "$(cat "$prefix.stderr")"
  contains "ui missing-config: stderr names mcp/playwright.json (headless path)" \
    'mcp/playwright.json' "$(cat "$prefix.stderr")"
  contains "ui missing-config: stderr includes operator-actionable hint" \
    'config.mcp.playwright.enabled=false' "$(cat "$prefix.stderr")"
  # Negative: claude was never invoked → argv capture file is empty.
  if [[ ! -s "$prefix.argv" ]]; then
    ok "ui missing-config: claude was not invoked (no argv capture)"
  else
    ng "ui missing-config: claude was not invoked" \
      "argv captured — die-path likely did not fire before exec: $(cat "$prefix.argv" | head -1)"
  fi

  # Adversarial: PLAYWRIGHT_HEADFUL=1 picks the headful sibling path,
  # which is also absent in the fixture; die-shape must mention the
  # headful filename.
  prefix="$_TEST_STUB_DIR/missing-ui-headful"
  rc="$(run_main_behavioral ui "$_TEST_HARNESS_DIR" "$prefix" 1)"
  if [[ "$rc" != "0" ]]; then
    ok "ui missing-config + HEADFUL=1: main exits non-zero (behavioral)"
  else
    ng "ui missing-config + HEADFUL=1: main exits non-zero (behavioral)" "rc=0"
  fi
  contains "ui missing-config + HEADFUL=1: stderr names mcp/playwright-headful.json" \
    'mcp/playwright-headful.json' "$(cat "$prefix.stderr")"
}

# ─── T_headful_picks_sibling_config ──────────────────────────────────────
# Behavioral: drive main() against REAL_HARNESS_ROOT (where both mcp/
# config files exist), toggle PLAYWRIGHT_HEADFUL, assert the --mcp-config
# arg in the captured argv ends in the correct filename. Pre-loopback
# this was a content-pin grep; the behavioral path catches a regression
# that flipped the env-var name (e.g. PLAYWRIGHT_HEADLESS=0) or moved
# the assignment outside the gate.
T_headful_picks_sibling_config() {
  printf '\n--- T_headful_picks_sibling_config ---\n'
  write_target_config true

  # HEADFUL=1 → playwright-headful.json
  local prefix="$_TEST_STUB_DIR/headful-on"
  local rc
  rc="$(run_main_behavioral ui "$REAL_HARNESS_ROOT" "$prefix" 1)"
  if [[ "$rc" == "0" ]]; then
    ok "ui HEADFUL=1: main exits 0 (behavioral)"
  else
    ng "ui HEADFUL=1: main exits 0 (behavioral)" "rc=$rc; stderr=$(cat "$prefix.stderr" 2>/dev/null | head -3)"
  fi
  contains "ui HEADFUL=1: argv names playwright-headful.json" \
    'playwright-headful.json' "$(cat "$prefix.argv")"

  # HEADFUL unset → playwright.json (default)
  prefix="$_TEST_STUB_DIR/headful-off"
  rc="$(run_main_behavioral ui "$REAL_HARNESS_ROOT" "$prefix")"
  if [[ "$rc" == "0" ]]; then
    ok "ui HEADFUL unset: main exits 0 (behavioral)"
  else
    ng "ui HEADFUL unset: main exits 0 (behavioral)" "rc=$rc; stderr=$(cat "$prefix.stderr" 2>/dev/null | head -3)"
  fi
  # Strict tail-match: argv must end in /mcp/playwright.json, NOT
  # /mcp/playwright-headful.json. The byte-strict grep guards against
  # an accidental swap of the default branch.
  local argv_body
  argv_body="$(cat "$prefix.argv")"
  contains "ui HEADFUL unset: argv names /mcp/playwright.json" \
    '/mcp/playwright.json' "$argv_body"
  notcontains "ui HEADFUL unset: argv does NOT name playwright-headful.json" \
    'playwright-headful.json' "$argv_body"
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
