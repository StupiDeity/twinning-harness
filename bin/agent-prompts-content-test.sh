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
# `<!-- pipeline: verdict result=wait reason=awaiting-approval -->` — that gate moved to build's
# P2. The only stage that emits wait shapes now is build (§7).
if printf '%s\n' "$s5" | grep -qF '<!-- pipeline: verdict result=wait reason=awaiting-approval -->'; then
  nope "§5 ENG-54: lacks '<!-- pipeline: verdict result=wait reason=awaiting-approval -->' marker" \
       "marker still emitted from §5 — gate must be at build's P2 only"
else
  ok "§5 ENG-54: '<!-- pipeline: verdict result=wait reason=awaiting-approval -->' marker absent"
fi

# ENG-54: the per-stage no-probe paragraph still mentions the marker as a
# *negative* example ("Do NOT emit ... here") which is fine — that paragraph
# is universal across all 9 stages and shared with build, where the marker
# IS emitted. Pin only that the agent's verdict-marker / decision-path
# instructions don't include it.
if printf '%s\n' "$s5" | grep -qF 'pipeline-wait' | grep -vqF 'Do NOT emit'; then
  : # any remaining occurrences should be in negative contexts; not asserting strictly here
fi

# ─── ENG-71 followup: §5 mandates overwriting the stage-summary file ───
# ENG-71 (May 2026) cycled 9 review-implement loops because iters 6-9
# emitted fresh `verdict fail` markers but never updated their
# stage-summary file. The orchestrator's post-dispatch hook reads the
# file verbatim and posts it as the Linear `completion/reviewing/<issue>`
# summary; with a stale file, the same iter-5 body landed on Linear every
# iter, and the implement agent on each loopback read that stale body,
# fixed everything in it, and reported done — never seeing the new
# findings the reviewer was actually generating each iter. Pin the
# overwrite-every-dispatch rule in §5 so a future prompt edit can't
# silently drop the contract.

# §5 must say "overwrite on every dispatch" (case-insensitive on
# "overwrite" since "overwritten" / "overwrite" are both reasonable).
if printf '%s\n' "$s5" | grep -qiE 'overwrite[ d]+on every dispatch'; then
  ok "§5 mandates 'overwrite on every dispatch' for the stage-summary file"
else
  nope "§5 mandates 'overwrite on every dispatch' for the stage-summary file" \
    "without this rule, the reviewer can re-emit verdicts without a fresh file write — orchestrator posts stale body, implement-loopback gets no new feedback (ENG-71 May 2026 cycle)"
fi

# §5 must explicitly reject the "read-then-conditionally-skip" misreading
# (the way ENG-71's iters 6-9 actually behaved — agent read existing file,
# decided findings unchanged, didn't re-write).
if printf '%s\n' "$s5" | grep -qF 'read-then-conditionally-skip'; then
  ok "§5 explicitly bans 'read-then-conditionally-skip' on the stage-summary file"
else
  nope "§5 explicitly bans 'read-then-conditionally-skip' on the stage-summary file" \
    "the carve-out names the exact ENG-71 misreading; without it, agents may re-derive the same wrong behavior"
fi

# §5 must cite the ENG-71 incident as precedent so the rule's reason is
# self-documenting.
if printf '%s\n' "$s5" | grep -qE 'ENG-71.*(May|2026)'; then
  ok "§5 cites the ENG-71 incident as the reason for the overwrite rule"
else
  nope "§5 cites the ENG-71 incident" \
    "without the precedent, a future prompt-cleanup pass might decide the rule is overcautious and remove it"
fi

# ─── ENG-77 QA-adversarial: §5 invariant deepening (QA round) ──────────
# Background: the existing three D-002 asserts (lines 211, 221, 230)
# run against the entire §5 body. `section_body()` includes pre-fence
# intro and post-fence trailing prose; if a future edit moves the
# MANDATORY paragraph out of §5's fenced block while leaving the
# literal phrase elsewhere in §5, all three D-002 asserts still pass —
# but `bin/render-prompt.sh::extract_block` only emits content BETWEEN
# the two column-0 fences, so the rule never reaches the agent. Pin
# the rendered-prompt-body subset and the negative-example evasion
# vector the brainstorm §7 E-6 considered implausible.

# Extract §5's fenced block — same content extract_block emits.
in_fence_s5="$(awk '
  /^## 5\. Review Agent/ { in_s = 1; next }
  /^## [0-9]+\./ && in_s { exit }
  in_s && /^```/ { in_f = !in_f; next }
  in_s && in_f { print }
' "$PROMPTS")"

# QA-A: MANDATORY phrase falls INSIDE the rendered fenced block.
# Catches a future cleanup that demotes the rule out of what the
# agent sees (intro/outro prose) while leaving the literal phrase in
# §5 — D-002 line 211's section-wide regex false-passes.
if printf '%s\n' "$in_fence_s5" | grep -qiE 'overwrite[ d]+on every dispatch'; then
  ok "§5 (QA-A): 'overwrite on every dispatch' falls INSIDE the rendered fenced block"
else
  nope "§5 (QA-A): 'overwrite on every dispatch' falls INSIDE the rendered fenced block" \
    "phrase exists in §5 (D-002 line 211 still passes) but outside the fenced block — render-prompt.sh::extract_block does not deliver it to the agent"
fi

# QA-B: 'read-then-conditionally-skip' carve-out lands inside the
# fenced block (companion check to QA-A on D-002 assert 2).
if printf '%s\n' "$in_fence_s5" | grep -qF 'read-then-conditionally-skip'; then
  ok "§5 (QA-B): 'read-then-conditionally-skip' carve-out falls INSIDE the rendered fenced block"
else
  nope "§5 (QA-B): 'read-then-conditionally-skip' carve-out falls INSIDE the rendered fenced block" \
    "phrase exists in §5 (D-002 line 221 still passes) but outside the fenced block"
fi

# QA-C: ENG-71 citation lands inside the fenced block.
if printf '%s\n' "$in_fence_s5" | grep -qE 'ENG-71.*(May|2026)'; then
  ok "§5 (QA-C): ENG-71 citation falls INSIDE the rendered fenced block"
else
  nope "§5 (QA-C): ENG-71 citation falls INSIDE the rendered fenced block" \
    "citation exists in §5 (D-002 line 230 still passes) but outside the fenced block"
fi

# QA-D: MANDATORY phrase NOT introduced by a same-line negation. The
# brainstorm §7 E-6 considered "DO NOT overwrite on every dispatch —
# that wastes tokens" implausible because all three pinned phrases
# would need to coexist with negative-context wording. Promote that
# implausibility to enforcement. Per-line regex avoids false-positive
# on the sibling 'do not read-then-conditionally-skip' clause that
# legitimately sits one line below the MANDATORY phrase.
if printf '%s\n' "$in_fence_s5" | grep -qiE '\b(do not|don'\''t|never)[^.]*overwrite[ d]+on every dispatch'; then
  nope "§5 (QA-D): MANDATORY phrase not in same-line negative-example context" \
    "found a negation (do not/don't/never) on the same line preceding 'overwrite on every dispatch' — D-002 line 211's literal-presence regex would false-pass against an anti-instruction"
else
  ok "§5 (QA-D): MANDATORY phrase not in same-line negative-example context"
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
# has a clean exit ramp (`bin/pipeline.sh event ... verdict halt
# --reason agent-blocked` per ENG-60 T2.11; was the legacy hand-crafted
# `<!-- pipeline: verdict result=halt reason=agent-blocked -->` marker pre-T2.11). The agent
# should halt instead of probing when uncertain.
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

  # ENG-60 T2.11: exit ramp is now `verdict halt --reason agent-blocked`
  # via bin/pipeline.sh; the old hand-crafted marker form was replaced
  # to match the per-stage Verdict marker block guidance.
  if printf '%s\n' "$body" | grep -qF 'verdict halt --reason agent-blocked'; then
    ok "$short contains 'verdict halt --reason agent-blocked' exit ramp"
  else
    nope "$short contains 'verdict halt --reason agent-blocked' exit ramp" "instruction missing"
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

# ─── ENG-74: env-var-prefix rule ──────────────────────────────────────
# PIPELINE_WRITER=agent (or any leading VAR=val) must NOT be prepended
# to `bash bin/...` invocations from inside the agent sandbox. The
# Claude allowlist matcher anchors on the first token; an env-var
# assignment is not `bash`, so the Bash(bash bin/pipeline.sh:*) pattern
# fails to match a `PIPELINE_WRITER=agent bash bin/pipeline.sh ...`
# invocation. ENG-64's build dispatch on 2026-05-05 hit this exact case
# — agent silently exited rc=0, no-output detector applied
# pipeline:halted. Pin the rule per-stage so a future prompt edit can't
# drop it from one stage and silently regress.
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

  if printf '%s\n' "$body" | grep -qF 'Do NOT prepend env-var assignments'; then
    ok "$short contains env-var-prefix rule (ENG-74)"
  else
    nope "$short contains env-var-prefix rule (ENG-74)" "phrase missing"
  fi

  if printf '%s\n' "$body" | grep -qF 'PIPELINE_WRITER=agent'; then
    ok "$short names canonical forbidden prefix PIPELINE_WRITER=agent (ENG-74)"
  else
    nope "$short names canonical forbidden prefix PIPELINE_WRITER=agent (ENG-74)" \
         "agent must see the exact forbidden form, not just a prose hint"
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

# ─── Branch-name convention defense (2026-05-04 ENG-63/64/65 incident) ─
# Three feature branches got created by agents using the `feature/eng-N-…`
# prefix (instead of canonical `feat/eng-N-…`). The harness's run-local.sh
# fell into a "legacy feature/* coexistence" path that dispatched the
# agent from the operator's checkout with no per-issue worktree, scope-
# check fired against the wrong working tree, three issues halted, the
# breaker tripped. AGENT_PROMPTS.md now carries an explicit section
# instructing agents to use {branch_name} verbatim and never run any of
# the four branch-creation forms (-b / -B / -m / -c). Pin those instructions
# so a future prompt edit can't quietly drop them.
prompts_full="$(cat "$SCRIPT_DIR/../AGENT_PROMPTS.md")"

if grep -qE '^### Branch-name convention' <<<"$prompts_full"; then
  ok 'Branch-name convention section present'
else
  nope 'Branch-name convention section present' \
       'top-level §"Branch-name convention" missing — agents have no canonical-prefix instruction'
fi

# Each banned branch-creation form must be explicitly named so an agent
# reading the section in isolation knows exactly what NOT to do.
for forbidden in 'git checkout -b' 'git checkout -B' 'git branch -m' 'git switch -c'; do
  if grep -qF "$forbidden" <<<"$prompts_full"; then
    ok "Branch-name convention names forbidden form: $forbidden"
  else
    nope "Branch-name convention names forbidden form: $forbidden" \
         'section must explicitly enumerate banned commands so agents cannot rationalize a near-equivalent'
  fi
done

# The canonical shape `feat/eng-N-<slug>` and `fix/eng-N-<slug>` must be
# named, alongside at least one rejected variant.
if grep -qF 'feat/eng-N-' <<<"$prompts_full" \
   && grep -qF 'fix/eng-N-' <<<"$prompts_full"; then
  ok 'Branch-name convention names canonical feat/ + fix/ prefixes'
else
  nope 'Branch-name convention names canonical feat/ + fix/ prefixes' \
       'agent must see the exact canonical shape, not just a prose hint'
fi
if grep -qF 'feature/' <<<"$prompts_full"; then
  ok 'Branch-name convention rejects `feature/` variant'
else
  nope 'Branch-name convention rejects `feature/` variant' \
       'the May-2026 incident name is feature/* — pin its rejection so the precedent is durable'
fi

# ─── Build → implement loopback rebase rule (ENG-65/ENG-75 May 2026) ────
# Build P6 ("no conflicts with main") rejects with verdict fail target=implementing
# and a meta:metric name=merge_conflict marker. The implement agent's only
# correct response is to rebase onto origin/main and force-push — without
# that, the next build cycle re-fails P6 on the same conflict and the
# loop is infinite. ENG-65 (May 2026) cycled twice this way before
# operator intervention because §3 had no explicit instruction. Pin the
# instruction in §3 so a future prompt edit can't quietly drop it.

# §3 must mention the loopback signal (transition from=building to=implementing).
if printf '%s\n' "$s3" | grep -qE 'building.*to=implementing|build.*loopback'; then
  ok '§3 names the build→implement loopback signal'
else
  nope '§3 names the build→implement loopback signal' \
       'agent needs an explicit hook to detect "this dispatch is post-build-rejection"'
fi

# §3 must instruct rebase + push (the actual remediation).
if printf '%s\n' "$s3" | grep -q 'rebase origin/main' \
   && printf '%s\n' "$s3" | grep -qE 'force-with-lease|force.push'; then
  ok '§3 instructs rebase origin/main + force-push on loopback'
else
  nope '§3 instructs rebase origin/main + force-push on loopback' \
       'without explicit rebase + force-push, agents add new commits but the remote stays behind main, P6 re-fails forever'
fi

# §3 must explicitly disallow the wrong response ("add more tests / new commits without rebasing").
# The instruction is "Do NOT interpret a build-loopback as 'add more tests'" — pin the
# distinctive substring so the negative carve-out can't get edited away in cleanup.
if printf '%s\n' "$s3" | grep -qF 'add more tests'; then
  ok '§3 explicitly bans "add more tests" as the loopback response'
else
  nope '§3 explicitly bans "add more tests" as the loopback response' \
       'ENG-65 cycle was caused by agent treating loopback as "add adversarial coverage"; carve-out must be pinned'
fi

# ─── ENG-71: §7 build agent must not check out main / pull / reset ────
# Pin the MANDATORY worktree-HEAD rule paragraph in §7 (D-001) and the
# symmetric pattern enumeration in `bin/dispatch.sh::_render_and_capture_stream`'s
# building-stage block (ENG-62 Bld-001 prompt-orchestrator symmetry
# discipline). A future contributor who adds a fifth pattern to either
# site without updating the other fails this test.
if printf '%s\n' "$s7" | grep -qF 'MANDATORY worktree-HEAD rule (ENG-71)'; then
  ok "§7 contains ENG-71 worktree-HEAD MANDATORY rule"
else
  nope "§7 contains ENG-71 worktree-HEAD MANDATORY rule" "phrase missing"
fi
for pat in 'git checkout' 'git switch' 'git pull' 'git reset'; do
  if printf '%s\n' "$s7" | grep -qF "\`$pat\`"; then
    ok "§7 explicitly names \`$pat\` as forbidden"
  else
    nope "§7 names \`$pat\`" "pattern not back-tick-quoted in §7"
  fi
done
if printf '%s\n' "$s7" | grep -qF 'chained commands'; then
  ok "§7 names chained-command class explicitly"
else
  nope "§7 names chained-command class" "phrase missing"
fi
if printf '%s\n' "$s7" | grep -qF 'git fetch origin main && git checkout main'; then
  ok "§7 contains literal worked example of chained-command bypass"
else
  nope "§7 contains literal chained-command worked example" \
    "phrase 'git fetch origin main && git checkout main' missing"
fi

# ENG-71 C1 regression pin: §7 must NOT recommend `gh api repos/.../branches/main`
# to verify the merge SHA — `gh api` is not in the building tool allowlist
# (only `gh pr view`, `gh pr list`, `gh pr checks`, `gh pr edit`, `gh pr merge`,
# `gh run` per bin/dispatch.sh::allowed_tools_for "building"). Following the
# §7 advice would force the agent to halt with `agent-blocked` — exactly the
# operator-impact fix the rule was meant to prevent. The MANDATORY rule
# paragraph names a permitted alternative (`gh pr view <N> --json mergeCommit`)
# so the agent has a path to verify the merge SHA without a checkout AND
# without hitting an allowlist denial.
if printf '%s\n' "$s7" | grep -qF 'gh api repos'; then
  nope "§7 must not recommend \`gh api repos/...\` (not in building allowlist)" \
    "phrase still present; rewrite the recipe to use a permitted verb (\`gh pr view\`)"
else
  ok "§7 worktree-HEAD rule does NOT recommend disallowed \`gh api\` recipe (ENG-71 C1)"
fi
if printf '%s\n' "$s7" | grep -qF 'gh pr view'; then
  ok "§7 names a permitted SHA-verification path (\`gh pr view\` is in building allowlist)"
else
  nope "§7 names permitted SHA-verification path" \
    "no \`gh pr view\` mention in §7 — agent has no allowlisted way to verify the merge SHA"
fi

# ─── ENG-71 symmetric pin: bin/dispatch.sh's building-stage block names
# the SAME four pattern literals (ENG-62 Bld-001 discipline).
DISPATCH_SH="$HARNESS_ROOT/bin/dispatch.sh"
if [[ -f "$DISPATCH_SH" ]]; then
  eng71_dispatch_missing=""
  for pat in "'git checkout'" "'git switch'" "'git pull'" "'git reset'"; do
    if ! grep -qF "$pat" "$DISPATCH_SH"; then
      eng71_dispatch_missing+="$pat "
    fi
  done
  if [[ -z "$eng71_dispatch_missing" ]]; then
    ok "ENG-71 symmetric pin: bin/dispatch.sh names all four forbidden patterns"
  else
    nope "ENG-71 symmetric pin: bin/dispatch.sh missing patterns" \
      "patterns missing from bin/dispatch.sh: $eng71_dispatch_missing"
  fi
else
  nope "ENG-71 symmetric pin: bin/dispatch.sh exists" "file missing"
fi

# ─── ENG-74 QA adversarial: symmetric pin on dispatch.sh's env wrapper ──
# The rule's claim "the orchestrator already exports `PIPELINE_WRITER=agent`
# into your dispatch via `bin/dispatch.sh::main`" depends on
# bin/dispatch.sh:361 wrapping the claude -p subprocess with
# `env PIPELINE_WRITER=agent`. If a future refactor drops the wrapper, the
# rule lies — agents reading the rule would still avoid the prefix, but
# bin/pipeline.sh's lane fence would fire (warn today; could be hardened
# to refuse later) on the now-missing PIPELINE_WRITER. Pin the symmetric
# invariant so the rule and its prerequisite stay in lockstep
# (mirrors the ENG-71 §7 ↔ dispatch.sh symmetric-pattern discipline).
DISPATCH_SH="$HARNESS_ROOT/bin/dispatch.sh"
if [[ -f "$DISPATCH_SH" ]] && grep -qE '^[[:space:]]*local cmd=\(env PIPELINE_WRITER=agent' "$DISPATCH_SH"; then
  ok 'ENG-74 symmetric pin: bin/dispatch.sh wraps dispatch with `env PIPELINE_WRITER=agent`'
else
  nope 'ENG-74 symmetric pin: bin/dispatch.sh wraps dispatch with `env PIPELINE_WRITER=agent`' \
       'rule claim "orchestrator already exports PIPELINE_WRITER=agent" depends on this — refactor would silently break the rule'
fi

# ─── ENG-74 QA adversarial: common.sh defaults+exports PIPELINE_WRITER ─
# The rule's "redundant AND unmatchable" framing depends on
# PIPELINE_WRITER being available to the agent's child shells WITHOUT
# the agent prepending it. bin/common.sh:293-294 defaults the value and
# exports it; if either line is dropped, an unprefixed agent invocation
# would land at bin/pipeline.sh's lane fence (currently a warn, but a
# future hardening could escalate to refuse) and the rule's safety net
# evaporates. Pin both lines.
COMMON_SH="$HARNESS_ROOT/bin/common.sh"
if [[ -f "$COMMON_SH" ]] \
   && grep -qF 'PIPELINE_WRITER="${PIPELINE_WRITER:-orchestrator}"' "$COMMON_SH" \
   && grep -qE '^export PIPELINE_WRITER$' "$COMMON_SH"; then
  ok 'ENG-74 symmetric pin: bin/common.sh defaults+exports PIPELINE_WRITER'
else
  nope 'ENG-74 symmetric pin: bin/common.sh defaults+exports PIPELINE_WRITER' \
       'rule "redundant AND unmatchable" claim depends on these two lines — drop them and unprefixed calls would warn (future: refuse) on lane mismatch'
fi

# ─── ENG-74 QA adversarial: no positive example shows the forbidden
# `PIPELINE_WRITER=agent bash bin/...` invocation anywhere in
# AGENT_PROMPTS.md. The rule names the forbidden form as a literal in
# its prose ("e.g. `PIPELINE_WRITER=agent`") but never as a usable
# command (no `PIPELINE_WRITER=agent bash bin/<file>.sh ...` shape).
# A future "wrong way" anti-example paste could trivially re-introduce
# the shape an agent might copy verbatim. Forbid the shape.
if grep -qE 'PIPELINE_WRITER=agent[[:space:]]+bash[[:space:]]+(\.pipeline/)?bin/' "$PROMPTS"; then
  nope 'ENG-74 QA: no PIPELINE_WRITER=agent bash bin/... command shape anywhere in AGENT_PROMPTS.md' \
       'a "wrong-way" anti-example could be copy-pasted by an agent; the rule must name the forbidden token sequence in prose only, never as a command'
else
  ok 'ENG-74 QA: no PIPELINE_WRITER=agent bash bin/... command shape anywhere in AGENT_PROMPTS.md'
fi

# ─── ENG-74 QA adversarial: §7 wait-exit example invocations stay bare.
# The empirical ENG-64 hit was on §7's wait-exit running
# `PIPELINE_WRITER=agent bash bin/pipeline.sh event ... verdict wait
# --reason awaiting-approval`. Pin that §7's actual example commands
# (P2 awaiting-approval at line 1283, P5 awaiting-ci at line 1324) stay
# unprefixed even if the universal rule paragraph drifts. The grep
# anchors on a leading VAR=val token before `bash bin/pipeline.sh event`.
if printf '%s\n' "$s7" | grep -qE '^[[:space:]]*[A-Z_]+=[A-Za-z0-9_-]+[[:space:]]+bash[[:space:]]+(\.pipeline/)?bin/pipeline\.sh[[:space:]]+event'; then
  nope '§7 wait-exit examples are bare (no env-var prefix on `bash bin/pipeline.sh event ...`)' \
       'a future prompt edit reintroduced the forbidden prefix shape on a §7 wait-exit example — would re-trigger the ENG-64 sandbox denial'
else
  ok '§7 wait-exit examples are bare (no env-var prefix on `bash bin/pipeline.sh event ...`)'
fi

# ─── ENG-74 QA adversarial (round 2): per-stage rule-sentence integrity.
# The plan-loop's two greps (`Do NOT prepend env-var assignments` and
# `PIPELINE_WRITER=agent`) match independently, so a future rewrite that
# preserves both literal tokens but loses the load-bearing linkage to
# `bash bin/...` would slip through — leaving the agent without a clear
# binding from the warning to the operative command shape. Pin a single
# regex per stage that the bolded sentence keeps all three anchors in
# order on the same paragraph line: warning trigger → canonical example →
# `bash bin/...` invocation target.
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

  if printf '%s\n' "$body" | grep -qE 'Do NOT prepend env-var assignments.*PIPELINE_WRITER=agent.*bash bin/'; then
    ok "$short rule sentence keeps trigger→example→target linkage on one line (ENG-74)"
  else
    nope "$short rule sentence keeps trigger→example→target linkage on one line (ENG-74)" \
         "the three anchors must co-occur on a single paragraph line; a rewrite that splits them across lines or loses the linkage breaks the agent's binding"
  fi
done

# ─── ENG-74 QA adversarial (round 2): bin/dispatch.sh env wrapper and
# claude invocation must live in the same `local cmd=(...)` array.
# The existing symmetric pin (line 649) only checks the prefix
# `local cmd=(env PIPELINE_WRITER=agent`. A refactor that splits the env
# wrapper away from the claude invocation (e.g., env wrapper applied to a
# different command, claude moved to a sibling cmd array without the
# wrapper) keeps the prefix substring but breaks the rule's premise that
# `dispatch.sh::main` exports `PIPELINE_WRITER=agent` INTO the agent's
# claude subprocess. Assert `claude` appears within 10 lines AFTER the
# env wrapper line so the two stay coupled.
if [[ -f "$DISPATCH_SH" ]] \
   && grep -A 10 'local cmd=(env PIPELINE_WRITER=agent' "$DISPATCH_SH" | grep -q 'claude'; then
  ok 'ENG-74 symmetric pin: bin/dispatch.sh env wrapper reaches claude in the same cmd array'
else
  nope 'ENG-74 symmetric pin: bin/dispatch.sh env wrapper reaches claude in the same cmd array' \
       'the env PIPELINE_WRITER=agent wrapper and claude invocation must share one cmd array; splitting them silently invalidates the rule premise'
fi

# ─── ENG-74 QA adversarial (round 2): no `env VAR=val bash bin/...`
# command shape anywhere in AGENT_PROMPTS.md. The rule says "an env-var
# assignment is not `bash`" but an agent could mis-read this as making
# `env VAR=val bash bin/...` permissible (it isn't — first token is
# `env`, not `bash`, so the Bash(bash bin/...) matcher still fails).
# Forbid the shape globally so a "wrong-way" anti-example or escape-hatch
# hedge cannot land in any stage's prompt body.
if grep -qE '\benv[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+bash[[:space:]]+(\.pipeline/)?bin/' "$PROMPTS"; then
  nope 'ENG-74 QA: no `env VAR=val bash bin/...` command shape anywhere in AGENT_PROMPTS.md' \
       '`env VAR=val bash bin/...` is also unmatchable (first token is env, not bash); a copy-pasteable example would re-trigger the ENG-64 sandbox denial under a different shape'
else
  ok 'ENG-74 QA: no `env VAR=val bash bin/...` command shape anywhere in AGENT_PROMPTS.md'
fi

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
