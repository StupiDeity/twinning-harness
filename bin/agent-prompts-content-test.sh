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
# Note: `## ` headings inside a column-0 fenced block do NOT end the section —
# the awk tracks in_fence to skip those (fixes §2 whose Completion checklist
# is a column-0 ## heading inside the opening ``` block).
section_body() {
  local heading="$1"
  awk -v h="$heading" '
    BEGIN{in_section=0; in_fence=0}
    /^```/{if (in_section) in_fence = !in_fence}
    /^## /{ if (in_section && !in_fence) exit; if (!in_section && index($0, h)) {in_section=1; next} }
    in_section{print}
  ' "$PROMPTS"
}

s2="$(section_body "## 2. Plan Agent")"
s3="$(section_body "## 3. Implementation Agent (Backend)")"
s4="$(section_body "## 4. UI Agent (Frontend)")"
s7="$(section_body "## 7. Build Agent")"
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
# Updated in ENG-60-T2.11: old-shape marker replaced with pipeline.sh event invocation.
if printf '%s\n' "$s4" | grep -qF "this stage is a pass-through: skip implementation, write a stage summary noting the no-op, run \`bash bin/pipeline.sh event {issue_id} verdict pass --stage ui\`, and exit"; then
  ok "§4 pass-through clause preserved (new-shape verdict)"
else
  nope "§4 pass-through clause preserved (new-shape verdict)" "phrase missing or altered"
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

# ─── ENG-52: §2 has BOTH a Tauri AND a non-Tauri api-contract example ───
if printf '%s\n' "$s2" | grep -qF '#[tauri::command]'; then
  ok "§2 preserves Tauri api-contract example (#[tauri::command])"
else
  nope "§2 preserves Tauri api-contract example (#[tauri::command])" "phrase missing"
fi
if printf '%s\n' "$s2" | grep -qF '@app.route'; then
  ok "§2 contains non-Tauri (Python/Flask) api-contract example (@app.route)"
else
  nope "§2 contains non-Tauri (Python/Flask) api-contract example (@app.route)" "phrase missing"
fi

# ─── ENG-52: §7 release.yml check is profile-conditional ────────────────
if printf '%s\n' "$s7" | grep -qF 'gh run list --branch main --workflow' \
   && printf '%s\n' "$s7" | grep -qiF 'if the project profile names a release CI workflow'; then
  ok "§7 release.yml check is profile-conditional"
else
  nope "§7 release.yml check is profile-conditional" \
       "either 'gh run list --branch main --workflow' missing OR 'if the project profile names a release CI workflow' missing"
fi

# ─── ENG-52: §8 attributes inputs to bin/run-release-observer.sh ────────
if printf '%s\n' "$s8" | grep -qF 'bin/run-release-observer.sh' \
   && printf '%s\n' "$s8" | grep -qF 'PIPELINE_RELEASE_VERSION' \
   && ! printf '%s\n' "$s8" | grep -qE 'Inputs supplied by[[:space:]]+`pipeline-release\.yml`'; then
  ok "§8 attributes inputs to bin/run-release-observer.sh (env vars)"
else
  nope "§8 attributes inputs to bin/run-release-observer.sh (env vars)" \
       "either 'bin/run-release-observer.sh' missing OR 'PIPELINE_RELEASE_VERSION' missing OR obsolete 'Inputs supplied by \`pipeline-release.yml\`' phrase still present"
fi

# ─── ENG-52 QA adversarial: §7 reordered config-scan list locks the new
# multi-stack examples (pyproject.toml, go.mod). The plan-locked
# assertion above only locks the profile-conditional release.yml prose;
# nothing locks the list-extension itself. A future retrospective edit
# could revert §7 to the Tauri-only list (`tauri.conf.json,
# next.config.js, Caddyfile, nginx.conf`) and the existing assertions
# would all still pass.
if printf '%s\n' "$s7" | grep -qF 'pyproject.toml' \
   && printf '%s\n' "$s7" | grep -qF 'go.mod'; then
  ok "§7 config-scan list contains non-Tauri examples (pyproject.toml, go.mod)"
else
  nope "§7 config-scan list contains non-Tauri examples (pyproject.toml, go.mod)" \
       "either 'pyproject.toml' missing OR 'go.mod' missing from §7's body"
fi

# ─── ENG-52 QA adversarial: §8 cites ALL THREE PIPELINE_RELEASE_* env-var
# names. The plan-locked assertion above only checks PIPELINE_RELEASE_VERSION;
# review-stage flagged this gap as minor. A future edit could drop _TAG /
# _PREV_TAG (or rename one) and the existing assertion would still pass.
if printf '%s\n' "$s8" | grep -qF 'PIPELINE_RELEASE_TAG' \
   && printf '%s\n' "$s8" | grep -qF 'PIPELINE_RELEASE_PREV_TAG'; then
  ok "§8 cites PIPELINE_RELEASE_TAG and PIPELINE_RELEASE_PREV_TAG env-var names"
else
  nope "§8 cites PIPELINE_RELEASE_TAG and PIPELINE_RELEASE_PREV_TAG env-var names" \
       "either 'PIPELINE_RELEASE_TAG' missing OR 'PIPELINE_RELEASE_PREV_TAG' missing — env-var attribution incomplete"
fi

# ─── ENG-52 QA adversarial: §2 column-0 fence count is exactly 2.
# render-prompt-test.sh is the authoritative cross-section check; this
# assertion is a localized backstop scoped to §2's section body, since
# the §2 Python/Flask example sits inside an indented fence pair (lines
# 390/425) and a future edit could trivially flip the indentation,
# raising the column-0 count to 4 and crashing render-prompt.sh.
fence_count_s2="$(printf '%s\n' "$s2" | grep -c '^```' || true)"
if [[ "$fence_count_s2" == "2" ]]; then
  ok "§2 column-0 fence count is exactly 2 (api-contract example stays indented)"
else
  nope "§2 column-0 fence count is exactly 2 (api-contract example stays indented)" \
       "got $fence_count_s2 column-0 fences in §2 body — render-prompt.sh::extract_block requires exactly 2"
fi

# ─── ENG-50 / ENG-54: §5 invariants ───────────────────────────────────
s5="$(section_body "## 5. Review Agent")"

# ENG-54: review never approves/request-changes via GitHub's API (humans do
# at build's P2). Only the COMMENTED-state path is permitted here.
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

# ENG-54: the review-stage human-approval gate is gone. §5 must NOT emit
# `<!-- pipeline-wait: awaiting-approval -->` — that gate moved to build's
# P2. The only stage that emits wait shapes now is build (§7).
if printf '%s\n' "$s5" | grep -qF '<!-- pipeline-wait: awaiting-approval -->'; then
  nope "§5 ENG-54: lacks '<!-- pipeline-wait: awaiting-approval -->' marker" \
       "marker still emitted from §5 — gate must be at build's P2 only"
else
  ok "§5 ENG-54: '<!-- pipeline-wait: awaiting-approval -->' marker absent"
fi

# ENG-54: the per-stage no-probe paragraph still mentions the marker as a
# *negative* example ("Do NOT emit ... here") which is fine — that paragraph
# is universal across all 9 stages and shared with build, where the marker
# IS emitted. Pin only that the agent's verdict-marker / decision-path
# instructions don't include it.
if printf '%s\n' "$s5" | grep -qF 'pipeline-wait' | grep -vqF 'Do NOT emit'; then
  : # any remaining occurrences should be in negative contexts; not asserting strictly here
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

  if printf '%s\n' "$body" | grep -qE 'Tool allowlist & probing \(ENG-53 #11'; then
    ok "$short contains 'Tool allowlist & probing (ENG-53 #11…)' header"
  else
    nope "$short contains 'Tool allowlist & probing (ENG-53 #11…)' header" "phrase missing"
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

# ─── ENG-56: pipeline:halted is orchestrator-managed ────────────────────
# The label is applied by run-stage.sh's post-dispatch hook (skipping
# wait-shape exits). Agents must NEVER call add-label pipeline:halted —
# dual authority routinely drifts (8/8 dispatches in ENG-44 had the
# orchestrator filling in for non-compliant agents) and the post-dispatch
# hook silently overrides ENG-45 wait-exit semantics if the label is
# already there. Test pins the absence of the agent-side add-label call
# in every stage section.
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

  # The instructional pattern is `bash ... add-label <issue> pipeline:halted`.
  # The descriptive footer "The orchestrator applies `pipeline:halted` ..."
  # is allowed; only the agent-side command form is forbidden.
  if printf '%s\n' "$body" | grep -qE 'add-label.*pipeline:halted'; then
    nope "$short lacks 'add-label … pipeline:halted' instruction (ENG-56)" \
         "agent-side command still present"
  else
    ok "$short lacks 'add-label … pipeline:halted' instruction (ENG-56)"
  fi
done

# ─── ENG-57: same-sig retry rule (no -v2 / -trial / -retry mutations) ──
# ENG-44's dogfood produced 6 duplicate Linear comments on a single ticket
# (`completion/reviewing/ENG-44-trial`, `…-v3`, `…-v9`, `…-v12`, `…-v13`)
# because the agent retried `add-or-update-comment` with mutated sigs every
# time a post appeared to fail. `add-or-update-comment` is idempotent —
# same sig + new body overwrites in place. The fix is a prompt
# instruction, replicated across all 9 stages via the universal Tool
# allowlist & probing paragraph (extended in ENG-57 to cover this case).
#
# Pin the rule per-stage so a future prompt edit can't silently drop it
# from one stage.
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

  if printf '%s\n' "$body" | grep -qF 'retry with the same sig'; then
    ok "$short contains 'retry with the same sig' rule (ENG-57)"
  else
    nope "$short contains 'retry with the same sig' rule (ENG-57)" "phrase missing"
  fi

  # Negative: stage body must not encourage sig variants. The forbidden
  # substrings appear ONLY in the prompt's own warning ("variants like
  # `-v2`, `-v3`, …"); we assert that they appear inside backticks and
  # within the same paragraph as the warning, by checking that any
  # occurrence is anchored to the warning phrase.
  if printf '%s\n' "$body" | grep -qE '\-(v[0-9]+|trial|retry)' \
     && ! printf '%s\n' "$body" | grep -qF 'never mutate it'; then
    nope "$short forbids mutated-sig variants (ENG-57)" \
         "stage body mentions sig variants but lacks the 'never mutate it' warning"
  else
    ok "$short forbids mutated-sig variants (ENG-57)"
  fi
done

# ─── ENG-55: stdin heredoc pattern for multi-line bodies ────────────────
# Pre-fix, agents wrote scratch `.md` files at the worktree root to feed
# `--body-file <path>` (and then couldn't `rm` them — no stage allow-lists
# `Bash(rm:*)`). ENG-44's dogfood accumulated 15 such dotfiles. ENG-55 added
# stdin support to bin/linear.sh's add-comment / add-or-update-comment via
# `--body -`, and the prompts must now point agents at the heredoc pattern.
#
# Each verdict-marker stage (1-7) needs at least one `--body -` heredoc
# example. Stages that don't post Linear comments at all (8 release / 9
# retrospective) are exempt.
for stage_section in \
  "## 1. Brainstorm Agent" \
  "## 2. Plan Agent" \
  "## 3. Implementation Agent (Backend)" \
  "## 4. UI Agent (Frontend)" \
  "## 5. Review Agent" \
  "## 6. QA Agent" \
  "## 7. Build Agent"; do
  body="$(section_body "$stage_section")"
  short="${stage_section## }"

  if printf '%s\n' "$body" | grep -qF -- '--body -'; then
    ok "$short contains '--body -' stdin example (ENG-55)"
  else
    nope "$short contains '--body -' stdin example (ENG-55)" "no stdin example found"
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
