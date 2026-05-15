#!/usr/bin/env bash
# Run the retrospective agent locally, then open a PR with any proposed rule /
# knowledge / workflow changes. Replaces the old pipeline-retrospective.yml
# weekly CI cron so we don't need ANTHROPIC_API_KEY in CI.
#
# Invoked by launchd via com.twinning.retrospective.plist (Mondays 09:00 local).
# Can also be kicked manually: bash .pipeline/bin/run-retrospective-local.sh
#
# Exit codes: 0=success (incl. no-op), 1=setup failure, 20=dispatch failed.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Load shared secrets then per-project .env.local so LINEAR_API_KEY and friends
# are available to the agent. secrets.env is loaded first; .env.local may override.
SECRETS_FILE="$HARNESS_CONFIG_DIR/secrets.env"
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$SECRETS_FILE"; set +a
fi
ENV_FILE="$TARGET_CONFIG_DIR/.env.local"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

require_env LINEAR_API_KEY
require_bin claude gh git jq

# _compute_retro_period — emits two ISO 8601 UTC timestamps on stdout
# (one per line: start, then end). Period semantics mirror
# AGENT_PROMPTS.md §9 "Period of analysis":
#   - Start: timestamp of the last weekly retrospective merge, or
#     30 days ago if none.
#   - End: now (UTC).
_compute_retro_period() {
  local end_iso start_iso last_merge_unix
  end_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  last_merge_unix="$(git -C "$TARGET_REPO" log --merges --format='%ct %s' \
    | grep 'weekly retrospective' | head -1 | awk '{print $1}')"
  if [[ -n "$last_merge_unix" && "$last_merge_unix" =~ ^[0-9]+$ ]]; then
    start_iso="$(date -u -r "$last_merge_unix" +%Y-%m-%dT%H:%M:%SZ)"
  else
    start_iso="$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ)"
  fi
  printf '%s\n%s\n' "$start_iso" "$end_iso"
}

main() {
  local today branch log_file prompt_file
  today="$(date -u +%Y-%m-%d)"
  branch="pipeline/retrospective-${today}"
  log_file="$PROJECT_STATE_DIR/logs/retrospective-$(date -u +%Y%m%dT%H%M%SZ).log"
  mkdir -p "$(dirname "$log_file")"

  log "retrospective: starting for $today"

  # Fresh-checkout guard. Bail if the working tree has uncommitted changes —
  # we run off main and don't want to pollute in-flight work.
  if [[ -n "$(git -C "$TARGET_REPO" status --porcelain)" ]]; then
    die "retrospective: working tree dirty; refusing to run. Commit or stash first."
  fi

  # Make sure we have the latest main.
  git -C "$TARGET_REPO" fetch origin main

  # Checkout working branch off origin/main. Idempotent: if the branch already
  # exists (e.g. re-run same day), reuse it.
  if git -C "$TARGET_REPO" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
    log "retrospective: branch $branch exists; reusing"
    git -C "$TARGET_REPO" checkout "$branch"
    git -C "$TARGET_REPO" reset --hard origin/main
  else
    git -C "$TARGET_REPO" checkout -b "$branch" origin/main
  fi

  # ENG-129: pre-compute stage-failure-summary as a shape artifact.
  # The parent retrospective Reads the artifact (via the
  # {stage_failure_summary_path} token interpolated into the §9 prompt
  # below) and incorporates §1 verbatim. Shape failures HALT the
  # retrospective for operator review — partial retrospectives are
  # worse than re-running next week.
  local period_lines period_start_iso period_end_iso
  period_lines="$(_compute_retro_period)"
  period_start_iso="$(printf '%s' "$period_lines" | sed -n '1p')"
  period_end_iso="$(printf '%s' "$period_lines"   | sed -n '2p')"
  local shape_artifact_dir="$PROJECT_STATE_DIR/retrospective-${today}"
  local stage_failure_summary_path="${shape_artifact_dir}/stage-failure-summary.md"
  mkdir -p "$shape_artifact_dir"
  local shape_rc=0
  bash "$SCRIPT_DIR/retro-shape-stage-failure-summary.sh" \
    --artifact-path     "$stage_failure_summary_path" \
    --period-start-iso  "$period_start_iso" \
    --period-end-iso    "$period_end_iso" \
    || shape_rc=$?
  if (( shape_rc != 0 )); then
    bash "$SCRIPT_DIR/slack.sh" error "Weekly retrospective shape stage-failure-summary failed (rc=$shape_rc)"
    exit 20
  fi

  # Extract the retrospective block from AGENT_PROMPTS.md.
  prompt_file="$(mktemp -t retrospective-prompt-XXXXXX)"
  awk '
    /^## 9\. Retrospective Agent/ { found=1; next }
    found && /^```/ { fence++; if (fence == 1) next; if (fence == 2) exit }
    found && fence == 1 { print }
  ' "$HARNESS_ROOT/AGENT_PROMPTS.md" > "$prompt_file"

  # ENG-129: inject the shape artifact path into the §9 prompt so the
  # parent Reads the pre-computed §1 instead of recomputing it.
  sed -i.bak \
    -e "s|{stage_failure_summary_path}|${stage_failure_summary_path}|g" \
    "$prompt_file"
  rm -f "${prompt_file}.bak"

  log "retrospective: rendered prompt ($(wc -l < "$prompt_file") lines)"

  # Dispatch the agent. dispatch.sh uses the local `claude` subscription session
  # when ANTHROPIC_API_KEY is unset; no API tokens burn against the subscription
  # billing path.
  if ! bash "$SCRIPT_DIR/dispatch.sh" retrospective "$prompt_file" "$log_file"; then
    rm -f "$prompt_file"
    bash "$SCRIPT_DIR/slack.sh" error "Weekly retrospective failed (log: $log_file)"
    exit 20
  fi
  rm -f "$prompt_file"

  # If the agent produced no changes, don't open a PR.
  git -C "$TARGET_REPO" add -A
  if git -C "$TARGET_REPO" diff --cached --quiet; then
    log "retrospective: no changes proposed this week"
    bash "$SCRIPT_DIR/slack.sh" info "Weekly retrospective: no changes proposed."
    git -C "$TARGET_REPO" checkout main
    git -C "$TARGET_REPO" branch -D "$branch" || true
    return 0
  fi

  git -C "$TARGET_REPO" \
    -c user.name="twinning-pipeline-bot" \
    -c user.email="twinning-pipeline-bot@users.noreply.github.com" \
    commit -m "chore(pipeline): weekly retrospective ${today}"
  git -C "$TARGET_REPO" push -u origin "$branch"

  gh pr create \
    --title "chore(pipeline): weekly retrospective ${today}" \
    --body "Automated weekly retrospective run. Proposed rule/convention/knowledge changes require CODEOWNERS review." \
    --label "pipeline-retrospective"

  bash "$SCRIPT_DIR/slack.sh" info "Weekly retrospective opened a PR for review."
  git -C "$TARGET_REPO" checkout main
  log "retrospective: done"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
