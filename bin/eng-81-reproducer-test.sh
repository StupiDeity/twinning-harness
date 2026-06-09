#!/usr/bin/env bash
# ENG-81 scenario reproducer — replays the 2026-05-14 15:54 UTC ledger incident
# against current code. Canonical regression fixture for the ENG-104 ledger
# contract family.
#
# Incident (2026-05-14 ~15:54 UTC): within ~30 s, (1) an agent self-posted a
# "verdict pass" via add_comment, (2) the orchestrator bumped a counter via
# add_comment, then (3) the orchestrator re-emitted a halt verdict via
# add_or_update_comment whose commentUpdate dedup-updated a prior halt comment
# from ~3 h upstream. commentUpdate preserves createdAt, so the canonical halt
# comment appeared hours upstream in Linear's top-down feed, invisible to
# anyone scanning from the bottom (most-recent) end.
#
# Dependency lifecycle (D-009) — source-text grep auto-un-skips each P1 block
# when the corresponding ticket ships; no fixture rewrite needed:
#
#   ENG-110  dispatch-id stamp           SHIPPED  (un-skips P0-4)
#   ENG-111  breadcrumb on dedup         SHIPPED  (un-skips P0-3b)
#   <header-line-ticket-id-TBD>          PENDING  (un-skips P1-header)
#   <verdict-split-ticket-id-TBD>        PENDING  (un-skips P1-verdict-split)
#   <guards-reason+threshold-ticket-TBD> PENDING  (un-skips P1-reason-threshold)
set -euo pipefail

SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Scaffold ────────────────────────────────────────────────────────────────
_TS="$(mktemp -d -t eng81r.XXXXXX)"
trap 'rm -rf "$_TS"' EXIT

_STUBS="$_TS/stubs"
mkdir -p "$_STUBS" "$_TS/state/test/metrics" \
         "$_TS/target/.pipeline-config/schemas"

cat > "$_TS/target/.pipeline-config/config.json" <<'JSON'
{
  "linear": {
    "team_id": "TEAM1",
    "project_id": "PROJ1",
    "native_states": {"in_review": "S1", "done": "S2", "active": "S3"},
    "workflow_stages": [
      "brainstorming","planning","implementing","ui",
      "reviewing","qa","building","released"
    ],
    "stage_label_prefix": "stage:"
  },
  "orchestrator": {},
  "human_checkpoints": {"require_human_on_threshold": {}},
  "project": {"slug": "test"}
}
JSON
printf '{"labels":{},"states":{}}' \
  > "$_TS/target/.pipeline-config/schemas/linear-ids.json"

# Stub metrics.sh so add_or_update_comment's internal || true calls succeed
printf '#!/usr/bin/env bash\nexit 0\n' > "$_STUBS/metrics.sh"
chmod +x "$_STUBS/metrics.sh"

export TARGET_REPO="$_TS/target"
export HARNESS_STATE_DIR="$_TS/state"
export PROJECT_SLUG="test"
export PIPELINE_DRY_RUN=0
export LINEAR_API_KEY="test-mock-key"
export PIPELINE_DISPATCH_ID="ENG-81R-d0001"
export PIPELINE_STAGE="implementing"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true

# ─── Source linear.sh ────────────────────────────────────────────────────────
# shellcheck disable=SC1091
source "$SCRIPT_DIR_REAL/linear.sh"

# Override SCRIPT_DIR so internal `bash "$SCRIPT_DIR/metrics.sh"` calls use stub
SCRIPT_DIR="$_STUBS"

# Stub _resolve_issue_uuid — avoids real Linear API roundtrip
_resolve_issue_uuid() { printf 'UUID-MOCK-ENG81R'; }

# ─── In-memory comment store ─────────────────────────────────────────────────
_STORE="$_TS/comment-store.json"
_ENG81R_CREATE_SEQ=0   # monotonic counter: drives both comment IDs and createdAt suffix

_eng81r_reset_store() {
  printf '{"comments":[]}' > "$_STORE"
  _ENG81R_CREATE_SEQ=0
}

_store_add_create() {
  local body="$1"
  _ENG81R_CREATE_SEQ=$(( _ENG81R_CREATE_SEQ + 1 ))
  local id ts tmp
  id="ENG81R-$(printf '%03d' "$_ENG81R_CREATE_SEQ")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%S).$(printf '%03d' "$_ENG81R_CREATE_SEQ")Z"
  tmp="$(jq --arg id "$id" --arg body "$body" --arg ts "$ts" \
    '.comments += [{"id":$id,"body":$body,"createdAt":$ts}]' "$_STORE")"
  printf '%s' "$tmp" > "$_STORE"
}

_store_update_by_id() {
  local id="$1" body="$2" tmp
  tmp="$(jq --arg id "$id" --arg body "$body" \
    '.comments |= map(if .id == $id then .body = $body else . end)' "$_STORE")"
  printf '%s' "$tmp" > "$_STORE"
}

_store_preseed_halt() {
  local issue="$1" tmp
  # Pre-seeded halt from ~3 h upstream (the ENG-81 bug precondition).
  # Hard-coded historical timestamp; seq counter intentionally NOT incremented.
  local old_body="Agent blocked — scope leak detected
<!-- meta: dedup key=halt/implementing/${issue} -->
<!-- meta: dispatch id=ENG-81R-d0000 stage=implementing -->"
  tmp="$(jq --arg id "HALT-PRE-001" --arg body "$old_body" \
    --arg ts "2026-05-14T12:54:00.001Z" \
    '.comments += [{"id":$id,"body":$body,"createdAt":$ts}]' "$_STORE")"
  printf '%s' "$tmp" > "$_STORE"
}

# ─── linear_query stub ───────────────────────────────────────────────────────
linear_query() {
  local query="${1:-}" vars="${2:-}"
  if [[ "$query" =~ commentCreate ]]; then
    local body
    body="$(jq -r '.body' <<<"$vars")"
    _store_add_create "$body"
    printf '{"data":{"commentCreate":{"success":true}}}'
  elif [[ "$query" =~ commentUpdate ]]; then
    local id body
    id="$(jq -r '.id' <<<"$vars")"
    body="$(jq -r '.body' <<<"$vars")"
    _store_update_by_id "$id" "$body"
    printf '{"data":{"commentUpdate":{"success":true}}}'
  else
    # fetch query (dedup check or existing-id lookup): return store in Linear shape
    jq -c '{data:{issue:{comments:{nodes:[.comments[]|{id,body,url:""}]}}}}' \
      "$_STORE"
  fi
}

# ─── Feature-flag probes (D-005) ─────────────────────────────────────────────
# Each probe is a source-text grep — self-maintaining when the dep ticket lands.

_probe_header_line_supported() {
  grep -qE '^\*\*[a-z]+\*\*.*author=' "$SCRIPT_DIR_REAL/run-stage.sh" 2>/dev/null
}
_probe_completion_claim_marker() {
  grep -qF 'stage-completion-claim' "$SCRIPT_DIR_REAL/pipeline-events.json" 2>/dev/null
}
_probe_verdict_split_supported() {
  _probe_completion_claim_marker
}
_probe_author_attribute() {
  grep -qE 'author=(orchestrator|agent|classify)' \
    "$SCRIPT_DIR_REAL/pipeline.sh" 2>/dev/null
}
_probe_guards_reason() {
  grep -qE 'reason=[a-z_]+ threshold=' "$SCRIPT_DIR_REAL/guards.sh" 2>/dev/null
}

# ─── Result accumulators ─────────────────────────────────────────────────────
_PASS=0 _FAIL=0 _SKIP=0

pass_at() { _PASS=$(( _PASS + 1 )); printf '  PASS %s\n' "$1"; }
fail_at() { _FAIL=$(( _FAIL + 1 )); printf '  FAIL %s\n' "$1"; }
skip_at() { _SKIP=$(( _SKIP + 1 )); printf '  SKIP %s\n' "$1"; }

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then pass_at "$label"
  else
    fail_at "$label"
    printf '    got:  %s\n' "$got"
    printf '    want: %s\n' "$want"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass_at "$label"
  else
    fail_at "$label"
    printf '    missing in body: %s\n' "$needle"
  fi
}

# ─── Timeline driver ─────────────────────────────────────────────────────────
replay_timeline() {
  local issue="$1" preseed="${2:-0}"
  _eng81r_reset_store
  if [[ "$preseed" == "1" ]]; then
    _store_preseed_halt "$issue"
  fi

  # Call-1: agent posts verdict PASS via add_comment.
  # Body carries <!-- pipeline: --> marker → bypasses hash-dedup path.
  PIPELINE_WRITER=agent
  add_comment "$issue" --body "PASS — implementing done
<!-- pipeline: verdict result=pass stage=implementing -->"

  # Call-2: orchestrator bumps counter via add_comment (pipeline marker).
  PIPELINE_WRITER=orchestrator
  add_comment "$issue" --body "Advancing implementing counter.
<!-- pipeline: counter bump=1 stage=implementing -->"

  # Call-3: orchestrator re-emits halt via add_or_update_comment (sig-dedup path).
  # In R-2 this updates HALT-PRE-001 in place, preserving its createdAt — the bug.
  PIPELINE_WRITER=orchestrator
  add_or_update_comment \
    "halt/implementing/${issue}" "$issue" \
    --body "Agent blocked — scope leak detected"
}

# ─── R-1: clean store (no preseed) ───────────────────────────────────────────
printf '\nR-1: clean store (no preseed)\n'

replay_timeline "ENG-154" 0

# P0-1: three calls produced three distinct commentCreate store entries
_r1_count="$(jq '.comments | length' "$_STORE")"
assert_eq "R-1/P0-1: store has 3 entries (3 commentCreate)" "$_r1_count" "3"

# P0-2: createdAt values are strictly monotonically increasing
_r1_orig_ts="$(jq -r '[.comments[].createdAt] | join(",")' "$_STORE")"
_r1_sort_ts="$(jq -r '[.comments[].createdAt] | sort | join(",")' "$_STORE")"
assert_eq "R-1/P0-2: createdAt strictly increasing" "$_r1_orig_ts" "$_r1_sort_ts"

# P0-4: every body carries the dispatch-id marker (ENG-110 SHIPPED)
_r1_no_marker="$(jq -r \
  '[.comments[] |
    select(.body | contains("<!-- meta: dispatch id=ENG-81R-d0001 stage=implementing -->") | not)
    | .id] | join(",")' "$_STORE")"
assert_eq "R-1/P0-4: all bodies carry dispatch marker (ENG-110)" \
  "$_r1_no_marker" ""

# P1-header (probe-gated): when header-line ticket ships, completion claim
# carries a typed author= header line
if _probe_header_line_supported; then
  fail_at "R-1/P1-header: probe true but assertion not yet written (<header-line-ticket-id-TBD>)"
else
  skip_at "R-1/P1-header: <header-line-ticket-id-TBD> not yet shipped"
fi

# P1-verdict-split (probe-gated): when verdict-split ticket ships, the agent
# verdict is a separate commentCreate with a distinct sig
if _probe_verdict_split_supported; then
  fail_at "R-1/P1-verdict-split: probe true but assertion not yet written (<verdict-split-ticket-id-TBD>)"
else
  skip_at "R-1/P1-verdict-split: <verdict-split-ticket-id-TBD> not yet shipped"
fi

# P1-reason-threshold (probe-gated): when guards-reason+threshold ticket ships,
# halt body carries reason=<token> threshold=<n>
if _probe_guards_reason; then
  _r1_halt_body="$(jq -r \
    '[.comments[] | select(.body | contains("<!-- meta: dedup key=halt/implementing/ENG-154"))]
     | last | .body' "$_STORE")"
  if [[ "$_r1_halt_body" =~ reason=[a-z_]+\ threshold=[0-9]+ ]]; then
    pass_at "R-1/P1-reason-threshold: halt body has reason+threshold"
  else
    fail_at "R-1/P1-reason-threshold: halt body missing reason+threshold"
    printf '    halt body: %s\n' "${_r1_halt_body:0:120}"
  fi
else
  skip_at "R-1/P1-reason-threshold: <guards-reason+threshold-ticket-TBD> not yet shipped"
fi

# ─── R-2: preseed (prior halt 3 h upstream — ENG-81 bug observation) ─────────
printf '\nR-2: preseed (prior halt 3h upstream)\n'

replay_timeline "ENG-154" 1

# P0-1b: store has 4 entries: preseed + 3 commentCreate (agent, counter, breadcrumb)
_r2_count="$(jq '.comments | length' "$_STORE")"
assert_eq "R-2/P0-1b: store has 4 entries (preseed + 3 creates)" "$_r2_count" "4"

# P0-3a (ENG-81 bug observation): commentUpdate preserves createdAt — the
# canonical halt comment appears hours upstream in Linear's top-down feed
_r2_preseed_ts="$(jq -r \
  '.comments[] | select(.id == "HALT-PRE-001") | .createdAt' "$_STORE")"
assert_eq "R-2/P0-3a: HALT-PRE-001 createdAt preserved (ENG-81 bug)" \
  "$_r2_preseed_ts" "2026-05-14T12:54:00.001Z"

# P0-3b (ENG-111 SHIPPED): breadcrumb comment posted as a fresh commentCreate,
# making the re-emission visible at the bottom of the top-down feed
_r2_breadcrumb_count="$(jq \
  '[.comments[] | select(.body | contains("<!-- meta: breadcrumb sig=halt/implementing/ENG-154"))]
   | length' "$_STORE")"
if [[ "$_r2_breadcrumb_count" -ge 1 ]]; then
  pass_at "R-2/P0-3b: breadcrumb comment posted (ENG-111)"
else
  fail_at "R-2/P0-3b: expected ENG-111 breadcrumb comment; none found"
fi

# P0-4b: all comments (including updated HALT-PRE-001) carry current dispatch marker
_r2_no_marker="$(jq -r \
  '[.comments[] |
    select(.body | contains("<!-- meta: dispatch id=ENG-81R-d0001 stage=implementing -->") | not)
    | .id] | join(",")' "$_STORE")"
assert_eq "R-2/P0-4b: all bodies carry dispatch marker (ENG-110)" \
  "$_r2_no_marker" ""

# P1-verdict-split (probe-gated): when verdict-split ships, halt should be a
# NEW commentCreate rather than a commentUpdate on HALT-PRE-001
if _probe_verdict_split_supported; then
  _r2_new_halt="$(jq \
    '[.comments[] |
      select(.body | contains("<!-- meta: dedup key=halt/implementing/ENG-154")) |
      select(.id != "HALT-PRE-001") |
      select(.createdAt > "2026-05-14T12:54:00.001Z")] | length' "$_STORE")"
  if [[ "$_r2_new_halt" -ge 1 ]]; then
    pass_at "R-2/P1-verdict-split: halt is fresh commentCreate (bug fixed)"
  else
    fail_at "R-2/P1-verdict-split: expected fresh halt CREATE; HALT-PRE-001 still canonical"
  fi
else
  skip_at "R-2/P1-verdict-split: <verdict-split-ticket-id-TBD> not yet shipped"
fi

# P1-reason-threshold: same probe as R-1, same body-content assertion
if _probe_guards_reason; then
  _r2_halt_body="$(jq -r \
    '[.comments[] | select(.id == "HALT-PRE-001") | .body] | first' "$_STORE")"
  if [[ "$_r2_halt_body" =~ reason=[a-z_]+\ threshold=[0-9]+ ]]; then
    pass_at "R-2/P1-reason-threshold: halt body has reason+threshold"
  else
    fail_at "R-2/P1-reason-threshold: halt body missing reason+threshold"
    printf '    halt body: %s\n' "${_r2_halt_body:0:120}"
  fi
else
  skip_at "R-2/P1-reason-threshold: <guards-reason+threshold-ticket-TBD> not yet shipped"
fi

# ─── P2: audit dump (ENG_81R_AUDIT=1) ────────────────────────────────────────
if [[ "${ENG_81R_AUDIT:-0}" == "1" ]]; then
  printf '\nP2 (audit): store state after R-2\n'
  jq '.' "$_STORE"
fi

# ─── Results ─────────────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed, %d skipped\n' "$_PASS" "$_FAIL" "$_SKIP"
[[ "$_FAIL" == "0" ]] || exit 1
exit 0

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
