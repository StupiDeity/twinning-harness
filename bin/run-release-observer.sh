#!/usr/bin/env bash
# Run the Release Agent once per semantic-release cut.
# Usage:
#   run-release-observer.sh <version> <tag> [<prev_tag>]
# Invoked by .github/workflows/pipeline-release.yml AFTER the stage:building→released sweep.
# In PIPELINE_DRY_RUN=1, echoes what it would do without calling claude.
#
# Unlike run-stage.sh, release is a cross-issue event — it has no single owning Linear
# issue. The agent enumerates all issues covered by commits in the window and writes
# per-issue Linear comments, a cross-release Slack summary, and a pipeline-metrics entry.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

main() {
  local version="${1:-}" tag="${2:-}" prev_tag="${3:-}"
  [[ -n "$version" && -n "$tag" ]] || die "usage: run-release-observer.sh <version> <tag> [<prev_tag>]"

  export PIPELINE_RELEASE_VERSION="$version"
  export PIPELINE_RELEASE_TAG="$tag"
  export PIPELINE_RELEASE_PREV_TAG="$prev_tag"

  local t0 t1 duration
  t0="$(date +%s)"

  # Render the prompt.
  local prompt_file log_file
  prompt_file="$(mktemp -t pipeline-release-prompt-XXXXXX)"
  log_file="$HARNESS_STATE_DIR/logs/release-${tag}-$(date -u +%Y%m%dT%H%M%SZ).log"
  mkdir -p "$(dirname "$log_file")"
  bash "$SCRIPT_DIR/render-prompt.sh" release > "$prompt_file"
  log "rendered release prompt: $prompt_file ($(wc -l < "$prompt_file") lines)"

  bash "$SCRIPT_DIR/metrics.sh" release-start "" release "dispatching" 0 \
    "version=$version tag=$tag prev_tag=${prev_tag:-auto}"

  if ! bash "$SCRIPT_DIR/dispatch.sh" release "$prompt_file" "$log_file"; then
    t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
    bash "$SCRIPT_DIR/metrics.sh" release-end "" release "failed" "$duration" \
      "version=$version log=$log_file"
    bash "$SCRIPT_DIR/slack.sh" error "Release observer failed for $tag (log: $log_file)"
    rm -f "$prompt_file"
    exit 20
  fi
  rm -f "$prompt_file"

  t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
  bash "$SCRIPT_DIR/metrics.sh" release-end "" release "success" "$duration" \
    "version=$version tag=$tag"
  log "release observer complete for $tag"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
