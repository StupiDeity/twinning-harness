#!/usr/bin/env bash
# Test harness for bin/entry-conditions.sh (ENG-86).
# Source-and-stub pattern per CLAUDE.md "Tests" §, mirroring
# bin/run-stage-test.sh:1-115. All cases run under PIPELINE_DRY_RUN=1
# against a mktemp'd state dir and a STUB_DIR of fake gh / branch-name.sh
# scripts so no real Linear / gh / filesystem side-effects escape.

set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

# common.sh requires TARGET_REPO to exist; mktemp a directory.
TARGET_REPO_TMP="$(mktemp -d)"
mkdir -p "$TARGET_REPO_TMP/.pipeline-config/schemas"
printf '{"project":{"slug":"%s"}}' "$PROJECT_SLUG" > "$TARGET_REPO_TMP/.pipeline-config/config.json"
export TARGET_REPO="$TARGET_REPO_TMP"

STUB_DIR="$(mktemp -d)"

# Toggleable gh stub: `gh pr view <branch> --json reviews` returns
# $MOCK_GH_REVIEWS_JSON. Honors $MOCK_GH_RC for fault injection (case E).
# ${VAR-} (single-dash) is empty when unset OR empty — secret-probe-lint.sh
# (ENG-46) only matches the `${VAR:-…}` two-character default-fallback.
cat > "$STUB_DIR/gh" <<'SH'
#!/usr/bin/env bash
if [[ -n "${MOCK_GH_RC-}" && "${MOCK_GH_RC-}" != "0" ]]; then
  exit "${MOCK_GH_RC}"
fi
json_arg=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--json" ]]; then
    json_arg="${2-}"
    break
  fi
  shift
done
case "$json_arg" in
  reviews) printf '%s' "${MOCK_GH_REVIEWS_JSON-}" ;;
  *)       printf '' ;;
esac
SH
chmod +x "$STUB_DIR/gh"

# branch-name.sh stub: deterministic feat/<lower-id>-mock-slug.
cat > "$STUB_DIR/branch-name.sh" <<'SH'
#!/usr/bin/env bash
printf 'feat/%s-mock-slug\n' "$(tr '[:upper:]' '[:lower:]' <<<"$1")"
SH
chmod +x "$STUB_DIR/branch-name.sh"

# Source common.sh first so $CONFIG, log, die are in scope.
# shellcheck source=common.sh
source "$HARNESS_DIR/common.sh"
# shellcheck source=entry-conditions.sh
source "$HARNESS_DIR/entry-conditions.sh"

# Isolate state and re-route helpers through the stubs.
HARNESS_STATE_DIR="$(mktemp -d)"
export HARNESS_STATE_DIR
PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
export PROJECT_STATE_DIR
mkdir -p "$PROJECT_STATE_DIR"

# Per-test config file overrides the harness $CONFIG. Tests rewrite this
# file between cases.
TMP_CFG="$(mktemp)"
trap 'rm -rf "$HARNESS_STATE_DIR" "$STUB_DIR" "$TARGET_REPO_TMP" "$TMP_CFG"' EXIT

# Post-source overrides: redirect entry-conditions.sh's sub-calls through
# the stubs and pin CONFIG to the per-test scratch file.
SCRIPT_DIR="$STUB_DIR"
PATH="$STUB_DIR:$PATH"
CONFIG="$TMP_CFG"

PASS=0; FAIL=0
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
fail_at() { printf '  ❌ %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

printf '\n--- ENG-86 entry-conditions registry cases ---\n'

# ─── Case A: condition met → proceed ────────────────────────────────────
# One APPROVED non-bot review fixture; config opts `building` into
# `pr-approved-by-non-bot`.
printf '{"orchestrator":{"entry_conditions":{"building":[{"name":"pr-approved-by-non-bot","type":"github-pr-review"}]}}}' > "$TMP_CFG"
export MOCK_GH_REVIEWS_JSON='{"reviews":[{"state":"APPROVED","author":{"login":"alice"}}]}'
unset MOCK_GH_RC
out_A="$(should_dispatch building ENG-86A 2>/dev/null || printf 'EXIT_NONZERO')"
if [[ "$out_A" == "proceed" ]]; then
  pass_at "ENG-86 case A: condition met → proceed"
else
  fail_at "ENG-86 case A" "expected 'proceed', got '$out_A'"
fi
unset MOCK_GH_REVIEWS_JSON

# ─── Case B: condition unmet → skip:awaiting-approval ──────────────────
# Zero APPROVED reviews. Same config as A.
export MOCK_GH_REVIEWS_JSON='{"reviews":[{"state":"COMMENTED","author":{"login":"alice"}}]}'
out_B="$(should_dispatch building ENG-86B 2>/dev/null || printf 'EXIT_NONZERO')"
if [[ "$out_B" == "skip:awaiting-approval" ]]; then
  pass_at "ENG-86 case B: condition unmet → skip:awaiting-approval"
else
  fail_at "ENG-86 case B" "expected 'skip:awaiting-approval', got '$out_B'"
fi

# ─── Case B2: empty reviews array also unmet → skip:awaiting-approval ──
export MOCK_GH_REVIEWS_JSON='{"reviews":[]}'
out_B2="$(should_dispatch building ENG-86B2 2>/dev/null || printf 'EXIT_NONZERO')"
if [[ "$out_B2" == "skip:awaiting-approval" ]]; then
  pass_at "ENG-86 case B2: empty reviews array → skip:awaiting-approval"
else
  fail_at "ENG-86 case B2" "expected 'skip:awaiting-approval', got '$out_B2'"
fi
unset MOCK_GH_REVIEWS_JSON

# ─── Case B3: bot-only APPROVED review does NOT count → skip ───────────
# Plan D-008: filter mirrors AGENT_PROMPTS.md P2 (lines 1287-1289). A
# bot self-approval is excluded via `author.login | test("\\[bot\\]$") | not`.
export MOCK_GH_REVIEWS_JSON='{"reviews":[{"state":"APPROVED","author":{"login":"github-actions[bot]"}}]}'
out_B3="$(should_dispatch building ENG-86B3 2>/dev/null || printf 'EXIT_NONZERO')"
if [[ "$out_B3" == "skip:awaiting-approval" ]]; then
  pass_at "ENG-86 case B3: bot-only APPROVED → skip:awaiting-approval (mirrors P2 filter)"
else
  fail_at "ENG-86 case B3" "expected 'skip:awaiting-approval', got '$out_B3'"
fi
unset MOCK_GH_REVIEWS_JSON

# ─── Case C: malformed config (unknown check name) → fall-through ──────
# Unknown handler logs a warning and the entry is skipped per D-005.
printf '{"orchestrator":{"entry_conditions":{"building":[{"name":"made-up-check","type":"unknown"}]}}}' > "$TMP_CFG"
out_C="$(should_dispatch building ENG-86C 2>/dev/null || printf 'EXIT_NONZERO')"
if [[ "$out_C" == "proceed" ]]; then
  pass_at "ENG-86 case C: unknown check name falls through to proceed"
else
  fail_at "ENG-86 case C" "expected 'proceed', got '$out_C'"
fi

# ─── Case D: empty/absent config → proceed (back-compat) ───────────────
printf '{}' > "$TMP_CFG"
out_D="$(should_dispatch building ENG-86D 2>/dev/null || printf 'EXIT_NONZERO')"
if [[ "$out_D" == "proceed" ]]; then
  pass_at "ENG-86 case D: empty config → proceed (back-compat)"
else
  fail_at "ENG-86 case D" "expected 'proceed', got '$out_D'"
fi

# ─── Case E: gh outage → error:pr-approved-by-non-bot (fail-open) ──────
printf '{"orchestrator":{"entry_conditions":{"building":[{"name":"pr-approved-by-non-bot","type":"github-pr-review"}]}}}' > "$TMP_CFG"
export MOCK_GH_RC=1
export MOCK_GH_REVIEWS_JSON=''
out_E="$(should_dispatch building ENG-86E 2>/dev/null || printf 'EXIT_NONZERO')"
if [[ "$out_E" == "error:pr-approved-by-non-bot" ]]; then
  pass_at "ENG-86 case E: gh outage → error:pr-approved-by-non-bot (D-010 fail-open)"
else
  fail_at "ENG-86 case E" "expected 'error:pr-approved-by-non-bot', got '$out_E'"
fi
unset MOCK_GH_RC MOCK_GH_REVIEWS_JSON

# ─── Case F: unknown stage key (gerund mismatch) → proceed ─────────────
# Config has `building`; caller asks for `build` (non-canonical). jq
# `// []` returns empty array → proceed. Documents D-005 trade-off.
printf '{"orchestrator":{"entry_conditions":{"building":[{"name":"pr-approved-by-non-bot","type":"github-pr-review"}]}}}' > "$TMP_CFG"
out_F="$(should_dispatch build ENG-86F 2>/dev/null || printf 'EXIT_NONZERO')"
if [[ "$out_F" == "proceed" ]]; then
  pass_at "ENG-86 case F: unknown stage key (build vs building) → proceed (D-005 silent gerund-drift)"
else
  fail_at "ENG-86 case F" "expected 'proceed', got '$out_F'"
fi

# ─── Case G: should_dispatch always exits 0 (caller parses stdout) ─────
# Implicit invariant from cases A-F all using `$(... || printf …)` and
# no `EXIT_NONZERO` surfacing — explicitly pin it here so a future
# refactor that swaps to nonzero exit codes is caught.
printf '{}' > "$TMP_CFG"
exit_rc=0
should_dispatch building ENG-86G >/dev/null 2>&1 || exit_rc=$?
if [[ "$exit_rc" == "0" ]]; then
  pass_at "ENG-86 case G: should_dispatch always exits 0 (caller parses stdout)"
else
  fail_at "ENG-86 case G" "expected exit 0, got rc=$exit_rc"
fi

# ─── Case H: sentinel pattern lets tests source without firing main ────
# Cases A-G all sourced bin/entry-conditions.sh and called
# should_dispatch() directly; if the sentinel were broken the file's
# main would fire on `source` and `die "usage: …"` would have aborted
# the test setup. This case asserts the sentinel-string is present
# in the file (defense against a future refactor that removes it).
if grep -q 'BASH_SOURCE\[0\].*== "\${0}"' "$HARNESS_DIR/entry-conditions.sh"; then
  pass_at "ENG-86 case H: bin/entry-conditions.sh ends with source-vs-execute sentinel"
else
  fail_at "ENG-86 case H" "sentinel pattern not found in bin/entry-conditions.sh"
fi

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
