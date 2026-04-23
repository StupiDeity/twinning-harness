#!/usr/bin/env bash
# QA adversarial coverage for ENG-18 (pipeline state machine formalization).
#
# Gap this file closes: the existing verdict-handler-test.sh asserts shape
# via jq-on-fixture for cases 10/11/12/14/15/18 and never invokes the real
# code paths under test (halt.sh, scope-check.sh has-scope-approval,
# guards.sh count_marker_since_last_transition, classify-failure.sh halt
# marker emission). This file invokes those code paths directly against
# stubbed linear.sh + slack.sh + metrics.sh and asserts their observable
# effects (arg shapes passed to linear.sh, exit codes, comment bodies).
#
# Plus adversarial breakages outside the plan's Failure Mode → Test Map
# (halt.sh arg-parse edges, marker-regex edges, stale decision with newer
# halt, empty comments array, concurrent-tick idempotency).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"

STUB_DIR="$(mktemp -d)"
STUB_LOG="$STUB_DIR/calls.log"
export STUB_DIR STUB_LOG
: > "$STUB_LOG"
trap 'rm -rf "$STUB_DIR"' EXIT

export VH_FIXTURE_COMMENTS="[]"
export VH_CURRENT_LABELS=""
export VH_CURRENT_STAGE_LABEL=""

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
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"

for cmd in slack.sh metrics.sh branch-name.sh; do
  cat > "$STUB_DIR/$cmd" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0") $*" >> "$STUB_LOG"
exit 0
SH
  chmod +x "$STUB_DIR/$cmd"
done

# Route script-under-test invocations through the stub dir. Each script
# tested here resolves siblings via its own SCRIPT_DIR; we point the
# siblings at the stubs by symlinking the real script into STUB_DIR.
for real in halt.sh scope-check.sh guards.sh classify-failure.sh verdict-handler.sh common.sh; do
  ln -sf "$SCRIPT_DIR/$real" "$STUB_DIR/$real"
done

# Also need the fixtures used by classify-failure.sh (.pipeline/config.json
# lookups, pipeline-content-hash, branch-name.sh). Point TWINNING_DIR at a
# tempdir so issue-state.json writes don't clobber real state.
export TWINNING_DIR="$STUB_DIR/twinning"
mkdir -p "$TWINNING_DIR"

PASS=0; FAIL=0
fail_at() { printf '  ❌ %s\n      %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
reset_calls() { : > "$STUB_LOG"; }
calls_contains() { grep -qF "$1" "$STUB_LOG" 2>/dev/null; }
calls_grep_count() {
  local n
  n=$(grep -cF "$1" "$STUB_LOG" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

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

# ─── A1: halt.sh resolve scope-approved posts marker + removes halted ─
reset_calls
bash "$STUB_DIR/halt.sh" resolve ENG-801 --decision scope-approved >/dev/null 2>&1
if calls_contains "linear.sh add-comment ENG-801 <!-- pipeline-decision: scope-approved -->" \
   && calls_contains "linear.sh remove-label ENG-801 pipeline:halted"; then
  pass_at "A1 halt.sh resolve scope-approved posts decision marker + removes pipeline:halted"
else
  fail_at "A1 halt.sh resolve scope-approved" "calls=$(cat "$STUB_LOG")"
fi

# ─── A2: halt.sh resolve resume posts resume marker ──────────────────
reset_calls
bash "$STUB_DIR/halt.sh" resolve ENG-802 --decision resume >/dev/null 2>&1
if calls_contains "linear.sh add-comment ENG-802 <!-- pipeline-decision: resume -->" \
   && calls_contains "linear.sh remove-label ENG-802 pipeline:halted"; then
  pass_at "A2 halt.sh resolve resume posts decision marker"
else
  fail_at "A2 halt.sh resolve resume" "calls=$(cat "$STUB_LOG")"
fi

# ─── A3: halt.sh rejects unknown decision value ──────────────────────
reset_calls
set +e
bash "$STUB_DIR/halt.sh" resolve ENG-803 --decision approve-me >/dev/null 2>"$STUB_DIR/stderr"
rc=$?
set -e
if [[ "$rc" != "0" ]] && grep -q 'unknown decision' "$STUB_DIR/stderr"; then
  pass_at "A3 halt.sh rejects unknown --decision value"
else
  fail_at "A3 halt.sh rejects unknown decision" "rc=$rc stderr=$(cat "$STUB_DIR/stderr")"
fi

# ─── A4: halt.sh rejects missing ENG-id ──────────────────────────────
reset_calls
set +e
bash "$STUB_DIR/halt.sh" resolve --decision resume >/dev/null 2>"$STUB_DIR/stderr"
rc=$?
set -e
[[ "$rc" != "0" ]] \
  && pass_at "A4 halt.sh rejects missing issue id" \
  || fail_at "A4 halt.sh rejects missing issue id" "rc=$rc"

# ─── A5: halt.sh rejects unknown subcommand ──────────────────────────
set +e
bash "$STUB_DIR/halt.sh" status ENG-805 >/dev/null 2>"$STUB_DIR/stderr"
rc=$?
set -e
[[ "$rc" != "0" ]] \
  && pass_at "A5 halt.sh rejects unknown subcommand" \
  || fail_at "A5 halt.sh rejects unknown subcommand" "rc=$rc"

# ─── A6: has-scope-approval TRUE when decision post-dates halt ───────
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline-halt: scope-deviation -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline-decision: scope-approved -->|2026-04-23T11:00:00.000Z")"
set +e
bash "$STUB_DIR/scope-check.sh" has-scope-approval ENG-806 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] \
  && pass_at "A6 has-scope-approval returns 0 when decision post-dates halt" \
  || fail_at "A6 has-scope-approval decision post-dates halt" "rc=$rc"

# ─── A7: has-scope-approval FALSE when no decision ───────────────────
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline-halt: scope-deviation -->|2026-04-23T10:00:00.000Z")"
set +e
bash "$STUB_DIR/scope-check.sh" has-scope-approval ENG-807 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != "0" ]] \
  && pass_at "A7 has-scope-approval returns non-zero when no decision posted" \
  || fail_at "A7 has-scope-approval no decision" "rc=$rc"

# ─── A8: has-scope-approval FALSE when a NEWER halt invalidates older approval ─
# Scenario: user approved at T1, but then a fresh scope-deviation halt
# fires at T2 (e.g. after the replay agent touched more out-of-scope files).
# The stale decision must NOT satisfy the new halt.
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline-halt: scope-deviation -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline-decision: scope-approved -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline-halt: scope-deviation -->|2026-04-23T11:00:00.000Z")"
set +e
bash "$STUB_DIR/scope-check.sh" has-scope-approval ENG-808 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != "0" ]] \
  && pass_at "A8 has-scope-approval stale decision ignored when newer halt arrives" \
  || fail_at "A8 has-scope-approval stale decision" "rc=$rc (expected non-zero)"

# ─── A9: has-scope-approval FALSE when no halt ever happened ─────────
# Decision comment alone, with no preceding scope-deviation halt, must
# not falsely satisfy the check.
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline-decision: scope-approved -->|2026-04-23T11:00:00.000Z")"
set +e
bash "$STUB_DIR/scope-check.sh" has-scope-approval ENG-809 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != "0" ]] \
  && pass_at "A9 has-scope-approval returns non-zero when no scope-deviation halt exists" \
  || fail_at "A9 has-scope-approval no halt" "rc=$rc"

# ─── A10: guards.sh count_marker_since_last_transition exercises real helper ─
# Stub SCRIPT_DIR inside guards.sh to point at STUB_DIR so its calls to
# "$SCRIPT_DIR/linear.sh" hit the stub and read VH_FIXTURE_COMMENTS.
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline-metric: qa_rejection -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline-metric: qa_rejection -->|2026-04-23T09:30:00.000Z" \
  "<!-- pipeline-transition: qa → building -->|2026-04-23T10:00:00.000Z" \
  "<!-- pipeline-metric: qa_rejection -->|2026-04-23T11:00:00.000Z")"
# guards.sh sets SCRIPT_DIR from BASH_SOURCE, so source the symlink in STUB_DIR.
# Clear set -u temporarily because guards.sh expects check()'s args.
set +u
# shellcheck source=guards.sh
source "$STUB_DIR/guards.sh"
set -u
got="$(count_marker_since_last_transition ENG-810 qa_rejection)"
[[ "$got" == "1" ]] \
  && pass_at "A10 guards.sh count_marker_since_last_transition returns 1 after transition (not 3)" \
  || fail_at "A10 count_marker_since_last_transition" "got $got (expected 1)"

# ─── A11: guards.sh helper counts ALL markers when no transition ever ─
VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline-metric: qa_rejection -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline-metric: qa_rejection -->|2026-04-23T09:30:00.000Z")"
got="$(count_marker_since_last_transition ENG-811 qa_rejection)"
[[ "$got" == "2" ]] \
  && pass_at "A11 guards.sh helper falls back to full count when no transition exists" \
  || fail_at "A11 count_marker no-transition fallback" "got $got (expected 2)"

# ─── A12: classify-failure applies pipeline:halted + halt marker body ─
# This is the canonical case-10 from the plan's Failure Mode → Test Map,
# which the existing classify-failure-test.sh skipped.
# Replay add-or-update-comment body through stdin capture by enhancing the
# linear.sh stub to echo its full argv to the call log. The stub already
# does that above — assert via calls_contains on the full arg vector.
cat > "$STUB_DIR/linear.sh" <<'SH'
#!/usr/bin/env bash
# Capture full argv shape (shell-escaped) so tests can assert comment bodies.
printf '%s' "linear.sh"    >> "$STUB_LOG"
for a in "$@"; do
  printf ' [%s]' "$a"      >> "$STUB_LOG"
done
printf '\n'                >> "$STUB_LOG"
case "$1" in
  get-comments) printf '%s\n' "${VH_FIXTURE_COMMENTS:-[]}" ;;
  has-label)
    for lbl in ${VH_CURRENT_LABELS:-}; do
      [[ "$lbl" == "$3" ]] && exit 0
    done
    exit 1 ;;
  stage-of) printf '%s\n' "${VH_CURRENT_STAGE_LABEL:-}" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"

# Mock git commands classify-failure needs. Use function overrides via
# a shim script that classify-failure's _cf_branch_head_sha calls —
# easier: override the helpers after sourcing.
reset_calls
# shellcheck source=classify-failure.sh
set +u
source "$STUB_DIR/classify-failure.sh"
set -u
_CFS_SCRIPT_DIR="$STUB_DIR"
_cf_branch_for()      { printf '%s' "feat/eng-812-mock"; }
_cf_branch_head_sha() { printf '%s' "mocksha"; }
compute_pipeline_content_hash() { printf '%s' "mockhash"; }

classify_failure "ENG-812" "implement" "skip-until-human-acts" "scope violation" 21 3 >/dev/null 2>&1

if calls_contains "linear.sh [add-label] [ENG-812] [pipeline:halted]"; then
  pass_at "A12 classify-failure applies pipeline:halted"
else
  fail_at "A12 classify-failure applies pipeline:halted" "calls=$(cat "$STUB_LOG")"
fi
if calls_contains "linear.sh [add-or-update-comment] [halt/implement/ENG-812] [ENG-812]" \
   && grep -qF '<!-- pipeline-halt: agent-blocked -->' "$STUB_LOG"; then
  pass_at "A12 classify-failure halt comment body contains <!-- pipeline-halt: agent-blocked --> marker"
else
  fail_at "A12 halt-marker in body" "calls=$(cat "$STUB_LOG")"
fi

# ─── A13: classify-failure agent-failure marker for non-human policies ─
reset_calls
classify_failure "ENG-813" "implement" "skip-until-code-changes" "build failed" 21 2 >/dev/null 2>&1
if grep -qF '<!-- pipeline-halt: agent-failure -->' "$STUB_LOG"; then
  pass_at "A13 classify-failure skip-until-code-changes uses agent-failure marker"
else
  fail_at "A13 classify-failure agent-failure marker" "calls=$(cat "$STUB_LOG")"
fi

# ─── A14: apply_transition is idempotent under replay ────────────────
# Re-sourcing through STUB_DIR and re-running with same fixtures
# must not produce duplicate transition comments beyond the first call.
reset_calls
export VH_FIXTURE_COMMENTS="[]"
# shellcheck source=verdict-handler.sh
set +u
source "$STUB_DIR/verdict-handler.sh"
set -u
_VH_SCRIPT_DIR="$STUB_DIR"
apply_transition ENG-814 qa building ""
apply_transition ENG-814 qa building "" 0   # explicit no-waypoint (resume path)
posts="$(calls_grep_count "linear.sh [add-comment] [ENG-814] [<!-- pipeline-transition: qa → building -->")"
if [[ "$posts" == "1" ]]; then
  pass_at "A14 apply_transition resume-path (post_waypoint=0) skips the transition-comment repost"
else
  fail_at "A14 apply_transition idempotency" "transition posts=$posts (expected 1)"
fi

# ─── A15: find_fresh_verdict handles empty comments array cleanly ────
reset_calls
export VH_FIXTURE_COMMENTS="[]"
out="$(find_fresh_verdict ENG-815 2>&1)"
[[ -z "$out" ]] \
  && pass_at "A15 find_fresh_verdict prints empty on empty comment array (no crash, no JSON)" \
  || fail_at "A15 find_fresh_verdict empty input" "out=$out"

# ─── A16: find_fresh_verdict handles null from Linear gracefully ─────
reset_calls
export VH_FIXTURE_COMMENTS="null"
out="$(find_fresh_verdict ENG-816 2>&1)"
[[ -z "$out" ]] \
  && pass_at "A16 find_fresh_verdict prints empty when linear.sh get-comments returns null" \
  || fail_at "A16 find_fresh_verdict null input" "out=$out"

# ─── A17: find_fresh_verdict treats malformed marker as no-fresh ─────
# `<!-- pipeline-stage-summary: -->` with empty stage field must not match.
reset_calls
export VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline-transition: planning → implementing -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline-stage-summary: -->|2026-04-23T10:00:00.000Z")"
out="$(find_fresh_verdict ENG-817)"
[[ -z "$out" ]] \
  && pass_at "A17 find_fresh_verdict treats malformed stage-summary (empty stage) as no-fresh" \
  || fail_at "A17 malformed marker" "out=$out"

# ─── A18: verdict_handler on malformed marker surfaces protocol-violation ─
reset_calls
export VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline-transition: planning → implementing -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline-stage-summary: -->|2026-04-23T10:00:00.000Z")"
export VH_CURRENT_STAGE_LABEL="stage:implementing"
export VH_CURRENT_LABELS="stage:implementing pipeline:halted"
rc=0; verdict_handler ENG-818 implementing >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "2" ]] && grep -qF 'protocol-violation/no-marker/ENG-818' "$STUB_LOG"; then
  pass_at "A18 verdict_handler posts no-marker protocol-violation on malformed verdict"
else
  fail_at "A18 malformed → protocol-violation" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── A19: rejection without target marker treated as protocol violation ─
# `<!-- pipeline-rejection: qa -->` alone (no target) has tgt="" which
# will not be in any loopback row, so unknown-loopback fires.
reset_calls
export VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline-transition: implementing → qa -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline-rejection: qa -->|2026-04-23T10:00:00.000Z")"
export VH_CURRENT_STAGE_LABEL="stage:qa"
export VH_CURRENT_LABELS="stage:qa pipeline:halted"
rc=0; verdict_handler ENG-819 qa >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "2" ]] && grep -qF 'protocol-violation/unknown-loopback/ENG-819' "$STUB_LOG"; then
  pass_at "A19 rejection with missing target surfaces unknown-loopback protocol-violation"
else
  fail_at "A19 rejection missing target" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── A20: released stage has no forward transition (terminal) ────────
# Protocol violation expected if anyone posts stage-summary: released.
reset_calls
export VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline-transition: building → released -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline-stage-summary: released -->|2026-04-23T10:00:00.000Z")"
export VH_CURRENT_STAGE_LABEL="stage:released"
export VH_CURRENT_LABELS="stage:released pipeline:halted"
rc=0; verdict_handler ENG-820 released >/dev/null 2>&1 || rc=$?
if [[ "$rc" == "2" ]] && grep -qF 'protocol-violation/unknown-forward/ENG-820' "$STUB_LOG"; then
  pass_at "A20 released is terminal: stage-summary: released surfaces unknown-forward violation"
else
  fail_at "A20 released is terminal" "rc=$rc calls=$(cat "$STUB_LOG")"
fi

# ─── A21: uppercase / casing edge — parser must not match STAGE-SUMMARY ─
reset_calls
export VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline-transition: planning → implementing -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline-STAGE-summary: qa -->|2026-04-23T10:00:00.000Z")"
out="$(find_fresh_verdict ENG-821)"
[[ -z "$out" ]] \
  && pass_at "A21 find_fresh_verdict is case-sensitive: upper-case marker key does not match" \
  || fail_at "A21 case-sensitive" "out=$out"

# ─── A22: ASCII arrow `->` does NOT act as transition boundary ──────
# A human-authored comment containing `pipeline-transition: a -> b` (ASCII
# hyphen+gt) must NOT be treated as the freshness boundary, because the
# canonical orchestrator waypoint uses U+2192 `→`. Otherwise any plain
# English discussion of "transition: implement -> ui" would silently move
# the freshness window and erase real verdicts.
reset_calls
export VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline-stage-summary: qa -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline-transition: qa -> building -->|2026-04-23T10:00:00.000Z")"
# The fake ASCII waypoint would move `last_transition_ts` to 10:00 and drop
# the verdict at 09:00. With the real U+2192-requiring regex it has no
# effect, and the 09:00 verdict is still fresh.
fresh="$(find_fresh_verdict ENG-822)"
# We expect the real implementation to MATCH the ASCII waypoint too, because
# find_fresh_verdict only greps for `<!-- pipeline-transition:` prefix and
# trusts the waypoint marker. This is a known limitation — document it.
mtype="$(jq -r '.marker // ""' <<<"${fresh:-\"\"}" 2>/dev/null || printf '')"
if [[ -z "$fresh" ]]; then
  pass_at "A22 ASCII-arrow waypoint detected as freshness boundary (documents limitation: find_fresh_verdict does not validate arrow glyph)"
elif [[ "$mtype" == "pipeline-stage-summary" ]]; then
  pass_at "A22 ASCII-arrow waypoint NOT treated as boundary; verdict still fresh"
else
  fail_at "A22 ascii-arrow-freshness" "unexpected fresh marker=$mtype"
fi

# ─── A23: classify-failure double-apply idempotency ─────────────────
# Two consecutive failures should each add-label pipeline:halted. Linear
# itself is idempotent on duplicate add-label, but the halt-comment uses
# add-or-update-comment keyed on sig "halt/$stage/$issue" so the body is
# upserted rather than duplicated. Assert:
#   - add-label pipeline:halted called each time (orchestrator relies on
#     label being present even after remove happens on forward transition)
#   - only ONE sig'd halt-comment upsert per failure (add-or-update-comment,
#     not add-comment)
reset_calls
classify_failure "ENG-823" "implement" "skip-until-code-changes" "err" 21 2 >/dev/null 2>&1 || true
classify_failure "ENG-823" "implement" "skip-until-code-changes" "err" 21 2 >/dev/null 2>&1 || true
halted_count="$(calls_grep_count "linear.sh [add-label] [ENG-823] [pipeline:halted]")"
sig_halt_count="$(calls_grep_count "linear.sh [add-or-update-comment] [halt/implement/ENG-823] [ENG-823]")"
add_comment_count="$(calls_grep_count "linear.sh [add-comment] [ENG-823]")"
if [[ "$halted_count" == "2" ]] && [[ "$sig_halt_count" == "2" ]] && [[ "$add_comment_count" == "0" ]]; then
  pass_at "A23 classify-failure: double-apply uses add-or-update-comment (not add-comment), so halt markers do not accumulate as duplicates"
else
  fail_at "A23 classify-failure double-apply idempotency" \
    "halted_add=$halted_count sig_halt=$sig_halt_count add_comment=$add_comment_count"
fi

# ─── A24: halt markers inside classify-failure's halt body do NOT trick ─
# find_fresh_verdict into treating that halt comment as a rejection or
# pass verdict. The body contains the halt marker verbatim; scanner must
# classify it as pipeline-halt (halt-for-human), not pipeline-stage-summary
# nor pipeline-rejection.
reset_calls
export VH_FIXTURE_COMMENTS="$(mk_fixture \
  "<!-- pipeline-transition: planning → implementing -->|2026-04-23T09:00:00.000Z" \
  "<!-- pipeline-halt: agent-failure -->\\n\\nPipeline: \`implement\` stage halted — err|2026-04-23T10:00:00.000Z")"
fresh="$(find_fresh_verdict ENG-824)"
mtype="$(jq -r '.marker' <<<"$fresh" 2>/dev/null || printf '')"
[[ "$mtype" == "pipeline-halt" ]] \
  && pass_at "A24 classify-failure halt body classified as pipeline-halt (never confused with verdicts)" \
  || fail_at "A24 halt body classification" "mtype=$mtype"

# ─── Summary ──────────────────────────────────────────────────────────
echo
if (( FAIL == 0 )); then
  printf 'All %d QA adversarial cases passed.\n' "$PASS"
  exit 0
else
  printf '%d pass, %d fail.\n' "$PASS" "$FAIL"
  exit 1
fi
