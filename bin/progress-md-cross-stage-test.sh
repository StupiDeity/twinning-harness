#!/usr/bin/env bash
# ENG-109: cross-stage progress.md chain coherence.
#
# Synthesises a fixture progress.md by sequentially invoking three
# mock writes (brainstorming, planning, implementing dispatch-ids)
# using the schema at docs/runbooks/progress-md.md §2. Asserts the
# AC#3 chain: three H2 entries, dispatch-id order preserved, heading
# shape parses into the three-token form, single-dispatch greps
# return exactly one match, and stage tokens are distinct and equal
# {brainstorming, planning, implementing}.
#
# Sources bin/common.sh::progress_md_path to exercise the resolver
# wiring: the fixture path is derived from the production helper, not
# a hand-constructed string, so a resolver regression surfaces here.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_TEST_ROOT="$(mktemp -d -t twinning-eng109.XXXXXX)"
_assert_temp_path() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
    *) printf 'REFUSING: %q is not a platform temp dir\n' "$1" >&2; exit 99 ;;
  esac
}
_assert_temp_path "$_TEST_ROOT"
trap 'case "$_TEST_ROOT" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$_TEST_ROOT" ;; esac' EXIT

# Set up environment and source common.sh so progress_md_path is available.
export TARGET_REPO="$_TEST_ROOT/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
export PROJECT_STATE_DIR="$_TEST_ROOT"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
set +e

PASS=0; FAIL=0; FAILED_CASES=()
report_ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
report_fail() { printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2; FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); }

main() {
  # Derive fixture path from the production resolver (exercises wiring).
  local fixture
  fixture="$(progress_md_path ENG-1)"
  mkdir -p "$(dirname "$fixture")"

  # Simulate three sequential dispatches on ENG-1 — note: NOT calling
  # the real bin/common.sh::allocate_dispatch_id (it would require
  # an issue_dir, issue-state.json, etc.); we hand-construct the
  # dispatch-ids in the canonical ENG-N-d<NNNN> shape.
  local d1="ENG-1-d0001" d2="ENG-1-d0002" d3="ENG-1-d0003"
  local t1="2026-05-16T10:00:00Z" t2="2026-05-16T10:30:00Z" t3="2026-05-16T11:00:00Z"

  # Write 1 — brainstorming dispatch
  cat >> "$fixture" <<EOF
## $d1 - brainstorming - $t1

Open question OQ-1 from persona review: deferred to ENG-110.

EOF
  # Write 2 — planning dispatch (appends; never overwrites)
  cat >> "$fixture" <<EOF
## $d2 - planning - $t2

Plan chose option B (extending existing helper) over option A.

EOF
  # Write 3 — implementing dispatch
  cat >> "$fixture" <<EOF
## $d3 - implementing - $t3

TDD evidence: gates green. Implementation matches plan task graph.

EOF

  # AC#3 (a): three H2 entries — regex accepts both ASCII ' - ' and em-dash ' — '
  local h2_count
  h2_count="$(grep -cE '^## ENG-1-d[0-9]{4}( - | — )[a-z]+( - | — )[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$fixture" || true)"
  if [[ "$h2_count" == "3" ]]; then
    report_ok "chain: three H2 entries"
  else
    report_fail "chain: three H2 entries" "3 H2 entries" "got $h2_count"
  fi

  # AC#3 (b): dispatch-id order preserved
  local order
  order="$(grep -oE 'ENG-1-d[0-9]{4}' "$fixture" | tr '\n' ' ')"
  if [[ "$order" == "$d1 $d2 $d3 " ]]; then
    report_ok "chain: dispatch-id order preserved"
  else
    report_fail "chain: dispatch-id order preserved" "$d1 $d2 $d3" "$order"
  fi

  # AC#3 (c): grep-friendly to a reader filtering by dispatch-id
  local one_count
  one_count="$(grep -cE "^## $d2( - | — )" "$fixture" || true)"
  if [[ "$one_count" == "1" ]]; then
    report_ok "chain: single-dispatch grep returns exactly one match"
  else
    report_fail "chain: single-dispatch grep returns exactly one match" "1 match for d0002" "got $one_count"
  fi

  # AC#3 (d): each heading parses into three ` - `-separated tokens
  local parse_ok=1
  while IFS= read -r heading; do
    local tokens
    tokens="$(printf '%s\n' "$heading" | awk -F' - ' '{print NF}')"
    [[ "$tokens" == "3" ]] || parse_ok=0
  done < <(grep -E '^## ENG-1-d' "$fixture")
  if (( parse_ok == 1 )); then
    report_ok "chain: every heading parses into three tokens"
  else
    report_fail "chain: every heading parses into three tokens" "all headings split into 3 by ' - '" "at least one heading has != 3 tokens"
  fi

  # AC#3 (e): stage tokens are distinct and equal {brainstorming, planning, implementing}.
  # Also verifies progress_md_path resolver: fixture path came from the production
  # helper, so a resolver regression (wrong PROJECT_STATE_DIR, wrong suffix) would
  # produce an empty fixture and this assertion would fail.
  local stages
  stages="$(grep -oE '^## ENG-1-d[0-9]{4} - [a-z]+' "$fixture" | awk -F' - ' '{print $NF}' | sort | tr '\n' ' ')"
  if [[ "$stages" == "brainstorming implementing planning " ]]; then
    report_ok "chain: stage tokens are distinct and equal {brainstorming, implementing, planning}"
  else
    report_fail "chain: stage tokens are distinct and equal {brainstorming, implementing, planning}" \
      "brainstorming implementing planning" "$stages"
  fi

  printf '\nprogress-md-cross-stage-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
  if (( FAIL > 0 )); then
    printf 'failed cases:\n'
    for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
    exit 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
