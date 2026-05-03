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

# Stub pipeline.sh: capture the new-shape body that the wrapper would have
# delegated to bin/pipeline. The wrapper translates legacy <kind, value>
# tuples to bin/pipeline event verdict <result> --<flag> <value>; this stub
# reconstructs the equivalent new-shape body and appends to LINEAR_CALLS so
# the existing assertions can match against the canonical post-T2.10 output.
LINEAR_CALLS="$_TEST_STUB/linear-calls.log"
: > "$LINEAR_CALLS"
cat > "$_TEST_STUB/pipeline.sh" <<SH
#!/usr/bin/env bash
# Args expected: event <issue> verdict <result> [--stage X | --target Y | --reason Z]
[[ "\$1" == "event" ]] || exit 0
issue="\$2"; result="\$4"
shift 4
flag=""; value=""
[[ \$# -ge 2 ]] && { flag="\$1"; value="\$2"; }
body="<!-- pipeline: verdict result=\$result"
case "\$flag" in
  --stage)  body="\$body stage=\$value" ;;
  --target) body="\$body target=\$value" ;;
  --reason) body="\$body reason=\$value" ;;
esac
body="\$body -->"
printf '%s\n' "\$body" >> "$LINEAR_CALLS"
exit 0
SH
chmod +x "$_TEST_STUB/pipeline.sh"

# Stub linear.sh too — the wrapper itself doesn't call linear.sh anymore,
# but the (real) bin/pipeline.sh would; keep the stub for safety in case any
# code path inadvertently goes via SCRIPT_DIR/linear.sh.
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

# Updated for ENG-60 T2.10: bin/post-verdict.sh is now a wrapper around
# bin/pipeline event verdict, and the comment body is the new shape. The
# pipeline.sh stub above translates the wrapper's delegation back into a
# new-shape body in LINEAR_CALLS so these cases can assert canonical output.

# Case 1: valid stage-summary → wrapper delegates to verdict pass --stage ui.
: > "$LINEAR_CALLS"
post_verdict ENG-990 stage-summary ui "test reason" >/dev/null 2>&1
posted="$(cat "$LINEAR_CALLS")"
[[ "$posted" == *'<!-- pipeline: verdict result=pass stage=ui -->'* ]] \
  && ok "case-1 valid stage-summary delegated to verdict pass" \
  || nope "case-1 stage-summary" "posted: $posted"

# Case 2: invalid kind dies (case statement in wrapper rejects it).
exit_code=0
(post_verdict ENG-991 bogus-kind ui >/dev/null 2>&1) || exit_code=$?
[[ "$exit_code" -ne 0 ]] \
  && ok "case-2 invalid kind dies" \
  || nope "case-2 invalid kind" "exit=$exit_code"

# Case 3: invalid stage delegates to bin/pipeline; in the stubbed test
# pipeline.sh accepts anything, so the wrapper itself succeeds. (Real
# bin/pipeline.sh registry validation rejects bogus stages — exercised
# by bin/pipeline-test.sh PE3 and PE4.) This case is now redundant; assert
# it just delegates without dying at the wrapper boundary.
: > "$LINEAR_CALLS"
post_verdict ENG-992 stage-summary not-a-stage >/dev/null 2>&1 || true
posted="$(cat "$LINEAR_CALLS")"
[[ "$posted" == *'<!-- pipeline: verdict result=pass stage=not-a-stage -->'* ]] \
  && ok "case-3 wrapper delegates blindly; registry validation is downstream" \
  || nope "case-3 wrapper delegates" "posted: $posted"

# Case 4: marker body is the new shape; literal <!-- survives.
: > "$LINEAR_CALLS"
post_verdict ENG-993 stage-summary building "release ready" >/dev/null 2>&1
posted="$(cat "$LINEAR_CALLS")"
[[ "$posted" == *"<!--"* && "$posted" == *"stage=building"* ]] \
  && ok "case-4 new-shape body preserves <!-- and carries stage" \
  || nope "case-4 new-shape body" "posted: $posted"

# Case 5: rejection delegates to verdict fail --target.
: > "$LINEAR_CALLS"
post_verdict ENG-994 rejection reviewing "rework needed" >/dev/null 2>&1
posted="$(cat "$LINEAR_CALLS")"
[[ "$posted" == *'<!-- pipeline: verdict result=fail target=reviewing -->'* ]] \
  && ok "case-5 rejection delegated to verdict fail target" \
  || nope "case-5 rejection" "posted: $posted"

# Case 6: halt delegates to verdict halt --reason.
: > "$LINEAR_CALLS"
post_verdict ENG-995 halt agent-blocked "manual halt" >/dev/null 2>&1
posted="$(cat "$LINEAR_CALLS")"
[[ "$posted" == *'<!-- pipeline: verdict result=halt reason=agent-blocked -->'* ]] \
  && ok "case-6 halt delegated to verdict halt reason" \
  || nope "case-6 halt" "posted: $posted"

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
