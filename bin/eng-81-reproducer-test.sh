#!/usr/bin/env bash
# ENG-154 — canonical regression fixture for the ENG-81 incident timeline.
#
# Incident summary (2026-05-14, all UTC):
#   15:54:04  agent self-claim PASS  (lane=agent, body opens
#             `<!-- pipeline: verdict result=pass stage=implementing -->`)
#   15:54:26  orchestrator counter bump
#             (`<!-- meta: metric name=implement_rejection -->
#             Counter bumped by guards.sh.`)
#   15:54:32  orchestrator halt verdict
#             (`<!-- pipeline: verdict result=halt reason=agent-blocked --> …`)
#             — in the historical incident this body was dedup-updated
#             onto a 12:24:00 halt slot via add-or-update-comment, pinning
#             createdAt hours upstream in the chronological feed.
#
# Dependency tickets whose acceptance criteria this fixture enforces:
#   ENG-150 — append-only ledger (add-or-update-comment removed)
#   ENG-151 — human-readable header line on every body
#   ENG-152 — agent vs orchestrator verdict marker split
#             (`stage-completion-claim` + `author=orchestrator`)
#   ENG-153 — `guards.sh::bump --reason` + threshold disclosure
#
# As each dependency ticket lands, its `_dep_<N>_landed` shape detector
# below will start returning 0 and the corresponding assertion un-skips.
# Do NOT remove the skip arm — leave it as the dependency-detector
# contract: when a sibling refactor silently reverts the fix, the
# detector flips back to 1 and the fixture marks the assertion as
# SKIP-with-reason rather than reporting a green test against a
# regressed code path.

set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

jq -n '{
  labels: {
    "stage:implementing": "uuid-stage-implementing",
    "pipeline:halted":    "uuid-pipeline-halted"
  },
  states: {}
}' > "$TARGET_REPO/.pipeline-config/schemas/linear-ids.json"

HARNESS_STATE_DIR="$_TEST_STUB_DIR/state"
export HARNESS_STATE_DIR
PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
export PROJECT_STATE_DIR
mkdir -p "$PROJECT_STATE_DIR/metrics"
: > "$PROJECT_STATE_DIR/metrics/events.jsonl"

# ─── Source linear.sh ────────────────────────────────────────────────────
# shellcheck source=linear.sh
source "$SCRIPT_DIR_REAL/linear.sh"

# Override SCRIPT_DIR inside linear.sh to point to our stub dir so any
# `bash "$SCRIPT_DIR/..."` calls inside the sourced functions hit stubs.
# The dependency-shape detectors below intentionally read from
# $SCRIPT_DIR_REAL (the on-disk bin/ dir), NOT from $SCRIPT_DIR.
SCRIPT_DIR="$_TEST_STUB_DIR"

# ─── Assertion helpers (mirror bin/linear-test.sh:91-92) ────────────────
PASS=0; FAIL=0; SKIP=0
fail_at() { printf '  FAIL %s\n      %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }
pass_at() { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }
skip_at() { printf '  SKIP %s (%s)\n' "$1" "$2"; SKIP=$((SKIP+1)); }

# ─── Dependency-shape detectors (ENG-150..153) ──────────────────────────
# Each returns 0 when the dependency has shipped, 1 otherwise. Consumed
# as booleans by `if _dep_15N_landed; then ...; fi`. Each detector
# reads from $SCRIPT_DIR_REAL (the live on-disk bin/ directory), so the
# detector flips automatically the next time the test runs after the
# sibling ticket merges.

# ENG-150 lands when `add-or-update-comment` is no longer a subcommand
# in main(). Today the case arm at bin/linear.sh:768 reads
#   `add-or-update-comment) add_or_update_comment "$@" ;;`
_dep_150_landed() {
  ! grep -qE '^\s*add-or-update-comment\)' "$SCRIPT_DIR_REAL/linear.sh"
}

# ENG-151 lands when bin/linear.sh defines a `_render_event_header` helper.
_dep_151_landed() {
  grep -qE '^_render_event_header\(\)' "$SCRIPT_DIR_REAL/linear.sh"
}

# ENG-152 lands when bin/pipeline-events.json registers a
# `stage-completion-claim` event (the agent/orchestrator verdict split).
_dep_152_landed() {
  jq -e '.events | has("stage-completion-claim")' \
    "$SCRIPT_DIR_REAL/pipeline-events.json" >/dev/null 2>&1
}

# ENG-153 lands when guards.sh::bump accepts --reason as a case arm.
# Structural grep targets `--reason)` as a bash case arm (indented); does
# NOT match docstrings or prose comments that merely mention "--reason".
_dep_153_landed() {
  grep -qE '^\s+--reason\)' "$SCRIPT_DIR_REAL/guards.sh"
}

# ─── Fixture comment store + linear_query override ──────────────────────
# Place the capture file INSIDE $_TEST_TARGET_DIR so the existing EXIT
# trap cleans it up via _test_safe_rm; a `mktemp -t` path lives at
# $TMPDIR outside the trap's reach.
_store_file="$_TEST_TARGET_DIR/eng-81-store.json"
printf '[]\n' > "$_store_file"

# Running tally of commentUpdate invocations across ALL test cases.
# Consulted by C-150 to prove the in-place-rewrite path was not triggered
# when ENG-150 ships.
_COMMENT_UPDATE_COUNT=0

# Override _resolve_issue_uuid post-source so add_comment skips its real
# Linear lookup and just returns a mock UUID.
_resolve_issue_uuid() { printf 'uuid-eng-81'; }

# Override linear_query post-source. Pattern-match on the GraphQL string:
#   - commentCreate: append a new node (id, body, createdAt) to the store
#     using the test-fixture-controlled $_FIXTURE_INJECT_CREATED_AT.
#   - commentUpdate: rewrite the matching node's body in place (the
#     pre-ENG-150 add-or-update-comment shape; never invoked by this
#     fixture's timeline, but defined so an accidental reintroduction
#     of the in-place rewrite path is observable in the store).
#   - comments(first: …): return the store contents in the canonical
#     {data:{issue:{comments:{nodes:[…]}}}} shape; add_comment uses this
#     for its last-10 dedup hash check (skipped for `<!-- pipeline: …`
#     marker bodies per bin/linear.sh:528).
#   - else: return a mocked issue payload so any incidental get_issue
#     call still succeeds.
linear_query() {
  local query="$1" variables="${2:-{\}}"
  if [[ "$query" =~ commentCreate ]]; then
    local body ts seq
    body="$(jq -r '.body' <<<"$variables")"
    ts="${_FIXTURE_INJECT_CREATED_AT:-2026-05-14T15:54:00Z}"
    seq="$(jq 'length' "$_store_file")"
    jq --arg b "$body" --arg t "$ts" --arg id "cmt-$seq" \
      '. + [{id:$id, body:$b, createdAt:$t}]' "$_store_file" \
      > "$_store_file.tmp" && mv "$_store_file.tmp" "$_store_file"
    printf '{"data":{"commentCreate":{"success":true}}}\n'
    return 0
  fi
  if [[ "$query" =~ commentUpdate ]]; then
    local id new_body
    id="$(jq -r '.id' <<<"$variables")"
    new_body="$(jq -r '.body' <<<"$variables")"
    jq --arg id "$id" --arg b "$new_body" \
      'map(if .id == $id then .body = $b else . end)' \
      "$_store_file" > "$_store_file.tmp" && mv "$_store_file.tmp" "$_store_file"
    _COMMENT_UPDATE_COUNT=$((_COMMENT_UPDATE_COUNT + 1))
    printf '{"data":{"commentUpdate":{"success":true}}}\n'
    return 0
  fi
  if [[ "$query" =~ comments\(first: ]]; then
    local arr
    arr="$(cat "$_store_file")"
    jq -cn --argjson nodes "$arr" '{data:{issue:{comments:{nodes:$nodes}}}}'
    return 0
  fi
  printf '{"data":{"issue":{"id":"uuid-eng-81","identifier":"ENG-81","title":"mock","state":{"id":"s","name":"In Progress"},"labels":{"nodes":[]},"url":"","createdAt":"","updatedAt":""}}}\n'
}

# Flip out of dry-run so add_comment's mutation path is reachable.
export PIPELINE_DRY_RUN=0

# ─── Replay the 15:54 timeline ──────────────────────────────────────────
export PIPELINE_DISPATCH_ID="ENG-81-d0007"
export PIPELINE_STAGE="implementing"

# Diagnostic: surface detector verdict at runtime so a reader of the
# test output knows which gates are open. Printed BEFORE the
# timeline-replay so an early failure is still attributable.
printf '\n--- ENG-150 (landed=%s) ---\n' "$(_dep_150_landed && echo yes || echo no)"
printf -- '--- ENG-151 (landed=%s) ---\n' "$(_dep_151_landed && echo yes || echo no)"
printf -- '--- ENG-152 (landed=%s) ---\n' "$(_dep_152_landed && echo yes || echo no)"
printf -- '--- ENG-153 (landed=%s) ---\n\n' "$(_dep_153_landed && echo yes || echo no)"

# Comment 1: agent self-claim (PASS) at 15:54:04Z.
PIPELINE_WRITER=agent _FIXTURE_INJECT_CREATED_AT="2026-05-14T15:54:04Z" \
  add_comment "ENG-81" --body \
    "<!-- pipeline: verdict result=pass stage=implementing -->" >/dev/null 2>&1

# Comment 2: orchestrator counter bump at 15:54:26Z (current shape;
# ENG-153 will widen this body to include Reason + Trips at).
PIPELINE_WRITER=orchestrator _FIXTURE_INJECT_CREATED_AT="2026-05-14T15:54:26Z" \
  add_comment "ENG-81" --body \
    "<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh." \
  >/dev/null 2>&1

# Comment 3: orchestrator halt verdict at 15:54:32Z. In the historical
# incident this body was dedup-updated onto the morning's 12:24:00 halt
# slot via add-or-update-comment; the fixture deliberately uses
# add-comment here so under CURRENT code the result is three append-only
# comments. (Once ENG-150 lands, add-or-update-comment is removed
# entirely; the fixture already reflects that target state.)
PIPELINE_WRITER=orchestrator _FIXTURE_INJECT_CREATED_AT="2026-05-14T15:54:32Z" \
  add_comment "ENG-81" --body \
    $'<!-- pipeline: verdict result=halt reason=agent-blocked --> SEVERE scope violation on learned-rules/harness/project-profile.md.\nRecorded at: 2026-05-14T15:54:32Z' \
  >/dev/null 2>&1

# ─── R-1: Always-on invariants (today's green path) ────────────────────

# C-001: store contains exactly three append-only comments — no in-place
# rewrite leaked through commentUpdate.
count="$(jq 'length' "$_store_file")"
if [[ "$count" == "3" ]]; then
  pass_at "C-001 store contains exactly 3 comments"
else
  fail_at "C-001 store contains exactly 3 comments" "got $count"
fi

# C-002: createdAt order matches dispatch order. Lexicographic compare is
# well-defined on ISO-8601 Z strings.
ts_ordered="$(jq -r '[.[].createdAt] | (sort == .) | tostring' "$_store_file")"
if [[ "$ts_ordered" == "true" ]]; then
  pass_at "C-002 createdAt ascending order matches dispatch order"
else
  fail_at "C-002 createdAt ascending order matches dispatch order" \
    "store=$(cat "$_store_file")"
fi

# C-003: every body carries the ENG-110 dispatch marker. Trailing space
# in the contains() probe avoids prefix-collision (e.g. id=ENG-81-d100
# vs id=ENG-81-d10), mirroring _inject_dispatch_marker's own idempotency
# check at bin/linear.sh:71.
missing="$(jq -r '[.[] | select(.body | contains("<!-- meta: dispatch id=ENG-81-d0007 ") | not)] | length' "$_store_file")"
if [[ "$missing" == "0" ]]; then
  pass_at "C-003 every body carries <!-- meta: dispatch id=ENG-81-d0007 stage=... -->"
else
  fail_at "C-003 every body carries dispatch marker" \
    "missing=$missing store=$(cat "$_store_file")"
fi

# C-003b: OFF state — PIPELINE_DISPATCH_ID="" → dispatch marker absent.
# Tests the chokepoint's guard; complements C-003's ON-state check.
_r1_len="$(jq 'length' "$_store_file")"
PIPELINE_DISPATCH_ID="" PIPELINE_WRITER=orchestrator PIPELINE_STAGE=implementing \
  add_comment "ENG-81" --body \
    "<!-- meta: metric name=implement_rejection --> Off-state probe." \
  >/dev/null 2>&1
_off_body="$(jq -r '.[-1].body' "$_store_file")"
if ! grep -qF '<!-- meta: dispatch id=' <<<"$_off_body"; then
  pass_at "C-003b PIPELINE_DISPATCH_ID empty: dispatch marker absent from body"
else
  fail_at "C-003b dispatch marker absent when PIPELINE_DISPATCH_ID is empty" \
    "body=$_off_body"
fi
# Restore store to R-1 state (remove the off-state probe entry).
jq ".[0:$_r1_len]" "$_store_file" > "$_store_file.tmp" && mv "$_store_file.tmp" "$_store_file"

# ─── R-2: pre-seeded prior halt (ENG-81 bug observation) ────────────────
#
# D-003 mandates two test cases: R-1 (clean store) and R-2 (pre-seeded).
# R-2 exercises the historical ENG-81 failure mode: add_or_update_comment
# rewrites the halt comment in-place (commentUpdate), preserving the
# pre-seed's createdAt from 3h earlier. Today this is the BUG — the
# operator's top-down scan sees the halt pinned hours upstream.
# When ENG-150 ships (removes add_or_update_comment), call-3 is skipped
# and C-R2 is marked SKIP (bug trigger moot).

printf '\n--- ENG-154 R-2: pre-seeded prior halt (bug observation) ---\n'
printf -- '--- ENG-150 (landed=%s) ---\n\n' "$(_dep_150_landed && echo yes || echo no)"

# Reset to clean slate for R-2.
printf '[]\n' > "$_store_file"

# Pre-seed a halt comment timestamped 3h before the incident timeline.
# Written directly to the store (bypassing add_comment) to inject a
# controlled createdAt. Body carries the sig marker so add_or_update_comment
# finds it via the dedup-key lookup at bin/linear.sh:624.
jq \
  --arg id "cmt-preseed" \
  --arg ts "2026-05-14T12:24:00Z" \
  --arg b $'SEVERE — scope violation (morning halt).\n\n<!-- meta: dedup key=halt/implementing/ENG-81 -->' \
  '. + [{id:$id, body:$b, createdAt:$ts}]' \
  "$_store_file" > "$_store_file.tmp" && mv "$_store_file.tmp" "$_store_file"

# Restore PIPELINE_DISPATCH_ID to the timeline value (C-003b set it to "").
export PIPELINE_DISPATCH_ID="ENG-81-d0007"

# Calls 1 and 2: append-only, same as R-1.
PIPELINE_WRITER=agent _FIXTURE_INJECT_CREATED_AT="2026-05-14T15:54:04Z" \
  add_comment "ENG-81" --body \
    "<!-- pipeline: verdict result=pass stage=implementing -->" >/dev/null 2>&1
PIPELINE_WRITER=orchestrator _FIXTURE_INJECT_CREATED_AT="2026-05-14T15:54:26Z" \
  add_comment "ENG-81" --body \
    "<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh." \
  >/dev/null 2>&1

# Call 3: add_or_update_comment triggers the historical bug — in-place
# rewrite against the preseed's id, preserving createdAt=12:24:00Z.
# Skipped when ENG-150 ships (add_or_update_comment removed entirely).
if ! _dep_150_landed; then
  PIPELINE_WRITER=orchestrator _FIXTURE_INJECT_CREATED_AT="2026-05-14T15:54:32Z" \
    add_or_update_comment "halt/implementing/ENG-81" "ENG-81" --body \
      $'<!-- pipeline: verdict result=halt reason=agent-blocked --> SEVERE scope violation.\nRecorded at: 2026-05-14T15:54:32Z' \
    >/dev/null 2>&1
fi

# C-R2: assert the bug is observable today — the preseed entry's createdAt
# is preserved across the in-place halt rewrite (pinned 3h upstream).
if _dep_150_landed; then
  skip_at "C-R2 R-2 bug observation" \
    "ENG-150 landed: add_or_update_comment removed; in-place rewrite path moot"
else
  _r2_preseed_ts="$(jq -r '.[0].createdAt' "$_store_file")"
  _r2_preseed_body="$(jq -r '.[0].body' "$_store_file")"
  if [[ "$_r2_preseed_ts" == "2026-05-14T12:24:00Z" ]] \
     && grep -qF 'result=halt' <<<"$_r2_preseed_body"; then
    pass_at "C-R2 R-2 bug-observation: add_or_update_comment preserved pre-seed createdAt across in-place halt rewrite"
  else
    fail_at "C-R2 R-2 preseed createdAt" \
      "got=$_r2_preseed_ts expected=2026-05-14T12:24:00Z body=$_r2_preseed_body"
  fi
fi

# ─── Dependency-gated invariants ────────────────────────────────────────

# ENG-150 (append-only ledger / no in-place rewrite). When ENG-150 ships
# and add_or_update_comment is removed, the entire R-1+R-2 timeline must
# produce zero commentUpdate calls. _COMMENT_UPDATE_COUNT was incremented
# by the stub's commentUpdate arm on each in-place rewrite; R-2's call-3
# is skipped when dep_150_landed, so the count stays 0.
if _dep_150_landed; then
  if [[ "$_COMMENT_UPDATE_COUNT" == "0" ]]; then
    pass_at "C-150 ENG-150 landed: 0 commentUpdate calls — append-only ledger confirmed"
  else
    fail_at "C-150 commentUpdate count" \
      "expected 0, got $_COMMENT_UPDATE_COUNT (add_or_update_comment still active)"
  fi
else
  skip_at "C-150 ENG-150 not yet landed" \
    "add-or-update-comment still present at bin/linear.sh::main"
fi

# ENG-151 (human-readable header line). Each body opens with the
# canonical `[ENG-81 · implementing · ENG-81-d0007 · <iso-ts> · <actor>]`.
if _dep_151_landed; then
  header_re='\[ENG-81 · implementing · ENG-81-d0007 · 2026-05-14T15:54:[0-9]{2}Z · (agent|orchestrator)\]'
  bad="$(jq -r --arg re "$header_re" \
    '[.[] | select(.body | test($re; "x") | not)] | length' "$_store_file")"
  if [[ "$bad" == "0" ]]; then
    pass_at "C-151 every body opens with canonical header line"
  else
    fail_at "C-151 header line" "$bad of 3 bodies missing header"
  fi
else
  skip_at "C-151 header line not yet wired" \
    "ENG-151 in flight at stage:implementing"
fi

# ENG-152 (agent/orchestrator verdict-split). Agent self-claim carries
# `pipeline: stage-completion-claim`; orchestrator halt verdict carries
# `pipeline: verdict ... author=orchestrator`.
if _dep_152_landed; then
  claim_ok="$(jq -r '.[0].body | test("pipeline: stage-completion-claim") | tostring' "$_store_file")"
  halt_ok="$(jq -r '.[2].body | test("pipeline: verdict result=halt.*author=orchestrator") | tostring' "$_store_file")"
  if [[ "$claim_ok" == "true" && "$halt_ok" == "true" ]]; then
    pass_at "C-152 agent self-claim + orchestrator verdict markers split"
  else
    fail_at "C-152 verdict-split markers" "claim_ok=$claim_ok halt_ok=$halt_ok"
  fi
else
  skip_at "C-152 verdict-split markers not yet wired" \
    "ENG-152 in flight at stage:implementing (currently halted)"
fi

# ENG-153 (guards.sh --reason + threshold). The counter-bump body
# carries an explicit `Reason:` clause and a `Trips at: <count>/<n>`
# threshold disclosure.
if _dep_153_landed; then
  counter="$(jq -r '.[1].body' "$_store_file")"
  if grep -qE 'Reason:' <<<"$counter" \
     && grep -qE 'Trips at: [0-9]+/[0-9]+' <<<"$counter"; then
    pass_at "C-153 counter-bump body carries Reason: + Trips at: threshold"
  else
    fail_at "C-153 counter body" "got: $counter"
  fi
else
  skip_at "C-153 counter Reason+threshold not yet wired" \
    "ENG-153 in review at stage:reviewing"
fi

# ─── Summary ────────────────────────────────────────────────────────────
printf '\n--- summary ---\n'
printf '  PASS=%s  FAIL=%s  SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
if (( FAIL > 0 )); then
  printf 'FAIL summary: %s test(s) failed\n' "$FAIL" >&2
  exit 1
fi
printf 'OK\n'
