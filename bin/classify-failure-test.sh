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

export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"

# Redirect bash "bash $SCRIPT_DIR/..." calls to local stubs via a tempdir.
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
METRICS_CAPTURE="$STUB_DIR/metrics.capture"
: > "$METRICS_CAPTURE"
for cmd in linear.sh slack.sh; do
  cat > "$STUB_DIR/$cmd" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$STUB_DIR/$cmd"
done
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

# ─── Summary ──────────────────────────────────────────────────────────
echo
if (( FAIL == 0 )); then
  printf 'All %d classify_failure cases passed.\n' "$PASS"
  exit 0
else
  printf '%d pass, %d fail.\n' "$PASS" "$FAIL"
  exit 1
fi
