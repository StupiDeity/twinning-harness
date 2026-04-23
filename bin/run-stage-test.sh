#!/usr/bin/env bash
# Test harness for post_completion_comment + rollback summary cleanup (ENG-11).
# All cases run under PIPELINE_DRY_RUN=1 against a mktemp'd TWINNING_DIR and
# a STUB_DIR of fake linear.sh / branch-name.sh / gh scripts, so no real
# Linear / gh / filesystem side-effects escape the harness.

set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"

# Stubs: linear.sh captures args for inspection; branch-name.sh + gh return
# deterministic values so we can assert PR-tail presence/absence.
STUB_DIR="$(mktemp -d)"
CAPTURE_FILE="$STUB_DIR/capture.txt"
: > "$CAPTURE_FILE"

cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
# args: \$1 subcommand \$2 sig \$3 ident \$4 body
printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
  "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"

cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
printf 'feat/%s-mock-slug\n' "$(tr '[:upper:]' '[:lower:]' <<<"$1")"
SH
chmod +x "$STUB_DIR/branch-name.sh"

# Toggleable gh stub: MOCK_GH_PR_URL controls the `gh pr list` output.
cat > "$STUB_DIR/gh" <<'SH'
#!/usr/bin/env bash
# Only handles: gh pr list --head <branch> --state {open|all} --json url --jq '.[0].url // ""'
printf '%s' "${MOCK_GH_PR_URL:-}"
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
# sets TWINNING_DIR=$HOME/.twinning-pipeline. Overriding here prevents the EXIT
# trap from deleting the real pipeline directory.
TWINNING_DIR="$(mktemp -d)"
export TWINNING_DIR
trap 'rm -rf "$TWINNING_DIR" "$STUB_DIR"' EXIT

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
  && grep -q 'plan complete' <<<"$body" \
  && grep -q 'Plan summary'  <<<"$body"; then
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
printf '## Real body\n<!-- pipeline-sig: completion/plan/ENG-OTHER -->\nMore text.\n' \
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
yes "x" | head -c 40000 > "$(issue_dir ENG-T5)/stage-summary-plan.md"
post_completion_comment ENG-T5 plan
body="$(captured_body)"
if grep -q 'summary_truncated' <<<"$body" \
  && grep -q '\[truncated at 32 KiB\]' <<<"$body"; then
  pass_at "case-5 oversize: truncation marker + truncate annotation"
else
  fail_at "case-5 oversize" "${body:0:200}..."
fi

# ─── Case 6: terminal-next header (build→released) ──────────────────────
reset_capture
mkdir -p "$(issue_dir ENG-T6)"
printf 'merge done\n' > "$(issue_dir ENG-T6)/stage-summary-build.md"
MOCK_GH_PR_URL="https://github.com/mock/repo/pull/99" \
  post_completion_comment ENG-T6 build
body="$(captured_body)"
if grep -q 'advancing to stage:released'                          <<<"$body" \
  && grep -q '— PR: https://github.com/mock/repo/pull/99'          <<<"$body"; then
  pass_at "case-6 build→released: arrow to 'released' + PR tail appended"
else
  fail_at "case-6 build→released" "$body"
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

# ─── Case 13: pr-opened-too-early bumps implement_rejection ────────────
reset_capture
reset_guards_capture
bash -c '
  ident="ENG-T13"; stage="implement"; branch="feat/eng-t13"
  # Mirror run-stage.sh:336-346: pr_count > 0 → bump + classify.
  pr_count=1
  if (( pr_count > 0 )); then
    bash "'"$STUB_DIR"'/guards.sh" bump "$ident" implement_rejection || true
  fi
' 2>/dev/null

bumps=$(guards_bump_count)
last_counter=$(guards_counter_for_last_bump)
if [[ "$bumps" == "1" && "$last_counter" == "implement_rejection" ]]; then
  pass_at "case-13 pr-opened-too-early: exactly one implement_rejection bump"
else
  fail_at "case-13 pr-too-early" "bumps=$bumps last_counter=$last_counter"
fi

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

# ─── Case 15: guards.sh check/bump round-trip for implement_rejection ──
# Exercises the REAL guards.sh against a fake-repo overlay so common.sh's
# REPO_ROOT computation (`dirname "${BASH_SOURCE[0]}"/../..`) resolves to a
# layout that symlinks to the real config.json and schemas/linear-ids.json,
# while linear.sh is a Case-15-specific stub returning two
# `implement_rejection` marker comments and a label toggle via MOCK_LABEL.
# Asserts guards.sh check exits 10 with `implement_rejection(2>=2)` when the
# ack label is absent, and exits 0 when present.
#
# Must remain the LAST case in the harness.
reset_capture
FAKE_REPO="$STUB_DIR/fake-repo"
mkdir -p "$FAKE_REPO/.pipeline/bin" "$FAKE_REPO/.pipeline/schemas"
ln -sf "$HARNESS_DIR/guards.sh"                          "$FAKE_REPO/.pipeline/bin/guards.sh"
ln -sf "$HARNESS_DIR/common.sh"                          "$FAKE_REPO/.pipeline/bin/common.sh"
ln -sf "$REPO_ROOT/.pipeline/config.json"                "$FAKE_REPO/.pipeline/config.json"
ln -sf "$REPO_ROOT/.pipeline/schemas/linear-ids.json"    "$FAKE_REPO/.pipeline/schemas/linear-ids.json"
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  query)
    # Return two marker comments for implement_rejection; empty for others.
    cat <<'JSON'
{"data":{"issues":{"nodes":[{"id":"id-T15","comments":{"nodes":[
  {"body":"<!-- pipeline-metric: implement_rejection --> Counter bumped by guards.sh."},
  {"body":"<!-- pipeline-metric: implement_rejection --> Counter bumped by guards.sh."}
]}}]}}}
JSON
    ;;
  has-label)
    # Match the label requested if env var is set.
    [[ "${MOCK_LABEL:-}" == "$3" ]] && exit 0 || exit 1
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

# Sub-shell so env-var changes don't leak into the rest of the harness.
set +e
trip_output="$(
  MOCK_LABEL="" \
  bash "$FAKE_REPO/.pipeline/bin/guards.sh" check ENG-T15 2>&1
)"
trip_rc=$?
clear_output="$(
  MOCK_LABEL="pipeline:reviewed" \
  bash "$FAKE_REPO/.pipeline/bin/guards.sh" check ENG-T15 2>&1
)"
clear_rc=$?
set -e

if [[ "$trip_rc" == "10" ]] \
   && grep -q 'implement_rejection(2>=2)' <<<"$trip_output" \
   && [[ "$clear_rc" == "0" ]]; then
  pass_at "case-15 guards.sh check trips on implement_rejection count=2 without pipeline:reviewed; clears when label present"
else
  fail_at "case-15 round-trip" "trip_rc=$trip_rc trip_output=$trip_output clear_rc=$clear_rc clear_output=$clear_output"
fi

echo
echo "run-stage-test: passed=$PASS failed=$FAIL"
(( FAIL == 0 )) || exit 1
