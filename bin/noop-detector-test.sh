#!/usr/bin/env bash
# Tests for bin/run-stage.sh::_dispatch_made_new_commits (ENG-105 follow-up).
#
# The helper is the comparison primitive behind run-stage.sh's
# noop-implementation halt: returns 0 (truthy, "new commits") when the
# worktree's HEAD advanced past the pre-dispatch SHA, returns 1
# (falsy, "NOOP") when HEAD equals pre exactly. Fails open on a missing
# worktree (returns 0) so a worktree-creation bug elsewhere doesn't
# get reclassified as a NOOP.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug-noop}"

# Minimal scaffold so common.sh sourcing succeeds.
_TEST_DIR="$(mktemp -d -t noop-detector-test-XXXXXX)"
case "$_TEST_DIR" in
  /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;;
  *) printf 'REFUSING: %q is not a platform temp dir\n' "$_TEST_DIR" >&2; exit 99 ;;
esac
trap 'rm -rf "$_TEST_DIR"' EXIT

export TARGET_REPO="$_TEST_DIR/target"
mkdir -p "$TARGET_REPO/.pipeline-config/schemas"
printf '{"linear":{"team_id":"T","project_id":"P","stage_label_prefix":"stage:"},"project":{"slug":"test-slug-noop"},"orchestrator":{"paused":false}}' \
  > "$TARGET_REPO/.pipeline-config/config.json"
printf '{}' > "$TARGET_REPO/.pipeline-config/schemas/linear-ids.json"
export HARNESS_STATE_DIR="$_TEST_DIR/state"
export PROJECT_STATE_DIR="$HARNESS_STATE_DIR/$PROJECT_SLUG"
mkdir -p "$PROJECT_STATE_DIR"

# Source run-stage.sh's prereq chain so _dispatch_made_new_commits is in scope.
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=classify-failure.sh
source "$SCRIPT_DIR/classify-failure.sh"
# shellcheck source=dispatch.sh
source "$SCRIPT_DIR/dispatch.sh"
# shellcheck source=run-stage.sh
source "$SCRIPT_DIR/run-stage.sh"

PASS=0; FAIL=0
ok()   { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  ❌ %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Build a tiny git repo to exercise the helper.
WT="$_TEST_DIR/wt"
mkdir -p "$WT"
( cd "$WT"
  git init -q -b main
  git config user.email "t@t.t"
  git config user.name "t"
  printf 'a\n' > a.txt
  git add a.txt
  git commit -q -m 'seed'
)

HEAD_INITIAL="$(git -C "$WT" rev-parse HEAD)"

# ─── Case 1: HEAD unchanged → NOOP (rc=1)
rc=0
_dispatch_made_new_commits "$WT" "$HEAD_INITIAL" || rc=$?
if [[ "$rc" == 1 ]]; then
  ok "case-1: HEAD unchanged → NOOP (rc=1)"
else
  fail "case-1: HEAD unchanged" "expected rc=1 got rc=$rc"
fi

# ─── Case 2: HEAD advanced → new commits (rc=0)
( cd "$WT"
  printf 'b\n' > b.txt
  git add b.txt
  git commit -q -m 'new commit'
)
rc=0
_dispatch_made_new_commits "$WT" "$HEAD_INITIAL" || rc=$?
if [[ "$rc" == 0 ]]; then
  ok "case-2: HEAD advanced → new commits (rc=0)"
else
  fail "case-2: HEAD advanced" "expected rc=0 got rc=$rc"
fi

# ─── Case 3: missing worktree → fail-open (rc=0, treat as new commits)
# Guards against a regression where a transient git failure / vanished
# worktree gets reclassified as a NOOP and halts the issue.
rc=0
_dispatch_made_new_commits "$_TEST_DIR/does-not-exist" "$HEAD_INITIAL" || rc=$?
if [[ "$rc" == 0 ]]; then
  ok "case-3: missing worktree → fail-open (rc=0)"
else
  fail "case-3: missing worktree" "expected rc=0 got rc=$rc"
fi

# ─── Case 4: failure_outcome_for_exit maps 30 → 'noop-implementation'
# Asserts the common.sh edit that registers the new exit code shape.
outcome="$(failure_outcome_for_exit 30 '')"
if [[ "$outcome" == "noop-implementation" ]]; then
  ok "case-4: exit 30 → 'noop-implementation' outcome"
else
  fail "case-4: exit 30 outcome" "expected 'noop-implementation' got '$outcome'"
fi

printf '\nnoop-detector: passed=%d failed=%d\n' "$PASS" "$FAIL"
exit $(( FAIL ? 1 : 0 ))
