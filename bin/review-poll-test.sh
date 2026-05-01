#!/usr/bin/env bash
# ENG-50 / ENG-54: review_should_dispatch returns truthy when the PR's HEAD
# SHA differs from last-review-state.sha (or no state exists), falsy otherwise.
#
# ENG-54 narrowed the contract: the human-approval gate moved to build's P2,
# so review-poll no longer fires on fresh non-bot APPROVED / CHANGES_REQUESTED
# reviews. The cases below pin the post-ENG-54 contract.
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
  "pr view") printf '%s\n' "${GH_PR_VIEW_JSON:-{\"commits\":[]\}}" ;;
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

# Helper to inject a last-review-state into the fixture in the post-ENG-54
# format (single sha field).
set_last_review_state() {
  local sha="$1"
  local body
  body=$(printf '<!-- pipeline-state: last-review-state -->\n\n{"sha":%s}\n' \
    "$([[ -z "$sha" ]] && printf 'null' || printf '"%s"' "$sha")")
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
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}]}' \
  review_should_dispatch ENG-510 stub-branch && rc=0 || rc=$?
[[ "$rc" == 0 ]] \
  && ok "Case A: bootstrap → dispatch" \
  || nope "Case A" "rc=$rc"

# ─── Case B: HEAD SHA differs from last-review-state.sha → truthy ─────
set_last_review_state "old1234"
GH_PR_VIEW_JSON='{"commits":[{"oid":"new5678"}]}' \
  review_should_dispatch ENG-511 stub-branch && rc=0 || rc=$?
[[ "$rc" == 0 ]] \
  && ok "Case B: SHA differs → dispatch" \
  || nope "Case B" "rc=$rc"

# ─── Case C: HEAD SHA matches last-reviewed SHA → falsy ───────────────
set_last_review_state "abc1234"
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}]}' \
  review_should_dispatch ENG-512 stub-branch && rc=0 || rc=$?
[[ "$rc" != 0 ]] \
  && ok "Case C: SHA matches → idle" \
  || nope "Case C" "rc=$rc (expected nonzero)"

# ─── Case D (ENG-54 regression): fresh APPROVED on current HEAD does NOT ──
# trigger a re-dispatch under the new contract. The human-approval gate
# moved to build's P2; review-poll stops on SHA equality regardless of
# review state.
set_last_review_state "abc1234"
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[{"author":{"login":"alice"},"state":"APPROVED","commit_id":"abc1234","submittedAt":"2026-04-30T11:00:00Z"}]}' \
  review_should_dispatch ENG-513 stub-branch && rc=0 || rc=$?
[[ "$rc" != 0 ]] \
  && ok "Case D ENG-54: fresh APPROVED on same HEAD does NOT re-dispatch (no human-approval gate)" \
  || nope "Case D ENG-54" "rc=$rc — review still re-dispatched on approval; human-approval gate must be at build P2"

# ─── Case E (ENG-54 regression): fresh CHANGES_REQUESTED on current HEAD ──
# also does NOT trigger a re-dispatch; humans express disapproval out-of-band
# (pipeline:halted) or the PR's branch protection prevents merge.
set_last_review_state "abc1234"
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[{"author":{"login":"alice"},"state":"CHANGES_REQUESTED","commit_id":"abc1234","submittedAt":"2026-04-30T11:00:00Z"}]}' \
  review_should_dispatch ENG-514 stub-branch && rc=0 || rc=$?
[[ "$rc" != 0 ]] \
  && ok "Case E ENG-54: fresh CHANGES_REQUESTED on same HEAD does NOT re-dispatch" \
  || nope "Case E ENG-54" "rc=$rc — review still re-dispatched on CR; gate must be at build P2"

# ─── Case F: gh query returns malformed JSON ('{}') → defensive dispatch ──
# review_should_dispatch's pr_view-check returns 0 on either an empty value
# or the literal '{}'; both indicate the gh query failed to produce useful
# output. Pin defensive-dispatch behavior so a transient gh outage doesn't
# silently freeze the review stage.
set_last_review_state "abc1234"
GH_PR_VIEW_JSON='{}' \
  review_should_dispatch ENG-515 stub-branch && rc=0 || rc=$?
[[ "$rc" == 0 ]] \
  && ok "Case F: gh PR view '{}' → defensive dispatch" \
  || nope "Case F" "rc=$rc"

PATH="$ORIG_PATH"
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
