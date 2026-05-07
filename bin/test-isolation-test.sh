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
# Save & restore the env afterward so T4b inherits the same env T3 saw.
_t4_saved_target_repo="${TARGET_REPO-}"
_t4_saved_project_slug="${PROJECT_SLUG-}"
_t4_saved_pipeline_dry_run="${PIPELINE_DRY_RUN-}"
_t4_saved_linear_api_key="${LINEAR_API_KEY-}"
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

# Restore env so T4b inherits the same env T3 saw.
if [[ -n "$_t4_saved_target_repo" ]]; then
  export TARGET_REPO="$_t4_saved_target_repo"
else
  unset TARGET_REPO
fi
if [[ -n "$_t4_saved_project_slug" ]]; then
  export PROJECT_SLUG="$_t4_saved_project_slug"
else
  unset PROJECT_SLUG
fi
if [[ -n "$_t4_saved_pipeline_dry_run" ]]; then
  export PIPELINE_DRY_RUN="$_t4_saved_pipeline_dry_run"
else
  unset PIPELINE_DRY_RUN
fi
if [[ -n "$_t4_saved_linear_api_key" ]]; then
  export LINEAR_API_KEY="$_t4_saved_linear_api_key"
else
  unset LINEAR_API_KEY
fi

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

# ─── T5: capture_core_bare_forensic helper unit tests (ENG-68) ──────
# Addresses review iteration 2 finding 'major (a)': the forensic helper
# (the load-bearing observability code for AC #1) had zero unit tests.
# T5a — happy path: helper creates the forensic_root with the expected
#       artifact filenames; returns 0.
# T5b — empty git_dir: returns 0 immediately, no dir created.
# T5c — non-existent git_dir: returns 0 immediately, no dir created.
# T5d — meta_kind registry consistency: pipeline-events.json::meta_kinds
#       contains "forensic" AND docs/pipeline-vocabulary.md renders the
#       same entry (catches drift introduced by forgetting to re-run
#       bin/generate-vocabulary-doc.sh).
#
# T5a/b/c source bin/run-local-helpers.sh and call the helper with a
# stub `log` shim plus a temp HARNESS_STATE_DIR. PROJECT_STATE_DIR /
# LINEAR_API_KEY / PIPELINE_FORENSIC_FALLBACK_ISSUE are unset so the
# helper's Linear-post path is a no-op; the dir + artifacts are the
# load-bearing assertion target.

# shellcheck source=run-local-helpers.sh
source "$HARNESS_ROOT/bin/run-local-helpers.sh" 2>/dev/null || true

if ! declare -f capture_core_bare_forensic >/dev/null 2>&1; then
  fail_at "T5 precondition" "capture_core_bare_forensic undefined after sourcing run-local-helpers.sh"
else
  # Stub log() so the helper's `log "[forensic] ..."` does not die; restore
  # any pre-existing definition after T5.
  _t5_had_log=0
  declare -f log >/dev/null 2>&1 && _t5_had_log=1
  log() { :; }
  _t5_saved_state="${HARNESS_STATE_DIR-}"
  _t5_saved_proj="${PROJECT_STATE_DIR-}"
  _t5_saved_lkey="${LINEAR_API_KEY-}"
  _t5_saved_fallback="${PIPELINE_FORENSIC_FALLBACK_ISSUE-}"
  _t5_saved_issue="${PIPELINE_ISSUE_ID-}"
  unset PROJECT_STATE_DIR LINEAR_API_KEY PIPELINE_FORENSIC_FALLBACK_ISSUE PIPELINE_ISSUE_ID

  # T5a — happy path
  T5A_STATE="$(mktemp -d -t t5a-state.XXXXXX)"
  t5a_probe="$(build_probe)"
  t5a_rc=0
  HARNESS_STATE_DIR="$T5A_STATE" capture_core_bare_forensic "$t5a_probe/.git" || t5a_rc=$?
  # forensic dir lives at $HARNESS_STATE_DIR/_unscoped/forensics/core-bare-flip-<ts>/
  shopt -s nullglob
  t5a_dirs=("$T5A_STATE/_unscoped/forensics/core-bare-flip-"*)
  shopt -u nullglob
  t5a_dir="${t5a_dirs[0]:-}"
  if (( t5a_rc == 0 )) && [[ -d "$t5a_dir" ]] \
     && [[ -e "$t5a_dir/config.before" || -e "$t5a_dir/config.before.error" ]] \
     && [[ -e "$t5a_dir/branches"      || -e "$t5a_dir/branches.error" ]] \
     && [[ -e "$t5a_dir/env-snapshot"  || -e "$t5a_dir/env-snapshot.error" ]] \
     && [[ -e "$t5a_dir/ps-snapshot"   || -e "$t5a_dir/ps-snapshot.error" ]]; then
    pass_at "T5a: helper creates forensic dir + key artifacts (config.before/branches/env-snapshot/ps-snapshot)"
  else
    fail_at "T5a" "rc=$t5a_rc dir=${t5a_dir:-<none>} (artifact presence below)
      config.before:  $([[ -e $t5a_dir/config.before  ]] && echo y || echo n)/$([[ -e $t5a_dir/config.before.error  ]] && echo err || echo .)
      branches:       $([[ -e $t5a_dir/branches       ]] && echo y || echo n)/$([[ -e $t5a_dir/branches.error       ]] && echo err || echo .)
      env-snapshot:   $([[ -e $t5a_dir/env-snapshot   ]] && echo y || echo n)/$([[ -e $t5a_dir/env-snapshot.error   ]] && echo err || echo .)
      ps-snapshot:    $([[ -e $t5a_dir/ps-snapshot    ]] && echo y || echo n)/$([[ -e $t5a_dir/ps-snapshot.error    ]] && echo err || echo .)"
  fi
  rm -rf "$t5a_probe" "$T5A_STATE"

  # T5b — empty git_dir
  T5B_STATE="$(mktemp -d -t t5b-state.XXXXXX)"
  t5b_rc=0
  HARNESS_STATE_DIR="$T5B_STATE" capture_core_bare_forensic "" || t5b_rc=$?
  if (( t5b_rc == 0 )) && [[ ! -d "$T5B_STATE/_unscoped/forensics" ]]; then
    pass_at "T5b: empty git_dir returns 0 with no side effects"
  else
    fail_at "T5b" "rc=$t5b_rc forensics_dir=$([[ -d "$T5B_STATE/_unscoped/forensics" ]] && echo present || echo absent)"
  fi
  rm -rf "$T5B_STATE"

  # T5c — non-existent path
  T5C_STATE="$(mktemp -d -t t5c-state.XXXXXX)"
  t5c_rc=0
  HARNESS_STATE_DIR="$T5C_STATE" capture_core_bare_forensic "/no/such/path/to/git_dir" || t5c_rc=$?
  if (( t5c_rc == 0 )) && [[ ! -d "$T5C_STATE/_unscoped/forensics" ]]; then
    pass_at "T5c: non-existent git_dir returns 0 with no side effects"
  else
    fail_at "T5c" "rc=$t5c_rc forensics_dir=$([[ -d "$T5C_STATE/_unscoped/forensics" ]] && echo present || echo absent)"
  fi
  rm -rf "$T5C_STATE"

  # Restore env so subsequent tests (or repeated invocations) inherit prior state.
  if [[ -n "$_t5_saved_state"    ]]; then export HARNESS_STATE_DIR="$_t5_saved_state"; else unset HARNESS_STATE_DIR; fi
  if [[ -n "$_t5_saved_proj"     ]]; then export PROJECT_STATE_DIR="$_t5_saved_proj"; fi
  if [[ -n "$_t5_saved_lkey"     ]]; then export LINEAR_API_KEY="$_t5_saved_lkey"; fi
  if [[ -n "$_t5_saved_fallback" ]]; then export PIPELINE_FORENSIC_FALLBACK_ISSUE="$_t5_saved_fallback"; fi
  if [[ -n "$_t5_saved_issue"    ]]; then export PIPELINE_ISSUE_ID="$_t5_saved_issue"; fi
  if (( _t5_had_log == 0 )); then unset -f log 2>/dev/null || true; fi
fi

# T5d — meta_kind registry consistency.
# pipeline-events.json::meta_kinds is the source-of-truth array;
# docs/pipeline-vocabulary.md is the rendered doc. After Task 7 they
# must both list "forensic". Drift here is a P0 finding for any future
# ENG-60 follow-up (CLAUDE.md "Pipeline vocabulary" §).
if jq -e '.meta_kinds | index("forensic")' \
     "$HARNESS_ROOT/bin/pipeline-events.json" >/dev/null 2>&1 \
   && grep -qE '^- `forensic`' "$HARNESS_ROOT/docs/pipeline-vocabulary.md"; then
  pass_at "T5d: forensic meta_kind registered in pipeline-events.json AND rendered in vocabulary doc"
else
  src_has=$(jq -r '.meta_kinds | index("forensic") // "MISSING"' \
              "$HARNESS_ROOT/bin/pipeline-events.json" 2>/dev/null || printf MISSING)
  doc_has=$(grep -qE '^- `forensic`' "$HARNESS_ROOT/docs/pipeline-vocabulary.md" \
              && printf yes || printf no)
  fail_at "T5d" "pipeline-events.json: $src_has, vocabulary doc lists forensic: $doc_has"
fi

# ─── QA adversarial coverage (ENG-68; not in plan's Failure Mode → Test Map) ─
# Q1-Q2 pin documented residual gaps so a future widening of the assertion
# pattern set is intentional (test breaks loud) rather than incidental.
# Q3-Q6 fill gaps in the helper's boundary + concurrency budget.

# Re-source run-local-helpers.sh and dispatch.sh so these tests can be reordered
# / split out without breaking. (Sourcing is idempotent via the sentinel.)
# common.sh's TARGET_REPO check has already been satisfied by T4a's seeded
# config above; its env was restored back to T3's, so we re-seed here.
_qa_saved_target_repo="${TARGET_REPO-}"
_qa_saved_project_slug="${PROJECT_SLUG-}"
_qa_saved_pipeline_dry_run="${PIPELINE_DRY_RUN-}"
_qa_saved_linear_api_key="${LINEAR_API_KEY-}"
QA_TARGET="$(mktemp -d -t qa-target.XXXXXX)"
mkdir -p "$QA_TARGET/.pipeline-config/schemas"
cat > "$QA_TARGET/.pipeline-config/config.json" <<'JSON'
{
  "project": {"slug": "qa68"},
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
printf '{"labels":{},"states":{}}\n' > "$QA_TARGET/.pipeline-config/schemas/linear-ids.json"
export TARGET_REPO="$QA_TARGET"
export PROJECT_SLUG="qa68"
export PIPELINE_DRY_RUN=1
: "${LINEAR_API_KEY:=test-mock-key}"; export LINEAR_API_KEY
# shellcheck source=dispatch.sh
source "$HARNESS_ROOT/bin/dispatch.sh" 2>/dev/null || true
# shellcheck source=run-local-helpers.sh
source "$HARNESS_ROOT/bin/run-local-helpers.sh" 2>/dev/null || true

# ─── Q1: chained `-c` form bypasses the assertion (documented residual gap) ─
# Plan OQ-3 acknowledges compound-shell escape; review iter-2 minor-3 noted
# `git -c init.defaultBranch=main -c core.bare=true config foo bar` doesn't
# start with `git -c core.bare=` and slips through. Decision: accepted as a
# known limitation (qa stage's residual surface; CB1-CB5 cover the canonical
# H1 trigger). Pin the limitation: if a future PR adds chained-`-c` matching,
# this test breaks loud, and the maintainer must update plan/runbook docs.
if declare -f assert_no_tool_invocation >/dev/null 2>&1; then
  q1_tmp="$(mktemp -t q1-tx.XXXXXX)"
  printf '%s\n' \
    '{"type":"system","subtype":"init","session_id":"q1","model":"test"}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git -c init.defaultBranch=main -c core.bare=true config foo bar"}}]}}' \
    > "$q1_tmp"
  q1_matched=""
  for _hp in "git config core.bare" "git init --bare" "git --bare" \
             "git config --add core.bare" "git -c core.bare="; do
    _o="$(assert_no_tool_invocation "$q1_tmp" "$_hp")" && _r=0 || _r=$?
    if (( _r == 1 )); then q1_matched="$_hp"; break; fi
  done
  if [[ -z "$q1_matched" ]]; then
    pass_at "Q1: chained -c form (\"git -c init.defaultBranch=… -c core.bare=…\") is NOT matched (documented residual gap; plan OQ-3-class)"
  else
    fail_at "Q1: chained -c form unexpectedly matched" \
      "harness pattern '$q1_matched' matched — if intentional, update plan OQ-3 and remove this Q1 pin"
  fi
  rm -f "$q1_tmp"
else
  fail_at "Q1 precondition" "assert_no_tool_invocation undefined; cannot run Q1"
fi

# ─── Q2: leading-whitespace prefix bypasses the assertion (residual gap) ────
# `assert_no_tool_invocation` uses jq's startswith() — literal-leading match.
# A tool_use command of "  git config core.bare true" (two leading spaces, as
# might appear if an agent indents a one-line script) is not matched. Accepted
# as residual gap: agent transcripts are emitted by `claude -p` which strips
# leading whitespace from Bash commands by convention. Pin in case a future
# transcript shape change leaks indented commands.
if declare -f assert_no_tool_invocation >/dev/null 2>&1; then
  q2_tmp="$(mktemp -t q2-tx.XXXXXX)"
  printf '%s\n' \
    '{"type":"system","subtype":"init","session_id":"q2","model":"test"}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"  git config core.bare true"}}]}}' \
    > "$q2_tmp"
  q2_matched=""
  for _hp in "git config core.bare" "git init --bare" "git --bare" \
             "git config --add core.bare" "git -c core.bare="; do
    _o="$(assert_no_tool_invocation "$q2_tmp" "$_hp")" && _r=0 || _r=$?
    if (( _r == 1 )); then q2_matched="$_hp"; break; fi
  done
  if [[ -z "$q2_matched" ]]; then
    pass_at "Q2: leading-whitespace prefix (\"  git config core.bare true\") is NOT matched (residual gap; transcript shape contract)"
  else
    fail_at "Q2: leading-whitespace prefix unexpectedly matched" \
      "harness pattern '$q2_matched' matched — review whether the transcript shape contract changed"
  fi
  rm -f "$q2_tmp"
else
  fail_at "Q2 precondition" "assert_no_tool_invocation undefined"
fi

# ─── Q3: concurrent helper invocations on the same UTC second do not deadlock ─
# Helper backgrounds 9 captures with `&` then `wait`. Two simultaneous calls
# that resolve to the same `core-bare-flip-<ts>` dir (same UTC second) race-
# share the dir. Test: both calls return 0; the dir exists; at least one full
# artifact set lands. The bash `wait` builtin is documented to return when
# ALL backgrounded children have exited — in bash 3.2 the loop must not
# deadlock or return non-zero on a backgrounded subshell exiting with 1.
if declare -f capture_core_bare_forensic >/dev/null 2>&1; then
  Q3_STATE="$(mktemp -d -t q3-state.XXXXXX)"
  q3_probe="$(build_probe)"
  _q3_had_log=0; declare -f log >/dev/null 2>&1 && _q3_had_log=1
  log() { :; }
  _q3_saved_state="${HARNESS_STATE_DIR-}"
  _q3_saved_proj="${PROJECT_STATE_DIR-}"
  _q3_saved_lkey="${LINEAR_API_KEY-}"
  _q3_saved_iss="${PIPELINE_ISSUE_ID-}"
  _q3_saved_fal="${PIPELINE_FORENSIC_FALLBACK_ISSUE-}"
  unset PROJECT_STATE_DIR LINEAR_API_KEY PIPELINE_ISSUE_ID PIPELINE_FORENSIC_FALLBACK_ISSUE
  export HARNESS_STATE_DIR="$Q3_STATE"
  # Fire two parallel helper invocations on the same probe; wait for both.
  (capture_core_bare_forensic "$q3_probe/.git" >/dev/null 2>&1) &
  q3_pid_a=$!
  (capture_core_bare_forensic "$q3_probe/.git" >/dev/null 2>&1) &
  q3_pid_b=$!
  q3_rc_a=0; q3_rc_b=0
  wait "$q3_pid_a" || q3_rc_a=$?
  wait "$q3_pid_b" || q3_rc_b=$?
  shopt -s nullglob
  q3_dirs=("$Q3_STATE/_unscoped/forensics/core-bare-flip-"*)
  shopt -u nullglob
  # The helper must return 0 in both subshells; at least one artifact file must
  # exist somewhere under the forensic root. Same-second collisions produce
  # one shared dir (mkdir -p is idempotent) so we accept >= 1 dirs.
  q3_dir_count="${#q3_dirs[@]}"
  q3_artifacts_present=0
  if (( q3_dir_count >= 1 )); then
    for _d in "${q3_dirs[@]}"; do
      if [[ -e "$_d/config.before" || -e "$_d/config.before.error" \
            || -e "$_d/branches" || -e "$_d/branches.error" ]]; then
        q3_artifacts_present=1; break
      fi
    done
  fi
  if (( q3_rc_a == 0 && q3_rc_b == 0 && q3_dir_count >= 1 && q3_artifacts_present == 1 )); then
    pass_at "Q3: parallel helper invocations on same probe both return 0 with no deadlock; ${q3_dir_count} forensic dir(s), artifacts present"
  else
    fail_at "Q3: parallel helper invocations" \
      "rc_a=$q3_rc_a rc_b=$q3_rc_b dirs=$q3_dir_count artifacts_present=$q3_artifacts_present"
  fi
  rm -rf "$q3_probe" "$Q3_STATE"
  if [[ -n "$_q3_saved_state" ]]; then export HARNESS_STATE_DIR="$_q3_saved_state"; else unset HARNESS_STATE_DIR; fi
  if [[ -n "$_q3_saved_proj"  ]]; then export PROJECT_STATE_DIR="$_q3_saved_proj"; fi
  if [[ -n "$_q3_saved_lkey"  ]]; then export LINEAR_API_KEY="$_q3_saved_lkey"; fi
  if [[ -n "$_q3_saved_iss"   ]]; then export PIPELINE_ISSUE_ID="$_q3_saved_iss"; fi
  if [[ -n "$_q3_saved_fal"   ]]; then export PIPELINE_FORENSIC_FALLBACK_ISSUE="$_q3_saved_fal"; fi
  if (( _q3_had_log == 0 )); then unset -f log 2>/dev/null || true; fi
else
  fail_at "Q3 precondition" "capture_core_bare_forensic undefined"
fi

# ─── Q4: LINEAR_API_KEY=""  set-empty short-circuits the Linear post ───────
# Helper guards Linear post with `[[ -n "${LINEAR_API_KEY-}" ... ]]`. The
# `${VAR-}` (single-dash) substitution returns "" for both unset and set-
# empty, and `-n ""` is false — so the guard correctly skips. ENG-46 secret-
# handling rule says NEVER use `${VAR:-X}` against secret-named env vars.
# Pin the short-circuit: a future refactor that switches to `${VAR:+set}`
# would invert the semantics and (with LINEAR_API_KEY exported empty in CI)
# silently start posting Linear comments when LINEAR_API_KEY is set-empty.
if declare -f capture_core_bare_forensic >/dev/null 2>&1; then
  Q4_STATE="$(mktemp -d -t q4-state.XXXXXX)"
  Q4_FAKE_HARNESS="$(mktemp -d -t q4-harness.XXXXXX)"
  mkdir -p "$Q4_FAKE_HARNESS/bin"
  # Stub linear.sh that fails loudly if invoked.
  cat > "$Q4_FAKE_HARNESS/bin/linear.sh" <<'STUB'
#!/usr/bin/env bash
printf 'STUB linear.sh INVOKED with: %s\n' "$*" > "${Q4_INVOKE_SENTINEL:-/dev/stderr}"
exit 0
STUB
  chmod +x "$Q4_FAKE_HARNESS/bin/linear.sh"
  q4_probe="$(build_probe)"
  _q4_had_log=0; declare -f log >/dev/null 2>&1 && _q4_had_log=1
  log() { :; }
  _q4_saved_hr="${HARNESS_ROOT-}"
  _q4_saved_state="${HARNESS_STATE_DIR-}"
  _q4_saved_proj="${PROJECT_STATE_DIR-}"
  _q4_saved_lkey="${LINEAR_API_KEY-}"
  _q4_saved_iss="${PIPELINE_ISSUE_ID-}"
  _q4_saved_fal="${PIPELINE_FORENSIC_FALLBACK_ISSUE-}"
  unset PROJECT_STATE_DIR
  export HARNESS_ROOT="$Q4_FAKE_HARNESS"
  export HARNESS_STATE_DIR="$Q4_STATE"
  export Q4_INVOKE_SENTINEL="$Q4_STATE/.linear-invoked"
  export LINEAR_API_KEY=""    # set but empty
  export PIPELINE_FORENSIC_FALLBACK_ISSUE="ENG-68"
  q4_rc=0
  capture_core_bare_forensic "$q4_probe/.git" >/dev/null 2>&1 || q4_rc=$?
  if (( q4_rc == 0 )) && [[ ! -f "$Q4_INVOKE_SENTINEL" ]]; then
    pass_at "Q4: LINEAR_API_KEY=\"\" (set-empty) short-circuits the Linear post (helper still returns 0; stub linear.sh not invoked)"
  else
    fail_at "Q4: LINEAR_API_KEY set-empty short-circuit" \
      "rc=$q4_rc sentinel_present=$([[ -f $Q4_INVOKE_SENTINEL ]] && echo y || echo n) sentinel=$(cat "$Q4_INVOKE_SENTINEL" 2>/dev/null)"
  fi
  unset Q4_INVOKE_SENTINEL
  rm -rf "$q4_probe" "$Q4_STATE" "$Q4_FAKE_HARNESS"
  if [[ -n "$_q4_saved_hr"   ]]; then export HARNESS_ROOT="$_q4_saved_hr"; else unset HARNESS_ROOT; fi
  if [[ -n "$_q4_saved_state" ]]; then export HARNESS_STATE_DIR="$_q4_saved_state"; else unset HARNESS_STATE_DIR; fi
  if [[ -n "$_q4_saved_proj"  ]]; then export PROJECT_STATE_DIR="$_q4_saved_proj"; fi
  if [[ -n "$_q4_saved_lkey"  ]]; then export LINEAR_API_KEY="$_q4_saved_lkey"; else unset LINEAR_API_KEY; fi
  if [[ -n "$_q4_saved_iss"   ]]; then export PIPELINE_ISSUE_ID="$_q4_saved_iss"; fi
  if [[ -n "$_q4_saved_fal"   ]]; then export PIPELINE_FORENSIC_FALLBACK_ISSUE="$_q4_saved_fal"; else unset PIPELINE_FORENSIC_FALLBACK_ISSUE; fi
  if (( _q4_had_log == 0 )); then unset -f log 2>/dev/null || true; fi
else
  fail_at "Q4 precondition" "capture_core_bare_forensic undefined"
fi

# ─── Q5: git_dir is a regular file (not a directory) → helper rc=0, no dir ─
# The helper's first guard is `[[ -n "$git_dir" && -d "$git_dir" ]] || return 0`.
# A regular file fails the `-d` check; helper returns 0 without creating the
# forensic dir. T5b/c cover empty-string and non-existent-path; a regular-file
# path is the third boundary case (operator misconfiguring with a file path).
if declare -f capture_core_bare_forensic >/dev/null 2>&1; then
  Q5_STATE="$(mktemp -d -t q5-state.XXXXXX)"
  q5_file="$(mktemp -t q5-file.XXXXXX)"
  printf 'not a directory\n' > "$q5_file"
  _q5_had_log=0; declare -f log >/dev/null 2>&1 && _q5_had_log=1
  log() { :; }
  _q5_saved_state="${HARNESS_STATE_DIR-}"
  _q5_saved_proj="${PROJECT_STATE_DIR-}"
  unset PROJECT_STATE_DIR
  export HARNESS_STATE_DIR="$Q5_STATE"
  q5_rc=0
  capture_core_bare_forensic "$q5_file" >/dev/null 2>&1 || q5_rc=$?
  if (( q5_rc == 0 )) && [[ ! -d "$Q5_STATE/_unscoped/forensics" ]]; then
    pass_at "Q5: regular-file git_dir returns 0 with no forensic dir created (boundary)"
  else
    fail_at "Q5: regular-file boundary" \
      "rc=$q5_rc forensics_dir=$([[ -d $Q5_STATE/_unscoped/forensics ]] && echo present || echo absent)"
  fi
  rm -f "$q5_file"
  rm -rf "$Q5_STATE"
  if [[ -n "$_q5_saved_state" ]]; then export HARNESS_STATE_DIR="$_q5_saved_state"; else unset HARNESS_STATE_DIR; fi
  if [[ -n "$_q5_saved_proj"  ]]; then export PROJECT_STATE_DIR="$_q5_saved_proj"; fi
  if (( _q5_had_log == 0 )); then unset -f log 2>/dev/null || true; fi
else
  fail_at "Q5 precondition" "capture_core_bare_forensic undefined"
fi

# ─── Q6: git_dir is a non-git dir (passes -d, but git subcommands fail) ────
# Operator misconfiguring TARGET_REPO=/tmp would pass `[[ -d ]]` but every
# git subcommand inside the helper would error. The helper still returns 0;
# `.error` siblings appear for the git-issuing captures; non-git captures
# (env-snapshot, ps-snapshot) succeed. Pin the partial-failure invariant
# from a different angle than T5e/iter-2 minor-5 (which the latest review
# accepted as deferred).
if declare -f capture_core_bare_forensic >/dev/null 2>&1; then
  Q6_STATE="$(mktemp -d -t q6-state.XXXXXX)"
  Q6_NONGIT="$(mktemp -d -t q6-nongit.XXXXXX)"
  # Q6_NONGIT is a directory but has no .git/, no objects, no refs.
  _q6_had_log=0; declare -f log >/dev/null 2>&1 && _q6_had_log=1
  log() { :; }
  _q6_saved_state="${HARNESS_STATE_DIR-}"
  _q6_saved_proj="${PROJECT_STATE_DIR-}"
  unset PROJECT_STATE_DIR
  export HARNESS_STATE_DIR="$Q6_STATE"
  q6_rc=0
  capture_core_bare_forensic "$Q6_NONGIT" >/dev/null 2>&1 || q6_rc=$?
  shopt -s nullglob
  q6_dirs=("$Q6_STATE/_unscoped/forensics/core-bare-flip-"*)
  shopt -u nullglob
  q6_dir="${q6_dirs[0]:-}"
  # Helper must rc=0; forensic dir must exist; env-snapshot (non-git) must
  # exist as a real file. The git-using captures may produce either the
  # primary file (with non-zero git stderr inside) or the .error sibling —
  # both are acceptable per the partial-failure contract.
  q6_env_present=0
  q6_dir_present=0
  [[ -n "$q6_dir" && -d "$q6_dir" ]] && q6_dir_present=1
  [[ -e "$q6_dir/env-snapshot" || -e "$q6_dir/env-snapshot.error" ]] && q6_env_present=1
  if (( q6_rc == 0 && q6_dir_present == 1 && q6_env_present == 1 )); then
    pass_at "Q6: non-git dir passes -d but git captures fail gracefully; helper rc=0; env-snapshot still lands"
  else
    fail_at "Q6: non-git dir boundary" \
      "rc=$q6_rc dir_present=$q6_dir_present env_present=$q6_env_present dir=$q6_dir"
  fi
  rm -rf "$Q6_NONGIT" "$Q6_STATE"
  if [[ -n "$_q6_saved_state" ]]; then export HARNESS_STATE_DIR="$_q6_saved_state"; else unset HARNESS_STATE_DIR; fi
  if [[ -n "$_q6_saved_proj"  ]]; then export PROJECT_STATE_DIR="$_q6_saved_proj"; fi
  if (( _q6_had_log == 0 )); then unset -f log 2>/dev/null || true; fi
else
  fail_at "Q6 precondition" "capture_core_bare_forensic undefined"
fi

# Restore env so any subsequent use of TARGET_REPO sees the saved value.
rm -rf "$QA_TARGET"
if [[ -n "$_qa_saved_target_repo" ]]; then export TARGET_REPO="$_qa_saved_target_repo"; else unset TARGET_REPO; fi
if [[ -n "$_qa_saved_project_slug" ]]; then export PROJECT_SLUG="$_qa_saved_project_slug"; else unset PROJECT_SLUG; fi
if [[ -n "$_qa_saved_pipeline_dry_run" ]]; then export PIPELINE_DRY_RUN="$_qa_saved_pipeline_dry_run"; else unset PIPELINE_DRY_RUN; fi
if [[ -n "$_qa_saved_linear_api_key" ]]; then export LINEAR_API_KEY="$_qa_saved_linear_api_key"; else unset LINEAR_API_KEY; fi

printf '\ntest-isolation: passed=%d failed=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
