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
# Force-override LINEAR_API_KEY (do NOT use ${VAR:=...}: an operator-set
# real key would otherwise leak into the test's add_comment path which
# could attempt a network roundtrip on regression).
export LINEAR_API_KEY=test-mock-key
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
mkdir -p "$PROJECT_STATE_DIR"

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
# `stage-completion-claim` event AND the verdict's linear_comment
# body_shape spec mentions `author=` (the agent/orchestrator split).
# Defensive `// "" | tostring` coerce so a non-string body_shape (null,
# array, or object placeholder mid-edit) reports "not landed" rather
# than failing the jq pipeline mid-detector.
_dep_152_landed() {
  jq -e '.events | has("stage-completion-claim")' \
    "$SCRIPT_DIR_REAL/pipeline-events.json" >/dev/null 2>&1 \
  && jq -e '(.events.verdict.linear_comment.body_shape // "") | tostring | contains("author=")' \
    "$SCRIPT_DIR_REAL/pipeline-events.json" >/dev/null 2>&1
}

# ENG-153 lands when guards.sh::bump parses the --reason flag in an argv
# handler. Anchor on the case-arm shape `^<indent>--reason)` so an
# incidental prose mention of `--reason` in a docstring or error string
# does not flip the gate prematurely.
_dep_153_landed() {
  grep -qE -- '^[[:space:]]*--reason\)' "$SCRIPT_DIR_REAL/guards.sh"
}

# ─── Fixture comment store + linear_query override ──────────────────────
# Place the capture file INSIDE $_TEST_TARGET_DIR so the existing EXIT
# trap cleans it up via _test_safe_rm; a `mktemp -t` path lives at
# $TMPDIR outside the trap's reach.
_store_file="$_TEST_TARGET_DIR/eng-81-store.json"
printf '[]\n' > "$_store_file"

# C-007: empty store at file open + path is inside cleanup scope (Failure
# Mode → Test Map row 7: fixture leaks across reruns). If the store path
# escapes $_TEST_TARGET_DIR, the EXIT trap will not remove it and residue
# can persist between runs. If the store is non-empty at this point,
# either we picked up cross-rerun state or the initialise-empty step
# silently failed. Run this BEFORE the timeline replay so the assertion
# reflects the as-opened state, not the post-write state.
case "$_store_file" in
  "$_TEST_TARGET_DIR/"*) pass_at "C-007a store path is inside cleanup-scope temp dir" ;;
  *) fail_at "C-007a store path is outside cleanup scope" "got: $_store_file" ;;
esac
_open_count="$(jq 'length' "$_store_file" 2>/dev/null || echo "X")"
if [[ "$_open_count" == "0" ]]; then
  pass_at "C-007b store is empty at file open (no cross-rerun residue)"
else
  fail_at "C-007b store is empty at file open" "got jq length=$_open_count"
fi

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
# timeline-replay so an early failure is still attributable. Use the
# `printf -- '…'` shape uniformly so the leading-dash payload never
# looks like an option to printf (parity with d6e8040).
printf -- '\n--- ENG-150 (landed=%s) ---\n' "$(_dep_150_landed && echo yes || echo no)"
printf -- '--- ENG-151 (landed=%s) ---\n' "$(_dep_151_landed && echo yes || echo no)"
printf -- '--- ENG-152 (landed=%s) ---\n' "$(_dep_152_landed && echo yes || echo no)"
printf -- '--- ENG-153 (landed=%s) ---\n\n' "$(_dep_153_landed && echo yes || echo no)"

# Comment 1: agent self-claim (PASS) at 15:54:04Z. The `if !` shape
# bypasses set -e and captures rc explicitly; stderr is NOT swallowed so
# a real add_comment failure surfaces in the test output instead of
# silently aborting the script.
if ! PIPELINE_WRITER=agent _FIXTURE_INJECT_CREATED_AT="2026-05-14T15:54:04Z" \
     add_comment "ENG-81" --body \
       "<!-- pipeline: verdict result=pass stage=implementing -->" >/dev/null; then
  fail_at "timeline replay #1 (agent self-claim 15:54:04Z)" "add_comment returned non-zero"
fi

# Comment 2: orchestrator counter bump at 15:54:26Z (current shape;
# ENG-153 will widen this body to include Reason + Trips at).
if ! PIPELINE_WRITER=orchestrator _FIXTURE_INJECT_CREATED_AT="2026-05-14T15:54:26Z" \
     add_comment "ENG-81" --body \
       "<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh." \
     >/dev/null; then
  fail_at "timeline replay #2 (orchestrator counter bump 15:54:26Z)" "add_comment returned non-zero"
fi

# Comment 3: orchestrator halt verdict at 15:54:32Z. In the historical
# incident this body was dedup-updated onto the morning's 12:24:00 halt
# slot via add-or-update-comment; the fixture deliberately uses
# add-comment here so under CURRENT code the result is three append-only
# comments. (Once ENG-150 lands, add-or-update-comment is removed
# entirely; the fixture already reflects that target state.) The
# adversarial replay block at C-150-adv (below) exercises the historical
# add-or-update path while ENG-150 is unlanded.
if ! PIPELINE_WRITER=orchestrator _FIXTURE_INJECT_CREATED_AT="2026-05-14T15:54:32Z" \
     add_comment "ENG-81" --body \
       $'<!-- pipeline: verdict result=halt reason=agent-blocked --> SEVERE scope violation on learned-rules/harness/project-profile.md.\nRecorded at: 2026-05-14T15:54:32Z' \
     >/dev/null; then
  fail_at "timeline replay #3 (orchestrator halt verdict 15:54:32Z)" "add_comment returned non-zero"
fi

unset _FIXTURE_INJECT_CREATED_AT

# ─── Always-on invariants (today's green path) ──────────────────────────

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

# ─── C-006: dependency-detector anti-false-positive probes ──────────────
# Failure Mode → Test Map row 6 (dependency-detector false-positive).
# Each `_dep_15N_landed` shape detector reads $SCRIPT_DIR_REAL/<file> and
# probes for a SHAPE (case arm, function def, jq key) — not an arbitrary
# prose mention of the symbol. This block swaps $SCRIPT_DIR_REAL to a
# controlled probe directory and verifies each detector:
#   (a) returns 1 on a known-bad file that only mentions the symbol in
#       prose or comment text (anti-false-positive); and
#   (b) returns 0 on a known-good file carrying the canonical shape
#       (anti-false-negative; the gate must un-skip when the dep ships).
# Catches the regression class where someone tightens a detector's
# anchored regex and accidentally over-tightens past the eventual shape.
_probe_dir="$_TEST_TARGET_DIR/dep-probe"
mkdir -p "$_probe_dir"
_real_script_dir_save="$SCRIPT_DIR_REAL"
SCRIPT_DIR_REAL="$_probe_dir"

# _dep_150_landed: ENG-150 lands when `add-or-update-comment` case-arm
# disappears from linear.sh::main.
printf '%s\n' '#!/usr/bin/env bash' 'case "$cmd" in' '  add-or-update-comment) cmd ;;' 'esac' \
  > "$_probe_dir/linear.sh"
if _dep_150_landed; then
  fail_at "C-006-150-bad" "_dep_150_landed flipped despite case-arm still present"
else
  pass_at "C-006-150-bad _dep_150_landed rejects file with subcommand still present"
fi
printf '%s\n' '#!/usr/bin/env bash' 'case "$cmd" in' '  add-comment) add_comment "$@" ;;' 'esac' \
  > "$_probe_dir/linear.sh"
if _dep_150_landed; then
  pass_at "C-006-150-good _dep_150_landed reports landed when case-arm absent"
else
  fail_at "C-006-150-good" "_dep_150_landed false-negative when case-arm absent"
fi

# _dep_151_landed: ENG-151 lands when bin/linear.sh defines
# `_render_event_header()` at column 0.
printf '%s\n' '#!/usr/bin/env bash' '# Comment that mentions _render_event_header in prose only.' 'echo hi' \
  > "$_probe_dir/linear.sh"
if _dep_151_landed; then
  fail_at "C-006-151-bad" "_dep_151_landed false-positive on prose mention"
else
  pass_at "C-006-151-bad _dep_151_landed rejects prose-only mention"
fi
printf '%s\n' '#!/usr/bin/env bash' '_render_event_header() { printf hi; }' \
  > "$_probe_dir/linear.sh"
if _dep_151_landed; then
  pass_at "C-006-151-good _dep_151_landed accepts real function definition"
else
  fail_at "C-006-151-good" "_dep_151_landed false-negative on function def"
fi

# _dep_152_landed: requires BOTH (a) events key `stage-completion-claim`
# AND (b) verdict.linear_comment.body_shape mentions `author=`.
jq -n '{events:{verdict:{linear_comment:{body_shape:"prose mentioning author= field only"}}}}' \
  > "$_probe_dir/pipeline-events.json"
if _dep_152_landed; then
  fail_at "C-006-152-bad" "_dep_152_landed flipped without stage-completion-claim event key"
else
  pass_at "C-006-152-bad _dep_152_landed rejects without stage-completion-claim event"
fi
jq -n '{events:{"stage-completion-claim":{},verdict:{linear_comment:{body_shape:"contains author= field"}}}}' \
  > "$_probe_dir/pipeline-events.json"
if _dep_152_landed; then
  pass_at "C-006-152-good _dep_152_landed accepts both event-key + author= shape"
else
  fail_at "C-006-152-good" "_dep_152_landed false-negative on canonical shape"
fi
# Defensive coerce check: null body_shape must NOT crash the detector.
jq -n '{events:{"stage-completion-claim":{},verdict:{linear_comment:{body_shape:null}}}}' \
  > "$_probe_dir/pipeline-events.json"
if _dep_152_landed; then
  fail_at "C-006-152-null" "_dep_152_landed accepts null body_shape"
else
  pass_at "C-006-152-null _dep_152_landed reports not-landed on null body_shape (no jq crash)"
fi

# _dep_153_landed: ENG-153 lands when guards.sh parses `--reason` in an
# argv handler (case-arm `^<indent>--reason)`).
printf '%s\n' '#!/usr/bin/env bash' '# This is prose-only commentary about a future --reason flag.' \
  > "$_probe_dir/guards.sh"
if _dep_153_landed; then
  fail_at "C-006-153-bad" "_dep_153_landed false-positive on prose mention"
else
  pass_at "C-006-153-bad _dep_153_landed rejects prose-only mention"
fi
printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in' '  --reason) reason="$2"; shift 2 ;;' 'esac' \
  > "$_probe_dir/guards.sh"
if _dep_153_landed; then
  pass_at "C-006-153-good _dep_153_landed accepts real argv handler"
else
  fail_at "C-006-153-good" "_dep_153_landed false-negative on argv handler"
fi

SCRIPT_DIR_REAL="$_real_script_dir_save"

# ─── Dependency-gated invariants ────────────────────────────────────────

# ENG-150 (append-only ledger / no in-place rewrite). On current code
# the three add_comment calls already produce three appends; this
# assertion documents that the SAME invariant continues to hold after
# ENG-150 ships and `add-or-update-comment` is removed entirely.
if _dep_150_landed; then
  pass_at "C-150 ENG-150 landed: add-or-update-comment removed from bin/linear.sh"
else
  skip_at "C-150 ENG-150 not yet landed" \
    "add-or-update-comment still present at bin/linear.sh::main"
fi

# C-150-adv: adversarial replay of the historical add-or-update path
# (the canonical ENG-81 incident bug). Plan Task 4 docblock forward-
# references "a separate adversarial fixture" that exercises the
# production add_or_update_comment path so the regression is captured
# under CURRENT code (before ENG-150 ships).
#
# Setup: pre-seed an isolated sub-store with a comment carrying the
# halt dedup-key marker timestamped 12:24:00 (the morning's halt slot).
# Then call add_or_update_comment with a new 15:54:32 halt body. Under
# current code (ENG-150 unlanded), the call routes through commentUpdate
# and rewrites the 12:24 entry's body IN PLACE while createdAt stays
# pinned at 12:24 — exactly the chronological-pinning bug ENG-150 fixes.
#
# When ENG-150 lands, add-or-update-comment is removed entirely; the
# fixture skip arm fires and this adversarial check becomes a no-op
# (the always-on C-001/C-002 invariants then guard the same property).
if _dep_150_landed; then
  skip_at "C-150-adv ENG-150 landed: add_or_update_comment removed; adversarial replay obsolete" \
    "subcommand removed from bin/linear.sh::main; in-place rewrite path no longer exists"
else
  _adv_store_file="$_TEST_TARGET_DIR/eng-81-adv-store.json"
  _orig_store_file="$_store_file"
  _store_file="$_adv_store_file"

  # Pre-seed: the morning's 12:24 halt comment carrying the dedup sig.
  jq -n '[{
    id: "cmt-pre-halt",
    body: "<!-- pipeline: verdict result=halt reason=agent-blocked --> 12:24 halt\n<!-- meta: dedup key=halt/implementing/ENG-81 -->",
    createdAt: "2026-05-14T12:24:00Z",
    url: ""
  }]' > "$_adv_store_file"

  # Replay: orchestrator emits a NEW halt body at 15:54:32 via the
  # historical add_or_update_comment path. The breadcrumb sub-call
  # (add_comment for the body-change ENG-111 trail) inherits the same
  # store; we filter it out below by id == "cmt-pre-halt".
  if ! PIPELINE_WRITER=orchestrator add_or_update_comment \
       "halt/implementing/ENG-81" "ENG-81" --body \
       "<!-- pipeline: verdict result=halt reason=agent-blocked --> 15:54 halt body rewritten in place" \
       >/dev/null; then
    _store_file="$_orig_store_file"
    fail_at "C-150-adv add_or_update_comment exec" "non-zero rc"
  else
    canon_ts="$(jq -r '.[] | select(.id == "cmt-pre-halt") | .createdAt' "$_adv_store_file")"
    canon_body="$(jq -r '.[] | select(.id == "cmt-pre-halt") | .body' "$_adv_store_file")"
    _store_file="$_orig_store_file"
    if [[ "$canon_ts" == "2026-05-14T12:24:00Z" ]] \
       && grep -qF "15:54 halt body rewritten in place" <<<"$canon_body"; then
      pass_at "C-150-adv add_or_update_comment in-place rewrite reproduces ENG-81 bug (createdAt pinned at 12:24 while body rewritten to 15:54)"
    else
      fail_at "C-150-adv adversarial replay" \
        "expected canonical createdAt pinned at 12:24:00Z and body rewritten; got ts=$canon_ts body=$canon_body"
    fi
  fi
fi

# ENG-151 (human-readable header line). Each body opens with the
# canonical `[ENG-81 · implementing · ENG-81-d0007 · <iso-ts> · <actor>]`.
# The timestamp regex is generic ISO-8601 (not incident-specific) so
# this assertion does NOT break if the eventual ENG-151 implementation
# is tested against a different replay window.
if _dep_151_landed; then
  header_re='\[ENG-81 · implementing · ENG-81-d0007 · [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z · (agent|orchestrator)\]'
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
# `pipeline: verdict ... author=orchestrator`. Use semantic selectors
# (filter by body content) rather than positional `.[0]/.[2]` indexing
# so the assertion stays correct if the timeline grows additional
# entries or the dispatch order shifts.
if _dep_152_landed; then
  claim_count="$(jq -r '[.[] | select(.body | contains("pipeline: stage-completion-claim"))] | length' "$_store_file")"
  halt_count="$(jq -r '[.[] | select(.body | test("pipeline: verdict result=halt.*author=orchestrator"))] | length' "$_store_file")"
  if (( claim_count >= 1 && halt_count >= 1 )); then
    pass_at "C-152 agent self-claim + orchestrator verdict markers split"
  else
    fail_at "C-152 verdict-split markers" "claim_count=$claim_count halt_count=$halt_count"
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
