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

echo
echo "cleanup-worktrees-test: passed=$PASS failed=$FAIL"
(( FAIL == 0 )) || exit 1
