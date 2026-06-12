#!/usr/bin/env bash
# Vocabulary-cleanliness gate. Fails when any legacy-shape pipeline marker
# (`<!-- pipeline-(stage-summary|rejection|halt|wait|decision|sig|metric|
# transition): ... -->`) appears as a write or load-bearing read in
# functional code, outside the documented dual-shape-read carve-outs.
#
# Why this test exists: ENG-60 Phase 3 verification was a markdown
# checkbox in the plan doc, not a CI gate. The internal writers (verdict-
# handler::apply_transition, poll auto-resume, linear::add_comment,
# guards::bump, run-stage fallbacks) kept emitting legacy shapes for weeks
# after the parser stopped recognizing them, because nothing automatically
# blocked the divergence. This test is that automatic block.
#
# When you intentionally need to keep a legacy-shape reference (e.g. a
# back-compat read for in-flight tickets, an anti-injection strip for both
# shapes, or the historical CLAUDE.md migration note), drop a sentinel
# substring within `CARVE_OUT_LOOKBACK` lines (default 6) above the matched
# line OR on the matched line itself. Recognized sentinels:
#   legacy | back-compat | in-flight | old-shape | both new and legacy | both shapes
# The window is deliberately tight (function-comment scope) so a stray
# "legacy" elsewhere in the file does not exempt an unrelated writer.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$SCRIPT_DIR/.."

PASS=0
FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s\n%s\n' "$1" "$2"; }

# ─── The closed list of legacy marker prefixes ───────────────────────
# Source-of-truth lives in docs/brainstorms/2026-05-02-pipeline-vocabulary-
# simplification-design.md §4.1. If a new legacy prefix is ever added (it
# shouldn't be), update this regex.
LEGACY_RE='<!-- pipeline-(stage-summary|rejection|rejection-target|halt|wait|decision|sig|metric|transition):'

# Files in scope: functional shell + agent prompts + project-instruction doc.
# Test fixtures (bin/*-test.sh) are exempt — they legitimately encode legacy
# shapes for back-compat read coverage.
SCAN_FILES=(
  "$HARNESS_ROOT"/bin/*.sh
  "$HARNESS_ROOT/AGENT_PROMPTS.md"
  "$HARNESS_ROOT/CLAUDE.md"
)

# Carve-out sentinels — substrings that, when present on the matched line
# OR within the look-back window above it, mark the reference as intentional.
CARVE_OUT_PATTERNS=(
  'legacy'
  'back-compat'
  'in-flight'
  'old-shape'
  'both new and legacy'
  'both shapes'
)
CARVE_OUT_LOOKBACK=10

# Returns 0 if any sentinel from CARVE_OUT_PATTERNS appears in the matched
# line OR in the preceding $CARVE_OUT_LOOKBACK lines. The look-back covers
# function-header comment blocks where the dual-shape rationale lives,
# without being so wide that an unrelated "legacy" 50 lines away exempts
# a writer.
_has_sentinel_nearby() {
  local file="$1" lineno="$2"
  local start=$(( lineno - CARVE_OUT_LOOKBACK ))
  (( start < 1 )) && start=1
  local window
  window="$(sed -n "${start},${lineno}p" "$file")"
  local pat
  for pat in "${CARVE_OUT_PATTERNS[@]}"; do
    [[ "$window" == *"$pat"* ]] && return 0
  done
  return 1
}

# ─── Case 1: no unexpected legacy markers in functional code ─────────
hits=""
for f in "${SCAN_FILES[@]}"; do
  case "$f" in *-test.sh) continue;; esac
  [[ -f "$f" ]] || continue

  while IFS=: read -r lineno content; do
    [[ -z "$lineno" ]] && continue
    if ! _has_sentinel_nearby "$f" "$lineno"; then
      hits+="${f#"$HARNESS_ROOT/"}:${lineno}:${content}"$'\n'
    fi
  done < <(grep -nE "$LEGACY_RE" "$f" 2>/dev/null)
done

if [[ -z "$hits" ]]; then
  pass_at "case-1: no unexpected legacy-shape markers in functional code"
else
  fail_at "case-1: legacy-shape markers found in functional code (use bin/pipeline.sh, or add a 'legacy'/'back-compat'/'in-flight'/'old-shape' sentinel comment if intentional)" \
    "$hits"
fi

# ─── Case 2: registry covers every legacy prefix ─────────────────────
# If someone deletes an entry from the closed registry, this surfaces it.
REG="$HARNESS_ROOT/bin/pipeline-events.json"
if [[ -f "$REG" ]]; then
  required_keys=(verdict_results halt_reasons wait_reasons fail_targets
                 pivot_targets pivot_reasons decision_actions decision_gates meta_kinds stages)
  missing=""
  for k in "${required_keys[@]}"; do
    if ! jq -e --arg k "$k" 'has($k)' "$REG" >/dev/null 2>&1; then
      missing+="  - $k"$'\n'
    fi
  done
  if [[ -z "$missing" ]]; then
    pass_at "case-2: bin/pipeline-events.json has every required registry key"
  else
    fail_at "case-2: bin/pipeline-events.json missing keys" "$missing"
  fi
else
  fail_at "case-2: bin/pipeline-events.json absent" "expected at $REG"
fi

# ─── Case 3: every meta_kinds entry is producible by the parser ──────
# parse_pipeline_marker emits {event:"meta", kind:"<k>", ...} for every
# `<!-- meta: <kind> ... -->`. Ensure each registered kind has a fixture
# that round-trips through the parser cleanly.
# shellcheck source=common.sh
TARGET_REPO="${TARGET_REPO:-$(mktemp -d)/target}"
mkdir -p "$TARGET_REPO/.pipeline-config"
[[ -f "$TARGET_REPO/.pipeline-config/config.json" ]] \
  || printf '{"linear":{},"orchestrator":{}}' > "$TARGET_REPO/.pipeline-config/config.json"
export TARGET_REPO PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
# shellcheck disable=SC1091
source "$HARNESS_ROOT/bin/common.sh"

case3_failed=0
while IFS= read -r kind; do
  body="<!-- meta: $kind sample=value -->"
  ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
  parsed_event="$(jq -r '.event // ""' <<<"$ev" 2>/dev/null || printf '')"
  parsed_kind="$(jq -r '.kind // ""' <<<"$ev" 2>/dev/null || printf '')"
  if [[ "$parsed_event" != "meta" || "$parsed_kind" != "$kind" ]]; then
    fail_at "case-3: meta kind=$kind does not round-trip through parse_pipeline_marker" \
      "  body=$body  parsed_event=$parsed_event  parsed_kind=$parsed_kind"
    case3_failed=1
  fi
done < <(jq -r '.meta_kinds[]' "$REG" 2>/dev/null)
(( case3_failed == 0 )) && pass_at "case-3: every meta_kinds entry round-trips through parse_pipeline_marker"

# ─── ENG-122: plan-contract-invalid in halt_reasons registry ──────────
# Verifies that the new halt reason token added by ENG-122 is present in
# the closed vocabulary so that `bash bin/pipeline.sh event ... verdict
# halt --reason plan-contract-invalid` passes registry validation.
if jq -e '.halt_reasons | index("plan-contract-invalid") != null' "$REG" >/dev/null 2>&1; then
  pass_at "ENG-122 case-4: plan-contract-invalid in halt_reasons registry"
else
  fail_at "ENG-122 case-4: plan-contract-invalid in halt_reasons registry" \
    "expected \"plan-contract-invalid\" in .halt_reasons array of $REG"
fi

# ─── ENG-113: qa-predicate-invalid in halt_reasons registry ─────────
# Verifies that the new halt reason token added by ENG-113 is present in
# the closed vocabulary so that `bash bin/pipeline.sh event ... verdict
# halt --reason qa-predicate-invalid` passes registry validation. Mirror
# of ENG-122 case-4 above. Reviewer iter-6 M3: previous closure was an
# inline jq assertion in Task 4 (implement-time only); the durable pin
# guards against silent regression.
if jq -e '.halt_reasons | index("qa-predicate-invalid") != null' "$REG" >/dev/null 2>&1; then
  pass_at "ENG-113 case-4b: qa-predicate-invalid in halt_reasons registry"
else
  fail_at "ENG-113 case-4b: qa-predicate-invalid in halt_reasons registry" \
    "expected \"qa-predicate-invalid\" in .halt_reasons array of $REG"
fi

# ─── ENG-115: plan-structural-defect in pivot_reasons registry ──────
# Verifies that the new pivot reason token added by ENG-115 is present
# in the closed vocabulary so that `bash bin/pipeline.sh event ... verdict
# pivot --reason plan-structural-defect` passes registry validation.
if jq -e '.pivot_reasons | index("plan-structural-defect") != null' "$REG" >/dev/null 2>&1; then
  pass_at "case-5: plan-structural-defect in pivot_reasons registry"
else
  fail_at "case-5: plan-structural-defect in pivot_reasons registry" \
    "expected \"plan-structural-defect\" in .pivot_reasons array of $REG"
fi

# ─── Summary ─────────────────────────────────────────────────────────
printf '\nvocabulary-cleanliness-test: passed=%s failed=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
