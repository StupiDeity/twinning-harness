#!/usr/bin/env bash
# ENG-60 T2.8: bin/pipeline.sh end-to-end coverage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Throwaway TARGET_REPO + PROJECT_SLUG so common.sh sources cleanly.
_TEST_ROOT="$(mktemp -d -t twinning-eng60-pipe.XXXXXX)"
case "$_TEST_ROOT" in
  /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;;
  *) printf 'REFUSING: %q is not a temp dir\n' "$_TEST_ROOT" >&2; exit 99 ;;
esac
trap 'rm -rf "$_TEST_ROOT"' EXIT

export TARGET_REPO="$_TEST_ROOT/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
export PROJECT_SLUG="${PROJECT_SLUG:-test-pipe}"
export HARNESS_ROOT="$SCRIPT_DIR/.."
STUB_DIR="$_TEST_ROOT/stubs"
mkdir -p "$STUB_DIR"

# Stub linear.sh: capture every add-comment invocation to a file.
# Note: pipeline.sh calls linear.sh via absolute path ($SCRIPT_DIR/linear.sh),
# so this stub is only reached if invoked via PATH. Under PIPELINE_DRY_RUN=1
# the linear.sh call is never reached; the stub is harmless infrastructure for
# any future non-dry-run fixtures.
CAPTURE="$_TEST_ROOT/captured-comments.log"
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
case "\$1" in
  add-comment) printf 'add-comment %s %s\n' "\$2" "\$3" >> "$CAPTURE"; printf 'ok' ;;
  get-comments) printf '[]' ;;
esac
EOF
chmod +x "$STUB_DIR/linear.sh"

PASS=0; FAIL=0; FAILED_CASES=()
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
fail_at() {
  FAIL=$((FAIL+1));
  if [[ -n "${2:-}" ]]; then
    printf '  ❌ %s\n      %s\n' "$1" "$2" >&2
  else printf '  ❌ %s\n' "$1" >&2; fi
  FAILED_CASES+=("$1")
}

# Helper: run bin/pipeline.sh with stub PATH; capture stdout, stderr, rc.
# PIPELINE_DRY_RUN=1 suppresses linear.sh calls so no real writes happen.
# 2>&1 merges stderr (DRY_RUN notices, warnings, die messages) into stdout.
run_pipe() {
  PATH="$STUB_DIR:$PATH" PIPELINE_DRY_RUN=1 \
    bash "$SCRIPT_DIR/pipeline.sh" "$@" 2>&1
}

printf '\n--- bin/pipeline.sh: event verdict ---\n'

# PE1: pass with valid stage → dry-run prints expected body
out="$(run_pipe event ENG-PE1 verdict pass --stage implementing)"
expect='<!-- pipeline: verdict result=pass stage=implementing -->'
[[ "$out" == *"$expect"* ]] && pass_at "PE1: verdict pass dry-run body" || fail_at "PE1: verdict pass dry-run body" "got: $out"

# PE2: halt with valid reason
out="$(run_pipe event ENG-PE2 verdict halt --reason agent-blocked)"
expect='<!-- pipeline: verdict result=halt reason=agent-blocked -->'
[[ "$out" == *"$expect"* ]] && pass_at "PE2: verdict halt dry-run body" || fail_at "PE2: verdict halt dry-run body" "got: $out"

# PE3: registry rejection — bogus reason
out="$(run_pipe event ENG-PE3 verdict halt --reason bogus-reason 2>&1 || true)"
[[ "$out" == *"not in halt_reasons"* ]] && pass_at "PE3: bogus halt reason rejected" || fail_at "PE3: bogus halt reason rejected" "got: $out"

# PE4: missing required field — pass without --stage
out="$(run_pipe event ENG-PE4 verdict pass 2>&1 || true)"
[[ "$out" == *"--stage required"* ]] && pass_at "PE4: pass requires --stage" || fail_at "PE4: pass requires --stage" "got: $out"

# PE5–PE7: fail/wait/pivot variants — required field validation
out="$(run_pipe event ENG-PE5 verdict fail --target planning)"
[[ "$out" == *"target=planning"* ]] && pass_at "PE5: verdict fail target" || fail_at "PE5: verdict fail target" "got: $out"

out="$(run_pipe event ENG-PE6 verdict wait --reason awaiting-approval)"
[[ "$out" == *"reason=awaiting-approval"* ]] && pass_at "PE6: verdict wait reason" || fail_at "PE6: verdict wait reason" "got: $out"

out="$(run_pipe event ENG-PE7 verdict pivot --target planning)"
[[ "$out" == *"result=pivot target=planning"* ]] && pass_at "PE7: verdict pivot target" || fail_at "PE7: verdict pivot target" "got: $out"

printf '\n--- bin/pipeline.sh: event transition ---\n'

# PT1: valid transition — body uses two k=v pairs (from=X to=Y) per T2.6
out="$(run_pipe event ENG-PT1 transition "implementing → reviewing")"
[[ "$out" == *"transition from=implementing to=reviewing"* ]] && pass_at "PT1: transition dry-run body" || fail_at "PT1: transition dry-run body" "got: $out"

# PT2: bogus from-stage
out="$(run_pipe event ENG-PT2 transition "bogus-stage → reviewing" 2>&1 || true)"
[[ "$out" == *"not in stages"* ]] && pass_at "PT2: bogus from-stage rejected" || fail_at "PT2: bogus from-stage rejected" "got: $out"

# PT3: missing arrow
out="$(run_pipe event ENG-PT3 transition "implementing reviewing" 2>&1 || true)"
[[ "$out" == *"contain →"* ]] && pass_at "PT3: missing arrow rejected" || fail_at "PT3: missing arrow rejected" "got: $out"

printf '\n--- bin/pipeline.sh: decide ---\n'

# PD1: continue (no gate)
out="$(run_pipe decide ENG-PD1 --action continue)"
[[ "$out" == *"decision action=continue -->"* ]] && pass_at "PD1: decide continue body" || fail_at "PD1: decide continue body" "got: $out"

# PD2: approve with gate=scope
out="$(run_pipe decide ENG-PD2 --action approve --gate scope)"
[[ "$out" == *"decision action=approve gate=scope"* ]] && pass_at "PD2: decide approve scope" || fail_at "PD2: decide approve scope" "got: $out"

# PD3: abandon with gate=scope
out="$(run_pipe decide ENG-PD3 --action abandon --gate scope)"
[[ "$out" == *"action=abandon gate=scope"* ]] && pass_at "PD3: decide abandon scope" || fail_at "PD3: decide abandon scope" "got: $out"

# PD4: approve without --gate → rejected
out="$(run_pipe decide ENG-PD4 --action approve 2>&1 || true)"
[[ "$out" == *"--gate required"* ]] && pass_at "PD4: approve requires --gate" || fail_at "PD4: approve requires --gate" "got: $out"

# PD5: continue with --gate → rejected
out="$(run_pipe decide ENG-PD5 --action continue --gate scope 2>&1 || true)"
[[ "$out" == *"--gate not allowed"* ]] && pass_at "PD5: continue rejects --gate" || fail_at "PD5: continue rejects --gate" "got: $out"

# PD6: bogus gate
out="$(run_pipe decide ENG-PD6 --action approve --gate bogus-gate 2>&1 || true)"
[[ "$out" == *"not in decision_gates"* ]] && pass_at "PD6: bogus gate rejected" || fail_at "PD6: bogus gate rejected" "got: $out"

printf '\n--- bin/pipeline.sh: lane fences (warn-only) ---\n'

# PL1: writing a verdict with PIPELINE_WRITER=human → warn but still write
out="$(PIPELINE_WRITER=human run_pipe event ENG-PL1 verdict pass --stage implementing 2>&1)"
[[ "$out" == *"lane mismatch"* ]] && pass_at "PL1: verdict-as-human warns" || fail_at "PL1: verdict-as-human warns" "got: $out"

# ─── ENG-58 atomic-reset (ported to pipeline.sh::cmd_decide --action continue) ─────────
# These tests exercise the live (non-dry-run) path so actual filesystem + Linear stub
# writes happen. A richer linear.sh stub is needed that handles has-label / stage-of /
# remove-label in addition to add-comment.
#
# Strategy: source pipeline.sh into this process (getting cmd_decide + helpers defined),
# then override SCRIPT_DIR to point at a full-featured stub dir, exactly like
# halt-test.sh overrides SCRIPT_DIR after sourcing halt.sh.  Issue IDs must be
# ENG-<digits> to satisfy the D-014 path-traversal guard on the live path.

printf '\n--- bin/pipeline.sh: decide continue → ENG-58 atomic reset ---\n'

# Isolated state dir for atomic-reset tests.
_AR_STATE_DIR="$(mktemp -d -t twinning-ar-state.XXXXXX)"
case "$_AR_STATE_DIR" in
  /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;;
  *) printf 'REFUSING: %q is not a temp dir\n' "$_AR_STATE_DIR" >&2; exit 99 ;;
esac
trap 'rm -rf "$_TEST_ROOT" "$_AR_STATE_DIR"' EXIT

# Fully-featured linear.sh stub (has-label + stage-of + write verbs).
# Call log path must be absolute and stable across tests.
_AR_LINEAR_CALLS="$_AR_STATE_DIR/linear-calls.log"
_AR_METRICS_CALLS="$_AR_STATE_DIR/metrics-calls.log"
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"

_AR_STUB_DIR="$_AR_STATE_DIR/stubs"
mkdir -p "$_AR_STUB_DIR"

cat > "$_AR_STUB_DIR/linear.sh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_AR_LINEAR_CALLS"
case "\$1" in
  add-comment|remove-label|add-label) exit 0 ;;
  stage-of) printf '%s' "\${STAGE_OF:-stage:implementing}" ;;
  has-label)
    case ",\${LABELS_ON:-}," in *,"\$3",*) exit 0 ;; *) exit 1 ;; esac
    ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$_AR_STUB_DIR/linear.sh"

cat > "$_AR_STUB_DIR/metrics.sh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_AR_METRICS_CALLS"
exit 0
STUBEOF
chmod +x "$_AR_STUB_DIR/metrics.sh"

# Set up an isolated project state dir and override HARNESS_STATE_DIR so
# issue_dir() resolves under our temp tree.
export HARNESS_STATE_DIR="$_AR_STATE_DIR"
export PROJECT_SLUG="${PROJECT_SLUG:-test-pipe}"
export PROJECT_STATE_DIR="${_AR_STATE_DIR}/${PROJECT_SLUG}"
mkdir -p "$PROJECT_STATE_DIR"

# Source pipeline.sh — this also sources common.sh which resets PIPELINE_DRY_RUN
# to "0" (its default). We re-export it as "" after sourcing so it doesn't
# accidentally short-circuit the live atomic-reset path.
# SCRIPT_DIR is overridden AFTER sourcing (same pattern as halt-test.sh).
# Capture the real bin dir before sourcing (needed for the dry-run subshell test).
_REAL_SCRIPT_DIR="$SCRIPT_DIR"
# shellcheck source=pipeline.sh
source "$SCRIPT_DIR/pipeline.sh"
# Override SCRIPT_DIR so all bash "$SCRIPT_DIR/linear.sh" / metrics.sh calls
# inside the already-defined helpers route to the stubs.
SCRIPT_DIR="$_AR_STUB_DIR"
# Reset PIPELINE_DRY_RUN: common.sh set it to "0"; we want "" (not-set) so
# the live path in cmd_decide executes normally.
PIPELINE_DRY_RUN=""
export PIPELINE_DRY_RUN

# Helper: call cmd_decide in-process (functions already defined above).
_ar_decide() {
  local issue="$1"; shift
  PIPELINE_WRITER=human cmd_decide "$issue" "$@" 2>/dev/null
}

# Fixture helpers.
_ar_seed() {
  # Args: <issue> [policy=skip-until-human-acts|skip-until-code-changes]
  local issue="$1" policy="${2:-skip-until-human-acts}"
  local d="$PROJECT_STATE_DIR/$issue"
  mkdir -p "$d"
  printf '{"reason":"awaiting-approval","attempts":3}\n' > "$d/wait-build.json"
  jq -cn --arg p "$policy" '{policy:$p, evidence:{pipeline_content_hash:"abc",branch_head_sha:"def"}}' \
    > "$d/issue-state.json"
}
_ar_clear() { rm -rf "${PROJECT_STATE_DIR:?}/$1"; }

# ── PR-E: continue + halted + full side state → atomic reset
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
_ar_seed "ENG-5801" "skip-until-human-acts"
LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
  STAGE_OF="stage:building" \
  _ar_decide "ENG-5801" --action continue || true
wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-5801/wait-build.json" ]] && wait_present=1
state_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-5801/issue-state.json" ]] && state_present=1
skip_remove="$(grep -c "^remove-label ENG-5801 pipeline:skip-until-human-acts$" "$_AR_LINEAR_CALLS" || true)"
halt_remove="$(grep -c "^remove-label ENG-5801 pipeline:halted$" "$_AR_LINEAR_CALLS" || true)"
waypoint="$(grep -c "operator-resume" "$_AR_LINEAR_CALLS" || true)"
if [[ "$wait_present" == "0" && "$state_present" == "0" \
      && "$skip_remove" -ge "1" && "$halt_remove" -ge "1" \
      && "$waypoint" -ge "1" ]]; then
  pass_at "PR-E: continue atomic reset (wait+state cleared, labels removed, waypoint posted)"
else
  fail_at "PR-E: continue atomic reset" \
    "wait=$wait_present state=$state_present skip_remove=$skip_remove halt_remove=$halt_remove waypoint=$waypoint"
fi
_ar_clear "ENG-5801"

# ── PR-I: continue + policy=skip-until-code-changes → issue-state.json PRESERVED
: > "$_AR_LINEAR_CALLS"
_ar_seed "ENG-5802" "skip-until-code-changes"
LABELS_ON="pipeline:halted" STAGE_OF="stage:building" \
  _ar_decide "ENG-5802" --action continue || true
state_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-5802/issue-state.json" ]] && state_present=1
if [[ "$state_present" == "1" ]]; then
  pass_at "PR-I: skip-until-code-changes preserves issue-state.json"
else
  fail_at "PR-I: code-changes policy preserve" "state file was removed (should be kept for auto-resume evidence)"
fi
_ar_clear "ENG-5802"

# ── PR-K: operator-resume waypoint passes spec-shape assertion
# Prior version pinned a literal marker substring; that locks the writer's
# byte sequence and would silently keep passing if the parser's expectations
# diverged from the writer's output (the ENG-60 failure mode). Round-trip
# the captured body through parse_pipeline_marker and assert event payload.
: > "$_AR_LINEAR_CALLS"
LABELS_ON="pipeline:halted" STAGE_OF="stage:building" \
  _ar_decide "ENG-5803" --action continue || true
posts_matching=0
while IFS= read -r line; do
  body="${line#add-comment ENG-5803 }"
  [[ "$body" == "$line" ]] && continue   # not an add-comment line
  ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
  [[ -z "$ev" ]] && continue
  if [[ "$(jq -r '.event' <<<"$ev")" == "transition" ]] \
     && [[ "$(jq -r '.from' <<<"$ev")" == "building" ]] \
     && [[ "$(jq -r '.to'   <<<"$ev")" == "building" ]] \
     && [[ "$(jq -r '.reason // ""' <<<"$ev")" == "operator-resume" ]]; then
    posts_matching=$((posts_matching + 1))
  fi
done < "$_AR_LINEAR_CALLS"
if [[ "$posts_matching" -ge "1" ]]; then
  pass_at "PR-K: operator-resume waypoint parses as transition from=building to=building reason=operator-resume"
else
  fail_at "PR-K: waypoint spec-shape" \
    "no recorded body parses as the expected transition; got: $(cat "$_AR_LINEAR_CALLS")"
fi
_ar_clear "ENG-5803"

# ── PR-N: metrics.sh halt-resume captures stats
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
_ar_seed "ENG-5804" "skip-until-human-acts"
LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" STAGE_OF="stage:building" \
  _ar_decide "ENG-5804" --action continue || true
metric_line="$(grep "^halt-resume ENG-5804 building atomic-reset 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
if [[ "$metric_line" == *"wait_files=1"* \
      && "$metric_line" == *"skip_labels=1"* \
      && "$metric_line" == *"state_file=true"* \
      && "$metric_line" == *"waypoint_posted=1"* ]]; then
  pass_at "PR-N: metrics.sh halt-resume captures full stats"
else
  fail_at "PR-N: metrics emission" "line='$metric_line'"
fi
_ar_clear "ENG-5804"

# ── PR-Q: corrupt issue-state.json preserved (jq -e . guard)
: > "$_AR_LINEAR_CALLS"
mkdir -p "$PROJECT_STATE_DIR/ENG-5805"
printf 'not valid json\n' > "$PROJECT_STATE_DIR/ENG-5805/issue-state.json"
LABELS_ON="pipeline:halted" STAGE_OF="stage:building" \
  _ar_decide "ENG-5805" --action continue || true
state_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-5805/issue-state.json" ]] && state_present=1
if [[ "$state_present" == "1" ]]; then
  pass_at "PR-Q: corrupt JSON issue-state.json preserved"
else
  fail_at "PR-Q: corrupt-JSON guard" "state file removed despite invalid JSON"
fi
_ar_clear "ENG-5805"

# ── PR-T: multiple wait-*.json files all cleared and counted correctly
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
mkdir -p "$PROJECT_STATE_DIR/ENG-5806"
printf '{}' > "$PROJECT_STATE_DIR/ENG-5806/wait-build.json"
printf '{}' > "$PROJECT_STATE_DIR/ENG-5806/wait-qa.json"
printf '{}' > "$PROJECT_STATE_DIR/ENG-5806/wait-implementing.json"
LABELS_ON="pipeline:halted" STAGE_OF="stage:building" \
  _ar_decide "ENG-5806" --action continue || true
remaining="$(find "$PROJECT_STATE_DIR/ENG-5806" -maxdepth 1 -name 'wait-*.json' 2>/dev/null | wc -l | tr -d ' ')"
metric_line="$(grep "^halt-resume ENG-5806 building atomic-reset 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
if [[ "$remaining" == "0" && "$metric_line" == *"wait_files=3"* ]]; then
  pass_at "PR-T: multiple wait-*.json files all cleared (3) with correct count in metric"
else
  fail_at "PR-T: multi-file glob" "remaining=$remaining metric='$metric_line'"
fi
_ar_clear "ENG-5806"

# ── PR-dry-run: PIPELINE_DRY_RUN=1 suppresses atomic reset (FS untouched)
# Calls cmd_decide in-process with PIPELINE_DRY_RUN=1 then resets it to "".
: > "$_AR_LINEAR_CALLS"
_ar_seed "ENG-5807" "skip-until-human-acts"
PIPELINE_DRY_RUN=1 PIPELINE_WRITER=human cmd_decide "ENG-5807" --action continue >/dev/null 2>&1 || true
PIPELINE_DRY_RUN=""
wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-5807/wait-build.json" ]] && wait_present=1
if [[ "$wait_present" == "1" ]]; then
  pass_at "PR-dry-run: PIPELINE_DRY_RUN=1 suppresses atomic reset (wait file untouched)"
else
  fail_at "PR-dry-run: dry-run should not touch FS" "wait file was removed"
fi
_ar_clear "ENG-5807"

printf '\npipeline-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed cases:\n'; for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
