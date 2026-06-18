#!/usr/bin/env bash
# Unit tests for bin/main-green-check.sh.
# Source-and-stub pattern mirroring bin/stuck-tick-alarm-test.sh.
# Stubs: bin/slack.sh, bin/metrics.sh. The git/gate seams
# (_origin_main_sha, _run_main_gate, _default_branch) are overridden so no
# real git or 268s suite run is needed.

set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY=test-mock-key
export PROJECT_SLUG=test-slug

_TEST_HARNESS_STATE_DIR="$(mktemp -d)"
_TEST_HARNESS_CONFIG_DIR="$(mktemp -d)"
_TEST_STUB_DIR="$(mktemp -d)"
TGT="$(mktemp -d)"
_test_assert_temp_path() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
    *) printf 'REFUSING: path %q is not a platform temp dir\n' "$1" >&2; exit 99 ;;
  esac
}
_test_assert_temp_path "$_TEST_HARNESS_STATE_DIR"
_test_assert_temp_path "$_TEST_HARNESS_CONFIG_DIR"
_test_assert_temp_path "$_TEST_STUB_DIR"
_test_assert_temp_path "$TGT"
_test_safe_rm() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$1" ;;
    *) printf 'SAFETY: trap refusing rm -rf %q (not a temp dir)\n' "$1" >&2 ;;
  esac
}
trap '_test_safe_rm "$_TEST_STUB_DIR"; _test_safe_rm "$_TEST_HARNESS_STATE_DIR"; _test_safe_rm "$_TEST_HARNESS_CONFIG_DIR"; _test_safe_rm "$TGT"' EXIT

HARNESS_STATE_DIR="$_TEST_HARNESS_STATE_DIR"
export HARNESS_STATE_DIR
# Redirect HARNESS_CONFIG_DIR via XDG_CONFIG_HOME (common.sh derives it there).
# Seed secrets.env so the source block exports PIPELINE_SLACK_WEBHOOK_URL.
XDG_CONFIG_HOME="$_TEST_HARNESS_CONFIG_DIR"
export XDG_CONFIG_HOME
mkdir -p "$XDG_CONFIG_HOME/twinning-harness"
printf 'PIPELINE_SLACK_WEBHOOK_URL=https://hooks.slack.test/AC-SECRETS-ENV-sentinel\n' \
  > "$XDG_CONFIG_HOME/twinning-harness/secrets.env"
PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
export PROJECT_STATE_DIR
mkdir -p "$PROJECT_STATE_DIR/metrics"

mkdir -p "$TGT/.pipeline-config/schemas"
printf '{"project":{"slug":"test-slug"},"linear":{"team_id":"t","project_id":"p"},"orchestrator":{}}\n' \
  > "$TGT/.pipeline-config/config.json"
export TARGET_REPO="$TGT"

STUB_DIR="$_TEST_STUB_DIR"
METRICS_CAPTURE="$PROJECT_STATE_DIR/metrics/events.jsonl"
SLACK_CAPTURE="$STUB_DIR/slack-calls.log"
GATE_CALLED="$STUB_DIR/gate-called"

# ─── Stubs ───────────────────────────────────────────────────────────────────
cat > "$STUB_DIR/metrics.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
event="\${1:-}" issue_id="\${2:-}" stage="\${3:-}" outcome="\${4:-}" duration_ms="\${5:-0}"
shift 5 || true
notes="\${*:-}"
iso_ts="\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -cn --arg ts "\$iso_ts" --arg event "\$event" --arg issue_id "\$issue_id" \\
       --arg stage "\$stage" --arg outcome "\$outcome" \\
       --argjson duration_ms "\${duration_ms:-0}" --arg notes "\$notes" \\
       '{ts:\$ts, event:\$event, issue_id:\$issue_id, stage:\$stage, outcome:\$outcome, duration_ms:\$duration_ms, notes:\$notes}' \\
  >> "$METRICS_CAPTURE"
SH
chmod +x "$STUB_DIR/metrics.sh"

cat > "$STUB_DIR/slack.sh" <<SH
#!/usr/bin/env bash
printf '%s\t%s\tPIPELINE_SLACK_WEBHOOK_URL=%s\n' \\
  "\${1:-}" "\${2:-}" "\${PIPELINE_SLACK_WEBHOOK_URL:-<unset>}" >> "$SLACK_CAPTURE"
SH
chmod +x "$STUB_DIR/slack.sh"

# ─── Source the script (sentinel bypasses main) ──────────────────────────────
# shellcheck source=main-green-check.sh
source "$SCRIPT_DIR_REAL/main-green-check.sh"
SCRIPT_DIR="$STUB_DIR"
STATE_FILE="$PROJECT_STATE_DIR/.main-green-state"
DEBOUNCE_FILE="$PROJECT_STATE_DIR/.main-green-last-alerted"

# ─── Mock the git/gate seams ─────────────────────────────────────────────────
MOCK_SHA="aaaaaaaaaaaa1111"
MOCK_GATE_RC=0
MOCK_GATE_SUMMARY=""
_default_branch() { printf 'main\n'; }
_origin_main_sha() { printf '%s\n' "$MOCK_SHA"; }
_run_main_gate() { touch "$GATE_CALLED"; printf '%s\n' "$MOCK_GATE_SUMMARY"; return "$MOCK_GATE_RC"; }

# ─── Helpers ─────────────────────────────────────────────────────────────────
PASS=0; FAIL=0
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
fail_at() { printf '  ❌ %s — %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }
_reset() {
  rm -f "$METRICS_CAPTURE" "$SLACK_CAPTURE" "$DEBOUNCE_FILE" "$STATE_FILE" "$GATE_CALLED"
  touch "$METRICS_CAPTURE"
  unset MAIN_GREEN_CHECK_DISABLED
}
_metrics_count() { wc -l < "$METRICS_CAPTURE" 2>/dev/null | tr -d ' ' || printf '0'; }
_slack_count() { [[ -f "$SLACK_CAPTURE" ]] && wc -l < "$SLACK_CAPTURE" | tr -d ' ' || printf '0'; }

# ─── AC-GREEN-NEW ────────────────────────────────────────────────────────────
printf '\n--- AC-GREEN-NEW: new SHA, gate passes → state ok, no alert ---\n'
_reset; MOCK_SHA="green0001"; MOCK_GATE_RC=0; MOCK_GATE_SUMMARY=""
main
[[ "$(_metrics_count)" -eq 0 ]] && pass_at "AC-GREEN-NEW: no metric" || fail_at "AC-GREEN-NEW: no metric" "got $(_metrics_count)"
[[ "$(_slack_count)" -eq 0 ]] && pass_at "AC-GREEN-NEW: no Slack" || fail_at "AC-GREEN-NEW: no Slack" "got $(_slack_count)"
[[ "$(cat "$STATE_FILE")" == "green0001 ok" ]] && pass_at "AC-GREEN-NEW: state recorded ok" || fail_at "AC-GREEN-NEW: state" "got '$(cat "$STATE_FILE" 2>/dev/null)'"
[[ -f "$GATE_CALLED" ]] && pass_at "AC-GREEN-NEW: gate was run" || fail_at "AC-GREEN-NEW: gate run" "gate not called"

# ─── AC-RED-NEW ──────────────────────────────────────────────────────────────
printf '\n--- AC-RED-NEW: new SHA, gate fails → metric + Slack + debounce + state red ---\n'
_reset; MOCK_SHA="red00001"; MOCK_GATE_RC=1; MOCK_GATE_SUMMARY="FAIL bin/foo-test.sh;1 failed"
main
[[ "$(_metrics_count)" -ge 1 ]] && pass_at "AC-RED-NEW: metric emitted" || fail_at "AC-RED-NEW: metric" "got 0"
[[ "$(_slack_count)" -ge 1 ]] && pass_at "AC-RED-NEW: Slack called" || fail_at "AC-RED-NEW: Slack" "got 0"
[[ -f "$DEBOUNCE_FILE" ]] && pass_at "AC-RED-NEW: debounce stamped" || fail_at "AC-RED-NEW: debounce" "missing"
[[ "$(cat "$STATE_FILE")" == "red00001 red" ]] && pass_at "AC-RED-NEW: state recorded red" || fail_at "AC-RED-NEW: state" "got '$(cat "$STATE_FILE" 2>/dev/null)'"
if jq -e '.event == "main-green-check"' "$METRICS_CAPTURE" >/dev/null 2>&1; then
  pass_at "AC-RED-NEW: metric event name is 'main-green-check'"
else fail_at "AC-RED-NEW: metric event name" "expected main-green-check"; fi
if jq -e '.notes | test("sha=red00001") and test("failing=")' "$METRICS_CAPTURE" >/dev/null 2>&1; then
  pass_at "AC-RED-NEW: metric notes carry sha=/failing="
else fail_at "AC-RED-NEW: metric notes" "missing sha=/failing="; fi
if grep -q $'^warn\t' "$SLACK_CAPTURE" && grep -q 'Main gate RED' "$SLACK_CAPTURE"; then
  pass_at "AC-RED-NEW: Slack payload uses warn level + 'Main gate RED' prefix"
else fail_at "AC-RED-NEW: Slack payload" "missing warn level or prefix"; fi

# ─── AC-RED-DEBOUNCED ────────────────────────────────────────────────────────
printf '\n--- AC-RED-DEBOUNCED: same red SHA again → metric only, Slack suppressed, NO gate rerun ---\n'
_reset; printf 'red00001 red\n' > "$STATE_FILE"; MOCK_SHA="red00001"
date -u +%Y-%m-%dT%H:%M:%SZ > "$DEBOUNCE_FILE"   # recent debounce
main
[[ "$(_metrics_count)" -ge 1 ]] && pass_at "AC-RED-DEBOUNCED: metric still emitted (level-triggered)" || fail_at "AC-RED-DEBOUNCED: metric" "got 0"
[[ "$(_slack_count)" -eq 0 ]] && pass_at "AC-RED-DEBOUNCED: Slack suppressed" || fail_at "AC-RED-DEBOUNCED: Slack" "got $(_slack_count)"
[[ ! -f "$GATE_CALLED" ]] && pass_at "AC-RED-DEBOUNCED: gate NOT re-run on unchanged SHA" || fail_at "AC-RED-DEBOUNCED: gate rerun" "gate ran on unchanged SHA"

# ─── AC-UNCHANGED-GREEN ──────────────────────────────────────────────────────
printf '\n--- AC-UNCHANGED-GREEN: same green SHA → nothing, no gate rerun ---\n'
_reset; printf 'green0001 ok\n' > "$STATE_FILE"; MOCK_SHA="green0001"
main
[[ "$(_metrics_count)" -eq 0 ]] && pass_at "AC-UNCHANGED-GREEN: no metric" || fail_at "AC-UNCHANGED-GREEN: metric" "got $(_metrics_count)"
[[ "$(_slack_count)" -eq 0 ]] && pass_at "AC-UNCHANGED-GREEN: no Slack" || fail_at "AC-UNCHANGED-GREEN: Slack" "got $(_slack_count)"
[[ ! -f "$GATE_CALLED" ]] && pass_at "AC-UNCHANGED-GREEN: gate NOT re-run" || fail_at "AC-UNCHANGED-GREEN: gate rerun" "gate ran"

# ─── AC-RECOVERY ─────────────────────────────────────────────────────────────
printf '\n--- AC-RECOVERY: was red, new SHA passes → state ok, info Slack, debounce cleared ---\n'
_reset; printf 'red00001 red\n' > "$STATE_FILE"; date -u +%Y-%m-%dT%H:%M:%SZ > "$DEBOUNCE_FILE"
MOCK_SHA="green0002"; MOCK_GATE_RC=0; MOCK_GATE_SUMMARY=""
main
[[ "$(cat "$STATE_FILE")" == "green0002 ok" ]] && pass_at "AC-RECOVERY: state flipped to ok" || fail_at "AC-RECOVERY: state" "got '$(cat "$STATE_FILE" 2>/dev/null)'"
if grep -q $'^info\t' "$SLACK_CAPTURE" && grep -q 'GREEN again' "$SLACK_CAPTURE"; then
  pass_at "AC-RECOVERY: info Slack 'GREEN again' posted"
else fail_at "AC-RECOVERY: recovery Slack" "missing info/GREEN again"; fi
[[ ! -f "$DEBOUNCE_FILE" ]] && pass_at "AC-RECOVERY: debounce cleared" || fail_at "AC-RECOVERY: debounce" "still present"

# ─── AC-FETCH-FAIL ───────────────────────────────────────────────────────────
printf '\n--- AC-FETCH-FAIL: empty SHA (fetch failed) → fail-open, no alert, no gate ---\n'
_reset; MOCK_SHA=""; MOCK_GATE_RC=1
main
[[ "$(_metrics_count)" -eq 0 ]] && pass_at "AC-FETCH-FAIL: no metric" || fail_at "AC-FETCH-FAIL: metric" "got $(_metrics_count)"
[[ "$(_slack_count)" -eq 0 ]] && pass_at "AC-FETCH-FAIL: no Slack" || fail_at "AC-FETCH-FAIL: Slack" "got $(_slack_count)"
[[ ! -f "$GATE_CALLED" ]] && pass_at "AC-FETCH-FAIL: gate not run" || fail_at "AC-FETCH-FAIL: gate" "gate ran"

# ─── AC-DISABLED ─────────────────────────────────────────────────────────────
printf '\n--- AC-DISABLED: MAIN_GREEN_CHECK_DISABLED=1 → no-op even with red gate ---\n'
_reset; MOCK_SHA="red00009"; MOCK_GATE_RC=1; MOCK_GATE_SUMMARY="FAIL"
MAIN_GREEN_CHECK_DISABLED=1
main
[[ "$(_metrics_count)" -eq 0 ]] && pass_at "AC-DISABLED: no metric" || fail_at "AC-DISABLED: metric" "got $(_metrics_count)"
[[ "$(_slack_count)" -eq 0 ]] && pass_at "AC-DISABLED: no Slack" || fail_at "AC-DISABLED: Slack" "got $(_slack_count)"
[[ ! -f "$GATE_CALLED" ]] && pass_at "AC-DISABLED: gate not run" || fail_at "AC-DISABLED: gate" "gate ran"
unset MAIN_GREEN_CHECK_DISABLED

# ─── AC-SECRETS-ENV ──────────────────────────────────────────────────────────
printf '\n--- AC-SECRETS-ENV: secrets.env PIPELINE_SLACK_WEBHOOK_URL reaches slack.sh ---\n'
_reset; MOCK_SHA="red00010"; MOCK_GATE_RC=1; MOCK_GATE_SUMMARY="FAIL"
main
if grep -q 'PIPELINE_SLACK_WEBHOOK_URL=https://hooks.slack.test/AC-SECRETS-ENV-sentinel' "$SLACK_CAPTURE"; then
  pass_at "AC-SECRETS-ENV: webhook URL reached slack.sh stub"
else fail_at "AC-SECRETS-ENV: secrets source block" "slack capture: $(cat "$SLACK_CAPTURE" 2>/dev/null || printf '<empty>')"; fi

# ─── Summary ─────────────────────────────────────────────────────────────────
printf '\n  passed: %d\n  failed: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
