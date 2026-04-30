#!/usr/bin/env bash
# ENG-50: review_should_dispatch returns truthy when PR state has changed
# since last-review-state, falsy otherwise.
set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

_TEST_TARGET="$(mktemp -d -t twinning-rpoll-target.XXXXXX)"
_TEST_STUB="$(mktemp -d -t twinning-rpoll-stub.XXXXXX)"
case "$_TEST_TARGET" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
case "$_TEST_STUB"   in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
trap 'rm -rf "$_TEST_TARGET" "$_TEST_STUB"' EXIT

mkdir -p "$_TEST_TARGET/.pipeline-config"
cat > "$_TEST_TARGET/.pipeline-config/config.json" <<'JSON'
{"project":{"slug":"test-slug"},"orchestrator":{"paused":false}}
JSON
export TARGET_REPO="$_TEST_TARGET"

# Stub gh: emit canned PR view JSON from $GH_PR_VIEW_JSON env var.
cat > "$_TEST_STUB/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") printf '%s\n' "${GH_PR_VIEW_JSON:-{\"commits\":[],\"reviews\":[]\}}" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/gh"

# Stub linear.sh get-comments to return a configurable last-review-state.
COMMENTS_FIXTURE="$_TEST_STUB/comments.json"
printf '[]' > "$COMMENTS_FIXTURE"
cat > "$_TEST_STUB/linear.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  get-comments) cat "$COMMENTS_FIXTURE" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/linear.sh"

# Helper to inject a last-review-state into the fixture in the spec format
# (multi-line: <!-- marker -->\n\n{json}).
set_last_review_state() {
  local sha="$1" approval_at="$2" cr_at="$3"
  local body
  body=$(printf '<!-- pipeline-state: last-review-state -->\n\n{"sha":%s,"last_processed_approval_at":%s,"last_processed_cr_at":%s}\n' \
    "$([[ -z "$sha" ]] && printf 'null' || printf '"%s"' "$sha")" \
    "$([[ -z "$approval_at" ]] && printf 'null' || printf '"%s"' "$approval_at")" \
    "$([[ -z "$cr_at" ]] && printf 'null' || printf '"%s"' "$cr_at")")
  jq -nc --arg b "$body" '[{id:"c1",createdAt:"2026-04-30T09:00:00Z",body:$b}]' > "$COMMENTS_FIXTURE"
}

ORIG_PATH="$PATH"
PATH="$_TEST_STUB:$PATH"
export PATH

# shellcheck source=common.sh
source "$SCRIPT_DIR_REAL/common.sh"
# shellcheck source=review-state.sh
source "$SCRIPT_DIR_REAL/review-state.sh"
# shellcheck source=review-poll.sh
source "$SCRIPT_DIR_REAL/review-poll.sh"
SCRIPT_DIR="$_TEST_STUB"

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# ─── Case A: bootstrap (no last-review-state) → truthy ────────────────
printf '[]' > "$COMMENTS_FIXTURE"
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[]}' \
  review_should_dispatch ENG-510 stub-branch && rc=0 || rc=$?
[[ "$rc" == 0 ]] \
  && ok "Case A: bootstrap → dispatch" \
  || nope "Case A" "rc=$rc"

# ─── Case B: HEAD SHA differs from last-review-state.sha → truthy ─────
set_last_review_state "old1234" "" ""
GH_PR_VIEW_JSON='{"commits":[{"oid":"new5678"}],"reviews":[]}' \
  review_should_dispatch ENG-511 stub-branch && rc=0 || rc=$?
[[ "$rc" == 0 ]] \
  && ok "Case B: SHA differs → dispatch" \
  || nope "Case B" "rc=$rc"

# ─── Case C: new APPROVED on current HEAD (newer than processed) → truthy ─
set_last_review_state "abc1234" "2026-04-29T10:00:00Z" ""
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[{"author":{"login":"alice"},"state":"APPROVED","commit_id":"abc1234","submittedAt":"2026-04-30T11:00:00Z"}]}' \
  review_should_dispatch ENG-512 stub-branch && rc=0 || rc=$?
[[ "$rc" == 0 ]] \
  && ok "Case C: new approval on HEAD → dispatch" \
  || nope "Case C" "rc=$rc"

# ─── Case D: new CHANGES_REQUESTED on current HEAD → truthy ───────────
set_last_review_state "abc1234" "" "2026-04-29T10:00:00Z"
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[{"author":{"login":"alice"},"state":"CHANGES_REQUESTED","commit_id":"abc1234","submittedAt":"2026-04-30T11:00:00Z"}]}' \
  review_should_dispatch ENG-513 stub-branch && rc=0 || rc=$?
[[ "$rc" == 0 ]] \
  && ok "Case D: new CR on HEAD → dispatch" \
  || nope "Case D" "rc=$rc"

# ─── Case E: APPROVED but on old SHA (HEAD has moved) → truthy (SHA differs) ─
set_last_review_state "abc1234" "2026-04-29T10:00:00Z" ""
GH_PR_VIEW_JSON='{"commits":[{"oid":"new5678"}],"reviews":[{"author":{"login":"alice"},"state":"APPROVED","commit_id":"abc1234","submittedAt":"2026-04-30T11:00:00Z"}]}' \
  review_should_dispatch ENG-514 stub-branch && rc=0 || rc=$?
[[ "$rc" == 0 ]] \
  && ok "Case E: approval on old SHA but HEAD moved → dispatch (SHA path)" \
  || nope "Case E" "rc=$rc"

# ─── Case F: nothing changed → falsy ──────────────────────────────────
set_last_review_state "abc1234" "2026-04-30T11:00:00Z" ""
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[{"author":{"login":"alice"},"state":"APPROVED","commit_id":"abc1234","submittedAt":"2026-04-30T11:00:00Z"}]}' \
  review_should_dispatch ENG-515 stub-branch && rc=0 || rc=$?
[[ "$rc" != 0 ]] \
  && ok "Case F: nothing changed → idle" \
  || nope "Case F" "rc=$rc (expected nonzero)"

# ─── Case G: APPROVED already processed (submittedAt <= last_processed) → falsy ─
set_last_review_state "abc1234" "2026-04-30T11:00:00Z" ""
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[{"author":{"login":"alice"},"state":"APPROVED","commit_id":"abc1234","submittedAt":"2026-04-30T10:00:00Z"}]}' \
  review_should_dispatch ENG-516 stub-branch && rc=0 || rc=$?
[[ "$rc" != 0 ]] \
  && ok "Case G: approval older than last_processed → idle" \
  || nope "Case G" "rc=$rc (expected nonzero)"

# ─── Case H: bot-only review on current HEAD → falsy ──────────────────
set_last_review_state "abc1234" "" ""
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[{"author":{"login":"twinning-pipeline[bot]"},"state":"COMMENTED","commit_id":"abc1234","submittedAt":"2026-04-30T11:00:00Z"}]}' \
  review_should_dispatch ENG-517 stub-branch && rc=0 || rc=$?
[[ "$rc" != 0 ]] \
  && ok "Case H: bot-only review → idle (non-bot filter)" \
  || nope "Case H" "rc=$rc (expected nonzero)"

PATH="$ORIG_PATH"
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
