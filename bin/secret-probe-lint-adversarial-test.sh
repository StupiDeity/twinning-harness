#!/usr/bin/env bash
# QA-authored adversarial coverage for bin/secret-probe-lint.sh (ENG-46).
# These cases are NOT in the plan's Failure Mode → Test Map; they exercise
# regex-shape, output-format, and pathspec-exclusion edge cases that the
# plan-mandated cases (1-10 in bin/secret-probe-lint-test.sh) cover only
# by code inspection or by single-hit fixtures.
#
# Mirrors the harness shape of bin/secret-probe-lint-test.sh.

set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
# shellcheck source=common.sh
source "$SCRIPT_DIR_REAL/common.sh"

: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

LINT="$SCRIPT_DIR_REAL/secret-probe-lint.sh"

PASS=0; FAIL=0

setup_git_fixture() {
  local dir
  dir="$(mktemp -d)"
  case "$dir" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;;
    *) printf 'REFUSING: %q is not a temp dir\n' "$dir" >&2; exit 99 ;;
  esac
  (
    cd "$dir"
    git init -q
    git config user.email test@example.com
    git config user.name 'test'
  )
  printf '%s' "$dir"
}

cleanup_fixture() {
  local dir="$1"
  case "$dir" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$dir" ;;
  esac
}

# Echo "<exit>|<stdout-file>|<stderr-file>" — caller must rm the temp files.
run_lint_in() {
  local dir="$1"
  local out err exit_code
  out="$(mktemp)"; err="$(mktemp)"
  set +e
  ( cd "$dir" && bash "$LINT" >"$out" 2>"$err" )
  exit_code=$?
  set -e
  printf '%s|%s|%s\n' "$exit_code" "$out" "$err"
}

ok()   { PASS=$((PASS+1)); printf 'pass: %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'fail: %s: %s\n' "$1" "$2" >&2; }

# ─── A-1: triplet-output contract — stdout lines == 3 * hits, hint immediately
# follows path:line, see immediately follows hint. Catches: a refactor that
# emits the hint once at the end, or interleaves multi-hit output.
case_A1_triplet_adjacency() {
  local dir; dir="$(setup_git_fixture)"
  cat >"$dir/bad.sh" <<'SH'
#!/usr/bin/env bash
echo "${LINEAR_API_KEY:-leak1}"
echo "${ANTHROPIC_TOKEN:-leak2}"
echo "${GITHUB_SECRET:-leak3}"
SH
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code out err < <(run_lint_in "$dir")
  if [[ "$exit_code" != "1" ]]; then
    bad 'A-1' "expected exit 1, got $exit_code"; rm -f "$out" "$err"; cleanup_fixture "$dir"; return
  fi
  local total
  total=$(wc -l <"$out" | tr -d ' ')
  if (( total % 3 != 0 )); then
    bad 'A-1' "stdout line count ($total) is not a multiple of 3 — triplet contract broken"
    cat "$out" >&2
    rm -f "$out" "$err"; cleanup_fixture "$dir"; return
  fi
  # Walk the file and verify every "path:line:" line is followed by hint+see.
  local broke=0
  awk '
    BEGIN { state=0; bad=0 }
    /^[^ ]/    { if (state != 0) bad=1; state=1; next }
    /^  hint:/ { if (state != 1) bad=1; state=2; next }
    /^  see:/  { if (state != 2) bad=1; state=0; next }
                 { bad=1 }
    END        { if (state != 0) bad=1; exit bad }
  ' "$out" || broke=1
  if (( broke )); then
    bad 'A-1' "triplet sequence broken (path:line / hint / see not adjacent)"
    cat "$out" >&2
  else
    ok 'A-1'
  fi
  rm -f "$out" "$err"; cleanup_fixture "$dir"
}

# ─── A-2: dual-match line is reported once, not twice. The line
# `${LINEAR_API_KEY:-x}` matches BOTH the KTS regex (KEY) and the PROVIDER
# regex (LINEAR). The lint unions and `sort -u`s — so the same path:line
# must appear once. Catches: regression that drops the dedup.
case_A2_dual_match_dedup() {
  local dir; dir="$(setup_git_fixture)"
  cat >"$dir/bad.sh" <<'SH'
#!/usr/bin/env bash
echo "${LINEAR_API_KEY:-x}"
SH
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code out err < <(run_lint_in "$dir")
  if [[ "$exit_code" != "1" ]]; then
    bad 'A-2' "expected exit 1, got $exit_code"; rm -f "$out" "$err"; cleanup_fixture "$dir"; return
  fi
  local hit_lines
  hit_lines=$(grep -c '^bad.sh:2:' "$out" || true)
  if (( hit_lines != 1 )); then
    bad 'A-2' "expected exactly 1 'bad.sh:2:' line (sort -u dedup), got $hit_lines"
    cat "$out" >&2
  else
    ok 'A-2'
  fi
  rm -f "$out" "$err"; cleanup_fixture "$dir"
}

# ─── A-3: lowercase env-var names must NOT trigger. Catches: a future
# `git grep -i` that would flag innocuous lowercase locals like `key`.
case_A3_lowercase_env_no_match() {
  local dir; dir="$(setup_git_fixture)"
  cat >"$dir/safe.sh" <<'SH'
#!/usr/bin/env bash
key=foo
echo "${key:-default}"
echo "${linear_api_key:-default}"
echo "${Anthropic_Foo:-default}"
SH
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code _out err < <(run_lint_in "$dir")
  if [[ "$exit_code" == "0" ]]; then
    ok 'A-3'
  else
    bad 'A-3' "lowercase/mixed-case names triggered the lint (exit $exit_code) — regex was widened"
    cat "$err" >&2
  fi
  rm -f "$_out" "$err"; cleanup_fixture "$dir"
}

# ─── A-4: substring-position coverage — KEY/TOKEN/SECRET as infix, prefix,
# and as suffix all trigger. Variable names contain only [A-Z_] (the regex
# excludes digits by design — see brainstorm § E-2). Catches: regex
# tightened to anchored boundaries (`^KEY$` etc.).
case_A4_substring_positions() {
  local dir; dir="$(setup_git_fixture)"
  cat >"$dir/bad.sh" <<'SH'
#!/usr/bin/env bash
echo "${MY_SECRET_VALUE:-x}"
echo "${TOKEN_PREFIX:-x}"
echo "${API_KEYS:-x}"
SH
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code out err < <(run_lint_in "$dir")
  if [[ "$exit_code" != "1" ]]; then
    bad 'A-4' "expected exit 1, got $exit_code — substring-position regex coverage regressed"
    rm -f "$out" "$err"; cleanup_fixture "$dir"; return
  fi
  local missing=()
  grep -q '^bad.sh:2:'   "$out" || missing+=('MY_SECRET_VALUE (infix)')
  grep -q '^bad.sh:3:'   "$out" || missing+=('TOKEN_PREFIX (prefix)')
  grep -q '^bad.sh:4:'   "$out" || missing+=('API_KEYS (suffix)')
  if (( ${#missing[@]} > 0 )); then
    bad 'A-4' "missing hits: ${missing[*]}"
    cat "$out" >&2
  else
    ok 'A-4'
  fi
  rm -f "$out" "$err"; cleanup_fixture "$dir"
}

# ─── A-5: sibling parameter-expansion operators (`:=` assign, `:?` error,
# single-dash `-`, `+` without colon) must NOT trigger. Catches: regex
# widened from `:[\+\-]` to `:[^A-Z]` or similar.
case_A5_sibling_operators_no_match() {
  local dir; dir="$(setup_git_fixture)"
  cat >"$dir/safe.sh" <<'SH'
#!/usr/bin/env bash
: "${LINEAR_API_KEY:=test-mock-key}"
: "${LINEAR_API_KEY:?must be set}"
echo "${LINEAR_API_KEY-}"
echo "${LINEAR_API_KEY+SET}"
SH
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code out err < <(run_lint_in "$dir")
  if [[ "$exit_code" == "0" ]]; then
    ok 'A-5'
  else
    bad 'A-5' "sibling operators (:=, :?, -, +) tripped the lint (exit $exit_code) — regex over-widened"
    cat "$out" >&2
  fi
  rm -f "$out" "$err"; cleanup_fixture "$dir"
}

# ─── A-6: pathspec exclusion is exact-path, not glob-prefix. A bad pattern
# in `bin/foo/secret-probe-lint.sh` (deeper path, same basename) MUST be
# flagged. Catches: someone "loosening" the pathspec to match basename.
case_A6_pathspec_exact_not_basename() {
  local dir; dir="$(setup_git_fixture)"
  mkdir -p "$dir/bin/foo"
  cat >"$dir/bin/foo/secret-probe-lint.sh" <<'SH'
#!/usr/bin/env bash
echo "${LINEAR_API_KEY:-leak}"
SH
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code out err < <(run_lint_in "$dir")
  if [[ "$exit_code" == "1" ]] && grep -q '^bin/foo/secret-probe-lint.sh:2:' "$out"; then
    ok 'A-6'
  else
    bad 'A-6' "expected exit 1 with hit on bin/foo/secret-probe-lint.sh:2; got exit $exit_code, stdout: $(cat "$out")"
  fi
  rm -f "$out" "$err"; cleanup_fixture "$dir"
}

# ─── A-7: nested directory depth under docs/ and learned-rules/ is excluded
# (the pathspec uses `**`, not `*`). Catches: a regression that downgrades
# to a single-level glob.
case_A7_deep_nested_prose_excluded() {
  local dir; dir="$(setup_git_fixture)"
  mkdir -p "$dir/docs/a/b/c" "$dir/learned-rules/x/y/z"
  cat >"$dir/docs/a/b/c/foo.md" <<'MD'
Bad: `${LINEAR_API_KEY:-leak}`
MD
  cat >"$dir/learned-rules/x/y/z/bar.md" <<'MD'
Bad: `${ANTHROPIC_TOKEN:-leak}`
MD
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code _out err < <(run_lint_in "$dir")
  if [[ "$exit_code" == "0" ]]; then
    ok 'A-7'
  else
    bad 'A-7' "deep-nested prose under docs/** or learned-rules/** triggered the lint (exit $exit_code) — pathspec dropped ** recursion"
    cat "$err" >&2
  fi
  rm -f "$_out" "$err"; cleanup_fixture "$dir"
}

# ─── A-8: untracked files are NOT scanned by `git grep` (no --untracked).
# An operator scratch file with a bad pattern MUST be ignored. Catches: a
# regression that adds --untracked and surfaces noise from operator state.
case_A8_untracked_file_ignored() {
  local dir; dir="$(setup_git_fixture)"
  # Commit a clean file so the working tree isn't empty.
  cat >"$dir/safe.sh" <<'SH'
#!/usr/bin/env bash
echo safe
SH
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  # Drop a bad pattern in an UNTRACKED file.
  cat >"$dir/scratch.sh" <<'SH'
#!/usr/bin/env bash
echo "${LINEAR_API_KEY:-leak}"
SH
  IFS='|' read -r exit_code out err < <(run_lint_in "$dir")
  if [[ "$exit_code" == "0" ]]; then
    ok 'A-8'
  else
    bad 'A-8' "untracked scratch file flagged (exit $exit_code) — git grep --untracked drift?"
    cat "$out" >&2
  fi
  rm -f "$out" "$err"; cleanup_fixture "$dir"
}

# ─── A-9: precondition (git rev-parse) runs BEFORE the greps. Even if a
# bad pattern is reachable, invoking outside any git repo must exit 2 with
# the env-failure message — never 1. Reinforces case-8 (which only checks
# exit code) by also asserting the env-error message in stderr.
case_A9_precondition_before_grep() {
  local dir
  dir="$(mktemp -d)"
  case "$dir" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;;
    *) printf 'REFUSING: %q\n' "$dir" >&2; exit 99 ;;
  esac
  # Create a file with a bad pattern in the no-git dir.
  cat >"$dir/bad.sh" <<'SH'
echo "${LINEAR_API_KEY:-leak}"
SH
  local exit_code err
  err="$(mktemp)"
  set +e
  ( cd "$dir" && bash "$LINT" >/dev/null 2>"$err" )
  exit_code=$?
  set -e
  if [[ "$exit_code" == "2" ]] && grep -q 'lint requires a git checkout' "$err"; then
    ok 'A-9'
  else
    bad 'A-9' "expected exit 2 with env-failure message, got exit $exit_code (stderr: $(cat "$err"))"
  fi
  rm -f "$err"
  cleanup_fixture "$dir"
}

main() {
  if [[ ! -f "$LINT" ]]; then
    printf 'fail: lint script not found at %s\n' "$LINT" >&2
    exit 1
  fi
  case_A1_triplet_adjacency
  case_A2_dual_match_dedup
  case_A3_lowercase_env_no_match
  case_A4_substring_positions
  case_A5_sibling_operators_no_match
  case_A6_pathspec_exact_not_basename
  case_A7_deep_nested_prose_excluded
  case_A8_untracked_file_ignored
  case_A9_precondition_before_grep
  printf '\n'
  printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
  (( FAIL == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
