#!/usr/bin/env bash
# Unit tests for bin/secret-probe-lint.sh (ENG-46).
#
# Cases 1-8 are fixture cases per plan Task 2 / Failure Mode → Test Map: each
# builds a temp `git init`'d repo, drops the relevant fixtures, invokes the
# lint, and asserts exit code + (for hit cases) stderr content.
# Cases 9-10 are review-loopback regressions (P0 #1: per-stage inline rule;
# P0 #2: dry-run smoke wiring) — they read the live harness's AGENT_PROMPTS.md
# and bin/dry-run.sh rather than building fixtures.
#
# Note: the lint itself deliberately does NOT source common.sh (D-007). This
# test DOES source common.sh — the test still runs in the harness env.

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

# Each test gets its own temp git repo so fixtures are isolated.
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

# Run the lint inside a fixture dir; capture exit, stdout, stderr separately.
# Echoes "<exit>|<stdout-file>|<stderr-file>" — caller is responsible for rm.
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

# ─── case 1: clean fixture (only safe ${VAR-} forms) → exit 0 ─────────
case_1_clean_safe_form() {
  local dir; dir="$(setup_git_fixture)"
  cat >"$dir/safe.sh" <<'SH'
#!/usr/bin/env bash
[[ -n "${LINEAR_API_KEY-}" ]] && echo SET || echo UNSET
SH
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code _out err < <(run_lint_in "$dir")
  [[ "$exit_code" == "0" ]] && ok 'case-1' || bad 'case-1' "expected exit 0, got $exit_code (stderr: $(cat "$err"))"
  cleanup_fixture "$dir"
}

# ─── case 2: ENG-45 surfacing bug shape ${LINEAR_API_KEY:-leak} → exit 1 ─
case_2_linear_api_key_minus_form() {
  local dir; dir="$(setup_git_fixture)"
  cat >"$dir/bad.sh" <<'SH'
#!/usr/bin/env bash
echo "key=${LINEAR_API_KEY:-leak}"
SH
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code out err < <(run_lint_in "$dir")
  if [[ "$exit_code" != "1" ]]; then
    bad 'case-2' "expected exit 1, got $exit_code"
    cleanup_fixture "$dir"; return
  fi
  if ! grep -q 'bad.sh:2' "$out" "$err" 2>/dev/null; then
    bad 'case-2' "stderr/stdout missing path:line"; cleanup_fixture "$dir"; return
  fi
  if ! grep -q 'use \${VAR-}' "$out" "$err" 2>/dev/null; then
    bad 'case-2' "missing remediation hint"; cleanup_fixture "$dir"; return
  fi
  if ! grep -q 'AGENT_PROMPTS.md "Secret-handling preamble (ENG-46)"' "$out" "$err" 2>/dev/null; then
    bad 'case-2' "missing preamble pointer"; cleanup_fixture "$dir"; return
  fi
  ok 'case-2'
  cleanup_fixture "$dir"
}

# ─── case 3: provider-prefix shape ${ANTHROPIC_FOO:-x} → exit 1 ───────
case_3_provider_prefix_minus_form() {
  local dir; dir="$(setup_git_fixture)"
  cat >"$dir/bad.sh" <<'SH'
#!/usr/bin/env bash
echo "${ANTHROPIC_FOO:-x}"
SH
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code _out _err < <(run_lint_in "$dir")
  [[ "$exit_code" == "1" ]] && ok 'case-3' || bad 'case-3' "expected exit 1, got $exit_code"
  cleanup_fixture "$dir"
}

# ─── case 4: ":+" sibling shape ${KEY:+--auth=$KEY} → exit 1 ──────────
case_4_plus_sibling_form() {
  local dir; dir="$(setup_git_fixture)"
  cat >"$dir/bad.sh" <<'SH'
#!/usr/bin/env bash
curl ${KEY:+--auth=$KEY} https://example.com
SH
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code _out _err < <(run_lint_in "$dir")
  [[ "$exit_code" == "1" ]] && ok 'case-4' || bad 'case-4' "expected exit 1, got $exit_code"
  cleanup_fixture "$dir"
}

# ─── case 5: empty-fallback ${LINEAR_API_KEY:-} → exit 1 (literal AC1) ─
case_5_empty_fallback_form() {
  local dir; dir="$(setup_git_fixture)"
  cat >"$dir/bad.sh" <<'SH'
#!/usr/bin/env bash
[[ -z "${LINEAR_API_KEY:-}" ]] && echo UNSET
SH
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code _out _err < <(run_lint_in "$dir")
  [[ "$exit_code" == "1" ]] && ok 'case-5' || bad 'case-5' "expected exit 1, got $exit_code"
  cleanup_fixture "$dir"
}

# ─── case 6: lint self-reference (regex string in lint file path) → 0 ─
case_6_lint_self_exclusion() {
  local dir; dir="$(setup_git_fixture)"
  mkdir -p "$dir/bin"
  # Place the bad pattern inside a file at the lint's own path → must be
  # excluded by the pathspec ':!bin/secret-probe-lint.sh'.
  cat >"$dir/bin/secret-probe-lint.sh" <<'SH'
# regex string for self-reference: ${LINEAR_API_KEY:-leak}
SH
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code _out _err < <(run_lint_in "$dir")
  [[ "$exit_code" == "0" ]] && ok 'case-6' || bad 'case-6' "expected exit 0, got $exit_code"
  cleanup_fixture "$dir"
}

# ─── case 7: docs/**, learned-rules/**, AGENT_PROMPTS.md prose excluded → 0 ─
case_7_prose_dirs_excluded() {
  local dir; dir="$(setup_git_fixture)"
  mkdir -p "$dir/docs/brainstorms" "$dir/learned-rules/twinning"
  cat >"$dir/docs/brainstorms/foo.md" <<'MD'
Example of the bad pattern: `${LINEAR_API_KEY:-leak}`.
MD
  cat >"$dir/learned-rules/twinning/foo.md" <<'MD'
Do not write `${ANTHROPIC_KEY:-FALLBACK}`.
MD
  # AGENT_PROMPTS.md is the preamble file — itself prose, with literal
  # bad-pattern examples in the "Secret-handling preamble (ENG-46)" section.
  cat >"$dir/AGENT_PROMPTS.md" <<'MD'
The preamble explains both halves: `${KEY:-UNSET}` and `${KEY:+SET}`.
MD
  ( cd "$dir" && git add -A && git commit -q -m fixture )
  IFS='|' read -r exit_code _out _err < <(run_lint_in "$dir")
  [[ "$exit_code" == "0" ]] && ok 'case-7' || bad 'case-7' "expected exit 0, got $exit_code"
  cleanup_fixture "$dir"
}

# ─── case 8: invoked outside a git checkout → exit 2, distinct from 1 ─
case_8_no_git_repo() {
  local dir
  dir="$(mktemp -d)"
  case "$dir" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;;
    *) printf 'REFUSING: %q\n' "$dir" >&2; exit 99 ;;
  esac
  local exit_code err
  err="$(mktemp)"
  set +e
  ( cd "$dir" && bash "$LINT" >/dev/null 2>"$err" )
  exit_code=$?
  set -e
  if [[ "$exit_code" != "2" ]]; then
    bad 'case-8' "expected exit 2, got $exit_code"
  elif ! grep -q 'lint requires a git checkout' "$err"; then
    bad 'case-8' "missing 'lint requires a git checkout' on stderr"
  else
    ok 'case-8'
  fi
  rm -f "$err"
  cleanup_fixture "$dir"
}

# ─── case 9: every dispatched agent receives the secret-handling rule ────
# Original review-loopback P0 #1: the file-level "## Secret-handling preamble
# (ENG-46)" section was invisible to dispatched agents because
# `bin/render-prompt.sh::extract_block` only emitted content inside
# `## N. <Stage> Agent` fenced blocks. The fix at the time was to inline the
# rule in every stage. After the AGENT_PROMPTS.md consolidation, the rule
# lives in `## 0. Common rules (delivered to every stage)` and
# `bin/render-prompt.sh::main` prepends §0's fenced block to every per-stage
# block — so each stage's rendered prompt still carries the rule, just from
# a single source. This test asserts both layers of the post-consolidation
# contract: (a) §0's fenced block carries the rule, (b) render-prompt.sh
# prepends §0, so what the agent actually sees has the rule.
case_9_per_stage_secret_rule_inlined() {
  local prompts="$SCRIPT_DIR_REAL/../AGENT_PROMPTS.md"
  local render="$SCRIPT_DIR_REAL/../bin/render-prompt.sh"
  if [[ ! -f "$prompts" ]]; then
    bad 'case-9' "AGENT_PROMPTS.md not found at $prompts"
    return
  fi
  if [[ ! -f "$render" ]]; then
    bad 'case-9' "bin/render-prompt.sh not found at $render"
    return
  fi

  # (a) §0 fenced block carries the rule.
  local s0_body
  s0_body="$(awk '
    /^## 0\. / { in_section=1; next }
    /^## [0-9]+\. / && in_section { exit }
    in_section && /^```/ { fence_count++; if (fence_count == 1) { in_block=1; next } if (fence_count == 2) { exit } }
    in_section && in_block { print }
  ' "$prompts")"
  if ! grep -qE 'Secret-handling \(ENG-46\)' <<<"$s0_body"; then
    bad 'case-9' "§0 (Common rules) fenced block missing 'Secret-handling (ENG-46)' rule — single source of truth is broken"
    return
  fi

  # (b) render-prompt.sh prepends §0's block in main() before per-stage
  # rendering. Without this, agents only see their per-stage block and the
  # rule never reaches them.
  if ! grep -qE 'extract_block "\$COMMON_SECTION"' "$render"; then
    bad 'case-9' "bin/render-prompt.sh::main does not extract \$COMMON_SECTION (§0) — agents won't see the rule from §0"
    return
  fi
  if ! grep -qE 'common_block.*\$.*block|block=.*common_block' "$render"; then
    bad 'case-9' "bin/render-prompt.sh::main extracts §0 but does not prepend it to the per-stage block — agents won't see the rule"
    return
  fi

  ok 'case-9'
}

# ─── case 10: bin/dry-run.sh wires bin/secret-probe-lint.sh ───────────────
# Review-loopback P0 #2 — the plan's Failure Mode → Test Map row "Lint missing
# from dry-run smoke (regression after merge)" had no executable assertion. This
# case grep-asserts the wiring; a future refactor that drops the `check` line
# from bin/dry-run.sh will fail this case.
case_10_dry_run_wires_lint() {
  local dry="$SCRIPT_DIR_REAL/../bin/dry-run.sh"
  if [[ ! -f "$dry" ]]; then
    bad 'case-10' "bin/dry-run.sh not found at $dry"
    return
  fi
  if grep -qE 'secret-probe-lint\.sh' "$dry"; then
    ok 'case-10'
  else
    bad 'case-10' "bin/dry-run.sh does not invoke bin/secret-probe-lint.sh — failure mode 'Lint missing from dry-run smoke' would not be caught by smoke run"
  fi
}

# ─── case 11: bin/dry-run.sh uses canonical stage names ────────────────
# Setup smoke must exercise the same canonical gerund-form stages consumed
# by render-prompt.sh, dispatch.sh, reconcile.sh, and run-stage.sh. Legacy
# short names (`brainstorm`, `plan`, `implement`, `review`, `build`,
# `release`) make setup fail even when the pipeline code is healthy.
case_11_dry_run_uses_canonical_stages() {
  local dry="$SCRIPT_DIR_REAL/../bin/dry-run.sh"
  if [[ ! -f "$dry" ]]; then
    bad 'case-11' "bin/dry-run.sh not found at $dry"
    return
  fi
  if grep -Eq '(for stage in brainstorm plan implement ui review qa build release retrospective|dispatch\.sh brainstorm([[:space:]]|$)|reconcile\.sh .* brainstorm([[:space:]]|$)|run-stage\.sh .* brainstorm([[:space:]]|$))' "$dry"; then
    bad 'case-11' "bin/dry-run.sh still invokes stage-aware checks with legacy short stage names"
    return
  fi
  if grep -qF 'for stage in brainstorming planning implementing ui reviewing qa building released retrospective' "$dry"; then
    ok 'case-11'
  else
    bad 'case-11' "bin/dry-run.sh does not enumerate canonical gerund-form stages"
  fi
}

# ─── case 12: stage-less run-stage probe skips paused issues ───────────
# The online setup smoke chooses a real Linear issue. A probe can be
# stage-less AND `pipeline:paused`; run-stage.sh then correctly refuses it
# at the pause precondition before the missing-stage guard. The smoke check
# must skip that issue instead of reporting a false failure.
case_12_dry_run_skips_paused_precondition_probe() {
  local dry="$SCRIPT_DIR_REAL/../bin/dry-run.sh"
  if [[ ! -f "$dry" ]]; then
    bad 'case-12' "bin/dry-run.sh not found at $dry"
    return
  fi
  if grep -qF 'pipeline:paused; skipping precondition probe' "$dry"; then
    ok 'case-12'
  else
    bad 'case-12' "bin/dry-run.sh does not skip run-stage precondition probe when the stage-less issue is pipeline:paused"
  fi
}

main() {
  if [[ ! -f "$LINT" ]]; then
    printf 'fail: lint script not found at %s\n' "$LINT" >&2
    exit 1
  fi
  case_1_clean_safe_form
  case_2_linear_api_key_minus_form
  case_3_provider_prefix_minus_form
  case_4_plus_sibling_form
  case_5_empty_fallback_form
  case_6_lint_self_exclusion
  case_7_prose_dirs_excluded
  case_8_no_git_repo
  case_9_per_stage_secret_rule_inlined
  case_10_dry_run_wires_lint
  case_11_dry_run_uses_canonical_stages
  case_12_dry_run_skips_paused_precondition_probe
  printf '\n'
  printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
  (( FAIL == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
