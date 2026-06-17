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
expect='<!-- pipeline: verdict result=pass author=orchestrator stage=implementing -->'
[[ "$out" == *"$expect"* ]] && pass_at "PE1: verdict pass dry-run body" || fail_at "PE1: verdict pass dry-run body" "got: $out"

# PE2: halt with valid reason
out="$(run_pipe event ENG-PE2 verdict halt --reason agent-blocked)"
expect='<!-- pipeline: verdict result=halt author=orchestrator reason=agent-blocked -->'
[[ "$out" == *"$expect"* ]] && pass_at "PE2: verdict halt dry-run body" || fail_at "PE2: verdict halt dry-run body" "got: $out"

# PE3: registry rejection — bogus reason
out="$(run_pipe event ENG-PE3 verdict halt --reason bogus-reason 2>&1 || true)"
[[ "$out" == *"not in halt_reasons"* ]] && pass_at "PE3: bogus halt reason rejected" || fail_at "PE3: bogus halt reason rejected" "got: $out"

# ENG-156: sandbox-contract-violation is registry-valid.
out="$(run_pipe event ENG-156T verdict halt --reason sandbox-contract-violation 2>&1 || true)"
[[ "$out" != *"not in halt_reasons"* ]] && pass_at "ENG-156: sandbox-contract-violation accepted by registry" \
  || fail_at "ENG-156: sandbox-contract-violation accepted by registry" "got: $out"

# PE4: missing required field — pass without --stage
out="$(run_pipe event ENG-PE4 verdict pass 2>&1 || true)"
[[ "$out" == *"--stage required"* ]] && pass_at "PE4: pass requires --stage" || fail_at "PE4: pass requires --stage" "got: $out"

# PE5–PE7: fail/wait/pivot variants — required field validation
out="$(run_pipe event ENG-PE5 verdict fail --target planning)"
[[ "$out" == *"target=planning"* ]] && pass_at "PE5: verdict fail target" || fail_at "PE5: verdict fail target" "got: $out"

out="$(run_pipe event ENG-PE6 verdict wait --reason awaiting-approval)"
[[ "$out" == *"reason=awaiting-approval"* ]] && pass_at "PE6: verdict wait reason" || fail_at "PE6: verdict wait reason" "got: $out"

# PE7: verdict pivot — full three-field body (target + stage + reason)
out="$(run_pipe event ENG-PE7 verdict pivot --target planning --stage implementing --reason plan-structural-defect)"
expect='<!-- pipeline: verdict result=pivot author=orchestrator stage=implementing target=planning reason=plan-structural-defect -->'
[[ "$out" == *"$expect"* ]] && pass_at "PE7: verdict pivot full body" || fail_at "PE7: verdict pivot full body" "got: $out"

# PE7a: pivot missing --reason
out="$(run_pipe event ENG-PE7a verdict pivot --target planning --stage implementing 2>&1 || true)"
[[ "$out" == *"--reason required"* ]] && pass_at "PE7a: pivot requires --reason" || fail_at "PE7a: pivot requires --reason" "got: $out"

# PE7b: pivot bogus reason
out="$(run_pipe event ENG-PE7b verdict pivot --target planning --stage implementing --reason bogus-reason 2>&1 || true)"
[[ "$out" == *"not in pivot_reasons"* ]] && pass_at "PE7b: bogus pivot reason rejected" || fail_at "PE7b: bogus pivot reason rejected" "got: $out"

# PE7c: pivot missing --stage
out="$(run_pipe event ENG-PE7c verdict pivot --target planning --reason plan-structural-defect 2>&1 || true)"
[[ "$out" == *"--stage required"* ]] && pass_at "PE7c: pivot requires --stage" || fail_at "PE7c: pivot requires --stage" "got: $out"

# PE7d: pivot bogus stage
out="$(run_pipe event ENG-PE7d verdict pivot --target planning --stage bogus-stage --reason plan-structural-defect 2>&1 || true)"
[[ "$out" == *"not in stages"* ]] && pass_at "PE7d: bogus pivot stage rejected" || fail_at "PE7d: bogus pivot stage rejected" "got: $out"

# PE7e: pivot bogus target (value valid for fail_targets but not pivot_targets)
out="$(run_pipe event ENG-PE7e verdict pivot --target implementing --stage implementing --reason plan-structural-defect 2>&1 || true)"
[[ "$out" == *"not in pivot_targets"* ]] && pass_at "PE7e: bogus pivot target rejected" || fail_at "PE7e: bogus pivot target rejected" "got: $out"

# PE7f: pivot missing --target (QA adversarial: pre-ENG-115 required field still enforced via schema)
out="$(run_pipe event ENG-PE7f verdict pivot --stage implementing --reason plan-structural-defect 2>&1 || true)"
[[ "$out" == *"--target required"* ]] && pass_at "PE7f: pivot requires --target" || fail_at "PE7f: pivot requires --target" "got: $out"

# PE7g: pivot --reason "" (QA adversarial: empty string hits [[ -n "$reason" ]] gate, maps to missing-reason path)
out="$(run_pipe event ENG-PE7g verdict pivot --target planning --stage implementing --reason "" 2>&1 || true)"
[[ "$out" == *"--reason required"* ]] && pass_at "PE7g: pivot rejects empty --reason string" || fail_at "PE7g: pivot rejects empty --reason string" "got: $out"

# ENG-191 PE-191A/B/C: pass arm gains the per-arm `pass_reasons` override
# (selective exit path D — ship-with-deferred-majors). Per-arm registry-by-arm
# narrows the pass.reason field to pass_reasons (just `ship-with-deferred-majors`
# today). Halt arm still reads halt_reasons|wait_reasons union, so an arm-cross
# leak (verdict halt --reason ship-with-deferred-majors) MUST be rejected.

# PE-191A: pass --reason ship-with-deferred-majors → accepted
out="$(run_pipe event ENG-PE-191A verdict pass --stage reviewing --reason ship-with-deferred-majors)"
[[ "$out" == *"reason=ship-with-deferred-majors"* ]] && pass_at "PE-191A: pass+reason ship-with-deferred-majors accepted" || fail_at "PE-191A: pass+reason ship-with-deferred-majors accepted" "got: $out"

# PE-191B: pass --reason unknown-token → rejected by per-arm pass_reasons override
out="$(run_pipe event ENG-PE-191B verdict pass --stage reviewing --reason unknown-token 2>&1 || true)"
[[ "$out" == *"not in pass_reasons"* ]] && pass_at "PE-191B: unknown pass reason rejected (per-arm scope)" || fail_at "PE-191B: unknown pass reason rejected (per-arm scope)" "got: $out"

# PE-191C: halt --reason ship-with-deferred-majors → rejected (per-arm override is pass-only)
out="$(run_pipe event ENG-PE-191C verdict halt --reason ship-with-deferred-majors 2>&1 || true)"
[[ "$out" == *"not in halt_reasons"* ]] && pass_at "PE-191C: ship-with-deferred-majors rejected on halt arm" || fail_at "PE-191C: ship-with-deferred-majors rejected on halt arm" "got: $out"

# ENG-118 PE-118A/B/C: fail arm gains the per-arm `fail_reasons` override
# (dimensional-threshold-not-met). The override narrows the fail.reason field
# to fail_reasons (just `dimensional-threshold-not-met` today). Halt arm still
# reads halt_reasons|wait_reasons union, so an arm-cross leak
# (verdict halt --reason dimensional-threshold-not-met) MUST be rejected.

# PE-118A: fail --target implementing --reason dimensional-threshold-not-met → accepted
out="$(run_pipe event ENG-PE-118A verdict fail --target implementing --reason dimensional-threshold-not-met)"
[[ "$out" == *"result=fail author=orchestrator target=implementing reason=dimensional-threshold-not-met"* ]] && pass_at "PE-118A: fail+reason dimensional-threshold-not-met accepted" || fail_at "PE-118A: fail+reason dimensional-threshold-not-met accepted" "got: $out"

# PE-118B: fail --reason unknown-token → rejected by per-arm fail_reasons override
out="$(run_pipe event ENG-PE-118B verdict fail --target implementing --reason unknown-token 2>&1 || true)"
[[ "$out" == *"not in fail_reasons"* ]] && pass_at "PE-118B: unknown fail reason rejected (per-arm scope)" || fail_at "PE-118B: unknown fail reason rejected (per-arm scope)" "got: $out"

# PE-118C: halt --reason dimensional-threshold-not-met → rejected (per-arm override is fail-only)
out="$(run_pipe event ENG-PE-118C verdict halt --reason dimensional-threshold-not-met 2>&1 || true)"
[[ "$out" == *"not in halt_reasons"* ]] && pass_at "PE-118C: dimensional-threshold-not-met rejected on halt arm" || fail_at "PE-118C: dimensional-threshold-not-met rejected on halt arm" "got: $out"

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

printf '\n--- bin/pipeline.sh: lane fences (ENG-152 hard fence on verdict) ---\n'

# PL1 (ENG-152): verdict is orchestrator-only. A non-agent writer auto-stamps
# author=orchestrator and writes with NO lane-mismatch warning.
out="$(PIPELINE_WRITER=orchestrator run_pipe event ENG-PL1 verdict pass --stage implementing 2>&1)"
[[ "$out" == *"author=orchestrator"* && "$out" != *"lane mismatch"* ]] \
  && pass_at "PL1: verdict-as-orchestrator auto-stamps, no warning" \
  || fail_at "PL1: verdict-as-orchestrator auto-stamps, no warning" "got: $out"

# PL1b (ENG-152): an agent invoking verdict DIES with the stage-completion-claim redirect.
out="$(PIPELINE_WRITER=agent run_pipe event ENG-PL1 verdict pass --stage implementing 2>&1 || true)"
[[ "$out" == *"stage-completion-claim"* ]] \
  && pass_at "PL1b: verdict-as-agent dies with redirect" \
  || fail_at "PL1b: verdict-as-agent dies with redirect" "got: $out"

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

# ─── ENG-180 D-001: approve --gate scope → halt-label-clear ───
# After NOTABLE scope-violation halt, a single `decide --action approve --gate scope`
# invocation removes pipeline:halted so the next launchd tick's scope-approval replay
# can fire. Five fixtures cover happy path, idempotency on no-halt, gate-narrowing,
# dry-run suppression, and the D-014 issue-id guard.

# DEC-APPROVE-SCOPE-1: halt-clear fires; remove-label appears BEFORE add-comment.
# `{ grep ... || true; } | head | cut` guards against grep rc=1 (no match)
# tripping pipefail and aborting the cmd substitution.
: > "$_AR_LINEAR_CALLS"
LABELS_ON="pipeline:halted" STAGE_OF="stage:implementing" \
  _ar_decide "ENG-1801" --action approve --gate scope || true
remove_line_n="$( { grep -n "^remove-label ENG-1801 pipeline:halted$" "$_AR_LINEAR_CALLS" || true; } | head -1 | cut -d: -f1)"
add_line_n="$( { grep -n "^add-comment ENG-1801" "$_AR_LINEAR_CALLS" || true; } | head -1 | cut -d: -f1)"
remove_count="$(grep -c "^remove-label ENG-1801 pipeline:halted$" "$_AR_LINEAR_CALLS" || true)"
add_count="$(grep -c "decision action=approve gate=scope" "$_AR_LINEAR_CALLS" || true)"
if [[ "$remove_count" == "1" && "$add_count" -ge "1" \
      && -n "$remove_line_n" && -n "$add_line_n" \
      && "$remove_line_n" -lt "$add_line_n" ]]; then
  pass_at "DEC-APPROVE-SCOPE-1: halt-clear fires, ordered before decision comment"
else
  fail_at "DEC-APPROVE-SCOPE-1: halt-clear" \
    "remove=$remove_count add=$add_count remove_line=$remove_line_n add_line=$add_line_n"
fi
_ar_clear "ENG-1801"

# DEC-APPROVE-SCOPE-2: idempotent on no-halt — no remove-label, decision still posts.
: > "$_AR_LINEAR_CALLS"
LABELS_ON="" STAGE_OF="stage:implementing" \
  _ar_decide "ENG-1802" --action approve --gate scope || true
remove_count="$(grep -c "^remove-label ENG-1802 pipeline:halted$" "$_AR_LINEAR_CALLS" || true)"
add_count="$(grep -c "decision action=approve gate=scope" "$_AR_LINEAR_CALLS" || true)"
if [[ "$remove_count" == "0" && "$add_count" -ge "1" ]]; then
  pass_at "DEC-APPROVE-SCOPE-2: idempotent on no-halt (no remove-label; decision still posts)"
else
  fail_at "DEC-APPROVE-SCOPE-2: idempotent" \
    "remove=$remove_count add=$add_count"
fi
_ar_clear "ENG-1802"

# DEC-APPROVE-SCOPE-3: other gate untouched — approve --gate build-cap does NOT clear halt.
: > "$_AR_LINEAR_CALLS"
LABELS_ON="pipeline:halted" STAGE_OF="stage:building" \
  _ar_decide "ENG-1803" --action approve --gate build-cap || true
remove_count="$(grep -c "^remove-label ENG-1803 pipeline:halted$" "$_AR_LINEAR_CALLS" || true)"
add_count="$(grep -c "decision action=approve gate=build-cap" "$_AR_LINEAR_CALLS" || true)"
if [[ "$remove_count" == "0" && "$add_count" -ge "1" ]]; then
  pass_at "DEC-APPROVE-SCOPE-3: approve --gate build-cap leaves halt label intact"
else
  fail_at "DEC-APPROVE-SCOPE-3: gate-narrow" \
    "remove=$remove_count add=$add_count"
fi
_ar_clear "ENG-1803"

# DEC-APPROVE-SCOPE-4: dry-run suppression — PIPELINE_DRY_RUN=1 → zero linear calls.
# Need to override the in-process PIPELINE_DRY_RUN setting (which is "" for the
# atomic-reset block). The dry-run branch in cmd_decide short-circuits BOTH the
# halt-clear (live-path-only guard) AND the add-comment call.
: > "$_AR_LINEAR_CALLS"
LABELS_ON="pipeline:halted" STAGE_OF="stage:implementing" \
  PIPELINE_DRY_RUN=1 _ar_decide "ENG-1804" --action approve --gate scope >/dev/null 2>&1 || true
linear_count="$(wc -l < "$_AR_LINEAR_CALLS" | tr -d ' ')"
if [[ "$linear_count" == "0" ]]; then
  pass_at "DEC-APPROVE-SCOPE-4: dry-run suppresses halt-clear AND decision post"
else
  fail_at "DEC-APPROVE-SCOPE-4: dry-run" \
    "linear_count=$linear_count calls=$(cat "$_AR_LINEAR_CALLS")"
fi
_ar_clear "ENG-1804"

# DEC-APPROVE-SCOPE-5: invalid issue id rejected by D-014 guard.
# cmd_decide should die with the "expected ENG-<digits>" error and post nothing.
# `$(...)` is a subshell — die's `exit 1` exits that subshell only, not the test.
# Use `|| _decide_rc=$?` to capture rc without toggling errexit.
: > "$_AR_LINEAR_CALLS"
_decide_rc=0
_decide_out="$( LABELS_ON="pipeline:halted" \
  _ar_decide "INVALID-ID" --action approve --gate scope 2>&1 )" \
  || _decide_rc=$?
linear_count="$(wc -l < "$_AR_LINEAR_CALLS" | tr -d ' ')"
if [[ "$_decide_rc" != "0" && "$linear_count" == "0" ]]; then
  pass_at "DEC-APPROVE-SCOPE-5: invalid issue id rejected (nonzero rc, no linear calls)"
else
  fail_at "DEC-APPROVE-SCOPE-5: invalid issue id" \
    "rc=$_decide_rc linear_count=$linear_count out=$_decide_out"
fi
_ar_clear "INVALID-ID" 2>/dev/null || true

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

# ── PR-X1 (ENG-60-followup): continue clears the breaker when paused
# Set orchestrator.paused=true via STATE_FILE + plant a .consecutive-failures
# counter, then run decide --action continue. Both should be cleared and the
# metric should record breaker_was_paused=true.
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
_ar_seed "ENG-5811" "skip-until-human-acts"
mkdir -p "$(dirname "$STATE_FILE")"
printf '{"orchestrator":{"paused":true}}\n' > "$STATE_FILE"
printf '5\n' > "$PROJECT_STATE_DIR/.consecutive-failures"
LABELS_ON="pipeline:halted" STAGE_OF="stage:building" \
  _ar_decide "ENG-5811" --action continue || true
paused_after="$(jq -r 'if .orchestrator.paused != null then (.orchestrator.paused | tostring) else "missing" end' "$STATE_FILE" 2>/dev/null || printf 'missing')"
counter_present=0; [[ -e "$PROJECT_STATE_DIR/.consecutive-failures" ]] && counter_present=1
metric_line="$(grep "^halt-resume ENG-5811 building atomic-reset 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
if [[ "$paused_after" == "false" && "$counter_present" == "0" \
      && "$metric_line" == *"breaker_was_paused=true"* ]]; then
  pass_at "PR-X1: continue clears tripped breaker (paused -> false, .consecutive-failures removed, metric records breaker_was_paused=true)"
else
  fail_at "PR-X1: breaker clear" \
    "paused_after=$paused_after counter_present=$counter_present metric='$metric_line'"
fi
_ar_clear "ENG-5811"
rm -f "$STATE_FILE"

# ── PR-X2: continue is a no-op for the breaker when not tripped
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
_ar_seed "ENG-5812" "skip-until-human-acts"
# No STATE_FILE, no .consecutive-failures: breaker is not tripped.
LABELS_ON="pipeline:halted" STAGE_OF="stage:building" \
  _ar_decide "ENG-5812" --action continue || true
paused_after="$(jq -r 'if .orchestrator.paused != null then (.orchestrator.paused | tostring) else "missing" end' "$STATE_FILE" 2>/dev/null || printf 'missing')"
metric_line="$(grep "^halt-resume ENG-5812 building atomic-reset 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
if [[ "$paused_after" == "false" \
      && "$metric_line" == *"breaker_was_paused=false"* ]]; then
  pass_at "PR-X2: continue with no breaker trip (paused stays false, metric records breaker_was_paused=false)"
else
  fail_at "PR-X2: breaker no-op" \
    "paused_after=$paused_after metric='$metric_line'"
fi
_ar_clear "ENG-5812"
rm -f "$STATE_FILE"

# ── PR-X3: auto_commit_in_scope no-op when no worktree present
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
_ar_seed "ENG-5813" "skip-until-human-acts"
# Deliberately NOT creating a worktree directory.
LABELS_ON="pipeline:halted" STAGE_OF="stage:building" \
  _ar_decide "ENG-5813" --action continue || true
metric_line="$(grep "^halt-resume ENG-5813 building atomic-reset 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
if [[ "$metric_line" == *"auto_commit_paths=0"* ]]; then
  pass_at "PR-X3: auto-commit no-op when worktree missing (metric records auto_commit_paths=0)"
else
  fail_at "PR-X3: auto-commit no-worktree" "metric='$metric_line'"
fi
_ar_clear "ENG-5813"

# ── PR-X4: auto_commit_in_scope commits an in-scope dirty path on a real worktree
# Build a self-contained git worktree with a brainstorm doc that the breaker
# would have suppressed. decide --action continue should auto-commit it.
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
_ar_seed "ENG-5814" "skip-until-human-acts"
WT="$PROJECT_STATE_DIR/ENG-5814/worktree"
mkdir -p "$WT"
(
  set -e
  cd "$WT"
  git init --quiet --initial-branch=main >/dev/null 2>&1 \
    || { git init --quiet >/dev/null && git checkout -B main --quiet; }
  git config user.email "test@example.com"
  git config user.name "test"
  # Track docs/brainstorms/ in the seed commit so an untracked file under
  # it shows as `?? docs/brainstorms/<file>` (not `?? docs/`, which is what
  # `git status --porcelain` reports for entirely new directories — and
  # would slip past partition_dirty_paths' allow-list match). Mirrors how
  # real worktrees forked from origin/main already have docs/brainstorms/.
  mkdir -p docs/brainstorms
  printf 'placeholder\n' > docs/brainstorms/.gitkeep
  printf 'seed\n' > seed.txt
  git add seed.txt docs/brainstorms/.gitkeep
  git commit --quiet -m "seed"
  git checkout -B "feat/eng-5814-test" --quiet
  printf -- '---\nlinear: ENG-5814\n---\n# brainstorm\n' > docs/brainstorms/eng-5814-design.md
)
LABELS_ON="pipeline:halted" STAGE_OF="stage:brainstorming" \
  _ar_decide "ENG-5814" --action continue || true
# Verify a commit landed on the feature branch with the agent message.
last_msg="$(git -C "$WT" log -1 --pretty=%s 2>/dev/null || true)"
metric_line="$(grep "^halt-resume ENG-5814 brainstorming atomic-reset 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
if [[ "$last_msg" == *"chore(pipeline): brainstorming for ENG-5814 (operator-resumed via decide)"* \
      && "$metric_line" == *"auto_commit_paths=1"* ]]; then
  pass_at "PR-X4: auto-commit picks up in-scope dirty path (commit landed, metric records auto_commit_paths=1)"
else
  fail_at "PR-X4: auto-commit in-scope" \
    "last_msg='$last_msg' metric='$metric_line'"
fi
_ar_clear "ENG-5814"

# ── PR-X5: auto_commit_in_scope skips main/master branches
# Even if there's a dirty in-scope path, commit on `main` is refused.
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
_ar_seed "ENG-5815" "skip-until-human-acts"
WT="$PROJECT_STATE_DIR/ENG-5815/worktree"
mkdir -p "$WT"
(
  set -e
  cd "$WT"
  git init --quiet --initial-branch=main >/dev/null 2>&1 \
    || { git init --quiet >/dev/null && git checkout -B main --quiet; }
  git config user.email "test@example.com"
  git config user.name "test"
  # Track docs/brainstorms/ so the untracked test doc shows at file granularity.
  mkdir -p docs/brainstorms
  printf 'placeholder\n' > docs/brainstorms/.gitkeep
  printf 'seed\n' > seed.txt
  git add seed.txt docs/brainstorms/.gitkeep
  git commit --quiet -m "seed"
  # Stay on main; create dirty in-scope path. Auto-commit must refuse to
  # land it (main/master/<detached> are guarded against).
  printf -- '---\nlinear: ENG-5815\n---\n# brainstorm\n' > docs/brainstorms/eng-5815-design.md
)
LABELS_ON="pipeline:halted" STAGE_OF="stage:brainstorming" \
  _ar_decide "ENG-5815" --action continue || true
metric_line="$(grep "^halt-resume ENG-5815 brainstorming atomic-reset 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
# Untracked file should still be present (not committed); commit count should be 0.
untracked_present=0
git -C "$WT" status --porcelain 2>/dev/null | grep -q '^?? docs/brainstorms/eng-5815-design.md$' \
  && untracked_present=1
if [[ "$untracked_present" == "1" && "$metric_line" == *"auto_commit_paths=0"* ]]; then
  pass_at "PR-X5: auto-commit refuses to commit on main (file stays dirty, auto_commit_paths=0)"
else
  fail_at "PR-X5: auto-commit main-branch refusal" \
    "untracked=$untracked_present metric='$metric_line'"
fi
_ar_clear "ENG-5815"

# ── PR-Z1 (ENG-87 review-iter-2 C1'): drain preserves dispatch_id allocator
# fields when removing classify-set fields. Pre-fix, the drain did rm -f on
# the file for skip-until-human-acts policy, so the next allocator read
# prior_seq=0 and re-emitted d0001 — colliding with the original first
# dispatch's id and re-introducing the V3 vulnerability the strict id-match
# path was designed to prevent. The fix: write a stripped JSON that keeps
# only current_dispatch_seq / current_dispatch_id / current_stage.
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
mkdir -p "$PROJECT_STATE_DIR/ENG-5820"
jq -cn '{
  policy: "skip-until-human-acts",
  reason: "test-classify-fields-must-be-stripped",
  retry_count: 3,
  evidence: {pipeline_content_hash: "abc", branch_head_sha: "def"},
  current_dispatch_seq: 7,
  current_dispatch_id: "ENG-5820-d0007",
  current_stage: "implementing"
}' > "$PROJECT_STATE_DIR/ENG-5820/issue-state.json"
LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" STAGE_OF="stage:implementing" \
  _ar_decide "ENG-5820" --action continue || true
state_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-5820/issue-state.json" ]] && state_present=1
got_seq="$(jq -r '.current_dispatch_seq // ""' "$PROJECT_STATE_DIR/ENG-5820/issue-state.json" 2>/dev/null || printf '')"
got_id="$(jq -r '.current_dispatch_id // ""' "$PROJECT_STATE_DIR/ENG-5820/issue-state.json" 2>/dev/null || printf '')"
got_stage="$(jq -r '.current_stage // ""' "$PROJECT_STATE_DIR/ENG-5820/issue-state.json" 2>/dev/null || printf '')"
got_policy="$(jq -r '.policy // ""' "$PROJECT_STATE_DIR/ENG-5820/issue-state.json" 2>/dev/null || printf '')"
got_reason="$(jq -r '.reason // ""' "$PROJECT_STATE_DIR/ENG-5820/issue-state.json" 2>/dev/null || printf '')"
got_retry="$(jq -r '.retry_count // ""' "$PROJECT_STATE_DIR/ENG-5820/issue-state.json" 2>/dev/null || printf '')"
if [[ "$state_present" == "1" \
      && "$got_seq" == "7" \
      && "$got_id" == "ENG-5820-d0007" \
      && "$got_stage" == "implementing" \
      && "$got_policy" == "" \
      && "$got_reason" == "" \
      && "$got_retry" == "" ]]; then
  pass_at "PR-Z1: drain preserves dispatch_id allocator fields, strips classify-set fields"
else
  fail_at "PR-Z1: drain dispatch_id preservation" \
    "state=$state_present seq=$got_seq id=$got_id stage=$got_stage policy=$got_policy reason=$got_reason retry=$got_retry"
fi
_ar_clear "ENG-5820"

# ── PR-Z2 (ENG-87 review-iter-2 C1'): post-drain, allocate_dispatch_id
# increments past the preserved seq instead of resetting to d0001. This
# is the actual collision-prevention contract the C1' fix targets:
# operator runs --action continue on a halt; next dispatch must NOT
# re-emit a previously-used id.
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
mkdir -p "$PROJECT_STATE_DIR/ENG-5821"
jq -cn '{
  policy: "skip-until-human-acts",
  reason: "envelope-violation",
  evidence: {pipeline_content_hash: "h", branch_head_sha: "s"},
  current_dispatch_seq: 7,
  current_dispatch_id: "ENG-5821-d0007",
  current_stage: "implementing"
}' > "$PROJECT_STATE_DIR/ENG-5821/issue-state.json"
LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" STAGE_OF="stage:implementing" \
  _ar_decide "ENG-5821" --action continue || true
# Source common.sh to call allocate_dispatch_id directly; mimic next-tick allocator.
PIPELINE_STAGE="implementing" next_id="$(allocate_dispatch_id "ENG-5821" 2>/dev/null || printf '')"
if [[ "$next_id" == "ENG-5821-d0008" ]]; then
  pass_at "PR-Z2: post-drain allocator monotonically increments to d0008 (no d0001 collision)"
else
  fail_at "PR-Z2: post-drain monotonic seq" "expected ENG-5821-d0008, got: $next_id"
fi
_ar_clear "ENG-5821"

# ── PR-Z3 (ENG-87 review-iter-2 C1'): drain on file that has ONLY
# allocator fields (no classify-set fields, e.g. an early-halt before
# classify_failure ever ran) is a no-op — preserves file unchanged
# and prints "false" so the metric reports state_file=false honestly.
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
mkdir -p "$PROJECT_STATE_DIR/ENG-5822"
jq -cn '{
  current_dispatch_seq: 4,
  current_dispatch_id: "ENG-5822-d0004",
  current_stage: "implementing"
}' > "$PROJECT_STATE_DIR/ENG-5822/issue-state.json"
LABELS_ON="pipeline:halted" STAGE_OF="stage:implementing" \
  _ar_decide "ENG-5822" --action continue || true
metric_line="$(grep "^halt-resume ENG-5822 implementing atomic-reset 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
got_seq="$(jq -r '.current_dispatch_seq // ""' "$PROJECT_STATE_DIR/ENG-5822/issue-state.json" 2>/dev/null || printf '')"
if [[ "$got_seq" == "4" && "$metric_line" == *"state_file=false"* ]]; then
  pass_at "PR-Z3: drain no-op when no classify-set fields present (state_file=false; allocator preserved)"
else
  fail_at "PR-Z3: drain no-op semantics" "seq=$got_seq metric='$metric_line'"
fi
_ar_clear "ENG-5822"

# ── PR-X6 (ENG-69): continue clears the per-issue consecutive-failures counter
# Plant a non-empty $(issue_dir)/.consecutive-failures (set by
# tally_leaked_in_scope_failure or route_run_stage_exit's per-issue arm) AND
# the global counter; assert decide --action continue removes BOTH (the
# global one via _pipeline_clear_breaker, the per-issue one via the new
# rm -f line in cmd_decide). Without the per-issue clear, the next
# escalation re-fires immediately on the threshold-1 -> threshold tick.
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
_ar_seed "ENG-5816" "skip-until-human-acts"
mkdir -p "$PROJECT_STATE_DIR/ENG-5816"
printf '2\n' > "$PROJECT_STATE_DIR/ENG-5816/.consecutive-failures"
printf '1\n' > "$PROJECT_STATE_DIR/.consecutive-failures"
LABELS_ON="pipeline:halted" STAGE_OF="stage:implementing" \
  _ar_decide "ENG-5816" --action continue || true
per_issue_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-5816/.consecutive-failures" ]] && per_issue_present=1
global_present=0; [[ -e "$PROJECT_STATE_DIR/.consecutive-failures" ]] && global_present=1
if [[ "$per_issue_present" == "0" && "$global_present" == "0" ]]; then
  pass_at "PR-X6: continue clears per-issue + global consecutive-failures counter"
else
  fail_at "PR-X6: per-issue counter clear" \
    "per_issue_present=$per_issue_present global_present=$global_present"
fi
_ar_clear "ENG-5816"

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

# ── PR-HD-1 (ENG-34): continue emits human-decision with before_state=halted
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
_ar_seed "ENG-5840" "skip-until-human-acts"
LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
  STAGE_OF="stage:building" \
  _ar_decide "ENG-5840" --action continue || true
hd_line="$(grep "^human-decision ENG-5840 building resumed 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
if [[ -n "$hd_line" \
      && "$hd_line" == *"action=continue"* \
      && "$hd_line" == *"actor="* \
      && "$hd_line" == *"before_state=halted"* ]]; then
  pass_at "PR-HD-1: continue emits human-decision (outcome=resumed, before_state=halted)"
else
  fail_at "PR-HD-1: human-decision continue" "line='$hd_line'"
fi
_ar_clear "ENG-5840"

# ── PR-HD-2 (ENG-34): approve --gate scope emits with outcome=approved
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
_ar_seed "ENG-5841" "skip-until-human-acts"
LABELS_ON="pipeline:skip-until-human-acts" \
  STAGE_OF="stage:implementing" \
  _ar_decide "ENG-5841" --action approve --gate scope || true
hd_line="$(grep "^human-decision ENG-5841 implementing approved 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
if [[ -n "$hd_line" \
      && "$hd_line" == *"action=approve"* \
      && "$hd_line" == *"gate=scope"* \
      && "$hd_line" == *"before_state=skip-until-human-acts"* ]]; then
  pass_at "PR-HD-2: approve --gate scope emits human-decision (outcome=approved, gate=scope)"
else
  fail_at "PR-HD-2: human-decision approve" "line='$hd_line'"
fi
_ar_clear "ENG-5841"

# ── PR-HD-3 (ENG-34): abandon --gate build-cap emits with outcome=abandoned
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
_ar_seed "ENG-5842" "skip-until-human-acts"
# No halt-class labels set: before_state should resolve to `none`.
LABELS_ON="" STAGE_OF="stage:building" \
  _ar_decide "ENG-5842" --action abandon --gate build-cap || true
hd_line="$(grep "^human-decision ENG-5842 building abandoned 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
if [[ -n "$hd_line" \
      && "$hd_line" == *"action=abandon"* \
      && "$hd_line" == *"gate=build-cap"* \
      && "$hd_line" == *"before_state=none"* ]]; then
  pass_at "PR-HD-3: abandon --gate build-cap emits human-decision (outcome=abandoned, gate=build-cap, before_state=none)"
else
  fail_at "PR-HD-3: human-decision abandon" "line='$hd_line'"
fi
_ar_clear "ENG-5842"

# ── PR-HD-DRY (ENG-34): dry-run suppresses human-decision emission
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
_ar_seed "ENG-5843" "skip-until-human-acts"
PIPELINE_DRY_RUN=1 PIPELINE_WRITER=human \
  cmd_decide "ENG-5843" --action continue >/dev/null 2>&1 || true
PIPELINE_DRY_RUN=""
hd_count="$(grep -c "^human-decision ENG-5843 " "$_AR_METRICS_CALLS" || true)"
if [[ "$hd_count" == "0" ]]; then
  pass_at "PR-HD-DRY: PIPELINE_DRY_RUN=1 suppresses human-decision emission"
else
  fail_at "PR-HD-DRY: dry-run suppression" "expected 0 human-decision rows, got $hd_count"
fi
_ar_clear "ENG-5843"

# ── PR-HD-SAN (ENG-34): actor resolver strips shell metas and length-caps.
: > "$_AR_LINEAR_CALLS"; : > "$_AR_METRICS_CALLS"
_ar_seed "ENG-5844" "skip-until-human-acts"
# Point HARNESS_ROOT at a fresh empty repo (no user.email) so the resolver
# falls back to $USER, into which we inject a malicious overlong payload.
_HD_SAN_REPO="$(mktemp -d -t hd-san.XXXXXX)"
( cd "$_HD_SAN_REPO" && git init --quiet -b main ) >/dev/null 2>&1
_OLD_HARNESS_ROOT="$HARNESS_ROOT"
HARNESS_ROOT="$_HD_SAN_REPO"
USER='evil$(rm -rf /);name@example.com;echo PWNED;aaaaaaaaaaaaaaaaaaaa' \
LABELS_ON="pipeline:halted" STAGE_OF="stage:building" \
  _ar_decide "ENG-5844" --action continue || true
HARNESS_ROOT="$_OLD_HARNESS_ROOT"
rm -rf "$_HD_SAN_REPO"
hd_line="$(grep "^human-decision ENG-5844 building resumed 0 " "$_AR_METRICS_CALLS" | head -1 || true)"
# Extract just the actor= token value (up to the next space).
actor_val="${hd_line#*actor=}"
actor_val="${actor_val%% *}"
san_ok=1
[[ "$actor_val" =~ ^[A-Za-z0-9._@+-]+$ ]] || san_ok=0
(( ${#actor_val} <= 64 )) || san_ok=0
if [[ "$san_ok" == "1" && -n "$actor_val" ]]; then
  pass_at "PR-HD-SAN: actor sanitiser strips shell metas + caps length (got '$actor_val', ${#actor_val} bytes)"
else
  fail_at "PR-HD-SAN: actor sanitiser" "actor_val='$actor_val' len=${#actor_val} line='$hd_line'"
fi
_ar_clear "ENG-5844"

printf '\n--- bin/pipeline.sh: ENG-112 schema validator ---\n'

# ENG-112 B-001: events.verdict.linear_comment.body_shape reachable via jq.
# Use _REAL_SCRIPT_DIR (saved at L193) — SCRIPT_DIR was repointed to the
# atomic-reset stub dir above.
HARNESS_REG="$_REAL_SCRIPT_DIR/pipeline-events.json"
HARNESS_PIPELINE_SH="$_REAL_SCRIPT_DIR/pipeline.sh"
HARNESS_GEN_SH="$_REAL_SCRIPT_DIR/generate-vocabulary-doc.sh"
HARNESS_VOCAB_MD="$_REAL_SCRIPT_DIR/../docs/pipeline-vocabulary.md"

# ENG-112 test runner: invokes the real pipeline.sh with stubs on PATH +
# dry-run so no Linear writes happen. Mirrors run_pipe but doesn't depend
# on SCRIPT_DIR (which is currently pointing at the atomic-reset stub dir).
run_pipe_real() {
  PATH="$STUB_DIR:$PATH" PIPELINE_DRY_RUN=1 \
    bash "$HARNESS_PIPELINE_SH" "$@" 2>&1
}
out="$(jq -r '.events.verdict.linear_comment.body_shape' "$HARNESS_REG")"
[[ "$out" == *"<!-- pipeline: verdict"* ]] && pass_at "ENG-112 B-001: events.verdict.linear_comment.body_shape registered" || fail_at "ENG-112 B-001: events.verdict schema missing" "got: $out"

# ENG-112 B-002: events.transition.linear_comment registered.
out="$(jq -r '.events.transition.linear_comment.body_shape' "$HARNESS_REG")"
[[ "$out" == *"<!-- pipeline: transition"* ]] && pass_at "ENG-112 B-002: events.transition.linear_comment registered" || fail_at "ENG-112 B-002: events.transition schema missing" "got: $out"

# ENG-112 B-003: events.decision.linear_comment registered.
out="$(jq -r '.events.decision.linear_comment.body_shape' "$HARNESS_REG")"
[[ "$out" == *"<!-- pipeline: decision"* ]] && pass_at "ENG-112 B-003: events.decision.linear_comment registered" || fail_at "ENG-112 B-003: events.decision schema missing" "got: $out"

# ENG-112 B-004: unknown CLI flag rejected (existing case-statement at flag
# parser layer — schema validation is downstream of CLI parsing).
out="$(run_pipe_real event ENG-PE-B4 verdict pass --stage implementing --bogus foo 2>&1 || true)"
[[ "$out" == *"unknown flag '--bogus'"* ]] && pass_at "ENG-112 B-004: unknown --bogus flag rejected at CLI" || fail_at "ENG-112 B-004: unknown flag rejection" "got: $out"

# ENG-112 B-005: schema-driven verdict body shape — halt emits clean body.
out="$(run_pipe_real event ENG-PE-B5 verdict halt --reason scope-violation)"
expect='<!-- pipeline: verdict result=halt author=orchestrator reason=scope-violation -->'
[[ "$out" == *"$expect"* ]] && pass_at "ENG-112 B-005: schema-driven halt body" || fail_at "ENG-112 B-005: schema-driven halt body" "got: $out"

# ENG-112 B-006: schema-driven decision body — approve with gate.
out="$(run_pipe_real decide ENG-PE-B6 --action approve --gate scope)"
expect='<!-- pipeline: decision action=approve gate=scope -->'
[[ "$out" == *"$expect"* ]] && pass_at "ENG-112 B-006: schema-driven decision body" || fail_at "ENG-112 B-006: schema-driven decision body" "got: $out"

# ENG-112 B-007: schema validator names the missing required field with
# CLI-flag wording.
out="$(run_pipe_real event ENG-PE-B7 verdict pass 2>&1 || true)"
[[ "$out" == *"--stage required"* ]] && pass_at "ENG-112 B-007: missing required field names the flag" || fail_at "ENG-112 B-007: missing required field" "got: $out"

# ENG-112 B-008: _validate_event_payload + _render_body helpers exist.
helper_grep="$(grep -Ec '^_validate_event_payload\(\)|^_render_body\(\)' "$HARNESS_PIPELINE_SH")"
[[ "$helper_grep" == "2" ]] && pass_at "ENG-112 B-008: schema helpers defined in pipeline.sh" || fail_at "ENG-112 B-008: schema helpers missing" "found $helper_grep / 2"

# ENG-112 B-009: bin/generate-vocabulary-doc.sh emits a Comment schemas
# section. Round-trip from registry → doc.
out="$(bash "$HARNESS_GEN_SH" 2>&1)"
if [[ "$out" == *"Generated:"* ]] && grep -q "^## Comment schemas$" "$HARNESS_VOCAB_MD"; then
  pass_at "ENG-112 B-009: vocabulary doc carries Comment schemas section"
else
  fail_at "ENG-112 B-009: vocabulary doc Comment schemas section missing" "generator out: $out"
fi

# ENG-112 B-010: round-trip pin — both sentinel pairs present in output doc.
sentinel_count="$(grep -c "GENERATED:" "$HARNESS_VOCAB_MD")"
[[ "$sentinel_count" == "4" ]] && pass_at "ENG-112 B-010: both sentinel pairs in regenerated doc" || fail_at "ENG-112 B-010: sentinel count" "expected 4, got $sentinel_count"

printf '\n--- ENG-152: verdict-author split schema + emit ---\n'

# PE-152-1: verdict event is orchestrator-lane and requires author
vev="$(jq -c '.events.verdict.linear_comment' "$HARNESS_REG")"
if [[ "$(jq -r '.writer_lane' <<<"$vev")" == "orchestrator" ]] \
   && jq -e '.required | index("author")' <<<"$vev" >/dev/null \
   && [[ "$(jq -r '.field_registry.author' <<<"$vev")" == "verdict_authors" ]]; then
  pass_at "PE-152-1: verdict event orchestrator-lane + author required/registered"
else
  fail_at "PE-152-1: verdict event schema" "got: $vev"
fi

# PE-152-2: verdict_authors enum
[[ "$(jq -rc '.verdict_authors' "$HARNESS_REG")" == '["orchestrator"]' ]] \
  && pass_at "PE-152-2: verdict_authors enum" || fail_at "PE-152-2: verdict_authors enum" "got: $(jq -rc '.verdict_authors' "$HARNESS_REG")"

# PE-152-3: stage-completion-claim event — agent-lane, requires result+stage,
# pass arm accepts pass_reasons (ENG-191 ship-with-deferred-majors gap closed).
scc="$(jq -c '.events["stage-completion-claim"].linear_comment' "$HARNESS_REG")"
if [[ "$(jq -r '.writer_lane' <<<"$scc")" == "agent" ]] \
   && [[ "$(jq -rc '.required' <<<"$scc")" == '["result","stage"]' ]] \
   && [[ "$(jq -r '.field_registry_by_arm.pass.reason' <<<"$scc")" == "pass_reasons" ]]; then
  pass_at "PE-152-3: stage-completion-claim event schema"
else
  fail_at "PE-152-3: stage-completion-claim event schema" "got: $scc"
fi

# PE-152-4: agent calling stage-completion-claim renders without an author field
out="$(PIPELINE_WRITER=agent run_pipe_real event ENG-152T stage-completion-claim pass --stage qa 2>&1 || true)"
[[ "$out" == *"stage-completion-claim result=pass"* && "$out" == *"stage=qa"* && "$out" != *"author="* ]] \
  && pass_at "PE-152-4: stage-completion-claim agent emit body" || fail_at "PE-152-4: stage-completion-claim agent emit body" "got: $out"

# PE-152-5: review Path-D claim (pass --reason ship-with-deferred-majors) validates on the claim event
out="$(PIPELINE_WRITER=agent run_pipe_real event ENG-152T stage-completion-claim pass --stage reviewing --reason ship-with-deferred-majors 2>&1 || true)"
[[ "$out" == *"reason=ship-with-deferred-majors"* && "$out" != *"not in"* ]] \
  && pass_at "PE-152-5: claim pass+ship-with-deferred-majors accepted" || fail_at "PE-152-5: claim pass+ship-with-deferred-majors accepted" "got: $out"

printf '\npipeline-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed cases:\n'; for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
