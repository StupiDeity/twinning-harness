#!/usr/bin/env bash
# Tests for bin/render-prompt.sh::append_project_profile.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2"; }

sandbox="$(mktemp -d -t render-prompt-test-XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT

mkdir -p "$sandbox/harness/learned-rules/test-slug" "$sandbox/target/.pipeline-config"
cat > "$sandbox/target/.pipeline-config/config.json" <<'JSON'
{"linear":{"team_id":"T","project_id":"P"},"project":{"slug":"test-slug"},"orchestrator":{"paused":false}}
JSON

cat > "$sandbox/harness/learned-rules/test-slug/project-profile.md" <<'PROFILE'
---
slug: test-slug
generated_at: 2026-04-27T00:00:00Z
generated_by: discovery-agent
schema_version: 1
---

# Project profile — Test

## Stack
bash.

## Build & test gates
- Build: `(n/a)`
- Test: `bash bin/foo-test.sh`
- Lint/check: `(n/a)`
- Integration/E2E: `(n/a)`

## File layout
- `bin/` — scripts.

## Language idioms
- snake_case.

## Don'ts
(none observed)
PROFILE

# Source render-prompt.sh in a subshell to get the function in scope.
# The script's `main` is sentinel-guarded.
src_with_env() {
  local stage="$1" addendum_flag="$2"
  (
    set +e
    export TARGET_REPO="$sandbox/target"
    export PIPELINE_PROFILE_ADDENDUM="$addendum_flag"
    export PROJECT_SLUG="test-slug"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/common.sh"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/render-prompt.sh"
    # render-prompt.sh re-sources common.sh, which recomputes HARNESS_ROOT
    # from common.sh's own location. Override AFTER both sources so the
    # function sees our sandbox path.
    export HARNESS_ROOT="$sandbox/harness"
    set -e
    printf 'BASE PROMPT BODY\n' | append_project_profile "$stage"
  )
}

# Case 6.1: addendum default-on, profile present → output contains addendum heading
out="$(src_with_env brainstorm 1 2>/dev/null)"
if grep -q 'Project profile (addendum)' <<<"$out" && grep -q '## Stack' <<<"$out"; then
  pass_at "case-6.1: profile appended for non-retrospective stage"
else
  fail_at "case-6.1: profile appended for non-retrospective stage" "out=$out"
fi

# Case 6.2: addendum default-on with no flag set → addendum still applies
out="$(src_with_env brainstorm '' 2>/dev/null)"
if grep -q 'Project profile (addendum)' <<<"$out"; then
  pass_at "case-6.2: addendum applies by default (no flag set)"
else
  fail_at "case-6.2: addendum applies by default (no flag set)" "out=$out"
fi

# Case 6.3: retrospective stage → no addendum
out="$(src_with_env retrospective 1 2>/dev/null)"
if [[ "$out" == "BASE PROMPT BODY" ]]; then
  pass_at "case-6.3: retrospective stage skips addendum"
else
  fail_at "case-6.3: retrospective stage skips addendum" "out=$out"
fi

# Case 6.4: missing profile → die
rm -f "$sandbox/harness/learned-rules/test-slug/project-profile.md"
if src_with_env brainstorm 1 >/dev/null 2>&1; then
  fail_at "case-6.4: missing profile dies" "returned 0"
else
  pass_at "case-6.4: missing profile dies"
fi

# Restore profile and add a marker
cat > "$sandbox/harness/learned-rules/test-slug/project-profile.md" <<'PROFILE'
---
slug: test-slug
generated_at: 2026-04-27T00:00:00Z
generated_by: discovery-agent
schema_version: 1
---

# Project profile — Test

## Stack
<<NEEDS-INPUT: what?>>

## Build & test gates
## File layout
## Language idioms
## Don'ts
PROFILE

# Case 6.5: profile with markers → die
if src_with_env brainstorm 1 >/dev/null 2>&1; then
  fail_at "case-6.5: marker-bearing profile dies" "returned 0"
else
  pass_at "case-6.5: marker-bearing profile dies"
fi

# ─── ENG-79: render-prompt.sh sources branch-name.sh; no `feature/` literal ──
# ENG-74 (May 2026) demonstrated the failure mode: a build-stage agent ran
# `gh pr list --head feature/eng-74-…` from the prompt's interpolated
# `{branch_name}` value, got an empty result because the actual branch is
# `feat/eng-74-…`, and emitted `verdict halt reason=agent-blocked` for P1.
# Root cause: render-prompt.sh:212 hand-rolled
# `branch_name="feature/${issue_id_lower}-${slug}"` while the canonical
# resolver bin/branch-name.sh emits `feat/eng-N-…`.
#
# Pin: render-prompt.sh MUST source branch-name.sh to resolve the canonical
# name, and MUST NOT carry a `feature/${issue_id_lower}` literal.
RP_SRC="$SCRIPT_DIR/render-prompt.sh"

if grep -qE 'bash[^|]*"\$SCRIPT_DIR/branch-name\.sh"[[:space:]]+"\$issue_id"' "$RP_SRC"; then
  pass_at 'ENG-79: render-prompt.sh resolves branch_name via bin/branch-name.sh'
else
  fail_at 'ENG-79: render-prompt.sh resolves branch_name via bin/branch-name.sh' \
    'no `bash $SCRIPT_DIR/branch-name.sh "$issue_id"` invocation found'
fi

if grep -qF 'feature/${issue_id_lower}' "$RP_SRC"; then
  fail_at 'ENG-79: render-prompt.sh has no `feature/${issue_id_lower}` literal' \
    'pre-ENG-79 hand-rolled form is back'
else
  pass_at 'ENG-79: render-prompt.sh has no `feature/${issue_id_lower}` literal'
fi

# ─── ENG-87: PROMPT_RESOLVERS registry + render-time validator ─────────
# Replaces ENG-79's hand-rolled python interpolation with a resolver
# table at render-prompt.sh's top + a render-time die() on unknown
# tokens. Tests source render-prompt.sh into a subshell directly so the
# resolver functions (defined in render-prompt.sh) are in scope without
# the bash -c re-process boundary.

# Restore the project profile so render-prompt's append_project_profile
# does not die. Required because case-6.4/6.5 above mutate it.
mkdir -p "$sandbox/harness/learned-rules/test-slug"
cat > "$sandbox/harness/learned-rules/test-slug/project-profile.md" <<'PROFILE'
---
slug: test-slug
generated_at: 2026-04-27T00:00:00Z
generated_by: discovery-agent
schema_version: 1
---

# Project profile — Test

## Stack
bash.
PROFILE

# Helper: run a body inside a subshell with common.sh + render-prompt.sh
# sourced, the sandbox env in place, and resolver-side globals
# pre-populated. The body comes via heredoc on stdin (eval).
run_resolver_body() {
  local body="$1"
  (
    set +e
    export TARGET_REPO="$sandbox/target"
    export PROJECT_SLUG="test-slug"
    export HARNESS_ROOT="$sandbox/harness"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/common.sh"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/render-prompt.sh"
    eval "$body"
  )
}

# Case 87-R1: every existing token in PROMPT_RESOLVERS resolves cleanly.
out="$(run_resolver_body '
  _RENDER_ISSUE_ID="ENG-87R1"
  _RENDER_ISSUE_ID_LOWER="eng-87r1"
  _RENDER_TITLE="Test title"
  _RENDER_DESCRIPTION="Test description"
  _RENDER_DATE="2026-05-09"
  _RENDER_SLUG="test-slug"
  _RENDER_BRAINSTORM_FILE="docs/brainstorms/foo.md"
  _RENDER_PLAN_FILE="docs/plans/foo.md"
  _RENDER_BRANCH_NAME="feat/eng-87r1-foo"
  _RENDER_STAGE_SUMMARY_PATH="/tmp/state/ENG-87R1/stage-summary-implementing.md"
  _RENDER_LEARNED_RULES_DIR="/tmp/harness/learned-rules/test-slug"
  _RENDER_DISPATCH_ID="ENG-87R1-d0042"
  resolve_block_tokens "{issue_id} {issue_id_lower} {issue_title} {date} {slug} {branch_name} {dispatch_id}"
' 2>&1)"
expected="ENG-87R1 eng-87r1 Test title 2026-05-09 test-slug feat/eng-87r1-foo ENG-87R1-d0042"
if [[ "$out" == "$expected" ]]; then
  pass_at "ENG-87 R1: every PROMPT_RESOLVERS token resolves cleanly"
else
  fail_at "ENG-87 R1: every token resolves" "expected='$expected' got='$out'"
fi

# Case 87-R2: unknown {token} dies with token name in message.
err="$(run_resolver_body '
  resolve_block_tokens "Hello {nonexistent_token_xyz} world" 2>&1
  printf "post-die-marker"
' 2>&1 || true)"
if grep -qF 'unknown token' <<<"$err" && grep -qF 'nonexistent_token_xyz' <<<"$err" \
   && ! grep -qF 'post-die-marker' <<<"$err"; then
  pass_at "ENG-87 R2: unknown {token} dies (token name in message; control flow halts)"
else
  fail_at "ENG-87 R2: unknown token dies" "err=$err"
fi

# Case 87-R3: {dispatch_id} interpolates from _RENDER_DISPATCH_ID
# (post-iter-7 M9 — resolver reads the _RENDER_* global, no longer
# ambient $PIPELINE_DISPATCH_ID).
out="$(run_resolver_body '
  _RENDER_DISPATCH_ID="ENG-87R3-d0042"
  resolve_block_tokens "id={dispatch_id}"
' 2>&1)"
if [[ "$out" == "id=ENG-87R3-d0042" ]]; then
  pass_at "ENG-87 R3: {dispatch_id} interpolates from \$_RENDER_DISPATCH_ID"
else
  fail_at "ENG-87 R3: {dispatch_id} interpolation" "out=$out"
fi

# Case 87-R4: {dispatch_id} resolves to empty when _RENDER_DISPATCH_ID
# is unset (acceptable per resolver contract — release stage / direct-
# dispatch test paths).
out="$(run_resolver_body '
  unset _RENDER_DISPATCH_ID
  resolve_block_tokens "id={dispatch_id}|end"
' 2>&1)"
if [[ "$out" == "id=|end" ]]; then
  pass_at "ENG-87 R4: {dispatch_id} → empty when _RENDER_DISPATCH_ID unset (allowed by contract)"
else
  fail_at "ENG-87 R4: {dispatch_id} empty-env" "out=$out"
fi

# Case 87-R5: PROMPT_RESOLVERS registry covers every {token} in
# AGENT_PROMPTS.md, EXCEPT for the released-only legacy-sed tokens and
# the AGENT_RUNTIME_TOKENS allowlist (post-iter-7 C1 — agent-runtime
# tokens are intentionally delivered as literal `{name}` text). Drift
# guard — if a new token enters the source without a registered
# resolver AND without an AGENT_RUNTIME_TOKENS entry, this test catches
# it before the orchestrator's render-time validator fires at dispatch
# time.
agent_prompts_tokens="$(grep -oE '\{[a-z_]+\}' "$SCRIPT_DIR/../AGENT_PROMPTS.md" | sort -u)"
registry_tokens="$(awk '/^PROMPT_RESOLVERS=/{flag=1; next} /^'"'"'$/ && flag {flag=0} flag' "$RP_SRC" \
  | grep -oE '^[a-z_]+=' | sed 's/=$//')"
# Released-stage-only tokens (handled by the legacy-sed pass in main()).
released_tokens=$'{version}\n{tag}\n{prev_tag}'
# AGENT_RUNTIME_TOKENS entries are space-separated with leading + trailing
# spaces. Extract the names into a newline list.
runtime_tokens="$(awk '/^AGENT_RUNTIME_TOKENS=/{
  gsub(/^[^=]*='\''[ ]*/, "");
  gsub(/[ ]*'\''[ ]*$/, "");
  n=split($0, a, /[ ]+/);
  for (i=1; i<=n; i++) if (a[i] != "") printf "{%s}\n", a[i];
  exit
}' "$RP_SRC")"
missing_tokens=""
while IFS= read -r tok; do
  [[ -z "$tok" ]] && continue
  if grep -qFx "$tok" <<<"$released_tokens"; then
    continue
  fi
  if grep -qFx "$tok" <<<"$runtime_tokens"; then
    continue
  fi
  name="${tok#\{}"; name="${name%\}}"
  if ! grep -qFx "$name" <<<"$registry_tokens"; then
    missing_tokens+="$tok "
  fi
done <<<"$agent_prompts_tokens"
if [[ -z "$missing_tokens" ]]; then
  pass_at "ENG-87 R5: every {token} in AGENT_PROMPTS.md has a resolver, an AGENT_RUNTIME_TOKENS entry, or is released-only"
else
  fail_at "ENG-87 R5: token coverage" "missing resolvers: $missing_tokens"
fi

# ─── ENG-87 review-iter-7 M9: _resolve_dispatch_id reads _RENDER_DISPATCH_ID ──
# Iter-7 M9 finding: _resolve_dispatch_id at render-prompt.sh:209-211
# reads `${PIPELINE_DISPATCH_ID-}` directly while every other resolver
# reads its `_RENDER_*` global (lines 198-208). Test isolation requires
# `export PIPELINE_DISPATCH_ID` rather than `_RENDER_DISPATCH_ID=...` —
# divergent pattern within the same registry. Post-fix: bind
# `_RENDER_DISPATCH_ID="${PIPELINE_DISPATCH_ID-}"` in main() at the
# resolver-side seeding stanza; have _resolve_dispatch_id read
# _RENDER_DISPATCH_ID like its siblings.
printf '\n--- ENG-87 R7: _resolve_dispatch_id reads _RENDER_DISPATCH_ID ---\n'

# Source pin: the resolver's body should read $_RENDER_DISPATCH_ID,
# not ambient $PIPELINE_DISPATCH_ID. Use awk to extract just the
# resolver function body and grep that.
_iter7_r7_body="$(awk '/^_resolve_dispatch_id\(\)/{flag=1} flag{print; if(/^}$/){exit}}' "$RP_SRC")"
if printf '%s' "$_iter7_r7_body" | grep -qF '_RENDER_DISPATCH_ID'; then
  pass_at "ENG-87 R7: _resolve_dispatch_id reads _RENDER_DISPATCH_ID (consistent with sibling resolvers)"
else
  fail_at "ENG-87 R7: _resolve_dispatch_id reads _RENDER_DISPATCH_ID" \
    "function body does not reference _RENDER_DISPATCH_ID — divergent from issue_id/title/etc. resolvers. Bind _RENDER_DISPATCH_ID in main() and read it here."
fi

# Behavioral pin: _RENDER_DISPATCH_ID set, PIPELINE_DISPATCH_ID unset →
# resolver returns the _RENDER_DISPATCH_ID value. Pre-fix: returns "".
out="$(run_resolver_body '
  _RENDER_DISPATCH_ID="ENG-87R7-d0042"
  unset PIPELINE_DISPATCH_ID
  resolve_block_tokens "id={dispatch_id}"
' 2>&1)"
if [[ "$out" == "id=ENG-87R7-d0042" ]]; then
  pass_at "ENG-87 R7-behavioral: _RENDER_DISPATCH_ID populates {dispatch_id}"
else
  fail_at "ENG-87 R7-behavioral: _RENDER_DISPATCH_ID populates {dispatch_id}" \
    "expected 'id=ENG-87R7-d0042', got '$out' — resolver is reading ambient PIPELINE_DISPATCH_ID, not _RENDER_DISPATCH_ID"
fi
unset _iter7_r7_body out

# ─── ENG-87 review-iter-7 C1 fix: AGENT_RUNTIME_TOKENS skip-set ──
# Pre-fix: _resolve_passthrough_file / _resolve_passthrough_pr_number
# returned the literal {token} string; the bash literal substitution
# was identity; the residual scan re-detected the token; the validator
# died. Post-fix: render-prompt.sh defines an AGENT_RUNTIME_TOKENS set
# (or equivalent) listing tokens that are agent-runtime placeholders;
# resolve_block_tokens excludes those tokens from the residual check
# AND removes the no-op _resolve_passthrough_* shims. Pin source-level.
printf '\n--- ENG-87 R8: AGENT_RUNTIME_TOKENS skip-set + no passthrough shim ---\n'

if grep -qE 'AGENT_RUNTIME_TOKENS' "$RP_SRC"; then
  pass_at "ENG-87 R8: AGENT_RUNTIME_TOKENS declared in render-prompt.sh"
else
  fail_at "ENG-87 R8: AGENT_RUNTIME_TOKENS declared" \
    "no AGENT_RUNTIME_TOKENS variable found — declare it as a runtime-token allowlist (e.g. file pr_number) and exclude those names from the residual unknown-token scan in resolve_block_tokens"
fi
if grep -qE '_resolve_passthrough_(file|pr_number)' "$RP_SRC"; then
  fail_at "ENG-87 R8: passthrough shim removed" \
    "_resolve_passthrough_* still present — the shim is a no-op that triggers the residual scan to fire on agent-runtime tokens. Remove the function bodies and registry entries; the AGENT_RUNTIME_TOKENS skip-set replaces them."
else
  pass_at "ENG-87 R8: _resolve_passthrough_* shim removed"
fi

# ─── ENG-87 review-iter-7 m5: released-stage {issue_id} substitution ──
# §0 (common rules) is prepended to every stage block, including released.
# §0 carries `{issue_id}` references in the agent-blocked exit-ramp prose
# (e.g. "bash bin/pipeline.sh event {issue_id} verdict halt..."). The
# released branch sed-substitutes only {version}/{tag}/{prev_tag} and
# never invokes resolve_block_tokens, so post-iter-7 fix the released-
# stage rendered prompt would still ship a literal `{issue_id}` to the
# agent. The reviewer's m5 fix: extend the sed pipeline with
# -e "s|{issue_id}|cross-issue-release-${tag}|g" so a released agent
# that hits the exit-ramp gets a usable issue_id literal.
printf '\n--- ENG-87 review-iter-7 m5: released-stage {issue_id} resolved ---\n'

# Pin source-level: the released-branch sed pipeline must contain a
# substitution for {issue_id}. Asserted via a literal grep on render-
# prompt.sh so a future refactor that drops the sed-pipeline arm fails
# fast.
if grep -qE 's\|\{issue_id\}\|cross-issue-release-' "$RP_SRC"; then
  pass_at "ENG-87 m5-iter7: released-stage sed pipeline substitutes {issue_id}"
else
  fail_at "ENG-87 m5-iter7: released-stage {issue_id} resolution" \
    'released branch sed pipeline substitutes only {version}/{tag}/{prev_tag}. §0 carries a {issue_id} reference (in the agent-blocked exit-ramp prose) which ships as a literal to the released agent. Fix: add a sed expression substituting {issue_id} -> cross-issue-release-${tag}.'
fi

echo
echo "━━━ Summary ━━━"
echo "PASS: $PASS / FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
