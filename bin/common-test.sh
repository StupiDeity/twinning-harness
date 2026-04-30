#!/usr/bin/env bash
# ENG-44: bin/common.sh::is_orchestrator_paused — six-row test table.
#
# Coverage maps directly to ENG-44's Test table (rows 1-6). Row 2 also
# exists in bin/run-local-helpers-adversarial-test.sh:601-611
# (test_paused_override_honored, written for ENG-49). The overlap is
# intentional (see brainstorm D-002): self-contained module-level
# coverage beats cross-file scavenging for a future reader.
#
# Read priority under test (bin/common.sh:122-125 contract):
#   STATE_FILE (if present and key is non-null) > CONFIG > "false"

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Throwaway TARGET_REPO and PROJECT_SLUG — common.sh requires both at
# source time (bin/common.sh:11-12, :40-48).
_TEST_ROOT="$(mktemp -d -t twinning-eng44.XXXXXX)"
_assert_temp_path() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
    *) printf 'REFUSING: %q is not a platform temp dir\n' "$1" >&2; exit 99 ;;
  esac
}
_assert_temp_path "$_TEST_ROOT"
trap 'case "$_TEST_ROOT" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$_TEST_ROOT" ;; esac' EXIT

export TARGET_REPO="$_TEST_ROOT/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# common.sh sets `-e`; relax it so a failing row does not abort.
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

# Materialize per-row config.json + state.local.json under $_TEST_ROOT
# and emit "<cfg-path>\n<sf-path>\n" so callers can `read -r cfg sf`.
# cfg_paused: "true" | "false" | "absent" (omits the .orchestrator.paused key)
# sf_body:    "absent"            -> no state.local.json file at all
#             "{}"                -> empty object
#             "{orch:{}}"         -> {"orchestrator":{}}
#             other               -> written verbatim as state.local.json body
mkfixture() {
  local row_name="$1" cfg_paused="$2" sf_body="$3"
  local tdir; tdir="$(mktemp -d "$_TEST_ROOT/row-${row_name}-XXXXXX")"
  local cfg="$tdir/config.json" sf="$tdir/state.local.json"
  if [[ "$cfg_paused" == "absent" ]]; then
    printf '{}\n' > "$cfg"
  else
    jq -n --argjson p "$cfg_paused" '{orchestrator:{paused:$p}}' > "$cfg"
  fi
  case "$sf_body" in
    "absent")     ;;                              # no state.local.json file
    "{}")         printf '{}\n' > "$sf" ;;
    "{orch:{}}")  printf '{"orchestrator":{}}\n' > "$sf" ;;
    *)            printf '%s\n' "$sf_body" > "$sf" ;;
  esac
  printf '%s\n%s\n' "$cfg" "$sf"
}

# ─── ENG-44 six-row table (brainstorm §5) ────────────────────────────
# | # | STATE_FILE       | config.paused | Result  |
# | - | ---------------- | ------------- | ------- |
# | 1 | absent           | true          | true    |  fall to CONFIG (no override)
# | 2 | {paused:false}   | true          | false   |  state.local wins (regression direction)
# | 3 | {paused:true}    | false         | true    |  state.local wins (other direction)
# | 4 | {}               | true          | true    |  empty STATE_FILE falls through
# | 5 | {orchestrator:{}}| true          | true    |  partial STATE_FILE falls through
# | 6 | {}               | absent        | false   |  // "false" CONFIG default

row1_state_file_absent_falls_to_config_true() {
  local cfg sf got
  read -r cfg sf < <(mkfixture row1 true absent)
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "row1_state_file_absent_falls_to_config_true" "true" "$got"
}
row1_state_file_absent_falls_to_config_true

row2_state_file_overrides_config_to_false() {
  local cfg sf got
  read -r cfg sf < <(mkfixture row2 true '{"orchestrator":{"paused":false}}')
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "row2_state_file_overrides_config_to_false" "false" "$got"
}
row2_state_file_overrides_config_to_false

row3_state_file_overrides_config_to_true() {
  local cfg sf got
  read -r cfg sf < <(mkfixture row3 false '{"orchestrator":{"paused":true}}')
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "row3_state_file_overrides_config_to_true" "true" "$got"
}
row3_state_file_overrides_config_to_true

row4_state_file_empty_object_falls_to_config() {
  local cfg sf got
  read -r cfg sf < <(mkfixture row4 true '{}')
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "row4_state_file_empty_object_falls_to_config" "true" "$got"
}
row4_state_file_empty_object_falls_to_config

row5_state_file_orchestrator_empty_falls_to_config() {
  local cfg sf got
  read -r cfg sf < <(mkfixture row5 true '{orch:{}}')
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "row5_state_file_orchestrator_empty_falls_to_config" "true" "$got"
}
row5_state_file_orchestrator_empty_falls_to_config

row6_both_layers_absent_returns_false() {
  local cfg sf got
  read -r cfg sf < <(mkfixture row6 absent '{}')
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "row6_both_layers_absent_returns_false" "false" "$got"
}
row6_both_layers_absent_returns_false

printf '\ncommon-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
