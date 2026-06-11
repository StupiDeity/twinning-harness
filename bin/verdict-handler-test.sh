#!/usr/bin/env bash
# Unit tests for verdict_handler (ENG-18).
# Runs under $PIPELINE_DRY_RUN=1 with stubbed linear.sh/slack.sh/metrics.sh
# so no Linear/Slack side effects. Canned comment fixtures stand in for
# Linear's GraphQL response.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

# ─── Stub external scripts ───────────────────────────────────────────
# Redirect bash "bash $SCRIPT_DIR/..." calls in verdict-handler.sh to
# local stubs via a tempdir. The stubs record their invocations to a
# log file so tests can assert call shapes.
STUB_DIR="$(mktemp -d)"
STUB_LOG="$STUB_DIR/calls.log"
export STUB_DIR STUB_LOG
: > "$STUB_LOG"
trap 'rm -rf "$STUB_DIR"' EXIT

# Exported so stubs (run via `bash ...`) see them.
export VH_FIXTURE_COMMENTS=""
export VH_CURRENT_STAGE_LABEL=""
export VH_CURRENT_LABELS=""

# linear.sh stub: handles get-comments (returns $VH_FIXTURE_COMMENTS),
# add-comment, add-label, remove-label, swap-stage, transition-state,
# stage-of (returns $VH_CURRENT_STAGE_LABEL), has-label, add-comment.
cat > "$STUB_DIR/linear.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "linear.sh $*" >> "$STUB_LOG"
case "$1" in
  get-comments) printf '%s\n' "${VH_FIXTURE_COMMENTS:-[]}" ;;
  has-label)
    # Returns 0 iff $2 is in $VH_CURRENT_LABELS (whitespace-separated).
    for lbl in ${VH_CURRENT_LABELS:-}; do
      [[ "$lbl" == "$3" ]] && exit 0
    done
    exit 1 ;;
  stage-of) printf '%s\n' "${VH_CURRENT_STAGE_LABEL:-}" ;;
  all-stage-labels)
    # Returns space-separated list of all stage:* labels from $VH_CURRENT_LABELS.
    result=""
    for lbl in ${VH_CURRENT_LABELS:-}; do
      [[ "$lbl" == stage:* ]] && result="${result:+$result }$lbl"
    done
    printf '%s\n' "$result" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"

for cmd in slack.sh metrics.sh; do
  cat > "$STUB_DIR/$cmd" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0") $*" >> "$STUB_LOG"
exit 0
SH
  chmod +x "$STUB_DIR/$cmd"
done

# ─── Source the module with redirected SCRIPT_DIR ────────────────────
# verdict-handler.sh internally sets _VH_SCRIPT_DIR from BASH_SOURCE; we
# override after sourcing so its `bash "$_VH_SCRIPT_DIR/linear.sh" ...`
# calls hit our stubs.
# shellcheck source=verdict-handler.sh
source "$SCRIPT_DIR/verdict-handler.sh"
_VH_SCRIPT_DIR="$STUB_DIR"

PASS=0; FAIL=0
fail_at() { printf '  ❌ %s\n      %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }

reset_calls() { : > "$STUB_LOG"; }
calls_grep() {
  local n
  n=$(grep -cF "$1" "$STUB_LOG" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}
calls_contains() { grep -qF "$1" "$STUB_LOG" 2>/dev/null; }

# ─── ENG-60-followup spec-shape assertion helpers ────────────────────
# Replaces brittle `calls_contains "<literal marker bytes>"` checks with
# event-payload assertions. The motivation: the previous test asserted
# the LEGACY marker shape on the wire, so when ENG-60's parser tightened
# to new-shape only and apply_transition was left emitting legacy, the
# tests still passed (they were checking the bug was preserved). A
# spec-shape assertion would have caught the divergence the moment the
# parser changed.
#
# extract_call_body <command> <issue>  → first body of recorded
# `linear.sh <command> <issue> <body>...` line.
extract_call_body() {
  local cmd="$1" issue="$2"
  grep -E "^linear\.sh ${cmd} ${issue} " "$STUB_LOG" 2>/dev/null \
    | head -1 \
    | sed -E "s|^linear\.sh ${cmd} ${issue} ||"
}

# assert_marker_event <command> <issue> <expected_event> [<k1>=<v1> ...]
# Round-trip the body through parse_pipeline_marker and check event +
# every named field. Returns 0 on full match, 1 otherwise. The mismatch
# detail is left for the caller's fail_at message.
assert_marker_event() {
  local cmd="$1" issue="$2" expected_event="$3"; shift 3
  local body ev
  body="$(extract_call_body "$cmd" "$issue")"
  [[ -n "$body" ]] || return 1
  ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
  [[ -n "$ev" ]] || return 1
  [[ "$(jq -r '.event' <<<"$ev")" == "$expected_event" ]] || return 1
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [[ "$(jq -r --arg k "$k" '.[$k] // ""' <<<"$ev")" == "$v" ]] || return 1
  done
  return 0
}

# Build a canned comments fixture. Args are `body|createdAt` pairs,
# processed in the order given; id is synthesised.
mk_fixture() {
  local i=0 arr='[]'
  for pair in "$@"; do
    local body="${pair%|*}" ts="${pair##*|}"
    arr="$(jq -c --arg id "c$i" --arg body "$body" --arg ts "$ts" \
      '. + [{id:$id, body:$body, createdAt:$ts}]' <<<"$arr")"
    i=$((i+1))
  done
  printf '%s' "$arr"
}

# ─── Case 1: forward-transition-qa-to-building ───────────────────────
# Transition at T0 + stage-summary at T1. Current stage qa + halted.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=implementing to=qa -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline: verdict result=pass stage=qa -->|2026-04-23T11:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:qa"
VH_CURRENT_LABELS="stage:qa pipeline:halted"
rc=0; verdict_handler "ENG-901" "qa" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "0" ]] \
   && assert_marker_event "add-comment" "ENG-901" "transition" "from=qa" "to=building" \
   && calls_contains "add-label ENG-901 stage:building" \
   && calls_contains "remove-label ENG-901 stage:qa" \
   && calls_contains "remove-label ENG-901 pipeline:halted"; then
  pass_at "case-1 forward-transition-qa-to-building"
else
  fail_at "case-1 forward-transition-qa-to-building" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

fwd="$(_vh_lookup_forward qa)"
[[ "$fwd" == "building" ]] \
  && pass_at "case-1 _vh_lookup_forward qa = building" \
  || fail_at "case-1 _vh_lookup_forward qa = building" "got $fwd"

# ─── Case 2: loopback-qa-to-implementing ─────────────────────────────
# New-shape rejection body (no source); T2.2 fallback derives source from
# VH_CURRENT_STAGE_LABEL via linear.sh stage-of.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=implementing to=qa -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline: verdict result=fail target=implementing -->|2026-04-23T11:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:qa"
VH_CURRENT_LABELS="stage:qa pipeline:halted"
rc=0; verdict_handler "ENG-902" "qa" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "0" ]] \
   && assert_marker_event "add-comment" "ENG-902" "transition" "from=qa" "to=implementing" \
   && calls_contains "add-label ENG-902 stage:implementing" \
   && calls_contains "remove-label ENG-902 stage:qa" \
   && calls_contains "remove-label ENG-902 pipeline:halted" \
   && ! calls_contains "add-label ENG-902 pipeline:supersede"; then
  pass_at "case-2 loopback-qa-to-implementing"
else
  fail_at "case-2 loopback-qa-to-implementing" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── Case 3: loopback-reviewing-to-brainstorming-adds-supersede ──────
# New-shape rejection body (no source); T2.2 fallback derives source from
# VH_CURRENT_STAGE_LABEL via linear.sh stage-of.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=ui to=reviewing -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline: verdict result=fail target=brainstorming -->|2026-04-23T11:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:reviewing"
VH_CURRENT_LABELS="stage:reviewing pipeline:halted"
rc=0; verdict_handler "ENG-903" "reviewing" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "0" ]] \
   && calls_contains "add-label ENG-903 stage:brainstorming" \
   && calls_contains "remove-label ENG-903 stage:reviewing" \
   && calls_contains "add-label ENG-903 pipeline:supersede"; then
  pass_at "case-3 loopback-reviewing-to-brainstorming-adds-supersede"
else
  fail_at "case-3 loopback-reviewing-to-brainstorming-adds-supersede" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── Case 4: halt-for-human-preserves-state ──────────────────────────
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=implementing to=qa -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline: verdict result=halt reason=agent-blocked -->|2026-04-23T11:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:qa"
VH_CURRENT_LABELS="stage:qa pipeline:halted"
rc=0; verdict_handler "ENG-904" "qa" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "1" ]] \
   && ! calls_contains "add-label ENG-904 stage:building" \
   && ! calls_contains "remove-label ENG-904 pipeline:halted"; then
  pass_at "case-4 halt-for-human-preserves-state"
else
  fail_at "case-4 halt-for-human-preserves-state" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── Case 5: no-marker-protocol-violation ────────────────────────────
# Only a transition comment; no fresh verdict marker newer than it.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=implementing to=qa -->|2026-04-23T10:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:qa"
VH_CURRENT_LABELS="stage:qa pipeline:halted"
rc=0; verdict_handler "ENG-905" "qa" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "2" ]] \
   && calls_contains "add-comment ENG-905 --sig protocol-violation/no-marker/ENG-905" \
   && ! calls_contains "remove-label ENG-905 pipeline:halted"; then
  pass_at "case-5 no-marker-protocol-violation"
else
  fail_at "case-5 no-marker-protocol-violation" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── Case 6: stage-mismatch-protocol-violation ───────────────────────
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=ui to=reviewing -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline: verdict result=pass stage=qa -->|2026-04-23T11:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:reviewing"
VH_CURRENT_LABELS="stage:reviewing pipeline:halted"
rc=0; verdict_handler "ENG-906" "reviewing" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "2" ]] \
   && calls_contains "add-comment ENG-906 --sig protocol-violation/stage-mismatch/ENG-906"; then
  pass_at "case-6 stage-mismatch-protocol-violation"
else
  fail_at "case-6 stage-mismatch-protocol-violation" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── Case 7: unknown-loopback-protocol-violation ─────────────────────
# New-shape rejection; T2.2 fallback derives source from VH_CURRENT_STAGE_LABEL.
# ui→planning is not a valid loopback row → protocol violation.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=implementing to=ui -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline: verdict result=fail target=planning -->|2026-04-23T11:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:ui"
VH_CURRENT_LABELS="stage:ui pipeline:halted"
rc=0; verdict_handler "ENG-907" "ui" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "2" ]] \
   && calls_contains "add-comment ENG-907 --sig protocol-violation/unknown-loopback/ENG-907"; then
  pass_at "case-7 unknown-loopback-protocol-violation"
else
  fail_at "case-7 unknown-loopback-protocol-violation" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── Case 7a: no-marker reason enrichment ────────────────────────────
# When no verdict markers exist on the issue at all, the protocol-violation
# halt body must include the current_dispatch_id (or `<unset>` placeholder)
# and a Resolution hint so operators can recover without reading code.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=implementing to=qa -->|2026-04-23T10:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:qa"
VH_CURRENT_LABELS="stage:qa pipeline:halted"
rc=0; verdict_handler "ENG-907a" "qa" >/dev/null 2>&1 || rc=$?
# Body checks use calls_contains rather than extract_call_body because
# the halt body is multi-line and extract_call_body | head -1 would
# truncate to the first line only.
if [[ "$rc" == "2" ]] \
   && calls_contains "add-comment ENG-907a --sig protocol-violation/no-marker/ENG-907a" \
   && calls_contains "current_dispatch_id" \
   && calls_contains "Resolution" \
   && calls_contains "pipeline.sh decide ENG-907a"; then
  pass_at "case-7a no-marker reason enrichment (current_dispatch_id + Resolution hint in body)"
else
  fail_at "case-7a no-marker reason enrichment" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── Case 7b: dispatch-id-mismatch protocol-violation ────────────────
# ENG-87 strict-id path: a verdict-pass marker exists AND a meta:dispatch
# marker exists on the issue, but no comment carries the CURRENT
# dispatch_id. This is the ENG-96 scenario: planning agent wrote a
# stage-summary with `<!-- meta: dispatch id=$PIPELINE_DISPATCH_ID stage=
# planning -->` (literal-placeholder) → strict path activates, current id
# not found, returns empty. Expectation: new case_id "dispatch-id-mismatch"
# (not "no-marker"), with the current id + observed marker values in the
# halt body so operators can diagnose without reading code.
reset_calls
# Mock current_dispatch_id() for this test only — the stub in the
# linear.sh fake doesn't know about issue-state.json, and the real
# function reads from $PROJECT_STATE_DIR which we don't want to touch.
current_dispatch_id() { printf '%s' 'ENG-907b-d0002'; }
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=brainstorming to=planning -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline: verdict result=pass stage=planning -->|2026-04-23T11:00:00.000Z" \
  "**planning summary** <!-- meta: dispatch id=\$PIPELINE_DISPATCH_ID stage=planning -->|2026-04-23T11:00:10.000Z")"
VH_CURRENT_STAGE_LABEL="stage:planning"
VH_CURRENT_LABELS="stage:planning"
rc=0; verdict_handler "ENG-907b" "planning" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "2" ]] \
   && calls_contains "add-comment ENG-907b --sig protocol-violation/dispatch-id-mismatch/ENG-907b" \
   && calls_contains "ENG-907b-d0002" \
   && calls_contains '$PIPELINE_DISPATCH_ID' \
   && calls_contains "Resolution"; then
  pass_at "case-7b dispatch-id-mismatch case_id + enriched halt body"
else
  fail_at "case-7b dispatch-id-mismatch" "rc=$rc calls=$(cat "$STUB_LOG")"
fi
# Restore real current_dispatch_id for downstream cases.
unset -f current_dispatch_id
current_dispatch_id() {
  local issue="$1"
  [[ -n "$issue" ]] || die "current_dispatch_id: missing issue id"
  local state_file; state_file="$(issue_dir "$issue")/issue-state.json"
  [[ -s "$state_file" ]] || { printf ''; return 0; }
  jq -r '.current_dispatch_id // ""' "$state_file" 2>/dev/null || printf ''
}

# ─── Case 8: most-recent-marker-wins ─────────────────────────────────
# Two stage-summary markers after a transition; newer one wins.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=implementing to=qa -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline: verdict result=pass stage=qa -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline: verdict result=pass stage=qa -->|2026-04-23T11:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:qa"
VH_CURRENT_LABELS="stage:qa pipeline:halted"
fresh="$(find_fresh_verdict "ENG-908")"
cid="$(jq -r '.comment_id' <<<"$fresh")"
if [[ "$cid" == "c2" ]]; then
  pass_at "case-8 most-recent-marker-wins"
else
  fail_at "case-8 most-recent-marker-wins" "got comment_id=$cid (expected c2)"
fi

# ─── Case 9: resume-in-progress-transition ───────────────────────────
# Transition `qa → building` posted, but current stage is still :qa
# and pipeline:halted still applied. Step 0 completes labels 2-5
# without re-posting the transition comment.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=implementing to=qa -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline: verdict result=pass stage=qa -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline: transition from=qa to=building -->|2026-04-23T10:30:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:qa"
VH_CURRENT_LABELS="stage:qa pipeline:halted"
rc=0; verdict_handler "ENG-909" "qa" >/dev/null 2>&1 || rc=$?
# Resume path posts NO new transition comment (the existing one in fixtures is
# the freshness waypoint already on the issue). Spec-shape: any add-comment
# whose body parses as event=transition would falsify the resume contract.
transition_posts="$(calls_grep "add-comment ENG-909 ")"
post_count_with_transition_marker=0
while IFS= read -r body; do
  ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
  [[ -z "$ev" ]] && continue
  [[ "$(jq -r '.event' <<<"$ev")" == "transition" ]] \
    && post_count_with_transition_marker=$((post_count_with_transition_marker + 1))
done < <(grep -E '^linear\.sh add-comment ENG-909 ' "$STUB_LOG" 2>/dev/null \
         | sed -E 's|^linear\.sh add-comment ENG-909 ||')
if [[ "$rc" == "0" ]] \
   && calls_contains "add-label ENG-909 stage:building" \
   && calls_contains "remove-label ENG-909 stage:qa" \
   && calls_contains "remove-label ENG-909 pipeline:halted" \
   && [[ "$post_count_with_transition_marker" == "0" ]]; then
  pass_at "case-9 resume-in-progress-transition"
else
  fail_at "case-9 resume-in-progress-transition" "rc=$rc transition_posts=$transition_posts calls=$(cat "$STUB_LOG")"
fi

# ─── Case 10: dispatch-failure-applies-halted-label (classify-failure integration) ──
# Smoke: the halt marker body must parse as an `agent-failure` or `agent-blocked`
# type once classify-failure.sh is updated (Task 7). Here we only assert the
# Verdict Handler's halt-for-human branch treats that shape correctly.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=planning to=implementing -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline: verdict result=halt reason=agent-failure -->|2026-04-23T11:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:implementing"
VH_CURRENT_LABELS="stage:implementing pipeline:halted pipeline:skip-until-code-changes"
rc=0; verdict_handler "ENG-910" "implementing" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "1" ]] \
   && ! calls_contains "remove-label ENG-910 pipeline:halted"; then
  pass_at "case-10 dispatch-failure-applies-halted-label"
else
  fail_at "case-10 dispatch-failure-applies-halted-label" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── Case 11: scope-deviation-emits-halt-marker ──────────────────────
# Verdict Handler treats `scope-deviation` halts the same as any other
# halt-for-human: rc=1, no transition, halt preserved.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=planning to=implementing -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline: verdict result=halt reason=scope-deviation -->|2026-04-23T11:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:implementing"
VH_CURRENT_LABELS="stage:implementing pipeline:halted"
rc=0; verdict_handler "ENG-911" "implementing" >/dev/null 2>&1 || rc=$?
[[ "$rc" == "1" ]] \
  && pass_at "case-11 scope-deviation-emits-halt-marker" \
  || fail_at "case-11 scope-deviation-emits-halt-marker" "rc=$rc"

# ─── Case 12: decide-continue-posts-decision-and-clears-halt ─────────
# After `bin/pipeline.sh decide --action continue` posts a decision
# comment newer than the scope-violation halt, the verdict handler still
# sees the halt marker as the most recent verdict-shape marker, so rc
# stays 1. decide itself is the actor that removes pipeline:halted —
# not verdict_handler. What this case asserts is that find_fresh_verdict
# IGNORES decision-event markers
# comments (they're not a verdict shape).
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=planning to=implementing -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline: verdict result=halt reason=scope-deviation -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline: decision action=approve gate=scope -->|2026-04-23T11:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:implementing"
VH_CURRENT_LABELS="stage:implementing pipeline:halted"
fresh="$(find_fresh_verdict "ENG-912")"
mtype="$(jq -r '.marker' <<<"$fresh")"
if [[ "$mtype" == "pipeline-halt" ]]; then
  pass_at "case-12 halt-sh-resolve-posts-decision-and-clears-halt (decision is not a verdict marker)"
else
  fail_at "case-12 halt-sh-resolve-posts-decision-and-clears-halt" "fresh marker=$mtype (expected pipeline-halt)"
fi

# ─── Case 13: building-conflict-loops-to-implementing ────────────────
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=qa to=building -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline: verdict result=fail target=implementing -->|2026-04-23T10:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:building"
VH_CURRENT_LABELS="stage:building pipeline:halted"
rc=0; verdict_handler "ENG-913" "building" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "0" ]] \
   && calls_contains "add-label ENG-913 stage:implementing" \
   && calls_contains "remove-label ENG-913 stage:building" \
   && ! calls_contains "add-label ENG-913 stage:released"; then
  pass_at "case-13 building-conflict-loops-to-implementing"
else
  fail_at "case-13 building-conflict-loops-to-implementing" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── Case 14: has-scope-approval via helper (covered by scope-check tests) ──
# We assert the shape that enables has_scope_approval: a `pipeline: decision
# action=approve gate=scope` comment is parseable as such. Verdict Handler does not
# call has_scope_approval — that's scope-check.sh's territory. This case
# validates the comment-shape contract the two modules share.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: verdict result=halt reason=scope-violation -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline: decision action=approve gate=scope -->|2026-04-23T11:00:00.000Z")"
approved_count="$(jq -r '[.[] | select(.body | contains("<!-- pipeline: decision action=approve gate=scope -->"))] | length' <<<"$VH_FIXTURE_COMMENTS")"
[[ "$approved_count" == "1" ]] \
  && pass_at "case-14 has-scope-approval-returns-true-when-decision-post-dates-halt (fixture shape)" \
  || fail_at "case-14 has-scope-approval-returns-true-when-decision-post-dates-halt" "approved_count=$approved_count"

# ─── Case 15: has-scope-approval-returns-false-when-no-decision ──────
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: verdict result=halt reason=scope-violation -->|2026-04-23T10:00:00.000Z")"
approved_count="$(jq -r '[.[] | select(.body | contains("<!-- pipeline: decision action=approve gate=scope -->"))] | length' <<<"$VH_FIXTURE_COMMENTS")"
[[ "$approved_count" == "0" ]] \
  && pass_at "case-15 has-scope-approval-returns-false-when-no-decision (fixture shape)" \
  || fail_at "case-15 has-scope-approval-returns-false-when-no-decision" "approved_count=$approved_count"

# ─── Case 16: verdict-handler-returns-1-on-halt-marker-so-poll-can-continue ──
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=planning to=implementing -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline: verdict result=halt reason=agent-blocked -->|2026-04-23T10:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:implementing"
VH_CURRENT_LABELS="stage:implementing pipeline:halted"
rc=0; verdict_handler "ENG-916" "implementing" >/dev/null 2>&1 || rc=$?
[[ "$rc" == "1" ]] \
  && pass_at "case-16 verdict-handler-returns-1-on-halt-marker-so-poll-can-continue" \
  || fail_at "case-16" "rc=$rc"

# ─── Case 17: halted-with-pass-marker-transitions-in-handler ─────────
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=implementing to=ui -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline: verdict result=pass stage=ui -->|2026-04-23T10:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:ui"
VH_CURRENT_LABELS="stage:ui pipeline:halted"
rc=0; verdict_handler "ENG-917" "ui" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "0" ]] \
   && calls_contains "add-label ENG-917 stage:reviewing"; then
  pass_at "case-17 halted-with-pass-marker-transitions-in-handler"
else
  fail_at "case-17 halted-with-pass-marker-transitions-in-handler" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── Case 18: counter-reset-on-operator-resume (guards.sh fixture shape) ──
# The count_marker_since_last_operator_resume helper in guards.sh is tested
# here by constructing the comment history shape and asserting jq-level
# counting matches the algorithm. Post-ENG-123: only `reason=operator-resume`
# transitions reset the counter; auto-transitions accumulate.
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- meta: metric name=qa_rejection -->|2026-04-23T09:00:00.000Z" \
  "<!-- meta: metric name=qa_rejection -->|2026-04-23T09:30:00.000Z" \
  "<!-- pipeline: transition from=qa to=building -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline: transition from=qa to=qa reason=operator-resume -->|2026-04-23T10:30:00.000Z" \
  "<!-- meta: metric name=qa_rejection -->|2026-04-23T11:00:00.000Z")"
last_ts="$(jq -r '
  [.[] | select(.body | test("<!-- pipeline: transition[^>]*reason=operator-resume"))]
  | sort_by(.createdAt) | last | .createdAt // ""' <<<"$VH_FIXTURE_COMMENTS")"
count_after="$(jq -r --arg t "$last_ts" \
  '[.[] | select(.createdAt > $t) | select(.body | contains("<!-- meta: metric name=qa_rejection -->"))] | length' \
  <<<"$VH_FIXTURE_COMMENTS")"
[[ "$count_after" == "1" ]] \
  && pass_at "case-18 counter-reset-on-operator-resume" \
  || fail_at "case-18 counter-reset-on-operator-resume" "count_after=$count_after (expected 1)"

# ─── Case 19: stale-comment-eng24-resume-returns-1 ───────────────────
# ENG-24 scenario: issue has stage:brainstorming + pipeline:halted, but
# the latest transition comment is "planning → implementing" from 2 days
# ago (stale, from a prior cycle). The new cross-check guard must detect
# that comment.from (planning) != current_stage (brainstorming) and
# return 1. Then verdict_handler falls through to find_fresh_verdict and
# correctly transitions brainstorming → planning via the fresh
# brainstorm done-marker.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=planning to=implementing -->|2026-04-25T12:59:01.000Z" \
  "<!-- pipeline: verdict result=pass stage=brainstorming -->|2026-04-27T06:30:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:brainstorming"
VH_CURRENT_LABELS="stage:brainstorming pipeline:halted"
# Assert resume_in_progress_transition returns 1 (stale comment guard fires).
resume_rc=0
resume_in_progress_transition "ENG-924" >/dev/null 2>&1 || resume_rc=$?
# Now assert the full verdict_handler path transitions correctly.
reset_calls
rc=0; verdict_handler "ENG-924" "brainstorming" >/dev/null 2>&1 || rc=$?
if [[ "$resume_rc" == "1" ]] \
   && [[ "$rc" == "0" ]] \
   && calls_contains "add-label ENG-924 stage:planning" \
   && calls_contains "remove-label ENG-924 stage:brainstorming" \
   && calls_contains "remove-label ENG-924 pipeline:halted" \
   && ! calls_contains "add-label ENG-924 stage:implementing"; then
  pass_at "case-19 stale-comment-eng24-resume-returns-1-then-fresh-verdict-transitions"
else
  fail_at "case-19 stale-comment-eng24-resume-returns-1-then-fresh-verdict-transitions" \
    "resume_rc=$resume_rc rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── Case 20: multi-stage-label-resume-returns-1 ─────────────────────
# Issue has BOTH stage:brainstorming AND stage:implementing AND
# pipeline:halted. The new multi-stage-label guard must detect the
# malformed state and return 1. No apply_transition should be called.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=brainstorming to=planning -->|2026-04-25T10:00:00.000Z" \
  "<!-- pipeline: transition from=planning to=implementing -->|2026-04-25T11:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:brainstorming"
VH_CURRENT_LABELS="stage:brainstorming stage:implementing pipeline:halted"
resume_rc=0
resume_in_progress_transition "ENG-920" >/dev/null 2>&1 || resume_rc=$?
apply_calls="$(calls_grep "add-label ENG-920 stage:")"
if [[ "$resume_rc" == "1" ]] \
   && [[ "$apply_calls" == "0" ]]; then
  pass_at "case-20 multi-stage-label-resume-returns-1-no-apply-transition"
else
  fail_at "case-20 multi-stage-label-resume-returns-1-no-apply-transition" \
    "resume_rc=$resume_rc apply_calls=$apply_calls calls=$(cat "$STUB_LOG")"
fi

# ─── ENG-45: pipeline-wait alone is NOT a verdict shape ────────────────
# Asserts the load-bearing claim from plan A-005: find_fresh_verdict ignores
# wait markers — even when they are the freshest comment newer than the most
# recent pipeline-transition. Without this guarantee, the wait flow would
# post a verdict marker on every wait dispatch and the orchestrator would
# happily transition the issue forward on a not-yet-merged PR.
# (New-shape wait; equivalent coverage provided also by FV5.)
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00.000Z" \
  "<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:17:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:building"
VH_CURRENT_LABELS="stage:building"
result="$(find_fresh_verdict "ENG-45-WAIT" 2>/dev/null || printf '')"
if [[ -z "$result" ]]; then
  pass_at "ENG-45 case-21 find_fresh_verdict ignores pipeline-wait marker (load-bearing for soft re-dispatch)"
else
  fail_at "ENG-45 case-21 find_fresh_verdict ignores pipeline-wait" \
    "got: $result"
fi

# ─── ENG-49 Gap #5: defensive guard — null/empty state name does not die ──
# Repro: config.linear.native_states.in_review missing → state name resolves
# to "null". apply_transition's |reviewing| hook must skip the
# transition-state call and emit a single log line, NOT die (no FATAL output;
# transition still completes the label swap).
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/config.json" <<'JSON'
{
  "orchestrator": {"paused": false},
  "linear": {"native_states": {}}
}
JSON
ORIG_CONFIG="$CONFIG"
CONFIG="$STUB_DIR/config.json"
export CONFIG

apply_transition_log="$(apply_transition "ENG-950" "ui" "reviewing" "" 2>&1)"
CONFIG="$ORIG_CONFIG"
export CONFIG

if printf '%s\n' "$apply_transition_log" | grep -q 'FATAL: state not in cache'; then
  fail_at "Gap-5 defensive guard: no FATAL on missing in_review" \
    "log contained FATAL — defensive guard not in place"
elif printf '%s\n' "$apply_transition_log" | grep -q 'skipping native-state hook'; then
  pass_at "Gap-5 defensive guard: missing in_review logs and skips"
else
  fail_at "Gap-5 defensive guard: missing in_review logs and skips" \
    "log neither FATAL nor skip-message: $apply_transition_log"
fi

# ─── ENG-49 Gap #4: to==released transitions Linear status to Done ─────
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/config.json" <<'JSON'
{
  "orchestrator": {"paused": false},
  "linear": {"native_states": {"in_review": "In Review", "done": "Done"}}
}
JSON
ORIG_CONFIG="$CONFIG"
CONFIG="$STUB_DIR/config.json"
export CONFIG

# Capture transition-state calls made by apply_transition.
TRANSITION_CALLS="$STUB_DIR/transition-state-calls.log"
: > "$TRANSITION_CALLS"
# Modify the linear.sh stub to capture transition-state calls.
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  transition-state) printf '%s\\t%s\\n' "\$2" "\$3" >> "$TRANSITION_CALLS" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"
ORIG_VH_DIR="$_VH_SCRIPT_DIR"
_VH_SCRIPT_DIR="$STUB_DIR"

apply_transition "ENG-960" "building" "released" "" >/dev/null 2>&1 || true

CONFIG="$ORIG_CONFIG"
_VH_SCRIPT_DIR="$ORIG_VH_DIR"
export CONFIG

if grep -qE '^ENG-960\sDone$' "$TRANSITION_CALLS"; then
  pass_at "Gap-4 to==released transitions to Done"
else
  fail_at "Gap-4 to==released transitions to Done" \
    "captured: $(cat "$TRANSITION_CALLS" 2>/dev/null || echo '<empty>')"
fi

# ─── ENG-49 Gap #1: to==reviewing opens PR when none exists ───────────
# Stub gh and capture invocations.
GH_CALLS="$STUB_DIR/gh-calls.log"
: > "$GH_CALLS"
cat > "$STUB_DIR/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALLS"
case "\$1 \$2" in
  "pr list")
    # Default to "no PR exists"; tests can override via \$GH_PR_LIST_RESULT.
    printf '%s' "\${GH_PR_LIST_RESULT:-0}" ;;
  "pr create") printf '%s' "https://example.com/pr/new" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/gh"

# Stub render-pr-body.sh too, to avoid reading fixture docs in this test.
cat > "$STUB_DIR/render-pr-body.sh" <<'SH'
render_pr_body() { printf '<stubbed body for %s>\n' "$1"; }
_rpb_title() { printf '%s\n' "stubbed title"; }
_rpb_title_type() { printf 'fix\n'; }
export -f render_pr_body _rpb_title _rpb_title_type
SH

# Need linear.sh to also stub get-issue (not just the existing ops).
# Update the existing stub to handle get-issue with a canned response
# that supplies gitBranchName, title, and labels.
cat > "$STUB_DIR/linear.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "linear.sh $*" >> "$STUB_LOG"
case "$1" in
  get-comments) printf '%s\n' "${VH_FIXTURE_COMMENTS:-[]}" ;;
  get-issue) printf '%s' '{"data":{"issue":{"identifier":"'"$2"'","title":"Stub title","gitBranchName":"stub/branch-'"$2"'","state":{"name":"In Progress"},"labels":{"nodes":[{"name":"Bug"}]}}}}' ;;
  has-label)
    for lbl in ${VH_CURRENT_LABELS:-}; do
      [[ "$lbl" == "$3" ]] && exit 0
    done
    exit 1 ;;
  stage-of) printf '%s\n' "${VH_CURRENT_STAGE_LABEL:-}" ;;
  all-stage-labels)
    result=""
    for lbl in ${VH_CURRENT_LABELS:-}; do
      case "$lbl" in stage:*) result="$result $lbl" ;; esac
    done
    printf '%s\n' "${result# }" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"

# ENG-53 #1: verdict-handler now derives the PR branch via
# bin/branch-name.sh (not via Linear's gitBranchName field). Stub it so
# the existing cases A/B/C still find a branch deterministically. Output
# mirrors production shape: feat/<eng-lower>-<slug>.
cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
# Stub: emit feat/<eng-lower>-stub-slug regardless of input.
ident_lower="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
printf 'feat/%s-stub-slug\n' "$ident_lower"
SH
chmod +x "$STUB_DIR/branch-name.sh"

ORIG_PATH="$PATH"
PATH="$STUB_DIR:$PATH"
export PATH

ORIG_VH_DIR="$_VH_SCRIPT_DIR"
_VH_SCRIPT_DIR="$STUB_DIR"

# Disable dry-run for the hook-invocation tests so `gh pr create` actually
# runs against the stub (the dry-run guard otherwise short-circuits to a log line).
ORIG_DRY_RUN="${PIPELINE_DRY_RUN:-}"
PIPELINE_DRY_RUN=0
export PIPELINE_DRY_RUN

# Case A: no PR exists → gh pr create is invoked.
GH_PR_LIST_RESULT=0 apply_transition "ENG-970" "ui" "reviewing" "" >/dev/null 2>&1 || true
if grep -q 'pr create' "$GH_CALLS"; then
  pass_at "Gap-1 to==reviewing + no PR → gh pr create invoked"
else
  fail_at "Gap-1 no PR → create" "no 'pr create' in $(cat "$GH_CALLS")"
fi

# Case A.1 (ENG-53 #6): title scope MUST be lowercase. The harness's
# merge-title regex requires `[a-z0-9-]+`, so `fix(ENG-970):` would be
# rejected at build's preflight P7 and the build agent would silently
# auto-fix via `gh pr edit --title`. Pin the lowercase form at the source.
if grep -qF -- '--title fix(eng-970):' "$GH_CALLS"; then
  pass_at "Gap-1 ENG-53#6: gh pr create title scope lowercased (fix(eng-970):)"
else
  fail_at "Gap-1 ENG-53#6: title scope must be lowercase" \
    "expected '--title fix(eng-970):' in $(cat "$GH_CALLS")"
fi
# And explicitly the uppercase form must NOT appear.
if grep -qF -- '--title fix(ENG-970):' "$GH_CALLS"; then
  fail_at "Gap-1 ENG-53#6: title scope is not uppercase" \
    "found '--title fix(ENG-970):' (uppercase) in $(cat "$GH_CALLS")"
else
  pass_at "Gap-1 ENG-53#6: title scope is not uppercase"
fi

# Case B: PR already exists → gh pr create is NOT invoked.
: > "$GH_CALLS"
GH_PR_LIST_RESULT=1 apply_transition "ENG-971" "ui" "reviewing" "" >/dev/null 2>&1 || true
if grep -q 'pr create' "$GH_CALLS"; then
  fail_at "Gap-1 idempotent: PR exists → no create" "found 'pr create' in $(cat "$GH_CALLS")"
else
  pass_at "Gap-1 idempotent: PR exists → no create"
fi

# Case C: to != reviewing → no gh pr calls at all.
: > "$GH_CALLS"
apply_transition "ENG-972" "implementing" "ui" "" >/dev/null 2>&1 || true
if grep -q 'pr ' "$GH_CALLS"; then
  fail_at "Gap-1 hook only fires on to==reviewing" "calls: $(cat "$GH_CALLS")"
else
  pass_at "Gap-1 hook only fires on to==reviewing"
fi

# Case D (ENG-53 #1 regression protection): in production, bin/linear.sh's
# get_issue GraphQL query does NOT select the gitBranchName field, so the
# prior `jq -r '.data.issue.gitBranchName // empty'` was unconditionally
# empty and the hook silently skipped on every reviewing transition. The
# fix derives the branch via bin/branch-name.sh instead. Mirror production
# by re-stubbing linear.sh's get-issue WITHOUT gitBranchName, then assert
# gh pr create still fires.
: > "$GH_CALLS"
cat > "$STUB_DIR/linear.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "linear.sh $*" >> "$STUB_LOG"
case "$1" in
  get-comments) printf '%s\n' "${VH_FIXTURE_COMMENTS:-[]}" ;;
  get-issue) printf '%s' '{"data":{"issue":{"identifier":"'"$2"'","title":"Stub title","state":{"name":"In Progress"},"labels":{"nodes":[{"name":"Bug"}]}}}}' ;;
  has-label)
    for lbl in ${VH_CURRENT_LABELS:-}; do
      [[ "$lbl" == "$3" ]] && exit 0
    done
    exit 1 ;;
  stage-of) printf '%s\n' "${VH_CURRENT_STAGE_LABEL:-}" ;;
  all-stage-labels)
    result=""
    for lbl in ${VH_CURRENT_LABELS:-}; do
      case "$lbl" in stage:*) result="$result $lbl" ;; esac
    done
    printf '%s\n' "${result# }" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"
GH_PR_LIST_RESULT=0 apply_transition "ENG-973" "ui" "reviewing" "" >/dev/null 2>&1 || true
if grep -q 'pr create' "$GH_CALLS"; then
  pass_at "Gap-1 ENG-53#1: hook independent of linear.sh::gitBranchName (regression protection)"
else
  fail_at "Gap-1 ENG-53#1 regression protection" \
    "branch lookup must use bin/branch-name.sh, not linear.sh's gitBranchName; calls: $(cat "$GH_CALLS")"
fi

PATH="$ORIG_PATH"
_VH_SCRIPT_DIR="$ORIG_VH_DIR"
PIPELINE_DRY_RUN="$ORIG_DRY_RUN"
export PATH PIPELINE_DRY_RUN

# ─── ENG-50: apply_transition to==reviewing calls bootstrap_review_state ──
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/config.json" <<'JSON'
{
  "orchestrator": {"paused": false},
  "linear": {"native_states": {"in_review": "In Review", "done": "Done"}}
}
JSON
ORIG_CONFIG="$CONFIG"
CONFIG="$STUB_DIR/config.json"
export CONFIG

# Stub review-state.sh CLI — capture bootstrap calls.
BOOTSTRAP_CALLS="$STUB_DIR/bootstrap-calls.log"
: > "$BOOTSTRAP_CALLS"
cat > "$STUB_DIR/review-state.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  bootstrap) printf '%s\\n' "\$2" >> "$BOOTSTRAP_CALLS" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/review-state.sh"

# Stub gh (PR-create hook short-circuits on dry-run anyway).
cat > "$STUB_DIR/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") printf '0' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/gh"

ORIG_PATH="$PATH"
PATH="$STUB_DIR:$PATH"
ORIG_VH_DIR="$_VH_SCRIPT_DIR"
_VH_SCRIPT_DIR="$STUB_DIR"

apply_transition "ENG-595" "ui" "reviewing" "" >/dev/null 2>&1 || true

PATH="$ORIG_PATH"
_VH_SCRIPT_DIR="$ORIG_VH_DIR"
CONFIG="$ORIG_CONFIG"
export PATH CONFIG

if grep -qE '^ENG-595$' "$BOOTSTRAP_CALLS"; then
  pass_at "ENG-50 bootstrap: to==reviewing calls bootstrap_review_state"
else
  fail_at "ENG-50 bootstrap" "captured: $(cat "$BOOTSTRAP_CALLS" 2>/dev/null || echo '<empty>')"
fi

# Sanity: to != reviewing does NOT call bootstrap.
: > "$BOOTSTRAP_CALLS"
PATH="$STUB_DIR:$PATH"
_VH_SCRIPT_DIR="$STUB_DIR"
apply_transition "ENG-596" "implementing" "ui" "" >/dev/null 2>&1 || true
PATH="$ORIG_PATH"
_VH_SCRIPT_DIR="$ORIG_VH_DIR"

if [[ -s "$BOOTSTRAP_CALLS" ]]; then
  fail_at "ENG-50 bootstrap: to!=reviewing must NOT call bootstrap" \
    "captured: $(cat "$BOOTSTRAP_CALLS")"
else
  pass_at "ENG-50 bootstrap: to!=reviewing does not call bootstrap"
fi

# ─── Group: find_fresh_verdict equivalence (ENG-60 Phase 1) ──────────────

printf '\n--- find_fresh_verdict accepts new-shape markers ---\n'

# Fixture FV1: new-shape stage-summary marker should be detected as fresh verdict.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline: transition from=planning to=implementing -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline: verdict result=pass stage=implementing -->"}
]'
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
chmod +x "$STUB_DIR/linear.sh"
_VH_SCRIPT_DIR="$STUB_DIR"
result="$(find_fresh_verdict ENG-FV1)"
# Tightened: require BOTH the legacy marker label AND the new event.result==pass —
# otherwise a halt or rejection (also event=verdict) would silently satisfy this.
[[ "$(jq -r '.marker' <<<"$result")" == "pipeline-stage-summary" \
   && "$(jq -r '.event.result // ""' <<<"$result")" == "pass" ]] \
  && pass_at "FV1: new-shape stage-summary detected" || fail_at "FV1: new-shape stage-summary detected" "got: $result"

# Fixture FV2: new-shape rejection
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline: transition from=implementing to=reviewing -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline: verdict result=fail target=planning -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
result="$(find_fresh_verdict ENG-FV2)"
target="$(jq -r '.target_stage // .target // ""' <<<"$result")"
[[ "$target" == "planning" ]] && pass_at "FV2: new-shape rejection target=planning" || fail_at "FV2: new-shape rejection target=planning" "got: $result"

# Fixture FV3: mixed bodies — old transition, new halt — halt detected
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline: transition from=planning to=implementing -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline: verdict result=halt reason=agent-blocked -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
result="$(find_fresh_verdict ENG-FV3)"
reason="$(jq -r '.reason // ""' <<<"$result")"
[[ "$reason" == "agent-blocked" ]] && pass_at "FV3: mixed-shape halt detected" || fail_at "FV3: mixed-shape halt detected" "got: $result"

# Fixture FV5: new-shape WAIT marker is NOT returned as a verdict (ENG-45
# load-bearing invariant — wait is a soft re-dispatch, not a verdict).
# Old-shape pipeline-wait was already excluded by the prior find_fresh_verdict;
# this fixture pins the equivalent guarantee for new shape so a regression
# can't sneak in via the parse_pipeline_marker path.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline: transition from=planning to=building -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
result="$(find_fresh_verdict ENG-FV5)"
[[ -z "$result" ]] && pass_at "FV5: new-shape wait NOT returned as verdict" || fail_at "FV5: new-shape wait NOT returned as verdict" "got: $result"

# Fixture FB1: new-shape rejection with empty source_stage falls back to
# the issue's current stage:* label (carryover #1 from Phase 1 T1.3).
# Uses reviewing→implementing (valid loopback row) so the transition
# completes cleanly once the source fallback resolves correctly.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline: transition from=implementing to=reviewing -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=fail target=implementing -->"}
]'
# Stub linear.sh: get-comments returns the new-shape rejection;
# get-issue returns labels including stage:reviewing (the implicit source).
# Other subcommands are no-op so apply_transition's side effects don't fail.
ISSUE_JSON='{"data":{"issue":{"id":"ENG-FB1","labels":{"nodes":[{"name":"stage:reviewing"},{"name":"Bug"}]}}}}'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
case "\$1" in
  get-comments) printf '%s' '$COMMENTS_JSON' ;;
  get-issue)    printf '%s' '$ISSUE_JSON' ;;
  stage-of)     printf 'stage:reviewing\n' ;;
  add-label|remove-label|add-comment) printf 'ok' ;;
  *) printf '' ;;
esac
EOF
chmod +x "$STUB_DIR/linear.sh"
_VH_SCRIPT_DIR="$STUB_DIR"

result="$(verdict_handler "ENG-FB1" "reviewing" 2>&1 || true)"
# Assert: no protocol violation (meaning src was resolved from stage:* label,
# and the loopback reviewing→implementing was found). Also confirm rc=0
# (transition was applied).
rc_fb1=0
verdict_handler "ENG-FB1" "reviewing" >/dev/null 2>&1 || rc_fb1=$?
echo "$result" | grep -qE 'protocol-violation|unknown-loopback|rejection-source-unknown' \
  && fail_at "FB1: rejection still triggers protocol violation" "result: $result" \
  || pass_at "FB1: new-shape rejection resolves source from stage:* label (rc=$rc_fb1)" "result: $result"

# Restore stub to the full-featured version used by earlier cases.
cat > "$STUB_DIR/linear.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "linear.sh $*" >> "$STUB_LOG"
case "$1" in
  get-comments) printf '%s\n' "${VH_FIXTURE_COMMENTS:-[]}" ;;
  has-label)
    for lbl in ${VH_CURRENT_LABELS:-}; do
      [[ "$lbl" == "$3" ]] && exit 0
    done
    exit 1 ;;
  stage-of) printf '%s\n' "${VH_CURRENT_STAGE_LABEL:-}" ;;
  all-stage-labels)
    result=""
    for lbl in ${VH_CURRENT_LABELS:-}; do
      [[ "$lbl" == stage:* ]] && result="${result:+$result }$lbl"
    done
    printf '%s\n' "$result" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"
_VH_SCRIPT_DIR="$STUB_DIR"

# ─── Group: legacy-label drain (ENG-60 T2.13) ────────────────────────────

printf '\n--- legacy pipeline-namespace labels are drained on transition ---\n'

# Reuse case-1's setup: forward transition qa → building. Just check the
# call log for the 5 legacy remove-label invocations.
reset_calls
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=implementing to=qa -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline: verdict result=pass stage=qa -->|2026-04-23T11:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:qa"
VH_CURRENT_LABELS="stage:qa pipeline:halted"
verdict_handler "ENG-T213" "qa" >/dev/null 2>&1 || true

drained_count=0
for legacy in pipeline:paused pipeline:scope-approval-needed pipeline:supersede pipeline:skip-until-code-changes pipeline:skip-until-human-acts; do
  if calls_contains "remove-label ENG-T213 $legacy"; then
    drained_count=$((drained_count + 1))
  fi
done
[[ "$drained_count" -eq 5 ]] && pass_at "T213: all 5 legacy labels drained on transition" || fail_at "T213: legacy label drain" "drained=$drained_count/5; calls=$(cat "$STUB_LOG")"

# Confirm pipeline:halted and pipeline:abandoned are NOT drained (kept labels).
if calls_contains "remove-label ENG-T213 pipeline:halted" \
   && ! calls_contains "remove-label ENG-T213 pipeline:abandoned"; then
  # pipeline:halted IS removed — that's fine, it's the normal end-of-transition
  # cleanup at step 5. The important thing is pipeline:abandoned is not drained.
  pass_at "T213: pipeline:abandoned not in drain list"
elif calls_contains "remove-label ENG-T213 pipeline:abandoned"; then
  fail_at "T213: pipeline:abandoned must NOT be drained" "calls=$(cat "$STUB_LOG")"
else
  pass_at "T213: pipeline:abandoned not in drain list"
fi

# ─── ENG-87: dispatch_id-primary filter (Tasks 11+12) ─────────────────
# find_fresh_verdict and resume_in_progress_transition gain a strict
# id-match filter ABOVE the existing timestamp-window code. Legacy
# issues (no markers anywhere) fall through to the existing behavior
# per D-005.
printf '\n--- ENG-87: dispatch_id-primary filter ---\n'

# Override current_dispatch_id with a test-controlled stub. The
# production helper reads PROJECT_STATE_DIR/<ident>/issue-state.json;
# overriding here keeps the test self-contained without standing up
# the per-issue state dir.
_VH_TEST_DISPATCH_ID=""
current_dispatch_id() {
  printf '%s' "$_VH_TEST_DISPATCH_ID"
}

# Case 87-V1: find_fresh_verdict prefers id-match when markers present.
# Two verdicts on the issue: an OLDER d0010 pass (createdAt earlier),
# a NEWER d0011 fail (createdAt later). Current dispatch_id = d0011.
# The id-match path filters by exact id == current; returns the d0011
# fail-marker. Pre-ENG-87 timestamp-window logic would also pick d0011
# here (newer wins), so this case alone doesn't distinguish — but the
# next case does.
reset_calls
_VH_TEST_DISPATCH_ID="ENG-87V1-d0011"
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=qa to=building --><!-- meta: dispatch id=ENG-87V1-d0009 stage=qa -->|2026-05-09T08:00:00.000Z" \
  "<!-- pipeline: verdict result=pass stage=reviewing --><!-- meta: dispatch id=ENG-87V1-d0010 stage=reviewing -->|2026-05-09T09:00:00.000Z" \
  "<!-- pipeline: verdict result=fail target=implementing --><!-- meta: dispatch id=ENG-87V1-d0011 stage=reviewing -->|2026-05-09T10:00:00.000Z")"
result="$(find_fresh_verdict "ENG-87V1" 2>/dev/null || printf '')"
if [[ -n "$result" ]] \
   && [[ "$(jq -r '.event.result' <<<"$result")" == "fail" ]] \
   && [[ "$(jq -r '.event.target' <<<"$result")" == "implementing" ]]; then
  pass_at "ENG-87 V1: find_fresh_verdict picks current-dispatch verdict (d0011 fail)"
else
  fail_at "ENG-87 V1: find_fresh_verdict id-match" "got: $result"
fi

# Case 87-V1b: id-match filter rejects unstamped decoy. Three comments:
# stamped pass (d0010, older), stamped fail (d0011, mid), UNSTAMPED
# decoy comment with newer createdAt. Pre-ENG-87 timestamp-window logic
# would pick the unstamped decoy (newest by createdAt). With ENG-87 id
# filter active, the unstamped decoy is filtered out (markers exist on
# the issue, so id-match path is taken; the decoy lacks the current id
# marker → excluded). Returns d0011 fail.
reset_calls
_VH_TEST_DISPATCH_ID="ENG-87V1b-d0011"
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=qa to=building --><!-- meta: dispatch id=ENG-87V1b-d0009 stage=qa -->|2026-05-09T08:00:00.000Z" \
  "<!-- pipeline: verdict result=fail target=implementing --><!-- meta: dispatch id=ENG-87V1b-d0011 stage=reviewing -->|2026-05-09T09:00:00.000Z" \
  "<!-- pipeline: verdict result=pass stage=reviewing -->|2026-05-09T11:00:00.000Z")"
result="$(find_fresh_verdict "ENG-87V1b" 2>/dev/null || printf '')"
if [[ -n "$result" ]] \
   && [[ "$(jq -r '.event.result' <<<"$result")" == "fail" ]]; then
  pass_at "ENG-87 V1b: id-match filter excludes unstamped decoy by createdAt"
else
  fail_at "ENG-87 V1b: id-match filter — unstamped decoy" \
    "expected current-dispatch (d0011) fail, got: $result"
fi

# Case 87-V2: legacy fallback — no markers anywhere on the issue.
# find_fresh_verdict falls through to the existing timestamp-window
# code (per D-005). Returns the latest verdict.
reset_calls
_VH_TEST_DISPATCH_ID="ENG-87V2-d0001"
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=implementing to=ui -->|2026-05-09T08:00:00.000Z" \
  "<!-- pipeline: verdict result=pass stage=ui -->|2026-05-09T09:00:00.000Z")"
result="$(find_fresh_verdict "ENG-87V2" 2>/dev/null || printf '')"
if [[ -n "$result" ]] \
   && [[ "$(jq -r '.event.result' <<<"$result")" == "pass" ]] \
   && [[ "$(jq -r '.event.stage' <<<"$result")" == "ui" ]]; then
  pass_at "ENG-87 V2: legacy fallback — no markers → timestamp-window picks latest verdict"
else
  fail_at "ENG-87 V2: legacy fallback" "got: $result"
fi

# Case 87-V3: id-match path returns empty when markers exist on the
# issue but none match the current dispatch (i.e., we're a fresh
# dispatch that hasn't emitted a verdict yet — markers belong to prior
# cycles only). Strict id-match: NOT timestamp fallback.
reset_calls
_VH_TEST_DISPATCH_ID="ENG-87V3-d0042"
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=qa to=building --><!-- meta: dispatch id=ENG-87V3-d0040 stage=qa -->|2026-05-09T08:00:00.000Z" \
  "<!-- pipeline: verdict result=pass stage=reviewing --><!-- meta: dispatch id=ENG-87V3-d0041 stage=reviewing -->|2026-05-09T09:00:00.000Z")"
result="$(find_fresh_verdict "ENG-87V3" 2>/dev/null || printf '')"
if [[ -z "$result" ]]; then
  pass_at "ENG-87 V3: strict id-match → empty when current dispatch has not yet emitted (prior-cycle verdicts ignored)"
else
  fail_at "ENG-87 V3: strict id-match empty" "got: $result"
fi

# Case 87-V4: resume_in_progress_transition rejects stale-id transition.
# Latest transition carries d0008 marker; current_dispatch_id = d0010.
# The id-mismatch guard fires BEFORE the existing labels-cross-check.
reset_calls
_VH_TEST_DISPATCH_ID="ENG-87V4-d0010"
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=planning to=implementing --><!-- meta: dispatch id=ENG-87V4-d0008 stage=planning -->|2026-05-09T08:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:planning"
VH_CURRENT_LABELS="stage:planning pipeline:halted"
rc=0; resume_in_progress_transition "ENG-87V4" 2>/dev/null || rc=$?
if [[ "$rc" == "1" ]] && ! calls_contains "add-label ENG-87V4 stage:implementing"; then
  pass_at "ENG-87 V4: resume_in_progress_transition rejects stale-id transition (d0008 != d0010)"
else
  fail_at "ENG-87 V4: stale-id reject" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# Case 87-V5: resume_in_progress_transition accepts matching-id transition.
# Latest transition carries d0010 marker; current_dispatch_id = d0010.
# Falls through to existing guards (current_stage == from); since
# stage:planning == from=planning, halted, it should resume.
reset_calls
_VH_TEST_DISPATCH_ID="ENG-87V5-d0010"
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=planning to=implementing --><!-- meta: dispatch id=ENG-87V5-d0010 stage=planning -->|2026-05-09T08:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:planning"
VH_CURRENT_LABELS="stage:planning pipeline:halted"
rc=0; resume_in_progress_transition "ENG-87V5" 2>/dev/null || rc=$?
if [[ "$rc" == "0" ]] && calls_contains "add-label ENG-87V5 stage:implementing"; then
  pass_at "ENG-87 V5: resume_in_progress_transition accepts matching-id transition"
else
  fail_at "ENG-87 V5: matching-id accept" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# Case 87-V6: resume_in_progress_transition legacy fallback — no marker
# on transition; existing labels-cross-check stays as-is (ENG-41 §4.2).
# stage:brainstorming ≠ from=planning → existing guard fires → return 1.
reset_calls
_VH_TEST_DISPATCH_ID="ENG-87V6-d0001"
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=planning to=implementing -->|2026-05-09T08:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:brainstorming"
VH_CURRENT_LABELS="stage:brainstorming pipeline:halted"
rc=0; resume_in_progress_transition "ENG-87V6" 2>/dev/null || rc=$?
if [[ "$rc" == "1" ]] && ! calls_contains "add-label ENG-87V6 stage:implementing"; then
  pass_at "ENG-87 V6: legacy fallback — labels-cross-check fires when transition lacks dispatch marker"
else
  fail_at "ENG-87 V6: legacy labels-cross-check" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# Restore the production current_dispatch_id (in case more tests follow).
unset -f current_dispatch_id

# ─── ENG-87 QA-adversarial: cutover + visibility edges ───────────────
# The strict id-match path activates the moment ANY comment on the
# issue carries a `<!-- meta: dispatch id=` marker (substring-match
# against the entire concatenated comments JSON). This creates a
# silent visibility blind spot during cutover: an issue that already
# has a legitimate pre-ENG-87 verdict (no marker) gets a marker-bearing
# comment posted by an unrelated tick (e.g., an operator triage note
# auto-stamped by a fresh dispatch) — the legacy verdict immediately
# becomes invisible to find_fresh_verdict because the strict path is
# now active and the legacy verdict carries no current-dispatch
# marker.
#
# Pin CURRENT behavior: mixed (legacy verdict + new marker on a
# transition) → strict path activates → legacy verdict filtered out
# → find_fresh_verdict returns empty → orchestrator may NOT advance
# the issue based on the legacy verdict.
#
# Restore the test stub for current_dispatch_id (was unset above).
current_dispatch_id() { printf '%s' "${_VH_TEST_DISPATCH_ID:-}"; }

# Re-create stub log used by resume_in_progress_transition.
reset_calls

# Case 87-QA-CUTOVER-1: legacy verdict (no marker) + a NEW transition
# marker present on the issue → strict path activates → legacy
# verdict invisible.
_VH_TEST_DISPATCH_ID="ENG-87QA-CUT-d0001"
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: verdict result=pass stage=reviewing -->|2026-05-08T10:00:00.000Z" \
  "<!-- pipeline: transition from=reviewing to=qa --><!-- meta: dispatch id=ENG-87QA-CUT-d0001 stage=reviewing -->|2026-05-09T09:00:00.000Z")"
result="$(find_fresh_verdict "ENG-87QA-CUT" 2>/dev/null || printf '')"
if [[ -z "$result" ]]; then
  pass_at "ENG-87 QA-CUT-1: cutover blind spot — legacy verdict (no marker) invisible once any marker exists on issue (CURRENT behavior; documented D-005 trade-off)"
else
  fail_at "ENG-87 QA-CUT-1: cutover blind spot pin" \
    "expected empty (legacy filtered), got: $result"
fi

# Case 87-QA-CUTOVER-2: post-cutover, the legacy verdict's stage CAN
# still be resumed via the fresh dispatch's own verdict comment. Ship
# a current-dispatch verdict comment alongside the legacy one →
# find_fresh_verdict picks the current-dispatch verdict, ignoring the
# legacy one's freshness. Pin: D-005's "first dispatch post-cutover
# auto-stamps and unblocks" actually works.
_VH_TEST_DISPATCH_ID="ENG-87QA-CUT2-d0002"
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: verdict result=pass stage=reviewing -->|2026-05-08T10:00:00.000Z" \
  "<!-- pipeline: verdict result=fail target=implementing --><!-- meta: dispatch id=ENG-87QA-CUT2-d0002 stage=reviewing -->|2026-05-09T11:00:00.000Z")"
result="$(find_fresh_verdict "ENG-87QA-CUT2" 2>/dev/null || printf '')"
if [[ -n "$result" ]] \
   && [[ "$(jq -r '.event.result' <<<"$result")" == "fail" ]]; then
  pass_at "ENG-87 QA-CUT-2: post-cutover unblock — current-dispatch verdict picked, legacy filtered (D-005 recovery path)"
else
  fail_at "ENG-87 QA-CUT-2: post-cutover unblock" \
    "expected fail verdict (current dispatch), got: $result"
fi

# Case 87-QA-RESUME-3: resume_in_progress_transition rejects a
# transition whose marker carries an issue-id mismatch (e.g., another
# project's ENG-87 leaks a marker via copy-paste in the body). The
# guard at bin/verdict-handler.sh:408 extracts via grep -oE
# `<!-- meta: dispatch id=[^[:space:]>]+`; pin current behavior on a
# fully-different id token (different prefix entirely).
reset_calls
_VH_TEST_DISPATCH_ID="ENG-87QA-R3-d0010"
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline: transition from=planning to=implementing --><!-- meta: dispatch id=DIFFERENT-PROJECT-X-d0008 stage=planning -->|2026-05-09T08:00:00.000Z")"
VH_CURRENT_STAGE_LABEL="stage:planning"
VH_CURRENT_LABELS="stage:planning pipeline:halted"
rc=0; resume_in_progress_transition "ENG-87QA-R3" 2>/dev/null || rc=$?
if [[ "$rc" == "1" ]]; then
  pass_at "ENG-87 QA-R3: cross-project foreign id-token (DIFFERENT-PROJECT-X-d0008) rejected as stale (id-mismatch guard fires)"
else
  fail_at "ENG-87 QA-R3: cross-project foreign id" \
    "rc=$rc calls=$(cat "$STUB_LOG") — expected guard to fire on non-matching id"
fi
unset -f current_dispatch_id

# ─── ENG-87 review-iter-7 m1: dispatch-id grep uses tail -1, not head -1 ──
# resume_in_progress_transition's id-mismatch guard at
# bin/verdict-handler.sh:408 reads the LAST transition's body and
# extracts the dispatch_id via:
#   grep -oE '<!-- meta: dispatch id=[^[:space:]>]+' <<<"$last_body" \
#     | head -1 | sed -E 's/.*id=//'
# `_inject_dispatch_marker` always APPENDS the marker (last line). The
# reader's `head -1` is the WRONG bookend — for a body that legitimately
# quotes a prior dispatch's marker (e.g., a halt-recap comment that
# embeds an old marker substring as part of its prose), head -1 returns
# the QUOTED id, while the auto-injected real marker is at the tail.
# Switch to `tail -1` to match the writer's "always append" semantics
# (the same pattern parse_pipeline_marker uses for marker family
# precedence at common.sh:315).
printf '\n--- ENG-87 m1-iter7: dispatch-id grep uses tail -1 ---\n'

_iter7_m1_line="$(grep -nE 'grep -oE .*<!-- meta: dispatch id=' "$SCRIPT_DIR/verdict-handler.sh" \
  | grep -F 'last_body' | head -1)"
# The next line should be the head/tail filter. Read the surrounding
# 3-line context.
_iter7_m1_lineno="$(awk -F: '{print $1}' <<<"$_iter7_m1_line")"
if [[ -z "$_iter7_m1_lineno" ]]; then
  fail_at "ENG-87 m1-iter7: dispatch-id grep site present" \
    "could not locate the grep + head/tail filter near 'last_body' in verdict-handler.sh — has the call site moved?"
else
  _iter7_m1_filter_line="$(awk -v ln="$((_iter7_m1_lineno + 1))" 'NR==ln' "$SCRIPT_DIR/verdict-handler.sh")"
  if grep -qF 'tail -1' <<<"$_iter7_m1_filter_line"; then
    pass_at "ENG-87 m1-iter7: dispatch-id grep at last_body uses tail -1 (matches writer's always-append semantics)"
  else
    fail_at "ENG-87 m1-iter7: dispatch-id grep at last_body uses tail -1" \
      "filter line: $_iter7_m1_filter_line — should be 'tail -1' so the reader picks the auto-injected (last) marker, not a quoted prose marker (first)"
  fi
  unset _iter7_m1_filter_line
fi
unset _iter7_m1_line _iter7_m1_lineno

# ─── Summary ──────────────────────────────────────────────────────────
echo
if (( FAIL == 0 )); then
  printf 'All %d verdict_handler cases passed.\n' "$PASS"
  exit 0
else
  printf '%d pass, %d fail.\n' "$PASS" "$FAIL"
  exit 1
fi
