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

# rendered_stage_body — returns what `bin/render-prompt.sh::extract_block` will
# deliver to the agent for this stage: §0 (Common rules) prepended to the
# stage's own body. Use this for assertions on rules that live in §0 (Secret-
# handling, Tool allowlist & probing, env-var-prefix, etc.) so per-stage
# loops still pass after the §0 consolidation. Use plain section_body() for
# stage-specific content (overwrite rule, --repo flag, branch loopback).
rendered_stage_body() {
  local heading="$1"
  section_body "## 0. Common rules"
  section_body "$heading"
}

# ─── §0 (Common rules) consolidation invariant ────────────────────────
# §0 is the single source of truth for rules delivered to every stage.
# render-prompt.sh::main prepends §0's fenced block to every per-stage
# block before token interpolation. Per-stage assertions below use
# rendered_stage_body (= §0 + §N) so the same checks survive both the
# pre-consolidation layout (rules inlined per stage) and the post-
# consolidation layout (rules in §0 only). Pin §0's existence + the four
# load-bearing phrases here so a §0 deletion surfaces directly, not just
# via downstream test-cascade.
s0="$(section_body "## 0. Common rules")"
if [[ -n "$s0" ]]; then
  ok "§0 (Common rules) section exists"
else
  nope "§0 (Common rules) section exists" \
    "section missing — render-prompt.sh::main will die on dispatch (no common block to prepend)"
fi
for phrase in 'Secret-handling (ENG-46)' 'Tool allowlist & probing (ENG-53 #11' 'retry with the same sig' 'Do NOT prepend env-var assignments' 'Sub-agent debris (ENG-100)'; do
  if printf '%s\n' "$s0" | grep -qF "$phrase"; then
    ok "§0 carries '$phrase' (delivered to every stage by render-prompt.sh)"
  else
    nope "§0 carries '$phrase'" \
      "phrase missing from §0 — per-stage checks below would still pass on re-inlined copies but consolidation is broken"
  fi
done

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

# ─── ENG-108: §3 read-first list has {progress_md_path} at position 1 ───
# The implementing prompt MUST instruct the agent to read the per-issue
# progress notebook before any other onboarding artifact (Linear AC-1).
# Pin the literal `1. {progress_md_path}` line in §3's body so a future
# edit that demotes the token (or removes it entirely) trips here.
if printf '%s\n' "$s3" | grep -qF '1. {progress_md_path}'; then
  ok "§3 ENG-108: read-first list has '{progress_md_path}' at position 1"
else
  nope "§3 ENG-108: read-first list has '{progress_md_path}' at position 1" \
    "literal '1. {progress_md_path}' line missing from §3 — has the position-1 placement been demoted, or the token removed entirely?"
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

# ─── ENG-97: §2 has gRPC (post-Tauri) AND a non-Tauri api-contract example ───
# Post-ENG-97 (May 2026): the §2 api-contract block carries a gRPC + protobuf
# compiled-IPC example (replacing the prior Tauri v2 + TypeScript shape) plus the
# existing Python/Flask HTTP-handler example. Test pins (a) the absence of
# the prior Tauri marker and (b) the presence of the new gRPC marker so a
# silent revert (or a silent drop of Example 1) trips here.
if printf '%s\n' "$s2" | grep -qF '#[tauri::command]'; then
  nope "§2 ENG-97: '#[tauri::command]' marker absent (post-Tauri-strip)" "marker present — has the api-contract Example 1 reverted to Tauri?"
else
  ok "§2 ENG-97: '#[tauri::command]' marker absent (post-Tauri-strip)"
fi
if printf '%s\n' "$s2" | grep -qF 'service FooService'; then
  ok "§2 ENG-97: contains gRPC api-contract example (service FooService)"
else
  nope "§2 ENG-97: contains gRPC api-contract example (service FooService)" "marker missing — has Example 1 been silently dropped or its body renamed?"
fi
if printf '%s\n' "$s2" | grep -qF '@app.route'; then
  ok "§2 contains non-Tauri (Python/Flask) api-contract example (@app.route)"
else
  nope "§2 contains non-Tauri (Python/Flask) api-contract example (@app.route)" "phrase missing"
fi

# ─── ENG-97: whole-file negative-grep on de-Tauri-ed tokens ─────────────
# Post-ENG-97 (May 2026): AGENT_PROMPTS.md must carry zero Tauri-specific
# illustrations. The prior assertions are §2-scoped (api-contract block) —
# this block scans the whole file so a re-introduction in §3/§6/§7/§8/§9
# trips here too. One assertion per token gives a diagnostic that names
# which token reappeared. Tokens enumerated by Linear ENG-97 AC#1.
for forbidden_token in 'Tauri' 'tauri::' 'tauri.conf.json' 'src-tauri/' 'cargo test -- --list' 'invoke('; do
  if grep -qF -- "$forbidden_token" "$PROMPTS"; then
    nope "AGENT_PROMPTS.md ENG-97: forbidden token '$forbidden_token' absent" "token reappeared in AGENT_PROMPTS.md — see ENG-97 for context"
  else
    ok "AGENT_PROMPTS.md ENG-97: forbidden token '$forbidden_token' absent"
  fi
done

# ─── ENG-97 QA-adversarial: case-insensitive 'tauri' substring scan ───────
# The Task 8.2 negative-grep is case-sensitive (`grep -F`). A future revert
# could write `TAURI`, `tauri-app`, or `Pre-Tauri-era` and evade the pinned
# tokens. This case-insensitive scan tightens the intent: the proper noun
# 'Tauri' in any casing is banned from AGENT_PROMPTS.md.
if grep -qiF -- 'tauri' "$PROMPTS"; then
  nope "ENG-97 QA: AGENT_PROMPTS.md case-insensitive 'tauri' marker absent" \
    "case-insensitive scan matched — a Tauri substring (any case) reappeared in the prompt"
else
  ok "ENG-97 QA: AGENT_PROMPTS.md case-insensitive 'tauri' marker absent"
fi

# ─── ENG-97 QA-adversarial: §2 body is non-empty (header-rename guard) ────
# Every §2-scoped assertion above operates on $s2 from `section_body`.
# If `## 2. Plan Agent` is renamed (e.g. to `## 2. Planning Agent`),
# section_body returns the empty string and every negative-grep on $s2
# trivially passes. This guard defends those assertions against silent
# header drift.
if [[ -n "$s2" ]]; then
  ok "ENG-97 QA: §2 (Plan Agent) section body is non-empty (header-rename guard)"
else
  nope "ENG-97 QA: §2 (Plan Agent) section body is non-empty (header-rename guard)" \
    "§2 body extracted as empty — has the '## 2. Plan Agent' heading been renamed? Every §2-scoped negative-grep is now trivially passing."
fi

# ─── ENG-97 QA-adversarial: §2 has exactly 2 indented api-contract fences ─
# The existing §2 column-0 fence-count pin (further below) covers the
# OUTER per-stage fence pair. If a future edit deletes the indented
# (column-4) api-contract fence — at AGENT_PROMPTS.md:460,494 — so the
# example bodies float as plain prose, the column-0 count stays at 2 and
# the existing test still passes, but downstream agents lose the fenced
# extraction target. Pin the indented fence count separately.
indented_fence_count_s2="$(printf '%s\n' "$s2" | grep -cE '^[[:space:]]+```' || true)"
if [[ "$indented_fence_count_s2" == "2" ]]; then
  ok "ENG-97 QA: §2 indented (column-4) fence count is exactly 2 (api-contract block bounds)"
else
  nope "ENG-97 QA: §2 indented (column-4) fence count is exactly 2 (api-contract block bounds)" \
    "got $indented_fence_count_s2 indented fences in §2 — the api-contract block bounds drifted; plan agents lose the fenced extraction target"
fi

# ─── ENG-97 QA-adversarial: §2 carries both Example heading markers ───────
# The positive pins above check one body-marker per example (`service
# FooService` for gRPC, `@app.route` for Flask). A silent collapse — drop
# Example 1, rename Example 2's body under the Example 1 header — could
# leave one body marker missing AND remove an Example heading without
# tripping body-marker assertions. Pin the heading markers as a
# structural complement.
if printf '%s\n' "$s2" | grep -qE '^[[:space:]]*# === Example 1 —' \
   && printf '%s\n' "$s2" | grep -qE '^[[:space:]]*# === Example 2 —'; then
  ok "ENG-97 QA: §2 api-contract carries both '# === Example 1 —' AND '# === Example 2 —' headers"
else
  nope "ENG-97 QA: §2 api-contract carries both '# === Example 1 —' AND '# === Example 2 —' headers" \
    "one or both example headers missing — has an example been silently collapsed?"
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
# could revert §7 to a Tauri-leaning list (`next.config.js, Caddyfile,
# nginx.conf` plus a desktop-shell config like the prior `tauri.conf.json`
# token, now banned by the ENG-97 global negative-grep above) and the
# existing list assertions below would all still pass.
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

# Iter-7 M4 (post-fix): the staleness mandate moved to §0's fenced block
# as the SSOT. Test against the rendered §5 body (= §0 + §5) so we
# verify the rule reaches review-stage agents via the same render path
# every other stage uses. The legacy §5-only assertions broke when M4
# hoisted the boilerplate; their behavior is preserved here against
# rendered_stage_body output.
rendered_s5="$(rendered_stage_body "## 5. Review Agent")"
if printf '%s\n' "$rendered_s5" | grep -qiE 'overwrite[ d]+on every dispatch'; then
  ok "§5 (rendered, post-iter-7-M4): mandates 'overwrite on every dispatch' for the stage-summary file"
else
  nope "§5 (rendered, post-iter-7-M4): mandates 'overwrite on every dispatch'" \
    "without this rule, the reviewer can re-emit verdicts without a fresh file write — orchestrator posts stale body, implement-loopback gets no new feedback (ENG-71 May 2026 cycle)"
fi

if printf '%s\n' "$rendered_s5" | grep -qF 'read-then-conditionally-skip'; then
  ok "§5 (rendered): bans 'read-then-conditionally-skip' on the stage-summary file"
else
  nope "§5 (rendered): bans 'read-then-conditionally-skip'" \
    "the carve-out names the exact ENG-71 misreading; without it, agents may re-derive the same wrong behavior"
fi

if printf '%s\n' "$rendered_s5" | grep -qE 'ENG-71.*(May|2026)'; then
  ok "§5 (rendered): cites the ENG-71 incident as the reason for the overwrite rule"
else
  nope "§5 (rendered): cites the ENG-71 incident" \
    "without the precedent, a future prompt-cleanup pass might decide the rule is overcautious and remove it"
fi
unset rendered_s5

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

# Iter-7 M4: the boilerplate moved to §0's fenced block. The QA-A/QA-B
# evasion vector (rule outside §5's fenced block but still in §5) no
# longer applies — §5 doesn't carry the rule directly. Pin against
# §0's fenced block instead so a future edit that moves the contract
# OUT of §0's fenced body still trips this guard.
in_fence_s0="$(awk '
  /^## 0\. Common rules/ { in_s = 1; next }
  /^## [0-9]+\./ && in_s { exit }
  in_s && /^```/ { in_f = !in_f; next }
  in_s && in_f { print }
' "$PROMPTS")"

if printf '%s\n' "$in_fence_s0" | grep -qiE 'overwrite[ d]+on every dispatch'; then
  ok "§0 (QA-A, post-M4): 'overwrite on every dispatch' falls INSIDE the rendered fenced block"
else
  nope "§0 (QA-A, post-M4): 'overwrite on every dispatch' falls INSIDE the rendered fenced block" \
    "phrase exists in §0 prose but outside the fenced block — render-prompt.sh::extract_block does not deliver it to any agent"
fi

if printf '%s\n' "$in_fence_s0" | grep -qF 'read-then-conditionally-skip'; then
  ok "§0 (QA-B, post-M4): 'read-then-conditionally-skip' carve-out falls INSIDE the rendered fenced block"
else
  nope "§0 (QA-B, post-M4): 'read-then-conditionally-skip' carve-out falls INSIDE the rendered fenced block" \
    "phrase exists in §0 prose but outside the fenced block — render-prompt.sh::extract_block does not deliver it to any agent"
fi
unset in_fence_s0

# Iter-7 M4 (post-fix): QA-C and QA-D moved with the boilerplate. Pin
# the citation + negative-context guards on §0's fenced block (the new
# SSOT). The §5-on-the-fenced-block evasion vector no longer applies
# (§5 doesn't carry the mandate); the §0 vector replaces it.
in_fence_s0_qa="$(awk '
  /^## 0\. Common rules/ { in_s = 1; next }
  /^## [0-9]+\./ && in_s { exit }
  in_s && /^```/ { in_f = !in_f; next }
  in_s && in_f { print }
' "$PROMPTS")"

# QA-C (post-M4): ENG-71/77 citation lives inside §0's fenced block.
if printf '%s\n' "$in_fence_s0_qa" | grep -qE 'ENG-(71|77).*(May|2026)'; then
  ok "§0 (QA-C, post-M4): ENG-71/77 citation falls INSIDE the rendered fenced block"
else
  nope "§0 (QA-C, post-M4): ENG-71/77 citation falls INSIDE the rendered fenced block" \
    "citation exists in §0 prose but outside the fenced block — render-prompt.sh::extract_block does not deliver it to any agent"
fi

# QA-D (post-M4): no negative-example context preceding the MANDATORY
# phrase inside §0's fenced block.
if printf '%s\n' "$in_fence_s0_qa" | grep -qiE '\b(do not|don'\''t|never)[^.]*overwrite[ d]+on every dispatch'; then
  nope "§0 (QA-D, post-M4): MANDATORY phrase not in same-line negative-example context" \
    "found a negation (do not/don't/never) on the same line preceding 'overwrite on every dispatch' — literal-presence regex would false-pass against an anti-instruction"
else
  ok "§0 (QA-D, post-M4): MANDATORY phrase not in same-line negative-example context"
fi
unset in_fence_s0_qa

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
  # rendered_stage_body == §0 (Common rules) + per-stage body. The phrases
  # tested below now live in §0 (consolidated) and are delivered to every
  # stage by render-prompt.sh::main's prepend.
  body="$(rendered_stage_body "$stage_section")"
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
  # rendered_stage_body picks up the rule from §0 (consolidated).
  body="$(rendered_stage_body "$stage_section")"
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
  body="$(rendered_stage_body "$stage_section")"
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
  body="$(rendered_stage_body "$stage_section")"
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

# ─── ENG-83: §7 build agent merge command must include --repo flag ────
# Without --repo, gh CLI's post-merge local cleanup tries `git checkout
# main` and errors when the operator's main checkout already holds main
# as a worktree (the canonical operator setup; see
# docs/runbooks/operator-mental-model.md §4). Pin the rule + rationale
# so a future "cleanup" pass can't strip the unfamiliar flag without
# context. Mirrors the ENG-71 §7 pin shape above.

# Positive: §7 names --repo on the gh pr merge command line.
if printf '%s\n' "$s7" | grep -qE 'gh pr merge.*--repo'; then
  ok "§7 names --repo flag on gh pr merge invocation"
else
  nope "§7 names --repo flag on gh pr merge invocation" \
    "without --repo, gh's local cleanup errors against the operator's main worktree (ENG-83)"
fi

# Positive: §7 explains the rationale (worktree-locks-main).
if printf '%s\n' "$s7" | grep -qE 'main is already used by worktree|local cleanup'; then
  ok "§7 explains --repo rationale (worktree-locks-main / local cleanup)"
else
  nope "§7 explains --repo rationale" \
    "rationale paragraph missing — a future cleanup pass might strip --repo without realising"
fi

# Negative: §7 must NOT contain a $(gh pr view ...) shape — the
# allowlist matcher rejects $() in Bash arguments (per ENG-83 §1
# and the secret-handling preamble above).
if printf '%s\n' "$s7" | grep -qE 'repo_full="\$\(gh|--repo "\$\(gh'; then
  nope "§7 lacks \$(gh ...) shell-substitution shape" \
    "allowlist matcher rejects \$() in Bash arguments — agent must derive in two separate tool calls (ENG-83)"
else
  ok "§7 lacks \$(gh ...) shell-substitution shape (allowlist-safe)"
fi

# Positive: §7 instructs the two-step derivation (gh pr view first,
# then gh pr merge with the literal). Pin the canonical command form.
if printf '%s\n' "$s7" | grep -qF 'gh pr view <N> --json url'; then
  ok "§7 names canonical owner/repo derivation (gh pr view --json url)"
else
  nope "§7 names canonical owner/repo derivation" \
    "without the --json url derivation, the agent has no allowlist-safe path to compute <owner>/<repo>"
fi

# ─── ENG-83 QA adversarial coverage ──────────────────────────────────
# The plan-enumerated asserts above pin --repo presence + rationale +
# canonical derivation + absence of one $() shape. Cold-reviewer
# (general-purpose subagent, 2026-05-09) surfaced regression vectors
# the four asserts do NOT catch: alternative substitution shapes
# (backticks, =$()), strip-by-cleanup of the load-bearing --auto /
# --delete-branch flags on the example invocation, loss of the
# MANDATORY imperative wording, and hardcoded-literal substitution
# instead of the placeholder. Five asserts below close those gaps.

# QA-ADV-1 (negative): §7 must NOT use backtick command substitution
# `--repo \`gh ...\``. Backticks are rejected by the dispatch allowlist
# matcher just like $(...) — the existing assert 3 (the $() negative
# pin) does NOT cover this variant.
if printf '%s\n' "$s7" | grep -qE -- '--repo[[:space:]]+`'; then
  nope "§7 lacks --repo backtick-substitution shape" \
    "allowlist matcher rejects backticks in Bash arguments — adv coverage on ENG-83 assert 3 ($() negative pin)"
else
  ok "§7 lacks --repo backtick-substitution shape (allowlist-safe)"
fi

# QA-ADV-2 (negative): §7 must NOT use the `--repo=$(...)` equals form.
# The existing assert 3 negative pin keys on `--repo "$(gh` (with quote);
# the equals form is a legitimate bash idiom that bypasses the regex
# but is still rejected by the allowlist matcher.
if printf '%s\n' "$s7" | grep -qF -- '--repo=$('; then
  nope "§7 lacks --repo=\$(...) equals-form substitution" \
    "allowlist matcher still rejects \$() inside the equals form — adv coverage on ENG-83 assert 3"
else
  ok "§7 lacks --repo=\$(...) equals-form substitution (allowlist-safe)"
fi

# QA-ADV-3 (positive): §7 *Merge strategy* example MUST keep `--auto`
# AND `--delete-branch`. A future cleanup pass that adds --repo could
# accidentally strip these load-bearing flags (--auto queues the
# server-side merge until checks pass + human approval per P5/P2;
# --delete-branch removes the remote ref via the API). Existing assert 1
# only matches `gh pr merge.*--repo` — both flags could vanish silently.
if printf '%s\n' "$s7" | grep -qE 'gh pr merge.*--repo.*--merge.*--auto|gh pr merge.*--repo.*--auto.*--merge'; then
  ok "§7 example invocation keeps --merge AND --auto on the gh pr merge line"
else
  nope "§7 example invocation keeps --merge + --auto" \
    "future cleanup pass might strip these load-bearing flags; --auto queues server-side merge per P5/P2"
fi
if printf '%s\n' "$s7" | grep -qF -- '--delete-branch'; then
  ok "§7 keeps --delete-branch (remote ref cleanup via API)"
else
  nope "§7 keeps --delete-branch" \
    "without --delete-branch, the remote source branch lingers post-merge; cleanup-worktrees.sh only handles local"
fi

# QA-ADV-4 (positive): §7 *Merge strategy* example MUST use the
# `<derived-owner-repo>` PLACEHOLDER on the merge line, not a hardcoded
# literal like `StupiDeity/twinning-harness`. Plan A-018 explicitly
# rejects the hardcoded fallback as brittle on multi-target deployments.
# A future "cleanup" might inline the example owner/repo and break the
# rule for every non-harness target.
if printf '%s\n' "$s7" | grep -qE 'gh pr merge.*--repo[[:space:]]+<derived-owner-repo>'; then
  ok "§7 merge example uses <derived-owner-repo> placeholder (not a hardcoded literal)"
else
  nope "§7 merge example uses <derived-owner-repo> placeholder" \
    "hardcoded literal like 'StupiDeity/twinning-harness' on the merge line breaks multi-target use (plan A-018)"
fi

# QA-ADV-5 (positive): §7 must word --repo as MANDATORY (or REQUIRED).
# Existing asserts pin the flag's PRESENCE in the example but not the
# imperative. A future edit that drops the "MANDATORY" sentence while
# leaving the example would technically pass all four ENG-83 asserts;
# the agent might then treat --repo as optional decoration.
if printf '%s\n' "$s7" | grep -qE '`?--repo`?[[:space:]]+flag[[:space:]]+is[[:space:]]+(MANDATORY|REQUIRED|mandatory|required)'; then
  ok "§7 marks --repo as MANDATORY (imperative wording present)"
else
  nope "§7 marks --repo as MANDATORY" \
    "without the imperative, agent might treat --repo as optional; example alone is descriptive, not prescriptive"
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
  body="$(rendered_stage_body "$stage_section")"
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

# ─── ENG-87 review-iter-7 M4: stage-summary mandate hoisted to §0 ────
# Pre-iter-7, the "MANDATORY — overwrite on every dispatch" clause +
# the "do not read-then-conditionally-skip" carve-out + the ENG-71/77
# incident citation were duplicated across §§1-7 (~6 sites). Iter-7 M4
# flagged that as a regression of the §0 SSOT consolidation. Post-fix,
# §0 carries the contract once; every per-stage block inherits it via
# render-prompt.sh::extract_block + main()'s `block="$common_block"$'\n'"$block"`
# prepend. The rendered_stage_body helper exercises that exact path
# (= §0 fenced block + per-stage fenced block); switching to it is
# how this test now verifies the contract reaches every stage.
assert_overwrite_mandate() {
  local section_name="$1" stage_key="$2"
  local body; body="$(rendered_stage_body "$section_name")"
  if printf '%s\n' "$body" | grep -qiE 'overwrite[ d]+on every dispatch'; then
    ok "${stage_key}: mandates 'overwrite on every dispatch' (delivered via §0)"
  else
    nope "${stage_key}: mandates 'overwrite on every dispatch' (delivered via §0)" \
      "without this rule, the ${stage_key} agent can re-emit verdicts without a fresh file write — orchestrator posts stale body, downstream loopback gets no new feedback (ENG-77/ENG-71 May 2026 cycle)"
  fi
  if printf '%s\n' "$body" | grep -qF 'read-then-conditionally-skip'; then
    ok "${stage_key}: bans 'read-then-conditionally-skip' (delivered via §0)"
  else
    nope "${stage_key}: bans 'read-then-conditionally-skip' (delivered via §0)" \
      "the carve-out names the exact ENG-71 misreading; without it, agents may re-derive the same wrong behavior"
  fi
  if printf '%s\n' "$body" | grep -qE 'ENG-(71|77).*(May|2026)'; then
    ok "${stage_key}: cites the ENG-71/77 incident (delivered via §0)"
  else
    nope "${stage_key}: cites the ENG-71/77 incident (delivered via §0)" \
      "without the precedent, a future prompt-cleanup pass might decide the rule is overcautious and remove it"
  fi
}

assert_overwrite_mandate "## 1. Brainstorm Agent"               brainstorming
assert_overwrite_mandate "## 2. Plan Agent"                     planning
assert_overwrite_mandate "## 3. Implementation Agent (Backend)" implementing
assert_overwrite_mandate "## 4. UI Agent (Frontend)"            ui
assert_overwrite_mandate "## 5. Review Agent"                   reviewing
assert_overwrite_mandate "## 6. QA Agent"                       qa
assert_overwrite_mandate "## 7. Build Agent"                    building

# ─── ENG-82: §6 back-fill detection clause + Decision-path D ────────
# Without this rule, the QA agent on a back-fill PR (issue scope =
# document a fix already shipped) spends reasoning budget rediscovering
# the workaround and emits a non-canonical status line. See
# docs/brainstorms/2026-05-14-eng-82-…-design.md and ENG-79's
# 2026-05-08 monitoring run for the source incident.
s6="$(section_body "## 6. QA Agent")"
if printf '%s\n' "$s6" | grep -qiF 'back-fill'; then
  ok "§6 ENG-82: carries 'back-fill' detection clause"
else
  nope "§6 ENG-82: carries 'back-fill' detection clause" \
       "phrase missing — QA agent will re-derive the workaround per dispatch"
fi
if printf '%s\n' "$s6" | grep -qF 'git diff main..HEAD --name-only'; then
  ok "§6 ENG-82: cites detection command 'git diff main..HEAD --name-only'"
else
  nope "§6 ENG-82: cites detection command 'git diff main..HEAD --name-only'" \
       "without the exact command, agents may invent different signals"
fi
if printf '%s\n' "$s6" | grep -qF 'Back-fill verified · 0 new code paths'; then
  ok "§6 ENG-82: pins canonical status line 'Back-fill verified · 0 new code paths · …'"
else
  nope "§6 ENG-82: pins canonical status line 'Back-fill verified · 0 new code paths · …'" \
       "non-canonical status lines break grep-based operator audit on completion/qa/ENG-N comments"
fi
unset s6

# ─── ENG-87 review-iter-7 C2: dispatch-id contract delivered to agents ──
# Iter-4/5 review found that the `### Dispatch identifier and freshness
# contract` subsection lived inside the unnumbered `## Verdict-marker
# protocol` section of AGENT_PROMPTS.md. extract_block (render-prompt.sh)
# only matches numbered `## N.` boundaries, so the unnumbered section is
# invisible to renders — every agent received the per-stage block plus
# §0's fenced block, and the dispatch-id contract was in NEITHER.
# CLAUDE.md and the plan claim this preamble is "the prompt-side defense
# for the chained-command blind spot in assert_no_tool_invocation"; the
# defense was never delivered.
#
# Pre-iter-7 the assertion grepped raw source from H1 to `## 1.` (the
# unnumbered section is in that range), so it false-passed. Post-fix:
# the contract body lives INSIDE §0's fenced block, so rendered_stage_body
# (= §0 + §N) carries it. Switch the assertion to rendered_stage_body
# so it tests what agents actually receive at dispatch time.
rendered_stage_body_implementing="$(rendered_stage_body "## 3. Implementation Agent (Backend)")"
if printf '%s' "$rendered_stage_body_implementing" | grep -qF 'Dispatch identifier and freshness contract'; then
  ok "rendered stage body: cites Dispatch identifier and freshness contract (delivered via §0)"
else
  nope "rendered stage body: cites Dispatch identifier and freshness contract (delivered via §0)" \
    "the heading is NOT in §0 + §3 (rendered stage body) — agents do not receive it. Move the contract body INTO §0's fenced block; the prior unnumbered placement was invisible to extract_block. Affected by review-iter-7 C2 (and iter-5 C2)."
fi

# Auto-injection rule must reach agents via §0.
if printf '%s' "$rendered_stage_body_implementing" | grep -qE 'auto-inject|chokepoint'; then
  ok "rendered stage body: cites auto-injection / chokepoint mechanism"
else
  nope "rendered stage body: cites auto-injection / chokepoint mechanism" \
    "without naming the chokepoint, an agent reading the rendered prompt might attempt manual marker emission"
fi

# Envelope-violation halt class must reach agents via §0.
if printf '%s' "$rendered_stage_body_implementing" | grep -qF 'dispatch-envelope-violation'; then
  ok "rendered stage body: names dispatch-envelope-violation halt class"
else
  nope "rendered stage body: names dispatch-envelope-violation halt class" \
    "without the halt-token reference, the no-mcp/no-curl rules read like style preferences instead of hard contracts"
fi

# No-carry-forward-state mandate must reach agents via §0.
if printf '%s' "$rendered_stage_body_implementing" | grep -qiE 'carry forward|fresh slate|previous (cycle|dispatch)'; then
  ok "rendered stage body: carries the no-carry-forward-state mandate"
else
  nope "rendered stage body: carries the no-carry-forward-state mandate" \
    "Task 14's fourth bullet (no-carry-forward-state) missing from the rendered body — an agent could read prior-dispatch artifacts and defeat the clear-on-start invariant"
fi
unset rendered_stage_body_implementing

# ─── ENG-100: sub-agent debris rule delivered via §0 ─────────────
# The new §0 rule must reach every rendered stage body, including
# brainstorm/plan which use it as the structural complement to the
# orchestrator-side auto-clean. Pin the rule's headline phrase + the
# operator-recognition word agent-blocked so a §0 deletion surfaces
# directly. Mirrors the ENG-87 C2 pin shape (rendered_stage_body =
# §0 + §N).
for stage_key in '## 1. Brainstorm Agent' '## 2. Plan Agent'; do
  short="${stage_key%% Agent*}"
  rsb="$(rendered_stage_body "$stage_key")"
  if printf '%s' "$rsb" | grep -qF 'Sub-agent debris (ENG-100)'; then
    ok "rendered stage body ($short): cites 'Sub-agent debris (ENG-100)' (delivered via §0)"
  else
    nope "rendered stage body ($short): cites 'Sub-agent debris (ENG-100)'" \
      "phrase missing from rendered §0 + §N — sub-agents not warned about debris generation"
  fi
  if printf '%s' "$rsb" | grep -qF 'verdict halt --reason agent-blocked'; then
    ok "rendered stage body ($short): names the agent-blocked exit ramp"
  else
    nope "rendered stage body ($short): names the agent-blocked exit ramp" \
      "without the operator-recognition word, the rule reads like advice instead of a hard contract"
  fi
done
unset stage_key short rsb

# ─── ENG-100 QA adversarial: §0 rule must reach EVERY stage body ────
# The implement-side fixture above pins delivery for §§1-2 only
# (brainstorm + planning — the two stages the rule was authored for).
# Because §0 is the canonical cross-stage rule section, the
# `Sub-agent debris (ENG-100)` paragraph MUST reach every dispatched
# stage's rendered body. The Agent-tool sub-agent constraint applies
# regardless of whether the parent agent is brainstorm, plan, or
# implementing — any stage that dispatches an inner sub-agent could
# generate debris. Pinning all 9 stages catches the regression where
# the rule is accidentally promoted into §1 / §2 bodies (instead of
# §0) and silently strips delivery to §§3-9.
for stage_key in \
  '## 3. Implementation Agent (Backend)' \
  '## 4. UI Agent (Frontend)' \
  '## 5. Review Agent' \
  '## 6. QA Agent' \
  '## 7. Build Agent' \
  '## 8. Release Agent' \
  '## 9. Retrospective Agent (Scheduled)'; do
  short="${stage_key%% Agent*}"
  rsb="$(rendered_stage_body "$stage_key")"
  if printf '%s' "$rsb" | grep -qF 'Sub-agent debris (ENG-100)'; then
    ok "QA-ADV ENG-100: rendered stage body ($short): §0 sub-agent debris rule delivered"
  else
    nope "QA-ADV ENG-100: rendered stage body ($short): §0 sub-agent debris rule delivered" \
      "rule absent from rendered §0+§N for $short — promoting the rule out of §0 (or removing it) silently weakens debris discipline for non-docs stages"
  fi
done
unset stage_key short rsb

# ─── ENG-87 review-iter-7 M4: stage-summary mandate hoisted to §0 ──
# Pre-iter-7 the staleness mandate ("MANDATORY — overwrite on every
# dispatch / read-then-conditionally-skip") was duplicated across §§1-7
# (~6 sites). §0's design intent (per render-prompt.sh:25-30) is "single
# source of truth … editing rules here lets operators avoid 9-place
# edits in §§1-9." Iter-7 M4 flagged the 6-place duplication as a
# regression of the §0 consolidation: ENG-46/53/57/74 each had to
# swallow the multi-place-edit cost; re-incurring it now is the same
# failure mode.
#
# Post-fix: §0 carries the mandate once; per-stage bullets reference
# rather than re-state it. Allow ≤ 1 occurrence per stage of the legacy
# 'MANDATORY — overwrite on every dispatch' phrase outside §0 (a
# transitional reference is acceptable; full re-statement is not).
_iter7_m4_total="$(grep -c 'MANDATORY — overwrite on every dispatch' "$PROMPTS" || true)"
# §0 itself owns one canonical occurrence; per-stage bullets may leave
# at most one short reference each. Strict pin: total ≤ 2 (§0 + at most
# 1 transitional reference). The pre-fix count is ~7.
if (( _iter7_m4_total <= 2 )); then
  ok "ENG-87 M4-iter7: 'MANDATORY — overwrite on every dispatch' phrase appears ≤2× (hoisted to §0)"
else
  nope "ENG-87 M4-iter7: staleness mandate hoisted to §0" \
    "phrase appears ${_iter7_m4_total}× — pre-iter-7 the mandate was duplicated across §§1-7 (~6 sites); §0 should be the SSOT. Hoist the boilerplate into §0's fenced block; leave one-line per-stage references."
fi
unset _iter7_m4_total

# ─── ENG-87: token-coverage — every `{token}` in AGENT_PROMPTS.md
# must be declared in bin/render-prompt.sh::PROMPT_RESOLVERS. Mirrors
# the render-time validator; defense-in-depth so a token added to
# AGENT_PROMPTS.md without a resolver entry fails fast at content-test
# time (instead of at the next dispatch's render).
RENDER_PROMPT_SH="$HARNESS_ROOT/bin/render-prompt.sh"
if [[ -f "$RENDER_PROMPT_SH" ]]; then
  resolver_tokens="$(awk '
    /^PROMPT_RESOLVERS=/{in_block=1; next}
    in_block && /^[[:space:]]*'"'"'[[:space:]]*$/ {exit}
    in_block {print}
  ' "$RENDER_PROMPT_SH" | awk -F= '/^[a-z_]+=/{print $1}' | sort -u)"
  # Iter-7 C1: AGENT_RUNTIME_TOKENS (space-separated names with leading
  # + trailing spaces) names the tokens delivered to the agent as
  # literal `{name}` text. Drift guard: a token in AGENT_PROMPTS.md
  # must be in PROMPT_RESOLVERS, AGENT_RUNTIME_TOKENS, or the released-
  # only set.
  runtime_tokens="$(awk '/^AGENT_RUNTIME_TOKENS=/{
    gsub(/^[^=]*='\''[ ]*/, "");
    gsub(/[ ]*'\''[ ]*$/, "");
    n=split($0, a, /[ ]+/);
    for (i=1; i<=n; i++) if (a[i] != "") print a[i];
    exit
  }' "$RENDER_PROMPT_SH")"
  prompt_tokens="$(grep -oE '\{[a-z_]+\}' "$PROMPTS" | sed 's/^{//; s/}$//' | sort -u)"
  # Release-stage-only tokens handled by the legacy sed pass in
  # render-prompt.sh::main (they're not in PROMPT_RESOLVERS by design).
  released_only_tokens=$'version\ntag\nprev_tag'
  missing=""
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    if grep -qxF "$tok" <<<"$released_only_tokens"; then
      continue
    fi
    if grep -qxF "$tok" <<<"$runtime_tokens"; then
      continue
    fi
    if ! grep -qxF "$tok" <<<"$resolver_tokens"; then
      missing+="$tok "
    fi
  done <<<"$prompt_tokens"
  if [[ -z "$missing" ]]; then
    ok "ENG-87: every {token} in AGENT_PROMPTS.md is declared in PROMPT_RESOLVERS or AGENT_RUNTIME_TOKENS"
  else
    nope "ENG-87: every {token} in AGENT_PROMPTS.md is declared in PROMPT_RESOLVERS or AGENT_RUNTIME_TOKENS" \
      "missing entry for: $missing — render-prompt.sh would die at dispatch time"
  fi
else
  nope "ENG-87: bin/render-prompt.sh exists for PROMPT_RESOLVERS lookup" \
    "render-prompt.sh missing — token-coverage assert cannot run"
fi

# ─── ENG-101: §3 Self-review + §5 Anti-bias defensive-code restraint ──
# Without these pins, a future "cleanup" pass that strips the §3
# bullet or §5 paragraph would pass every existing assertion (no
# current assertion keys on defensive-code content). The four
# positive-marker pins mirror the ENG-82 §6 / ENG-77 stage-summary
# pin shapes — one assertion per token gives a per-token
# diagnostic on failure.
s3_eng101="$(section_body "## 3. Implementation Agent (Backend)")"
if printf '%s\n' "$s3_eng101" | grep -qF '**Defensive-code restraint:**'; then
  ok "§3 ENG-101: carries '**Defensive-code restraint:**' Self-review bullet header"
else
  nope "§3 ENG-101: carries '**Defensive-code restraint:**' Self-review bullet header" \
       "header missing — implement agent will not self-review for defensive code (ENG-101 D-1)"
fi
if printf '%s\n' "$s3_eng101" | grep -qF 'try/except: pass'; then
  ok "§3 ENG-101: carries 'try/except: pass' AVOID example token"
else
  nope "§3 ENG-101: carries 'try/except: pass' AVOID example token" \
       "example missing — bullet body was gutted while header preserved (ENG-101 D-3 #2)"
fi
if printf '%s\n' "$s3_eng101" | grep -qF 'controllers/'; then
  ok "§3 ENG-101: carries 'controllers/' boundary heuristic token"
else
  nope "§3 ENG-101: carries 'controllers/' boundary heuristic token" \
       "'controllers/' missing — boundary half of heuristic incomplete (ENG-101 D-3 #3)"
fi
if printf '%s\n' "$s3_eng101" | grep -qF 'internal/'; then
  ok "§3 ENG-101: carries 'internal/' boundary heuristic token"
else
  nope "§3 ENG-101: carries 'internal/' boundary heuristic token" \
       "'internal/' missing — internal-site half of heuristic incomplete (ENG-101 D-3 #3)"
fi
unset s3_eng101

s5_eng101="$(section_body "## 5. Review Agent")"
if printf '%s\n' "$s5_eng101" | grep -qF '**Defensive-code restraint:**'; then
  ok "§5 ENG-101: carries '**Defensive-code restraint:**' paragraph header (Anti-bias check)"
else
  nope "§5 ENG-101: carries '**Defensive-code restraint:**' paragraph header (Anti-bias check)" \
       "header missing — review agent will not flag defensive code (ENG-101 D-2)"
fi
# Paragraph-unique [major] anchor — the bare '[major]' token appears
# elsewhere in §5 (review-comment rubric example, severity-token legend),
# so a future downgrade of THIS paragraph's severity would slip past a
# bare grep -qF '[major]'. Anchor on the distinctive prose at the
# paragraph's flag line: 'flag the occurrence as `[major]' is unique to
# the ENG-101 §5 paragraph.
if printf '%s\n' "$s5_eng101" | grep -qF 'flag the occurrence as `[major]'; then
  ok "§5 ENG-101: '[major]' severity bound to the paragraph's flag clause (downgrade-resistant)"
else
  nope "§5 ENG-101: '[major]' severity bound to the paragraph's flag clause (downgrade-resistant)" \
       "paragraph-unique 'flag the occurrence as \`[major]' literal missing — severity may have been silently downgraded to [minor]/[nit] (ENG-101 D-2 / D-3 #4)"
fi
# Body-token pins parallel to §3's controllers/ + internal/ pins above.
# Without these, a future edit could preserve the paragraph header and
# severity prose but gut the boundary body (e.g., delete the (a)/(b)
# clause list), and the assertions above would still pass.
if printf '%s\n' "$s5_eng101" | grep -qF 'controllers/'; then
  ok "§5 ENG-101: carries 'controllers/' boundary path in clause (a)"
else
  nope "§5 ENG-101: carries 'controllers/' boundary path in clause (a)" \
       "'controllers/' missing — clause (a) boundary path list was gutted (ENG-101 D-2)"
fi
if printf '%s\n' "$s5_eng101" | grep -qF 'internal site'; then
  ok "§5 ENG-101: carries 'internal site' descriptor in the flag clause"
else
  nope "§5 ENG-101: carries 'internal site' descriptor in the flag clause" \
       "'internal site' missing — flag-clause body was gutted while header preserved (ENG-101 D-2)"
fi
unset s5_eng101

# ─── ENG-101 QA-adversarial: drift modes NOT in plan's Failure Mode → Test Map ──
# These pins guard against drift the implement-side test-map missed. Each
# anchors on a load-bearing literal that the §3 implementer-rule + §5
# reviewer-rule require to remain in lockstep; cosmetic drift would
# silently weaken or contradict the rule.
s3_eng101_qa="$(section_body "## 3. Implementation Agent (Backend)")"
s5_eng101_qa="$(section_body "## 5. Review Agent")"

# Carve-out drift (test code): without this, the implementer flags
# the harness's own *-test.sh assertions as defensive code and removes
# them; the reviewer flags them at [major].
if printf '%s\n' "$s3_eng101_qa" | grep -qF '*-test.sh'; then
  ok "§3 ENG-101 QA: test-code carve-out anchor '*-test.sh' present"
else
  nope "§3 ENG-101 QA: test-code carve-out anchor '*-test.sh' present" \
       "*-test.sh missing — implement agent will flag test assertions as defensive code (ENG-101 QA-1)"
fi
if printf '%s\n' "$s5_eng101_qa" | grep -qF '*-test.sh'; then
  ok "§5 ENG-101 QA: test-code carve-out anchor '*-test.sh' present"
else
  nope "§5 ENG-101 QA: test-code carve-out anchor '*-test.sh' present" \
       "*-test.sh missing — review agent will flag test assertions as [major] (ENG-101 QA-1)"
fi

# Carve-out drift (idiomatic-propagation): without this, every Go
# `if err != nil { return err }` fires as defensive code, producing
# massive false-positive [major] noise on Go projects.
if printf '%s\n' "$s3_eng101_qa" | grep -qF 'if err != nil { return err }'; then
  ok "§3 ENG-101 QA: idiomatic-propagation carve-out anchor 'if err != nil { return err }' present"
else
  nope "§3 ENG-101 QA: idiomatic-propagation carve-out anchor 'if err != nil { return err }' present" \
       "Go idiom anchor missing — implement agent will treat every Go err-propagate as defensive code (ENG-101 QA-2)"
fi
if printf '%s\n' "$s5_eng101_qa" | grep -qF 'if err != nil { return err }'; then
  ok "§5 ENG-101 QA: idiomatic-propagation carve-out anchor 'if err != nil { return err }' present"
else
  nope "§5 ENG-101 QA: idiomatic-propagation carve-out anchor 'if err != nil { return err }' present" \
       "Go idiom anchor missing — review agent will flag every Go err-propagate at [major] (ENG-101 QA-2)"
fi

# Escape-valve drift: §5 clause (b) cites the literal `Defensive:`
# commit-trailer §3 prescribes. If the trailer literal drifts on either
# side (renamed to Reason:/Justification:/etc.), implementer-reviewer
# alignment breaks silently — every internal-site defensive code fires
# as [major] despite the implementer following §3's escape valve.
if printf '%s\n' "$s3_eng101_qa" | grep -qF 'Defensive: <why this is a real-world reachable failure mode>'; then
  ok "§3 ENG-101 QA: escape-valve commit-trailer 'Defensive: <why ...>' present (§3 implementer side)"
else
  nope "§3 ENG-101 QA: escape-valve commit-trailer 'Defensive: <why ...>' present (§3 implementer side)" \
       "trailer literal drifted — §3's escape valve is unreachable (ENG-101 QA-3)"
fi
# §5 wraps the trailer literal across two lines (line ~1010-1011 of
# AGENT_PROMPTS.md). grep -qF is line-oriented, so pin on the 3-token
# prefix `Defensive: <why` which fits on one line and is still
# distinctive — drift to a different trailer key (Reason:/Justification:)
# or removing the trailer mention from §5 would break this pin.
if printf '%s\n' "$s5_eng101_qa" | grep -qF 'Defensive: <why'; then
  ok "§5 ENG-101 QA: escape-valve commit-trailer prefix 'Defensive: <why' present (§5 reviewer side, clause (b))"
else
  nope "§5 ENG-101 QA: escape-valve commit-trailer prefix 'Defensive: <why' present (§5 reviewer side, clause (b))" \
       "trailer prefix drifted on §5 side — implementer-reviewer alignment broken; every escape fires as [major] (ENG-101 QA-3)"
fi

# System-prompt rule citation drift: both sides quote the rule verbatim.
# Drift to a paraphrase ("Don't write paranoid checks") silently weakens
# the rule's semantic anchor. Pinning the verbatim closing sentence
# guards against paraphrase drift on either side.
if printf '%s\n' "$s3_eng101_qa" | grep -qF 'Only validate at system boundaries.'; then
  ok "§3 ENG-101 QA: system-prompt rule citation verbatim — 'Only validate at system boundaries.' present"
else
  nope "§3 ENG-101 QA: system-prompt rule citation verbatim — 'Only validate at system boundaries.' present" \
       "verbatim rule citation drifted on §3 — semantic anchor weakened (ENG-101 QA-4)"
fi
if printf '%s\n' "$s5_eng101_qa" | grep -qF 'Only validate at system boundaries.'; then
  ok "§5 ENG-101 QA: system-prompt rule citation verbatim — 'Only validate at system boundaries.' present"
else
  nope "§5 ENG-101 QA: system-prompt rule citation verbatim — 'Only validate at system boundaries.' present" \
       "verbatim rule citation drifted on §5 — semantic anchor weakened (ENG-101 QA-4)"
fi

# §5 verdict-comment greppable signal-string: the reviewer is instructed
# to emit `[major] ... — defensive code at internal site; ...` in PR
# comments so retrospective analysis can grep across reviews. The literal
# wraps across lines in AGENT_PROMPTS.md (`defensive\n  code at internal
# site`); pin on `code at internal site` which fits on one line and is
# still unique to this paragraph — drift in the operational hook breaks
# this pin.
if printf '%s\n' "$s5_eng101_qa" | grep -qF 'code at internal site'; then
  ok "§5 ENG-101 QA: verdict-comment signal-string suffix 'code at internal site' present"
else
  nope "§5 ENG-101 QA: verdict-comment signal-string suffix 'code at internal site' present" \
       "signal-string drifted — retrospective grep across reviews loses the operational hook (ENG-101 QA-5)"
fi

unset s3_eng101_qa s5_eng101_qa

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
