#!/usr/bin/env bash
# QA-authored adversarial coverage for _poll_emit_halt_sprawl_alert (ENG-21).
# These cases are NOT in the plan's Failure Mode → Test Map; they exercise
# brainstorm "Test Strategy → Adversarial" rows that the plan only covered
# by code-inspection, plus boundary inputs not enumerated in the plan.
#
# Mirrors the harness shape of halt-sprawl-test.sh.

set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR_REAL/common.sh"

export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"

_TEST_TWINNING_DIR="$(mktemp -d)"
_TEST_STUB_DIR="$(mktemp -d)"
_test_assert_temp_path() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
    *) printf 'REFUSING: path %q is not a platform temp dir\n' "$1" >&2; exit 99 ;;
  esac
}
_test_assert_temp_path "$_TEST_TWINNING_DIR"
_test_assert_temp_path "$_TEST_STUB_DIR"
_test_safe_rm() {
  local path="$1"
  case "$path" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$path" ;;
    *) printf 'SAFETY: trap refusing rm -rf %q (not a temp dir)\n' "$path" >&2 ;;
  esac
}
trap '_test_safe_rm "$_TEST_STUB_DIR"; _test_safe_rm "$_TEST_TWINNING_DIR"' EXIT

TWINNING_DIR="$_TEST_TWINNING_DIR"
export TWINNING_DIR
STUB_DIR="$_TEST_STUB_DIR"
METRICS_FILE="$TWINNING_DIR/metrics/events.jsonl"
DEBOUNCE_FILE="$TWINNING_DIR/.halt-sprawl-last-alerted"
SLACK_CAPTURE="$STUB_DIR/slack-calls.log"
mkdir -p "$(dirname "$METRICS_FILE")"
export METRICS_FILE DEBOUNCE_FILE SLACK_CAPTURE

# Default stubs (overridable per-test via reinstall_default_metrics_stub /
# install_failing_metrics_stub).
install_default_metrics_stub() {
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
  >> "$METRICS_FILE"
SH
  chmod +x "$STUB_DIR/metrics.sh"
}

install_failing_metrics_stub() {
  cat > "$STUB_DIR/metrics.sh" <<'SH'
#!/usr/bin/env bash
echo "metrics: simulated disk failure" >&2
exit 1
SH
  chmod +x "$STUB_DIR/metrics.sh"
}

cat > "$STUB_DIR/slack.sh" <<SH
#!/usr/bin/env bash
printf '%s\t%s\n' "\${1:-}" "\${2:-}" >> "$SLACK_CAPTURE"
SH
chmod +x "$STUB_DIR/slack.sh"

install_default_metrics_stub

# shellcheck source=poll.sh
source "$SCRIPT_DIR_REAL/poll.sh"
SCRIPT_DIR="$STUB_DIR"
_VH_SCRIPT_DIR="$STUB_DIR"
TWINNING_DIR="$_TEST_TWINNING_DIR"
export TWINNING_DIR

git() {
  if [[ "$1" == "-C" && "$3" == "ls-remote" ]]; then
    printf ''; return 0
  fi
  command git "$@"
}

PASS=0; FAIL=0
fail_at() { printf '  ❌ %s\n      %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
reset_state() { : > "$METRICS_FILE"; rm -f "$DEBOUNCE_FILE"; : > "$SLACK_CAPTURE"; }

count_metric_events() {
  jq -c --arg o "$1" 'select(.event=="halt-sprawl" and .outcome==$o)' \
    "$METRICS_FILE" | wc -l | tr -d ' '
}
slack_call_count() { wc -l < "$SLACK_CAPTURE" | tr -d ' '; }

# Six halted classified entries — above the default threshold of 5 in the
# repo's live config — used by every case below unless overridden.
DEFAULT_CLASSIFIED='[
  {"identifier":"ENG-901","slot":"vacate"},
  {"identifier":"ENG-902","slot":"vacate"},
  {"identifier":"ENG-903","slot":"vacate"},
  {"identifier":"ENG-904","slot":"vacate"},
  {"identifier":"ENG-905","slot":"vacate"},
  {"identifier":"ENG-906","slot":"vacate"}
]'

# ─── ADV-DEBOUNCE-FUTURE: future-dated debounce stamp → slack silent ──
# Brainstorm Test Strategy adversarial row 2: "future timestamp →
# now-last < 0, NOT > 86400, slack stays silent" — documented but had
# no executable assertion. Boundary test for the comparison.
reset_state
future_ts="$(date -u -v+25H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d '25 hours' +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$future_ts" > "$DEBOUNCE_FILE"
_poll_emit_halt_sprawl_alert "$DEFAULT_CLASSIFIED" 2>/dev/null || true
if [[ "$(count_metric_events alert)" == "1" ]] \
   && [[ "$(slack_call_count)" == "0" ]]; then
  pass_at "ADV-DEBOUNCE-FUTURE future stamp suppresses slack; metric still fires"
else
  fail_at "ADV-DEBOUNCE-FUTURE future stamp suppresses slack; metric still fires" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count)"
fi

# ─── ADV-DEBOUNCE-EMPTY: empty debounce file → treated as absent ─────
# Boundary: zero-byte file (touch only). The helper's `[[ -n "$stamp" ]]`
# guard skips date parsing; last_epoch stays "0"; slack fires.
reset_state
: > "$DEBOUNCE_FILE"
_poll_emit_halt_sprawl_alert "$DEFAULT_CLASSIFIED" 2>/dev/null || true
if [[ "$(count_metric_events alert)" == "1" ]] \
   && [[ "$(slack_call_count)" == "1" ]] \
   && [[ -s "$DEBOUNCE_FILE" ]]; then
  pass_at "ADV-DEBOUNCE-EMPTY empty file → slack fires; debounce restamped"
else
  fail_at "ADV-DEBOUNCE-EMPTY empty file → slack fires; debounce restamped" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count) stamped=$([[ -s $DEBOUNCE_FILE ]] && echo y || echo n)"
fi

# ─── ADV-DEBOUNCE-CORRUPT: unparseable content → falls through, fires ─
# Brainstorm Test Strategy adversarial row 1: "corrupt non-ISO-8601 →
# helper falls through to last_epoch=0 and re-fires (self-heals in one
# tick)". Plan said "implicitly covered by the `|| printf '0'` fallback"
# — no assertion. This makes the assertion explicit.
reset_state
printf 'not-a-date-at-all\n' > "$DEBOUNCE_FILE"
_poll_emit_halt_sprawl_alert "$DEFAULT_CLASSIFIED" 2>/dev/null || true
new_stamp="$(cat "$DEBOUNCE_FILE")"
if [[ "$(count_metric_events alert)" == "1" ]] \
   && [[ "$(slack_call_count)" == "1" ]] \
   && [[ "$new_stamp" != "not-a-date-at-all" ]] \
   && [[ "$new_stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  pass_at "ADV-DEBOUNCE-CORRUPT garbage stamp → slack fires; file self-heals to ISO-8601"
else
  fail_at "ADV-DEBOUNCE-CORRUPT garbage stamp → slack fires; file self-heals to ISO-8601" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count) new_stamp=$new_stamp"
fi

# ─── ADV-METRICS-FAIL: metrics.sh exit 1 → helper still completes ─────
# Plan's Failure-Mode row 12 said "manually verified during code review";
# this case exercises it for real. Helper's `|| true` precedent (poll.sh:235)
# must keep the tick alive so Slack still fires and the debounce is stamped.
reset_state
install_failing_metrics_stub
_poll_emit_halt_sprawl_alert "$DEFAULT_CLASSIFIED" 2>/dev/null
helper_rc=$?
install_default_metrics_stub
# No metric row should land (stub failed before write); slack should still
# fire because the metric is the FIRST step but is wrapped in `|| true`.
if [[ "$helper_rc" == "0" ]] \
   && [[ "$(count_metric_events alert)" == "0" ]] \
   && [[ "$(slack_call_count)" == "1" ]] \
   && [[ -s "$DEBOUNCE_FILE" ]]; then
  pass_at "ADV-METRICS-FAIL metrics.sh exits 1 → helper rc=0; slack still fires; debounce stamped"
else
  fail_at "ADV-METRICS-FAIL metrics.sh exits 1 → helper rc=0; slack still fires; debounce stamped" \
    "rc=$helper_rc metric=$(count_metric_events alert) slack=$(slack_call_count) stamped=$([[ -s $DEBOUNCE_FILE ]] && echo y || echo n)"
fi

# ─── ADV-LARGE-COUNT: 100 vacate entries → one metric, top-3 only ─────
# Boundary: very large input. Verifies (a) jq handles a sizeable array
# without falling over, (b) the slack body still names exactly the first
# three identifiers (no truncation issues), (c) metric notes report the
# correct count.
reset_state
big_classified="$(jq -nc '[range(0; 100) | {identifier: ("ENG-\(. + 1000)"), slot: "vacate"}]')"
_poll_emit_halt_sprawl_alert "$big_classified" 2>/dev/null || true
notes="$(jq -rc 'select(.event=="halt-sprawl") | .notes' "$METRICS_FILE" | tail -1)"
slack_body="$(awk -F'\t' 'NR==1{print $2}' "$SLACK_CAPTURE")"
if [[ "$(count_metric_events alert)" == "1" ]] \
   && [[ "$notes" == "count=100 threshold=5" ]] \
   && [[ "$(slack_call_count)" == "1" ]] \
   && [[ "$slack_body" == *"ENG-1000"* ]] \
   && [[ "$slack_body" == *"ENG-1001"* ]] \
   && [[ "$slack_body" == *"ENG-1002"* ]] \
   && [[ "$slack_body" != *"ENG-1003"* ]] \
   && [[ "$slack_body" == *"…"* ]]; then
  pass_at "ADV-LARGE-COUNT 100 vacate → 1 metric, slack body top-3 only with ellipsis"
else
  fail_at "ADV-LARGE-COUNT 100 vacate → 1 metric, slack body top-3 only with ellipsis" \
    "notes=$notes slack=$slack_body"
fi

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
