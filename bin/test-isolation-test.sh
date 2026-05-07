#!/usr/bin/env bash
# Regression test for the 2026-05-04 fixture-leak incident.
#
# Symptom: ENG-63 / ENG-64 / ENG-65 implementing-stage dispatches halted on
# SEVERE scope violations because the bin/*-test.sh fixtures landed
# `seed.txt` (and stray `feat/eng-58XX-test` branches) in the live worktree.
# Forensic finding: the harness's main repo had `core.bare=true` set; with
# that flag, fixture `git init` calls in subshells inside tempdirs no
# longer fully isolate from the parent's git context, and the inherited
# pre-commit-hook env (`GIT_INDEX_FILE=.git/index` relative path) lets
# fixture commits resolve into the harness's `.git/`.
#
# This test pins the defended-against invariants:
#
#   T1: The .githooks/pre-commit hook unsets the in-bound GIT_* env vars
#       so test fixtures can't inherit GIT_INDEX_FILE / GIT_DIR / etc.
#   T2: The hook checks core.bare and self-heals (sets to false + warns)
#       so a transient flip doesn't silently corrupt state across ticks.
#   T3: Running each git-ops-touching test (pipeline-test.sh,
#       scope-check-test.sh, secret-probe-lint-test.sh,
#       secret-probe-lint-adversarial-test.sh) from a hostile cwd inside
#       a non-bare git worktree, with a poisoned GIT_INDEX_FILE in env,
#       must NOT leak commits, branches, or files into the parent worktree.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$SCRIPT_DIR/.."

PASS=0; FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s\n%s\n' "$1" "$2"; }

# ─── T1: pre-commit hook unsets in-bound GIT_* env vars ─────────────
hook="$HARNESS_ROOT/.githooks/pre-commit"
if [[ ! -f "$hook" ]]; then
  fail_at "T1: hook missing" "expected $hook"
else
  # The hook's unset list MUST cover at minimum the vars git itself sets
  # when invoking hooks (per `git help hooks` and observed Darwin output).
  required=(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
            GIT_NAMESPACE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
            GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_PREFIX)
  # Collapse the unset block (folded across continuation lines) into a single
  # logical line, then check each required name appears as a word in any
  # `unset …` invocation.
  unset_block="$(awk '/^[[:space:]]*unset / {p=1} p {printf "%s ", $0; if ($NF !~ /\\$/) {print ""; p=0}}' "$hook")"
  missing=""
  for v in "${required[@]}"; do
    grep -qE "(^| )${v}( |$)" <<<"$unset_block" || missing+="  - $v"$'\n'
  done
  if [[ -z "$missing" ]]; then
    pass_at "T1: hook unsets all required GIT_* env vars"
  else
    fail_at "T1: hook unset list incomplete" "$missing"
  fi
fi

# ─── T2: hook contains a core.bare invariant guard ──────────────────
if grep -q 'core\.bare' "$hook" 2>/dev/null \
   && grep -q 'config core.bare false' "$hook" 2>/dev/null; then
  pass_at "T2: hook has core.bare=false self-heal"
else
  fail_at "T2: missing core.bare guard in hook" \
    "expected the hook to read core.bare and reset to false on detection"
fi

# T2 (run-local.sh as well — same invariant on the launchd path)
if grep -q 'core\.bare' "$HARNESS_ROOT/bin/run-local.sh" 2>/dev/null; then
  pass_at "T2: run-local.sh has core.bare invariant"
else
  fail_at "T2: missing core.bare guard in run-local.sh" \
    "the launchd path bypasses the hook; needs its own self-heal"
fi

# ─── T3: per-test fixture-leak repro under hostile env ──────────────
# Build a non-bare probe worktree, set hostile GIT_INDEX_FILE=.git/index
# (relative — matches what git emits when invoking real hooks), run each
# git-ops test from cwd=probe-worktree, and assert the probe is unchanged.
build_probe() {
  local p; p="$(mktemp -d -t test-isolation-probe.XXXXXX)"
  git -C "$p" init --quiet --initial-branch=main
  git -C "$p" config user.email probe@probe
  git -C "$p" config user.name probe
  printf 'probe\n' > "$p/sentinel.txt"
  git -C "$p" add sentinel.txt
  git -C "$p" commit --quiet -m sentinel
  printf '%s' "$p"
}
snapshot() {
  local p="$1"
  printf 'branches=%s\n' "$(git -C "$p" branch -a | wc -l | tr -d ' ')"
  printf 'log=%s\n'      "$(git -C "$p" log --all --oneline | wc -l | tr -d ' ')"
  printf 'tracked=%s\n'  "$(git -C "$p" ls-files | wc -l | tr -d ' ')"
  printf 'dirty=%s\n'    "$(git -C "$p" status --porcelain --untracked-files=all | wc -l | tr -d ' ')"
}

for test_file in pipeline-test.sh scope-check-test.sh \
                 secret-probe-lint-test.sh secret-probe-lint-adversarial-test.sh; do
  probe="$(build_probe)"
  before="$(snapshot "$probe")"
  (
    cd "$probe"
    # Hostile env: relative GIT_INDEX_FILE (what real hooks emit) + a
    # poisoned GIT_DIR pointing at probe's .git/. This is the worst-case
    # configuration any test fixture might face.
    export GIT_INDEX_FILE=".git/index"
    export GIT_DIR="$probe/.git"
    TARGET_REPO="$HARNESS_ROOT" \
      bash "$HARNESS_ROOT/bin/$test_file" >/dev/null 2>&1 || true
  )
  after="$(snapshot "$probe")"
  if [[ "$before" == "$after" ]]; then
    pass_at "T3 $test_file: probe worktree unchanged after hostile invocation"
  else
    fail_at "T3 $test_file: leak detected" \
      "  before:\n$(sed 's/^/    /' <<<"$before")\n  after:\n$(sed 's/^/    /' <<<"$after")"
  fi
  rm -rf "$probe"
done

# ─── T4: core.bare invariant under candidate trigger scenarios (ENG-68) ─
# T4a: synthetic transcript replay through assert_no_tool_invocation;
#      assertion FIRES on each of the five forbidden command shapes,
#      returns 1 with the matched command on stdout. Tests Task-5's
#      helper layer directly. The probe parent's core.bare stays false
#      because the assertion is content-based (transcript scan), not
#      a state flip.
# T4b: extends T3's hostile-env probe loop with a core.bare invariant
#      — no test fixture flips the bit on the probe parent.
# T4c: positive control. Direct invocation MUST flip the bit, proving
#      the test mechanism (read via --git-dir) works.

# T4a precondition: source dispatch.sh to expose assert_no_tool_invocation.
# common.sh requires TARGET_REPO + a config.json — seed a throwaway one.
T4A_TARGET="$(mktemp -d -t t4a-target.XXXXXX)"
mkdir -p "$T4A_TARGET/.pipeline-config/schemas"
cat > "$T4A_TARGET/.pipeline-config/config.json" <<'JSON'
{
  "project": {"slug": "t4a"},
  "linear": {
    "team_id": "x",
    "project_id": "x",
    "stage_label_prefix": "stage:",
    "native_states": {"inbox": "Todo", "active": "In Progress", "done": "Done"},
    "workflow_stages": ["brainstorming","planning","implementing","ui","reviewing","qa","building","released"]
  },
  "orchestrator": {"paused": false}
}
JSON
printf '{"labels":{},"states":{}}\n' > "$T4A_TARGET/.pipeline-config/schemas/linear-ids.json"
export TARGET_REPO="$T4A_TARGET"
export PROJECT_SLUG="t4a"
export PIPELINE_DRY_RUN=1
: "${LINEAR_API_KEY:=test-mock-key}"; export LINEAR_API_KEY
# shellcheck source=dispatch.sh
source "$HARNESS_ROOT/bin/dispatch.sh" 2>/dev/null || true

if ! declare -f assert_no_tool_invocation >/dev/null 2>&1; then
  fail_at "T4a precondition" "assert_no_tool_invocation undefined after sourcing dispatch.sh"
else
  t4a_probe="$(build_probe)"
  t4a_tmp="$(mktemp -t t4a-tx.XXXXXX)"
  t4a_failed=0
  for _pat in \
      "git config core.bare true" \
      "git init --bare" \
      "git --bare config core.bare true" \
      "git config --add core.bare true" \
      "git -c core.bare=true config foo bar"; do
    # Build a minimal NDJSON transcript with the candidate command in a
    # tool_use block.
    {
      printf '%s\n' \
        '{"type":"system","subtype":"init","session_id":"t4a","model":"test"}'
      printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]}}\n' "$_pat"
    } > "$t4a_tmp"
    # At least one of the five harness patterns MUST match the candidate.
    _matched=""
    for _harness_pat in "git config core.bare" "git init --bare" "git --bare" \
                        "git config --add core.bare" "git -c core.bare="; do
      _out="$(assert_no_tool_invocation "$t4a_tmp" "$_harness_pat")" \
        && _rc=0 || _rc=$?
      if (( _rc == 1 )); then _matched="$_harness_pat"; break; fi
    done
    if [[ -z "$_matched" ]]; then
      fail_at "T4a candidate '$_pat'" "no harness pattern matched"
      t4a_failed=1
    fi
  done
  rm -f "$t4a_tmp"
  # T4a side-condition: probe parent's core.bare stays false (assertion
  # is content-based, not state-based).
  t4a_after_bare="$(git --git-dir="$t4a_probe/.git" config --get core.bare 2>/dev/null || printf 'false')"
  if [[ "$t4a_failed" == "0" && "$t4a_after_bare" == "false" ]]; then
    pass_at "T4a: assertion fires on all 5 forbidden forms; probe parent core.bare stays false"
  else
    fail_at "T4a aggregate" "t4a_failed=$t4a_failed bare_after=$t4a_after_bare"
  fi
  rm -rf "$t4a_probe"
fi
rm -rf "$T4A_TARGET"

# T4b: extend T3's hostile-env probe loop with a core.bare invariant.
# For each test_file already exercised in T3, after the test runs the
# probe parent's core.bare must still be `false` (no fixture path
# silently flipped the bit through inherited GIT_DIR).
for test_file in pipeline-test.sh scope-check-test.sh \
                 secret-probe-lint-test.sh secret-probe-lint-adversarial-test.sh; do
  t4b_probe="$(build_probe)"
  t4b_before_bare="$(git --git-dir="$t4b_probe/.git" config --get core.bare 2>/dev/null || printf 'false')"
  (
    cd "$t4b_probe"
    export GIT_INDEX_FILE=".git/index"
    export GIT_DIR="$t4b_probe/.git"
    TARGET_REPO="$HARNESS_ROOT" \
      bash "$HARNESS_ROOT/bin/$test_file" >/dev/null 2>&1 || true
  )
  t4b_after_bare="$(git --git-dir="$t4b_probe/.git" config --get core.bare 2>/dev/null || printf 'false')"
  if [[ "$t4b_before_bare" == "false" && "$t4b_after_bare" == "false" ]]; then
    pass_at "T4b $test_file: probe parent core.bare stays false (no flip)"
  else
    fail_at "T4b $test_file" "before=$t4b_before_bare after=$t4b_after_bare"
  fi
  rm -rf "$t4b_probe"
done

# T4c: positive control. Direct invocation MUST flip the bit, proving
# the test mechanism (read via --git-dir) works. Without this, T4a/T4b
# could silently pass on a broken read mechanism that always returns
# "false".
t4c_probe="$(build_probe)"
git --git-dir="$t4c_probe/.git" config core.bare true 2>/dev/null
t4c_after="$(git --git-dir="$t4c_probe/.git" config --get core.bare 2>/dev/null || printf 'false')"
if [[ "$t4c_after" == "true" ]]; then
  pass_at "T4c: positive control — direct invocation flips bit"
else
  fail_at "T4c" "expected true after direct flip, got $t4c_after"
fi
rm -rf "$t4c_probe"

printf '\ntest-isolation: passed=%d failed=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
