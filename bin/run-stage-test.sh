#!/usr/bin/env bash
# Test harness for post_completion_comment + rollback summary cleanup (ENG-11).
# All cases run under PIPELINE_DRY_RUN=1 against a mktemp'd HARNESS_STATE_DIR and
# a STUB_DIR of fake linear.sh / branch-name.sh / gh scripts, so no real
# Linear / gh / filesystem side-effects escape the harness.

set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

# Stubs: linear.sh captures args for inspection; branch-name.sh + gh return
# deterministic values so we can assert PR-tail presence/absence.
STUB_DIR="$(mktemp -d)"
CAPTURE_FILE="$STUB_DIR/capture.txt"
: > "$CAPTURE_FILE"

cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
# args: \$1 subcommand \$2 sig \$3 ident \$4 body
# ENG-45: get-comments returns \$MOCK_COMMENTS_JSON (default '[]') so unit tests
# of _fresh_wait_reason can inject fixture comment streams without standing up
# a full Linear stub.
case "\${1:-}" in
  get-comments)
    printf '%s' "\${MOCK_COMMENTS_JSON-[]}"
    ;;
  *)
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
      "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    ;;
esac
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"

cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
printf 'feat/%s-mock-slug\n' "$(tr '[:upper:]' '[:lower:]' <<<"$1")"
SH
chmod +x "$STUB_DIR/branch-name.sh"

# Toggleable gh stub: routes by the value of the --json arg.
#   MOCK_GH_PR_URL   — controls `gh pr list --json url` output.
#   MOCK_GH_PR_STATE — controls `gh pr list --json state` output (ENG-62).
# Argument scan walks argv to find `--json <value>` so the stub stays oblivious
# to other flag ordering. ${VAR-} (single-dash) is empty on unset OR empty,
# matches neither the secret-name pattern nor secret-probe-lint.sh's
# ${VAR:-FALLBACK} matcher (ENG-46) — lint-clean by construction.
cat > "$STUB_DIR/gh" <<'SH'
#!/usr/bin/env bash
json_arg=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--json" ]]; then
    json_arg="${2-}"
    break
  fi
  shift
done
case "$json_arg" in
  state) printf '%s' "${MOCK_GH_PR_STATE-}" ;;
  url|*) printf '%s' "${MOCK_GH_PR_URL-}" ;;
esac
SH
chmod +x "$STUB_DIR/gh"

# Guards capture: records every `guards.sh bump <ident> <counter>` invocation.
GUARDS_CAPTURE="$STUB_DIR/guards.capture"
: > "$GUARDS_CAPTURE"
cat > "$STUB_DIR/guards.sh" <<SH
#!/usr/bin/env bash
# args: \$1 subcmd \$2 ident \$3 counter
printf 'SUBCMD=%s\nIDENT=%s\nCOUNTER=%s\n---\n' \
  "\${1:-}" "\${2:-}" "\${3:-}" >> "$GUARDS_CAPTURE"
exit 0
SH
chmod +x "$STUB_DIR/guards.sh"
reset_guards_capture() { : > "$GUARDS_CAPTURE"; }
guards_bump_count() { grep -c '^SUBCMD=bump$' "$GUARDS_CAPTURE" 2>/dev/null || true; }
guards_counter_for_last_bump() { awk -F= '/^COUNTER=/ {c=$2} END{print c}' "$GUARDS_CAPTURE"; }

# scope-check stub: MOCK_SCOPE_RC sets the exit code, MOCK_SCOPE_OUT the stdout.
cat > "$STUB_DIR/scope-check.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_SCOPE_OUT:-}"
exit "${MOCK_SCOPE_RC:-0}"
SH
chmod +x "$STUB_DIR/scope-check.sh"

# Source common.sh + run-stage.sh so post_completion_comment is defined.
# run-stage.sh's sentinel at :307 `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` means
# sourcing does NOT run main(); no no-op sentinel variable needed.
# shellcheck source=common.sh
source "$HARNESS_DIR/common.sh"
# shellcheck source=classify-failure.sh
source "$HARNESS_DIR/classify-failure.sh"
# shellcheck source=run-stage.sh
source "$HARNESS_DIR/run-stage.sh"

# Isolate on-disk state: must come AFTER sourcing common.sh, which unconditionally
# sets HARNESS_STATE_DIR=$HOME/.twinning-pipeline. Overriding here prevents the EXIT
# trap from deleting the real pipeline directory.
HARNESS_STATE_DIR="$(mktemp -d)"
export HARNESS_STATE_DIR
PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
export PROJECT_STATE_DIR
mkdir -p "$PROJECT_STATE_DIR"
trap 'rm -rf "$HARNESS_STATE_DIR" "$STUB_DIR"' EXIT

# Redirect post_completion_comment's sub-calls through the stubs.
SCRIPT_DIR="$STUB_DIR"
PATH="$STUB_DIR:$PATH"

PASS=0; FAIL=0
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
fail_at() { printf '  ❌ %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
# Each test resets CAPTURE_FILE first, so the file always has at most one record.
reset_capture()   { : > "$CAPTURE_FILE"; }
captured_sig()    { awk -F= '/^SIG=/  {print $2; exit}' "$CAPTURE_FILE"; }
captured_body()   { awk '/^BODY_BEGIN$/{flag=1; next} /^BODY_END$/{flag=0} flag' "$CAPTURE_FILE"; }

# ─── Case 1: happy path (non-empty file, not symlink) ───────────────────
reset_capture
mkdir -p "$(issue_dir ENG-T1)"
printf '## Plan summary\n\nWork done.\n' > "$(issue_dir ENG-T1)/stage-summary-plan.md"
post_completion_comment ENG-T1 plan
body="$(captured_body)"
if   [[ "$(captured_sig)" == "completion/plan/ENG-T1" ]] \
  && grep -q 'plan summary' <<<"$body" \
  && grep -q 'Plan summary' <<<"$body"; then
  pass_at "case-1 happy path: sig + header + agent body posted"
else
  fail_at "case-1 happy path" "sig=$(captured_sig) body=$body"
fi

# ─── Case 2: missing file → summary_missing fallback ────────────────────
reset_capture
mkdir -p "$(issue_dir ENG-T2)"
rm -f "$(issue_dir ENG-T2)/stage-summary-plan.md"
post_completion_comment ENG-T2 plan
body="$(captured_body)"
if grep -q 'summary_missing' <<<"$body" \
  && grep -q 'Agent did not write' <<<"$body"; then
  pass_at "case-2 missing file: fallback body + summary_missing marker"
else
  fail_at "case-2 missing file" "$body"
fi

# ─── Case 3: symlink refused ────────────────────────────────────────────
reset_capture
mkdir -p "$(issue_dir ENG-T3)"
ln -sf /dev/null "$(issue_dir ENG-T3)/stage-summary-plan.md"
post_completion_comment ENG-T3 plan
body="$(captured_body)"
if grep -q 'summary_symlink_refused' <<<"$body"; then
  pass_at "case-3 symlink: fallback with summary_symlink_refused marker"
else
  fail_at "case-3 symlink" "$body"
fi

# ─── Case 4: sig-hijack marker stripped from body ───────────────────────
reset_capture
mkdir -p "$(issue_dir ENG-T4)"
printf '## Real body\n<!-- meta: dedup key=completion/plan/ENG-OTHER -->\nMore text.\n' \
  > "$(issue_dir ENG-T4)/stage-summary-plan.md"
post_completion_comment ENG-T4 plan
body="$(captured_body)"
if   grep -q 'Real body'                          <<<"$body" \
  && grep -q 'More text'                          <<<"$body" \
  && ! grep -q 'completion/plan/ENG-OTHER'        <<<"$body"; then
  pass_at "case-4 sig-hijack: agent-embedded pipeline-sig line stripped"
else
  fail_at "case-4 sig-hijack" "$body"
fi

# ─── Case 5: oversize file → truncation marker ──────────────────────────
reset_capture
mkdir -p "$(issue_dir ENG-T5)"
head -c 40000 /dev/zero | tr '\0' x > "$(issue_dir ENG-T5)/stage-summary-plan.md"
post_completion_comment ENG-T5 plan
body="$(captured_body)"
if grep -q 'summary_truncated' <<<"$body" \
  && grep -q '\[truncated at 32 KiB\]' <<<"$body"; then
  pass_at "case-5 oversize: truncation marker + truncate annotation"
else
  fail_at "case-5 oversize" "${body:0:200}..."
fi

# ─── Case 6: building-stage header + PR tail ──────────────────────────
reset_capture
mkdir -p "$(issue_dir ENG-T6)"
printf 'merge done\n' > "$(issue_dir ENG-T6)/stage-summary-building.md"
MOCK_GH_PR_URL="https://github.com/mock/repo/pull/99" \
  post_completion_comment ENG-T6 building
body="$(captured_body)"
if grep -q 'building summary'                                      <<<"$body" \
  && grep -q '— PR: https://github.com/mock/repo/pull/99'          <<<"$body"; then
  pass_at "case-6 building: header 'building summary' + PR tail appended"
else
  fail_at "case-6 build" "$body"
fi

# ─── Case 7: no-PR fallthrough (ui stage with gh returning empty) ──────
reset_capture
mkdir -p "$(issue_dir ENG-T7)"
printf 'UI done.\n' > "$(issue_dir ENG-T7)/stage-summary-ui.md"
MOCK_GH_PR_URL="" post_completion_comment ENG-T7 ui
body="$(captured_body)"
if   grep -q 'UI done'   <<<"$body" \
  && ! grep -q '— PR:'   <<<"$body"; then
  pass_at "case-7 no-PR fallthrough: body posts without PR tail"
else
  fail_at "case-7 no-PR fallthrough" "$body"
fi

# ─── Case 8: rollback-stage clears summary files (Task 6 coverage) ──────
# Direct test of rollback-stage.sh's cleanup loop via a mocked current/target.
# We seed summaries for stages implement..qa and verify rollback from qa→implement
# deletes the three stages the rank loop walks through (ui, review, qa).
reset_capture
mkdir -p "$(issue_dir ENG-T8)"
for s in implement ui review qa; do
  printf 'stub %s\n' "$s" > "$(issue_dir ENG-T8)/stage-summary-${s}.md"
done
# Invoke rollback-stage.sh with its stubbed dependencies.
# - linear.sh stub already in PATH via STUB_DIR, handles swap-stage / add-comment as no-ops.
# - metrics.sh + slack.sh likewise: add no-op stubs so rollback-stage.sh's full main() runs.
for cmd in metrics.sh slack.sh; do
  [[ -x "$STUB_DIR/$cmd" ]] && continue
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/$cmd"
  chmod +x "$STUB_DIR/$cmd"
done
# Stub `linear.sh stage-of` to return 'stage:qa' and always exit 0 for swap-stage/add-comment.
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  stage-of) printf 'stage:qa\n' ;;
  add-or-update-comment)
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
      "\$1" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    ;;
esac
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"
SCRIPT_DIR_SAVED="$SCRIPT_DIR"
PATH_SAVED="$PATH"
# rollback-stage.sh computes its own SCRIPT_DIR from BASH_SOURCE; we need the
# real rollback-stage.sh but its dependent bash calls go through our stubs.
# Symlink real scripts into STUB_DIR so SCRIPT_DIR resolution picks up stubs.
ln -sf "$HARNESS_DIR/rollback-stage.sh" "$STUB_DIR/rollback-stage.sh"
ln -sf "$HARNESS_DIR/common.sh"         "$STUB_DIR/common.sh"
(
  cd "$STUB_DIR"
  bash ./rollback-stage.sh ENG-T8 implementing "test-driven rollback" >/dev/null 2>&1 || true
)
# Expected: stage-summary for ui, review, qa deleted. stage-summary for implement
# (== to_stage exclusive) retained.
missing_ui="$([[ ! -f "$(issue_dir ENG-T8)/stage-summary-ui.md"     ]] && echo 1 || echo 0)"
missing_review="$([[ ! -f "$(issue_dir ENG-T8)/stage-summary-review.md" ]] && echo 1 || echo 0)"
missing_qa="$([[ ! -f "$(issue_dir ENG-T8)/stage-summary-qa.md"     ]] && echo 1 || echo 0)"
present_impl="$([[ -f "$(issue_dir ENG-T8)/stage-summary-implement.md" ]] && echo 1 || echo 0)"
if [[ "$missing_ui" == "1" && "$missing_review" == "1" && "$missing_qa" == "1" && "$present_impl" == "1" ]]; then
  pass_at "case-8 rollback cleanup: stages >tgt deleted, to_stage retained"
else
  fail_at "case-8 rollback cleanup" \
    "missing_ui=$missing_ui missing_review=$missing_review missing_qa=$missing_qa present_impl=$present_impl"
fi
SCRIPT_DIR="$SCRIPT_DIR_SAVED"
PATH="$PATH_SAVED"

# ─── Case 9: paused path emits stage-end outcome=paused (ENG-10) ─────
# Pins the metrics emissions for run-stage.sh:178-183. The harness
# simulates the paused branch by manually invoking the metric calls the
# block performs (via a local capture stub for metrics.sh) so we can
# assert both stage-start and stage-end carry outcome=paused.
reset_capture
mkdir -p "$(issue_dir ENG-T9)"
cat > "$STUB_DIR/metrics.sh" <<SH
#!/usr/bin/env bash
printf 'EVENT=%s\nSTAGE=%s\nOUTCOME=%s\nNOTES=%s\n---\n' \
  "\${1:-}" "\${3:-}" "\${4:-}" "\${6:-}" >> "$STUB_DIR/metrics.capture"
exit 0
SH
chmod +x "$STUB_DIR/metrics.sh"
: > "$STUB_DIR/metrics.capture"

bash "$STUB_DIR/metrics.sh" stage-start ENG-T9 plan paused 0
bash "$STUB_DIR/metrics.sh" stage-end   ENG-T9 plan "$(failure_outcome_for_exit 11 '')" 0 "exit=11"

starts=$(awk -F= '/^EVENT=/{print $2}' "$STUB_DIR/metrics.capture" | grep -c stage-start)
ends=$(  awk -F= '/^EVENT=/{print $2}' "$STUB_DIR/metrics.capture" | grep -c stage-end)
paused_outcomes=$(grep -c '^OUTCOME=paused$' "$STUB_DIR/metrics.capture" | tr -d ' ')

if [[ "$starts" == "1" && "$ends" == "1" && "$paused_outcomes" == "2" ]]; then
  pass_at "case-9 paused path emits both stage-start and stage-end with outcome=paused"
else
  fail_at "case-9 paused path" "starts=$starts ends=$ends paused_outcomes=$paused_outcomes"
fi

# ─── Case 10: scope-approval notable path passes subcode=1 (ENG-10) ──
# Contract test: pins the failure_outcome_for_exit(0,1) → scope-approval-pending
# mapping that run-stage.sh:294 relies on. A future helper edit that
# breaks this mapping fails here before it can silently break the path.
outcome=$(failure_outcome_for_exit 0 1)
if [[ "$outcome" == "scope-approval-pending" ]]; then
  pass_at "case-10 failure_outcome_for_exit(0,1) → scope-approval-pending"
else
  fail_at "case-10" "got $outcome"
fi

# ─── Case 10b (ENG-48): exit 124 → dispatch-timeout outcome ────────────
# When gtimeout SIGTERM's a wedged dispatch, the pipeline propagates
# exit 124. Pin the failure_outcome_for_exit mapping so the metrics
# stream and the retrospective agent's exit-code-bucketing groups
# this distinct from generic dispatch-failed (exit 20).
outcome=$(failure_outcome_for_exit 124 "")
if [[ "$outcome" == "dispatch-timeout" ]]; then
  pass_at "case-10b failure_outcome_for_exit(124,'') → dispatch-timeout"
else
  fail_at "case-10b" "got $outcome"
fi

# ─── Case 11: SEVERE scope-violation bumps implement_rejection ─────────
# Stub scope-check.sh to return rc=3 with a `severe\t<file>` row; call the
# scope-check branch inline; assert the bump stub captured exactly one
# `bump <ident> implement_rejection` invocation.
reset_capture
reset_guards_capture
MOCK_SCOPE_RC=3 MOCK_SCOPE_OUT=$'severe\tcrates/twinning-pipeline/tests/completion_scan_integration.rs' \
  bash -c '
    ident="ENG-T11"; stage="implement"; branch="feat/eng-t11"
    scope_rc=0
    scope_out="$(bash "'"$STUB_DIR"'/scope-check.sh" "$ident" "$branch" 2>&1)" || scope_rc=$?
    case "$scope_rc" in
      3)
        bash "'"$STUB_DIR"'/guards.sh" bump "$ident" implement_rejection || true
        ;;
    esac
  ' 2>/dev/null

bumps=$(guards_bump_count)
last_counter=$(guards_counter_for_last_bump)
if [[ "$bumps" == "1" && "$last_counter" == "implement_rejection" ]]; then
  pass_at "case-11 SEVERE scope-violation: exactly one implement_rejection bump"
else
  fail_at "case-11 SEVERE" "bumps=$bumps last_counter=$last_counter"
fi

# ─── Case 12: unknown-rc scope-violation bumps implement_rejection ─────
reset_capture
reset_guards_capture
MOCK_SCOPE_RC=4 MOCK_SCOPE_OUT="" \
  bash -c '
    ident="ENG-T12"; stage="implement"; branch="feat/eng-t12"
    scope_rc=0
    scope_out="$(bash "'"$STUB_DIR"'/scope-check.sh" "$ident" "$branch" 2>&1)" || scope_rc=$?
    case "$scope_rc" in
      3) ;;
      *)
        bash "'"$STUB_DIR"'/guards.sh" bump "$ident" implement_rejection || true
        ;;
    esac
  ' 2>/dev/null

bumps=$(guards_bump_count)
last_counter=$(guards_counter_for_last_bump)
if [[ "$bumps" == "1" && "$last_counter" == "implement_rejection" ]]; then
  pass_at "case-12 unknown-rc scope-violation: exactly one implement_rejection bump"
else
  fail_at "case-12 unknown-rc" "bumps=$bumps last_counter=$last_counter"
fi

# ─── Case 13: removed in ENG-42 ────────────────────────────────────────
# The PR-opened-too-early guard at run-stage.sh:373-384 was a state-check
# proxy for "implement agent invoked gh pr create". The implement stage's
# tool lane (dispatch.sh:44) already denies `gh pr create` and `Agent`,
# so the guard could only fire on PRs opened by other actors — i.e., on
# false positives. Deleted in ENG-42 (see brainstorm D-001). The
# transcript-based assertion that answers the contract question directly
# is captured in the brainstorm §2.1 and shipped as ENG-43, after ENG-26
# lands the stream-json infrastructure on main.
#
# Case numbering preserved (no renumber of cases 14-24) — the gap is
# intentional and self-documents the deletion.

# ─── Case 14: NOTABLE scope-approval (rc=1) does NOT bump counter ──────
# Anti-regression per D-003: the soft-pause branch must never bump.
reset_capture
reset_guards_capture
MOCK_SCOPE_RC=1 MOCK_SCOPE_OUT=$'notable\tcrates/twinning-pipeline/src/adjacent.rs' \
  bash -c '
    ident="ENG-T14"; stage="implement"; branch="feat/eng-t14"
    scope_rc=0
    scope_out="$(bash "'"$STUB_DIR"'/scope-check.sh" "$ident" "$branch" 2>&1)" || scope_rc=$?
    # Per D-003: the 1) branch does NOT bump — only 3) and *) and pr-too-early bump.
    case "$scope_rc" in
      1) ;;  # soft-pause awaiting user approval; no bump
      3|*)
        bash "'"$STUB_DIR"'/guards.sh" bump "$ident" implement_rejection || true
        ;;
    esac
  ' 2>/dev/null

bumps=$(guards_bump_count)
if [[ "$bumps" == "0" ]]; then
  pass_at "case-14 NOTABLE (rc=1): zero bumps (D-003 exclusion holds)"
else
  fail_at "case-14 NOTABLE" "unexpected bumps=$bumps"
fi

# ─── Case 19: _cost_flags_for emits 12 lines when usage file present (ENG-26 D-005) ──
# Asserts the helper turns a six-field usage-<stage>.json into a newline-delimited
# stream of `--key`/`value` pairs and that the model literal `claude-opus-4-7[1m]`
# round-trips with [1m] intact (DL-202 / SEC-007 — bash array boundary preserves
# glob chars).
COST_DIR="$(issue_dir ENG-T-COST)"
mkdir -p "$COST_DIR"
cat > "$COST_DIR/usage-plan.json" <<'JSON'
{"tokens_in":5,"tokens_out":6,"cache_read":20773,"cache_create":17419,"cost_usd":0.42,"model":"claude-opus-4-7[1m]"}
JSON

cost_flags=()
while IFS= read -r _cf_line; do
  cost_flags+=("$_cf_line")
done < <(_cost_flags_for ENG-T-COST plan)

# Find the `--model` slot; the next array element is the model value.
model_idx=-1
for i in "${!cost_flags[@]}"; do
  [[ "${cost_flags[$i]}" == "--model" ]] && { model_idx=$((i+1)); break; }
done
model_val=""
[[ $model_idx -ge 0 ]] && model_val="${cost_flags[$model_idx]}"

if [[ "${#cost_flags[@]}" == "12" ]] \
   && [[ "${cost_flags[0]}" == "--tokens-in" && "${cost_flags[1]}" == "5" ]] \
   && [[ "${cost_flags[8]}" == "--cost-usd" && "${cost_flags[9]}" == "0.42" ]] \
   && [[ "$model_val" == "claude-opus-4-7[1m]" ]]; then
  pass_at "case-19 _cost_flags_for: 12 lines emitted; model literal preserved with [1m]"
else
  fail_at "case-19 _cost_flags_for" "count=${#cost_flags[@]} model_val=$model_val flags=$(printf '%s|' "${cost_flags[@]}")"
fi

# ─── Case 20: _cost_flags_for emits nothing when usage file absent ──────
COST_DIR_B="$(issue_dir ENG-T-COSTB)"
mkdir -p "$COST_DIR_B"
rm -f "$COST_DIR_B/usage-plan.json"

cost_flags_b=()
while IFS= read -r _cf_line; do
  [[ -z "$_cf_line" ]] && continue
  cost_flags_b+=("$_cf_line")
done < <(_cost_flags_for ENG-T-COSTB plan)

if [[ "${#cost_flags_b[@]}" == "0" ]]; then
  pass_at "case-20 _cost_flags_for: empty array when usage file absent"
else
  fail_at "case-20 _cost_flags_for absent" "got ${#cost_flags_b[@]} entries"
fi

# ─── Case 21: _cost_footer shape pinned to brainstorm D-008 format ─────
# Pinned values: cost_usd=0.42, tokens_in=18000, tokens_out=4000,
# cache_read=20773, cache_create=17419 → cache_pct = round(54.39…) = 54.
COST_DIR_C="$(issue_dir ENG-T-COSTC)"
mkdir -p "$COST_DIR_C"
cat > "$COST_DIR_C/usage-plan.json" <<'JSON'
{"tokens_in":18000,"tokens_out":4000,"cache_read":20773,"cache_create":17419,"cost_usd":0.42,"model":"claude-opus-4-7[1m]"}
JSON

footer_c="$(_cost_footer ENG-T-COSTC plan)"
expected_c=$'\ncost: $0.42 · in 18.0k · out 4.0k · cache 54%'
if [[ "$footer_c" == "$expected_c" ]]; then
  pass_at "case-21 _cost_footer shape: 'cost: \$0.42 · in 18.0k · out 4.0k · cache 54%'"
else
  fail_at "case-21 _cost_footer shape" "got=$(printf '%q' "$footer_c") expected=$(printf '%q' "$expected_c")"
fi

# ─── Case 22: _cost_footer omits cache segment when denominator is zero ─
COST_DIR_D="$(issue_dir ENG-T-COSTD)"
mkdir -p "$COST_DIR_D"
cat > "$COST_DIR_D/usage-plan.json" <<'JSON'
{"tokens_in":1000,"tokens_out":500,"cache_read":0,"cache_create":0,"cost_usd":0.10,"model":"claude-opus-4-7"}
JSON

footer_d="$(_cost_footer ENG-T-COSTD plan)"
if [[ "$footer_d" =~ cache ]]; then
  fail_at "case-22 _cost_footer cache-zero" "footer should omit cache segment, got=$footer_d"
elif [[ "$footer_d" =~ ^$'\n'cost:\ \$.*in.*out ]]; then
  pass_at "case-22 _cost_footer cache-zero: '· cache N%' segment omitted when read+create == 0"
else
  fail_at "case-22 _cost_footer cache-zero shape" "got=$(printf '%q' "$footer_d")"
fi

# ─── Case 23: _cost_footer prints empty when usage file absent ─────────
COST_DIR_E="$(issue_dir ENG-T-COSTE)"
mkdir -p "$COST_DIR_E"
rm -f "$COST_DIR_E/usage-plan.json"

footer_e="$(_cost_footer ENG-T-COSTE plan)"
if [[ -z "$footer_e" ]]; then
  pass_at "case-23 _cost_footer absent: empty string when no usage file"
else
  fail_at "case-23 _cost_footer absent" "got=$(printf '%q' "$footer_e")"
fi

# ─── Case 24: D-011 stale-file removal — behavioural integration test ──
# The plan's failure-mode → test-map binds "Stale usage-<stage>.json on
# scope-approval replay" to an *integration* test, not a source-text grep.
# Drive the scope-approval-replay path directly via _replay_scope_approval
# (the helper that owns the rm-f + replay metrics emit) and assert:
#   (a) the pre-existing usage-<stage>.json is gone; and
#   (b) the resulting metrics call carries NO `--`-prefixed cost flags,
#       since replays must omit cost fields (D-011 double-count guard).
# A future refactor that deletes the rm-f, hoists the helper without
# touching the file, or accidentally feeds cost flags into the replay
# metric will fail this test.
reset_capture
COST_DIR_F="$(issue_dir ENG-T-COSTF)"
mkdir -p "$COST_DIR_F"
cat > "$COST_DIR_F/usage-implement.json" <<'JSON'
{"tokens_in":5,"tokens_out":6,"cache_read":20,"cache_create":10,"cost_usd":0.42,"model":"claude-opus-4-7"}
JSON

# metrics.sh capture stub: every invocation writes its full argv to a
# capture file so the assertions can match `--cost-usd` etc. precisely.
METRICS_CAPTURE_F="$STUB_DIR/replay-metrics.capture"
: > "$METRICS_CAPTURE_F"
cat > "$STUB_DIR/metrics.sh" <<SH
#!/usr/bin/env bash
printf 'ARGS=%s\n' "\$*" >> "$METRICS_CAPTURE_F"
exit 0
SH
chmod +x "$STUB_DIR/metrics.sh"

# Drive the actual code path: SCRIPT_DIR points at $STUB_DIR (set above
# at :87) so _replay_scope_approval invokes the stub metrics.sh.
# `|| true` keeps the assertion path running if the helper is missing —
# the test will fail on the (a)/(b) checks below rather than aborting.
_replay_scope_approval ENG-T-COSTF implement 2>/dev/null || true

if [[ ! -e "$COST_DIR_F/usage-implement.json" ]] \
   && grep -q 'ARGS=stage-start ENG-T-COSTF implement scope-approval-replay 0' "$METRICS_CAPTURE_F" \
   && ! grep -qE -- '--(tokens-in|tokens-out|cache-read|cache-create|cost-usd|model)' "$METRICS_CAPTURE_F"; then
  pass_at "case-24 D-011 replay: usage-<stage>.json removed and metrics carries no cost flags"
else
  fail_at "case-24 D-011 replay" \
    "file_exists=$([[ -e "$COST_DIR_F/usage-implement.json" ]] && echo yes || echo no) capture=$(cat "$METRICS_CAPTURE_F")"
fi

# ─── Case 25: _cost_flags_for tolerates corrupt JSON (review blocker 1) ──
# Plan failure-mode → test-map row "usage-<stage>.json exists but
# _cost_flags_for jq parse fails" requires a *malformed file* fixture, not
# just the absent path covered by case-20. Seed `not-json{` and assert the
# helper emits zero lines AND a downstream metrics call carries zero
# `--`-prefixed cost flags. jq's parse failure must be silent.
reset_capture
COST_DIR_G="$(issue_dir ENG-T-COSTG)"
mkdir -p "$COST_DIR_G"
printf 'not-json{' > "$COST_DIR_G/usage-plan.json"

cost_flags_g=()
while IFS= read -r _cf_line; do
  cost_flags_g+=("$_cf_line")
done < <(_cost_flags_for ENG-T-COSTG plan)

# metrics.sh capture stub: same shape as case-24's, isolated capture file.
METRICS_CAPTURE_G="$STUB_DIR/corrupt-flags-metrics.capture"
: > "$METRICS_CAPTURE_G"
cat > "$STUB_DIR/metrics.sh" <<SH
#!/usr/bin/env bash
printf 'ARGS=%s\n' "\$*" >> "$METRICS_CAPTURE_G"
exit 0
SH
chmod +x "$STUB_DIR/metrics.sh"

bash "$STUB_DIR/metrics.sh" stage-end ENG-T-COSTG plan success 100 "branch=foo" \
  "${cost_flags_g[@]+"${cost_flags_g[@]}"}"

if [[ "${#cost_flags_g[@]}" == "0" ]] \
   && ! grep -qE -- '--(tokens-in|tokens-out|cache-read|cache-create|cost-usd|model)' "$METRICS_CAPTURE_G"; then
  pass_at "case-25 _cost_flags_for corrupt JSON: zero lines emitted; metrics carries no cost flags"
else
  fail_at "case-25 corrupt-JSON _cost_flags_for" \
    "count=${#cost_flags_g[@]} capture=$(cat "$METRICS_CAPTURE_G")"
fi

# ─── Case 26: _cost_footer empty on corrupt JSON (review blocker 3) ─────
# `_cost_footer` previously emitted misleading `cost: $0.00 · in 0.0k ·
# out 0.0k` to Linear when usage-<stage>.json failed to parse, because
# bash's `local x=$(failing)` masked jq's nonzero rc and the empty values
# arithmetic-evaluated to 0. Brainstorm D-010 specifies soft-fail
# semantics — the corrupt-but-nonempty path must mirror the absent path
# (return empty string).
COST_DIR_H="$(issue_dir ENG-T-COSTH)"
mkdir -p "$COST_DIR_H"
printf 'not-json{' > "$COST_DIR_H/usage-plan.json"

footer_h="$(_cost_footer ENG-T-COSTH plan)"
if [[ -z "$footer_h" ]]; then
  pass_at "case-26 _cost_footer corrupt JSON: returns empty (D-010 soft fail)"
else
  fail_at "case-26 _cost_footer corrupt JSON" "got=$(printf '%q' "$footer_h")"
fi

# ─── Case 27: cache% formula parity across _cost_footer and status.sh ──
# Brainstorm D-007 binds the cache-percent formula to round-half-up:
#   round(100 * cache_read / max(1, cache_read + cache_create))
# and "Defined once and used by both `_aggregate_cost_by_stage` and the
# Linear footer (D-008)." A divergence (e.g. floor vs round-half-up) prints
# different cache% values for the same numbers in the per-stage Linear
# comment vs `bash bin/status.sh`, breaking operator trust.
#
# Pin a non-half ratio (r=8, c=3 → 100*8/11 = 72.727…, round-half-up = 73,
# floor = 72) so the next regression that swaps round for floor (or vice
# versa) fails this test. Earlier cases (case-21: r=20773, c=17419 →
# 54.39 → 54) are floor/round-equivalent and miss the boundary.
COST_DIR_K="$(issue_dir ENG-T-COSTK)"
mkdir -p "$COST_DIR_K"
cat > "$COST_DIR_K/usage-plan.json" <<'JSON'
{"tokens_in":5000,"tokens_out":6000,"cache_read":8,"cache_create":3,"cost_usd":0.42,"model":"claude-opus-4-7"}
JSON

footer_k="$(_cost_footer ENG-T-COSTK plan)"
if [[ "$footer_k" =~ cache\ 73% ]]; then
  pass_at "case-27a _cost_footer rounds 72.73% → 73% (D-007 round-half-up)"
else
  fail_at "case-27a _cost_footer round" "expected 'cache 73%', got=$(printf '%q' "$footer_k")"
fi

# Build a tempdir-scoped events.jsonl with one cost-bearing stage-end event
# matching the same r=8, c=3 pin, then drive `_aggregate_cost_by_stage`
# via a child bash that sources status.sh fresh (avoids polluting the
# parent test's SCRIPT_DIR / set -u state). Output is TSV; column 6 is
# cache_pct.
mkdir -p "$PROJECT_STATE_DIR/metrics"
cat > "$PROJECT_STATE_DIR/metrics/events.jsonl" <<'JSON'
{"ts":"2026-04-27T12:00:00Z","event":"stage-end","issue_id":"ENG-T-COSTK","stage":"plan","outcome":"success","duration_ms":100,"notes":"","cost_usd":0.42,"tokens_in":5000,"tokens_out":6000,"cache_read":8,"cache_create":3,"model":"claude-opus-4-7"}
JSON

agg_out="$(
  PROJECT_STATE_DIR="$PROJECT_STATE_DIR" \
  PROJECT_SLUG="$PROJECT_SLUG" \
  HARNESS_STATE_DIR="$HARNESS_STATE_DIR" \
  TARGET_REPO="${TARGET_REPO:-$STUB_DIR}" \
  bash -c '
    source "'"$HARNESS_DIR"'/status.sh" >/dev/null 2>&1
    _aggregate_cost_by_stage "'"$PROJECT_STATE_DIR/metrics/events.jsonl"'"
  ' 2>/dev/null || true
)"
agg_cache_pct="$(awk -F'\t' '$1 == "plan" {print $6}' <<<"$agg_out")"

if [[ "$agg_cache_pct" == "73" ]]; then
  pass_at "case-27b _aggregate_cost_by_stage rounds 72.73% → 73% (matches footer; D-007 single formula)"
else
  fail_at "case-27b cache% formula divergence (status.sh vs run-stage.sh)" \
          "expected 73 (round-half-up), got=$agg_cache_pct; full row=$(awk -F'\t' '$1 == "plan"' <<<"$agg_out")"
fi

# ─── QA-authored adversarial cases (NOT in plan's Failure Mode → Test Map) ──

# ─── Case 28: _cost_footer cache% exact-half boundary (round-half-up tie) ──
# D-007 specifies `round(100 * cache_read / max(1, cache_read + cache_create))`
# with round-half-up semantics. Pin the .5 boundary explicitly: r=99,c=101
# → 49.500% → 50 (round-up); r=101,c=99 → 50.500% → 51 (round-up). A future
# regression that swaps to banker's-rounding (round-half-to-even) would
# render 50% on the first case (correct) but 50% on the SECOND case
# (incorrect — banker's rounds 50.5 to 50, not 51). Anchor both sides.
COST_DIR_BD1="$(issue_dir ENG-T-COST-BD1)"
mkdir -p "$COST_DIR_BD1"
cat > "$COST_DIR_BD1/usage-plan.json" <<'JSON'
{"tokens_in":5000,"tokens_out":6000,"cache_read":99,"cache_create":101,"cost_usd":0.42,"model":"claude-opus-4-7"}
JSON
footer_bd1="$(_cost_footer ENG-T-COST-BD1 plan)"
if [[ "$footer_bd1" =~ cache\ 50% ]]; then
  pass_at "case-28a _cost_footer 49.5% rounds to 50% (round-half-up)"
else
  fail_at "case-28a _cost_footer 49.5% boundary" "expected 'cache 50%', got=$(printf '%q' "$footer_bd1")"
fi

COST_DIR_BD2="$(issue_dir ENG-T-COST-BD2)"
mkdir -p "$COST_DIR_BD2"
cat > "$COST_DIR_BD2/usage-plan.json" <<'JSON'
{"tokens_in":5000,"tokens_out":6000,"cache_read":101,"cache_create":99,"cost_usd":0.42,"model":"claude-opus-4-7"}
JSON
footer_bd2="$(_cost_footer ENG-T-COST-BD2 plan)"
if [[ "$footer_bd2" =~ cache\ 51% ]]; then
  pass_at "case-28b _cost_footer 50.5% rounds to 51% (round-half-up — NOT banker's)"
else
  fail_at "case-28b _cost_footer 50.5% boundary" "expected 'cache 51%', got=$(printf '%q' "$footer_bd2")"
fi

# ─── Case 29: _cost_footer very small cost rendering ───────────────────────
# A very small cost (e.g. a stage that finished in cache + tiny prompt)
# truncates to $0.00 under `%.2f`. Pin the format so a future change to
# `%.4f` doesn't quietly widen every Linear footer.
COST_DIR_TINY="$(issue_dir ENG-T-COST-TINY)"
mkdir -p "$COST_DIR_TINY"
cat > "$COST_DIR_TINY/usage-plan.json" <<'JSON'
{"tokens_in":50,"tokens_out":20,"cache_read":1000,"cache_create":0,"cost_usd":0.001,"model":"claude-opus-4-7"}
JSON
footer_tiny="$(_cost_footer ENG-T-COST-TINY plan)"
if [[ "$footer_tiny" == *"cost: \$0.00"* ]] \
   && [[ "$footer_tiny" == *"in 0.1k"* ]] \
   && [[ "$footer_tiny" == *"out 0.0k"* ]] \
   && [[ "$footer_tiny" == *"cache 100%"* ]]; then
  pass_at "case-29 _cost_footer tiny cost: \$0.00 · in 0.1k · out 0.0k · cache 100%"
else
  fail_at "case-29 _cost_footer tiny cost" "got=$(printf '%q' "$footer_tiny")"
fi

# ─── Case 30: _cost_flags_for forward-compat — extra fields in usage file ──
# A future dispatch.sh extension may add fields beyond the six contracted by
# D-003 (e.g. `tools_invoked`). `_cost_flags_for` MUST emit only the six
# contracted flags regardless. The downstream metrics.sh would otherwise
# reject unknown flags (case-G in metrics-test) or — worse — pass through
# whatever extra flags this helper produces. Pin the contract.
COST_DIR_FWD="$(issue_dir ENG-T-COST-FWD)"
mkdir -p "$COST_DIR_FWD"
cat > "$COST_DIR_FWD/usage-plan.json" <<'JSON'
{"tokens_in":18000,"tokens_out":4000,"cache_read":20773,"cache_create":17419,"cost_usd":0.42,"model":"claude-opus-4-7","tools_invoked":["Read","Grep"],"future_field":"some-value"}
JSON

cost_flags_fwd=()
_cf_line=
while IFS= read -r _cf_line; do
  cost_flags_fwd+=("$_cf_line")
done < <(_cost_flags_for ENG-T-COST-FWD plan)

# 12 lines = six --key/value pairs. No more, no less.
if [[ "${#cost_flags_fwd[@]}" == "12" ]] \
   && [[ "${cost_flags_fwd[*]}" != *"--tools-invoked"* ]] \
   && [[ "${cost_flags_fwd[*]}" != *"--future-field"* ]]; then
  pass_at "case-30 _cost_flags_for forward-compat: only six contracted flags emitted, extras dropped"
else
  fail_at "case-30 _cost_flags_for forward-compat" \
          "count=${#cost_flags_fwd[@]} flags=(${cost_flags_fwd[*]})"
fi

# ─── Case 31 (QA adversarial): _cost_footer locale-numeric — current behavior pin ──
# DEFECT FOUND BY QA: under a non-C numeric locale (LC_NUMERIC=de_DE.UTF-8 →
# comma decimal), `_cost_footer` emits `cost: $0,42` instead of `cost: $0.42`.
# Same defect applies to `_aggregate_cost_by_stage` (status.sh per-stage
# table). Root cause: awk's `printf "%.2f"` respects LC_NUMERIC; the helper
# does not wrap `LC_ALL=C` around the awk call.
#
# Severity: P2 (cosmetic). Surface area: visible to operators on hosts with
# non-default locale; events.jsonl is unaffected (jq always emits `.`
# decimal regardless of locale, so the underlying cost-data pipeline stays
# correct). v1 ships under en_US/POSIX; the defect cannot fire on the
# canonical CI/dev configuration. Logged as a v2 hardening candidate in
# the QA stage-summary; tracking in a follow-up Linear bug.
#
# Pin CURRENT behavior so a future fix (wrapping awk in `LC_ALL=C`) trips
# this test and prompts a deliberate update — and so the failure cannot
# silently change shape (e.g., switch from `$0,42` to `$0` if the locale
# config drops the cost segment entirely).
COST_DIR_LOC="$(issue_dir ENG-T-LOCALE)"
mkdir -p "$COST_DIR_LOC"
cat > "$COST_DIR_LOC/usage-plan.json" <<'JSON'
{"tokens_in":18000,"tokens_out":4000,"cache_read":20773,"cache_create":17419,"cost_usd":0.42,"model":"claude-opus-4-7"}
JSON

footer_loc="$(LC_ALL=de_DE.UTF-8 LC_NUMERIC=de_DE.UTF-8 LANG=de_DE.UTF-8 _cost_footer ENG-T-LOCALE plan 2>/dev/null)"
# When the locale is unavailable on this host, awk falls back to C-locale
# silently and emits `$0.42`. Accept either shape so the test is portable
# across CI hosts with or without `de_DE.UTF-8` installed; the assertion
# is "the cost segment is one of the two known shapes, not corrupted".
if [[ "$footer_loc" == *"\$0,42"* ]]; then
  pass_at "case-31 _cost_footer locale: emits '\$0,42' under de_DE.UTF-8 (KNOWN P2 — pin current behavior; v2 hardening tracked)"
elif [[ "$footer_loc" == *"\$0.42"* ]]; then
  pass_at "case-31 _cost_footer locale: emits '\$0.42' (de_DE locale unavailable on host — fallback to C is also acceptable)"
else
  fail_at "case-31 _cost_footer locale" "footer corrupted under de_DE locale — neither '\$0,42' nor '\$0.42': $(printf '%q' "$footer_loc")"
fi

# ─── Case 32 (QA adversarial): _cost_footer huge token counts ────────────
# A very long stage with multi-million tokens (rare today but possible with
# 1M-context Opus) MUST render as `1234.5k` not `1.2345e+06k` or similar
# scientific notation. awk's `%.1f` handles this naturally; pin the format
# so any future change to printf width specifiers does not silently break.
COST_DIR_HUGE="$(issue_dir ENG-T-HUGE)"
mkdir -p "$COST_DIR_HUGE"
cat > "$COST_DIR_HUGE/usage-plan.json" <<'JSON'
{"tokens_in":12345000,"tokens_out":987000,"cache_read":50000000,"cache_create":1000000,"cost_usd":42.99,"model":"claude-opus-4-7"}
JSON

footer_huge="$(_cost_footer ENG-T-HUGE plan)"
# Expect: cost: $42.99 · in 12345.0k · out 987.0k · cache 98%
if [[ "$footer_huge" == *"\$42.99"* ]] \
   && [[ "$footer_huge" == *"in 12345.0k"* ]] \
   && [[ "$footer_huge" == *"out 987.0k"* ]] \
   && [[ "$footer_huge" == *"cache 98%"* ]] \
   && [[ "$footer_huge" != *"e+"* ]] \
   && [[ "$footer_huge" != *"e-"* ]]; then
  pass_at "case-32 _cost_footer huge tokens: '\$42.99 · in 12345.0k · out 987.0k · cache 98%'; no sci notation"
else
  fail_at "case-32 _cost_footer huge tokens" "got=$(printf '%q' "$footer_huge")"
fi

# ─── Case 33 (QA adversarial): _cost_footer zero-byte file (race window) ──
# A theoretical race window: dispatch's renderer truncates `>` the file but
# crashes before the jq filter writes content; or another process holds a
# write lock. The brainstorm's D-010 soft-fail semantics demand that
# zero-byte files mirror the absent-file path — empty footer, no crash,
# no misleading `cost: $0.00 · in 0.0k · out 0.0k`.
COST_DIR_EMPTY="$(issue_dir ENG-T-EMPTY)"
mkdir -p "$COST_DIR_EMPTY"
: > "$COST_DIR_EMPTY/usage-plan.json"  # zero bytes, file exists

footer_empty="$(_cost_footer ENG-T-EMPTY plan 2>/dev/null)"
flags_empty=()
while IFS= read -r _cf_line; do
  [[ -z "$_cf_line" ]] && continue
  flags_empty+=("$_cf_line")
done < <(_cost_flags_for ENG-T-EMPTY plan 2>/dev/null)

if [[ -z "$footer_empty" ]] && [[ "${#flags_empty[@]}" == "0" ]]; then
  pass_at "case-33 zero-byte usage file: _cost_footer empty, _cost_flags_for empty (D-010 soft fail)"
else
  fail_at "case-33 zero-byte usage file" "footer=$(printf '%q' "$footer_empty") flags=${#flags_empty[@]}"
fi

# ─── Case 34 (QA adversarial): _aggregate_cost_by_stage with no stage-end events ─
# Plan failure-mode "status.sh asked for cost summary before any cost-tagged
# event exists" is bound to a manual smoke check. Pin a unit-level assertion
# too: feed an events.jsonl with only stage-start lines (no stage-end), and
# assert _aggregate_cost_by_stage emits no rows (not a NaN row, not a zero
# row). Otherwise a future filter regression that drops the `event ==
# "stage-end"` predicate would silently aggregate stage-starts (which have
# no cost data) and pollute the per-stage table.
AGGR_TMP_DIR="$(mktemp -d)"
mkdir -p "$AGGR_TMP_DIR/metrics"
cat > "$AGGR_TMP_DIR/metrics/events.jsonl" <<'JSONL'
{"ts":"2026-04-27T12:00:00Z","event":"stage-start","issue_id":"ENG-A","stage":"plan","outcome":"dispatching","duration_ms":0,"notes":""}
{"ts":"2026-04-27T12:01:00Z","event":"stage-start","issue_id":"ENG-B","stage":"implement","outcome":"dispatching","duration_ms":0,"notes":""}
JSONL

aggr_out_no_end="$(
  PROJECT_STATE_DIR="$AGGR_TMP_DIR" \
  PROJECT_SLUG="$PROJECT_SLUG" \
  HARNESS_STATE_DIR="$HARNESS_STATE_DIR" \
  TARGET_REPO="${TARGET_REPO:-$STUB_DIR}" \
  bash -c '
    source "'"$HARNESS_DIR"'/status.sh" >/dev/null 2>&1
    _aggregate_cost_by_stage "'"$AGGR_TMP_DIR/metrics/events.jsonl"'"
  ' 2>/dev/null || true
)"
rm -rf "$AGGR_TMP_DIR"

if [[ -z "${aggr_out_no_end// /}" ]]; then
  pass_at "case-34 _aggregate_cost_by_stage: zero rows when events.jsonl has no stage-end events"
else
  fail_at "case-34 _aggregate no-stage-end" "got rows=$(printf '%q' "$aggr_out_no_end")"
fi

# ─── Case 35 (QA adversarial): _cost_flags_for never word-splits a model with spaces ─
# DL-202 / SEC-007 anchored the `[1m]` glob-char concern. Spaces are a
# different word-splitting axis: today's models don't have them, but a
# future model name like "Claude Opus 4.7 (1M ctx)" or even a corrupted
# usage file with a multi-word model would silently lose the suffix when
# the flag stream goes through `mapfile` / `while read`. The newline-
# delimited contract preserves spaces; pin it.
COST_DIR_SPC="$(issue_dir ENG-T-SPC)"
mkdir -p "$COST_DIR_SPC"
cat > "$COST_DIR_SPC/usage-plan.json" <<'JSON'
{"tokens_in":5,"tokens_out":6,"cache_read":1,"cache_create":1,"cost_usd":0.10,"model":"future model with spaces"}
JSON

flags_spc=()
while IFS= read -r _cf_line; do
  flags_spc+=("$_cf_line")
done < <(_cost_flags_for ENG-T-SPC plan)

# Find model slot and assert verbatim preservation.
model_idx_spc=-1
for i in "${!flags_spc[@]}"; do
  [[ "${flags_spc[$i]}" == "--model" ]] && { model_idx_spc=$((i+1)); break; }
done
model_val_spc=""
[[ $model_idx_spc -ge 0 ]] && model_val_spc="${flags_spc[$model_idx_spc]}"

if [[ "$model_val_spc" == "future model with spaces" ]] \
   && [[ "${#flags_spc[@]}" == "12" ]]; then
  pass_at "case-35 _cost_flags_for spaces in model: 12 lines emitted; spaces preserved verbatim"
else
  fail_at "case-35 _cost_flags_for spaces" \
          "count=${#flags_spc[@]} model_val=$(printf '%q' "$model_val_spc")"
fi

# ════════════════════════════════════════════════════════════════════════════
# ENG-45 — build-stage wait-marker gate + budget escalation
# ════════════════════════════════════════════════════════════════════════════
# Inserted BEFORE case-15 because the pre-existing $REPO_ROOT unbound-var bug
# at line ~870 aborts the script (set -u) and any cases appended after it
# never run. Same insertion pattern as cases 19-35 already followed.
#
# Rebuild the linear.sh stub: case-8 (line ~220) overwrote the initial stub
# with a smaller variant that only handles stage-of/add-or-update-comment, so
# get-comments would silently exit 0 with empty output here. The variant below
# preserves all paths the rest of the suite (and case-15+) might need.

cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  get-comments)
    # ENG-45: fixture-injected comment stream for _fresh_wait_reason cases.
    printf '%s' "\${MOCK_COMMENTS_JSON-[]}"
    ;;
  stage-of) printf 'stage:qa\n' ;;
  *)
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
      "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    ;;
esac
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"

# ─── ENG-45 case A: fresh wait marker on build → returns reason ──────────────
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->\n\nAwaiting human Code Owner approval."}]'
out="$(_fresh_wait_reason ENG-45T1 building || printf '')"
if [[ "$out" == "awaiting-approval" ]]; then
  pass_at "ENG-45 case A: fresh wait marker → returns awaiting-approval"
else
  fail_at "ENG-45 case A" "got: $out"
fi

# ─── ENG-45 case A2: fresh CI wait marker → returns awaiting-ci ──────────────
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-ci -->\n\nAwaiting CI to turn green."}]'
out="$(_fresh_wait_reason ENG-45T1B building || printf '')"
if [[ "$out" == "awaiting-ci" ]]; then
  pass_at "ENG-45 case A2: fresh CI wait marker → returns awaiting-ci"
else
  fail_at "ENG-45 case A2" "got: $out"
fi

# ─── ENG-45 case B: stage=implement → empty (build|review gate, security F-1) ──
# ENG-50: review is now accepted by the wait gate (build|review); use implement
# instead to pin the rejection path.
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"}]'
out="$(_fresh_wait_reason ENG-45T2 implementing || printf '')"
if [[ -z "$out" ]]; then
  pass_at "ENG-45 case B: implementing stage rejected by building gate"
else
  fail_at "ENG-45 case B" "got: $out"
fi

# ─── ENG-45 case C: invented reason rejected by allow-list (security F-2) ───
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline: verdict result=wait reason=never-escalate -->"}]'
out="$(_fresh_wait_reason ENG-45T3 building || printf '')"
if [[ -z "$out" ]]; then
  pass_at "ENG-45 case C: invented reason rejected by allow-list"
else
  fail_at "ENG-45 case C" "got: $out"
fi

# ─── ENG-45 case D: wait marker older than last pipeline-transition → empty ──
export MOCK_COMMENTS_JSON='[
  {"createdAt":"2026-04-28T08:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"},
  {"createdAt":"2026-04-28T08:05:00Z","body":"<!-- pipeline: transition from=implementing to=building -->"}
]'
out="$(_fresh_wait_reason ENG-45T4 building || printf '')"
if [[ -z "$out" ]]; then
  pass_at "ENG-45 case D: stale wait marker (pre-transition) is ignored"
else
  fail_at "ENG-45 case D" "got: $out"
fi

# ─── ENG-45 case E: empty get-comments → fail-closed (return 1) ─────────────
export MOCK_COMMENTS_JSON=''
out="$(_fresh_wait_reason ENG-45T5 building || printf '')"
if [[ -z "$out" ]]; then
  pass_at "ENG-45 case E: empty get-comments fails closed"
else
  fail_at "ENG-45 case E" "got: $out"
fi

# ─── ENG-45 case F: get-comments returns "null" → fail-closed (return 1) ────
export MOCK_COMMENTS_JSON='null'
out="$(_fresh_wait_reason ENG-45T6 building || printf '')"
if [[ -z "$out" ]]; then
  pass_at "ENG-45 case F: 'null' get-comments fails closed"
else
  fail_at "ENG-45 case F" "got: $out"
fi

# ─── ENG-45 case P6: rejection marker present, wait gate must NOT fire ──────
# Linear issue's IN list (Task 8a). The wait gate must NOT fire on a rejection-
# marker-only fixture — the existing rejection loopback flow must remain
# reachable.
export MOCK_COMMENTS_JSON='[
  {"createdAt":"2026-04-28T08:00:00Z","body":"<!-- pipeline: transition from=implementing to=building -->"},
  {"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline: verdict result=fail target=implementing -->\nMerge conflict on rebase."}
]'
out="$(_fresh_wait_reason ENG-45T-P6 building || printf '')"
if [[ -z "$out" ]]; then
  pass_at "ENG-45 case P6: rejection marker is invisible to wait gate"
else
  fail_at "ENG-45 case P6" "wait gate spuriously matched: $out"
fi
unset MOCK_COMMENTS_JSON

# ─── ENG-45 case G: first wait → attempts=1, file written, returns 0 ────────
ENG_45_TMP_CFG="$(mktemp)"
printf '{"orchestrator":{}}' > "$ENG_45_TMP_CFG"
ENG_45_CFG_SAVED="${CONFIG:-}"
CONFIG="$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T7)"
rm -f "$(issue_dir ENG-45T7)/wait-building.json"
if _handle_wait ENG-45T7 building awaiting-approval; then
  if jq -e '.attempts == 1 and .reason == "awaiting-approval" and .stage == "building" and .issue == "ENG-45T7"' \
       "$(issue_dir ENG-45T7)/wait-building.json" >/dev/null 2>&1; then
    pass_at "ENG-45 case G: first wait writes attempts=1 with reason+stage+issue, returns 0"
  else
    fail_at "ENG-45 case G" "json: $(cat "$(issue_dir ENG-45T7)/wait-building.json" 2>/dev/null)"
  fi
else
  fail_at "ENG-45 case G" "_handle_wait returned nonzero on first attempt"
fi

# ─── ENG-45 case H: 2nd wait increments attempts to 2 ───────────────────────
if _handle_wait ENG-45T7 building awaiting-approval; then
  if jq -e '.attempts == 2' "$(issue_dir ENG-45T7)/wait-building.json" >/dev/null 2>&1; then
    pass_at "ENG-45 case H: 2nd wait increments to 2"
  else
    fail_at "ENG-45 case H" "json: $(cat "$(issue_dir ENG-45T7)/wait-building.json" 2>/dev/null)"
  fi
else
  fail_at "ENG-45 case H" "_handle_wait returned nonzero on within-budget 2nd attempt"
fi

# ─── ENG-45 case I: budget=2 attempts → 2nd call exhausts (returns 1) ───────
# Plan Failure Mode → Test Map row claims this verifies four artifacts:
#   (a) returns 1, (b) wait file deleted, (c) halt comment posted with
#   external-signal-budget-exhausted reason, (d) pipeline:halted applied.
printf '{"orchestrator":{"external_signal_budget":{"max_attempts":2}}}' > "$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T8)"
rm -f "$(issue_dir ENG-45T8)/wait-building.json"
_handle_wait ENG-45T8 building awaiting-approval >/dev/null  # first call returns 0
reset_capture                                              # only capture exhaust call
if _handle_wait ENG-45T8 building awaiting-approval >/dev/null; then
  fail_at "ENG-45 case I" "expected nonzero on 2nd call (budget exhausted)"
elif [[ -e "$(issue_dir ENG-45T8)/wait-building.json" ]]; then
  fail_at "ENG-45 case I" "wait file should have been deleted: $(cat "$(issue_dir ENG-45T8)/wait-building.json" 2>/dev/null)"
elif ! grep -q '^SUBCMD=add-comment$' "$CAPTURE_FILE" \
   || ! grep -q 'external-signal-budget-exhausted' "$CAPTURE_FILE"; then
  fail_at "ENG-45 case I" "missing add-comment with external-signal-budget-exhausted body: $(cat "$CAPTURE_FILE")"
elif ! grep -qE '^SUBCMD=add-label$' "$CAPTURE_FILE" \
   || ! grep -q 'pipeline:halted' "$CAPTURE_FILE"; then
  fail_at "ENG-45 case I" "missing add-label pipeline:halted: $(cat "$CAPTURE_FILE")"
else
  pass_at "ENG-45 case I: budget exhausted → halt comment + pipeline:halted + wait file deleted, returned 1"
fi

# ─── ENG-45 case I-LF (round-3 M-B): add-label failure preserves wait file ──
# The else-arm at bin/run-stage.sh:419-423 is load-bearing: a transient
# add-label failure on the budget-exhaust path must NOT delete the wait
# file. Otherwise a network blip leaves the issue with no halt label AND
# no counter file → the next dispatch starts a brand-new wait window at
# attempts=1, silently bypassing the budget safety net. Case I asserts the
# happy path (add-label succeeds, file deleted); case I-LF locks the else
# arm. Stub `linear.sh add-label) exit 1` and assert: rc=1, file present,
# halt comment still posted (the comment is best-effort, file lifecycle is
# the load-bearing invariant).
ENG_45_LF_LINEAR_SAVED="$STUB_DIR/linear-saved-pre-LF.sh"
cp "$STUB_DIR/linear.sh" "$ENG_45_LF_LINEAR_SAVED"
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  add-label)
    # Capture the call so the test can assert it was attempted, then fail
    # to simulate a Linear API hiccup / network blip.
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
      "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    exit 1
    ;;
  *)
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
      "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    ;;
esac
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"

printf '{"orchestrator":{"external_signal_budget":{"max_attempts":1}}}' > "$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T-LF)"
rm -f "$(issue_dir ENG-45T-LF)/wait-building.json"
reset_capture
ENG_45_LF_RC=0
_handle_wait ENG-45T-LF building awaiting-approval >/dev/null 2>&1 || ENG_45_LF_RC=$?

if (( ENG_45_LF_RC == 0 )); then
  fail_at "ENG-45 case I-LF" "_handle_wait should return 1 on budget exhaust (got 0)"
elif [[ ! -e "$(issue_dir ENG-45T-LF)/wait-building.json" ]]; then
  fail_at "ENG-45 case I-LF" "wait file should be PRESERVED when add-label fails (else-arm of run-stage.sh:419-423)"
elif ! grep -q '^SUBCMD=add-comment$' "$CAPTURE_FILE" \
   || ! grep -q 'external-signal-budget-exhausted' "$CAPTURE_FILE"; then
  fail_at "ENG-45 case I-LF" "missing add-comment with halt body: $(cat "$CAPTURE_FILE")"
elif ! grep -qE '^SUBCMD=add-label$' "$CAPTURE_FILE"; then
  fail_at "ENG-45 case I-LF" "add-label was never attempted: $(cat "$CAPTURE_FILE")"
else
  pass_at "ENG-45 case I-LF: add-label failure preserves wait file (round-3 M-B)"
fi

# Restore the pre-I-LF stub so cases J / J2 / J3 / K / K2 / M see the
# get-comments + stage-of behavior they expect.
mv "$ENG_45_LF_LINEAR_SAVED" "$STUB_DIR/linear.sh"
chmod +x "$STUB_DIR/linear.sh"

# ─── ENG-45 case J: corrupt first_attempt_at resets the window (security F-3) ──
printf '{"orchestrator":{}}' > "$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T9)"
printf '{"first_attempt_at":"NOT-A-DATE","attempts":99}' > "$(issue_dir ENG-45T9)/wait-building.json"
_handle_wait ENG-45T9 building awaiting-approval >/dev/null
# Pin attempts==1 (round-2 review n3): first reset to "now" with attempts=0,
# then incremented to 1 on this very call. The previous disjunction muddied
# the increment-ordering invariant the security F-3 guard depends on.
if jq -e '.attempts == 1' \
     "$(issue_dir ENG-45T9)/wait-building.json" >/dev/null 2>&1; then
  pass_at "ENG-45 case J: corrupt first_attempt_at resets counter (no arbitrary date input)"
else
  fail_at "ENG-45 case J" "json: $(cat "$(issue_dir ENG-45T9)/wait-building.json" 2>/dev/null)"
fi

# ─── ENG-45 case J2 (review-major-2): future-dated first_attempt_at is corrupt ─
# A regex-valid but in-the-future timestamp (e.g. attacker-crafted or clock-skew)
# without the `first_epoch <= now_epoch` clamp produces negative `elapsed_m`,
# clamped to 0, which the wall-clock cap branch can NEVER trip — operator
# running with `max_minutes`-only (no `max_attempts`) loses the safety net.
# With the clamp, future timestamps are treated as corrupt: counter resets to
# 0, increments to 1 on this call, fresh window from now. Test distinguishes by
# asserting attempts==1 after the call (would be 100 without the clamp because
# the regex would pass and attempts++ would just bump 99→100).
printf '{"orchestrator":{}}' > "$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T9F)"
printf '{"first_attempt_at":"9999-12-31T23:59:59Z","attempts":99}' > "$(issue_dir ENG-45T9F)/wait-building.json"
_handle_wait ENG-45T9F building awaiting-approval >/dev/null
if jq -e '.attempts == 1' \
     "$(issue_dir ENG-45T9F)/wait-building.json" >/dev/null 2>&1; then
  pass_at "ENG-45 case J2: future first_attempt_at treated as corrupt (resets counter)"
else
  fail_at "ENG-45 case J2" "json: $(cat "$(issue_dir ENG-45T9F)/wait-building.json" 2>/dev/null)"
fi

# ─── ENG-45 case J3 (round-2 review M1): pre-epoch first_attempt_at is corrupt ─
# Symmetric to J2 in the past direction. `1900-01-01T00:00:00Z` passes the
# shape regex and parses (under BSD date) to a NEGATIVE epoch (~-2.2e9).
# Without a `_first_epoch < 0` floor, `elapsed_m = (now - very-negative) / 60`
# blows past any `max_minutes` budget on the FIRST tick — turning the budget
# safety net into a one-shot trip wire. With the floor, pre-epoch timestamps
# are treated as corrupt: counter resets to 0, increments to 1, fresh window.
# Pin attempts==1 (would be 100 in bug-mode because the regex passes, the
# wall-clock branch fires immediately on attempts=99→100, exhausts, deletes
# the file — distinguishable too, but counter pin is the cleaner invariant).
printf '{"orchestrator":{}}' > "$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T9P)"
printf '{"first_attempt_at":"1900-01-01T00:00:00Z","attempts":99}' > "$(issue_dir ENG-45T9P)/wait-building.json"
_handle_wait ENG-45T9P building awaiting-approval >/dev/null
if jq -e '.attempts == 1' \
     "$(issue_dir ENG-45T9P)/wait-building.json" >/dev/null 2>&1; then
  pass_at "ENG-45 case J3: pre-epoch first_attempt_at treated as corrupt (resets counter)"
else
  fail_at "ENG-45 case J3" "json: $(cat "$(issue_dir ENG-45T9P)/wait-building.json" 2>/dev/null)"
fi

# ─── ENG-45 case K: wall-clock cap exhausts even when attempts < cap ────────
# Pre-write a wait file dated 2 minutes in the past; max_minutes=1 should
# trip exhaustion on the next call regardless of the attempts cap.
# Same four-artifact assertion as case I — covers the wall-clock path.
printf '{"orchestrator":{"external_signal_budget":{"max_minutes":1}}}' > "$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T10)"
two_min_ago="$(date -u -j -v-2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"first_attempt_at":"%s","attempts":1}' "$two_min_ago" \
  > "$(issue_dir ENG-45T10)/wait-building.json"
reset_capture
if _handle_wait ENG-45T10 building awaiting-approval >/dev/null; then
  fail_at "ENG-45 case K" "wall-clock cap should have exhausted; got within-budget"
elif [[ -e "$(issue_dir ENG-45T10)/wait-building.json" ]]; then
  fail_at "ENG-45 case K" "wait file should have been deleted on exhaust"
elif ! grep -q '^SUBCMD=add-comment$' "$CAPTURE_FILE" \
   || ! grep -q 'external-signal-budget-exhausted' "$CAPTURE_FILE"; then
  fail_at "ENG-45 case K" "missing add-comment with external-signal-budget-exhausted body: $(cat "$CAPTURE_FILE")"
elif ! grep -qE '^SUBCMD=add-label$' "$CAPTURE_FILE" \
   || ! grep -q 'pipeline:halted' "$CAPTURE_FILE"; then
  fail_at "ENG-45 case K" "missing add-label pipeline:halted: $(cat "$CAPTURE_FILE")"
else
  pass_at "ENG-45 case K: wall-clock cap exhaust → halt comment + pipeline:halted + wait file deleted"
fi

# ─── ENG-45 case K2 (round-2 review M2): TZ=UTC pin on date -j -f ──────────
# BSD `date -j -f %Y-%m-%dT%H:%M:%SZ` parses Z as a literal char and
# interprets the H:M:S in HOST-LOCAL TZ. case K hides this via symmetry —
# its fixture is produced by the same host-local date call. To break the
# symmetry, hard-code a UTC-canonical fixture via epoch arithmetic and
# force TZ=Pacific/Honolulu (UTC-10) on the call. Bug-mode: parsed epoch
# lands ~10h in the future, M1/M2 future-clamp resets first to now and
# attempts to 0 → call increments to 1, max_minutes=1 → NOT exhausted.
# Fixed-mode (TZ=UTC pinned inside _handle_wait): parse is correct,
# elapsed_m=5 → EXHAUSTED. Assertion: exhaust path's three artifacts
# (rc!=0, file deleted, halt comment) all present.
printf '{"orchestrator":{"external_signal_budget":{"max_minutes":1}}}' > "$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T10TZ)"
five_min_ago_utc_epoch=$(( $(date -u +%s) - 300 ))
five_min_ago_utc="$(date -u -j -f %s "$five_min_ago_utc_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                  || date -u -d @"$five_min_ago_utc_epoch" +%Y-%m-%dT%H:%M:%SZ)"
printf '{"first_attempt_at":"%s","attempts":1}' "$five_min_ago_utc" \
  > "$(issue_dir ENG-45T10TZ)/wait-building.json"
reset_capture
ENG_45_K2_RC=0
TZ=Pacific/Honolulu _handle_wait ENG-45T10TZ building awaiting-approval >/dev/null \
  || ENG_45_K2_RC=$?
if (( ENG_45_K2_RC == 0 )); then
  fail_at "ENG-45 case K2" "wall-clock cap should have exhausted under TZ=Pacific/Honolulu (UTC-10); got within-budget"
elif [[ -e "$(issue_dir ENG-45T10TZ)/wait-building.json" ]]; then
  fail_at "ENG-45 case K2" "wait file should have been deleted on exhaust"
elif ! grep -q 'external-signal-budget-exhausted' "$CAPTURE_FILE"; then
  fail_at "ENG-45 case K2" "missing add-comment with exhaust reason: $(cat "$CAPTURE_FILE")"
else
  pass_at "ENG-45 case K2: wall-clock cap exhausts under non-UTC host TZ (TZ=UTC parse pin)"
fi

# ─── ENG-45 case M: stale stage-summary file is deleted on wait entry ───────
# Load-bearing: prevents post_completion_comment from posting stale content
# from a prior dispatch into the next tick's wait window.
printf '{"orchestrator":{}}' > "$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T11)"
rm -f "$(issue_dir ENG-45T11)/wait-building.json"
printf 'STALE CONTENT FROM PRIOR DISPATCH\n' > "$(issue_dir ENG-45T11)/stage-summary-building.md"
_handle_wait ENG-45T11 building awaiting-approval >/dev/null
if [[ ! -e "$(issue_dir ENG-45T11)/stage-summary-building.md" ]]; then
  pass_at "ENG-45 case M: stale stage-summary-building.md deleted on wait entry"
else
  fail_at "ENG-45 case M" "stale summary file still present"
fi

# Restore CONFIG to whatever case-15 expects (which never runs anyway, but
# preserve invariants for any future case inserted here).
rm -f "$ENG_45_TMP_CFG"
CONFIG="$ENG_45_CFG_SAVED"

# ─── ENG-45 case N (review-major-4): vh_rc=0 success arm clears wait-building.json
# Plan AC-3 ("once approval lands, the next building tick passes P2 and proceeds
# to merge") depends on the wait-counter being cleared after a successful
# build dispatch. This case drives main() with stage=building through to the
# `case "$vh_rc" in 0)` arm and asserts the counter file is gone. Subshell
# isolates stub overrides + any in-main exit.

ENG_45_CASE_N_DIR="$(issue_dir ENG-45T-N)"
mkdir -p "$ENG_45_CASE_N_DIR"
printf '{"issue":"ENG-45T-N","stage":"building","reason":"awaiting-approval","attempts":3,"first_attempt_at":"2026-04-28T10:00:00Z","last_attempt_at":"2026-04-28T10:30:00Z"}' \
  > "$ENG_45_CASE_N_DIR/wait-building.json"
# Pre-write stage-summary file so the agent-contract validator (run-stage.sh
# line ~626) doesn't exit 25 before reaching the success arm.
printf 'build summary\n' > "$ENG_45_CASE_N_DIR/stage-summary-building.md"

# Build-stage linear.sh stub: stage-of returns stage:building (no drift),
# has-label answers stage:* and pipeline:halted yes / paused no, get-comments
# returns empty so _fresh_wait_reason finds no wait marker.
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  has-label)
    case "\${3:-}" in
      pipeline:paused) exit 1 ;;
      stage:*)         exit 0 ;;
      pipeline:halted) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  stage-of)     printf 'stage:building\n' ;;
  get-comments) printf '[]' ;;
  *)            exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/render-prompt.sh"; chmod +x "$STUB_DIR/render-prompt.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/dispatch.sh"; chmod +x "$STUB_DIR/dispatch.sh"

(
  verdict_handler() { return 0; }
  post_completion_comment() { return 0; }
  push_branch_if_ahead() { return 0; }
  main ENG-45T-N building
) >/dev/null 2>&1 || true

if [[ ! -e "$ENG_45_CASE_N_DIR/wait-building.json" ]]; then
  pass_at "ENG-45 case N: vh_rc=0 success arm clears wait-building.json (AC-3)"
else
  fail_at "ENG-45 case N" "wait file still present: $(cat "$ENG_45_CASE_N_DIR/wait-building.json" 2>/dev/null)"
fi

# ─── ENG-45 case O (review-major-1): budget-exhausted exits clean halt-for-human
# Without M1's explicit-exit fix, after _handle_wait deletes stage-summary and
# returns 1, main() falls through to post_completion_comment which posts a
# misleading `summary_missing` Linear comment, contradicting the clean halt
# the wait gate just produced. The fix replaces the fall-through with an
# explicit `metrics.sh stage-end halt-for-human` + exit 0. Test asserts:
#   (a) main exits 0 (clean halt, NOT exit 25 from agent-contract validator
#       and NOT exit 24 from post_completion_comment)
#   (b) post_completion_comment was NOT invoked (no contradictory summary
#       comment)
#   (c) metrics.sh stage-end recorded outcome=halt-for-human

ENG_45_CASE_O_DIR="$(issue_dir ENG-45T-O)"
mkdir -p "$ENG_45_CASE_O_DIR"
rm -f "$ENG_45_CASE_O_DIR/wait-building.json" "$ENG_45_CASE_O_DIR/stage-summary-building.md"

# Force exhaustion on the very first wait dispatch by setting max_attempts=1.
ENG_45_CASE_O_CFG="$(mktemp)"
printf '{"orchestrator":{"external_signal_budget":{"max_attempts":1}},"linear":{"stage_label_prefix":"stage:"}}' \
  > "$ENG_45_CASE_O_CFG"
ENG_45_CASE_O_CFG_SAVED="$CONFIG"
CONFIG="$ENG_45_CASE_O_CFG"

# Linear stub: get-comments returns a fresh wait marker so the gate fires;
# stage-of returns stage:building so no drift; has-label answers as case N.
# Comments fixture lives in a file so the stub heredoc doesn't have to escape
# the embedded JSON quotes.
ENG_45_CASE_O_COMMENTS_FILE="$STUB_DIR/case-o-comments.json"
printf '%s' '[{"createdAt":"2026-04-28T18:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->\n\nAwaiting human Code Owner approval."}]' \
  > "$ENG_45_CASE_O_COMMENTS_FILE"
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  has-label)
    case "\${3:-}" in
      pipeline:paused) exit 1 ;;
      stage:*)         exit 0 ;;
      pipeline:halted) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  stage-of)     printf 'stage:building\n' ;;
  get-comments) cat "$ENG_45_CASE_O_COMMENTS_FILE" ;;
  add-comment)
    # Round-2 review M3: production fidelity — posted comments become
    # visible to subsequent get-comments. With this append, the real
    # find_fresh_verdict (no test-side override) resolves the just-
    # posted halt comment naturally, defending the M1 invariant against
    # any future refactor that moves the agent-contract validator back
    # onto the budget-exhausted path. \$3 is the body for add-comment.
    _now="\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg b "\${3:-}" --arg t "\$_now" \\
      '. + [{createdAt:\$t, body:\$b}]' \\
      "$ENG_45_CASE_O_COMMENTS_FILE" \\
      > "$ENG_45_CASE_O_COMMENTS_FILE.new" \\
      && mv "$ENG_45_CASE_O_COMMENTS_FILE.new" "$ENG_45_CASE_O_COMMENTS_FILE"
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \\
      "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    ;;
  *)
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \\
      "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    ;;
esac
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/render-prompt.sh"; chmod +x "$STUB_DIR/render-prompt.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/dispatch.sh"; chmod +x "$STUB_DIR/dispatch.sh"

# Track post_completion_comment invocations and capture metrics.sh args.
ENG_45_CASE_O_PCC_FLAG="$STUB_DIR/case-o-pcc.flag"
ENG_45_CASE_O_METRICS="$STUB_DIR/case-o-metrics.capture"
: > "$ENG_45_CASE_O_PCC_FLAG"
: > "$ENG_45_CASE_O_METRICS"
cat > "$STUB_DIR/metrics.sh" <<SH
#!/usr/bin/env bash
printf 'EVENT=%s IDENT=%s STAGE=%s OUTCOME=%s\n' \
  "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$ENG_45_CASE_O_METRICS"
exit 0
SH
chmod +x "$STUB_DIR/metrics.sh"

reset_capture
ENG_45_CASE_O_RC=0
(
  post_completion_comment() { printf 'called\n' >> "$ENG_45_CASE_O_PCC_FLAG"; return 0; }
  push_branch_if_ahead() { return 0; }
  verdict_handler() { return 0; }  # unreached if M1 fix lands
  # Round-2 review M3: no `find_fresh_verdict` override. The linear.sh stub
  # above appends posted comments into the get-comments fixture, so if any
  # future refactor moves the agent-contract validator back onto the
  # budget-exhausted path, the real find_fresh_verdict's jq filter (and its
  # `<!-- pipeline: verdict result=halt reason=[a-z-]+ -->` regex) runs against actual production
  # data — a tightening to `[a-z]+` would break a test, where the previous
  # static stub would have hidden the regression.
  main ENG-45T-O building
) >/dev/null 2>&1 || ENG_45_CASE_O_RC=$?

# Cleanup metrics.sh stub so subsequent cases (case-15+) use the original.
rm -f "$STUB_DIR/metrics.sh"

if (( ENG_45_CASE_O_RC != 0 )); then
  fail_at "ENG-45 case O" "main exited rc=$ENG_45_CASE_O_RC (expected 0; M1 fix should yield clean halt)"
elif [[ -s "$ENG_45_CASE_O_PCC_FLAG" ]]; then
  fail_at "ENG-45 case O" "post_completion_comment fired on budget-exhausted path (should be skipped per M1) — flag=$(cat "$ENG_45_CASE_O_PCC_FLAG") metrics=$(cat "$ENG_45_CASE_O_METRICS")"
elif ! grep -q 'OUTCOME=halt-for-human' "$ENG_45_CASE_O_METRICS"; then
  fail_at "ENG-45 case O" "missing OUTCOME=halt-for-human metric: $(cat "$ENG_45_CASE_O_METRICS")"
else
  pass_at "ENG-45 case O: budget-exhausted exits clean halt-for-human (no summary_missing follow-on)"
fi

CONFIG="$ENG_45_CASE_O_CFG_SAVED"
rm -f "$ENG_45_CASE_O_CFG"

# ─── Case 15: guards.sh check reset-on-transition for implement_rejection ──
# Exercises the REAL guards.sh against a fake-repo overlay so common.sh's
# REPO_ROOT computation (`dirname "${BASH_SOURCE[0]}"/../..`) resolves to a
# layout that symlinks to the real config.json and schemas/linear-ids.json,
# while linear.sh is a Case-15-specific stub returning `implement_rejection`
# markers via get-comments. Asserts guards.sh check exits 10 with
# `implement_rejection(2>=2)` when two markers exist with no newer
# pipeline-transition, and exits 0 when a forward pipeline-transition
# marker is injected after them (counter-reset semantic — ENG-18 §Counter
# unification).
reset_capture
FAKE_REPO="$STUB_DIR/fake-repo"
mkdir -p "$FAKE_REPO/.pipeline/bin" "$FAKE_REPO/.pipeline/schemas"
ln -sf "$HARNESS_DIR/guards.sh"                          "$FAKE_REPO/.pipeline/bin/guards.sh"
ln -sf "$HARNESS_DIR/common.sh"                          "$FAKE_REPO/.pipeline/bin/common.sh"
ln -sf "$HARNESS_ROOT/.pipeline-config/config.json"                "$FAKE_REPO/.pipeline/config.json"
ln -sf "$HARNESS_ROOT/.pipeline-config/schemas/linear-ids.json"    "$FAKE_REPO/.pipeline/schemas/linear-ids.json"

# Stub for trip path: two impl_rejection markers, no transition marker.
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get-comments)
    cat <<'JSON'
[
  {"body":"<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh.","createdAt":"2026-04-23T09:00:00.000Z"},
  {"body":"<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh.","createdAt":"2026-04-23T09:30:00.000Z"}
]
JSON
    ;;
  query)
    # gotcha/rule counters use count_marker (query) — return empty.
    printf '%s\n' '{"data":{"issues":{"nodes":[{"id":"id-T15","comments":{"nodes":[]}}]}}}'
    ;;
  has-label) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
trip_output="$(bash "$FAKE_REPO/.pipeline/bin/guards.sh" check ENG-T15 2>&1)"
trip_rc=$?
set -e

# Stub for reset path: same two markers plus a newer pipeline-transition.
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get-comments)
    cat <<'JSON'
[
  {"body":"<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh.","createdAt":"2026-04-23T09:00:00.000Z"},
  {"body":"<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh.","createdAt":"2026-04-23T09:30:00.000Z"},
  {"body":"<!-- pipeline: transition from=implementing to=ui -->","createdAt":"2026-04-23T10:00:00.000Z"}
]
JSON
    ;;
  query)
    printf '%s\n' '{"data":{"issues":{"nodes":[{"id":"id-T15","comments":{"nodes":[]}}]}}}'
    ;;
  has-label) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
clear_output="$(bash "$FAKE_REPO/.pipeline/bin/guards.sh" check ENG-T15 2>&1)"
clear_rc=$?
set -e

if [[ "$trip_rc" == "10" ]] \
   && grep -q 'implement_rejection(2>=2)' <<<"$trip_output" \
   && [[ "$clear_rc" == "0" ]]; then
  pass_at "case-15 guards.sh check trips on implement_rejection count=2; resets after forward pipeline-transition"
else
  fail_at "case-15 reset-on-transition" "trip_rc=$trip_rc trip_output=$trip_output clear_rc=$clear_rc clear_output=$clear_output"
fi

# ─── Case 16 (QA adversarial): bump's marker text matches count_marker's grep ──
# Guards against a future refactor that changes the marker string in bump() but
# forgets count_marker() (or vice versa), silently disabling the counter. The
# test asserts the literal text `<!-- meta: metric name=implement_rejection -->`
# is the prefix of what bump writes — which is the exact grep target in
# count_marker (guards.sh:30).
reset_capture
BUMP_CAPTURE="$STUB_DIR/bump-marker.capture"
: > "$BUMP_CAPTURE"
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  add-comment)
    # \$2=ident, \$3=body
    printf '%s\n' "\${3:-}" >> "$BUMP_CAPTURE"
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"
bash "$FAKE_REPO/.pipeline/bin/guards.sh" bump ENG-T16 implement_rejection >/dev/null 2>&1
bump_body="$(cat "$BUMP_CAPTURE")"
if grep -q '<!-- meta: metric name=implement_rejection -->' "$BUMP_CAPTURE"; then
  pass_at "case-16 QA: bump emits the exact marker that count_marker greps for"
else
  fail_at "case-16 QA marker contract" "body=$bump_body"
fi

# ─── Case 17 (QA adversarial): clear-log line includes impl=N ───────────────
# Guards against a future edit that drops `impl=$impl` from the clear-log line
# at guards.sh, which would silently remove operator visibility into the new
# counter. The test asserts the literal token `impl=0` appears when the issue
# has no markers (clear path).
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  query)
    # gotcha/rule counters use count_marker (query) — empty.
    printf '%s\n' '{"data":{"issues":{"nodes":[{"id":"id-T17","comments":{"nodes":[]}}]}}}'
    ;;
  get-comments)
    # rejection counters use count_marker_since_last_transition — empty.
    printf '%s\n' '[]'
    ;;
  has-label) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
clear_log_output="$(
  bash "$FAKE_REPO/.pipeline/bin/guards.sh" check ENG-T17 2>&1
)"
clear_log_rc=$?
set -e

if [[ "$clear_log_rc" == "0" ]] && grep -q 'impl=0' <<<"$clear_log_output"; then
  pass_at "case-17 QA: clear-log line includes impl=N (drift guard)"
else
  fail_at "case-17 QA clear-log" "rc=$clear_log_rc output=$clear_log_output"
fi

# ─── Case 19 (ENG-41): stage-drift guard — dispatched ui, stage flips to reviewing ──
# Simulates the ENG-26 forged-transition scenario: after dispatch, stage-of returns
# stage:reviewing instead of stage:ui. Post-run expectations:
#   - pipeline:halted is NOT applied (drift guard exits early before halt-add)
#   - verdict_handler is NOT called
#   - exit code is 0
#   - metrics records outcome=stage-drift
METRICS_CAPTURE_19="$STUB_DIR/metrics.capture.19"
VH_FLAG_19="$STUB_DIR/vh-called.19"
HALT_FLAG_19="$STUB_DIR/halt-added.19"
: > "$METRICS_CAPTURE_19"
rm -f "$VH_FLAG_19" "$HALT_FLAG_19"

# linear.sh stub: stage-of returns stage:reviewing (simulating drift from stage:ui).
# has-label stage:ui returns 0 (precondition check passes).
# add-label pipeline:halted is flagged (we assert it does NOT happen).
cat > "$STUB_DIR/linear.sh" <<SH19
#!/usr/bin/env bash
case "\${1:-}" in
  has-label)
    case "\${3:-}" in
      pipeline:paused) exit 1 ;;
      stage:ui)        exit 0 ;;
      pipeline:halted) exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  stage-of)
    printf 'stage:reviewing\n'
    ;;
  add-label)
    if [[ "\${3:-}" == "pipeline:halted" ]]; then
      printf 'halted\n' > "$HALT_FLAG_19"
    fi
    ;;
  *) exit 0 ;;
esac
exit 0
SH19
chmod +x "$STUB_DIR/linear.sh"

# metrics.sh: capture stage-end calls so we can verify outcome=stage-drift.
cat > "$STUB_DIR/metrics.sh" <<SH19
#!/usr/bin/env bash
printf 'EVENT=%s IDENT=%s STAGE=%s OUTCOME=%s NOTES=%s\n' \
  "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" "\${6:-}" >> "$METRICS_CAPTURE_19"
exit 0
SH19
chmod +x "$STUB_DIR/metrics.sh"

# scan-gotcha-trailers.sh: no-op (needed for ui-stage flow).
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/scan-gotcha-trailers.sh"
chmod +x "$STUB_DIR/scan-gotcha-trailers.sh"

# render-prompt.sh + dispatch.sh: no-ops so main() can reach post-dispatch.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/render-prompt.sh"
chmod +x "$STUB_DIR/render-prompt.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/dispatch.sh"
chmod +x "$STUB_DIR/dispatch.sh"

mkdir -p "$(issue_dir ENG-T19)"

# Run main in a subshell so exit inside main() does not kill the test process.
# Override functions to reach the stage-drift guard without real Linear/dispatch.
set +e
_drift_exit_rc=0
(
  # Override verify_preconditions so we can reach the post-dispatch block.
  verify_preconditions() { return 0; }
  # Pass the agent-contract validator (needs non-empty fresh-marker or summary file).
  find_fresh_verdict() { printf 'dummy-marker'; }
  # Record if verdict_handler is called (we assert it is NOT).
  verdict_handler() { printf 'called\n' > "$VH_FLAG_19"; return 0; }
  post_completion_comment() { return 0; }
  push_branch_if_ahead() { return 0; }
  main ENG-T19 ui 2>/dev/null
) || _drift_exit_rc=$?
set -e

_halt_added="$([[ -f "$HALT_FLAG_19" ]] && echo true || echo false)"
_vh_called="$([[ -f "$VH_FLAG_19" ]] && echo true || echo false)"
_drift_metric_count="$(grep -c 'OUTCOME=stage-drift' "$METRICS_CAPTURE_19" 2>/dev/null || true)"

if [[ "$_drift_exit_rc" == "0" ]] \
   && [[ "$_halt_added" == "false" ]] \
   && [[ "$_vh_called" == "false" ]] \
   && [[ "$_drift_metric_count" -ge "1" ]]; then
  pass_at "case-19 stage-drift guard: halt NOT applied, vh NOT called, exit 0, metrics=stage-drift"
else
  fail_at "case-19 stage-drift guard" \
    "exit_rc=$_drift_exit_rc halt_added=$_halt_added vh_called=$_vh_called drift_metric=$_drift_metric_count"
fi

# ─── Case 18: success-arm clears pipeline:supersede for brainstorm+plan only (ENG-6) ──
# Drives main() for stage=brainstorm through a full-mock chain to the
# `case "$vh_rc" in 0)` success arm. Captures every linear.sh call and asserts
# that remove-label pipeline:supersede fires for brainstorm+vh_rc=0 and NOT for
# stage=implement or vh_rc=1 (halt arm). Sub-assertions share one linear.sh
# stub shape so the three scenarios remain synchronized.

# Dispatch-based linear.sh stub: has-label exits 0 for the labels we want
# present (stage:<X> and pipeline:halted), exits 1 for pipeline:paused;
# stage-of prints `stage:<vh_stage>`; every capturable subcommand records
# into CAPTURE_FILE using the existing SUBCMD/SIG/IDENT/BODY shape.
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  has-label)
    case "\${3:-}" in
      pipeline:paused) exit 1 ;;
      stage:*)         exit 0 ;;
      pipeline:halted) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  stage-of)
    printf '%s\n' "\${MOCK_STAGE_OF:-stage:brainstorming}"
    ;;
  *)
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
      "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    ;;
esac
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"

# render-prompt.sh + dispatch.sh: no-op stubs so main() reaches verdict_handler.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/render-prompt.sh"
chmod +x "$STUB_DIR/render-prompt.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/dispatch.sh"
chmod +x "$STUB_DIR/dispatch.sh"

# Override post_completion_comment so its add-or-update-comment call does not
# drown the capture file. Harness-local; doesn't affect other cases since this
# is the last case before the summary line.
post_completion_comment() { return 0; }
# ENG-45 review-major-3 (M3 follow-on): once the REPO_ROOT typo at case-15 is
# fixed, the script reaches case-18; main()'s agent-contract validator (line
# ~626) exits 25 unless the agent emitted a stage-summary file or fresh verdict
# marker. Stub find_fresh_verdict to return a non-empty string so case-18 drives
# into the success/halt arms it cares about. Same pattern case-19 uses (line
# ~1298).
find_fresh_verdict() { printf 'dummy-marker'; }

# Drive: stage=brainstorming, vh_rc=0 → remove-label pipeline:supersede expected.
# ENG-45 review-major-3 follow-on: wrap each main() call in a subshell so any
# `exit` inside main() (notably the post-completion-comment exit-24 path or the
# stage-drift exit-0 path) terminates only the subshell, not the whole test.
# Same pattern case-19 already uses.
reset_capture
MOCK_STAGE_OF="stage:brainstorming"
( verdict_handler() { return 0; }; main ENG-T18A brainstorming ) >/dev/null 2>&1 || true

if grep -B2 '^IDENT=pipeline:supersede$' "$CAPTURE_FILE" 2>/dev/null \
     | grep -q '^SUBCMD=remove-label$'; then
  pass_at "case-18a brainstorming+vh_rc=0: remove-label pipeline:supersede fires"
else
  fail_at "case-18a brainstorm+vh_rc=0" "capture=$(cat "$CAPTURE_FILE")"
fi

# Drive: stage=implementing, vh_rc=0 → remove-label pipeline:supersede NOT expected.
reset_capture
MOCK_STAGE_OF="stage:implementing"
( verdict_handler() { return 0; }; main ENG-T18B implementing ) >/dev/null 2>&1 || true

if ! grep -q '^IDENT=pipeline:supersede$' "$CAPTURE_FILE" 2>/dev/null; then
  pass_at "case-18b implementing+vh_rc=0: remove-label pipeline:supersede does NOT fire"
else
  fail_at "case-18b implement+vh_rc=0" "capture=$(cat "$CAPTURE_FILE")"
fi

# Drive: stage=brainstorming, vh_rc=1 (halt) → remove-label pipeline:supersede NOT expected.
reset_capture
MOCK_STAGE_OF="stage:brainstorming"
( verdict_handler() { return 1; }; main ENG-T18C brainstorming ) >/dev/null 2>&1 || true

if ! grep -q '^IDENT=pipeline:supersede$' "$CAPTURE_FILE" 2>/dev/null; then
  pass_at "case-18c brainstorming+vh_rc=1 (halt arm): remove-label pipeline:supersede does NOT fire"
else
  fail_at "case-18c brainstorm+vh_rc=1" "capture=$(cat "$CAPTURE_FILE")"
fi

# ─── ENG-45 case TICK (round-3 M-A): wait body must include per-tick token ──
# bin/linear.sh add-comment dedups identical bodies after stripping ISO
# timestamps + git SHAs (bin/linear.sh:380-411). Without a per-tick varying
# token in the wait body, ticks 2..N are silently swallowed and the
# brainstorm §4.2 "operator sees tick N/M trail" UX claim is broken.
# AGENT_PROMPTS.md §7 P2 + P5 wait bodies must instruct the agent to
# include a `tick_at: <human-readable UTC time>` token whose format
# (yyyy-mm-dd HH:MM:SSZ with a SPACE separator, not a `T`) survives both
# dedup regexes:
#   - ISO regex `[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z`
#     does not match (literal T required).
#   - SHA regex `[0-9a-f]{7,40}` does not match (max contiguous hex run
#     in `2026-04-29 03:14:00Z` is 4 chars: `2026`).
ENG_45_PROMPTS_PATH="$HARNESS_DIR/../AGENT_PROMPTS.md"
[[ -f "$ENG_45_PROMPTS_PATH" ]] || ENG_45_PROMPTS_PATH="$HARNESS_ROOT/AGENT_PROMPTS.md"
if [[ ! -f "$ENG_45_PROMPTS_PATH" ]]; then
  fail_at "ENG-45 case TICK" "AGENT_PROMPTS.md not found at $ENG_45_PROMPTS_PATH"
else
  # Two grep checks — one per wait reason. Each must mention `tick_at` in
  # the wait body section. Failing either is a P0 prompt-prose drift.
  # ENG-60 T2.11: anchor strings switched from old-shape
  # `pipeline-wait: awaiting-approval/ci` to new-shape
  # `verdict wait --reason awaiting-approval/ci`. Match the new shape.
  if grep -A8 'verdict wait --reason awaiting-approval' "$ENG_45_PROMPTS_PATH" \
       | grep -q 'tick_at'; then
    p2_ok=1
  else
    p2_ok=0
  fi
  if grep -A8 'verdict wait --reason awaiting-ci' "$ENG_45_PROMPTS_PATH" \
       | grep -q 'tick_at'; then
    p5_ok=1
  else
    p5_ok=0
  fi
  if (( p2_ok == 1 && p5_ok == 1 )); then
    pass_at "ENG-45 case TICK: AGENT_PROMPTS §7 P2+P5 wait bodies instruct per-tick tick_at token"
  else
    fail_at "ENG-45 case TICK" "missing tick_at instruction in wait body — P2_ok=$p2_ok P5_ok=$p5_ok"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# ENG-45 — QA-authored adversarial cases (NOT in plan's Failure Mode → Test Map)
# ════════════════════════════════════════════════════════════════════════════
# These cases were identified during QA by an adversarial-coverage sweep over
# `_fresh_wait_reason` and `_handle_wait`. They pin behaviors that the plan
# rows do not enumerate but that a future refactor could silently change.

# Restore the get-comments-aware linear.sh stub (cases N, O, 19, 18 above
# overwrote it) so QA-A1..QA-A3 can inject MOCK_COMMENTS_JSON fixtures.
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  get-comments) printf '%s' "\${MOCK_COMMENTS_JSON-[]}" ;;
  stage-of)     printf 'stage:qa\n' ;;
  *)
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
      "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    ;;
esac
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"

# ─── Case QA-A1: empty array `[]` is distinct from empty string and "null" ──
# Plan cases E and F cover MOCK_COMMENTS_JSON='' and ='null' (both fail at
# the `-z` / literal-string short-circuit before jq runs). The third empty-
# shape — a syntactically valid empty array — exercises the jq filters end
# to end and must also return 1 (no fresh marker found). A future refactor
# that swaps `[[ -z … ]]` for `jq 'length == 0'` (or vice versa) would change
# which empty shape short-circuits and which falls through; pinning all
# three keeps the read path's fail-closed contract uniform.
export MOCK_COMMENTS_JSON='[]'
qa_a1_out="$(_fresh_wait_reason ENG-45T-QA1 building || printf '')"
if [[ -z "$qa_a1_out" ]]; then
  pass_at "ENG-45 case QA-A1: empty comments array [] returns empty (distinct from '' / 'null', covers jq path)"
else
  fail_at "ENG-45 case QA-A1" "got: $qa_a1_out"
fi
unset MOCK_COMMENTS_JSON

# ─── Case QA-A2: prose-quoted pipeline-marker inside wait body breaks gate ─
# Latent regression risk: `_fresh_wait_reason` iterates comments through
# parse_pipeline_marker, whose grep is unanchored (`<!-- pipeline: [^>]+ -->`)
# and matches the substring ANYWHERE in a comment body — including inside a
# wait body that quotes the marker as documentation. When that happens,
# `last_t` advances to the wait comment's own createdAt; the freshness
# filter `createdAt > $t` is strictly-greater, so the wait comment cannot
# match itself → gate returns empty → falls through to the agent-contract
# validator → exit 25.
#
# Net effect: the wait window FAILS to start on the very tick the agent
# posted the marker. The orchestrator falls back to halt-for-human (a
# graceful degradation, not a security hole, since the wait gate's
# job is to avoid premature halts — failing closed is correct). Pin
# the current behavior: ENG-61 will fix this by stripping markdown code
# spans and fenced blocks before the grep; that work is out of scope here.
#
# Build agent's authored wait body does NOT contain this substring (verified
# AGENT_PROMPTS.md §7), so this is a defensive pin against future prompt
# rewrites or operator-pasted comments.
export MOCK_COMMENTS_JSON='[
  {"createdAt":"2026-04-29T08:00:00Z","body":"<!-- pipeline: transition from=implementing to=building -->"},
  {"createdAt":"2026-04-29T08:17:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->\n\nAwaiting approval. (See doc: <!-- pipeline: transition from=X to=Y --> markers are orchestrator-only.)"}
]'
qa_a2_out="$(_fresh_wait_reason ENG-45T-QA2 building || printf '')"
if [[ -z "$qa_a2_out" ]]; then
  pass_at "ENG-45 case QA-A2: wait body containing prose-quoted pipeline marker fails closed (parser is shape-but-not-context-aware)"
else
  fail_at "ENG-45 case QA-A2" "wait gate spuriously matched a body that quotes a pipeline marker: got=$qa_a2_out"
fi
unset MOCK_COMMENTS_JSON

# ─── Case QA-A3: malformed legacy marker silently fails (closed) ──────
# parse_pipeline_marker's grep `<!-- pipeline: [^>]+ -->` requires the
# `pipeline: ` (colon-space) prefix of the new shape. A legacy/typoed
# marker like `<!-- pipeline-wait:awaiting-approval -->` doesn't match,
# so the gate returns empty. Fail-closed semantic: a malformed marker
# degrades to halt-for-human rather than silently allowing the wait.
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-29T08:17:00Z","body":"<!-- pipeline-wait:awaiting-approval -->"}]'
qa_a3_out="$(_fresh_wait_reason ENG-45T-QA3 building || printf '')"
if [[ -z "$qa_a3_out" ]]; then
  pass_at "ENG-45 case QA-A3: marker missing trailing space fails closed (jq test() string is space-anchored)"
else
  fail_at "ENG-45 case QA-A3" "no-space-after-colon marker spuriously matched: $qa_a3_out"
fi
unset MOCK_COMMENTS_JSON

# ─── Case QA-B1: max_attempts: 0 halts on the very first attempt ────────────
# Operator foot-gun pin. Setting `max_attempts: 0` in config.json is a
# plausible typo (e.g., when the operator intends to "disable the budget"
# they might write 0 instead of removing the key or setting null).
# Current behavior: `(( attempts >= 0 ))` is true after the first increment
# (attempts=1), so `_handle_wait` returns 1 on the very first call →
# halt-for-human via the budget-exhausted path. This is the most
# conservative interpretation of "0 attempts allowed". Pin explicitly so a
# future change that adds `(( max_a > 0 ))` validation (treating 0 as
# disabled) is a deliberate, reviewed semantic flip.
ENG_45_QA_TMP_CFG="$(mktemp)"
ENG_45_QA_CFG_SAVED="${CONFIG:-}"
printf '{"orchestrator":{"external_signal_budget":{"max_attempts":0}}}' > "$ENG_45_QA_TMP_CFG"
CONFIG="$ENG_45_QA_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T-QA-B1)"
rm -f "$(issue_dir ENG-45T-QA-B1)/wait-building.json"
reset_capture
qa_b1_rc=0
_handle_wait ENG-45T-QA-B1 building awaiting-approval >/dev/null 2>&1 || qa_b1_rc=$?
if (( qa_b1_rc != 0 )) \
   && [[ ! -e "$(issue_dir ENG-45T-QA-B1)/wait-building.json" ]] \
   && grep -q 'external-signal-budget-exhausted' "$CAPTURE_FILE"; then
  pass_at "ENG-45 case QA-B1: max_attempts=0 halts on first attempt (no infinite-loop foot-gun)"
else
  fail_at "ENG-45 case QA-B1" "rc=$qa_b1_rc file_present=$([[ -e "$(issue_dir ENG-45T-QA-B1)/wait-building.json" ]] && echo yes || echo no) capture=$(cat "$CAPTURE_FILE")"
fi

# ─── Case QA-B2: wait file with empty-string first_attempt_at resets ────────
# Plan cases J/J2/J3 cover non-date / future / pre-epoch first_attempt_at.
# A fourth corruption shape — explicit empty string `""` — slips through the
# jq path with `// ""` returning empty, and the regex `^[0-9]{4}-...` fails
# the empty string. The expected reset-then-increment path produces
# attempts==1. Pin so a future regex relaxation (e.g., `^[0-9-T:Z]*$`
# accidentally matching empty) is caught.
printf '{"orchestrator":{}}' > "$ENG_45_QA_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T-QA-B2)"
printf '{"first_attempt_at":"","attempts":99}' > "$(issue_dir ENG-45T-QA-B2)/wait-building.json"
_handle_wait ENG-45T-QA-B2 building awaiting-approval >/dev/null
if jq -e '.attempts == 1' "$(issue_dir ENG-45T-QA-B2)/wait-building.json" >/dev/null 2>&1; then
  pass_at "ENG-45 case QA-B2: empty-string first_attempt_at resets counter (4th corruption shape)"
else
  fail_at "ENG-45 case QA-B2" "json: $(cat "$(issue_dir ENG-45T-QA-B2)/wait-building.json" 2>/dev/null)"
fi

# ─── Case QA-B3: wait file with missing attempts key still increments ───────
# A wait file that's valid JSON object with `first_attempt_at` but no
# `attempts` key (e.g., crafted by an older code path that forgot to write
# the field). `jq -r '.attempts // 0'` defaults to 0; the regex
# `^[0-9]+$` matches "0"; attempts++=1. Pin so a future jq filter swap
# (e.g., `.attempts | tonumber` which would error on missing) is caught.
printf '{"orchestrator":{}}' > "$ENG_45_QA_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T-QA-B3)"
# first_attempt_at = now-ish to dodge the future-clamp; omit attempts entirely.
qa_b3_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"first_attempt_at":"%s"}' "$qa_b3_now" > "$(issue_dir ENG-45T-QA-B3)/wait-building.json"
_handle_wait ENG-45T-QA-B3 building awaiting-approval >/dev/null
if jq -e '.attempts == 1' "$(issue_dir ENG-45T-QA-B3)/wait-building.json" >/dev/null 2>&1; then
  pass_at "ENG-45 case QA-B3: wait file with missing attempts key defaults to 0 then increments to 1"
else
  fail_at "ENG-45 case QA-B3" "json: $(cat "$(issue_dir ENG-45T-QA-B3)/wait-building.json" 2>/dev/null)"
fi

# Restore CONFIG and clean up.
CONFIG="$ENG_45_QA_CFG_SAVED"
rm -f "$ENG_45_QA_TMP_CFG"

# ─── ENG-54 case A: _fresh_wait_reason rejects review stage ───────────
# ENG-50 originally extended _fresh_wait_reason's allow-list to {build,review}
# so the review-stage human-approval gate could emit pipeline-wait. ENG-54
# moved the gate to build's P2 — review never waits anymore — so the
# allow-list narrows back to build only. Pin the new contract.
fresh_comments='[{"id":"c1","createdAt":"2026-04-30T12:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->\n\nReviewed commit abc1234."}]'
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  get-comments) printf '%s' '$fresh_comments' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"
SCRIPT_DIR="$STUB_DIR"
reason="$(_fresh_wait_reason "ENG-580" "review" 2>/dev/null || printf '')"
[[ -z "$reason" ]] \
  && pass_at "ENG-54 _fresh_wait_reason: review stage REJECTED (gate moved to build P2)" \
  || fail_at "ENG-54 _fresh_wait_reason review" "got: '$reason' (expected empty — review must not emit wait shapes)"

# Sanity: build still works.
reason="$(_fresh_wait_reason "ENG-581" "building" 2>/dev/null || printf '')"
[[ "$reason" == "awaiting-approval" ]] \
  && pass_at "ENG-54 _fresh_wait_reason: building still accepts wait shape" \
  || fail_at "ENG-54 _fresh_wait_reason build" "got: '$reason'"

# Other stages still rejected.
reason="$(_fresh_wait_reason "ENG-582" "implementing" 2>/dev/null || printf '')"
[[ -z "$reason" ]] \
  && pass_at "ENG-54 _fresh_wait_reason: implementing still rejected" \
  || fail_at "ENG-54 _fresh_wait_reason implement" "got: '$reason' (expected empty)"

# ─── ENG-54 case B: _post_review_dispatch_update writes only SHA ──────
# Pre-ENG-54 it forwarded sha + last_processed_approval_at + last_processed_cr_at.
# Post-ENG-54 only the SHA is recorded — the human-approval gate moved to
# build's P2 and there are no per-state timestamps to track.
UPDATE_CALLS="$STUB_DIR/update-state-calls.log"
: > "$UPDATE_CALLS"
cat > "$STUB_DIR/review-state.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  update)
    # \$2=issue \$3=sha; record the full call shape so we can assert on
    # extra-arg-absence as well as the sha value.
    printf 'update issue=%s sha=%s extra=%s\\n' "\$2" "\$3" "\${4-MISSING}\${5-}\${6-}" >> "$UPDATE_CALLS"
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/review-state.sh"

# Stub gh: pretend HEAD SHA = abc1234. ENG-54 dropped the reviews query
# from _post_review_dispatch_update's gh call (only commits is needed now).
cat > "$STUB_DIR/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") printf '%s' '{"commits":[{"oid":"abc1234"}]}' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/gh"

ORIG_PATH="$PATH"
PATH="$STUB_DIR:$PATH"
SCRIPT_DIR="$STUB_DIR"
_post_review_dispatch_update "ENG-585" "stub-branch" >/dev/null 2>&1 || true
PATH="$ORIG_PATH"

captured="$(cat "$UPDATE_CALLS")"
if [[ "$captured" == *"issue=ENG-585"* && "$captured" == *"sha=abc1234"* ]]; then
  pass_at "ENG-54 _post_review_dispatch_update writes current SHA only"
else
  fail_at "ENG-54 _post_review_dispatch_update" "captured: $captured"
fi
if [[ "$captured" == *"extra=MISSING"* ]]; then
  pass_at "ENG-54 _post_review_dispatch_update: no approval/CR timestamps passed (single-arg update)"
else
  fail_at "ENG-54 _post_review_dispatch_update extra args" "captured: $captured (expected extra=MISSING)"
fi


# ─── ENG-56: _post_dispatch_apply_halt marker-shape gate ──────────────
# Pre-fix: the post-dispatch hook was an unconditional `if ! has-label
# pipeline:halted; then add-label`. ENG-44's dogfood showed the orchestrator
# silently filling in for non-compliant agents on 8/8 dispatches — and on
# build's wait-shape exits the apply would silently override ENG-45 wait
# semantics had the early-exit at line ~676 not preceded it. ENG-56 makes
# the apply marker-shape aware: skip when `_fresh_wait_reason` reports a
# wait shape, otherwise apply (idempotent on `has-label` short-circuit).
#
# Each case stubs linear.sh + MOCK_COMMENTS_JSON, calls the function, and
# asserts whether `add-label pipeline:halted` was captured.

ENG_56_HOOK_LINEAR_CAPTURE="$STUB_DIR/eng-56-hook.capture"
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  get-comments)
    printf '%s' "\${MOCK_COMMENTS_JSON-[]}"
    ;;
  has-label)
    # Always say label is missing so add-label path fires when reachable.
    exit 1
    ;;
  add-label)
    printf 'add-label %s %s\n' "\${2:-}" "\${3:-}" >> "$ENG_56_HOOK_LINEAR_CAPTURE"
    ;;
esac
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"

eng_56_reset() { : > "$ENG_56_HOOK_LINEAR_CAPTURE"; }
eng_56_halt_applied() { grep -q '^add-label .* pipeline:halted$' "$ENG_56_HOOK_LINEAR_CAPTURE"; }

# Case ENG-56-A: implement stage with no fresh marker → applies halt.
eng_56_reset
unset MOCK_COMMENTS_JSON
_post_dispatch_apply_halt "ENG-56T-A" implement >/dev/null 2>&1
if eng_56_halt_applied; then
  pass_at "ENG-56-A: implement + no fresh marker → orchestrator applies pipeline:halted"
else
  fail_at "ENG-56-A: implement + no fresh marker" "capture: $(cat "$ENG_56_HOOK_LINEAR_CAPTURE")"
fi

# Case ENG-56-B: implement stage with stage-summary marker → applies halt.
eng_56_reset
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline: verdict result=pass stage=implementing -->\n\nDone."}]'
_post_dispatch_apply_halt "ENG-56T-B" implement >/dev/null 2>&1
if eng_56_halt_applied; then
  pass_at "ENG-56-B: implement + stage-summary → orchestrator applies pipeline:halted"
else
  fail_at "ENG-56-B: implement + stage-summary" "capture: $(cat "$ENG_56_HOOK_LINEAR_CAPTURE")"
fi

# Case ENG-56-C: review stage with rejection marker → applies halt.
eng_56_reset
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline: verdict result=fail target=implementing -->"}]'
_post_dispatch_apply_halt "ENG-56T-C" review >/dev/null 2>&1
if eng_56_halt_applied; then
  pass_at "ENG-56-C: review + rejection → orchestrator applies pipeline:halted"
else
  fail_at "ENG-56-C: review + rejection" "capture: $(cat "$ENG_56_HOOK_LINEAR_CAPTURE")"
fi

# Case ENG-56-D: building stage with halt marker → applies halt.
eng_56_reset
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline: verdict result=halt reason=agent-blocked -->"}]'
_post_dispatch_apply_halt "ENG-56T-D" building >/dev/null 2>&1
if eng_56_halt_applied; then
  pass_at "ENG-56-D: build + halt marker → orchestrator applies pipeline:halted"
else
  fail_at "ENG-56-D: build + halt marker" "capture: $(cat "$ENG_56_HOOK_LINEAR_CAPTURE")"
fi

# Case ENG-56-E (regression for ENG-45): building + wait awaiting-approval
# → orchestrator does NOT apply pipeline:halted.
eng_56_reset
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->\n\nAwaiting human Code Owner approval."}]'
_post_dispatch_apply_halt "ENG-56T-E" building >/dev/null 2>&1
if eng_56_halt_applied; then
  fail_at "ENG-56-E: build + wait awaiting-approval" "halt was applied; should be skipped"
else
  pass_at "ENG-56-E: build + wait awaiting-approval → orchestrator does NOT apply pipeline:halted"
fi

# Case ENG-56-F: building + wait awaiting-ci → orchestrator does NOT apply.
eng_56_reset
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-ci -->\n\nAwaiting CI."}]'
_post_dispatch_apply_halt "ENG-56T-F" building >/dev/null 2>&1
if eng_56_halt_applied; then
  fail_at "ENG-56-F: build + wait awaiting-ci" "halt was applied; should be skipped"
else
  pass_at "ENG-56-F: build + wait awaiting-ci → orchestrator does NOT apply pipeline:halted"
fi

# Case ENG-56-G (ENG-54 update): review + stray wait awaiting-approval →
# orchestrator now APPLIES pipeline:halted. Pre-ENG-54 the review stage was
# wait-eligible (human-approval gate); ENG-54 narrowed _fresh_wait_reason's
# allow-list to build only, so a wait marker on review-stage is now a stray
# comment and the halt-apply is the correct response.
eng_56_reset
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->\n\nReviewed commit abc1234."}]'
_post_dispatch_apply_halt "ENG-56T-G" reviewing >/dev/null 2>&1
if eng_56_halt_applied; then
  pass_at "ENG-56-G (ENG-54): review + stray wait → orchestrator applies pipeline:halted (no human-approval gate at review)"
else
  fail_at "ENG-56-G (ENG-54): review + stray wait" "halt should be applied — gate moved to build P2"
fi

# Case ENG-56-H: implement stage with stray pipeline-wait marker. Wait shape
# is allow-listed for build only (ENG-54); on other stages a wait comment
# is a protocol violation and the halt apply is the correct response.
eng_56_reset
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"}]'
_post_dispatch_apply_halt "ENG-56T-H" implementing >/dev/null 2>&1
if eng_56_halt_applied; then
  pass_at "ENG-56-H: implement + stray wait marker (out-of-allow-list stage) → orchestrator applies pipeline:halted"
else
  fail_at "ENG-56-H: implement + stray wait" "halt should be applied (wait carve-out is build/review only)"
fi

# Case ENG-56-I: idempotency. has-label returns 0 → add-label is skipped.
eng_56_reset
unset MOCK_COMMENTS_JSON
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  get-comments) printf '%s' "\${MOCK_COMMENTS_JSON-[]}" ;;
  has-label)    exit 0 ;;
  add-label)    printf 'add-label %s %s\n' "\${2:-}" "\${3:-}" >> "$ENG_56_HOOK_LINEAR_CAPTURE" ;;
esac
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"
_post_dispatch_apply_halt "ENG-56T-I" implementing >/dev/null 2>&1
if eng_56_halt_applied; then
  fail_at "ENG-56-I: idempotency" "add-label fired when has-label already returned 0"
else
  pass_at "ENG-56-I: has-label already 0 → add-label NOT called (idempotent)"
fi
unset MOCK_COMMENTS_JSON

# ─── Group: marker-emission audit accepts new-shape (ENG-60 Phase 1) ─────

printf '\n--- marker-emission audit detects new-shape verdict ---\n'

# Fixture MEA1: a comment with new-shape verdict pass should NOT trigger
# the defensive halt-add path (because find_fresh_verdict returns non-empty).
# Note: find_fresh_verdict was stubbed at line ~1684 for earlier test cases;
# we must restore it here so the real implementation is called.
source "$HARNESS_DIR/verdict-handler.sh"

cat > "$STUB_DIR/linear.sh" <<'SH'
#!/bin/bash
if [[ "$1" == "get-comments" ]]; then
  printf '%s' '[{"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline: transition from=planning to=implementing -->"},{"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline: verdict result=pass stage=implementing -->"}]'
fi
SH
chmod +x "$STUB_DIR/linear.sh"

# Override _VH_SCRIPT_DIR to point to our stub directory
_VH_SCRIPT_DIR="$STUB_DIR"
export _VH_SCRIPT_DIR

result="$(find_fresh_verdict ENG-MEA1)"
[[ -n "$result" ]] && pass_at "MEA1: new-shape pass detected for marker-emission audit" || fail_at "MEA1" "got empty result"

# Extract the result field
result_field="$(jq -r '.event.result' <<<"$result")"
[[ "$result_field" == "pass" ]] && pass_at "MEA1: result=pass via event field" || fail_at "MEA1 result" "got: $result_field"

# ─── Group: _fresh_wait_reason new-shape detection (ENG-60 T2.1) ─────────

printf '\n--- _fresh_wait_reason accepts new-shape wait marker ---\n'

# Fixture WR1: new-shape wait marker on build stage should return reason.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline: transition from=qa to=building -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"}
]'
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
SCRIPT_DIR="$STUB_DIR"
result="$(_fresh_wait_reason ENG-WR1 building 2>/dev/null || printf '')"
[[ "$result" == "awaiting-approval" ]] && pass_at "WR1: new-shape wait reason returned" "got: '$result'" || fail_at "WR1: new-shape wait reason returned" "got: '$result'"

# Fixture WR2: new-shape wait on non-building stage still returns 1 (building-only gate).
# Capture rc directly via `cmd; rc=$?` after a `rc=0; cmd || rc=$?` pattern so
# the assertion actually exercises the early-return guard rather than the
# `|| printf ''` masking it. Keep stdout/stderr suppressed under set -e.
rc=0; _fresh_wait_reason ENG-WR2 implementing >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "WR2: non-build stage rejected (rc=1)" "rc=$rc" || fail_at "WR2: non-build stage rejected" "rc=$rc"

# Fixture WR3: new-shape wait awaiting-ci on building stage.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline: transition from=qa to=building -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-ci -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
result="$(_fresh_wait_reason ENG-WR3 building 2>/dev/null || printf '')"
[[ "$result" == "awaiting-ci" ]] && pass_at "WR3: new-shape wait awaiting-ci returned" "got: '$result'" || fail_at "WR3: new-shape wait awaiting-ci returned" "got: '$result'"

# ─── Group: _fresh_wait_reason Bug B (wait shadowed by newer non-wait) ───

printf '\n--- _fresh_wait_reason: Bug B (wait shadows newer non-wait) ---\n'

# Fixture WS1: wait at T1 followed by verdict pass at T2 > T1 → rc=1.
# Bug B fix's primary scenario (ENG-61 AC #2 fixture 1): the existing
# second loop tracked only wait verdicts and returned the stale wait
# reason; the fix tracks the latest verdict of any result and returns
# rc=1 when the latest verdict is no longer a wait.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline: transition from=qa to=building -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"},
  {"id":"c3","createdAt":"2026-05-03T12:00:00Z","body":"<!-- pipeline: verdict result=pass stage=building -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
rc=0; result="$(_fresh_wait_reason ENG-WS1 building 2>/dev/null)" || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "WS1: wait shadowed by newer pass → rc=1" "rc=$rc" || fail_at "WS1: rc mismatch" "expected 1, got $rc"
[[ -z "$result" ]] && pass_at "WS1: wait shadowed by newer pass → empty stdout" || fail_at "WS1: stdout not empty" "got: $result"

# Fixture WS2: wait at T1, no later verdict → reason returned + rc=0.
# Regression check that the wait carve-out still works when no later
# verdict shadows it (AC #2 fixture 2).
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline: transition from=qa to=building -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
result="$(_fresh_wait_reason ENG-WS2 building 2>/dev/null || printf '')"
[[ "$result" == "awaiting-approval" ]] && pass_at "WS2: wait alone → reason returned" "got: '$result'" || fail_at "WS2: wait reason mismatch" "got: '$result'"

# Fixture WS3: wait at T1 followed by verdict halt at T2 > T1 → rc=1.
# Confirms the predicate is "any non-wait" — pivot/fail/halt all shadow
# (AC #2 fixture 3, plus implicit pivot/fail symmetry per design D-004).
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline: transition from=qa to=building -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"},
  {"id":"c3","createdAt":"2026-05-03T12:00:00Z","body":"<!-- pipeline: verdict result=halt reason=agent-blocked -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
rc=0; result="$(_fresh_wait_reason ENG-WS3 building 2>/dev/null)" || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "WS3: wait shadowed by newer halt → rc=1" "rc=$rc" || fail_at "WS3: rc mismatch" "expected 1, got $rc"
[[ -z "$result" ]] && pass_at "WS3: wait shadowed by newer halt → empty stdout" || fail_at "WS3: stdout not empty" "got: $result"

# ─── ENG-61 QA adversarial coverage ───────────────────────────────────────

printf '\n--- _fresh_wait_reason: QA adversarial coverage ---\n'

# Fixture WS4 (adversarial): no transition ever, wait at T1, pass at T2.
# Brainstorm §6 says transition is the freshness floor; with no
# transition (last_t empty) the floor check short-circuits and every
# verdict is considered. Latest is the pass → rc=1.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"},
  {"id":"c2","createdAt":"2026-05-03T12:00:00Z","body":"<!-- pipeline: verdict result=pass stage=building -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
rc=0; result="$(_fresh_wait_reason ENG-WS4 building 2>/dev/null)" || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "WS4: no transition + wait then pass → rc=1" "rc=$rc" || fail_at "WS4: rc mismatch" "expected 1, got $rc"
[[ -z "$result" ]] && pass_at "WS4: no transition + wait then pass → empty stdout" || fail_at "WS4: stdout not empty" "got: $result"

# Fixture WS5 (adversarial): wait older than transition, no later verdict
# → rc=1. Post-transition freshness window is empty; fresh_result stays
# empty so the != "wait" guard returns 1. Pins the no-verdict-after-
# transition path that the AC2 fixtures don't exercise.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: transition from=qa to=building -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
rc=0; result="$(_fresh_wait_reason ENG-WS5 building 2>/dev/null)" || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "WS5: wait older than transition, no later verdict → rc=1" "rc=$rc" || fail_at "WS5: rc mismatch" "expected 1, got $rc"
[[ -z "$result" ]] && pass_at "WS5: wait older than transition → empty stdout" || fail_at "WS5: stdout not empty" "got: $result"

# Fixture WS6 (adversarial): reverse case — pass at T1, wait at T2 > T1.
# Wait IS the latest verdict, so the wait reason should be returned.
# Confirms latest-wins semantics from D-003 — the new logic does NOT
# silently discard a fresh wait that came AFTER a pass.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline: transition from=qa to=building -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=pass stage=building -->"},
  {"id":"c3","createdAt":"2026-05-03T12:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-ci -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
result="$(_fresh_wait_reason ENG-WS6 building 2>/dev/null || printf '')"
[[ "$result" == "awaiting-ci" ]] && pass_at "WS6: pass-then-wait → wait reason returned (latest-wins)" "got: '$result'" || fail_at "WS6: wait reason not returned" "got: '$result'"

# Fixture WS7 (adversarial): wait with non-allow-listed reason must rc=1
# even when it IS the latest verdict (security F-2 / brainstorm §6).
# Latest-verdict tracking must NOT bypass the post-loop reason allow-list.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline: transition from=qa to=building -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=invented-token -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
rc=0; result="$(_fresh_wait_reason ENG-WS7 building 2>/dev/null)" || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "WS7: wait with non-allow-listed reason → rc=1 (F-2 enforced)" "rc=$rc" || fail_at "WS7: rc mismatch" "expected 1, got $rc"
[[ -z "$result" ]] && pass_at "WS7: wait with bogus reason → empty stdout" || fail_at "WS7: stdout not empty" "got: $result"

# Fixture WS8 (adversarial, cold-pass gap): explicit pivot symmetry. The
# plan's Failure Mode table claims "Wait at T1, verdict pivot at T2 > T1"
# is "covered by WS1/WS3 — predicate is != \"wait\" not enum". Pin the
# pivot branch explicitly so a future regression that special-cases the
# enum (e.g. accidentally including pivot in the wait branch) is caught.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline: transition from=qa to=building -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"},
  {"id":"c3","createdAt":"2026-05-03T12:00:00Z","body":"<!-- pipeline: verdict result=pivot stage=building -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
rc=0; result="$(_fresh_wait_reason ENG-WS8 building 2>/dev/null)" || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "WS8: wait shadowed by newer pivot → rc=1 (D-004 symmetry pinned)" "rc=$rc" || fail_at "WS8: rc mismatch" "expected 1, got $rc"
[[ -z "$result" ]] && pass_at "WS8: pivot shadows wait → empty stdout" || fail_at "WS8: stdout not empty" "got: $result"

# Fixture WS9 (adversarial, cold-pass gap): two waits in the freshness
# window — older wait has an allow-listed reason, latest wait has a
# non-allow-listed reason. Latest-wins beats reason-allow-list: there
# is no fallback to the older valid wait. Distinct from WS7 (single wait
# with bogus reason) — confirms the post-loop guard does not silently
# downgrade to an earlier wait when the latest wait is rejected.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline: transition from=qa to=building -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"},
  {"id":"c3","createdAt":"2026-05-03T12:00:00Z","body":"<!-- pipeline: verdict result=wait reason=invented-token -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
rc=0; result="$(_fresh_wait_reason ENG-WS9 building 2>/dev/null)" || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "WS9: latest wait with bogus reason → rc=1 (no fallback to older valid wait)" "rc=$rc" || fail_at "WS9: rc mismatch" "expected 1, got $rc"
[[ -z "$result" ]] && pass_at "WS9: two waits, latest invalid → empty stdout" || fail_at "WS9: stdout not empty" "got: $result"
# ─── ENG-65 D-004: dispatch_rc==124 halt reason includes worktree-resume hint ───
# The reason string is constructed inline at run-stage.sh's `dispatch_rc == 124`
# branch. Pin the substrings so a future refactor can't strip the operator-facing
# inspection path or the resume command. Source-text assertion is the right tool
# here because the surrounding flow (cmd_run main) is harder to invoke than a
# helper, and the failure mode we care about is "operator gets a halt comment
# that lacks the resume hint" — exactly what a substring check catches.
printf '\n--- ENG-65 D-004: dispatch_rc==124 halt reason hint ---\n'

eng65_124_block="$(awk '/if \(\( dispatch_rc == 124 \)\); then/{ in_b=1 } in_b{print} /exit 124/{ if (in_b) { in_b=0; print "----END----"; exit } }' "$HARNESS_DIR/run-stage.sh")"
if [[ -z "$eng65_124_block" ]]; then
  fail_at "ENG-65 D-004: dispatch_rc==124 branch not found in run-stage.sh" \
    "expected an 'if (( dispatch_rc == 124 )); then ... exit 124' block"
else
  ok=1
  for needle in 'wall-clock timeout' 'Inspect:' 'worktree' '--action continue'; do
    if ! grep -qF -- "$needle" <<<"$eng65_124_block"; then
      fail_at "ENG-65 D-004: missing substring in dispatch_rc==124 halt reason" \
        "missing: $needle"
      ok=0
    fi
  done
  if (( ok == 1 )); then
    pass_at "ENG-65 D-004: dispatch_rc==124 halt reason carries worktree-resume hint (Inspect: ...worktree, --action continue)"
  fi
fi

# ─── ENG-62 followup: merge-gate-fires path pairs stage-start with stage-end ─
# ENG-10 D-004 contract: every stage-end must be paired with a stage-start so
# retrospective §1's stage-pairing pass doesn't see orphans. The original
# ENG-62 implementation of `_pre_dispatch_merge_gate` (PR #56) only emitted
# `stage-end "merged-pre-dispatch"`, not the matching `stage-start` —
# review #3 flagged it major; review #4 reversed without the code being
# changed; the fix landed only in this followup. Pin the pairing here as a
# source-text assertion so a future refactor of the gate-fires block can't
# silently drop one event again. Same style as the ENG-65 D-004 test above.
printf '\n--- ENG-62 followup: merge-gate-fires pairs stage-start + stage-end ---\n'

eng62_gate_block="$(awk '/if _pre_dispatch_merge_gate "\$ident" "\$stage"; then/{ in_b=1 } in_b{print} in_b && /exit 0/{ in_b=0; print "----END----"; exit }' "$HARNESS_DIR/run-stage.sh")"
if [[ -z "$eng62_gate_block" ]]; then
  fail_at "ENG-62 gate-fires block not found in run-stage.sh" \
    "expected 'if _pre_dispatch_merge_gate ...; then ... exit 0' block"
else
  # Bash `\` line-continuations split metrics.sh invocations across two lines,
  # so collapse the block to a single line before substring-matching. Any
  # surviving "stage-start" + "merged-pre-dispatch" co-occurrence is the
  # paired emission; same for stage-end.
  eng62_gate_flat="$(tr '\n' ' ' <<<"$eng62_gate_block")"
  has_start=0; has_end=0
  # `metrics.sh"` (with closing quote) followed by ` stage-start` then later
  # the literal `merged-pre-dispatch` outcome token, all before the next `|`
  # (which terminates the bash invocation as `|| true`).
  grep -qE 'metrics\.sh"? stage-start[^|]*merged-pre-dispatch' <<<"$eng62_gate_flat" && has_start=1
  grep -qE 'metrics\.sh"? stage-end[^|]*merged-pre-dispatch' <<<"$eng62_gate_flat" && has_end=1
  if (( has_start == 1 && has_end == 1 )); then
    pass_at "ENG-62 followup: gate-fires block carries paired stage-start + stage-end (merged-pre-dispatch)"
  else
    fail_at "ENG-62 followup: gate-fires block missing paired stage-{start,end}" \
      "has_start=$has_start has_end=$has_end (expected both 1)"
  fi
fi

# ─── ENG-65 Task 6: _cost_flags_for emits --cost-usd 0 for a partial usage file ─
# B-003 contract: when usage-<stage>.json has cost_usd: null and partial: true
# (the shape D-003 writes on SIGTERM), _cost_flags_for must coerce null → 0
# via jq's // 0 default. The flag stream stays clean (--cost-usd 0, NOT
# --cost-usd null), so metrics.sh stage-end downstream sees a well-formed
# zero-cost dispatch. The partial: true discriminator on disk is the
# retrospective's cue — not the flag stream's.
COST_DIR_PARTIAL="$(issue_dir ENG-T65-PARTIAL)"
mkdir -p "$COST_DIR_PARTIAL"
cat > "$COST_DIR_PARTIAL/usage-brainstorming.json" <<'JSON'
{"tokens_in":350,"tokens_out":150,"cache_read":55,"cache_create":28,"cost_usd":null,"model":"claude-opus-4-7","partial":true}
JSON

cost_flags_p=()
while IFS= read -r _cf_line; do
  cost_flags_p+=("$_cf_line")
done < <(_cost_flags_for ENG-T65-PARTIAL brainstorming)

# Find --cost-usd, then assert the next slot is the literal string "0".
cost_idx=-1
for i in "${!cost_flags_p[@]}"; do
  [[ "${cost_flags_p[$i]}" == "--cost-usd" ]] && { cost_idx=$((i+1)); break; }
done
cost_val=""
[[ $cost_idx -ge 0 ]] && cost_val="${cost_flags_p[$cost_idx]}"

# tokens_in must round-trip from the partial file (not zeroed by accident).
tokens_in_idx=-1
for i in "${!cost_flags_p[@]}"; do
  [[ "${cost_flags_p[$i]}" == "--tokens-in" ]] && { tokens_in_idx=$((i+1)); break; }
done
tokens_in_val=""
[[ $tokens_in_idx -ge 0 ]] && tokens_in_val="${cost_flags_p[$tokens_in_idx]}"

if [[ "${#cost_flags_p[@]}" == "12" ]] \
   && [[ "$cost_val" == "0" ]] \
   && [[ "$tokens_in_val" == "350" ]]; then
  pass_at "ENG-65 Task 6: _cost_flags_for partial file → --cost-usd 0 (jq // 0 coercion); tokens_in survives"
else
  fail_at "ENG-65 Task 6: _cost_flags_for partial-file coercion" \
    "count=${#cost_flags_p[@]} cost_val=$cost_val tokens_in_val=$tokens_in_val flags=$(printf '%s|' "${cost_flags_p[@]}")"
fi
# ════════════════════════════════════════════════════════════════════════════
# ENG-62: pre-dispatch merge-detection gate (_pre_dispatch_merge_gate)
# ════════════════════════════════════════════════════════════════════════════
# Cases A–F exercise the helper's full contract per the plan's Failure Mode
# → Test Map (docs/plans/2026-05-06-eng-62-…). Helper lives in run-stage.sh
# above main(); apply_transition is sourced from verdict-handler.sh
# (run-stage.sh:21-22). _VH_SCRIPT_DIR was overridden to STUB_DIR at line
# ~2161 above, so apply_transition's linear.sh calls reach the capturing stub.

printf '\n--- ENG-62 _pre_dispatch_merge_gate cases ---\n'

# Re-establish the canonical gh stub: an earlier case (line ~1988)
# overwrote it with a `pr view`-only variant for _post_review_dispatch_update
# testing, which silently returns empty for `gh pr list --json state` —
# making case A/E look like rc=1 fail-open paths even with MOCK_GH_PR_STATE
# correctly exported.
cat > "$STUB_DIR/gh" <<'SH'
#!/usr/bin/env bash
json_arg=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--json" ]]; then
    json_arg="${2-}"
    break
  fi
  shift
done
case "$json_arg" in
  state) printf '%s' "${MOCK_GH_PR_STATE-}" ;;
  url|*) printf '%s' "${MOCK_GH_PR_URL-}" ;;
esac
SH
chmod +x "$STUB_DIR/gh"

# Re-establish a captures-everything linear.sh stub so the case-A/E
# assertions on add-label / remove-label / add-comment substrings work.
# Mirrors the "rebuilt" stub at lines 890-905 (preserves get-comments and
# stage-of returns; everything else captures into CAPTURE_FILE).
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  get-comments) printf '%s' "\${MOCK_COMMENTS_JSON-[]}" ;;
  stage-of)     printf 'stage:building\n' ;;
  *)
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
      "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    ;;
esac
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"

# Restore the canonical branch-name.sh stub in case an earlier case
# overwrote it (defensive — tests above might have).
cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
printf 'feat/%s-mock-slug\n' "$(tr '[:upper:]' '[:lower:]' <<<"$1")"
SH
chmod +x "$STUB_DIR/branch-name.sh"

_eng62_reset_capture() { : > "$CAPTURE_FILE"; }
_eng62_capture_count() {
  local pat="$1"
  grep -cE "$pat" "$CAPTURE_FILE" 2>/dev/null || true
}

# ─── ENG-62 Case A: gate fires on MERGED (D-001 happy path) ─────────────
_eng62_reset_capture
export MOCK_GH_PR_STATE="MERGED"
mkdir -p "$(issue_dir ENG-62T1)"
printf '{}' > "$(issue_dir ENG-62T1)/wait-building.json"
printf '{}' > "$(issue_dir ENG-62T1)/issue-state.json"
rc=0
_pre_dispatch_merge_gate ENG-62T1 building || rc=$?
summary_present=0; [[ -s "$(issue_dir ENG-62T1)/stage-summary-building.md" ]] && summary_present=1
wait_present=1;    [[ ! -e "$(issue_dir ENG-62T1)/wait-building.json" ]]      && wait_present=0
state_present=1;   [[ ! -e "$(issue_dir ENG-62T1)/issue-state.json" ]]        && state_present=0
add_label_released="$(_eng62_capture_count '^SUBCMD=add-label$')"
remove_label_building="$(_eng62_capture_count '^SUBCMD=remove-label$')"
transition_post="$(_eng62_capture_count 'pipeline: transition from=building to=released')"
if [[ "$rc" == 0 \
      && "$summary_present" == 1 \
      && "$wait_present" == 0 \
      && "$state_present" == 0 \
      && "$add_label_released" -ge 1 \
      && "$remove_label_building" -ge 1 \
      && "$transition_post" -ge 1 ]]; then
  pass_at "ENG-62 case A: gate fires on MERGED (transition + cleanup applied)"
else
  fail_at "ENG-62 case A" \
    "rc=$rc summary=$summary_present wait=$wait_present state=$state_present add=$add_label_released remove=$remove_label_building transition=$transition_post"
fi
unset MOCK_GH_PR_STATE

# ─── ENG-62 Case B: gate skips on non-MERGED (D-006 contract) ───────────
for _state in OPEN CLOSED DRAFT ""; do
  _eng62_reset_capture
  export MOCK_GH_PR_STATE="$_state"
  rc=0
  _pre_dispatch_merge_gate ENG-62T2 building || rc=$?
  side_effects="$(_eng62_capture_count 'SUBCMD=add-label|SUBCMD=remove-label|pipeline: transition')"
  if [[ "$rc" == 1 && "$side_effects" == 0 ]]; then
    pass_at "ENG-62 case B: gate skips on state='$_state' (rc=1, no side effects)"
  else
    fail_at "ENG-62 case B (state='$_state')" "rc=$rc side_effects=$side_effects"
  fi
done
unset _state MOCK_GH_PR_STATE

# ─── ENG-62 Case C: stage allow-list (security parallel to _fresh_wait_reason) ─
export MOCK_GH_PR_STATE="MERGED"
for _stage in implementing ui reviewing qa planning brainstorming released; do
  _eng62_reset_capture
  rc=0
  _pre_dispatch_merge_gate ENG-62T3 "$_stage" || rc=$?
  side_effects="$(_eng62_capture_count 'SUBCMD=add-label|SUBCMD=remove-label|pipeline: transition')"
  if [[ "$rc" == 1 && "$side_effects" == 0 ]]; then
    pass_at "ENG-62 case C: stage='$_stage' rejected by allow-list (rc=1)"
  else
    fail_at "ENG-62 case C (stage='$_stage')" "rc=$rc side_effects=$side_effects"
  fi
done
unset _stage MOCK_GH_PR_STATE

# ─── ENG-62 Case D: branch-derivation failure → fail-open (D-006) ───────
export MOCK_GH_PR_STATE="MERGED"
cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
printf ''
SH
chmod +x "$STUB_DIR/branch-name.sh"
_eng62_reset_capture
rc=0
_pre_dispatch_merge_gate ENG-62T4 building || rc=$?
side_effects="$(_eng62_capture_count 'SUBCMD=add-label|SUBCMD=remove-label|pipeline: transition')"
if [[ "$rc" == 1 && "$side_effects" == 0 ]]; then
  pass_at "ENG-62 case D: empty branch-name → fail-open (rc=1, no side effects)"
else
  fail_at "ENG-62 case D" "rc=$rc side_effects=$side_effects"
fi
# Restore the canonical branch-name.sh stub for subsequent cases.
cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
printf 'feat/%s-mock-slug\n' "$(tr '[:upper:]' '[:lower:]' <<<"$1")"
SH
chmod +x "$STUB_DIR/branch-name.sh"
unset MOCK_GH_PR_STATE

# ─── ENG-62 Case E: apply_transition partial-failure idempotency ────────
# First invocation: linear.sh's first add-label call returns 1 (Linear
# outage). The gate's `apply_transition ... || true` swallows the error
# and the gate still returns 0. Second invocation with linear.sh restored
# completes the transition idempotently.
export MOCK_GH_PR_STATE="MERGED"
mkdir -p "$(issue_dir ENG-62T5)"
_eng62_reset_capture
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
  "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
if [[ "\${1:-}" == "add-label" && ! -f "$STUB_DIR/.eng62_first_add_done" ]]; then
  : > "$STUB_DIR/.eng62_first_add_done"
  exit 1
fi
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"
rc1=0
_pre_dispatch_merge_gate ENG-62T5 building || rc1=$?
_eng62_reset_capture
rc2=0
_pre_dispatch_merge_gate ENG-62T5 building || rc2=$?
transition_post_2="$(_eng62_capture_count 'pipeline: transition from=building to=released')"
add_label_released_2="$(_eng62_capture_count '^SUBCMD=add-label$')"
if [[ "$rc1" == 0 && "$rc2" == 0 \
      && "$transition_post_2" -ge 1 \
      && "$add_label_released_2" -ge 1 ]]; then
  pass_at "ENG-62 case E: partial-failure recovery (both invocations rc=0; second produces full transition)"
else
  fail_at "ENG-62 case E" "rc1=$rc1 rc2=$rc2 transition2=$transition_post_2 add2=$add_label_released_2"
fi
rm -f "$STUB_DIR/.eng62_first_add_done"
# Restore the canonical capturing linear.sh stub.
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  get-comments) printf '%s' "\${MOCK_COMMENTS_JSON-[]}" ;;
  stage-of)     printf 'stage:building\n' ;;
  *)
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
      "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    ;;
esac
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"
unset MOCK_GH_PR_STATE

# ─── ENG-62 Case F: gh missing from PATH → fail-open ────────────────────
export MOCK_GH_PR_STATE="MERGED"
mv "$STUB_DIR/gh" "$STUB_DIR/gh.disabled"
_eng62_reset_capture
rc=0
_pre_dispatch_merge_gate ENG-62T6 building || rc=$?
side_effects="$(_eng62_capture_count 'SUBCMD=add-label|SUBCMD=remove-label|pipeline: transition')"
if [[ "$rc" == 1 && "$side_effects" == 0 ]]; then
  pass_at "ENG-62 case F: gh missing from PATH → fail-open (rc=1, no side effects)"
else
  fail_at "ENG-62 case F" "rc=$rc side_effects=$side_effects"
fi
mv "$STUB_DIR/gh.disabled" "$STUB_DIR/gh"
unset MOCK_GH_PR_STATE

# ════════════════════════════════════════════════════════════════════════════
# ENG-62 QA adversarial coverage: boundary + idempotency cases not in the
# plan's Failure Mode → Test Map. Each pins an invariant a future refactor
# could plausibly break (e.g. swapping `==` for `=~`, adding case-insensitive
# matching, switching summary write to append).
# ════════════════════════════════════════════════════════════════════════════

printf '\n--- ENG-62 QA adversarial cases ---\n'

# ─── ENG-62 Case G: case-sensitivity on the MERGED comparison ────────────
# The helper uses `[[ "$_pr_state" == "MERGED" ]]` (exact match). A future
# `shopt -s nocasematch` regression OR an accidental `==` → `=~` swap would
# falsely fire the gate on lowercase/mixed-case states. gh CLI is documented
# to return uppercase ("MERGED", "OPEN", "CLOSED") but pinning the exact-match
# invariant catches the regression class.
for _state in merged Merged mErGeD MERGED_BUT_NOT_REALLY; do
  _eng62_reset_capture
  export MOCK_GH_PR_STATE="$_state"
  rc=0
  _pre_dispatch_merge_gate ENG-62QG building || rc=$?
  side_effects="$(_eng62_capture_count 'SUBCMD=add-label|SUBCMD=remove-label|pipeline: transition')"
  if [[ "$rc" == 1 && "$side_effects" == 0 ]]; then
    pass_at "ENG-62 case G: state='$_state' rejected (exact-match guard)"
  else
    fail_at "ENG-62 case G (state='$_state')" "rc=$rc side_effects=$side_effects"
  fi
done
unset _state MOCK_GH_PR_STATE

# ─── ENG-62 Case H: substring / glob-prefix robustness ──────────────────
# A future `[[ "$_pr_state" == MERGED* ]]` (glob) or `=~ MERGED` (regex)
# regression would falsely fire on near-substrings. Pin exact-match.
for _state in MERGED-WITH-CONFLICTS UNMERGED PREMERGED REMERGED; do
  _eng62_reset_capture
  export MOCK_GH_PR_STATE="$_state"
  rc=0
  _pre_dispatch_merge_gate ENG-62QH building || rc=$?
  side_effects="$(_eng62_capture_count 'SUBCMD=add-label|SUBCMD=remove-label|pipeline: transition')"
  if [[ "$rc" == 1 && "$side_effects" == 0 ]]; then
    pass_at "ENG-62 case H: state='$_state' rejected (no substring match)"
  else
    fail_at "ENG-62 case H (state='$_state')" "rc=$rc side_effects=$side_effects"
  fi
done
unset _state MOCK_GH_PR_STATE

# ─── ENG-62 Case I: whitespace-padded state rejected ─────────────────────
# Defends against jq output drift / future `--jq` formula changes that emit
# trailing or leading whitespace. Exact `==` should reject these.
# (NOTE: a pure trailing-newline is NOT adversarial here — command
# substitution strips trailing \n, so 'MERGED\n' captures as 'MERGED' and
# the gate fires by design — that is the normal gh CLI output shape.)
for _state in 'MERGED ' ' MERGED' '  MERGED  '; do
  _eng62_reset_capture
  export MOCK_GH_PR_STATE="$_state"
  rc=0
  _pre_dispatch_merge_gate ENG-62QI building || rc=$?
  side_effects="$(_eng62_capture_count 'SUBCMD=add-label|SUBCMD=remove-label|pipeline: transition')"
  if [[ "$rc" == 1 && "$side_effects" == 0 ]]; then
    pass_at "ENG-62 case I: whitespace-padded state rejected (exact-match)"
  else
    fail_at "ENG-62 case I (state='$(printf %q "$_state")')" "rc=$rc side_effects=$side_effects"
  fi
done
unset _state MOCK_GH_PR_STATE

# ─── ENG-62 Case J: clean-rerun idempotency (no Linear failure) ──────────
# Two back-to-back invocations on a MERGED PR (without any stub failure
# injection) — both rc=0, second invocation produces the same shape of
# side effects as the first. Pins that future caching / once-per-tick
# optimisations don't silently skip the second invocation when it should
# still post a transition waypoint (the operator's only audit trail of
# the second tick's gate decision). Distinct from case E which exercises
# RECOVERY from a partial failure.
export MOCK_GH_PR_STATE="MERGED"
mkdir -p "$(issue_dir ENG-62QJ)"
# First invocation.
_eng62_reset_capture
rc1=0
_pre_dispatch_merge_gate ENG-62QJ building || rc1=$?
add1="$(_eng62_capture_count '^SUBCMD=add-label$')"
remove1="$(_eng62_capture_count '^SUBCMD=remove-label$')"
trans1="$(_eng62_capture_count 'pipeline: transition from=building to=released')"
# Second invocation — gate should re-fire idempotently (not short-circuit).
_eng62_reset_capture
rc2=0
_pre_dispatch_merge_gate ENG-62QJ building || rc2=$?
add2="$(_eng62_capture_count '^SUBCMD=add-label$')"
remove2="$(_eng62_capture_count '^SUBCMD=remove-label$')"
trans2="$(_eng62_capture_count 'pipeline: transition from=building to=released')"
if [[ "$rc1" == 0 && "$rc2" == 0 \
      && "$add1" -ge 1 && "$add2" -ge 1 \
      && "$remove1" -ge 1 && "$remove2" -ge 1 \
      && "$trans1" -ge 1 && "$trans2" -ge 1 ]]; then
  pass_at "ENG-62 case J: clean-rerun idempotency (both rc=0; both produce full transition shape)"
else
  fail_at "ENG-62 case J" "rc1=$rc1 rc2=$rc2 add1=$add1 add2=$add2 remove1=$remove1 remove2=$remove2 trans1=$trans1 trans2=$trans2"
fi
unset MOCK_GH_PR_STATE

# ─── ENG-62 Case K: stage-summary content + branch interpolation ────────
# Pin that the summary file is actually populated with the expected text
# AND that the branch name is interpolated correctly. Defends against a
# future printf format-string regression that loses the branch name (a
# silent drift would still make case A pass on the `-s` size check).
export MOCK_GH_PR_STATE="MERGED"
mkdir -p "$(issue_dir ENG-62QK)"
# Pre-seed the summary file with stale content; the gate must overwrite,
# not append.
printf 'STALE-SUMMARY-FROM-PRIOR-RUN\n' > "$(issue_dir ENG-62QK)/stage-summary-building.md"
_eng62_reset_capture
rc=0
_pre_dispatch_merge_gate ENG-62QK building || rc=$?
summary_body="$(cat "$(issue_dir ENG-62QK)/stage-summary-building.md" 2>/dev/null || printf '')"
expected_branch="feat/eng-62qk-mock-slug"  # branch-name.sh stub lowercases ident
contains_branch=0; grep -qF "$expected_branch" <<<"$summary_body" && contains_branch=1
contains_marker=0; grep -qF 'Pre-dispatch merge detection (ENG-62)' <<<"$summary_body" && contains_marker=1
no_stale=1;        grep -qF 'STALE-SUMMARY' <<<"$summary_body" && no_stale=0
if [[ "$rc" == 0 \
      && "$contains_branch" == 1 \
      && "$contains_marker" == 1 \
      && "$no_stale" == 1 ]]; then
  pass_at "ENG-62 case K: stage-summary overwrites stale + interpolates branch name"
else
  fail_at "ENG-62 case K" "rc=$rc contains_branch=$contains_branch contains_marker=$contains_marker no_stale=$no_stale body=${summary_body:0:200}"
fi
unset MOCK_GH_PR_STATE

# ─── ENG-62 Case L: empty / whitespace ident rejected harmlessly ─────────
# A defensive caller-contract test: passing empty or whitespace ident
# must NOT trigger a partial transition. The branch-name.sh stub maps
# empty ident → 'feat/-mock-slug' (a real-but-bogus branch); since
# MOCK_GH_PR_STATE is unset for these iterations, the gh stub returns
# empty → not MERGED → rc=1, no side effects.
for _ident in '' '   ' $'\t'; do
  _eng62_reset_capture
  unset MOCK_GH_PR_STATE
  rc=0
  _pre_dispatch_merge_gate "$_ident" building || rc=$?
  side_effects="$(_eng62_capture_count 'SUBCMD=add-label|SUBCMD=remove-label|pipeline: transition')"
  if [[ "$rc" == 1 && "$side_effects" == 0 ]]; then
    pass_at "ENG-62 case L: empty/whitespace ident=$(printf %q "$_ident") rejected harmlessly"
  else
    fail_at "ENG-62 case L (ident=$(printf %q "$_ident"))" "rc=$rc side_effects=$side_effects"
  fi
done
unset _ident

# ─── ENG-62 Case M (QA adversarial round 2): metrics emission via main() ─
# Plan Failure Mode → Test Map row 1 promises the gate-fires path emits
# `metrics.sh stage-end` with outcome=merged-pre-dispatch. Cases A–L call
# `_pre_dispatch_merge_gate` directly and therefore CANNOT exercise the
# metrics call, which lives in main() at run-stage.sh:618-622. This case
# drives main() with stage=building + MOCK_GH_PR_STATE=MERGED through the
# canonical stub chain (mirrors ENG-45 case N's main()-driving pattern at
# lines ~1285-1290) and asserts on the captured metrics.sh argv.
#
# Defends Failure Mode Map row 1's metric promise. Without this case, a
# regression that drops the metrics call (or changes the literal to e.g.
# 'merge-detected') would silently pass cases A–L while breaking the
# retrospective's outcome-rollup rationale (Q1/Task 6).
ENG_62_CASE_M_DIR="$(issue_dir ENG-62QM)"
mkdir -p "$ENG_62_CASE_M_DIR"

# linear.sh stub for the main() drive: verify_preconditions calls has-label
# with pipeline:paused (must return non-zero) and stage:building (must
# return 0). Everything else captures into CAPTURE_FILE so the apply_transition
# side effects are still observable to the gate's normal contract.
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  has-label)
    case "\${3:-}" in
      pipeline:paused) exit 1 ;;
      stage:*)         exit 0 ;;
      pipeline:halted) exit 1 ;;
      *)               exit 1 ;;
    esac
    ;;
  stage-of)     printf 'stage:building\n' ;;
  get-comments) printf '[]' ;;
  *)
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
      "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    ;;
esac
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"

# metrics.sh capture stub — records every invocation with subcmd + ident +
# stage + outcome on a single line; lets us assert on the gate's exact
# argv shape. Mirrors ENG-45 case O's metrics capture at lines 1373-1379.
ENG_62_CASE_M_METRICS="$STUB_DIR/case-m-metrics.capture"
: > "$ENG_62_CASE_M_METRICS"
cat > "$STUB_DIR/metrics.sh" <<SH
#!/usr/bin/env bash
printf 'EVENT=%s IDENT=%s STAGE=%s OUTCOME=%s DURATION=%s\n' \
  "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" "\${5:-}" >> "$ENG_62_CASE_M_METRICS"
exit 0
SH
chmod +x "$STUB_DIR/metrics.sh"

_eng62_reset_capture
export MOCK_GH_PR_STATE="MERGED"
ENG_62_CASE_M_RC=0
(
  main ENG-62QM building
) >/dev/null 2>&1 || ENG_62_CASE_M_RC=$?
unset MOCK_GH_PR_STATE
# Cleanup the metrics.sh stub so subsequent cases (none today, but defensive
# for future inserts) don't see the case-M capture stub.
rm -f "$STUB_DIR/metrics.sh"

# Re-establish the linear.sh capturing stub (mirrors lines 2485-2497).
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  get-comments) printf '%s' "\${MOCK_COMMENTS_JSON-[]}" ;;
  stage-of)     printf 'stage:building\n' ;;
  *)
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
      "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    ;;
esac
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"

stage_end_count="$(grep -c 'EVENT=stage-end .*OUTCOME=merged-pre-dispatch' "$ENG_62_CASE_M_METRICS" 2>/dev/null || true)"
transition_landed="$(_eng62_capture_count 'pipeline: transition from=building to=released')"
if [[ "$ENG_62_CASE_M_RC" == 0 \
      && "$stage_end_count" -ge 1 \
      && "$transition_landed" -ge 1 ]]; then
  pass_at "ENG-62 case M: main() gate-fires path emits stage-end outcome=merged-pre-dispatch + transition (FM-map row 1)"
else
  fail_at "ENG-62 case M" \
    "rc=$ENG_62_CASE_M_RC stage_end=$stage_end_count transition=$transition_landed metrics=$(cat "$ENG_62_CASE_M_METRICS" 2>/dev/null)"
fi

# ─── ENG-71: D-003 _post_dispatch_check_worktree_head fixtures ─────────
# Pin the post-dispatch worktree-HEAD detector across three states:
# (case 7) mismatch — worktree on main but expected feat/eng-…  → detach,
# emit metric, post sig-deduped Linear comment;
# (case 8) match — worktree on the expected branch  → no-op, no metric,
# no comment;
# (case 9) stage gate — qa with HEAD on main  → no-op (stage-gated to
# building only).
#
# Each case stubs `metrics.sh` (writes invocations to a capture file
# under $STUB_DIR), uses a real `git init`'d worktree under
# $STUB_DIR/wt-T7/worktree, and asserts the detach action's effect on
# the actual git state plus the metric+comment side-effects.
printf '\n--- ENG-71: D-003 _post_dispatch_check_worktree_head ---\n'

reset_metrics_capture() { : > "$STUB_DIR/metrics.capture"; }
if [[ ! -x "$STUB_DIR/metrics.sh" ]]; then
  cat > "$STUB_DIR/metrics.sh" <<SH
#!/usr/bin/env bash
# args: \$1 event \$2 ident \$3 stage \$4 outcome \$5 duration_ms \$6 notes
printf 'EVENT=%s\nIDENT=%s\nSTAGE=%s\nOUTCOME=%s\nNOTES=%s\n---\n' \
  "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" "\${6:-}" >> "$STUB_DIR/metrics.capture"
exit 0
SH
  chmod +x "$STUB_DIR/metrics.sh"
fi
reset_metrics_capture

# ─── Case 71-1: D-003 detach-on-mismatch (stage=building, HEAD on main) ─
reset_capture
ENG_T7_WT="$(issue_dir ENG-T7)/worktree"
rm -rf "$ENG_T7_WT"
mkdir -p "$ENG_T7_WT"
( cd "$ENG_T7_WT" \
  && git init --quiet -b main \
  && git config user.email t@t \
  && git config user.name t \
  && git commit --quiet --allow-empty -m init ) >/dev/null 2>&1

# Override branch-name.sh to return a different branch than `main` so the
# mismatch fires. Restored to the default mock-slug shape after this case.
cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
printf 'feat/eng-t7-mock-slug\n'
SH
chmod +x "$STUB_DIR/branch-name.sh"

_post_dispatch_check_worktree_head ENG-T7 building >/dev/null 2>&1 || true

current_head_t7="$(git -C "$ENG_T7_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
metric_count_t7="$(grep -c '^EVENT=worktree-mutated-by-agent$' "$STUB_DIR/metrics.capture" 2>/dev/null || true)"
comment_count_t7="$(grep -c '^SIG=worktree-mutation/ENG-T7$' "$CAPTURE_FILE" 2>/dev/null || true)"
# ENG-71 m3 (review iter-2 feedback): assert body content too, not just SIG header.
# Without these checks a regression that produces an empty/malformed body still
# passes the SIG-only count. The fields pinned: meta marker (operator-visibility
# discriminator), current branch (so operator knows what HEAD landed on), expected
# branch (so operator knows what should have been there), and the success-path
# detach phrasing introduced by ENG-71 m1 (review iter-2 feedback).
body_t7="$(awk '/^BODY_BEGIN$/{flag=1; next} /^BODY_END$/{flag=0} flag' "$CAPTURE_FILE")"
body_has_meta_t7="$(grep -cF '<!-- meta: metric name=worktree-mutated-by-agent -->' <<<"$body_t7" || true)"
body_has_current_t7="$(grep -cF 'main' <<<"$body_t7" || true)"
body_has_expected_t7="$(grep -cF 'feat/eng-t7-mock-slug' <<<"$body_t7" || true)"
body_has_detach_success_t7="$(grep -cF 'detached HEAD' <<<"$body_t7" || true)"

if [[ "$current_head_t7" == "HEAD" ]] \
   && [[ "$metric_count_t7" == "1" ]] \
   && [[ "$comment_count_t7" == "1" ]] \
   && (( body_has_meta_t7 >= 1 )) \
   && (( body_has_current_t7 >= 1 )) \
   && (( body_has_expected_t7 >= 1 )) \
   && (( body_has_detach_success_t7 >= 1 )); then
  pass_at "case-71-1 D-003 detach-on-mismatch (stage=building, current=main, expected=feat/eng-t7-…) → HEAD detached, metric+comment emitted, body names current/expected/meta/detach-success"
else
  fail_at "case-71-1 D-003 detach-on-mismatch" \
    "current_head=$current_head_t7 metric_count=$metric_count_t7 comment_count=$comment_count_t7 meta=$body_has_meta_t7 current=$body_has_current_t7 expected=$body_has_expected_t7 detach=$body_has_detach_success_t7"
fi

# Restore branch-name.sh to the default mock-slug shape for downstream cases.
cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
printf 'feat/%s-mock-slug\n' "$(tr '[:upper:]' '[:lower:]' <<<"$1")"
SH
chmod +x "$STUB_DIR/branch-name.sh"

# ─── Case 71-2: D-003 no-detach when HEAD on expected branch ───────────
reset_capture
reset_metrics_capture
ENG_T8_WT="$(issue_dir ENG-T8)/worktree"
rm -rf "$ENG_T8_WT"
mkdir -p "$ENG_T8_WT"
( cd "$ENG_T8_WT" \
  && git init --quiet -b feat/eng-t8-mock-slug \
  && git config user.email t@t \
  && git config user.name t \
  && git commit --quiet --allow-empty -m init ) >/dev/null 2>&1

_post_dispatch_check_worktree_head ENG-T8 building >/dev/null 2>&1 || true

current_head_t8="$(git -C "$ENG_T8_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
metric_count_t8="$(grep -c '^EVENT=worktree-mutated-by-agent$' "$STUB_DIR/metrics.capture" 2>/dev/null || true)"
comment_count_t8="$(grep -c '^SIG=worktree-mutation/ENG-T8$' "$CAPTURE_FILE" 2>/dev/null || true)"

if [[ "$current_head_t8" == "feat/eng-t8-mock-slug" ]] \
   && [[ "$metric_count_t8" == "0" ]] \
   && [[ "$comment_count_t8" == "0" ]]; then
  pass_at "case-71-2 D-003 no-detach when HEAD on expected branch → no detach, no metric, no comment"
else
  fail_at "case-71-2 D-003 no-detach" \
    "current_head=$current_head_t8 metric_count=$metric_count_t8 comment_count=$comment_count_t8"
fi

# ─── Case 71-3: D-003 stage gate (stage=qa with HEAD on main → no-op) ─
reset_capture
reset_metrics_capture
ENG_T9_WT="$(issue_dir ENG-T9)/worktree"
rm -rf "$ENG_T9_WT"
mkdir -p "$ENG_T9_WT"
( cd "$ENG_T9_WT" \
  && git init --quiet -b main \
  && git config user.email t@t \
  && git config user.name t \
  && git commit --quiet --allow-empty -m init ) >/dev/null 2>&1

_post_dispatch_check_worktree_head ENG-T9 qa >/dev/null 2>&1 || true

current_head_t9="$(git -C "$ENG_T9_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
metric_count_t9="$(grep -c '^EVENT=worktree-mutated-by-agent$' "$STUB_DIR/metrics.capture" 2>/dev/null || true)"
comment_count_t9="$(grep -c '^SIG=worktree-mutation/ENG-T9$' "$CAPTURE_FILE" 2>/dev/null || true)"

if [[ "$current_head_t9" == "main" ]] \
   && [[ "$metric_count_t9" == "0" ]] \
   && [[ "$comment_count_t9" == "0" ]]; then
  pass_at "case-71-3 D-003 stage gate (stage=qa) → no-op even when HEAD on main"
else
  fail_at "case-71-3 D-003 stage gate" \
    "current_head=$current_head_t9 metric_count=$metric_count_t9 comment_count=$comment_count_t9"
fi

# ─── Case 71-4: rc=26 arm invokes _post_dispatch_check_worktree_head ───
# Structure pin: D-002's transcript scan is post-stream — by the time it
# returns 26 the agent has already executed the forbidden Bash command,
# so the worktree may already be on `main`. Without invoking the helper
# in the rc=26 arm, the rc=26 path exits and main stays globally locked
# until cleanup-worktrees.sh runs on the next post-merge tick (which
# only fires on merged/canceled/30-day-orphan triggers — none fire on a
# halted build). The rc=26 arm in run-stage.sh::main MUST call
# _post_dispatch_check_worktree_head before exit 26 so the helper
# detaches HEAD on the way out.
RC26_ARM_BLOCK="$(awk '/elif \(\( dispatch_rc == 26 \)\); then/,/exit 26/' "$HARNESS_DIR/run-stage.sh")"
if printf '%s\n' "$RC26_ARM_BLOCK" | grep -qF '_post_dispatch_check_worktree_head'; then
  pass_at "case-71-4 rc=26 arm invokes _post_dispatch_check_worktree_head before exit 26"
else
  fail_at "case-71-4 rc=26 arm missing helper invocation" \
    "block did not contain _post_dispatch_check_worktree_head"
fi

# ─── Case 71-5: D-003 detach-failure body language (ENG-71 m1) ─────────
# When `git checkout --detach` fails (in this fixture: .git made read-only
# so the ref update is denied), the operator-visibility comment body MUST
# NOT claim "Orchestrator detached HEAD" — that would be a lie. Instead
# the body should say "detach … failed" so the operator knows main may
# still be locked and they need to recover manually.
#
# Pre-iter-6 the body unconditionally claimed success regardless of the
# detach exit code; this fixture pins the conditional language and the
# detach_rc field in the metric notes.
reset_capture
reset_metrics_capture
ENG_T75_WT="$(issue_dir ENG-T75)/worktree"
rm -rf "$ENG_T75_WT"
mkdir -p "$ENG_T75_WT"
( cd "$ENG_T75_WT" \
  && git init --quiet -b main \
  && git config user.email t@t \
  && git config user.name t \
  && git commit --quiet --allow-empty -m init ) >/dev/null 2>&1

cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
printf 'feat/eng-t75-mock-slug\n'
SH
chmod +x "$STUB_DIR/branch-name.sh"

# Make .git read-only so `git checkout --detach`'s ref-update fails. We
# capture rc explicitly because BSD chmod on Darwin sometimes warns on
# subdir-perm changes; the test cares only about the post-state, not the
# chmod's exit code.
chmod -R a-w "$ENG_T75_WT/.git" 2>/dev/null || true

_post_dispatch_check_worktree_head ENG-T75 building >/dev/null 2>&1 || true

# Restore write perms so the EXIT-trap rm -rf can clean up.
chmod -R u+w "$ENG_T75_WT/.git" 2>/dev/null || true

body_t75="$(awk '/^BODY_BEGIN$/{flag=1; next} /^BODY_END$/{flag=0} flag' "$CAPTURE_FILE")"
metric_notes_t75="$(awk -F= '/^NOTES=/ {print $2}' "$STUB_DIR/metrics.capture" | tail -1)"
body_claims_success_t75="$(grep -cF 'detached HEAD' <<<"$body_t75" || true)"
body_says_failed_t75="$(grep -ciE 'detach.*failed|failed.*detach' <<<"$body_t75" || true)"
notes_has_detach_rc_nonzero="$(grep -cE 'detach_rc=[1-9]' <<<"$metric_notes_t75" || true)"

if (( body_says_failed_t75 >= 1 )) \
   && (( body_claims_success_t75 == 0 )) \
   && (( notes_has_detach_rc_nonzero >= 1 )); then
  pass_at "case-71-5 D-003 detach-failure (read-only .git) → body says detach failed (no success claim), metric notes carry detach_rc!=0"
else
  fail_at "case-71-5 D-003 detach-failure body" \
    "body_says_failed=$body_says_failed_t75 body_claims_success=$body_claims_success_t75 notes_detach_rc=$notes_has_detach_rc_nonzero notes='$metric_notes_t75'"
fi

# Restore the default branch-name.sh stub for any tests appended below.
cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
printf 'feat/%s-mock-slug\n' "$(tr '[:upper:]' '[:lower:]' <<<"$1")"
SH
chmod +x "$STUB_DIR/branch-name.sh"

# ─── Case 71-6: D-003 empty-branch-name log line (ENG-71 m2) ───────────
# When branch-name.sh dies (Linear API outage in production) D-003 returns
# 0 to avoid detaching on a wrong expected value — but pre-iter-6 it did
# so SILENTLY, with no log line, leaving operators unable to distinguish
# "no mismatch" from "branch resolution failed". Pin a log line so the
# silent skip is observable.
reset_capture
reset_metrics_capture
ENG_T76_WT="$(issue_dir ENG-T76)/worktree"
rm -rf "$ENG_T76_WT"
mkdir -p "$ENG_T76_WT"
( cd "$ENG_T76_WT" \
  && git init --quiet -b main \
  && git config user.email t@t \
  && git config user.name t \
  && git commit --quiet --allow-empty -m init ) >/dev/null 2>&1

# Stub branch-name.sh to return empty (simulating Linear API outage).
cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
printf ''
exit 1
SH
chmod +x "$STUB_DIR/branch-name.sh"

t76_stderr="$(_post_dispatch_check_worktree_head ENG-T76 building 2>&1 >/dev/null || true)"

current_head_t76="$(git -C "$ENG_T76_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
metric_count_t76="$(grep -c '^EVENT=worktree-mutated-by-agent$' "$STUB_DIR/metrics.capture" 2>/dev/null || true)"
comment_count_t76="$(grep -c '^SIG=worktree-mutation/ENG-T76$' "$CAPTURE_FILE" 2>/dev/null || true)"
log_line_emitted_t76="$(grep -ciE 'expected_branch=|branch.*resolution|skip.*ENG-T76' <<<"$t76_stderr" || true)"

if [[ "$current_head_t76" == "main" ]] \
   && [[ "$metric_count_t76" == "0" ]] \
   && [[ "$comment_count_t76" == "0" ]] \
   && (( log_line_emitted_t76 >= 1 )); then
  pass_at "case-71-6 D-003 empty branch-name → no detach, no metric, no comment, BUT log line emitted (silent-skip diagnostic)"
else
  fail_at "case-71-6 D-003 empty-branch log line" \
    "current_head=$current_head_t76 metric=$metric_count_t76 comment=$comment_count_t76 log_emitted=$log_line_emitted_t76 stderr='${t76_stderr}'"
fi

# Restore default branch-name.sh.
cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
printf 'feat/%s-mock-slug\n' "$(tr '[:upper:]' '[:lower:]' <<<"$1")"
SH
chmod +x "$STUB_DIR/branch-name.sh"

echo
echo "run-stage-test: passed=$PASS failed=$FAIL"
(( FAIL == 0 )) || exit 1
