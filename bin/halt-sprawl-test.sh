#!/usr/bin/env bash
# Integration tests for poll.sh's halt-sprawl alert emission (ENG-21).
# Runs under $PIPELINE_DRY_RUN=1 with stubbed linear.sh/metrics.sh/slack.sh.
# Fixture JSON files in $FIXTURE_DIR stand in for Linear GraphQL responses.

set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR_REAL/common.sh"

export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"

# Allocate temp dirs captured into _TEST_* (never reassigned by sourcing
# common.sh / poll.sh). See ENG-20 incident 2026-04-24.
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
FIXTURE_DIR="$STUB_DIR/fixtures"
METRICS_FILE="$TWINNING_DIR/metrics/events.jsonl"
DEBOUNCE_FILE="$TWINNING_DIR/.halt-sprawl-last-alerted"
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
  remove-label|add-label|swap-stage|transition-state|add-comment|add-or-update-comment|refresh-cache|stage-of|has-label)
    exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"

# metrics.sh: write a real jsonl line so tests can inspect the on-disk shape.
# Mirrors the real metrics.sh shape but skips TWINNING_DIR recomputation.
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

# ─── Source poll.sh and override SCRIPT_DIR / TWINNING_DIR ────────────
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
# (Cases appended in Tasks 4 and 5.)

# ─── Summary ──────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
