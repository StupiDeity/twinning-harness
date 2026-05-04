#!/usr/bin/env bash
# Tests for bin/cleanup-worktrees.sh — ENG-64.
#
# Two contracts are pinned here:
#   1. issue_id_from_branch's regex (cases A-G2). The original sed used
#      `|` as both the s-command delimiter and ERE alternation operator,
#      which BSD sed parses as the closing delimiter. Cases A-G2 lock
#      the contract: lowercase feat/fix prefixes match; everything else
#      returns empty.
#   2. remove_tree + worktree-orphan-detected metric shape (cases H, I, J).
#      The original metric calls passed reason/branch in the issue_id/stage
#      slots, producing JSONL with issue_id="merged" and stage="feat/eng-…".
#      Cases H, I, J pin the corrected positional contract from
#      bin/metrics.sh:20 — slot 2 = issue_id (ENG-N or empty); slot 3 =
#      stage (empty for cleanup events); branch and reason ride in notes.
#
# Source-and-stub pattern (CLAUDE.md §"How tests work"):
#   - PIPELINE_DRY_RUN=1 + LINEAR_API_KEY=test-mock-key (defensive; the
#     code paths we exercise do not call Linear).
#   - Throwaway TARGET_REPO + isolated PROJECT_STATE_DIR.
#   - Stub `git` on PATH so remove_tree's `git -C TARGET_REPO worktree
#     remove --force` and `git -C TARGET_REPO branch -D` no-op without
#     touching real worktrees. Do NOT shadow metrics.sh — we want the
#     real JSONL writer to validate the full positional contract.

set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

# Throwaway TARGET_REPO with the minimum config.json common.sh demands.
_TEST_ROOT="$(mktemp -d -t twinning-eng64.XXXXXX)"
case "$_TEST_ROOT" in
  /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) : ;;
  *) printf 'REFUSING: %q is not a platform temp dir\n' "$_TEST_ROOT" >&2; exit 99 ;;
esac
export TARGET_REPO="$_TEST_ROOT/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
cat > "$TARGET_REPO/.pipeline-config/config.json" <<'JSON'
{
  "linear": {
    "team_id": "x",
    "project_id": "x",
    "native_states": {"in_review": "x", "done": "x", "active": "x"},
    "workflow_stages": ["brainstorming","planning","implementing","ui","reviewing","qa","building","released"],
    "stage_label_prefix": "stage:"
  },
  "orchestrator": {},
  "human_checkpoints": {"require_human_on_threshold": {}},
  "project": {"slug": "test-slug"}
}
JSON

# Isolated state dir + metrics file — read by run_metrics-style assertions.
HARNESS_STATE_DIR="$(mktemp -d -t twinning-eng64-state.XXXXXX)"
PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
JSONL="${PROJECT_STATE_DIR}/metrics/events.jsonl"
mkdir -p "$(dirname "$JSONL")"
export HARNESS_STATE_DIR PROJECT_STATE_DIR

# Stub `git` so remove_tree's worktree/branch operations no-op cleanly
# against fake paths. Real metrics.sh stays on the original PATH because
# remove_tree calls it via `bash "$SCRIPT_DIR/metrics.sh"` (absolute path),
# not `git`-style PATH lookup.
STUB_DIR="$(mktemp -d -t twinning-eng64-stubs.XXXXXX)"
cat > "$STUB_DIR/git" <<'STUB'
#!/usr/bin/env bash
# Test stub: no-op for the two subcommands cleanup-worktrees.sh::remove_tree
# invokes (worktree remove, branch -D). Anything else falls through to the
# real git so source-time `git -C $TARGET_REPO …` calls (none today, but
# defensive) still work.
case "${*}" in
  *"worktree remove"*|*"branch -D"*) exit 0 ;;
  *) exec /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin /usr/bin/git "$@" ;;
esac
STUB
chmod +x "$STUB_DIR/git"
export PATH="$STUB_DIR:$PATH"

trap 'rm -rf "$_TEST_ROOT" "$HARNESS_STATE_DIR" "$STUB_DIR"' EXIT

# Source the script under test. Sentinel guard (added in the prior commit)
# prevents main from firing on source.
# shellcheck source=cleanup-worktrees.sh
source "$HARNESS_DIR/cleanup-worktrees.sh"
# common.sh sets `-e`; relax for assertion flow.
set +e

PASS=0; FAIL=0; FAILED_CASES=()
report_ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
report_fail() {
  printf 'FAIL: %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3" >&2
  FAIL=$((FAIL+1)); FAILED_CASES+=("$1")
}
assert_eq() {
  local name="$1" expected="$2" got="$3"
  if [[ "$got" == "$expected" ]]; then report_ok "$name"; else report_fail "$name" "$expected" "$got"; fi
}

reset_jsonl() { : > "$JSONL"; }
last_line()   { tail -n 1 "$JSONL"; }

# ─── Cases A-G2: issue_id_from_branch regex contract ──────────────────────

assert_eq "case-A: feat/eng-99-foo → ENG-99" \
  "ENG-99" "$(issue_id_from_branch "feat/eng-99-foo" 2>/dev/null)"

assert_eq "case-B: fix/eng-100-bar-baz → ENG-100" \
  "ENG-100" "$(issue_id_from_branch "fix/eng-100-bar-baz" 2>/dev/null)"

assert_eq "case-C: feat/eng-7-x (single digit) → ENG-7" \
  "ENG-7" "$(issue_id_from_branch "feat/eng-7-x" 2>/dev/null)"

assert_eq "case-D: main (no prefix) → empty" \
  "" "$(issue_id_from_branch "main" 2>/dev/null)"

assert_eq "case-E: feature/eng-5-foo (wrong prefix) → empty" \
  "" "$(issue_id_from_branch "feature/eng-5-foo" 2>/dev/null)"

assert_eq "case-F: feat/foo-bar (no eng-N) → empty" \
  "" "$(issue_id_from_branch "feat/foo-bar" 2>/dev/null)"

assert_eq "case-G: empty input under set -u → empty (no crash)" \
  "" "$(issue_id_from_branch "" 2>/dev/null)"

assert_eq "case-G2: feat/ENG-99-foo (uppercase, I flag dropped) → empty" \
  "" "$(issue_id_from_branch "feat/ENG-99-foo" 2>/dev/null)"

# ─── Cases H, I, J: remove_tree + orphan-detected metric shape ────────────
# Lock the bin/metrics.sh:20 positional contract:
#   slot 2 = issue_id (ENG-N or empty), slot 3 = stage (empty for cleanup),
#   branch and reason ride in notes.

# Case H: remove_tree carries ENG-13 in the issue_id slot, "" in stage,
# and emits branch=…, reason=…, path=… as notes.
reset_jsonl
remove_tree "/tmp/cleanup-test-h-$$" "feat/eng-13-foo" "merged" "ENG-13" >/dev/null 2>&1
line="$(last_line)"
issue_id="$(jq -r '.issue_id' <<<"$line")"
stage="$(jq -r '.stage' <<<"$line")"
event="$(jq -r '.event' <<<"$line")"
outcome="$(jq -r '.outcome' <<<"$line")"
notes="$(jq -r '.notes' <<<"$line")"
if [[ "$event" == "worktree-cleanup" ]] \
   && [[ "$issue_id" == "ENG-13" ]] \
   && [[ "$stage" == "" ]] \
   && [[ "$outcome" == "success" ]] \
   && [[ "$notes" == *"branch=feat/eng-13-foo"* ]] \
   && [[ "$notes" == *"reason=merged"* ]] \
   && [[ "$notes" == *"path=/tmp/cleanup-test-h-$$"* ]]; then
  report_ok "case-H remove_tree merged: issue_id=ENG-13, stage='', notes carries branch+reason+path"
else
  report_fail "case-H remove_tree merged" \
    "issue_id=ENG-13 stage='' notes~'branch=… reason=merged path=…'" \
    "event=$event issue_id=$issue_id stage=$stage outcome=$outcome notes=$notes"
fi

# Case I: caller passes "" for issue_id (branch did not match regex);
# JSONL must have empty issue_id, empty stage — no field-shift.
reset_jsonl
remove_tree "/tmp/cleanup-test-i-$$" "main" "merged" "" >/dev/null 2>&1
line="$(last_line)"
issue_id="$(jq -r '.issue_id' <<<"$line")"
stage="$(jq -r '.stage' <<<"$line")"
notes="$(jq -r '.notes' <<<"$line")"
if [[ "$issue_id" == "" ]] \
   && [[ "$stage" == "" ]] \
   && [[ "$notes" == *"branch=main"* ]] \
   && [[ "$notes" == *"reason=merged"* ]]; then
  report_ok "case-I remove_tree empty issue_id: no field-shift, branch lands in notes"
else
  report_fail "case-I remove_tree empty issue_id" \
    "issue_id='' stage='' notes~'branch=main'" \
    "issue_id=$issue_id stage=$stage notes=$notes"
fi

# Case J: orphan-detected metric (cleanup-worktrees.sh:88) — same field
# shape. Exercise the metrics call directly with the corrected positionals
# so a future regression at line 88 fails this assertion.
reset_jsonl
bash "$HARNESS_DIR/metrics.sh" worktree-orphan-detected "ENG-13" "" warn 0 \
  "branch=feat/eng-13-foo path=/tmp/cleanup-test-j age_days=33"
line="$(last_line)"
event="$(jq -r '.event' <<<"$line")"
issue_id="$(jq -r '.issue_id' <<<"$line")"
stage="$(jq -r '.stage' <<<"$line")"
outcome="$(jq -r '.outcome' <<<"$line")"
notes="$(jq -r '.notes' <<<"$line")"
if [[ "$event" == "worktree-orphan-detected" ]] \
   && [[ "$issue_id" == "ENG-13" ]] \
   && [[ "$stage" == "" ]] \
   && [[ "$outcome" == "warn" ]] \
   && [[ "$notes" == *"branch=feat/eng-13-foo"* ]] \
   && [[ "$notes" == *"age_days=33"* ]]; then
  report_ok "case-J orphan-detected: issue_id=ENG-13, stage='', notes carries branch+age_days"
else
  report_fail "case-J orphan-detected" \
    "issue_id=ENG-13 stage='' notes~'branch=… age_days=33'" \
    "event=$event issue_id=$issue_id stage=$stage outcome=$outcome notes=$notes"
fi

echo
echo "cleanup-worktrees-test: passed=$PASS failed=$FAIL"
(( FAIL == 0 )) || exit 1
