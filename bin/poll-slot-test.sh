#!/usr/bin/env bash
# Integration tests for poll.sh's slot-allocation logic (ENG-20).
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

# Allocate temp dirs. These paths are captured into _TEST_* variables that
# never get reassigned by sourcing common.sh / poll.sh (both of which reset
# HARNESS_STATE_DIR to $HOME/.twinning-pipeline). The trap uses the _TEST_*
# copies so an accidental HARNESS_STATE_DIR reassignment can't cause rm -rf to
# hit live pipeline state. See ENG-20 incident on 2026-04-24.
_TEST_HARNESS_STATE_DIR="$(mktemp -d)"
_TEST_STUB_DIR="$(mktemp -d)"

# Defense-in-depth: refuse to continue if mktemp ever returns a path
# outside platform temp roots. On macOS mktemp writes to /var/folders/...
# and on Linux to /tmp/... — anything else is a red flag.
_test_assert_temp_path() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
    *) printf 'REFUSING: path %q is not a platform temp dir\n' "$1" >&2; exit 99 ;;
  esac
}
_test_assert_temp_path "$_TEST_HARNESS_STATE_DIR"
_test_assert_temp_path "$_TEST_STUB_DIR"

# Trap cleanup. Uses _TEST_* (never reassigned) and checks each path is
# still a temp dir at trap-fire time before rm-rf-ing it. This would have
# prevented the 2026-04-24 incident where sourcing common.sh reset
# HARNESS_STATE_DIR to $HOME/.twinning-pipeline and the exit trap removed it.
_test_safe_rm() {
  local path="$1"
  case "$path" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*)
      rm -rf "$path" ;;
    *)
      printf 'SAFETY: trap refusing rm -rf %q (not a temp dir)\n' "$path" >&2 ;;
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
mkdir -p "$FIXTURE_DIR"
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
    # No-op for side-effecting subcommands. Optionally append the call to
    # $LINEAR_STUB_LOG so individual tests can assert on side effects.
    [[ -n "${LINEAR_STUB_LOG-}" ]] && printf '%s\n' "$*" >> "$LINEAR_STUB_LOG"
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
# NB: poll.sh sources common.sh, which resets HARNESS_STATE_DIR to HOME path;
# we must re-override HARNESS_STATE_DIR after sourcing poll.sh.
# shellcheck source=poll.sh
source "$SCRIPT_DIR_REAL/poll.sh"
SCRIPT_DIR="$STUB_DIR"
_VH_SCRIPT_DIR="$STUB_DIR"
HARNESS_STATE_DIR="$_TEST_HARNESS_STATE_DIR"
export HARNESS_STATE_DIR
PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
export PROJECT_STATE_DIR

# Override CONFIG with a self-contained scratch config carrying every
# key poll.sh reads: orchestrator.{paused,max_concurrent_features,
# alert_on_halted_over}, linear.{native_states.inbox,workflow_stages}.
# Without this, $CONFIG points at the test target's config.json which
# may not exist; poll.sh's config_get calls return empty, AC-1 sees
# limit= and the slot allocation collapses.
CONFIG="$STUB_DIR/config.json"
jq -n '{
  orchestrator: {paused: false, max_concurrent_features: 2, alert_on_halted_over: 5},
  linear: {
    native_states: {inbox: "Todo", active: "In Progress", done: "Done"},
    workflow_stages: ["brainstorming","planning","implementing","ui","reviewing","qa","building","released"],
    stage_label_prefix: "stage:"
  }
}' > "$CONFIG"
export CONFIG

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
   && [[ "$stage" == "planning" ]] \
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
  "<!-- pipeline: verdict result=halt reason=agent-blocked -->|2026-04-24T10:00:00.000Z"
write_comments_fixture "ENG-2002" \
  "<!-- pipeline: verdict result=halt reason=agent-blocked -->|2026-04-24T10:00:00.000Z"
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
  "<!-- pipeline: verdict result=pass stage=planning -->|2026-04-24T10:00:00.000Z"
write_comments_fixture "ENG-4002" \
  "<!-- pipeline: verdict result=pass stage=planning -->|2026-04-24T10:00:00.000Z"
write_inbox_fixture \
  "ENG-3002|Todo|3|Bug"
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // ""' <<<"$out")"
if [[ "$issue_id" != "ENG-3002" ]]; then
  pass_at "AC-3 halt-for-verdict holds slot; inbox NOT picked"
else
  fail_at "AC-3 halt-for-verdict holds slot; inbox NOT picked" "out=$out"
fi

# ─── AC-4: priority sort — higher Linear priority advances first ──────
# Two stage:planning issues at same stage. ENG-5001 has priority 1 (Urgent),
# ENG-5002 has priority 3 (Normal). cap=2. Expected: ENG-5001 is dispatched.
reset_fixtures
write_label_fixture "stage:planning" \
  "ENG-5001|In Progress|1|Bug,stage:planning" \
  "ENG-5002|In Progress|3|Bug,stage:planning"
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // ""' <<<"$out")"
if [[ "$issue_id" == "ENG-5001" ]]; then
  pass_at "AC-4 priority sort — Urgent advances before Normal"
else
  fail_at "AC-4 priority sort — Urgent advances before Normal" "out=$out"
fi

# Also: stage sort — later stage advances before earlier stage at same priority.
# ENG-5003 at stage:reviewing (later) + ENG-5004 at stage:planning, same priority 3.
# Expected: ENG-5003 dispatched (closer to released).
reset_fixtures
write_label_fixture "stage:planning" \
  "ENG-5004|In Progress|3|Bug,stage:planning"
write_label_fixture "stage:reviewing" \
  "ENG-5003|In Progress|3|Bug,stage:reviewing"
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // ""' <<<"$out")"
stage="$(jq -r '.stage // ""' <<<"$out")"
if [[ "$issue_id" == "ENG-5003" ]] && [[ "$stage" == "reviewing" ]]; then
  pass_at "AC-4 stage sort — reviewing advances before planning"
else
  fail_at "AC-4 stage sort — reviewing advances before planning" "out=$out"
fi

# ─── AC-5: metric reason — max-concurrent-reached only at inbox-gate ──
# Capture idle reason by replacing the metrics.sh stub with a capture
# stub for this test only. With ENG-90 the halted-no-marker branch
# vacates the slot, so this fixture uses halt + stage-summary markers
# instead: classifier returns hold/advanceable=true; Pass 4 invokes
# verdict_handler (a no-op against the stubbed Linear API) and falls
# through without dispatching; held_count stays at 2 = max_concurrent;
# the cap-gate on Pass 5/6 fires and the final idle path emits
# "max-concurrent-reached".
reset_fixtures
write_label_fixture "stage:planning" \
  "ENG-6001|In Progress|3|Bug,stage:planning,pipeline:halted" \
  "ENG-6002|In Progress|3|Bug,stage:planning,pipeline:halted"
write_comments_fixture "ENG-6001" \
  "<!-- pipeline: verdict result=pass stage=planning -->|2026-04-24T10:00:00.000Z"
write_comments_fixture "ENG-6002" \
  "<!-- pipeline: verdict result=pass stage=planning -->|2026-04-24T10:00:00.000Z"

# Replace metrics.sh with a capture stub that writes the reason to a file.
REASON_CAPTURE="$STUB_DIR/last-reason"
: > "$REASON_CAPTURE"
cat > "$STUB_DIR/metrics.sh" <<SH
#!/usr/bin/env bash
# Signature: metrics.sh poll-tick "" "" idle 0 <reason>
if [[ "\$1" == "poll-tick" && "\$4" == "idle" ]]; then
  printf '%s' "\${6:-}" > "$REASON_CAPTURE"
fi
exit 0
SH
chmod +x "$STUB_DIR/metrics.sh"

out="$(main 2>/dev/null || true)"
reason="$(cat "$REASON_CAPTURE" 2>/dev/null || printf '')"
if [[ "$reason" == max-concurrent-reached* ]] \
   && [[ "$(jq -r '.issue_id // "null"' <<<"$out")" == "null" ]]; then
  pass_at "AC-5 idle reason max-concurrent-reached when all held non-advanceable"
else
  fail_at "AC-5 idle reason max-concurrent-reached when all held non-advanceable" \
    "reason=$reason out=$out"
fi

# Restore the no-op metrics.sh for subsequent tests (if any).
cat > "$STUB_DIR/metrics.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$STUB_DIR/metrics.sh"

# ─── AC-6: skip-until-code-changes auto-resume also clears halt label ──
# Regression: ENG-26 stayed at no-work after evidence-change cleared the
# skip label because pipeline:halted + a <!-- pipeline: verdict result=halt --> marker
# (both written by classify-failure) kept _poll_classify_labels in
# vacate/not-advanceable. _poll_evaluate_skip must clear the halt label
# AND post a `pipeline: decision action=continue` marker so the next tick can
# advance the issue.
reset_fixtures
write_label_fixture "stage:implementing" \
  "ENG-7001|In Progress|3|Bug,stage:implementing,pipeline:halted,pipeline:skip-until-code-changes"
write_comments_fixture "ENG-7001" \
  "<!-- pipeline: verdict result=halt reason=agent-failure -->|2026-04-27T05:34:40.000Z"

# Plant a stale issue-state.json so the evidence-changed branch fires.
mkdir -p "$PROJECT_STATE_DIR/ENG-7001"
cat > "$PROJECT_STATE_DIR/ENG-7001/issue-state.json" <<JSON
{"issue":"ENG-7001","stage":"implement","policy":"skip-until-code-changes",
 "branch":"feat/eng-7001",
 "evidence":{"pipeline_content_hash":"stale-hash","branch_head_sha":"stale-sha"}}
JSON

# Capture linear.sh side-effect calls.
LINEAR_STUB_LOG="$STUB_DIR/linear-calls-ac6.log"
: > "$LINEAR_STUB_LOG"
export LINEAR_STUB_LOG

out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // ""' <<<"$out")"
stage="$(jq -r '.stage // ""' <<<"$out")"

removed_skip=0; removed_halt=0; posted_resume=0
grep -qE '^remove-label ENG-7001 pipeline:skip-until-code-changes$' "$LINEAR_STUB_LOG" && removed_skip=1
grep -qE '^remove-label ENG-7001 pipeline:halted$'                  "$LINEAR_STUB_LOG" && removed_halt=1
grep -qE 'pipeline: decision action=continue'                       "$LINEAR_STUB_LOG" && posted_resume=1

unset LINEAR_STUB_LOG
rm -rf "$PROJECT_STATE_DIR/ENG-7001"

if (( removed_skip == 1 )) && (( removed_halt == 1 )) && (( posted_resume == 1 )) \
   && [[ "$issue_id" == "ENG-7001" ]] && [[ "$stage" == "implementing" ]]; then
  pass_at "AC-6 auto-resume clears skip+halt, posts resume marker, dispatches stage"
else
  fail_at "AC-6 auto-resume clears skip+halt, posts resume marker, dispatches stage" \
    "removed_skip=$removed_skip removed_halt=$removed_halt posted_resume=$posted_resume issue=$issue_id stage=$stage"
fi

# ─── AC-7: auto-resume is a no-op when pipeline:halted is absent ──────
# If the issue carries skip-until-code-changes alone (no halt), the
# auto-resume must NOT fire remove-label pipeline:halted or post a resume
# marker. Guards against unconditional Linear writes regressing the fix.
reset_fixtures
write_label_fixture "stage:implementing" \
  "ENG-7002|In Progress|3|Bug,stage:implementing,pipeline:skip-until-code-changes"
mkdir -p "$PROJECT_STATE_DIR/ENG-7002"
cat > "$PROJECT_STATE_DIR/ENG-7002/issue-state.json" <<JSON
{"issue":"ENG-7002","stage":"implement","policy":"skip-until-code-changes",
 "branch":"feat/eng-7002",
 "evidence":{"pipeline_content_hash":"stale-hash","branch_head_sha":"stale-sha"}}
JSON

LINEAR_STUB_LOG="$STUB_DIR/linear-calls-ac7.log"
: > "$LINEAR_STUB_LOG"
export LINEAR_STUB_LOG

# main calls `exit 0` on its happy paths; capture via $(...) so the exit
# stays in the subshell.
_=$(main 2>/dev/null || true)

extra_halt_clear=0; extra_resume_post=0
grep -qE '^remove-label ENG-7002 pipeline:halted$' "$LINEAR_STUB_LOG" && extra_halt_clear=1
grep -qE 'pipeline: decision action=continue'      "$LINEAR_STUB_LOG" && extra_resume_post=1

unset LINEAR_STUB_LOG
rm -rf "$PROJECT_STATE_DIR/ENG-7002"

if (( extra_halt_clear == 0 )) && (( extra_resume_post == 0 )); then
  pass_at "AC-7 auto-resume skips halt-clear when pipeline:halted absent"
else
  fail_at "AC-7 auto-resume skips halt-clear when pipeline:halted absent" \
    "extra_halt_clear=$extra_halt_clear extra_resume_post=$extra_resume_post"
fi

# ─── AC-WAIT-1 (ENG-85): stage:building + only pipeline-wait fresh
#     → slot=vacate, advanceable=false, wait_recallable=true. Replaces
#     the pre-ENG-85 ENG-45 fixture (which asserted hold/advanceable=true
#     via the catch-all else branch). The pre-ENG-85 hold/true
#     classification was the load-bearing starvation surface this
#     ticket fixes; AC-WAIT-3 covers the "wait still progresses
#     eventually" contract that the prior ENG-45 fixture pinned.
reset_fixtures
write_comments_fixture "ENG-45-WAIT" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:17:00Z'

out="$(_poll_classify_labels "ENG-45-WAIT" '["stage:building"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
# Use `tostring` rather than `// ""` because jq's `//` treats boolean false
# as null and falls through to the default — which would emit "" not "false".
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
recall="$(jq -r '.wait_recallable | tostring' <<<"$out")"
oar="$(jq -r '.operator_action_required | tostring' <<<"$out")"
ts="$(jq -r '.wait_progress_ts // ""' <<<"$out")"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$recall" == "true" \
      && "$oar" == "false" \
      && "$ts" == "2026-04-28T08:17:00Z" ]]; then
  pass_at "AC-WAIT-1 (ENG-85): wait verdict on stage:building → vacate/false/wait_recallable=true/oar=false"
else
  fail_at "AC-WAIT-1 (ENG-85): wait verdict classification" \
    "got slot=$slot adv=$adv recall=$recall oar=$oar ts=$ts (want vacate/false/true/false/2026-04-28T08:17:00Z) full=$out"
fi

# ─── AC-WAIT-2 (ENG-85): two issues, ENG-A waits at stage:building,
#     ENG-B held at stage:qa, max_concurrent=2. After classify, ENG-A
#     is vacate; ENG-B is hold. Pass 4 dispatches ENG-B, NOT ENG-A.
#     This is the literal regression test for the issue body's
#     "ENG-79 starved 45 min" scenario.
reset_fixtures
write_label_fixture "stage:building" "ENG-WAIT-A|In Progress|1|stage:building"
write_label_fixture "stage:qa"       "ENG-WAIT-B|In Progress|1|stage:qa"
write_comments_fixture "ENG-WAIT-A" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:17:00Z'
write_comments_fixture "ENG-WAIT-B" \
  '<!-- pipeline: transition from=reviewing to=qa -->|2026-04-28T08:05:00Z'
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
reason="$(jq -r '.reason // ""' <<<"$out")"
if [[ "$issue_id" == "ENG-WAIT-B" && "$reason" == *"stage:qa"* ]]; then
  pass_at "AC-WAIT-2 (ENG-85): ENG-A waits, ENG-B (stage:qa) wins Pass 4 dispatch"
else
  fail_at "AC-WAIT-2 (ENG-85): wait-vacates slot for sibling held work" \
    "got issue_id=$issue_id reason=$reason (want ENG-WAIT-B / *stage:qa*) full=$out"
fi

# ─── AC-WAIT-3 (ENG-85): single wait issue, empty inbox, no other
#     classified issues → Pass 6 fires with reason
#     "wait re-pickup at stage:building (no other ready work)".
reset_fixtures
write_label_fixture "stage:building" "ENG-WAIT-C|In Progress|1|stage:building"
write_comments_fixture "ENG-WAIT-C" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:17:00Z'
# No inbox fixture written → list-issues-in-state stub returns empty.
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
stage="$(jq -r '.stage // ""' <<<"$out")"
entry="$(jq -r '.entry_action // ""' <<<"$out")"
reason="$(jq -r '.reason // ""' <<<"$out")"
if [[ "$issue_id" == "ENG-WAIT-C" && "$stage" == "building" \
      && "$entry" == "run" && "$reason" == *"wait re-pickup at stage:building"* ]]; then
  pass_at "AC-WAIT-3 (ENG-85): Pass 6 recalls wait issue when no other ready work"
else
  fail_at "AC-WAIT-3 (ENG-85): Pass 6 wait recall" \
    "got issue_id=$issue_id stage=$stage entry=$entry reason=$reason full=$out"
fi

# ─── AC-WAIT-4 (ENG-85): two wait issues, equal priority. Pass 6
#     picks the older one (FIFO tiebreak by wait_progress_ts asc).
reset_fixtures
write_label_fixture "stage:building" \
  "ENG-WAIT-D|In Progress|1|stage:building" \
  "ENG-WAIT-E|In Progress|1|stage:building"
write_comments_fixture "ENG-WAIT-D" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T10:00:00Z'
write_comments_fixture "ENG-WAIT-E" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T10:05:00Z'
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
if [[ "$issue_id" == "ENG-WAIT-D" ]]; then
  pass_at "AC-WAIT-4 (ENG-85): Pass 6 FIFO tiebreak — older wait (ENG-WAIT-D) wins"
else
  fail_at "AC-WAIT-4 (ENG-85): Pass 6 FIFO" "got issue_id=$issue_id (want ENG-WAIT-D) full=$out"
fi

# ─── AC-WAIT-5 (ENG-85): two wait issues, different priority. Pass 6
#     picks the higher-priority one regardless of wait_progress_ts.
#     ENG-WAIT-F (priority=Normal=3) wait at 10:00:00Z;
#     ENG-WAIT-G (priority=Urgent=1) wait at 10:05:00Z.
#     Urgent wins despite being newer.
reset_fixtures
write_label_fixture "stage:building" \
  "ENG-WAIT-F|In Progress|3|stage:building" \
  "ENG-WAIT-G|In Progress|1|stage:building"
write_comments_fixture "ENG-WAIT-F" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T10:00:00Z'
write_comments_fixture "ENG-WAIT-G" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T10:05:00Z'
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
if [[ "$issue_id" == "ENG-WAIT-G" ]]; then
  pass_at "AC-WAIT-5 (ENG-85): Pass 6 priority dominates FIFO (Urgent wins over Normal)"
else
  fail_at "AC-WAIT-5 (ENG-85): Pass 6 priority" "got issue_id=$issue_id (want ENG-WAIT-G) full=$out"
fi

# ─── AC-WAIT-6 (ENG-85): pins that the halted arm in _poll_classify_labels
#     fires BEFORE the new wait arm (branch-ordering invariant).
#     Setup plants both pipeline:halted AND a halt verdict; the halted
#     arm short-circuits at the case='pipeline-halt' branch and emits
#     slot=vacate, advanceable=false (no wait_recallable key set). Does
#     NOT exercise find_fresh_wait_verdict's `fresh_result != "wait"`
#     supersession short-circuit — that path is exercised by AC-WAIT-7.
#     Pins the brainstorm §"Acceptance" §4 hand-off:
#     "ENG-45 external_signal_budget escalation path still works
#     (wait → halt-for-budget-exhausted → existing halt vacate)."
reset_fixtures
write_comments_fixture "ENG-WAIT-H" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T10:00:00Z' \
  '<!-- pipeline: verdict result=halt reason=external-signal-budget-exhausted -->|2026-04-28T10:30:00Z'

out="$(_poll_classify_labels "ENG-WAIT-H" '["stage:building","pipeline:halted"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
recall="$(jq -r '.wait_recallable // false | tostring' <<<"$out")"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$recall" == "false" ]]; then
  pass_at "AC-WAIT-6 (ENG-85): budget-exhausted halt routes through halted arm, NOT wait arm"
else
  fail_at "AC-WAIT-6 (ENG-85): halt-handoff" \
    "got slot=$slot adv=$adv recall=$recall (want vacate/false/false) full=$out"
fi

# ─── AC-WAIT-7 (ENG-85): wait verdict superseded by a later fail before
#     the next tick. find_fresh_wait_verdict's `fresh_result != "wait"`
#     short-circuit at bin/verdict-handler.sh fires (latest verdict in
#     the post-transition window is fail, not wait — helper returns
#     empty). The new wait arm in _poll_classify_labels does NOT fire;
#     classifier falls through to the catch-all else branch
#     (slot=hold, advanceable=true). No pipeline:halted label is set
#     here (distinguishes from AC-WAIT-6's halted-arm precedence pin).
#     Pins the supersession-by-fail load-bearing claim of D-001.
reset_fixtures
write_comments_fixture "ENG-WAIT-I" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T10:00:00Z' \
  '<!-- pipeline: verdict result=fail target=implementing -->|2026-04-28T10:30:00Z'

out="$(_poll_classify_labels "ENG-WAIT-I" '["stage:building"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
recall="$(jq -r '.wait_recallable // false | tostring' <<<"$out")"
if [[ "$slot" == "hold" && "$adv" == "true" && "$recall" == "false" ]]; then
  pass_at "AC-WAIT-7 (ENG-85): fail-supersedes-wait routes through else, NOT wait arm"
else
  fail_at "AC-WAIT-7 (ENG-85): supersession by fail" \
    "got slot=$slot adv=$adv recall=$recall (want hold/true/false) full=$out"
fi

# ─── AC-8: ENG-24 Bug A — Todo with skip-until-human-acts is NOT inbox-picked ──
# A Todo issue carrying only pipeline:skip-until-human-acts (no state
# file, no stage:* label) must be skipped by Pass 5's inbox jq filter.
# Pre-fix: the issue was dispatched into stage:brainstorming.
reset_fixtures
write_inbox_fixture \
  "ENG-8001|Todo|3|Bug,pipeline:skip-until-human-acts"
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
if [[ "$issue_id" == "null" ]]; then
  pass_at "AC-8 Bug A — Todo with skip-until-human-acts is NOT inbox-picked"
else
  fail_at "AC-8 Bug A — Todo with skip-until-human-acts is NOT inbox-picked" "out=$out"
fi

# AC-8b: same shape, code-changes label flavor.
reset_fixtures
write_inbox_fixture \
  "ENG-8002|Todo|3|Bug,pipeline:skip-until-code-changes"
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
if [[ "$issue_id" == "null" ]]; then
  pass_at "AC-8b Bug A — Todo with skip-until-code-changes is NOT inbox-picked"
else
  fail_at "AC-8b Bug A — Todo with skip-until-code-changes is NOT inbox-picked" "out=$out"
fi

# ─── AC-9: ENG-24 Bug B — stage-labeled + skip-until-human-acts + no state file ──
# An issue carrying stage:planning AND pipeline:skip-until-human-acts AND
# NO state file must vacate its slot AND the label must NOT be stripped
# by poll. Pre-fix: _poll_evaluate_skip's orphan-label branch fired
# `linear.sh remove-label ENG-9001 pipeline:skip-until-human-acts` then
# returned 0 (include).
reset_fixtures
write_label_fixture "stage:planning" \
  "ENG-9001|In Progress|3|Bug,stage:planning,pipeline:skip-until-human-acts"
# No mkdir / no issue-state.json — exercises the no-state-file path.

LINEAR_STUB_LOG="$STUB_DIR/linear-calls-ac9.log"
: > "$LINEAR_STUB_LOG"
export LINEAR_STUB_LOG

out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"

# Negative assertion: the EXACT line `remove-label ENG-9001
# pipeline:skip-until-human-acts` must not appear in the stub log.
# `grep -Fxq` matches a full line literally (no regex), so a future
# unrelated remove-label on ENG-9001 (different label) cannot relax
# this guard.
stripped=0
grep -Fxq 'remove-label ENG-9001 pipeline:skip-until-human-acts' "$LINEAR_STUB_LOG" && stripped=1

unset LINEAR_STUB_LOG

if [[ "$issue_id" != "ENG-9001" ]] && (( stripped == 0 )); then
  pass_at "AC-9 Bug B — stage+skip-until-human-acts (no state file) vacates and preserves label"
else
  fail_at "AC-9 Bug B — stage+skip-until-human-acts (no state file) vacates and preserves label" \
    "issue=$issue_id stripped=$stripped"
fi

# ─── AC-10: ENG-24 Bug B (uniformity) — same as AC-9 with code-changes label ──
# The orphan-label branch must treat both skip-until-* labels identically:
# vacate, no Linear writes. AC-10 guards the uniformity claim from
# brainstorm §2 D-2: future regressions that special-case only human-acts
# would otherwise pass.
reset_fixtures
write_label_fixture "stage:planning" \
  "ENG-9002|In Progress|3|Bug,stage:planning,pipeline:skip-until-code-changes"
# No mkdir / no issue-state.json.

LINEAR_STUB_LOG="$STUB_DIR/linear-calls-ac10.log"
: > "$LINEAR_STUB_LOG"
export LINEAR_STUB_LOG

out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"

stripped=0
grep -Fxq 'remove-label ENG-9002 pipeline:skip-until-code-changes' "$LINEAR_STUB_LOG" && stripped=1

unset LINEAR_STUB_LOG

if [[ "$issue_id" != "ENG-9002" ]] && (( stripped == 0 )); then
  pass_at "AC-10 Bug B uniformity — stage+skip-until-code-changes (no state file) vacates and preserves label"
else
  fail_at "AC-10 Bug B uniformity — stage+skip-until-code-changes (no state file) vacates and preserves label" \
    "issue=$issue_id stripped=$stripped"
fi

# ─── AC-11: ENG-24 QA adversarial — Bug A inbox filter uses EXACT label match ──
# A Todo issue carrying a label whose name is a strict superstring of
# pipeline:skip-until-human-acts (e.g. a custom human-coined
# pipeline:skip-until-human-acts-tomorrow) MUST still be inbox-picked.
# jq's `index($n)` does exact array-element equality, so the new filter
# clauses must NOT match prefixes/superstrings. Pins the semantic so a
# future refactor to `any(. | startswith("pipeline:skip-until-"))` would
# fail this test instead of silently over-blocking the inbox.
reset_fixtures
write_inbox_fixture \
  "ENG-AD11|Todo|3|Bug,pipeline:skip-until-human-acts-tomorrow"
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
entry="$(jq -r '.entry_action // ""' <<<"$out")"
if [[ "$issue_id" == "ENG-AD11" ]] && [[ "$entry" == "apply-stage-label" ]]; then
  pass_at "AC-11 QA — inbox filter is exact-match (skip-until-human-acts-tomorrow IS picked)"
else
  fail_at "AC-11 QA — inbox filter is exact-match (skip-until-human-acts-tomorrow IS picked)" "out=$out"
fi

# ─── AC-12: ENG-24 QA adversarial — Bug B uniformity for BOTH labels at once ──
# A stage-labeled issue carrying BOTH pipeline:skip-until-human-acts AND
# pipeline:skip-until-code-changes simultaneously, with NO state file,
# must vacate AND have NEITHER label stripped. The brainstorm §6 case 1
# claims this is "transitively covered by AC-9 + AC-10 — both labels
# exercise the same branch" but neither AC-9 nor AC-10 actually plants
# both labels. This pins the uniformity-claim directly: a future refactor
# that conditionally strips one label depending on the other being
# present would pass AC-9/AC-10 individually but fail this test.
reset_fixtures
write_label_fixture "stage:planning" \
  "ENG-AD12|In Progress|3|Bug,stage:planning,pipeline:skip-until-human-acts,pipeline:skip-until-code-changes"
# No mkdir / no issue-state.json — exercises the orphan-skip-label branch
# with both labels set.

LINEAR_STUB_LOG="$STUB_DIR/linear-calls-ad12.log"
: > "$LINEAR_STUB_LOG"
export LINEAR_STUB_LOG

out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"

stripped_human=0; stripped_code=0
grep -Fxq 'remove-label ENG-AD12 pipeline:skip-until-human-acts' "$LINEAR_STUB_LOG" && stripped_human=1
grep -Fxq 'remove-label ENG-AD12 pipeline:skip-until-code-changes' "$LINEAR_STUB_LOG" && stripped_code=1

unset LINEAR_STUB_LOG

if [[ "$issue_id" != "ENG-AD12" ]] && (( stripped_human == 0 )) && (( stripped_code == 0 )); then
  pass_at "AC-12 QA — both skip labels + no state file vacates and preserves BOTH labels"
else
  fail_at "AC-12 QA — both skip labels + no state file vacates and preserves BOTH labels" \
    "issue=$issue_id stripped_human=$stripped_human stripped_code=$stripped_code"
fi

# ─── AC-13: ENG-24 QA adversarial — Bug A inbox filter, BOTH labels at once ──
# A Todo issue carrying BOTH pipeline:skip-until-human-acts AND
# pipeline:skip-until-code-changes must be filtered out. Either filter
# clause alone is sufficient, so AC-8 / AC-8b each prove only one. This
# guards against a future jq refactor that combines the two clauses with
# `or` semantics or accidentally drops one — either way, AC-8 + AC-8b
# would still pass (each label is present in only one of the single-
# label fixtures), but co-occurrence on the same issue would leak
# through. Tests order-independent dropping.
reset_fixtures
write_inbox_fixture \
  "ENG-AD13|Todo|3|Bug,pipeline:skip-until-human-acts,pipeline:skip-until-code-changes"
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
if [[ "$issue_id" == "null" ]]; then
  pass_at "AC-13 QA — Todo carrying BOTH skip-until-* labels is NOT inbox-picked"
else
  fail_at "AC-13 QA — Todo carrying BOTH skip-until-* labels is NOT inbox-picked" "out=$out"
fi

# ─── ENG-50: stage:reviewing dispatch gating via review_should_dispatch ──
# Stub review-poll.sh: review_should_dispatch returns based on
# $REVIEW_SHOULD_DISPATCH env var (0 → truthy/dispatch, 1 → falsy/idle).
cat > "$STUB_DIR/review-poll.sh" <<'SH'
review_should_dispatch() { return "${REVIEW_SHOULD_DISPATCH:-0}"; }
export -f review_should_dispatch
SH

# ENG-53 #12: poll.sh now derives the branch via bin/branch-name.sh
# (not via linear.sh::gitBranchName). Stub it so the test environment's
# poll.sh::reviewing path finds a branch deterministically.
cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
ident_lower="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
printf 'feat/%s-stub-slug\n' "$ident_lower"
SH
chmod +x "$STUB_DIR/branch-name.sh"

# linear.sh stub (does NOT need to expose gitBranchName any more, but the
# ENG-53 #12 fix removes that dependency entirely; keeping the field
# present is harmless cruft).
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
  get-issue)
    # gitBranchName intentionally OMITTED — poll.sh's reviewing path no
    # longer reads it (ENG-53 #12). Mirrors production reality.
    printf '%s' "{\"data\":{\"issue\":{\"identifier\":\"$2\"}}}"
    ;;
  remove-label|add-label|swap-stage|transition-state|add-comment|add-or-update-comment|refresh-cache|stage-of|has-label)
    [[ -n "${LINEAR_STUB_LOG-}" ]] && printf '%s\n' "$*" >> "$LINEAR_STUB_LOG"
    exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"

# Case ENG-50-A: stage:reviewing with REVIEW_SHOULD_DISPATCH=0 (dispatch).
reset_fixtures
labels_json='["stage:reviewing"]'
class="$(REVIEW_SHOULD_DISPATCH=0 _poll_classify_labels "ENG-590" "$labels_json")"
adv="$(jq -r '.advanceable' <<<"$class")"
slot="$(jq -r '.slot' <<<"$class")"
if [[ "$adv" == "true" && "$slot" == "hold" ]]; then
  pass_at "ENG-50: stage:reviewing + dispatch=true → hold/advanceable"
else
  fail_at "ENG-50: stage:reviewing + dispatch=true" "got slot=$slot adv=$adv"
fi

# Case ENG-50-B: stage:reviewing with REVIEW_SHOULD_DISPATCH=1 (idle).
# ENG-90 D-002: review-idle now vacates the slot with operator_action_required=false
# (next-tick orchestrator-side state check via review_should_dispatch is the
# implicit recall path). Pre-ENG-90 emitted hold/advanceable=false (held the
# slot AND blocked sibling work — the starvation surface this ticket fixes).
class="$(REVIEW_SHOULD_DISPATCH=1 _poll_classify_labels "ENG-591" "$labels_json")"
adv="$(jq -r '.advanceable' <<<"$class")"
slot="$(jq -r '.slot' <<<"$class")"
oar="$(jq -r '.operator_action_required | tostring' <<<"$class")"
if [[ "$adv" == "false" && "$slot" == "vacate" && "$oar" == "false" ]]; then
  pass_at "ENG-50/ENG-90: stage:reviewing + dispatch=false → vacate/oar=false (D-002)"
else
  fail_at "ENG-50/ENG-90: stage:reviewing + dispatch=false" \
    "got slot=$slot adv=$adv oar=$oar"
fi

# Case ENG-50-C: non-reviewing stage unchanged (sanity).
labels_json='["stage:implementing"]'
class="$(_poll_classify_labels "ENG-592" "$labels_json")"
adv="$(jq -r '.advanceable' <<<"$class")"
if [[ "$adv" == "true" ]]; then
  pass_at "ENG-50: stage:implementing unchanged (default branch advanceable)"
else
  fail_at "ENG-50: stage:implementing default branch" "got adv=$adv"
fi

# ─── ENG-78 D-003: retry-immediately state preserved across orphan cleanup ──
# Setup: a state file with policy=retry-immediately, labels set without
# either skip-until-* label.
reset_fixtures
mkdir -p "$(issue_dir ENG-925)"
printf '{"policy":"retry-immediately","retry_count":1,"evidence":{"pipeline_content_hash":"h1","branch_head_sha":"s1"},"branch":"feat/eng-925"}' \
  > "$(issue_dir ENG-925)/issue-state.json"

labels='["stage:implementing"]'
# _poll_evaluate_skip returns 0 (include); we don't read its stdout here —
# we only verify the side effect on the state file.
if _poll_evaluate_skip "ENG-925" "$labels" >/dev/null 2>&1; then
  if [[ -f "$(issue_dir ENG-925)/issue-state.json" ]]; then
    pass_at "ENG-78 D-003: retry-immediately state preserved when no skip label"
  else
    fail_at "ENG-78 D-003: retry-immediately state was deleted (orphan-cleanup overreach)" \
      "$(issue_dir ENG-925)/issue-state.json missing after _poll_evaluate_skip"
  fi
else
  fail_at "ENG-78 D-003: _poll_evaluate_skip should return 0 (include) for retry-immediately" \
    "non-zero exit"
fi
rm -rf "$PROJECT_STATE_DIR/ENG-925"

# ─── ENG-78 D-003 adversarial: orphan skip-until-* state still cleaned up ──
# A state file with policy=skip-until-code-changes BUT no skip label is
# still treated as orphan (pre-ENG-78 orphan-cleanup behavior preserved).
reset_fixtures
mkdir -p "$(issue_dir ENG-926)"
printf '{"policy":"skip-until-code-changes","retry_count":2,"evidence":{"pipeline_content_hash":"h2","branch_head_sha":"s2"},"branch":"feat/eng-926"}' \
  > "$(issue_dir ENG-926)/issue-state.json"
labels='["stage:implementing"]'
if _poll_evaluate_skip "ENG-926" "$labels" >/dev/null 2>&1; then
  if [[ ! -f "$(issue_dir ENG-926)/issue-state.json" ]]; then
    pass_at "ENG-78 D-003 adversarial: orphan skip-until-code-changes state cleaned up"
  else
    fail_at "ENG-78 D-003 adversarial: skip-until-code-changes orphan was preserved (overreach)" \
      "state file still exists after _poll_evaluate_skip"
  fi
else
  fail_at "ENG-78 D-003 adversarial: _poll_evaluate_skip should return 0 for orphan" \
    "non-zero exit"
fi
rm -rf "$PROJECT_STATE_DIR/ENG-926"

# ─── QA adversarial (ENG-78 D-003): malformed-JSON state file is treated
#     as orphan. The new policy-aware branch reads `.policy` via
#     `jq -r '.policy // ""' "$state_file" 2>/dev/null || true`; on
#     malformed JSON, jq exits non-zero, the `2>/dev/null` swallows the
#     error, the `|| true` keeps the assignment empty → cur_policy="" →
#     orphan branch fires and rm -f's the file. Without this pin, a
#     future refactor that drops the `2>/dev/null || true` guard would
#     crash _poll_evaluate_skip under set -e for any operator who
#     manually edits issue-state.json. ────────────────────────────────
reset_fixtures
mkdir -p "$(issue_dir ENG-927)"
printf '{ this is not valid json' > "$(issue_dir ENG-927)/issue-state.json"
labels='["stage:implementing"]'
if _poll_evaluate_skip "ENG-927" "$labels" >/dev/null 2>&1; then
  if [[ ! -f "$(issue_dir ENG-927)/issue-state.json" ]]; then
    pass_at "QA adversarial (ENG-78 D-003): malformed-JSON state file orphan-cleaned"
  else
    fail_at "QA adversarial (ENG-78 D-003): malformed-JSON state file should be cleaned up" \
      "state file still present"
  fi
else
  fail_at "QA adversarial (ENG-78 D-003): _poll_evaluate_skip should not crash on malformed JSON" \
    "non-zero exit"
fi
rm -rf "$PROJECT_STATE_DIR/ENG-927"

# ─── QA adversarial (ENG-78 D-003): state file with `.policy = null` JSON
#     literal (NOT missing key) is treated as orphan. jq's `// ""`
#     alternative-default operator returns "" for null, so the new branch
#     correctly reads cur_policy="" and routes to the orphan-cleanup arm.
#     Pre-ENG-78 state files that pre-date the `.policy` field share this
#     fate via the missing-key path; this case pins the explicit-null
#     equivalent so a future move from `// ""` to `// "default"` doesn't
#     silently change semantics. ───────────────────────────────────────
reset_fixtures
mkdir -p "$(issue_dir ENG-928)"
printf '{"policy":null,"retry_count":0,"evidence":{"pipeline_content_hash":"h3","branch_head_sha":"s3"},"branch":"feat/eng-928"}' \
  > "$(issue_dir ENG-928)/issue-state.json"
labels='["stage:implementing"]'
if _poll_evaluate_skip "ENG-928" "$labels" >/dev/null 2>&1; then
  if [[ ! -f "$(issue_dir ENG-928)/issue-state.json" ]]; then
    pass_at "QA adversarial (ENG-78 D-003): policy=null JSON literal treated as orphan"
  else
    fail_at "QA adversarial (ENG-78 D-003): policy=null state file should be cleaned up" \
      "state file still present"
  fi
else
  fail_at "QA adversarial (ENG-78 D-003): _poll_evaluate_skip should return 0 for policy=null" \
    "non-zero exit"
fi
rm -rf "$PROJECT_STATE_DIR/ENG-928"

# ─── QA adversarial (ENG-78 D-003): empty (zero-byte) state file is
#     orphan. Same path as malformed JSON (jq fails on empty input) but
#     a distinct failure shape — pin both so no future filesystem-level
#     edge case sneaks past the policy check. ─────────────────────────
reset_fixtures
mkdir -p "$(issue_dir ENG-929)"
: > "$(issue_dir ENG-929)/issue-state.json"
labels='["stage:implementing"]'
if _poll_evaluate_skip "ENG-929" "$labels" >/dev/null 2>&1; then
  if [[ ! -f "$(issue_dir ENG-929)/issue-state.json" ]]; then
    pass_at "QA adversarial (ENG-78 D-003): zero-byte state file orphan-cleaned"
  else
    fail_at "QA adversarial (ENG-78 D-003): zero-byte state file should be cleaned up" \
      "state file still present"
  fi
else
  fail_at "QA adversarial (ENG-78 D-003): _poll_evaluate_skip should not crash on zero-byte file" \
    "non-zero exit"
fi
rm -rf "$PROJECT_STATE_DIR/ENG-929"

# ─── QA adversarial (ENG-78 D-003): retry-immediately state with retry_count
#     near the escalation cap is preserved (the escalation cap is enforced
#     by classify_failure, NOT by poll's orphan cleanup). Without this,
#     a future "preserve only when retry_count < N" pre-filter in poll
#     would silently break the auto-escalation flow. ─────────────────
reset_fixtures
mkdir -p "$(issue_dir ENG-930)"
printf '{"policy":"retry-immediately","retry_count":1,"evidence":{"pipeline_content_hash":"h4","branch_head_sha":"s4"},"branch":"feat/eng-930"}' \
  > "$(issue_dir ENG-930)/issue-state.json"
labels='["stage:implementing"]'
if _poll_evaluate_skip "ENG-930" "$labels" >/dev/null 2>&1; then
  if [[ -f "$(issue_dir ENG-930)/issue-state.json" ]]; then
    rc="$(jq -r '.retry_count' "$(issue_dir ENG-930)/issue-state.json")"
    if [[ "$rc" == "1" ]]; then
      pass_at "QA adversarial (ENG-78 D-003): retry-immediately state with retry_count=1 preserved verbatim"
    else
      fail_at "QA adversarial (ENG-78 D-003): retry_count was mutated by poll" "got rc=$rc"
    fi
  else
    fail_at "QA adversarial (ENG-78 D-003): retry-immediately state with retry_count=1 was deleted" \
      "$(issue_dir ENG-930)/issue-state.json missing"
  fi
else
  fail_at "QA adversarial (ENG-78 D-003): _poll_evaluate_skip should return 0 for active retry tracking" \
    "non-zero exit"
fi
rm -rf "$PROJECT_STATE_DIR/ENG-930"

# ─── QA adversarial (ENG-85): find_fresh_wait_verdict on empty comment list ──
# Boundary test for new code path — Linear stub returns "[]" (empty array).
# The helper's first while-loop runs over zero rows (last_transition_ts="");
# the second while-loop runs over zero rows (fresh_result=""); the closing
# `[[ "$fresh_result" != "wait" ]] && return empty` short-circuit fires.
# Without this test, a refactor that drops the empty-array guard at the
# top (`[[ -z "$comments" || "$comments" == "null" ]] && return empty`) but
# leaves the post-loop short-circuit in place would still pass — but a
# refactor that drops BOTH (e.g., to "always emit something") would silently
# return a `wait_result=""` shape and trip the wait-arm classifier on issues
# with no Linear history at all.
reset_fixtures
write_comments_fixture "ENG-WAIT-QA-EMPTY"  # zero pairs → []
out_helper="$(find_fresh_wait_verdict "ENG-WAIT-QA-EMPTY" 2>/dev/null || true)"
if [[ -z "$out_helper" ]]; then
  pass_at "QA adversarial (ENG-85): find_fresh_wait_verdict returns empty for [] comments"
else
  fail_at "QA adversarial (ENG-85): find_fresh_wait_verdict empty-comments boundary" \
    "got non-empty: $out_helper"
fi

# ─── QA adversarial (ENG-85): wait verdict OLDER than the latest transition
#     is filtered out by the transition floor.
# Setup: wait at 08:00, THEN a later transition at 09:00.
# find_fresh_wait_verdict's first loop sets last_transition_ts="09:00";
# second loop's `[[ -n "$last_transition_ts" && ! "$ts" > "$last_transition_ts" ]] && continue`
# discards the 08:00 wait. fresh_result="" → return empty.
# This pins the supersession-by-newer-transition rule (the wait was on a
# previous stage iteration; the new stage entry resets the budget).
reset_fixtures
write_comments_fixture "ENG-WAIT-QA-FLOOR" \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T09:00:00Z'
out_helper="$(find_fresh_wait_verdict "ENG-WAIT-QA-FLOOR" 2>/dev/null || true)"
if [[ -z "$out_helper" ]]; then
  pass_at "QA adversarial (ENG-85): wait older than latest transition is floored out"
else
  fail_at "QA adversarial (ENG-85): transition-floor supersession" \
    "got non-empty (wait should be discarded): $out_helper"
fi

# ─── QA adversarial (ENG-85): wait verdict with NO transition history
#     (genesis state) is still surfaced.
# Edge case: an issue with a single wait verdict and no transition events
# at all. last_transition_ts remains empty → second loop's `-n` guard
# short-circuits → wait passes through. Defensive: protects against a
# refactor that "requires" a transition floor by setting it to a sentinel.
reset_fixtures
write_comments_fixture "ENG-WAIT-QA-GENESIS" \
  '<!-- pipeline: verdict result=wait reason=awaiting-ci -->|2026-04-28T08:17:00Z'
out_helper="$(find_fresh_wait_verdict "ENG-WAIT-QA-GENESIS" 2>/dev/null || true)"
reason="$(jq -r '.reason // ""' <<<"$out_helper")"
if [[ "$reason" == "awaiting-ci" ]]; then
  pass_at "QA adversarial (ENG-85): wait with no transition history is still surfaced"
else
  fail_at "QA adversarial (ENG-85): genesis-state wait" \
    "got reason=$reason out=$out_helper"
fi

# ─── QA adversarial (ENG-85): wait then result=pass supersedes the wait.
# Symmetric with AC-WAIT-7 (which uses result=fail). A successful build
# verdict landing while the orchestrator was waiting should not leave the
# issue dangling in wait state — it should advance via find_fresh_verdict's
# transition. This pins that pass/fail/halt all supersede a prior wait.
# Without this, AC-WAIT-7 (fail) alone leaves the pass/halt cases at the
# precedent of "find_fresh_verdict mirrors run-stage.sh:332-356" — true,
# but unpinned at the read-side.
reset_fixtures
write_comments_fixture "ENG-WAIT-QA-PASS" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T10:00:00Z' \
  '<!-- pipeline: verdict result=pass stage=building -->|2026-04-28T10:30:00Z'
out_helper="$(find_fresh_wait_verdict "ENG-WAIT-QA-PASS" 2>/dev/null || true)"
if [[ -z "$out_helper" ]]; then
  pass_at "QA adversarial (ENG-85): pass-supersedes-wait → helper returns empty"
else
  fail_at "QA adversarial (ENG-85): supersession by pass" \
    "got non-empty: $out_helper"
fi

# ─── QA adversarial (ENG-85): pipeline:scope-approval-needed + fresh wait
#     → earlier elif arm wins (vacate, NO wait_recallable). Pass 6 must NOT
#     pick it up (the issue is awaiting human triage, not a build-side
#     external signal). Pins arm ordering: scope-approval / paused / abandoned
#     all take precedence over wait_recallable to prevent silent recall of
#     human-blocked work. Without this, swapping the elif order would
#     visibly leak scope-approval issues into Pass 6 wait recalls.
reset_fixtures
write_comments_fixture "ENG-WAIT-QA-SAN" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:17:00Z'
out="$(_poll_classify_labels "ENG-WAIT-QA-SAN" '["stage:building","pipeline:scope-approval-needed"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
recall="$(jq -r '.wait_recallable // false | tostring' <<<"$out")"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$recall" == "false" ]]; then
  pass_at "QA adversarial (ENG-85): scope-approval-needed precedes wait arm (no wait_recallable)"
else
  fail_at "QA adversarial (ENG-85): scope-approval precedence" \
    "got slot=$slot adv=$adv recall=$recall (want vacate/false/false) full=$out"
fi

# ─── QA adversarial (ENG-85): stage:reviewing issue + wait verdict —
# defense-in-depth check that the new wait arm fires BEFORE the reviewing
# arm. Per ENG-54 the review stage is agent-only and doesn't emit wait,
# but a stray wait marker on a stage:reviewing issue (operator action,
# protocol drift) should not cause the orchestrator to treat it as a
# review-poll.sh dispatch decision. The brainstorm §4 D-002 ordering
# rationale claims this is strictly safer than pre-ENG-85's re-dispatch
# loop on a broken review. This pins it.
reset_fixtures
write_comments_fixture "ENG-WAIT-QA-REVIEW" \
  '<!-- pipeline: transition from=implementing to=reviewing -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:17:00Z'
out="$(_poll_classify_labels "ENG-WAIT-QA-REVIEW" '["stage:reviewing"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
recall="$(jq -r '.wait_recallable | tostring' <<<"$out")"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$recall" == "true" ]]; then
  pass_at "QA adversarial (ENG-85): wait arm precedes stage:reviewing arm (defense-in-depth)"
else
  fail_at "QA adversarial (ENG-85): wait-vs-reviewing branch ordering" \
    "got slot=$slot adv=$adv recall=$recall (want vacate/false/true) full=$out"
fi

# ─── QA adversarial (ENG-85): Pass 6 respects max-concurrent cap.
# Setup: 2 halted-with-stage-summary issues at stage:planning + 1 wait
# at stage:building, max_concurrent=2. With ENG-90 the halted-no-marker
# branch vacates the slot, so this fixture uses halt + stage-summary
# markers (classifier returns hold/advanceable=true). Pass 4 invokes
# verdict_handler against the stubbed Linear API, logs, and falls
# through without dispatching; held_count stays at 2 = max_concurrent.
# Pass 5 inbox is gated `< max_concurrent` and skipped. Pass 6 is
# gated `< max_concurrent` and skipped. Final: idle
# "max-concurrent-reached". The wait issue must NOT be recalled.
# Without this pin, dropping the `(( held_count < max_concurrent ))`
# guard on Pass 6 (or moving Pass 6 above Pass 5's cap-check) would
# over-allocate the dispatcher and starve the held-but-stuck path.
reset_fixtures
write_label_fixture "stage:planning" \
  "ENG-WAIT-QA-CAP-1|In Progress|1|stage:planning,pipeline:halted" \
  "ENG-WAIT-QA-CAP-2|In Progress|1|stage:planning,pipeline:halted"
write_label_fixture "stage:building" \
  "ENG-WAIT-QA-CAP-3|In Progress|1|stage:building"
write_comments_fixture "ENG-WAIT-QA-CAP-1" \
  '<!-- pipeline: verdict result=pass stage=planning -->|2026-04-28T08:00:00Z'
write_comments_fixture "ENG-WAIT-QA-CAP-2" \
  '<!-- pipeline: verdict result=pass stage=planning -->|2026-04-28T08:00:00Z'
write_comments_fixture "ENG-WAIT-QA-CAP-3" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:17:00Z'
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
reason="$(jq -r '.reason // ""' <<<"$out")"
# `idle` emits `{"issue_id":null,"stage":null,"reason":"<idle-reason>"}`.
# Pass 6 firing would emit a real dispatch with a non-null issue_id and a
# `wait re-pickup` reason. Assert: issue_id is null AND the reason starts
# with "max-concurrent-reached" — proving Pass 5/6 were both gated out by
# the cap-check and the final idle path took over.
if [[ "$issue_id" == "null" && "$reason" == max-concurrent-reached* ]]; then
  pass_at "QA adversarial (ENG-85): Pass 6 respects cap when held_count >= max_concurrent"
else
  fail_at "QA adversarial (ENG-85): Pass 6 cap safety" \
    "got issue_id=$issue_id reason=$reason (want issue_id=null + max-concurrent-reached) full=$out"
fi

# ═══════════════════════════════════════════════════════════════════════
# ENG-90 — Slot-occupancy contract: per-classifier-branch unit fixtures.
# Every branch of _poll_classify_labels is pinned by an AC-OAR-* row.
# Adding a new branch without a fixture trips at CI; see CLAUDE.md
# "Slot-occupancy contract (ENG-90)" for the contract.
# ═══════════════════════════════════════════════════════════════════════

# ─── AC-OAR-ABANDONED: pipeline:abandoned → terminal; oar absent ──────
# Use `jq -e 'has(...) | not'` to assert the field is OMITTED, not just
# coerced to literal-null. `jq -r '.field | tostring'` returns "null"
# both for missing AND for explicit null, so a regression that emitted
# `{operator_action_required:null}` would silently pass otherwise.
reset_fixtures
out="$(_poll_classify_labels "ENG-OAR-ABANDONED" '["pipeline:abandoned"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
if [[ "$slot" == "terminal" && "$adv" == "false" ]] \
   && jq -e 'has("operator_action_required") | not' <<<"$out" >/dev/null; then
  pass_at "AC-OAR-ABANDONED pipeline:abandoned → terminal; oar absent"
else
  fail_at "AC-OAR-ABANDONED pipeline:abandoned → terminal" \
    "got slot=$slot adv=$adv full=$out"
fi

# ─── AC-OAR-PAUSED: pipeline:paused → vacate, oar=true ────────────────
reset_fixtures
out="$(_poll_classify_labels "ENG-OAR-PAUSED" '["pipeline:paused"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
oar="$(jq -r '.operator_action_required | tostring' <<<"$out")"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$oar" == "true" ]]; then
  pass_at "AC-OAR-PAUSED pipeline:paused → vacate, oar=true (D-001)"
else
  fail_at "AC-OAR-PAUSED" \
    "got slot=$slot adv=$adv oar=$oar full=$out"
fi

# ─── AC-OAR-SCOPE: pipeline:scope-approval-needed → vacate, oar=true ──
reset_fixtures
out="$(_poll_classify_labels "ENG-OAR-SCOPE" '["pipeline:scope-approval-needed"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
oar="$(jq -r '.operator_action_required | tostring' <<<"$out")"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$oar" == "true" ]]; then
  pass_at "AC-OAR-SCOPE pipeline:scope-approval-needed → vacate, oar=true (D-001)"
else
  fail_at "AC-OAR-SCOPE" \
    "got slot=$slot adv=$adv oar=$oar full=$out"
fi

# ─── AC-OAR-HALT-PASS: halt + stage-summary verdict → hold/advanceable ─
# Verdict-handler-led transition is upcoming in Pass 4; the halt label is
# consumed by apply_transition. Slot remains held (active dispatch work).
reset_fixtures
write_comments_fixture "ENG-OAR-HALT-PASS" \
  '<!-- pipeline: verdict result=pass stage=planning -->|2026-05-09T08:00:00Z'
out="$(_poll_classify_labels "ENG-OAR-HALT-PASS" '["stage:planning","pipeline:halted"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
if [[ "$slot" == "hold" && "$adv" == "true" ]] \
   && jq -e 'has("operator_action_required") | not' <<<"$out" >/dev/null; then
  pass_at "AC-OAR-HALT-PASS halt + stage-summary → hold/advanceable; oar absent"
else
  fail_at "AC-OAR-HALT-PASS" \
    "got slot=$slot adv=$adv full=$out"
fi

# ─── AC-OAR-HALT-FAIL: halt + rejection verdict → hold/advanceable ────
reset_fixtures
write_comments_fixture "ENG-OAR-HALT-FAIL" \
  '<!-- pipeline: verdict result=fail target=implementing -->|2026-05-09T08:00:00Z'
out="$(_poll_classify_labels "ENG-OAR-HALT-FAIL" '["stage:implementing","pipeline:halted"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
if [[ "$slot" == "hold" && "$adv" == "true" ]] \
   && jq -e 'has("operator_action_required") | not' <<<"$out" >/dev/null; then
  pass_at "AC-OAR-HALT-FAIL halt + rejection → hold/advanceable; oar absent"
else
  fail_at "AC-OAR-HALT-FAIL" \
    "got slot=$slot adv=$adv full=$out"
fi

# ─── AC-OAR-HALT-HALT: halt + pipeline-halt verdict → vacate, oar=true ─
# D-003: pipeline-halt marker folds into the default arm; same observable
# behaviour as no-marker / unknown-marker (halt label gates dispatch).
reset_fixtures
write_comments_fixture "ENG-OAR-HALT-HALT" \
  '<!-- pipeline: verdict result=halt reason=agent-blocked -->|2026-05-09T08:00:00Z'
out="$(_poll_classify_labels "ENG-OAR-HALT-HALT" '["stage:implementing","pipeline:halted"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
oar="$(jq -r '.operator_action_required | tostring' <<<"$out")"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$oar" == "true" ]]; then
  pass_at "AC-OAR-HALT-HALT halt + pipeline-halt → vacate, oar=true (D-003)"
else
  fail_at "AC-OAR-HALT-HALT" \
    "got slot=$slot adv=$adv oar=$oar full=$out"
fi

# ─── AC-OAR-HALT-NO-MARKER: halt + no fresh marker → vacate, oar=true ──
# D-003: silent agent crash, externally-applied label, or marker race;
# halt label still gates dispatch. Pre-ENG-90 emitted hold/advanceable=false
# (the starvation surface). Linear stub returns [] for missing comments
# fixture.
reset_fixtures
out="$(_poll_classify_labels "ENG-OAR-HALT-NO-MARKER" '["stage:planning","pipeline:halted"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
oar="$(jq -r '.operator_action_required | tostring' <<<"$out")"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$oar" == "true" ]]; then
  pass_at "AC-OAR-HALT-NO-MARKER halt + no marker → vacate, oar=true (D-003 — was hold pre-fix)"
else
  fail_at "AC-OAR-HALT-NO-MARKER" \
    "got slot=$slot adv=$adv oar=$oar full=$out"
fi

# ─── AC-OAR-HALT-NO-VERDICT: halt + only a transition marker present (no
#     actionable verdict) → vacate, oar=true. find_fresh_verdict ignores
#     non-verdict events (bin/verdict-handler.sh:107-117) and returns
#     empty, so this fixture exercises the same `if -z "$fresh"` no-marker
#     fall-through as AC-OAR-HALT-NO-MARKER (poll.sh:299-305), NOT the
#     case-`*)` arm at poll.sh:292-297.
#
#     Naming note: previously called AC-OAR-HALT-UNKNOWN-MARKER, but
#     find_fresh_verdict never emits marker:"unknown" in production —
#     parse_pipeline_marker only emits known event kinds; the
#     marker:"unknown" jq-projection arm at bin/verdict-handler.sh:139-141
#     is reached only for verdicts with unrecognised result tokens, which
#     the registry rejects. The case-`*)` arm in _poll_classify_labels is
#     defense-in-depth against future drift; observable behaviour is
#     identical to the no-marker fall-through (both vacate/oar=true).
#     Renamed to NO-VERDICT to match the path actually exercised.
reset_fixtures
write_comments_fixture "ENG-OAR-HALT-NO-VERDICT" \
  '<!-- pipeline: transition from=planning to=implementing -->|2026-05-09T08:00:00Z'
out="$(_poll_classify_labels "ENG-OAR-HALT-NO-VERDICT" '["stage:planning","pipeline:halted"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
oar="$(jq -r '.operator_action_required | tostring' <<<"$out")"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$oar" == "true" ]]; then
  pass_at "AC-OAR-HALT-NO-VERDICT halt + transition-only → vacate, oar=true (D-003)"
else
  fail_at "AC-OAR-HALT-NO-VERDICT" \
    "got slot=$slot adv=$adv oar=$oar full=$out"
fi

# ─── AC-OAR-WAIT: stage:building + wait verdict → vacate, oar=false ───
# Wait is Pass-6-recallable; orchestrator-side _handle_wait re-runs the
# predicate. Mirrors AC-WAIT-1's classification but explicitly pins
# operator_action_required=false (D-001).
reset_fixtures
write_comments_fixture "ENG-OAR-WAIT" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:17:00Z'
out="$(_poll_classify_labels "ENG-OAR-WAIT" '["stage:building"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
recall="$(jq -r '.wait_recallable | tostring' <<<"$out")"
oar="$(jq -r '.operator_action_required | tostring' <<<"$out")"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$recall" == "true" && "$oar" == "false" ]]; then
  pass_at "AC-OAR-WAIT wait verdict → vacate/wait_recallable=true/oar=false (D-001)"
else
  fail_at "AC-OAR-WAIT" \
    "got slot=$slot adv=$adv recall=$recall oar=$oar full=$out"
fi

# ─── AC-OAR-REVIEW-DISPATCH: stage:reviewing + REVIEW_SHOULD_DISPATCH=0
#     → hold/advanceable; oar absent. Mirrors ENG-50-A but explicitly
#     pins the absence of the oar field on hold-class outputs.
reset_fixtures
out="$(REVIEW_SHOULD_DISPATCH=0 _poll_classify_labels "ENG-OAR-REVIEW-DISPATCH" '["stage:reviewing"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
if [[ "$slot" == "hold" && "$adv" == "true" ]] \
   && jq -e 'has("operator_action_required") | not' <<<"$out" >/dev/null; then
  pass_at "AC-OAR-REVIEW-DISPATCH review_should_dispatch=true → hold/advanceable; oar absent"
else
  fail_at "AC-OAR-REVIEW-DISPATCH" \
    "got slot=$slot adv=$adv full=$out"
fi

# ─── AC-OAR-REVIEW-IDLE: stage:reviewing + REVIEW_SHOULD_DISPATCH=1
#     → vacate, oar=false (D-002). Pre-ENG-90 emitted hold/advanceable=false
#     (the review-starvation surface).
reset_fixtures
out="$(REVIEW_SHOULD_DISPATCH=1 _poll_classify_labels "ENG-OAR-REVIEW-IDLE" '["stage:reviewing"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
oar="$(jq -r '.operator_action_required | tostring' <<<"$out")"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$oar" == "false" ]]; then
  pass_at "AC-OAR-REVIEW-IDLE review_should_dispatch=false → vacate, oar=false (D-002 — was hold pre-fix)"
else
  fail_at "AC-OAR-REVIEW-IDLE" \
    "got slot=$slot adv=$adv oar=$oar full=$out"
fi

# ─── AC-OAR-SKIP-HUMAN: pipeline:skip-until-human-acts + state file
#     → vacate, oar=true (D-005). Skip-until-human-acts requires operator
#     action (label removal) to recall.
reset_fixtures
mkdir -p "$(issue_dir ENG-OAR-SKIP-HUMAN)"
jq -nc '{policy:"skip-until-human-acts",branch:"feat/test",evidence:{pipeline_content_hash:"x",branch_head_sha:"y"}}' \
  > "$(issue_dir ENG-OAR-SKIP-HUMAN)/issue-state.json"
out="$(_poll_classify_labels "ENG-OAR-SKIP-HUMAN" '["stage:planning","pipeline:skip-until-human-acts"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
oar="$(jq -r '.operator_action_required | tostring' <<<"$out")"
rm -rf "$PROJECT_STATE_DIR/ENG-OAR-SKIP-HUMAN"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$oar" == "true" ]]; then
  pass_at "AC-OAR-SKIP-HUMAN pipeline:skip-until-human-acts → vacate, oar=true (D-005)"
else
  fail_at "AC-OAR-SKIP-HUMAN" \
    "got slot=$slot adv=$adv oar=$oar full=$out"
fi

# ─── AC-OAR-SKIP-CODE-UNCHANGED: pipeline:skip-until-code-changes + state
#     file with hashes matching current → vacate, oar=false (D-005).
#     Auto-recallable: next-tick re-checks pipeline_content_hash + branch
#     SHA and clears the label mid-tick on change.
reset_fixtures
expected_hash="$(compute_pipeline_content_hash)"
mkdir -p "$(issue_dir ENG-OAR-SKIP-CODE-UNCHANGED)"
jq -nc --arg h "$expected_hash" \
  '{policy:"skip-until-code-changes",branch:"feat/test",evidence:{pipeline_content_hash:$h,branch_head_sha:""}}' \
  > "$(issue_dir ENG-OAR-SKIP-CODE-UNCHANGED)/issue-state.json"
# git ls-remote is stubbed (line ~137) to return empty → current_sha=""
# matches state file's branch_head_sha="" → evidence-unchanged path → rc=1.
out="$(_poll_classify_labels "ENG-OAR-SKIP-CODE-UNCHANGED" '["stage:planning","pipeline:skip-until-code-changes"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
oar="$(jq -r '.operator_action_required | tostring' <<<"$out")"
rm -rf "$PROJECT_STATE_DIR/ENG-OAR-SKIP-CODE-UNCHANGED"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$oar" == "false" ]]; then
  pass_at "AC-OAR-SKIP-CODE-UNCHANGED skip-until-code-changes evidence-unchanged → vacate, oar=false (D-005)"
else
  fail_at "AC-OAR-SKIP-CODE-UNCHANGED" \
    "got slot=$slot adv=$adv oar=$oar full=$out"
fi

# ─── AC-OAR-SKIP-CODE-NO-STATE: pipeline:skip-until-code-changes WITHOUT a
#     state file → vacate, oar=true (D-005 review-fix). _poll_evaluate_skip
#     short-circuits at bin/poll.sh:87-89 BEFORE the evidence check, so the
#     next tick takes the identical path — no orchestrator-side recall. Only
#     operator action recovers (label removal, or classify-failure.sh
#     belatedly writing the state file). Pinned distinct from
#     AC-OAR-SKIP-CODE-UNCHANGED (which DOES auto-recover via the
#     pipeline_content_hash / branch SHA recompute).
reset_fixtures
# Intentionally do NOT create issue-state.json for ENG-OAR-SKIP-CODE-NO-STATE.
out="$(_poll_classify_labels "ENG-OAR-SKIP-CODE-NO-STATE" '["stage:planning","pipeline:skip-until-code-changes"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
oar="$(jq -r '.operator_action_required | tostring' <<<"$out")"
if [[ "$slot" == "vacate" && "$adv" == "false" && "$oar" == "true" ]]; then
  pass_at "AC-OAR-SKIP-CODE-NO-STATE skip-until-code-changes + no state file → vacate, oar=true (D-005 review-fix)"
else
  fail_at "AC-OAR-SKIP-CODE-NO-STATE" \
    "got slot=$slot adv=$adv oar=$oar full=$out"
fi

# ─── AC-OAR-DEFAULT: stage label only, no other markers → hold/advanceable
#     The catch-all else arm; oar absent.
reset_fixtures
out="$(_poll_classify_labels "ENG-OAR-DEFAULT" '["stage:implementing"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable | tostring' <<<"$out")"
if [[ "$slot" == "hold" && "$adv" == "true" ]] \
   && jq -e 'has("operator_action_required") | not' <<<"$out" >/dev/null; then
  pass_at "AC-OAR-DEFAULT default catch-all → hold/advanceable; oar absent"
else
  fail_at "AC-OAR-DEFAULT" \
    "got slot=$slot adv=$adv full=$out"
fi

# ═══════════════════════════════════════════════════════════════════════
# ENG-90 — Multi-issue regression fixtures (main()-level integration).
# Pin the literal starvation scenarios that motivated the contract: a
# stuck "hold" classification of agent-idle work blocked sibling issues
# from advancing.
# ═══════════════════════════════════════════════════════════════════════

# ─── AC-OAR-REVIEW-STARVATION: ENG-A at stage:reviewing+idle; ENG-B at
#     stage:implementing; cap=1. main() dispatches ENG-B (review-vacate
#     freed the slot per D-002). Pre-ENG-90, ENG-A held the slot and
#     blocked ENG-B's dispatch. Direct regression for the Linear issue
#     body's primary motivating example.
#
#     Why cap=1, not the test default cap=2: under cap=2, BOTH ENG-A and
#     ENG-B fit in held[] regardless of D-002. Pre-fix Pass 4 would skip
#     ENG-A (advanceable=false guard, line ~528) then dispatch ENG-B —
#     identical observable to post-fix. Cap=1 forces the slot pinch:
#     pre-fix Pass 3 sorts reviewing (idx=4) above implementing (idx=2),
#     held=[ENG-A] holds the only slot, Pass 4 skips ENG-A and the
#     orchestrator goes idle (no JSON output). Post-fix ENG-A vacates,
#     held=[ENG-B], and Pass 4 dispatches ENG-B. The assertion now
#     genuinely fails pre-fix, satisfying "regression test must fail
#     under the regression."
reset_fixtures
SCRATCH_CONFIG="$STUB_DIR/config-cap-1.json"
jq -n '{
  orchestrator: {paused: false, max_concurrent_features: 1, alert_on_halted_over: 5},
  linear: {
    native_states: {inbox: "Todo", active: "In Progress", done: "Done"},
    workflow_stages: ["brainstorming","planning","implementing","ui","reviewing","qa","building","released"],
    stage_label_prefix: "stage:"
  }
}' > "$SCRATCH_CONFIG"
ORIG_CONFIG="$CONFIG"
CONFIG="$SCRATCH_CONFIG"
write_label_fixture "stage:reviewing" \
  "ENG-OAR-REV-A|In Progress|3|stage:reviewing"
write_label_fixture "stage:implementing" \
  "ENG-OAR-REV-B|In Progress|3|stage:implementing"
out="$(REVIEW_SHOULD_DISPATCH=1 main 2>/dev/null || true)"
CONFIG="$ORIG_CONFIG"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
stage="$(jq -r '.stage // ""' <<<"$out")"
if [[ "$issue_id" == "ENG-OAR-REV-B" && "$stage" == "implementing" ]]; then
  pass_at "AC-OAR-REVIEW-STARVATION review-vacate frees slot for sibling impl (D-002, cap=1)"
else
  fail_at "AC-OAR-REVIEW-STARVATION" \
    "got issue_id=$issue_id stage=$stage full=$out"
fi

# ─── AC-OAR-HALT-NO-MARKER-STARVATION: ENG-A at stage:planning + halt + no
#     marker; ENG-B Todo in inbox; cap=1. main() dispatches ENG-B with
#     entry_action=apply-stage-label (halt-no-marker freed the slot per
#     D-003). Pre-ENG-90, ENG-A held the slot and Pass 5's inbox gate
#     skipped — no inbox issue could enter the pipeline.
#
#     Why cap=1, not the test default cap=2: under cap=2, Pass 5's inbox
#     gate (held_count < max_concurrent → 1 < 2 = true) admits ENG-B
#     regardless of whether ENG-A holds or vacates. Pre-fix and post-fix
#     dispatch identically. Cap=1 closes the gate pre-fix
#     (held_count=1 ≥ cap=1) and opens it post-fix (held_count=0 < 1),
#     which is the literal regression D-003 fixes.
reset_fixtures
SCRATCH_CONFIG="$STUB_DIR/config-cap-1.json"
jq -n '{
  orchestrator: {paused: false, max_concurrent_features: 1, alert_on_halted_over: 5},
  linear: {
    native_states: {inbox: "Todo", active: "In Progress", done: "Done"},
    workflow_stages: ["brainstorming","planning","implementing","ui","reviewing","qa","building","released"],
    stage_label_prefix: "stage:"
  }
}' > "$SCRATCH_CONFIG"
ORIG_CONFIG="$CONFIG"
CONFIG="$SCRATCH_CONFIG"
write_label_fixture "stage:planning" \
  "ENG-OAR-HNMS-A|In Progress|3|stage:planning,pipeline:halted"
# No write_comments_fixture for ENG-OAR-HNMS-A → linear.sh stub returns []
write_inbox_fixture \
  "ENG-OAR-HNMS-B|Todo|3|Bug"
out="$(main 2>/dev/null || true)"
CONFIG="$ORIG_CONFIG"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
entry="$(jq -r '.entry_action // ""' <<<"$out")"
if [[ "$issue_id" == "ENG-OAR-HNMS-B" && "$entry" == "apply-stage-label" ]]; then
  pass_at "AC-OAR-HALT-NO-MARKER-STARVATION halt-no-marker frees slot for inbox pickup (D-003, cap=1)"
else
  fail_at "AC-OAR-HALT-NO-MARKER-STARVATION" \
    "got issue_id=$issue_id entry=$entry full=$out"
fi

# ─── AC-OAR-DECIDE-CONTINUE-RECOVERS-HALT-NO-MARKER: simulates the
#     post-resume tick after `bin/pipeline.sh decide --action continue`.
#     Fixture state: halt label cleared (operator action) + transition
#     waypoint marker present (operator-resume from decide). Classifier
#     sees no halt label + a transition waypoint → catch-all else arm
#     → hold/advanceable=true. main() dispatches the issue with
#     entry_action=run, proving the documented recovery contract works.
reset_fixtures
write_label_fixture "stage:planning" \
  "ENG-OAR-DCRH-A|In Progress|3|stage:planning"
write_comments_fixture "ENG-OAR-DCRH-A" \
  '<!-- pipeline: transition from=planning to=planning reason=operator-resume -->|2026-05-09T08:00:00Z'
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
stage="$(jq -r '.stage // ""' <<<"$out")"
entry="$(jq -r '.entry_action // ""' <<<"$out")"
if [[ "$issue_id" == "ENG-OAR-DCRH-A" && "$stage" == "planning" && "$entry" == "run" ]]; then
  pass_at "AC-OAR-DECIDE-CONTINUE-RECOVERS-HALT-NO-MARKER post-resume tick dispatches (D-003 recovery)"
else
  fail_at "AC-OAR-DECIDE-CONTINUE-RECOVERS-HALT-NO-MARKER" \
    "got issue_id=$issue_id stage=$stage entry=$entry full=$out"
fi

# ─── Summary ──────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
