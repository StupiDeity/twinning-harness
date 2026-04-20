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

# Load .env.local so LINEAR_API_KEY and friends are available to the agent.
if [[ -f "$PIPELINE_ROOT/.env.local" ]]; then
  # shellcheck disable=SC1091
  set -a; source "$PIPELINE_ROOT/.env.local"; set +a
fi

require_env LINEAR_API_KEY
require_bin claude gh git jq

main() {
  local today branch log_file prompt_file
  today="$(date -u +%Y-%m-%d)"
  branch="pipeline/retrospective-${today}"
  log_file="$REPO_ROOT/logs/pipeline/retrospective-$(date -u +%Y%m%dT%H%M%SZ).log"
  mkdir -p "$(dirname "$log_file")"

  log "retrospective: starting for $today"

  # Fresh-checkout guard. Bail if the working tree has uncommitted changes —
  # we run off main and don't want to pollute in-flight work.
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    die "retrospective: working tree dirty; refusing to run. Commit or stash first."
  fi

  # Make sure we have the latest main.
  git -C "$REPO_ROOT" fetch origin main

  # Checkout working branch off origin/main. Idempotent: if the branch already
  # exists (e.g. re-run same day), reuse it.
  if git -C "$REPO_ROOT" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
    log "retrospective: branch $branch exists; reusing"
    git -C "$REPO_ROOT" checkout "$branch"
    git -C "$REPO_ROOT" reset --hard origin/main
  else
    git -C "$REPO_ROOT" checkout -b "$branch" origin/main
  fi

  # Extract the retrospective block from AGENT_PROMPTS.md.
  prompt_file="$(mktemp -t retrospective-prompt-XXXXXX)"
  awk '
    /^## 9\. Retrospective Agent/ { found=1; next }
    found && /^```/ { fence++; if (fence == 1) next; if (fence == 2) exit }
    found && fence == 1 { print }
  ' "$PIPELINE_ROOT/AGENT_PROMPTS.md" > "$prompt_file"
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
  git -C "$REPO_ROOT" add -A
  if git -C "$REPO_ROOT" diff --cached --quiet; then
    log "retrospective: no changes proposed this week"
    bash "$SCRIPT_DIR/slack.sh" info "Weekly retrospective: no changes proposed."
    git -C "$REPO_ROOT" checkout main
    git -C "$REPO_ROOT" branch -D "$branch" || true
    return 0
  fi

  git -C "$REPO_ROOT" \
    -c user.name="twinning-pipeline-bot" \
    -c user.email="twinning-pipeline-bot@users.noreply.github.com" \
    commit -m "chore(pipeline): weekly retrospective ${today}"
  git -C "$REPO_ROOT" push -u origin "$branch"

  gh pr create \
    --title "chore(pipeline): weekly retrospective ${today}" \
    --body "Automated weekly retrospective run. Proposed rule/convention/knowledge changes require CODEOWNERS review." \
    --label "pipeline-retrospective"

  bash "$SCRIPT_DIR/slack.sh" info "Weekly retrospective opened a PR for review."
  git -C "$REPO_ROOT" checkout main
  log "retrospective: done"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
