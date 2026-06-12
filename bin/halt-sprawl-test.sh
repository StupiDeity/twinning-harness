#!/usr/bin/env bash
# Integration tests for poll.sh's halt-sprawl alert emission (ENG-21).
# Runs under $PIPELINE_DRY_RUN=1 with stubbed linear.sh/metrics.sh/slack.sh.
# Fixture JSON files in $FIXTURE_DIR stand in for Linear GraphQL responses.

set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
# shellcheck source=common.sh
source "$SCRIPT_DIR_REAL/common.sh"

: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

# Allocate temp dirs captured into _TEST_* (never reassigned by sourcing
# common.sh / poll.sh). See ENG-20 incident 2026-04-24.
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
mkdir -p "$PROJECT_STATE_DIR"
STUB_DIR="$_TEST_STUB_DIR"
FIXTURE_DIR="$STUB_DIR/fixtures"
METRICS_FILE="$PROJECT_STATE_DIR/metrics/events.jsonl"
DEBOUNCE_FILE="$PROJECT_STATE_DIR/.halt-sprawl-last-alerted"
SLACK_CAPTURE="$STUB_DIR/slack-calls.log"
mkdir -p "$FIXTURE_DIR" "$(dirname "$METRICS_FILE")"
export FIXTURE_DIR METRICS_FILE DEBOUNCE_FILE SLACK_CAPTURE

# ─── Stub external scripts ───────────────────────────────────────────
# linear.sh: fixture-reader (same as poll-slot-test.sh).
cat > "$STUB_DIR/linear.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-issues-with-label)
    f="$FIXTURE_DIR/label-$(printf '%s' "$2" | tr ':' '-').json"
    [[ -f "$f" ]] && cat "$f" || printf '{"data":{"issues":{"nodes":[]}}}'
    ;;
  list-issues-in-state)
    f="$FIXTURE_DIR/state-$2.json"
    [[ -f "$f" ]] && cat "$f" || printf '{"data":{"issues":{"nodes":[]}}}'
    ;;
  get-comments)
    f="$FIXTURE_DIR/comments-$2.json"
    [[ -f "$f" ]] && cat "$f" || printf '[]'
    ;;
  remove-label|add-label|swap-stage|transition-state|add-comment|refresh-cache|stage-of|has-label)
    exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"

# metrics.sh: write a real jsonl line so tests can inspect the on-disk shape.
# Mirrors the real metrics.sh shape but skips HARNESS_STATE_DIR recomputation.
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

# slack.sh: log the call into $SLACK_CAPTURE for test assertions.
cat > "$STUB_DIR/slack.sh" <<SH
#!/usr/bin/env bash
printf '%s\t%s\n' "\${1:-}" "\${2:-}" >> "$SLACK_CAPTURE"
SH
chmod +x "$STUB_DIR/slack.sh"

# ─── Source poll.sh and override SCRIPT_DIR / HARNESS_STATE_DIR ────────────
# shellcheck source=poll.sh
source "$SCRIPT_DIR_REAL/poll.sh"
SCRIPT_DIR="$STUB_DIR"
_VH_SCRIPT_DIR="$STUB_DIR"
HARNESS_STATE_DIR="$_TEST_HARNESS_STATE_DIR"
export HARNESS_STATE_DIR
PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
export PROJECT_STATE_DIR

# Default CONFIG with alert_on_halted_over=5 — matches the live config's
# threshold so AC-THR-GT (count=6) and AC-DEBOUNCE-* (count=6) cases trip
# the alert. Cases that need a different threshold (AC-THR-EQ, AC-THR-ZERO,
# AC-CONFIG-ABSENT, AC-CONFIG-GARBAGE) override CONFIG locally via the
# SCRATCH_CONFIG pattern below.
CONFIG="$STUB_DIR/config.json"
jq -n '{orchestrator: {alert_on_halted_over: 5}}' > "$CONFIG"
export CONFIG

git() {
  if [[ "$1" == "-C" && "$3" == "ls-remote" ]]; then
    printf ''; return 0
  fi
  command git "$@"
}

# ─── Assertion helpers ────────────────────────────────────────────────
PASS=0; FAIL=0
fail_at() { printf '  ❌ %s\n      %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
reset_fixtures() { rm -f "$FIXTURE_DIR"/*.json; }
reset_state() { : > "$METRICS_FILE"; rm -f "$DEBOUNCE_FILE"; : > "$SLACK_CAPTURE"; }

# write_label_fixture <stage_label> <issue_spec>...
# issue_spec: "ENG-N|state_name|priority_int|comma,labels"
write_label_fixture() {
  local label="$1"; shift
  local nodes='[]'
  local spec
  for spec in "$@"; do
    IFS='|' read -r ident state prio labels <<<"$spec"
    local labels_array
    labels_array="$(jq -nc --arg s "$labels" '
      ($s | split(",")) | map(select(length>0)) | map({name: .})')"
    nodes="$(jq -c --argjson n "$nodes" --arg id "$ident" --arg st "$state" \
      --argjson p "$prio" --argjson l "$labels_array" \
      '$n + [{identifier:$id, state:{name:$st}, priority:$p, labels:{nodes:$l}}]' <<<"$nodes")"
  done
  local fname; fname="$(printf '%s' "$label" | tr ':' '-')"
  jq -nc --argjson nodes "$nodes" '{data:{issues:{nodes:$nodes}}}' \
    > "$FIXTURE_DIR/label-$fname.json"
}

# write_comments_fixture <issue_id> <body|createdAt>...
write_comments_fixture() {
  local ident="$1"; shift
  local arr='[]'
  local i=0
  for pair in "$@"; do
    local body="${pair%|*}" ts="${pair##*|}"
    arr="$(jq -c --arg id "c$i" --arg body "$body" --arg ts "$ts" \
      '. + [{id:$id, body:$body, createdAt:$ts}]' <<<"$arr")"
    i=$((i+1))
  done
  printf '%s' "$arr" > "$FIXTURE_DIR/comments-$ident.json"
}

# count_metric_events <outcome_value>
count_metric_events() {
  jq -c --arg o "$1" 'select(.event=="halt-sprawl" and .outcome==$o)' \
    "$METRICS_FILE" | wc -l | tr -d ' '
}

last_metric_notes() {
  jq -rc 'select(.event=="halt-sprawl") | .notes' "$METRICS_FILE" | tail -1
}

slack_call_count() { wc -l < "$SLACK_CAPTURE" | tr -d ' '; }

# ─── Test cases ───────────────────────────────────────────────────────

# ─── AC-THR-EQ: count == threshold → no metric, no Slack (strict GT) ──
# 5 halted issues, threshold 5 → no alert (D-002).
# ENG-90 D-004: items carry operator_action_required=true so the new
# inclusion-by-flag filter counts them. Without the field, the default-
# false hatch silently excludes — see AC-ADV-MISSING-FLAG.
reset_fixtures; reset_state
# Build a classified array of 5 vacate entries. We call the helper
# directly (unit layer) — no need to route through main/linear stubs.
classified='[
  {"identifier":"ENG-101","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-102","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-103","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-104","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-105","slot":"vacate","operator_action_required":true}
]'
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
if [[ "$(count_metric_events alert)" == "0" ]] \
   && [[ "$(slack_call_count)" == "0" ]]; then
  pass_at "AC-THR-EQ count==threshold emits nothing"
else
  fail_at "AC-THR-EQ count==threshold emits nothing" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count)"
fi

# ─── AC-THR-GT: count > threshold → metric fires; Slack fires once ────
# 7 halted issues, threshold 5 → metric notes exactly "count=7 threshold=5"
# and Slack is called with level=warn and body containing top-3 identifiers.
reset_fixtures; reset_state
classified='[
  {"identifier":"ENG-201","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-202","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-203","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-204","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-205","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-206","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-207","slot":"vacate","operator_action_required":true}
]'
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
notes="$(last_metric_notes)"
slack_body="$(awk -F'\t' 'NR==1{print $2}' "$SLACK_CAPTURE")"
slack_level="$(awk -F'\t' 'NR==1{print $1}' "$SLACK_CAPTURE")"
if [[ "$(count_metric_events alert)" == "1" ]] \
   && [[ "$notes" == "count=7 threshold=5" ]] \
   && [[ "$(slack_call_count)" == "1" ]] \
   && [[ "$slack_level" == "warn" ]] \
   && [[ "$slack_body" == *"ENG-201"* ]] \
   && [[ "$slack_body" == *"ENG-202"* ]] \
   && [[ "$slack_body" == *"ENG-203"* ]] \
   && [[ "$slack_body" == *"threshold 5"* ]]; then
  pass_at "AC-THR-GT count>threshold emits metric + slack with top-3"
else
  fail_at "AC-THR-GT count>threshold emits metric + slack with top-3" \
    "notes=$notes slack=$slack_body"
fi

# ─── AC-THR-ZERO: threshold == 0 + count == 1 → alert fires ───────────
# Operator explicitly set threshold=0 to alert on any sprawl.
reset_fixtures; reset_state
# Temporarily override the config read by writing a self-contained
# scratch file with only the keys this helper reads, and pointing CONFIG
# at it. Self-contained so the test does not depend on $TARGET_REPO
# having a populated config.json.
SCRATCH_CONFIG="$STUB_DIR/config-zero.json"
jq -n '{orchestrator: {alert_on_halted_over: 0}}' > "$SCRATCH_CONFIG"
ORIG_CONFIG="$CONFIG"
CONFIG="$SCRATCH_CONFIG"
classified='[{"identifier":"ENG-301","slot":"vacate","operator_action_required":true}]'
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
CONFIG="$ORIG_CONFIG"
if [[ "$(count_metric_events alert)" == "1" ]] \
   && [[ "$(slack_call_count)" == "1" ]]; then
  pass_at "AC-THR-ZERO threshold=0 alerts on count=1"
else
  fail_at "AC-THR-ZERO threshold=0 alerts on count=1" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count)"
fi

# ─── AC-DEBOUNCE-WITHIN: Slack silent within 24h; metric still fires ──
# Stamp the debounce file "now", then call helper twice.
reset_fixtures; reset_state
date -u +%Y-%m-%dT%H:%M:%SZ > "$DEBOUNCE_FILE"
classified='[
  {"identifier":"ENG-401","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-402","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-403","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-404","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-405","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-406","slot":"vacate","operator_action_required":true}
]'
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
if [[ "$(count_metric_events alert)" == "2" ]] \
   && [[ "$(slack_call_count)" == "0" ]]; then
  pass_at "AC-DEBOUNCE-WITHIN metric fires every tick; slack silent"
else
  fail_at "AC-DEBOUNCE-WITHIN metric fires every tick; slack silent" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count)"
fi

# ─── AC-DEBOUNCE-AFTER: aged debounce file → Slack fires again ────────
reset_fixtures; reset_state
# Age the file by writing a timestamp 25h in the past.
past_ts="$(date -u -v-25H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$past_ts" > "$DEBOUNCE_FILE"
# Also backdate mtime to survive any mtime-based check.
touch -t "$(date -u -v-25H +%Y%m%d%H%M 2>/dev/null \
            || date -u -d '25 hours ago' +%Y%m%d%H%M)" "$DEBOUNCE_FILE"
classified='[
  {"identifier":"ENG-501","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-502","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-503","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-504","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-505","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-506","slot":"vacate","operator_action_required":true}
]'
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
if [[ "$(count_metric_events alert)" == "1" ]] \
   && [[ "$(slack_call_count)" == "1" ]]; then
  pass_at "AC-DEBOUNCE-AFTER aged debounce → slack fires again"
else
  fail_at "AC-DEBOUNCE-AFTER aged debounce → slack fires again" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count)"
fi

# ─── AC-EMPTY: classified is [] → no alert ────────────────────────────
reset_fixtures; reset_state
_poll_emit_halt_sprawl_alert '[]' 2>/dev/null || true
if [[ "$(count_metric_events alert)" == "0" ]] \
   && [[ "$(slack_call_count)" == "0" ]]; then
  pass_at "AC-EMPTY empty classified → no alert"
else
  fail_at "AC-EMPTY empty classified → no alert" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count)"
fi

# ─── AC-MIXED-SLOTS: only vacate counted (hold/terminal ignored) ──────
# 4 vacate + 3 hold + 1 terminal, threshold 5 → count=4, no alert.
reset_fixtures; reset_state
classified='[
  {"identifier":"ENG-601","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-602","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-603","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-604","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-605","slot":"hold"},
  {"identifier":"ENG-606","slot":"hold"},
  {"identifier":"ENG-607","slot":"hold"},
  {"identifier":"ENG-608","slot":"terminal"}
]'
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
if [[ "$(count_metric_events alert)" == "0" ]] \
   && [[ "$(slack_call_count)" == "0" ]]; then
  pass_at "AC-MIXED-SLOTS only vacate counted (4≤5)"
else
  fail_at "AC-MIXED-SLOTS only vacate counted (4≤5)" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count)"
fi

# ─── AC-CONFIG-ABSENT: key missing → feature disabled, no alert ───────
reset_fixtures; reset_state
SCRATCH_CONFIG="$STUB_DIR/config-absent.json"
jq -n '{orchestrator: {paused: false}}' > "$SCRATCH_CONFIG"
ORIG_CONFIG="$CONFIG"
CONFIG="$SCRATCH_CONFIG"
classified='[
  {"identifier":"ENG-701","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-702","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-703","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-704","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-705","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-706","slot":"vacate","operator_action_required":true}
]'
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
CONFIG="$ORIG_CONFIG"
if [[ "$(count_metric_events alert)" == "0" ]] \
   && [[ "$(slack_call_count)" == "0" ]]; then
  pass_at "AC-CONFIG-ABSENT missing key → feature disabled"
else
  fail_at "AC-CONFIG-ABSENT missing key → feature disabled" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count)"
fi

# ─── AC-CONFIG-GARBAGE: non-integer key → feature disabled ────────────
reset_fixtures; reset_state
SCRATCH_CONFIG="$STUB_DIR/config-garbage.json"
jq -n '{orchestrator: {alert_on_halted_over: "five"}}' > "$SCRATCH_CONFIG"
ORIG_CONFIG="$CONFIG"
CONFIG="$SCRATCH_CONFIG"
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
CONFIG="$ORIG_CONFIG"
if [[ "$(count_metric_events alert)" == "0" ]] \
   && [[ "$(slack_call_count)" == "0" ]]; then
  pass_at "AC-CONFIG-GARBAGE non-integer → feature disabled"
else
  fail_at "AC-CONFIG-GARBAGE non-integer → feature disabled" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count)"
fi

# ─── AC-TOP3-SUFFIX: N>3 → top-3 listed with trailing ", …" ──────────
# reset_state already cleared DEBOUNCE_FILE; no extra rm -f needed.
reset_fixtures; reset_state
classified='[
  {"identifier":"ENG-801","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-802","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-803","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-804","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-805","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-806","slot":"vacate","operator_action_required":true}
]'
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
slack_body="$(awk -F'\t' 'NR==1{print $2}' "$SLACK_CAPTURE")"
if [[ "$slack_body" == *"ENG-801"* ]] \
   && [[ "$slack_body" == *"ENG-802"* ]] \
   && [[ "$slack_body" == *"ENG-803"* ]] \
   && [[ "$slack_body" != *"ENG-804"* ]] \
   && [[ "$slack_body" == *"…"* ]]; then
  pass_at "AC-TOP3-SUFFIX N>3 names top-3 and suffix ellipsis"
else
  fail_at "AC-TOP3-SUFFIX N>3 names top-3 and suffix ellipsis" \
    "body=$slack_body"
fi

# ═══════════════════════════════════════════════════════════════════════
# ENG-90 D-004 — inclusion-by-flag filter fixtures.
# Pre-fix the polarity was exclude-by-wait_recallable; under the new
# contract, halt-sprawl includes ONLY operator_action_required==true.
# ═══════════════════════════════════════════════════════════════════════

# ─── AC-THR-EXCLUDE-WAIT (D-004 / preserves ENG-85 invariant under rename):
#     6 wait-recallable vacates; threshold 5. count must be 0; no metric,
#     no slack. Pre-ENG-85 included these → false-positive halt-sprawl.
reset_fixtures; reset_state
classified='[
  {"identifier":"ENG-W1","slot":"vacate","wait_recallable":true,"operator_action_required":false},
  {"identifier":"ENG-W2","slot":"vacate","wait_recallable":true,"operator_action_required":false},
  {"identifier":"ENG-W3","slot":"vacate","wait_recallable":true,"operator_action_required":false},
  {"identifier":"ENG-W4","slot":"vacate","wait_recallable":true,"operator_action_required":false},
  {"identifier":"ENG-W5","slot":"vacate","wait_recallable":true,"operator_action_required":false},
  {"identifier":"ENG-W6","slot":"vacate","wait_recallable":true,"operator_action_required":false}
]'
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
if [[ "$(count_metric_events alert)" == "0" ]] \
   && [[ "$(slack_call_count)" == "0" ]]; then
  pass_at "AC-THR-EXCLUDE-WAIT 6 wait-recallable vacates → no alert"
else
  fail_at "AC-THR-EXCLUDE-WAIT 6 wait-recallable vacates → no alert" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count)"
fi

# ─── AC-THR-EXCLUDE-SKIP-CODE (D-004 — was a miscount pre-fix):
#     6 vacate items modeling skip-until-code-changes evidence-unchanged
#     (oar=false). Pre-D-004 these were COUNTED toward halt-sprawl
#     because the old filter excluded only wait_recallable; under the
#     inclusion-by-flag filter they are correctly excluded.
reset_fixtures; reset_state
classified='[
  {"identifier":"ENG-SC1","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-SC2","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-SC3","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-SC4","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-SC5","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-SC6","slot":"vacate","operator_action_required":false}
]'
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
if [[ "$(count_metric_events alert)" == "0" ]] \
   && [[ "$(slack_call_count)" == "0" ]]; then
  pass_at "AC-THR-EXCLUDE-SKIP-CODE 6 oar=false vacates → no alert (D-004)"
else
  fail_at "AC-THR-EXCLUDE-SKIP-CODE" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count)"
fi

# ─── AC-THR-EXCLUDE-REVIEW-VACATE (D-004 — would be miscount post-D-002
#     without polarity flip): 6 review-PR-pending vacates (oar=false).
#     Without D-004 these would over-count halt-sprawl since they emit
#     slot=vacate post-D-002.
reset_fixtures; reset_state
classified='[
  {"identifier":"ENG-RV1","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-RV2","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-RV3","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-RV4","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-RV5","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-RV6","slot":"vacate","operator_action_required":false}
]'
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
if [[ "$(count_metric_events alert)" == "0" ]] \
   && [[ "$(slack_call_count)" == "0" ]]; then
  pass_at "AC-THR-EXCLUDE-REVIEW-VACATE 6 review-PR-pending vacates → no alert (D-004)"
else
  fail_at "AC-THR-EXCLUDE-REVIEW-VACATE" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count)"
fi

# ─── AC-THR-MIXED: 3 oar=true + 3 oar=false; threshold 5. Filter counts
#     only oar=true → count=3 ≤ 5; no alert.
reset_fixtures; reset_state
classified='[
  {"identifier":"ENG-MIX-T1","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-MIX-T2","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-MIX-T3","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-MIX-F1","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-MIX-F2","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-MIX-F3","slot":"vacate","operator_action_required":false}
]'
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
if [[ "$(count_metric_events alert)" == "0" ]] \
   && [[ "$(slack_call_count)" == "0" ]]; then
  pass_at "AC-THR-MIXED count=3 (oar=true) ≤ threshold; no alert"
else
  fail_at "AC-THR-MIXED" \
    "metric=$(count_metric_events alert) slack=$(slack_call_count)"
fi

# ─── AC-THR-MIXED-OVER: 6 oar=true (ENG-M-*) + 3 oar=false (ENG-X-*);
#     threshold 5. count=6 > 5 → metric notes "count=6 threshold=5";
#     Slack body lists ENG-M-1, ENG-M-2, ENG-M-3 (top-3); does NOT
#     contain any ENG-X-* (top-3 selector mirrors filter). Suffix ", …"
#     present (count=6 > 3).
reset_fixtures; reset_state
classified='[
  {"identifier":"ENG-M-1","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-M-2","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-M-3","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-M-4","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-M-5","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-M-6","slot":"vacate","operator_action_required":true},
  {"identifier":"ENG-X-1","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-X-2","slot":"vacate","operator_action_required":false},
  {"identifier":"ENG-X-3","slot":"vacate","operator_action_required":false}
]'
_poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
notes="$(last_metric_notes)"
slack_body="$(awk -F'\t' 'NR==1{print $2}' "$SLACK_CAPTURE")"
if [[ "$(count_metric_events alert)" == "1" ]] \
   && [[ "$notes" == "count=6 threshold=5" ]] \
   && [[ "$(slack_call_count)" == "1" ]] \
   && [[ "$slack_body" == *"ENG-M-1"* ]] \
   && [[ "$slack_body" == *"ENG-M-2"* ]] \
   && [[ "$slack_body" == *"ENG-M-3"* ]] \
   && [[ "$slack_body" != *"ENG-X-1"* ]] \
   && [[ "$slack_body" != *"ENG-X-2"* ]] \
   && [[ "$slack_body" != *"ENG-X-3"* ]] \
   && [[ "$slack_body" == *"…"* ]]; then
  pass_at "AC-THR-MIXED-OVER count=6 fires; top-3 selector mirrors filter (no ENG-X-* leak)"
else
  fail_at "AC-THR-MIXED-OVER" \
    "notes=$notes body=$slack_body"
fi

# ─── Summary ──────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
