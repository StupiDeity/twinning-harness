#!/usr/bin/env bash
# ENG-49 Gap #3: post-verdict.sh constructs marker via heredoc and
# validates against verdict-handler regex before posting.
set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

_TEST_TARGET="$(mktemp -d -t twinning-pv-target.XXXXXX)"
_TEST_STUB="$(mktemp -d -t twinning-pv-stub.XXXXXX)"
case "$_TEST_TARGET" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
case "$_TEST_STUB"   in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
trap 'rm -rf "$_TEST_TARGET" "$_TEST_STUB"' EXIT

mkdir -p "$_TEST_TARGET/.pipeline-config"
cat > "$_TEST_TARGET/.pipeline-config/config.json" <<'JSON'
{"project":{"slug":"test-slug"},"orchestrator":{"paused":false}}
JSON
export TARGET_REPO="$_TEST_TARGET"

# Stub linear.sh: capture add-comment payloads.
LINEAR_CALLS="$_TEST_STUB/linear-calls.log"
: > "$LINEAR_CALLS"
cat > "$_TEST_STUB/linear.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  add-comment) printf '%s\n' "\$3" >> "$LINEAR_CALLS"; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/linear.sh"

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# source post-verdict.sh, override SCRIPT_DIR to point at stubs.
# shellcheck source=post-verdict.sh
source "$SCRIPT_DIR_REAL/post-verdict.sh"
SCRIPT_DIR="$_TEST_STUB"

# Case 1: valid stage-summary → marker matches regex, posted.
: > "$LINEAR_CALLS"
post_verdict ENG-990 stage-summary ui "test reason" >/dev/null 2>&1
posted="$(cat "$LINEAR_CALLS")"
[[ "$posted" == *'<!-- pipeline-stage-summary: ui -->'* ]] \
  && ok "case-1 valid stage-summary marker posted" \
  || nope "case-1 stage-summary" "posted: $posted"

# Case 2: invalid kind dies.
exit_code=0
(post_verdict ENG-991 bogus-kind ui >/dev/null 2>&1) || exit_code=$?
[[ "$exit_code" -ne 0 ]] \
  && ok "case-2 invalid kind dies" \
  || nope "case-2 invalid kind" "exit=$exit_code"

# Case 3: invalid stage dies.
exit_code=0
(post_verdict ENG-992 stage-summary not-a-stage >/dev/null 2>&1) || exit_code=$?
[[ "$exit_code" -ne 0 ]] \
  && ok "case-3 invalid stage dies" \
  || nope "case-3 invalid stage" "exit=$exit_code"

# Case 4: heredoc construction — the literal `<!--` survives as-is.
: > "$LINEAR_CALLS"
post_verdict ENG-993 stage-summary building "release ready" >/dev/null 2>&1
posted="$(cat "$LINEAR_CALLS")"
[[ "$posted" == *"<!--"* ]] \
  && ok "case-4 heredoc preserves literal <!--" \
  || nope "case-4 heredoc <!--" "posted: $posted"

# Case 5: rejection marker shape.
: > "$LINEAR_CALLS"
post_verdict ENG-994 rejection reviewing "rework needed" >/dev/null 2>&1
posted="$(cat "$LINEAR_CALLS")"
[[ "$posted" == *'<!-- pipeline-rejection: reviewing -->'* ]] \
  && ok "case-5 rejection marker shape" \
  || nope "case-5 rejection" "posted: $posted"

# Case 6: halt marker shape (uses kind 'halt').
: > "$LINEAR_CALLS"
post_verdict ENG-995 halt agent-blocked "manual halt" >/dev/null 2>&1
posted="$(cat "$LINEAR_CALLS")"
[[ "$posted" == *'<!-- pipeline-halt: agent-blocked -->'* ]] \
  && ok "case-6 halt marker shape" \
  || nope "case-6 halt" "posted: $posted"

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
