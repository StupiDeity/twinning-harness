#!/usr/bin/env bash
# ENG-49: Invariants on AGENT_PROMPTS.md content.
#
# Asserts prompt-content rules that this PR introduces and that future
# edits must preserve. Reads AGENT_PROMPTS.md directly; no external stubs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMPTS="$HARNESS_ROOT/AGENT_PROMPTS.md"
[[ -f "$PROMPTS" ]] || { printf 'FATAL: not found: %s\n' "$PROMPTS" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  reason: %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# Helpers — extract a single H2 section's body (between its line and the next H2).
section_body() {
  local heading="$1"
  awk -v h="$heading" '
    BEGIN{in_section=0}
    /^## /{ if (in_section) exit; if (index($0, h)) {in_section=1; next} }
    in_section{print}
  ' "$PROMPTS"
}

s3="$(section_body "## 3. Implementation Agent (Backend)")"
s4="$(section_body "## 4. UI Agent (Frontend)")"
s8="$(section_body "## 8. Release Agent")"

# §3 — implement does not own PR creation.
if printf '%s\n' "$s3" | grep -q 'Do NOT create a PR'; then
  ok "§3 contains 'Do NOT create a PR'"
else
  nope "§3 contains 'Do NOT create a PR'" "phrase missing"
fi
if printf '%s\n' "$s3" | grep -qE 'gh pr create'; then
  nope "§3 lacks 'gh pr create'" "string 'gh pr create' present"
else
  ok "§3 lacks 'gh pr create'"
fi

if printf '%s\n' "$s4" | grep -qE 'gh pr create'; then
  nope "§4 lacks 'gh pr create'" "string 'gh pr create' present"
else
  ok "§4 lacks 'gh pr create'"
fi
if printf '%s\n' "$s4" | grep -qE '^[[:space:]]*PR creation'; then
  nope "§4 lacks 'PR creation' heading" "heading present"
else
  ok "§4 lacks 'PR creation' heading"
fi

# §4 pass-through clause is preserved verbatim (regression — must not tighten).
if printf '%s\n' "$s4" | grep -qF 'this stage is a pass-through: skip implementation, write a stage summary noting the no-op, post `<!-- pipeline-stage-summary: ui -->`, and exit'; then
  ok "§4 pass-through clause preserved"
else
  nope "§4 pass-through clause preserved" "phrase missing or altered"
fi

# §8 — positive companion: contains the new orchestrator attribution.
# This guards against silent false-pass if the §8 heading text drifts
# (an empty section_body would make every "lacks X" check trivially pass).
if printf '%s\n' "$s8" | grep -q 'verdict-handler::apply_transition'; then
  ok "§8 contains new orchestrator attribution (verdict-handler::apply_transition)"
else
  nope "§8 contains new orchestrator attribution" "phrase missing — has the §8 heading drifted, or has the wording reverted?"
fi

# §8 — no longer attributes state-swap to pipeline-release.yml.
if printf '%s\n' "$s8" | grep -qE 'pipeline-release\.yml sweep already swapped'; then
  nope "§8 lacks obsolete 'pipeline-release.yml sweep' phrase" "phrase still present"
else
  ok "§8 lacks obsolete 'pipeline-release.yml sweep' phrase"
fi

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
