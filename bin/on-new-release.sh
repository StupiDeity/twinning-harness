#!/usr/bin/env bash
# Handle a newly-published GitHub release, locally. Replaces the old
# pipeline-release.yml CI workflow (both the bash sweep and the observer agent)
# so CI no longer needs ANTHROPIC_API_KEY.
#
# Usage: on-new-release.sh <version> <tag>
# Example: on-new-release.sh 1.23.0 v1.23.0
#
# Invoked by run-local.sh on every tick after it detects a newer tag than the
# last one recorded in ~/.twinning-pipeline/last-observed-release.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

main() {
  local version="${1:-}" tag="${2:-}"
  [[ -n "$version" && -n "$tag" ]] || die "usage: on-new-release.sh <version> <tag>"

  require_env LINEAR_API_KEY

  log "on-new-release: version=$version tag=$tag"

  # ─── Part 1: sweep stage:building → stage:released (safety net) ─────
  # Primary path: when the build agent posts a `<!-- pipeline: verdict
  # result=pass stage=building -->` marker, verdict-handler.sh::apply_transition
  # advances the issue to stage:released and flips Linear native-state to
  # Done (see bin/verdict-handler.sh:159-167). This sweep is the SAFETY NET for
  # issues that didn't transition that way — for example, a build-agent
  # crash that left the issue stuck at stage:building, or a manually-
  # moved issue that bypassed the agent. In the happy path this loop
  # finds no issues and is a no-op.
  local active_state done_state
  active_state="$(config_get '.linear.native_states.active')"
  done_state="$(config_get '.linear.native_states.done')"

  local issues
  issues="$(bash "$SCRIPT_DIR/linear.sh" list-issues-with-label 'stage:building' \
    | jq -r --arg s "$active_state" '.data.issues.nodes[] | select(.state.name == $s) | .identifier')"

  if [[ -z "$issues" ]]; then
    log "sweep: no stage:building issues to flip"
    bash "$SCRIPT_DIR/slack.sh" info "Release $tag: no issues were at stage:building."
  else
    local count=0
    while IFS= read -r ident; do
      [[ -n "$ident" ]] || continue
      log "sweep: flipping $ident → stage:released + $done_state"
      bash "$SCRIPT_DIR/linear.sh" swap-stage "$ident" released
      bash "$SCRIPT_DIR/linear.sh" transition-state "$ident" "$done_state"
      bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" \
        "Pipeline: release $tag completed. Issue moved to Done."
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" build success 0 "release-sweep tag=$tag"
      count=$((count + 1))
    done <<<"$issues"
    bash "$SCRIPT_DIR/slack.sh" info "Release $tag: flipped $count issue(s) to stage:released."
  fi

  # ─── Part 2: release observer agent ──────────────────────────────────────
  # Writes per-issue "shipped in $tag" Linear enrichments and a cross-release
  # Slack summary. Non-fatal if it fails — the sweep above has already moved
  # issues to Done. The observer is enrichment, not critical path.
  if ! bash "$SCRIPT_DIR/run-release-observer.sh" "$version" "$tag"; then
    local rc=$?
    log "release observer exited rc=$rc (non-fatal; sweep already completed)"
    return 0
  fi

  log "on-new-release complete for $tag"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
