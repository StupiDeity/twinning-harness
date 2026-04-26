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

trap 'rm -rf "$FAKE" "$STUB" "$HARNESS_STATE_DIR"' EXIT

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
