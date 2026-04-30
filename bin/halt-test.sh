#!/usr/bin/env bash
# ENG-49 Gap #2: halt.sh resolve --decision resume calls verdict-handler
# before clearing pipeline:halted.
set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

_TEST_TARGET="$(mktemp -d -t twinning-halt-target.XXXXXX)"
_TEST_STUB="$(mktemp -d -t twinning-halt-stub.XXXXXX)"
case "$_TEST_TARGET" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
case "$_TEST_STUB"   in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
trap 'rm -rf "$_TEST_TARGET" "$_TEST_STUB"' EXIT

mkdir -p "$_TEST_TARGET/.pipeline-config"
cat > "$_TEST_TARGET/.pipeline-config/config.json" <<'JSON'
{"project":{"slug":"test-slug"},"orchestrator":{"paused":false},"linear":{"native_states":{"in_review":"In Review","done":"Done"}}}
JSON
export TARGET_REPO="$_TEST_TARGET"

LINEAR_CALLS="$_TEST_STUB/linear-calls.log"
: > "$LINEAR_CALLS"
cat > "$_TEST_STUB/linear.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LINEAR_CALLS"
case "\$1" in
  add-comment|remove-label|add-label) exit 0 ;;
  stage-of) printf 'stage:ui' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/linear.sh"

# Stub verdict-handler — return-code controllable via VH_RC env var.
cat > "$_TEST_STUB/verdict-handler.sh" <<'SH'
verdict_handler() { return "${VH_RC:-0}"; }
export -f verdict_handler
SH

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# Source halt.sh post-config so it sees TARGET_REPO. Override SCRIPT_DIR
# AFTER sourcing so internal calls point at stubs.
# shellcheck source=halt.sh
source "$SCRIPT_DIR_REAL/halt.sh"
SCRIPT_DIR="$_TEST_STUB"

# Case A: --decision resume + verdict-handler returns 0 → halt.sh skips remove-label.
: > "$LINEAR_CALLS"
VH_RC=0 resolve "ENG-980" "resume" >/dev/null 2>&1 || true
remove_count="$(grep -c "^remove-label ENG-980 pipeline:halted$" "$LINEAR_CALLS" || true)"
[[ "$remove_count" == "0" ]] \
  && ok "Gap-2 rc=0: halt.sh skips its own remove-label" \
  || nope "Gap-2 rc=0 skip remove-label" "remove-label called $remove_count time(s)"

# Case B: --decision resume + verdict-handler returns 1 → halt.sh removes halt.
: > "$LINEAR_CALLS"
VH_RC=1 resolve "ENG-981" "resume" >/dev/null 2>&1 || true
remove_count="$(grep -c "^remove-label ENG-981 pipeline:halted$" "$LINEAR_CALLS" || true)"
[[ "$remove_count" == "1" ]] \
  && ok "Gap-2 rc=1: halt.sh removes halt label" \
  || nope "Gap-2 rc=1 remove halt label" "remove-label called $remove_count time(s)"

# Case C: --decision resume + verdict-handler returns 2 → halt.sh exits non-zero, halt preserved.
: > "$LINEAR_CALLS"
exit_code=0
( VH_RC=2 resolve "ENG-982" "resume" >/dev/null 2>&1 ) || exit_code=$?
remove_count="$(grep -c "^remove-label ENG-982 pipeline:halted$" "$LINEAR_CALLS" || true)"
if [[ "$exit_code" -ne 0 && "$remove_count" == "0" ]]; then
  ok "Gap-2 rc=2: halt.sh exits non-zero, halt preserved"
else
  nope "Gap-2 rc=2: halt.sh exits non-zero, halt preserved" \
    "exit=$exit_code remove-count=$remove_count"
fi

# Case D: --decision scope-approved → no verdict-handler involvement, current behavior.
: > "$LINEAR_CALLS"
VH_RC=99 resolve "ENG-983" "scope-approved" >/dev/null 2>&1 || true
remove_count="$(grep -c "^remove-label ENG-983 pipeline:halted$" "$LINEAR_CALLS" || true)"
[[ "$remove_count" == "1" ]] \
  && ok "Gap-2 scope-approved: current behavior preserved (rm halt)" \
  || nope "Gap-2 scope-approved" "remove-label called $remove_count time(s)"

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
