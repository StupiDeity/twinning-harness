#!/usr/bin/env bash
# Verify render-prompt.sh substitutes {learned_rules_dir} with the slug-aware path.
set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY=test-mock-key
export PROJECT_SLUG=test-slug
HARNESS_STATE_DIR="$(mktemp -d)"
export HARNESS_STATE_DIR
export PROJECT_STATE_DIR="$HARNESS_STATE_DIR/$PROJECT_SLUG"
mkdir -p "$PROJECT_STATE_DIR"

# Mock target repo + linear.sh stub.
FAKE="$(mktemp -d)"
mkdir -p "$FAKE/.pipeline-config/schemas"
printf '{"linear":{},"project":{"slug":"test-slug"}}\n' > "$FAKE/.pipeline-config/config.json"
printf '{}\n' > "$FAKE/.pipeline-config/schemas/linear-ids.json"
export TARGET_REPO="$FAKE"

STUB="$(mktemp -d)"
cat > "$STUB/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get-issue) printf '{"data":{"issue":{"identifier":"ENG-99","title":"Test","description":"d"}}}\n' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB/linear.sh"

# Seed a minimal valid project-profile.md for the test slug so the
# stack-aware addendum injector doesn't die. Cleaned up via the trap.
HARNESS_REPO_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"
PROFILE_DIR="$HARNESS_REPO_ROOT/learned-rules/test-slug"
mkdir -p "$PROFILE_DIR"
cat > "$PROFILE_DIR/project-profile.md" <<'PROFILE'
---
slug: test-slug
generated_at: 2026-04-29T00:00:00Z
generated_by: render-prompt-slug-test
schema_version: 1
---

# Project profile — test-slug

## Stack
test fixture.

## Build & test gates
- Build: `(n/a)`
- Test: `bash bin/render-prompt-slug-test.sh`
- Lint/check: `(n/a)`
- Integration/E2E: `(n/a)`

## File layout
- `bin/` — scripts.

## Language idioms
- bash.

## Don'ts
(none observed)
PROFILE

trap 'rm -rf "$FAKE" "$STUB" "$HARNESS_STATE_DIR" "$PROFILE_DIR"' EXIT

# render-prompt.sh calls `bash "$SCRIPT_DIR/linear.sh"`, so PATH stubbing
# won't intercept it. Use the canonical source-and-override pattern:
# source common.sh + render-prompt.sh (their sentinels prevent main from
# firing), then override SCRIPT_DIR to point at the stub dir. Subsequent
# main calls then resolve linear.sh from the stub.
# shellcheck source=common.sh
source "$HARNESS_DIR/common.sh"
# shellcheck source=render-prompt.sh
source "$HARNESS_DIR/render-prompt.sh"
SCRIPT_DIR="$STUB"
out="$(main brainstorm ENG-99 2>&1)"

# After the render, the prompt body should contain the absolute path
# $HARNESS_ROOT/learned-rules/test-slug, NOT the literal token.
grep -q "{learned_rules_dir}" <<<"$out" \
  && { echo "FAIL: token not substituted"; exit 1; }
grep -q "learned-rules/test-slug" <<<"$out" \
  || { echo "FAIL: slug-aware path missing in rendered prompt"; exit 1; }

echo OK
