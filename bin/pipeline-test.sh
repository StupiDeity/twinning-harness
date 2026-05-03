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

printf '\npipeline-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed cases:\n'; for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
