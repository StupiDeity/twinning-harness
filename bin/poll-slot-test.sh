#!/usr/bin/env bash
# Integration tests for poll.sh's slot-allocation logic (ENG-20).
# Runs under $PIPELINE_DRY_RUN=1 with stubbed linear.sh/metrics.sh/slack.sh.
# Fixture JSON files in $FIXTURE_DIR stand in for Linear GraphQL responses.

set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR_REAL/common.sh"

export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
TWINNING_DIR="$(mktemp -d)"
export TWINNING_DIR
_TEST_TWINNING_DIR="$TWINNING_DIR"  # Save for later re-assignment

STUB_DIR="$(mktemp -d)"
FIXTURE_DIR="$STUB_DIR/fixtures"
mkdir -p "$FIXTURE_DIR"
trap 'rm -rf "$STUB_DIR" "$TWINNING_DIR"' EXIT
export FIXTURE_DIR

# ─── Stub external scripts ───────────────────────────────────────────
# linear.sh stub reads fixture JSONs from $FIXTURE_DIR keyed by subcommand.
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
    # No-op for side-effecting subcommands; tests assert on dispatch output, not side effects.
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"

for cmd in metrics.sh slack.sh; do
  cat > "$STUB_DIR/$cmd" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$STUB_DIR/$cmd"
done

# ─── Source poll.sh and override SCRIPT_DIR ───────────────────────────
# poll.sh sets SCRIPT_DIR from BASH_SOURCE at load time and uses it in
# every `bash "$SCRIPT_DIR/..."` call. We source the real file (so
# main() and helpers are defined) and then override SCRIPT_DIR so
# call sites resolve to our stubs. Same with verdict-handler.sh's
# _VH_SCRIPT_DIR (set when verdict-handler.sh is sourced by poll.sh).
# NB: poll.sh sources common.sh, which resets TWINNING_DIR to HOME path;
# we must re-override TWINNING_DIR after sourcing poll.sh.
# shellcheck source=poll.sh
source "$SCRIPT_DIR_REAL/poll.sh"
SCRIPT_DIR="$STUB_DIR"
_VH_SCRIPT_DIR="$STUB_DIR"
TWINNING_DIR="$_TEST_TWINNING_DIR"
export TWINNING_DIR

# _poll_evaluate_skip calls git ls-remote for branch SHA. Override for
# tests: always return empty current SHA so evidence-unchanged branch
# is taken when skip state exists. Tests that exercise skip-code path
# must set up fixtures explicitly.
git() {
  if [[ "$1" == "-C" && "$3" == "ls-remote" ]]; then
    printf ''; return 0
  fi
  command git "$@"
}

# compute_pipeline_content_hash is defined in common.sh; tests leave it
# as-is (it reads .pipeline/* from the repo root, which is stable during
# one test run).

# ─── Assertion helpers ────────────────────────────────────────────────
PASS=0; FAIL=0
fail_at() { printf '  ❌ %s\n      %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }

reset_fixtures() { rm -f "$FIXTURE_DIR"/*.json; }

# write_label_fixture <stage_label> <issue_spec>...
# issue_spec format: "ENG-N|state_name|priority_int|comma,separated,labels"
# state_name is "In Progress"/"Done"/"Todo"/etc. (Linear native state name).
# priority_int is 0-4 (Linear priority enum).
# Labels is a comma-separated list of label NAMES (no spaces).
write_label_fixture() {
  local label="$1"; shift
  local nodes='[]'
  local spec
  for spec in "$@"; do
    IFS='|' read -r ident state prio labels <<<"$spec"
    local labels_array
    labels_array="$(jq -nc --arg s "$labels" '
      ($s | split(",")) | map(select(length>0)) | map({name: .})')"
    nodes="$(jq -c \
      --argjson n "$nodes" \
      --arg id "$ident" \
      --arg st "$state" \
      --argjson p "$prio" \
      --argjson l "$labels_array" \
      '$n + [{identifier:$id, state:{name:$st}, priority:$p, labels:{nodes:$l}}]' \
      <<<"$nodes")"
  done
  local fixture_name
  fixture_name="$(printf '%s' "$label" | tr ':' '-')"
  jq -nc --argjson nodes "$nodes" '{data:{issues:{nodes:$nodes}}}' \
    > "$FIXTURE_DIR/label-$fixture_name.json"
}

# write_inbox_fixture <issue_spec>... — same spec shape as write_label_fixture.
# Writes to state-Todo.json (the config's inbox state name).
write_inbox_fixture() {
  local inbox_state
  inbox_state="$(config_get '.linear.native_states.inbox')"
  local nodes='[]'
  local spec
  for spec in "$@"; do
    IFS='|' read -r ident state prio labels <<<"$spec"
    local labels_array
    labels_array="$(jq -nc --arg s "$labels" '
      ($s | split(",")) | map(select(length>0)) | map({name: .})')"
    nodes="$(jq -c \
      --argjson n "$nodes" \
      --arg id "$ident" \
      --arg st "$state" \
      --argjson p "$prio" \
      --argjson l "$labels_array" \
      '$n + [{identifier:$id, state:{name:$st}, priority:$p, labels:{nodes:$l}}]' \
      <<<"$nodes")"
  done
  jq -nc --argjson nodes "$nodes" '{data:{issues:{nodes:$nodes}}}' \
    > "$FIXTURE_DIR/state-$inbox_state.json"
}

# write_comments_fixture <issue_id> <body|createdAt>...
# Writes a JSON array of comment objects for get-comments fixture lookup.
write_comments_fixture() {
  local ident="$1"; shift
  local arr='[]'
  local i=0
  local pair
  for pair in "$@"; do
    local body="${pair%|*}" ts="${pair##*|}"
    arr="$(jq -c --arg id "c$i" --arg body "$body" --arg ts "$ts" \
      '. + [{id:$id, body:$body, createdAt:$ts}]' <<<"$arr")"
    i=$((i+1))
  done
  printf '%s' "$arr" > "$FIXTURE_DIR/comments-$ident.json"
}

# ─── Test cases ───────────────────────────────────────────────────────
# (Cases appended below in later tasks.)

# ─── AC-1: advance held issue when cap is reached ─────────────────────
# Two issues at stage:planning, cap=2. Must advance one of them.
reset_fixtures
write_label_fixture "stage:planning" \
  "ENG-1001|In Progress|3|Bug,stage:planning" \
  "ENG-1002|In Progress|3|Bug,stage:planning"
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // ""' <<<"$out")"
stage="$(jq -r '.stage // ""' <<<"$out")"
entry="$(jq -r '.entry_action // ""' <<<"$out")"
if { [[ "$issue_id" == "ENG-1001" ]] || [[ "$issue_id" == "ENG-1002" ]]; } \
   && [[ "$stage" == "plan" ]] \
   && [[ "$entry" == "run" ]]; then
  pass_at "AC-1 advance-held-at-cap dispatches a planning issue"
else
  fail_at "AC-1 advance-held-at-cap dispatches a planning issue" "out=$out"
fi

# ─── AC-2: halt-for-human vacates slot ────────────────────────────────
# 2 issues bare-halted with pipeline-halt markers (agent-blocked for human)
# + 1 Todo in inbox. Expected: Todo picked up (halted don't hold slots).
reset_fixtures
write_label_fixture "stage:planning" \
  "ENG-2001|In Progress|3|Bug,stage:planning,pipeline:halted" \
  "ENG-2002|In Progress|3|Bug,stage:planning,pipeline:halted"
write_comments_fixture "ENG-2001" \
  "<!-- pipeline-halt: agent-blocked -->|2026-04-24T10:00:00.000Z"
write_comments_fixture "ENG-2002" \
  "<!-- pipeline-halt: agent-blocked -->|2026-04-24T10:00:00.000Z"
write_inbox_fixture \
  "ENG-3001|Todo|3|Bug"
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // ""' <<<"$out")"
entry="$(jq -r '.entry_action // ""' <<<"$out")"
if [[ "$issue_id" == "ENG-3001" ]] && [[ "$entry" == "apply-stage-label" ]]; then
  pass_at "AC-2 halt-for-human vacates slot; inbox Todo picked"
else
  fail_at "AC-2 halt-for-human vacates slot; inbox Todo picked" "out=$out"
fi

# ─── AC-3: halt-for-verdict holds slot ────────────────────────────────
# 2 issues bare-halted with pipeline-stage-summary markers (auto-advance
# via verdict_handler) + 1 Todo in inbox. Expected: no inbox pickup,
# idle or verdict-handler-scheduled advancement. Either outcome is
# acceptable — issue MUST NOT be the inbox Todo.
reset_fixtures
write_label_fixture "stage:planning" \
  "ENG-4001|In Progress|3|Bug,stage:planning,pipeline:halted" \
  "ENG-4002|In Progress|3|Bug,stage:planning,pipeline:halted"
write_comments_fixture "ENG-4001" \
  "<!-- pipeline-stage-summary: planning -->|2026-04-24T10:00:00.000Z"
write_comments_fixture "ENG-4002" \
  "<!-- pipeline-stage-summary: planning -->|2026-04-24T10:00:00.000Z"
write_inbox_fixture \
  "ENG-3002|Todo|3|Bug"
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // ""' <<<"$out")"
if [[ "$issue_id" != "ENG-3002" ]]; then
  pass_at "AC-3 halt-for-verdict holds slot; inbox NOT picked"
else
  fail_at "AC-3 halt-for-verdict holds slot; inbox NOT picked" "out=$out"
fi

# ─── Summary ──────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
