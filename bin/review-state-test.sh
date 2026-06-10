#!/usr/bin/env bash
# ENG-50: bin/review-state.sh helper covers bootstrap/update/read of the
# orchestrator's last-review-state/<issue> Linear comment.
set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

_TEST_TARGET="$(mktemp -d -t twinning-rstate-target.XXXXXX)"
_TEST_STUB="$(mktemp -d -t twinning-rstate-stub.XXXXXX)"
case "$_TEST_TARGET" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
case "$_TEST_STUB"   in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
trap 'rm -rf "$_TEST_TARGET" "$_TEST_STUB"' EXIT

mkdir -p "$_TEST_TARGET/.pipeline-config"
cat > "$_TEST_TARGET/.pipeline-config/config.json" <<'JSON'
{"project":{"slug":"test-slug"},"orchestrator":{"paused":false}}
JSON
export TARGET_REPO="$_TEST_TARGET"

# Stub linear.sh: capture add-comment + emulate get-comments from a
# per-test fixture file. Post-ENG-150, the call shape is
# `add-comment <issue> --sig <sig> --body <body>` and the stub records
# the parsed sig + ident.
LINEAR_CALLS="$_TEST_STUB/linear-calls.log"
COMMENTS_FIXTURE="$_TEST_STUB/comments.json"
printf '[]' > "$COMMENTS_FIXTURE"
: > "$LINEAR_CALLS"
cat > "$_TEST_STUB/linear.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  add-comment)
    # \$2=issue, then --sig <sig> --body <body>
    issue="\$2"; shift 2
    sig=""; body=""
    while (( \$# > 0 )); do
      case "\$1" in
        --sig)  sig="\$2"; shift 2 ;;
        --sig=*) sig="\${1#--sig=}"; shift ;;
        --body) body="\$2"; shift 2 ;;
        --body=*) body="\${1#--body=}"; shift ;;
        *) shift ;;
      esac
    done
    printf 'aouc\\t%s\\t%s\\n' "\$sig" "\$issue" >> "$LINEAR_CALLS"
    body_json="\$(jq -nc --arg b "\$body" '{id:"c1",createdAt:"2026-04-30T10:00:00Z",body:\$b}')"
    jq --argjson new "\$body_json" '. + [\$new]' "$COMMENTS_FIXTURE" > "$_TEST_STUB/_t" && mv "$_TEST_STUB/_t" "$COMMENTS_FIXTURE"
    exit 0 ;;
  get-comments)
    cat "$COMMENTS_FIXTURE" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/linear.sh"

# shellcheck source=common.sh
source "$SCRIPT_DIR_REAL/common.sh"
# shellcheck source=review-state.sh
source "$SCRIPT_DIR_REAL/review-state.sh"
SCRIPT_DIR="$_TEST_STUB"

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# ─── Case 1: bootstrap_review_state writes initial null-sha state ─────
# ENG-54: `last_processed_approval_at` and `last_processed_cr_at` were
# removed when the human-approval gate moved to build's P2. The struct
# now carries only `sha`.
: > "$LINEAR_CALLS"; printf '[]' > "$COMMENTS_FIXTURE"
bootstrap_review_state ENG-501 >/dev/null 2>&1
sig="$(awk -F'\t' '$1=="aouc"{print $2; exit}' "$LINEAR_CALLS")"
posted="$(jq -r '[.[] | select(.body | contains("<!-- pipeline-state: last-review-state -->"))][0].body' "$COMMENTS_FIXTURE")"
[[ "$sig" == "last-review-state/ENG-501" ]] \
  && ok "case-1 bootstrap uses correct sig" \
  || nope "case-1 sig" "got: $sig"
[[ "$posted" == *"<!-- pipeline-state: last-review-state -->"* ]] \
  && ok "case-1 bootstrap body has marker" \
  || nope "case-1 marker" "body: $posted"
state_json="$(printf '%s\n' "$posted" | grep -E '^\{' | head -1)"
[[ "$(jq -r '.sha' <<<"$state_json")" == "null" ]] \
  && ok "case-1 sha=null" || nope "case-1 sha" "got: $(jq -r '.sha' <<<"$state_json")"
# ENG-54 negative: the dropped fields must NOT reappear in the payload.
[[ "$(jq 'has("last_processed_approval_at")' <<<"$state_json")" == "false" ]] \
  && ok "case-1 ENG-54: last_processed_approval_at field absent" \
  || nope "case-1 ENG-54 approval_at field" "still present in: $state_json"
[[ "$(jq 'has("last_processed_cr_at")' <<<"$state_json")" == "false" ]] \
  && ok "case-1 ENG-54: last_processed_cr_at field absent" \
  || nope "case-1 ENG-54 cr_at field" "still present in: $state_json"

# ─── Case 2: update_review_state writes the supplied SHA ──────────────
: > "$LINEAR_CALLS"; printf '[]' > "$COMMENTS_FIXTURE"
update_review_state ENG-502 "abc1234" >/dev/null 2>&1
posted="$(jq -r '[.[] | select(.body | contains("<!-- pipeline-state: last-review-state -->"))][0].body' "$COMMENTS_FIXTURE")"
state_json="$(printf '%s\n' "$posted" | grep -E '^\{' | head -1)"
[[ "$(jq -r '.sha' <<<"$state_json")" == "abc1234" ]] \
  && ok "case-2 sha=abc1234" || nope "case-2 sha" "got: $(jq -r '.sha' <<<"$state_json")"
[[ "$(jq 'has("last_processed_approval_at")' <<<"$state_json")" == "false" ]] \
  && ok "case-2 ENG-54: approval_at field absent on update" \
  || nope "case-2 ENG-54 approval_at" "still present in: $state_json"

# ─── Case 3: read_review_state parses back what update wrote ──────────
read_back="$(read_review_state ENG-502)"
[[ "$(jq -r '.sha' <<<"$read_back")" == "abc1234" ]] \
  && ok "case-3 read returns sha" || nope "case-3 read sha" "got: $(jq -r '.sha' <<<"$read_back")"

# ─── Case 4: read_review_state on missing comment returns empty ───────
printf '[]' > "$COMMENTS_FIXTURE"
read_back="$(read_review_state ENG-503 2>/dev/null || printf '')"
[[ -z "$read_back" ]] \
  && ok "case-4 read returns empty when no comment exists" \
  || nope "case-4 empty" "got: $read_back"

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
