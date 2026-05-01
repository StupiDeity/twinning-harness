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

# ─── ENG-50: §5 invariants ────────────────────────────────────────────
s5="$(section_body "## 5. Review Agent")"

if printf '%s\n' "$s5" | grep -qF 'Preflight (MANDATORY'; then
  ok "§5 contains 'Preflight (MANDATORY'"
else
  nope "§5 contains 'Preflight (MANDATORY'" "phrase missing"
fi

if printf '%s\n' "$s5" | grep -qF 'gh pr review --approve'; then
  nope "§5 lacks 'gh pr review --approve'" "phrase present"
else
  ok "§5 lacks 'gh pr review --approve'"
fi

if printf '%s\n' "$s5" | grep -qF 'gh pr review --request-changes'; then
  nope "§5 lacks 'gh pr review --request-changes'" "phrase present"
else
  ok "§5 lacks 'gh pr review --request-changes'"
fi

if printf '%s\n' "$s5" | grep -qF 'gh pr review --comment'; then
  ok "§5 contains 'gh pr review --comment'"
else
  nope "§5 contains 'gh pr review --comment'" "phrase missing"
fi

if printf '%s\n' "$s5" | grep -qF '<!-- pipeline-wait: awaiting-approval -->'; then
  ok "§5 contains '<!-- pipeline-wait: awaiting-approval -->'"
else
  nope "§5 contains '<!-- pipeline-wait: awaiting-approval -->'" "marker missing"
fi

# ─── ENG-53 #11(a): every stage prompt has the no-probe + halt-instead ──
# Pre-fix: agents routinely posted throwaway Linear comments (`test`,
# `test ping`) to probe what Bash patterns are allowlisted, plus
# sig-mutated retry comments when posts seemed to fail. Linear has no
# delete-comment mechanism, so the issue thread accumulated permanent
# litter (ENG-44's dogfood: `test`, `test ping`, plus 6+ trial sigs).
#
# (a) addresses the exploratory-probe pattern via prompt instruction:
# tell the agent that probing leaves permanent litter and the harness
# has a clean exit ramp (`<!-- pipeline-halt: agent-blocked -->`). The
# agent should halt instead of probing when uncertain.
#
# Pattern (b) — sig-mutated retries (`-trial`, `-v3`, ...) — is tracked
# separately in ENG-57.
#
# Test pins the new instruction in EVERY stage section (1-9) so future
# prompt edits can't silently drop it from one stage.
for stage_section in \
  "## 1. Brainstorm Agent" \
  "## 2. Plan Agent" \
  "## 3. Implementation Agent (Backend)" \
  "## 4. UI Agent (Frontend)" \
  "## 5. Review Agent" \
  "## 6. QA Agent" \
  "## 7. Build Agent" \
  "## 8. Release Agent" \
  "## 9. Retrospective Agent (Scheduled)"; do
  body="$(section_body "$stage_section")"
  short="${stage_section## }"

  if printf '%s\n' "$body" | grep -qF 'Tool allowlist & probing (ENG-53 #11)'; then
    ok "$short contains 'Tool allowlist & probing (ENG-53 #11)' header"
  else
    nope "$short contains 'Tool allowlist & probing (ENG-53 #11)' header" "phrase missing"
  fi

  if printf '%s\n' "$body" | grep -qF 'do not probe'; then
    ok "$short contains 'do not probe' rule"
  else
    nope "$short contains 'do not probe' rule" "phrase missing"
  fi

  if printf '%s\n' "$body" | grep -qF '<!-- pipeline-halt: agent-blocked -->'; then
    ok "$short contains 'pipeline-halt: agent-blocked' exit ramp"
  else
    nope "$short contains 'pipeline-halt: agent-blocked' exit ramp" "marker missing"
  fi
done

# ─── ENG-53 #3 + #4: doc-filename templates carry {issue_id_lower} ──────
# `partition_dirty_paths::D-004` requires `eng-N` (case-insensitive) in
# the basename to bucket as in-scope. The brainstorm and plan stage
# prompts must encode this in their filename templates, otherwise agents
# produce filenames that get leaked-in-scope on every run (observed on
# ENG-44's dogfood run — soft-fail counter +1, brainstorm doc dangled
# untracked until a downstream stage's sweep retroactively caught it).
#
# Guards against re-introducing `{date}-{slug}-design.md` (the original
# brainstorm template) or `{date}-{slug}.md` (the inconsistent plan
# template at line 424 pre-fix).
s1="$(section_body "## 1. Brainstorm Agent")"
s2="$(section_body "## 2. Plan Agent")"

# §1 — every `docs/brainstorms/{...}.md` template MUST include {issue_id_lower}.
b_templates="$(printf '%s\n' "$s1" | grep -oE 'docs/brainstorms/\{[^}]+\}[-{][^[:space:]]*\.md' || true)"
if [[ -z "$b_templates" ]]; then
  nope "§1 contains at least one docs/brainstorms/{…}.md template" \
       "no template found — file may have drifted away from the harness contract"
else
  bad_b=""
  while IFS= read -r tmpl; do
    [[ -z "$tmpl" ]] && continue
    [[ "$tmpl" == *"{issue_id_lower}"* ]] || bad_b+="$tmpl "
  done <<<"$b_templates"
  if [[ -z "$bad_b" ]]; then
    ok "§1 every docs/brainstorms/ template contains {issue_id_lower}"
  else
    nope "§1 every docs/brainstorms/ template contains {issue_id_lower}" \
         "missing in: $bad_b"
  fi
fi

# §2 — every `docs/plans/{...}.md` template MUST include {issue_id_lower}.
p_templates="$(printf '%s\n' "$s2" | grep -oE 'docs/plans/\{[^}]+\}[-{][^[:space:]]*\.md' || true)"
if [[ -z "$p_templates" ]]; then
  nope "§2 contains at least one docs/plans/{…}.md template" \
       "no template found — file may have drifted away from the harness contract"
else
  bad_p=""
  while IFS= read -r tmpl; do
    [[ -z "$tmpl" ]] && continue
    [[ "$tmpl" == *"{issue_id_lower}"* ]] || bad_p+="$tmpl "
  done <<<"$p_templates"
  if [[ -z "$bad_p" ]]; then
    ok "§2 every docs/plans/ template contains {issue_id_lower}"
  else
    nope "§2 every docs/plans/ template contains {issue_id_lower}" \
         "missing in: $bad_p"
  fi
fi

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
