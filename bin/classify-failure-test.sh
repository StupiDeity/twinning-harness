#!/usr/bin/env bash
# Unit tests for classify_failure (ENG-15).
# Runs under $PIPELINE_DRY_RUN=1 so no Linear/Slack/metrics side effects.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=classify-failure.sh
source "$SCRIPT_DIR/classify-failure.sh"

: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

# Redirect bash "bash $SCRIPT_DIR/..." calls to local stubs via a tempdir.
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
METRICS_CAPTURE="$STUB_DIR/metrics.capture"
: > "$METRICS_CAPTURE"

# Capture-stub for linear.sh (ENG-78). Records every invocation as a
# single line in $LINEAR_CAPTURE for assertions. Mirrors the
# metrics.sh capture pattern below.
LINEAR_CAPTURE="$STUB_DIR/linear.capture"
: > "$LINEAR_CAPTURE"
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LINEAR_CAPTURE"
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"

# slack.sh stays a no-op stub (no test asserts on slack invocations).
cat > "$STUB_DIR/slack.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$STUB_DIR/slack.sh"
# metrics.sh as a capture stub so cases 9-14 can inspect the emitted
# outcome/notes (ENG-10). Args: event issue_id stage outcome duration_ms notes.
cat > "$STUB_DIR/metrics.sh" <<SH
#!/usr/bin/env bash
printf 'EVENT=%s\nISSUE=%s\nSTAGE=%s\nOUTCOME=%s\nDURATION=%s\nNOTES=%s\n---\n' \
  "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" "\${5:-}" "\${6:-}" >> "$METRICS_CAPTURE"
exit 0
SH
chmod +x "$STUB_DIR/metrics.sh"

# classify-failure.sh uses "bash $_CFS_SCRIPT_DIR/linear.sh ..." — override
# _CFS_SCRIPT_DIR to point at our stubs.
_CFS_SCRIPT_DIR="$STUB_DIR"

# Also override git ls-remote and pipeline hash for deterministic evidence.
_cf_branch_head_sha() { printf '%s' "${MOCK_BRANCH_SHA:-mockbranchsha}"; }
compute_pipeline_content_hash() { printf '%s' "${MOCK_PIPELINE_HASH:-mockpipelinehash}"; }
_cf_branch_for() { printf '%s' "${MOCK_BRANCH:-feat/eng-test-mock}"; }

# Use a temp dir for issue state so we don't clobber live state.
HARNESS_STATE_DIR="$(mktemp -d)"
export HARNESS_STATE_DIR
PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
export PROJECT_STATE_DIR
mkdir -p "$PROJECT_STATE_DIR"

PASS=0; FAIL=0
fail_at() { printf '  ❌ %s\n      %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }

reset_state() {
  rm -rf "$PROJECT_STATE_DIR"/ENG-*
}

# Capture-stub helpers (ENG-10 cases 9-14). The capture file accumulates
# multiple invocations as `KEY=VALUE` blocks separated by `---`; latest_*
# returns the last non-empty value for the field.
latest_outcome() { awk -F= '/^OUTCOME=/ {out=$2} /^---$/ {} END{print out}' "$METRICS_CAPTURE"; }
latest_notes()   { awk -F= '/^NOTES=/   {n=substr($0,7)} END{print n}' "$METRICS_CAPTURE"; }
reset_metrics()  { : > "$METRICS_CAPTURE"; }

# ENG-78 linear-capture helpers. linear_calls returns one line per
# `bash linear.sh <args>` invocation made inside classify_failure.
reset_linear()   { : > "$LINEAR_CAPTURE"; }
linear_calls()   { cat "$LINEAR_CAPTURE"; }

read_state() {
  cat "$(issue_dir "$1")/issue-state.json"
}

# ─── Test 1: fresh skip-until-code-changes writes state + evidence ─────
reset_state
MOCK_PIPELINE_HASH="hashA" MOCK_BRANCH_SHA="shaA" \
  classify_failure "ENG-901" "implement" "skip-until-code-changes" "rc=2" 21 2
policy=$(read_state ENG-901 | jq -r .policy)
[[ "$policy" == "skip-until-code-changes" ]] \
  && pass_at "case-1 fresh skip-until-code-changes writes expected policy" \
  || fail_at "case-1 fresh skip-until-code-changes writes expected policy" "got $policy"

hash=$(read_state ENG-901 | jq -r '.evidence.pipeline_content_hash')
[[ "$hash" == "hashA" ]] \
  && pass_at "case-1 records pipeline_content_hash" \
  || fail_at "case-1 records pipeline_content_hash" "got $hash"

# ─── Test 2: retry-immediately first hit → retry_count=0 ─────────────
reset_state
MOCK_PIPELINE_HASH="hashB" MOCK_BRANCH_SHA="shaB" \
  classify_failure "ENG-902" "implement" "retry-immediately" "API-529" 20 ""
rc=$(read_state ENG-902 | jq -r .retry_count)
policy=$(read_state ENG-902 | jq -r .policy)
[[ "$rc" == "0" && "$policy" == "retry-immediately" ]] \
  && pass_at "case-2 retry-immediately first hit keeps policy + retry_count=0" \
  || fail_at "case-2" "got rc=$rc policy=$policy"

# ─── Test 3: retry-immediately same-SHA second hit → retry_count=1 ────
MOCK_PIPELINE_HASH="hashB" MOCK_BRANCH_SHA="shaB" \
  classify_failure "ENG-902" "implement" "retry-immediately" "API-529" 20 ""
rc=$(read_state ENG-902 | jq -r .retry_count)
policy=$(read_state ENG-902 | jq -r .policy)
[[ "$rc" == "1" && "$policy" == "retry-immediately" ]] \
  && pass_at "case-3 retry-immediately same-SHA increments retry_count to 1" \
  || fail_at "case-3" "got rc=$rc policy=$policy"

# ─── Test 4: retry-immediately same-SHA third hit → escalate ─────────
MOCK_PIPELINE_HASH="hashB" MOCK_BRANCH_SHA="shaB" \
  classify_failure "ENG-902" "implement" "retry-immediately" "API-529" 20 ""
rc=$(read_state ENG-902 | jq -r .retry_count)
policy=$(read_state ENG-902 | jq -r .policy)
[[ "$rc" == "2" && "$policy" == "skip-until-code-changes" ]] \
  && pass_at "case-4 retry-immediately same-SHA at 3rd hit escalates to skip-until-code-changes" \
  || fail_at "case-4" "got rc=$rc policy=$policy"

# ─── Test 5: retry-immediately DIFFERENT hash → retry_count resets ───
reset_state
MOCK_PIPELINE_HASH="hashC" MOCK_BRANCH_SHA="shaC" \
  classify_failure "ENG-903" "implement" "retry-immediately" "r1" 20 ""
MOCK_PIPELINE_HASH="hashC2" MOCK_BRANCH_SHA="shaC" \
  classify_failure "ENG-903" "implement" "retry-immediately" "r2" 20 ""
rc=$(read_state ENG-903 | jq -r .retry_count)
[[ "$rc" == "0" ]] \
  && pass_at "case-5 different pipeline hash resets retry_count" \
  || fail_at "case-5" "got rc=$rc"

# ─── Test 6: skip-until-human-acts writes correct policy (no escalation) ─
reset_state
MOCK_PIPELINE_HASH="hashD" MOCK_BRANCH_SHA="shaD" \
  classify_failure "ENG-904" "implement" "skip-until-human-acts" "severe" 21 3
policy=$(read_state ENG-904 | jq -r .policy)
[[ "$policy" == "skip-until-human-acts" ]] \
  && pass_at "case-6 skip-until-human-acts is recorded verbatim" \
  || fail_at "case-6" "got $policy"

# ─── Test 7: atomic write (no partial file on disk during write) ─────
reset_state
MOCK_PIPELINE_HASH="hashE" MOCK_BRANCH_SHA="shaE" \
  classify_failure "ENG-905" "implement" "skip-until-code-changes" "rc=2" 21 2
jq empty "$(issue_dir ENG-905)/issue-state.json" \
  && pass_at "case-7 state file is valid JSON" \
  || fail_at "case-7" "state file malformed"

# ─── Test 8: branch_head_sha empty when branch unresolved ────────────
reset_state
_cf_branch_for() { printf ''; }
_cf_branch_head_sha() { printf ''; }
MOCK_PIPELINE_HASH="hashF" \
  classify_failure "ENG-906" "brainstorm" "skip-until-code-changes" "no branch yet" 21 2
sha=$(read_state ENG-906 | jq -r '.evidence.branch_head_sha')
[[ "$sha" == "" ]] \
  && pass_at "case-8 empty branch yields empty branch_head_sha" \
  || fail_at "case-8" "got $sha"

# ─── Test 9: exit 10 → outcome=guards-tripped ─────────────────────────
reset_state; reset_metrics
classify_failure "ENG-907" "implement" "skip-until-human-acts" "g" 10 ""
outcome=$(latest_outcome); notes=$(latest_notes)
[[ "$outcome" == "guards-tripped" && "$notes" == *"policy=skip-until-human-acts"* ]] \
  && pass_at "case-9 exit 10 → guards-tripped with policy in notes" \
  || fail_at "case-9" "outcome=$outcome notes=$notes"

# ─── Test 10: exit 20 → outcome=dispatch-failed ───────────────────────
reset_state; reset_metrics
classify_failure "ENG-908" "implement" "retry-immediately" "d" 20 ""
outcome=$(latest_outcome); notes=$(latest_notes)
[[ "$outcome" == "dispatch-failed" && "$notes" == *"policy=retry-immediately"* ]] \
  && pass_at "case-10 exit 20 → dispatch-failed with policy in notes" \
  || fail_at "case-10" "outcome=$outcome notes=$notes"

# ─── Test 11: exit 21 subcode=3 → outcome=scope-violation ─────────────
reset_state; reset_metrics
classify_failure "ENG-909" "implement" "skip-until-human-acts" "sv" 21 3
outcome=$(latest_outcome); notes=$(latest_notes)
[[ "$outcome" == "scope-violation" && "$notes" == *"subcode=3"* && "$notes" == *"policy=skip-until-human-acts"* ]] \
  && pass_at "case-11 exit 21 subcode=3 → scope-violation with subcode+policy in notes" \
  || fail_at "case-11" "outcome=$outcome notes=$notes"

# ─── Test 12: exit 22 → outcome=pr-opened-too-early ───────────────────
reset_state; reset_metrics
classify_failure "ENG-910" "implement" "skip-until-human-acts" "pr" 22 ""
outcome=$(latest_outcome)
[[ "$outcome" == "pr-opened-too-early" ]] \
  && pass_at "case-12 exit 22 → pr-opened-too-early" \
  || fail_at "case-12" "outcome=$outcome"

# ─── Test 13: exit 24 → outcome=linear-post-failed ────────────────────
reset_state; reset_metrics
classify_failure "ENG-911" "implement" "retry-immediately" "lp" 24 ""
outcome=$(latest_outcome)
[[ "$outcome" == "linear-post-failed" ]] \
  && pass_at "case-13 exit 24 → linear-post-failed" \
  || fail_at "case-13" "outcome=$outcome"

# ─── Test 14: exit 0 subcode=1 → outcome=scope-approval-pending ───────
reset_state; reset_metrics
classify_failure "ENG-912" "implement" "skip-until-human-acts" "sa" 0 1
outcome=$(latest_outcome)
[[ "$outcome" == "scope-approval-pending" ]] \
  && pass_at "case-14 exit 0 subcode=1 → scope-approval-pending" \
  || fail_at "case-14" "outcome=$outcome"

# ─── Test 15: exit 26 → outcome=worktree-mutation-forbidden (ENG-71) ──
# Pin the new build-stage exit code added in ENG-71. Without this fixture,
# a regression that drops the `26)` arm in failure_outcome_for_exit routes
# silently to `unknown-exit-26` and the retrospective's §1 outcome filter
# misses it (CLAUDE.md: "adding a new exit code without updating that
# switch routes it to `unknown-exit-N` and the retrospective's §1 filter
# will not classify it").
reset_state; reset_metrics
classify_failure "ENG-913" "building" "skip-until-human-acts" "wt" 26 ""
outcome=$(latest_outcome)
[[ "$outcome" == "worktree-mutation-forbidden" ]] \
  && pass_at "case-15 exit 26 → worktree-mutation-forbidden" \
  || fail_at "case-15" "outcome=$outcome"

# ─── Test 16 (ENG-78 D-001): retry-immediately fresh hit no halt label ────
reset_state; reset_linear
MOCK_PIPELINE_HASH="hashG" MOCK_BRANCH_SHA="shaG" \
  classify_failure "ENG-920" "implement" "retry-immediately" "API-529" 20 ""
if linear_calls | grep -q '^add-label ENG-920 pipeline:halted$'; then
  fail_at "case-16 retry-immediately fresh hit must NOT apply pipeline:halted (ENG-78 D-001)" \
    "got: $(linear_calls | grep pipeline:halted)"
else
  pass_at "case-16 retry-immediately fresh hit does NOT apply pipeline:halted (ENG-78 D-001)"
fi

# ─── Test 17 (ENG-78 D-001): retry-immediately auto-escalation applies halt ─
reset_state
MOCK_PIPELINE_HASH="hashH" MOCK_BRANCH_SHA="shaH" \
  classify_failure "ENG-921" "implement" "retry-immediately" "r1" 20 ""
MOCK_PIPELINE_HASH="hashH" MOCK_BRANCH_SHA="shaH" \
  classify_failure "ENG-921" "implement" "retry-immediately" "r2" 20 ""
reset_linear
MOCK_PIPELINE_HASH="hashH" MOCK_BRANCH_SHA="shaH" \
  classify_failure "ENG-921" "implement" "retry-immediately" "r3" 20 ""
if linear_calls | grep -q '^add-label ENG-921 pipeline:halted$'; then
  pass_at "case-17 auto-escalated retry-immediately applies pipeline:halted (ENG-78 G-2)"
else
  fail_at "case-17 auto-escalated retry-immediately should apply pipeline:halted" \
    "got: $(linear_calls)"
fi

# ─── Test 18 (ENG-78 G-3): skip-until-human-acts applies halt verbatim ────
reset_state; reset_linear
MOCK_PIPELINE_HASH="hashI" MOCK_BRANCH_SHA="shaI" \
  classify_failure "ENG-922" "implement" "skip-until-human-acts" "severe" 21 3
if linear_calls | grep -q '^add-label ENG-922 pipeline:halted$'; then
  pass_at "case-18 skip-until-human-acts applies pipeline:halted (ENG-78 G-3)"
else
  fail_at "case-18 skip-until-human-acts should apply pipeline:halted" \
    "got: $(linear_calls)"
fi

# ─── Test 19 (ENG-78 D-002): retry-immediately uses retry-pending meta-shape ─
reset_state; reset_linear
MOCK_PIPELINE_HASH="hashJ" MOCK_BRANCH_SHA="shaJ" \
  classify_failure "ENG-923" "implement" "retry-immediately" "API-529" 20 ""
last_aoc="$(linear_calls | grep '^add-comment ' | tail -1)"
# Sig must contain retry-pending/, body must NOT contain halt verdict marker,
# body must contain meta:metric transient-retry header.
if [[ "$last_aoc" == *"retry-pending/implement/ENG-923"* ]] \
   && [[ "$last_aoc" != *"<!-- pipeline: verdict result=halt"* ]] \
   && [[ "$last_aoc" == *"<!-- meta: metric name=transient-retry"* ]]; then
  pass_at "case-19 retry-immediately uses retry-pending sig + meta-shape body (ENG-78 D-002)"
else
  fail_at "case-19 retry-immediately marker shape" "got: $last_aoc"
fi

# ─── Test 20 (QA adversarial, ENG-78): malformed issue-state.json must not
#     crash classify_failure; the corrupt prior state must be ignored and
#     the call must complete with a fresh retry_count=0. Pin: silent/no-op
#     behavior on a corrupted state file is what the `2>/dev/null || true`
#     guards in the prior_* reads at lines 60-65 promise — without this
#     test, a future refactor that drops those guards would crash the
#     classifier (and SIGTERM the dispatch under set -euo pipefail). ──
reset_state; reset_linear
mkdir -p "$(issue_dir ENG-924)"
printf '{ this is not valid json' > "$(issue_dir ENG-924)/issue-state.json"
if MOCK_PIPELINE_HASH="hashK" MOCK_BRANCH_SHA="shaK" \
     classify_failure "ENG-924" "implement" "retry-immediately" "API-529" 20 ""; then
  rc=$(read_state ENG-924 | jq -r .retry_count)
  policy=$(read_state ENG-924 | jq -r .policy)
  if [[ "$rc" == "0" && "$policy" == "retry-immediately" ]]; then
    pass_at "case-20 (QA adversarial) malformed prior state file does not crash; treated as fresh"
  else
    fail_at "case-20 (QA adversarial) state was not rewritten cleanly" "rc=$rc policy=$policy"
  fi
else
  fail_at "case-20 (QA adversarial) classify_failure crashed on malformed prior state" "non-zero exit"
fi

# ─── Test 21 (QA adversarial, ENG-78 D-002): meta-shape comment body must
#     parse via parse_pipeline_marker as event=meta, kind=metric — proves
#     find_fresh_verdict's `event != "verdict"` filter at
#     verdict-handler.sh:111 will exclude it. This pins the contract end-
#     to-end (writer → parser), so a future change to either side cannot
#     silently re-introduce the dead-end retry bug. ────────────────────
reset_state; reset_linear
MOCK_PIPELINE_HASH="hashL" MOCK_BRANCH_SHA="shaL" \
  classify_failure "ENG-924b" "implement" "retry-immediately" "API-529" 20 ""
last_aoc="$(linear_calls | grep '^add-comment ' | tail -1)"
# Strip the leading `add-comment <ident> --sig <sig> --body ` to recover body.
# The body is the remaining args concatenated with single spaces (linear
# capture-stub uses `$*`). parse_pipeline_marker only needs the marker
# substring, which survives whitespace re-collapse.
body="${last_aoc#add-comment ENG-924b --sig retry-pending/implement/ENG-924b --body }"
ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
ev_event="$(jq -r '.event // ""' <<<"$ev" 2>/dev/null || printf '')"
ev_kind="$(jq -r '.kind // ""'  <<<"$ev" 2>/dev/null || printf '')"
ev_name="$(jq -r '.name // ""'  <<<"$ev" 2>/dev/null || printf '')"
if [[ "$ev_event" == "meta" && "$ev_kind" == "metric" && "$ev_name" == "transient-retry" ]]; then
  pass_at "case-21 (QA adversarial) meta-shape body parses as {event:meta,kind:metric,name:transient-retry}"
else
  fail_at "case-21 (QA adversarial) meta-shape parse round-trip" \
    "ev_event=$ev_event ev_kind=$ev_kind ev_name=$ev_name body=$body"
fi

# ─── Test 22 (QA adversarial, ENG-78 G-4): retry-immediately fresh-hit
#     comment body advertises the right attempt counter (`attempt=0`,
#     `attempt 0 of 2`, `2 more time(s)`). Without this, a future refactor
#     that off-by-ones the counter would silently mislead operators about
#     when escalation will fire — the brainstorm's G-4 explicitly calls
#     out "attempt N of 2" as load-bearing operator-visible text. The
#     body spans multiple lines (printf with embedded \n), so we read the
#     full capture, not just the first line. ──
reset_state; reset_linear
MOCK_PIPELINE_HASH="hashM" MOCK_BRANCH_SHA="shaM" \
  classify_failure "ENG-924c" "implement" "retry-immediately" "API-529" 20 ""
full_capture="$(linear_calls)"
if [[ "$full_capture" == *"attempt=0"* ]] \
   && [[ "$full_capture" == *"attempt 0 of 2"* ]] \
   && [[ "$full_capture" == *"2 more time(s)"* ]]; then
  pass_at "case-22 (QA adversarial) fresh retry-immediately comment shows attempt=0 / 2 remaining"
else
  fail_at "case-22 (QA adversarial) attempt-counter shape" "got: $full_capture"
fi

# ─── Test 87.C2: classify_failure preserves allocator-set fields ─────
# ENG-87 review C2: pre-fix, classify_failure overwrote issue-state.json
# with a fresh JSON missing current_dispatch_id / current_dispatch_seq;
# next tick's allocator reset seq=0 → re-emitted d0001 → monotonicity
# broken. Plan §A-007 mandates the merge-preserve idiom:
# `$prior + {…}`, mirroring _allocate_dispatch_id_locked at common.sh.
#
# Sequence: seed issue-state with allocator-side fields → invoke
# classify_failure → assert allocator fields survive.
reset_state
mkdir -p "$(issue_dir ENG-887C2)"
printf '%s\n' '{"current_dispatch_seq":7,"current_dispatch_id":"ENG-887C2-d0007","current_stage":"implementing"}' \
  > "$(issue_dir ENG-887C2)/issue-state.json"
MOCK_PIPELINE_HASH="hashC2" MOCK_BRANCH_SHA="shaC2" \
  classify_failure "ENG-887C2" "implementing" "skip-until-human-acts" "test" 29 ""
got_dispatch_id="$(jq -r '.current_dispatch_id // ""' "$(issue_dir ENG-887C2)/issue-state.json")"
got_dispatch_seq="$(jq -r '.current_dispatch_seq // ""' "$(issue_dir ENG-887C2)/issue-state.json")"
got_stage="$(jq -r '.current_stage // ""' "$(issue_dir ENG-887C2)/issue-state.json")"
got_policy="$(jq -r '.policy // ""' "$(issue_dir ENG-887C2)/issue-state.json")"
[[ "$got_dispatch_id" == "ENG-887C2-d0007" ]] \
  && pass_at "87.C2: classify_failure preserves current_dispatch_id" \
  || fail_at "87.C2: current_dispatch_id stomped" "got: $got_dispatch_id"
[[ "$got_dispatch_seq" == "7" ]] \
  && pass_at "87.C2: classify_failure preserves current_dispatch_seq" \
  || fail_at "87.C2: current_dispatch_seq stomped" "got: $got_dispatch_seq"
[[ "$got_stage" == "implementing" ]] \
  && pass_at "87.C2: classify_failure preserves current_stage" \
  || fail_at "87.C2: current_stage stomped" "got: $got_stage"
# Also confirm classify_failure's own fields landed.
[[ "$got_policy" == "skip-until-human-acts" ]] \
  && pass_at "87.C2: classify_failure still writes its own policy field" \
  || fail_at "87.C2: classify_failure policy missing" "got: $got_policy"

# ─── Test 87.C2-dual: classify_failure overwrites stale classify-set
# ENG-87 review-iter-2 M3: the original 87.C2 verifies one direction
# (allocator fields survive) but not the inverse (stale classify-set
# fields get OVERWRITTEN). A future regression like
# `$prior + ($prior + {…})` (double-merge that lets prior win) would
# silently false-pass the original. Pin both directions: seed prior
# with BOTH allocator fields AND a stale classify-set
# {policy=retry-immediately, reason=old, retry_count=3}; assert the
# new write produces the new classify values AND keeps the allocator
# fields.
reset_state
# Restore the default _cf_branch_head_sha that respects MOCK_BRANCH_SHA
# (case-8 above overrode it to always-empty and the override persists).
_cf_branch_for() { printf 'feat/eng-887c2d'; }
_cf_branch_head_sha() { printf '%s' "${MOCK_BRANCH_SHA:-mockbranchsha}"; }
mkdir -p "$(issue_dir ENG-887C2D)"
printf '%s\n' '{"current_dispatch_seq":11,"current_dispatch_id":"ENG-887C2D-d0011","current_stage":"implementing","policy":"retry-immediately","reason":"prior-stale-reason","retry_count":3,"exit_code":21,"evidence":{"pipeline_content_hash":"hOLD","branch_head_sha":"sOLD"}}' \
  > "$(issue_dir ENG-887C2D)/issue-state.json"
MOCK_PIPELINE_HASH="hNEW" MOCK_BRANCH_SHA="sNEW" \
  classify_failure "ENG-887C2D" "implementing" "skip-until-human-acts" "new-reason" 29 ""
# Allocator-fields direction.
got_dispatch_id="$(jq -r '.current_dispatch_id // ""' "$(issue_dir ENG-887C2D)/issue-state.json")"
got_dispatch_seq="$(jq -r '.current_dispatch_seq // ""' "$(issue_dir ENG-887C2D)/issue-state.json")"
[[ "$got_dispatch_id" == "ENG-887C2D-d0011" ]] \
  && pass_at "87.C2-dual: allocator current_dispatch_id survives merge (preserve direction)" \
  || fail_at "87.C2-dual: allocator id" "got: $got_dispatch_id"
[[ "$got_dispatch_seq" == "11" ]] \
  && pass_at "87.C2-dual: allocator current_dispatch_seq survives merge" \
  || fail_at "87.C2-dual: allocator seq" "got: $got_dispatch_seq"
# Classify-set fields: stale values must be OVERWRITTEN with the new
# values from this classify_failure invocation.
got_policy="$(jq -r '.policy // ""' "$(issue_dir ENG-887C2D)/issue-state.json")"
got_reason="$(jq -r '.reason // ""' "$(issue_dir ENG-887C2D)/issue-state.json")"
got_exit_code="$(jq -r '.exit_code // ""' "$(issue_dir ENG-887C2D)/issue-state.json")"
got_hash="$(jq -r '.evidence.pipeline_content_hash // ""' "$(issue_dir ENG-887C2D)/issue-state.json")"
got_sha="$(jq -r '.evidence.branch_head_sha // ""' "$(issue_dir ENG-887C2D)/issue-state.json")"
[[ "$got_policy" == "skip-until-human-acts" ]] \
  && pass_at "87.C2-dual: stale policy 'retry-immediately' overwritten with new (overwrite direction)" \
  || fail_at "87.C2-dual: policy not overwritten" "got: $got_policy (expected skip-until-human-acts)"
[[ "$got_reason" == "new-reason" ]] \
  && pass_at "87.C2-dual: stale reason overwritten" \
  || fail_at "87.C2-dual: reason not overwritten" "got: $got_reason"
[[ "$got_exit_code" == "29" ]] \
  && pass_at "87.C2-dual: stale exit_code overwritten" \
  || fail_at "87.C2-dual: exit_code not overwritten" "got: $got_exit_code"
[[ "$got_hash" == "hNEW" && "$got_sha" == "sNEW" ]] \
  && pass_at "87.C2-dual: stale evidence overwritten with current hash/sha" \
  || fail_at "87.C2-dual: evidence not overwritten" "hash=$got_hash sha=$got_sha"

# ─── Test 23: exit 23 → outcome=branch-creation-forbidden (ENG-66) ────
# Pin the new cross-stage exit code added in ENG-66. Without this
# fixture, a regression that drops the `23)` arm in
# failure_outcome_for_exit routes silently to `unknown-exit-23` and
# the retrospective's §1 outcome filter misses it (CLAUDE.md: "adding
# a new exit code without updating that switch routes it to
# `unknown-exit-N` and the retrospective's §1 filter will not classify
# it"). Mirror of Test 15 (ENG-71 exit-26 entry pin).
reset_state; reset_metrics
classify_failure "ENG-914" "implementing" "skip-until-human-acts" "br" 23 ""
outcome=$(latest_outcome)
[[ "$outcome" == "branch-creation-forbidden" ]] \
  && pass_at "case-23 exit 23 → branch-creation-forbidden" \
  || fail_at "case-23" "outcome=$outcome"

# ─── Test 24 (ENG-87 review-iter-3 M3): exit 29 → envelope-violation ──
# Round-trip pin for the ENG-87 dispatch-envelope-violation arm in
# failure_outcome_for_exit (bin/common.sh:235). CLAUDE.md "When wiring
# a new script" §: "adding a new exit code without updating that
# switch routes it to `unknown-exit-N` and the retrospective's §1
# filter will not classify it." Test-23 covers the prior new arm
# (23 → branch-creation-forbidden); the parallel pin for arm 29 was
# absent — a future refactor that drops the `29)` case would silently
# route every envelope-violation halt to `unknown-exit-29` and the
# retrospective's §1 outcome filter would lose the classification.
got="$(failure_outcome_for_exit 29 "")"
[[ "$got" == "envelope-violation" ]] \
  && pass_at "case-29 exit 29 → envelope-violation" \
  || fail_at "case-29 (review-iter-3 M3)" "outcome=$got (expected envelope-violation)"

# ─── Summary ──────────────────────────────────────────────────────────
echo
if (( FAIL == 0 )); then
  printf 'All %d classify_failure cases passed.\n' "$PASS"
  exit 0
else
  printf '%d pass, %d fail.\n' "$PASS" "$FAIL"
  exit 1
fi
