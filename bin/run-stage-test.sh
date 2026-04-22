#!/usr/bin/env bash
# Test harness for post_completion_comment + rollback summary cleanup (ENG-11).
# All cases run under PIPELINE_DRY_RUN=1 against a mktemp'd TWINNING_DIR and
# a STUB_DIR of fake linear.sh / branch-name.sh / gh scripts, so no real
# Linear / gh / filesystem side-effects escape the harness.

set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Isolate on-disk state.
TWINNING_DIR="$(mktemp -d)"
export TWINNING_DIR
export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"

# Stubs: linear.sh captures args for inspection; branch-name.sh + gh return
# deterministic values so we can assert PR-tail presence/absence.
STUB_DIR="$(mktemp -d)"
CAPTURE_FILE="$STUB_DIR/capture.txt"
: > "$CAPTURE_FILE"
trap 'rm -rf "$TWINNING_DIR" "$STUB_DIR"' EXIT

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

# Source common.sh + run-stage.sh so post_completion_comment is defined.
# run-stage.sh's sentinel at :307 `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` means
# sourcing does NOT run main(); no no-op sentinel variable needed.
# shellcheck source=common.sh
source "$HARNESS_DIR/common.sh"
# shellcheck source=classify-failure.sh
source "$HARNESS_DIR/classify-failure.sh"
# shellcheck source=run-stage.sh
source "$HARNESS_DIR/run-stage.sh"

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

echo
echo "run-stage-test: passed=$PASS failed=$FAIL"
(( FAIL == 0 )) || exit 1
