#!/usr/bin/env bash
# ENG-87 review-iter-7 Case-87-R6: end-to-end render rc=0 against the
# production AGENT_PROMPTS.md for every dispatch-time stage.
#
# The pre-existing render-prompt-test.sh sources render-prompt.sh and
# tests resolve_block_tokens with synthetic input — it does not exercise
# the full main() path against real AGENT_PROMPTS.md. As a result,
# review-iter-7 C1 stayed silent: `_resolve_passthrough_file` returns
# the literal string `{file}`; the substitution is identity; the
# residual scan re-detects `{file}`; the validator at
# render-prompt.sh::resolve_block_tokens dies with "unresolved token
# after registry pass: {file}". AGENT_PROMPTS.md carries `{file}` in §1
# (around line 341) and `{pr_number}` in §5 (around lines 1010, 1028);
# every brainstorming and reviewing render dies the moment this branch
# is on the operator's main.
#
# This test exec()s `bash bin/render-prompt.sh <stage> ENG-X` with
# stub linear.sh + branch-name.sh on a copied SCRIPT_DIR — same path
# the orchestrator takes at dispatch time. Pre-fix: brainstorming and
# reviewing exit non-zero. Post-fix: every stage exits 0.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()   { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  ❌ %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Sandbox: a copy of bin/render-prompt.sh + bin/common.sh sit alongside
# stub linear.sh + branch-name.sh, plus a symlink to AGENT_PROMPTS.md and
# learned-rules/. render-prompt.sh's `$SCRIPT_DIR` resolves to the copy
# location, so its sibling `bash $SCRIPT_DIR/linear.sh get-issue` lookups
# pick up our stubs.
sandbox="$(mktemp -d -t render-prompt-rc0-test-XXXXXX)"
cleanup() { rm -rf "$sandbox"; }
trap cleanup EXIT

mkdir -p "$sandbox/bin" "$sandbox/target/.pipeline-config"
cat > "$sandbox/target/.pipeline-config/config.json" <<'JSON'
{"linear":{"team_id":"T","project_id":"P","stage_label_prefix":"stage:"},"project":{"slug":"test-slug-rc0"},"orchestrator":{"paused":false}}
JSON

mkdir -p "$sandbox/learned-rules/test-slug-rc0"
cat > "$sandbox/learned-rules/test-slug-rc0/project-profile.md" <<'PROFILE'
---
slug: test-slug-rc0
generated_at: 2026-04-29T00:00:00Z
generated_by: discovery-agent
schema_version: 1
---
# Project profile — Test
## Stack
bash
## Build & test gates
- Build: n/a
- Test: bash
- Lint/check: n/a
- Integration/E2E: n/a
## File layout
- bin
## Language idioms
- snake_case
## Don'ts
none
PROFILE

cp "$HARNESS_ROOT/bin/render-prompt.sh" "$sandbox/bin/"
cp "$HARNESS_ROOT/bin/common.sh"        "$sandbox/bin/"
ln -s "$HARNESS_ROOT/AGENT_PROMPTS.md" "$sandbox/AGENT_PROMPTS.md"

cat > "$sandbox/bin/linear.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  get-issue)
    cat <<'JSON'
{"data":{"issue":{"title":"Test title","description":"Test desc","labels":{"nodes":[]},"state":{"name":"Todo"}}}}
JSON
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$sandbox/bin/linear.sh"

cat > "$sandbox/bin/branch-name.sh" <<'STUB'
#!/usr/bin/env bash
printf 'feat/%s-test-slug-rc0' "$(tr '[:upper:]' '[:lower:]' <<<"${1:-eng-x}")"
STUB
chmod +x "$sandbox/bin/branch-name.sh"

run_render() {
  local stage="$1" rc=0 err
  err="$(mktemp)"
  PIPELINE_DRY_RUN=1 \
    LINEAR_API_KEY=test-mock-key \
    TARGET_REPO="$sandbox/target" \
    PROJECT_SLUG=test-slug-rc0 \
    HARNESS_ROOT="$sandbox" \
    bash "$sandbox/bin/render-prompt.sh" "$stage" ENG-87R6X \
      >/dev/null 2>"$err" || rc=$?
  if (( rc == 0 )); then
    ok "Case-87-R6: bash bin/render-prompt.sh $stage ENG-X exits 0"
  else
    fail "Case-87-R6: bash bin/render-prompt.sh $stage ENG-X exits 0" \
         "rc=$rc stderr-tail: $(tail -3 "$err" | tr '\n' ' ')"
  fi
  rm -f "$err"
}

# Cover every dispatch-time stage. `released` is excluded (cross-issue;
# requires PIPELINE_RELEASE_VERSION/TAG env) and `retrospective` is
# excluded (cross-slug; doesn't fetch issue metadata).
for stage in brainstorming planning implementing ui reviewing qa building; do
  run_render "$stage"
done

# ─── ENG-105 follow-up: {review_findings} token wiring ─────────────────
# Two cases:
#   A. No stage-summary-reviewing.md on disk → resolver emits the
#      "(no prior review …)" sentinel so the prompt's loopback block
#      treats this as a fresh dispatch from planning.
#   B. stage-summary-reviewing.md present → resolver emits its contents
#      verbatim into the implementing prompt body.
#
# Both cases exercise the full main() path through resolve_block_tokens
# (and the residual-token validator) — a regression that drops the
# resolver from PROMPT_RESOLVERS would die with "unresolved token after
# registry pass: {review_findings}".

ISSUE_DIR_A="$sandbox/state/test-slug-rc0/ENG-87R6X-A"
rm -rf "$ISSUE_DIR_A"; mkdir -p "$ISSUE_DIR_A"
out_a="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  PROJECT_STATE_DIR="" \
  bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-A 2>/dev/null || true)"
if grep -q '(no prior review for this issue' <<<"$out_a"; then
  ok "ENG-105 case A: absent reviewing summary → '(no prior review …)' sentinel"
else
  fail "ENG-105 case A: absent reviewing summary → sentinel" \
       "out tail: $(tail -3 <<<"$out_a" | tr '\n' ' ')"
fi

ISSUE_DIR_B="$sandbox/state/test-slug-rc0/ENG-87R6X-B"
rm -rf "$ISSUE_DIR_B"; mkdir -p "$ISSUE_DIR_B"
REVIEW_SENTINEL='SENTINEL-REVIEW-BODY-LINE-FROM-FIXTURE-B-7821'
printf '## Review summary\n\n[major] %s\n' "$REVIEW_SENTINEL" \
  > "$ISSUE_DIR_B/stage-summary-reviewing.md"
out_b="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  PROJECT_STATE_DIR="" \
  bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-B 2>/dev/null || true)"
if grep -qF "$REVIEW_SENTINEL" <<<"$out_b"; then
  ok "ENG-105 case B: present reviewing summary → inlined verbatim in implementing prompt"
else
  fail "ENG-105 case B: present reviewing summary inlined" \
       "out tail: $(tail -5 <<<"$out_b" | tr '\n' ' ')"
fi

# ─── ENG-108: {progress_md_path} token wiring (implement reader pilot) ───
# Two cases (mirror of the ENG-105 pair above):
#   C. No progress.md exists in the per-issue state dir → render-prompt's
#      stage-conditional log fires with `progress-md missing` to stderr;
#      stdout still carries the resolved absolute path (the agent will
#      Read-fail at runtime per D-003).
#   D. progress.md present with a sentinel entry → no `progress-md
#      missing` log fires; stdout still carries the resolved absolute
#      path (the agent will Read it at runtime).
# Both cases exercise the full main() path through the new
# _RENDER_PROGRESS_MD_PATH binding, the new info-log condition, and the
# resolve_block_tokens registry pass. A regression that drops
# progress_md_path from PROMPT_RESOLVERS would die at the registry
# validator with "unresolved token after registry pass: {progress_md_path}".

ISSUE_DIR_C="$sandbox/state/test-slug-rc0/ENG-87R6X-C"
rm -rf "$ISSUE_DIR_C"
err_c="$(mktemp)"
out_c="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-C 2>"$err_c" || true)"
if grep -qF "$ISSUE_DIR_C/progress.md" <<<"$out_c"; then
  ok "ENG-108 case C: absent progress.md → resolved absolute path appears in implementing prompt body"
else
  fail "ENG-108 case C: absent progress.md → resolved absolute path in prompt body" \
       "stdout tail: $(tail -3 <<<"$out_c" | tr '\n' ' ')"
fi
if grep -qF 'progress-md missing' "$err_c"; then
  ok "ENG-108 case C: absent progress.md → stderr carries 'progress-md missing' info-log"
else
  fail "ENG-108 case C: absent progress.md → 'progress-md missing' info-log on stderr" \
       "stderr tail: $(tail -3 "$err_c" | tr '\n' ' ')"
fi
rm -f "$err_c"

ISSUE_DIR_D="$sandbox/state/test-slug-rc0/ENG-87R6X-D"
rm -rf "$ISSUE_DIR_D"; mkdir -p "$ISSUE_DIR_D"
PROGRESS_SENTINEL='SENTINEL-PROGRESS-MD-ENTRY-FROM-FIXTURE-D-9143'
printf '## ENG-87R6X-D-d0001 - planning - 2026-05-16T12:34:56Z\n\n%s\n' "$PROGRESS_SENTINEL" \
  > "$ISSUE_DIR_D/progress.md"
err_d="$(mktemp)"
out_d="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-D 2>"$err_d" || true)"
if grep -qF "$ISSUE_DIR_D/progress.md" <<<"$out_d"; then
  ok "ENG-108 case D: present progress.md → resolved absolute path appears in implementing prompt body"
else
  fail "ENG-108 case D: present progress.md → resolved absolute path in prompt body" \
       "stdout tail: $(tail -3 <<<"$out_d" | tr '\n' ' ')"
fi
if grep -qF 'progress-md missing' "$err_d"; then
  fail "ENG-108 case D: present progress.md → NO 'progress-md missing' info-log" \
       "stderr unexpectedly contained 'progress-md missing': $(tail -3 "$err_d" | tr '\n' ' ')"
else
  ok "ENG-108 case D: present progress.md → no 'progress-md missing' info-log on stderr"
fi
rm -f "$err_d"

# ─── ENG-108 QA adversarial: stage-scoping + zero-byte edge cases ───
# E. Non-implementing stage (qa) with absent progress.md → info-log must
#    NOT fire. The condition is `stage == "implementing"` — any other stage
#    render should produce zero `progress-md missing` lines even when the
#    file is absent.
# F. Zero-byte progress.md on implementing stage → info-log must NOT fire.
#    The predicate is `! -e` (file-exists test), not `! -s` (non-empty test).
#    A zero-byte file is `-e`-true; a future refactor to `! -s` would silently
#    change semantics and break this case.

ISSUE_DIR_E="$sandbox/state/test-slug-rc0/ENG-87R6X-E"
rm -rf "$ISSUE_DIR_E"
err_e="$(mktemp)"
PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  bash "$sandbox/bin/render-prompt.sh" qa ENG-87R6X-E >/dev/null 2>"$err_e" || true
if grep -qF 'progress-md missing' "$err_e"; then
  fail "ENG-108 case E: qa stage + absent progress.md → NO 'progress-md missing' info-log" \
       "stderr unexpectedly contained 'progress-md missing': $(tail -3 "$err_e" | tr '\n' ' ')"
else
  ok "ENG-108 case E: qa stage + absent progress.md → no 'progress-md missing' info-log (stage-scoping)"
fi
rm -f "$err_e"

ISSUE_DIR_F="$sandbox/state/test-slug-rc0/ENG-87R6X-F"
rm -rf "$ISSUE_DIR_F"; mkdir -p "$ISSUE_DIR_F"
: > "$ISSUE_DIR_F/progress.md"  # zero-byte file
err_f="$(mktemp)"
out_f="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-F 2>"$err_f" || true)"
if grep -qF "$ISSUE_DIR_F/progress.md" <<<"$out_f"; then
  ok "ENG-108 case F: zero-byte progress.md → resolved absolute path appears in implementing prompt"
else
  fail "ENG-108 case F: zero-byte progress.md → resolved absolute path in prompt body" \
       "stdout tail: $(tail -3 <<<"$out_f" | tr '\n' ' ')"
fi
if grep -qF 'progress-md missing' "$err_f"; then
  fail "ENG-108 case F: zero-byte progress.md → NO 'progress-md missing' info-log (! -e, not ! -s)" \
       "stderr unexpectedly contained 'progress-md missing': $(tail -3 "$err_f" | tr '\n' ' ')"
else
  ok "ENG-108 case F: zero-byte progress.md → no 'progress-md missing' info-log (! -e predicate)"
fi
rm -f "$err_f"

# ─── ENG-139-follow-up: review_findings is loopback-source-gated ────────
# Today's _resolve_review_findings emits the file's content whenever
# stage-summary-reviewing.md is non-empty. That file persists across
# non-current-stage clears (by design — forward + loopback reads need
# it), so once any reviewing dispatch has fired on the issue, every
# subsequent implementing dispatch sees stale review findings — even on
# building → implementing rebase loopbacks and qa → implementing fail
# loopbacks, where the implementer should be doing a different shape of
# work (rebase / bugfix) and being told "address the prior reviewer's
# findings" is incorrect.
#
# Fix: PIPELINE_LOOPBACK_SOURCE env var declares which stage's
# from-transition put us into implementing. The resolver gates on it:
#
#   - PIPELINE_LOOPBACK_SOURCE=reviewing → file content (review-loopback).
#   - PIPELINE_LOOPBACK_SOURCE=building  → sentinel (rebase or CI-red loop).
#   - PIPELINE_LOOPBACK_SOURCE=qa        → sentinel (qa fail loopback).
#   - PIPELINE_LOOPBACK_SOURCE=planning  → sentinel (fresh forward).
#   - PIPELINE_LOOPBACK_SOURCE unset     → back-compat (file content if file
#       is non-empty). Preserves behavior for callers outside run-stage.sh
#       (debug renders, dry-run.sh) that haven't been updated to set the
#       env var. Production opt-in: run-stage.sh sets it on every
#       implementing dispatch.
#
# Cases G–J reuse the case-B fixture path; the sentinel file IS present.
# The four cases differ only in PIPELINE_LOOPBACK_SOURCE.

ISSUE_DIR_G="$sandbox/state/test-slug-rc0/ENG-87R6X-G"
rm -rf "$ISSUE_DIR_G"; mkdir -p "$ISSUE_DIR_G"
LB_SENTINEL='SENTINEL-REVIEW-FINDINGS-LOOPBACK-GATE-CASE-G-9281'
printf '## Review summary\n\n[major] %s\n' "$LB_SENTINEL" \
  > "$ISSUE_DIR_G/stage-summary-reviewing.md"

# Case G: source=reviewing → findings inlined (positive control).
out_g="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  PIPELINE_LOOPBACK_SOURCE=reviewing \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-G 2>/dev/null || true)"
if grep -qF "$LB_SENTINEL" <<<"$out_g"; then
  ok "ENG-139 case G: PIPELINE_LOOPBACK_SOURCE=reviewing + file present → findings inlined"
else
  fail "ENG-139 case G: source=reviewing → findings inlined" \
       "out tail: $(tail -5 <<<"$out_g" | tr '\n' ' ')"
fi

ISSUE_DIR_H="$sandbox/state/test-slug-rc0/ENG-87R6X-H"
rm -rf "$ISSUE_DIR_H"; mkdir -p "$ISSUE_DIR_H"
printf '## Review summary\n\n[major] %s\n' "$LB_SENTINEL" \
  > "$ISSUE_DIR_H/stage-summary-reviewing.md"

# Case H: source=building → sentinel (the ENG-106 / ENG-139 failure mode).
out_h="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  PIPELINE_LOOPBACK_SOURCE=building \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-H 2>/dev/null || true)"
if grep -qF "$LB_SENTINEL" <<<"$out_h"; then
  fail "ENG-139 case H: source=building → sentinel (NOT findings)" \
       "stale review findings leaked into build-loopback dispatch — out tail: $(tail -5 <<<"$out_h" | tr '\n' ' ')"
else
  ok "ENG-139 case H: PIPELINE_LOOPBACK_SOURCE=building + file present → sentinel (no stale review-findings leak)"
fi
# Note: we deliberately do NOT also assert the literal sentinel string is
# present in $out_h — AGENT_PROMPTS.md's prose quotes the literal sentinel
# (as documentation of the off-switch), which would make any such grep
# always-true and mask a regression where the resolver returns empty.

ISSUE_DIR_I="$sandbox/state/test-slug-rc0/ENG-87R6X-I"
rm -rf "$ISSUE_DIR_I"; mkdir -p "$ISSUE_DIR_I"
printf '## Review summary\n\n[major] %s\n' "$LB_SENTINEL" \
  > "$ISSUE_DIR_I/stage-summary-reviewing.md"

# Case I: source=qa → sentinel (qa-loopback should not see stale review).
out_i="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  PIPELINE_LOOPBACK_SOURCE=qa \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-I 2>/dev/null || true)"
if grep -qF "$LB_SENTINEL" <<<"$out_i"; then
  fail "ENG-139 case I: source=qa → sentinel (NOT findings)" \
       "stale review findings leaked into qa-loopback dispatch — out tail: $(tail -5 <<<"$out_i" | tr '\n' ' ')"
else
  ok "ENG-139 case I: PIPELINE_LOOPBACK_SOURCE=qa + file present → sentinel"
fi

ISSUE_DIR_J="$sandbox/state/test-slug-rc0/ENG-87R6X-J"
rm -rf "$ISSUE_DIR_J"; mkdir -p "$ISSUE_DIR_J"
printf '## Review summary\n\n[major] %s\n' "$LB_SENTINEL" \
  > "$ISSUE_DIR_J/stage-summary-reviewing.md"

# Case J: source=planning → sentinel (forward-from-planning).
out_j="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  PIPELINE_LOOPBACK_SOURCE=planning \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-J 2>/dev/null || true)"
if grep -qF "$LB_SENTINEL" <<<"$out_j"; then
  fail "ENG-139 case J: source=planning → sentinel (NOT findings)" \
       "stale review findings leaked into fresh-from-planning dispatch — out tail: $(tail -5 <<<"$out_j" | tr '\n' ' ')"
else
  ok "ENG-139 case J: PIPELINE_LOOPBACK_SOURCE=planning + file present → sentinel"
fi

# Case K: source UNSET, file present → findings inlined (back-compat).
# Preserves case-B semantics so debug renders + dry-run.sh + any caller
# that hasn't been updated to set PIPELINE_LOOPBACK_SOURCE keeps seeing
# the file content.
ISSUE_DIR_K="$sandbox/state/test-slug-rc0/ENG-87R6X-K"
rm -rf "$ISSUE_DIR_K"; mkdir -p "$ISSUE_DIR_K"
printf '## Review summary\n\n[major] %s\n' "$LB_SENTINEL" \
  > "$ISSUE_DIR_K/stage-summary-reviewing.md"
out_k="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-K 2>/dev/null || true)"
if grep -qF "$LB_SENTINEL" <<<"$out_k"; then
  ok "ENG-139 case K: PIPELINE_LOOPBACK_SOURCE unset + file present → findings inlined (back-compat)"
else
  fail "ENG-139 case K: source unset → findings inlined (back-compat)" \
       "out tail: $(tail -5 <<<"$out_k" | tr '\n' ' ')"
fi

# ─── ENG-140 cases L/M/N: {qa_findings} loopback-gate coverage ───
# Mirror cases G/H/I exactly with the qa-loopback substitutions:
#   stage-summary-reviewing.md → stage-summary-qa.md
#   PIPELINE_LOOPBACK_SOURCE=reviewing → =qa
# Each case uses a DISTINCT literal sentinel injected into the fixture
# file so prose quotes of the sentinel in AGENT_PROMPTS.md §3 cannot
# make a presence-of-sentinel grep always-true (see cases H/I caveat).

# Case L: source=qa + qa-file present → findings inlined (positive control).
ISSUE_DIR_L="$sandbox/state/test-slug-rc0/ENG-87R6X-L"
rm -rf "$ISSUE_DIR_L"; mkdir -p "$ISSUE_DIR_L"
QA_SENTINEL_L='SENTINEL-QA-FINDINGS-LOOPBACK-GATE-CASE-L-9281'
printf '## QA summary\n\nP0 %s\n' "$QA_SENTINEL_L" \
  > "$ISSUE_DIR_L/stage-summary-qa.md"
# Regression-intent (AC-2): a stage-summary-reviewing.md ALSO present
# under source=qa must NOT leak into the rendered prompt — verifies
# the existing _resolve_review_findings gate (5ebae80) still works.
REGRESSION_SENTINEL_L='SENTINEL-REVIEW-FINDINGS-CASE-L-REGRESSION-9281'
printf '## Review summary\n\n[major] %s\n' "$REGRESSION_SENTINEL_L" \
  > "$ISSUE_DIR_L/stage-summary-reviewing.md"
out_l="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  PIPELINE_LOOPBACK_SOURCE=qa \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-L 2>/dev/null || true)"
if grep -qF "$QA_SENTINEL_L" <<<"$out_l"; then
  ok "ENG-140 case L: PIPELINE_LOOPBACK_SOURCE=qa + stage-summary-qa.md present → findings inlined"
else
  fail "ENG-140 case L: source=qa → findings inlined" \
       "out tail: $(tail -5 <<<"$out_l" | tr '\n' ' ')"
fi
if grep -qF "$REGRESSION_SENTINEL_L" <<<"$out_l"; then
  fail "ENG-140 case L regression: PIPELINE_LOOPBACK_SOURCE=qa does NOT leak stale review-findings (5ebae80)" \
       "stale review-findings leaked into qa-loopback dispatch — out tail: $(tail -5 <<<"$out_l" | tr '\n' ' ')"
else
  ok "ENG-140 case L regression: PIPELINE_LOOPBACK_SOURCE=qa does NOT leak stale review-findings (5ebae80 still gates correctly)"
fi

# Case M: source=building + qa-file present → sentinel (the build-loopback no-leak case).
ISSUE_DIR_M="$sandbox/state/test-slug-rc0/ENG-87R6X-M"
rm -rf "$ISSUE_DIR_M"; mkdir -p "$ISSUE_DIR_M"
QA_SENTINEL_M='SENTINEL-QA-FINDINGS-LOOPBACK-GATE-CASE-M-9281'
printf '## QA summary\n\nP0 %s\n' "$QA_SENTINEL_M" \
  > "$ISSUE_DIR_M/stage-summary-qa.md"
out_m="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  PIPELINE_LOOPBACK_SOURCE=building \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-M 2>/dev/null || true)"
if grep -qF "$QA_SENTINEL_M" <<<"$out_m"; then
  fail "ENG-140 case M: source=building → sentinel (NOT findings)" \
       "stale qa findings leaked into build-loopback dispatch — out tail: $(tail -5 <<<"$out_m" | tr '\n' ' ')"
else
  ok "ENG-140 case M: PIPELINE_LOOPBACK_SOURCE=building + qa-file present → sentinel (no stale qa-findings leak)"
fi
# Note: we deliberately do NOT also assert the literal sentinel string is
# present in $out_m — AGENT_PROMPTS.md's prose quotes the literal sentinel
# (as documentation of the off-switch), which would make any such grep
# always-true and mask a regression where the resolver returns empty.

# Case N: source=reviewing + qa-file present → sentinel (the review-loopback no-leak case).
ISSUE_DIR_N="$sandbox/state/test-slug-rc0/ENG-87R6X-N"
rm -rf "$ISSUE_DIR_N"; mkdir -p "$ISSUE_DIR_N"
QA_SENTINEL_N='SENTINEL-QA-FINDINGS-LOOPBACK-GATE-CASE-N-9281'
printf '## QA summary\n\nP0 %s\n' "$QA_SENTINEL_N" \
  > "$ISSUE_DIR_N/stage-summary-qa.md"
out_n="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  PIPELINE_LOOPBACK_SOURCE=reviewing \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-N 2>/dev/null || true)"
if grep -qF "$QA_SENTINEL_N" <<<"$out_n"; then
  fail "ENG-140 case N: source=reviewing → sentinel (NOT findings)" \
       "stale qa findings leaked into review-loopback dispatch — out tail: $(tail -5 <<<"$out_n" | tr '\n' ' ')"
else
  ok "ENG-140 case N: PIPELINE_LOOPBACK_SOURCE=reviewing + qa-file present → sentinel (no stale qa-findings leak)"
fi

# ─── ENG-113 case O: {qa_predicate_path} resolves on a qa-stage render ────
# The §6 prompt body carries the literal token {qa_predicate_path}, and
# render-prompt.sh::PROMPT_RESOLVERS registers `qa_predicate_path` →
# `_resolve_qa_predicate_path`. main() binds _RENDER_QA_PREDICATE_PATH via
# common.sh::qa_predicate_path(issue_id). After resolution, the rendered
# prompt MUST contain the full absolute-path shape `<issue-dir>/qa-predicate-<ISSUE>.json`
# — basename-only would pass even if a regression dropped the directory
# prefix and emitted just the filename (broken authority surface).
ISSUE_DIR_O="$sandbox/state/test-slug-rc0/ENG-87R6X-O"
rm -rf "$ISSUE_DIR_O"; mkdir -p "$ISSUE_DIR_O"
out_o="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  bash "$sandbox/bin/render-prompt.sh" qa ENG-87R6X-O 2>/dev/null || true)"
EXPECTED_O="$sandbox/state/test-slug-rc0/ENG-87R6X-O/qa-predicate-ENG-87R6X-O.json"
if grep -qF "$EXPECTED_O" <<<"$out_o"; then
  ok "ENG-113 case O: {qa_predicate_path} resolves to $EXPECTED_O on qa-stage render"
else
  fail "ENG-113 case O: {qa_predicate_path} resolves on qa-stage render" \
       "expected absolute-path substring '$EXPECTED_O' missing from rendered prompt — out tail: $(tail -10 <<<"$out_o" | tr '\n' ' ')"
fi

printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
