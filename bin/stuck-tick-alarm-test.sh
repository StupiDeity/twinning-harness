#!/usr/bin/env bash
# Unit tests for bin/stuck-tick-alarm.sh (ENG-132).
# Source-and-stub pattern mirroring bin/halt-sprawl-test.sh.
# Stubs: bin/slack.sh, bin/metrics.sh.  No Linear stub needed.

set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY=test-mock-key
export PROJECT_SLUG=test-slug

_TEST_HARNESS_STATE_DIR="$(mktemp -d)"
_TEST_STUB_DIR="$(mktemp -d)"
_test_assert_temp_path() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
    *) printf 'REFUSING: path %q is not a platform temp dir\n' "$1" >&2; exit 99 ;;
  esac
}
_test_assert_temp_path "$_TEST_HARNESS_STATE_DIR"
_test_assert_temp_path "$_TEST_STUB_DIR"
_test_safe_rm() {
  local path="$1"
  case "$path" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$path" ;;
    *) printf 'SAFETY: trap refusing rm -rf %q (not a temp dir)\n' "$path" >&2 ;;
  esac
}
trap '_test_safe_rm "$_TEST_STUB_DIR"; _test_safe_rm "$_TEST_HARNESS_STATE_DIR"' EXIT

HARNESS_STATE_DIR="$_TEST_HARNESS_STATE_DIR"
export HARNESS_STATE_DIR
PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
export PROJECT_STATE_DIR
mkdir -p "$PROJECT_STATE_DIR/metrics"

STUB_DIR="$_TEST_STUB_DIR"
METRICS_CAPTURE="$PROJECT_STATE_DIR/metrics/events.jsonl"
SLACK_CAPTURE="$STUB_DIR/slack-calls.log"

# Minimal target repo so common.sh's TARGET_REPO check passes.
TGT="$(mktemp -d)"
_test_assert_temp_path "$TGT"
trap '_test_safe_rm "$_TEST_STUB_DIR"; _test_safe_rm "$_TEST_HARNESS_STATE_DIR"; _test_safe_rm "$TGT"' EXIT
mkdir -p "$TGT/.pipeline-config/schemas"
printf '{"project":{"slug":"test-slug"},"linear":{"team_id":"t","project_id":"p"},"orchestrator":{}}\n' \
  > "$TGT/.pipeline-config/config.json"
export TARGET_REPO="$TGT"

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
printf '%s\t%s\n' "\${1:-}" "\${2:-}" >> "$SLACK_CAPTURE"
SH
chmod +x "$STUB_DIR/slack.sh"

# ─── Source alarm script (sentinel bypasses main) ─────────────────────────────
# shellcheck source=stuck-tick-alarm.sh
source "$SCRIPT_DIR_REAL/stuck-tick-alarm.sh"
SCRIPT_DIR="$STUB_DIR"

# Let tests override HEARTBEAT_FILE and DEBOUNCE_FILE per-AC.
# Defaults point into PROJECT_STATE_DIR.

# ─── Test helpers ─────────────────────────────────────────────────────────────
PASS=0; FAIL=0
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
fail_at() { printf '  ❌ %s — %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

_reset_captures() {
  rm -f "$METRICS_CAPTURE" "$SLACK_CAPTURE"
  rm -f "$DEBOUNCE_FILE"
  touch "$METRICS_CAPTURE"
  unset STUCK_TICK_ALARM_MINUTES
}

_metrics_count() {
  wc -l < "$METRICS_CAPTURE" 2>/dev/null || printf '0'
}

_slack_count() {
  wc -l < "$SLACK_CAPTURE" 2>/dev/null || printf '0'
}

# Back-date a file by N seconds on macOS (BSD touch -A requires HH[MM[SS]])
# or via setting mtime explicitly. We use a tempfile + touch approach:
# touch -t YYYYMMDDHHMM.SS is portable across BSD/GNU.
_backdate_file() {
  local file="$1" seconds="$2"
  local ts
  ts="$(date -u -v -${seconds}S +%Y%m%d%H%M.%S 2>/dev/null || \
        date -u -d "@$(( $(date -u +%s) - seconds ))" +%Y%m%d%H%M.%S 2>/dev/null)"
  touch -t "$ts" "$file"
}

# ─── AC-FRESH ─────────────────────────────────────────────────────────────────
printf '\n--- AC-FRESH: fresh heartbeat → no alert ---\n'
HEARTBEAT_FILE="$PROJECT_STATE_DIR/.last-tick-end"
DEBOUNCE_FILE="$PROJECT_STATE_DIR/.stuck-tick-last-alerted"
CONFIG="$TGT/.pipeline-config/config.json"
export CONFIG
_reset_captures
touch "$HEARTBEAT_FILE"   # mtime ≈ now
main
mc="$(_metrics_count | tr -d ' ')"
sc="$(_slack_count | tr -d ' ')"
[[ "$mc" -eq 0 ]] \
  && pass_at "AC-FRESH: no metric emitted" \
  || fail_at "AC-FRESH: no metric" "got $mc metric line(s)"
[[ "$sc" -eq 0 ]] \
  && pass_at "AC-FRESH: no Slack call" \
  || fail_at "AC-FRESH: no Slack" "got $sc Slack call(s)"
[[ ! -f "$DEBOUNCE_FILE" ]] \
  && pass_at "AC-FRESH: no debounce stamp written" \
  || fail_at "AC-FRESH: no debounce stamp" "debounce file created unexpectedly"

# ─── AC-STALE ─────────────────────────────────────────────────────────────────
printf '\n--- AC-STALE: stale heartbeat → metric + Slack + debounce ---\n'
_reset_captures
touch "$HEARTBEAT_FILE"
_backdate_file "$HEARTBEAT_FILE" 1860   # 31 min ago (> default 30 min threshold)
main
mc="$(_metrics_count | tr -d ' ')"
sc="$(_slack_count | tr -d ' ')"
[[ "$mc" -ge 1 ]] \
  && pass_at "AC-STALE: metric emitted" \
  || fail_at "AC-STALE: metric emitted" "got 0 metric lines"
[[ "$sc" -ge 1 ]] \
  && pass_at "AC-STALE: Slack called" \
  || fail_at "AC-STALE: Slack called" "got 0 Slack calls"
[[ -f "$DEBOUNCE_FILE" ]] \
  && pass_at "AC-STALE: debounce stamp written" \
  || fail_at "AC-STALE: debounce stamp" "debounce file missing"
# Verify metric event name
if jq -e '.event == "stuck-tick"' "$METRICS_CAPTURE" >/dev/null 2>&1; then
  pass_at "AC-STALE: metric event name is 'stuck-tick'"
else
  fail_at "AC-STALE: metric event name" "expected 'stuck-tick' in events.jsonl"
fi
# Verify metric .notes fields carry structured triage data (age=, threshold=, holder_pid=)
if jq -e '.notes | test("age=[0-9]+") and test("threshold=[0-9]+") and test("holder_pid=")' \
     "$METRICS_CAPTURE" >/dev/null 2>&1; then
  pass_at "AC-STALE: metric notes carry age/threshold/holder_pid"
else
  fail_at "AC-STALE: metric notes" "missing structured fields (age=, threshold=, holder_pid=)"
fi
# Verify Slack payload uses warn level and 'Stuck tick alarm' prefix (operator-visible)
if grep -q $'^warn\t' "$SLACK_CAPTURE" && grep -q 'Stuck tick alarm' "$SLACK_CAPTURE"; then
  pass_at "AC-STALE: Slack payload uses warn level + alarm prefix"
else
  fail_at "AC-STALE: Slack payload" "missing 'warn' level or 'Stuck tick alarm' prefix"
fi

# ─── AC-DEBOUNCED ─────────────────────────────────────────────────────────────
printf '\n--- AC-DEBOUNCED: stale + recent debounce → metric only (no Slack) ---\n'
_reset_captures
touch "$HEARTBEAT_FILE"
_backdate_file "$HEARTBEAT_FILE" 1860   # 31 min stale
# Write a debounce stamp with mtime = now (within 24h)
date -u +%Y-%m-%dT%H:%M:%SZ > "$DEBOUNCE_FILE"
main
mc="$(_metrics_count | tr -d ' ')"
sc="$(_slack_count | tr -d ' ')"
[[ "$mc" -ge 1 ]] \
  && pass_at "AC-DEBOUNCED: metric still emitted (level-triggered)" \
  || fail_at "AC-DEBOUNCED: metric emitted" "got 0 metric lines"
[[ "$sc" -eq 0 ]] \
  && pass_at "AC-DEBOUNCED: Slack suppressed by debounce" \
  || fail_at "AC-DEBOUNCED: Slack suppressed" "got $sc Slack call(s)"

# ─── AC-MISSING-HEARTBEAT ─────────────────────────────────────────────────────
printf '\n--- AC-MISSING-HEARTBEAT: absent heartbeat → treated as worst-case stale ---\n'
_reset_captures
rm -f "$HEARTBEAT_FILE"
main
mc="$(_metrics_count | tr -d ' ')"
sc="$(_slack_count | tr -d ' ')"
[[ "$mc" -ge 1 ]] \
  && pass_at "AC-MISSING-HEARTBEAT: metric emitted" \
  || fail_at "AC-MISSING-HEARTBEAT: metric" "got 0 metric lines"
[[ "$sc" -ge 1 ]] \
  && pass_at "AC-MISSING-HEARTBEAT: Slack called" \
  || fail_at "AC-MISSING-HEARTBEAT: Slack" "got 0 Slack calls"

# ─── AC-MALFORMED-TIMESTAMP ───────────────────────────────────────────────────
printf '\n--- AC-MALFORMED-TIMESTAMP: garbage content, mtime past threshold → alarm fires ---\n'
_reset_captures
printf 'not-a-timestamp\n' > "$HEARTBEAT_FILE"
_backdate_file "$HEARTBEAT_FILE" 1860   # 31 min stale mtime
main
mc="$(_metrics_count | tr -d ' ')"
[[ "$mc" -ge 1 ]] \
  && pass_at "AC-MALFORMED-TIMESTAMP: alarm fires on stale mtime despite garbage content" \
  || fail_at "AC-MALFORMED-TIMESTAMP: alarm fires" "got 0 metric lines"

printf '\n--- AC-MALFORMED-TIMESTAMP (fresh mtime): garbage content, fresh mtime → no alarm ---\n'
_reset_captures
printf 'not-a-timestamp\n' > "$HEARTBEAT_FILE"
touch "$HEARTBEAT_FILE"   # fresh mtime
main
mc="$(_metrics_count | tr -d ' ')"
[[ "$mc" -eq 0 ]] \
  && pass_at "AC-MALFORMED-TIMESTAMP (fresh): no alarm when mtime is fresh" \
  || fail_at "AC-MALFORMED-TIMESTAMP (fresh): no alarm" "got $mc metric line(s)"

# ─── AC-CONFIG-DEFAULT ────────────────────────────────────────────────────────
printf '\n--- AC-CONFIG-DEFAULT: absent config key → default 30 min applies ---\n'
_reset_captures
jq -n '{project:{slug:"test-slug"},linear:{team_id:"t",project_id:"p"},orchestrator:{}}' \
  > "$TGT/.pipeline-config/config.json"
touch "$HEARTBEAT_FILE"
_backdate_file "$HEARTBEAT_FILE" 1860   # 31 min > default 30 min
main
mc="$(_metrics_count | tr -d ' ')"
[[ "$mc" -ge 1 ]] \
  && pass_at "AC-CONFIG-DEFAULT: alarm fires with default 30 min threshold" \
  || fail_at "AC-CONFIG-DEFAULT: alarm fires" "got 0 metric lines"

# ─── AC-CONFIG-OVERRIDE ───────────────────────────────────────────────────────
printf '\n--- AC-CONFIG-OVERRIDE: stuck_tick_alarm_minutes=45 → 45 min threshold ---\n'
jq -n '{project:{slug:"test-slug"},linear:{team_id:"t",project_id:"p"},orchestrator:{stuck_tick_alarm_minutes:45}}' \
  > "$TGT/.pipeline-config/config.json"

# 31 min stale → below 45 min threshold → no alarm
_reset_captures
touch "$HEARTBEAT_FILE"
_backdate_file "$HEARTBEAT_FILE" 1860
main
mc="$(_metrics_count | tr -d ' ')"
[[ "$mc" -eq 0 ]] \
  && pass_at "AC-CONFIG-OVERRIDE: no alarm at 31 min with 45 min threshold" \
  || fail_at "AC-CONFIG-OVERRIDE: no alarm" "got $mc metric line(s)"

# 46 min stale → above 45 min threshold → alarm
_reset_captures
touch "$HEARTBEAT_FILE"
_backdate_file "$HEARTBEAT_FILE" 2760   # 46 min
main
mc="$(_metrics_count | tr -d ' ')"
[[ "$mc" -ge 1 ]] \
  && pass_at "AC-CONFIG-OVERRIDE: alarm fires at 46 min with 45 min threshold" \
  || fail_at "AC-CONFIG-OVERRIDE: alarm fires" "got 0 metric lines"

# Restore default config
jq -n '{project:{slug:"test-slug"},linear:{team_id:"t",project_id:"p"},orchestrator:{}}' \
  > "$TGT/.pipeline-config/config.json"

# ─── AC-CONFIG-BELOW-FLOOR ────────────────────────────────────────────────────
printf '\n--- AC-CONFIG-BELOW-FLOOR: stuck_tick_alarm_minutes=5 → falls through to default 30 ---\n'
jq -n '{project:{slug:"test-slug"},linear:{team_id:"t",project_id:"p"},orchestrator:{stuck_tick_alarm_minutes:5}}' \
  > "$TGT/.pipeline-config/config.json"

# 6 min stale → below the floor-fallback of 30 min → no alarm
_reset_captures
touch "$HEARTBEAT_FILE"
_backdate_file "$HEARTBEAT_FILE" 360    # 6 min
main
mc="$(_metrics_count | tr -d ' ')"
[[ "$mc" -eq 0 ]] \
  && pass_at "AC-CONFIG-BELOW-FLOOR: no alarm at 6 min (default 30 applies)" \
  || fail_at "AC-CONFIG-BELOW-FLOOR: no alarm" "got $mc metric line(s)"

# 31 min stale → above the floor-fallback of 30 min → alarm
_reset_captures
touch "$HEARTBEAT_FILE"
_backdate_file "$HEARTBEAT_FILE" 1860   # 31 min
main
mc="$(_metrics_count | tr -d ' ')"
[[ "$mc" -ge 1 ]] \
  && pass_at "AC-CONFIG-BELOW-FLOOR: alarm fires at 31 min (default 30 applies)" \
  || fail_at "AC-CONFIG-BELOW-FLOOR: alarm fires" "got 0 metric lines"

# Restore default config
jq -n '{project:{slug:"test-slug"},linear:{team_id:"t",project_id:"p"},orchestrator:{}}' \
  > "$TGT/.pipeline-config/config.json"

# ─── AC-CONFIG-NON-INTEGER ────────────────────────────────────────────────────
printf '\n--- AC-CONFIG-NON-INTEGER: stuck_tick_alarm_minutes="30m" → falls through to default 30 ---\n'
jq -n '{project:{slug:"test-slug"},linear:{team_id:"t",project_id:"p"},orchestrator:{stuck_tick_alarm_minutes:"30m"}}' \
  > "$TGT/.pipeline-config/config.json"

# 31 min stale → alarm fires with default 30 (non-integer falls through)
_reset_captures
touch "$HEARTBEAT_FILE"
_backdate_file "$HEARTBEAT_FILE" 1860
main
mc="$(_metrics_count | tr -d ' ')"
[[ "$mc" -ge 1 ]] \
  && pass_at "AC-CONFIG-NON-INTEGER: alarm fires (default 30 applied)" \
  || fail_at "AC-CONFIG-NON-INTEGER: alarm fires" "got 0 metric lines"

# Restore default config
jq -n '{project:{slug:"test-slug"},linear:{team_id:"t",project_id:"p"},orchestrator:{}}' \
  > "$TGT/.pipeline-config/config.json"

# ─── AC-ENV-OVERRIDE ──────────────────────────────────────────────────────────
printf '\n--- AC-ENV-OVERRIDE: STUCK_TICK_ALARM_MINUTES=20 → env wins ---\n'
_reset_captures
STUCK_TICK_ALARM_MINUTES=20
export STUCK_TICK_ALARM_MINUTES
touch "$HEARTBEAT_FILE"
_backdate_file "$HEARTBEAT_FILE" 1260   # 21 min stale → above 20 min
main
mc="$(_metrics_count | tr -d ' ')"
[[ "$mc" -ge 1 ]] \
  && pass_at "AC-ENV-OVERRIDE: alarm fires at 21 min with env-override 20 min" \
  || fail_at "AC-ENV-OVERRIDE: alarm fires" "got 0 metric lines"
unset STUCK_TICK_ALARM_MINUTES

# ─── Summary ──────────────────────────────────────────────────────────────────
printf '\n  passed: %d\n  failed: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  :  # already ran above when executed directly
fi
