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

echo
echo "━━━ Summary ━━━"
echo "PASS: $PASS / FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
