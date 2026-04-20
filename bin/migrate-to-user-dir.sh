#!/usr/bin/env bash
# One-shot, idempotent migration of repo-resident pipeline state to
# ~/.twinning-pipeline/. Safe to re-run. Does NOT remove anything from
# the repo — that is a deliberate git rm + commit performed manually after
# verification.
#
# Prerequisite: stop the launchd agent before running:
#   launchctl unload ~/Library/LaunchAgents/com.twinning.pipeline.plist

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

if launchctl list 2>/dev/null | grep -q com.twinning.pipeline; then
  die "launchd agent is loaded. Unload first: launchctl unload ~/Library/LaunchAgents/com.twinning.pipeline.plist"
fi

mkdir -p "$TWINNING_DIR"/{metrics,scope-approval,worktrees}
chmod 700 "$TWINNING_DIR"

# 1. Metrics JSONL.
if [[ -f "$REPO_ROOT/.pipeline/metrics/events.jsonl" ]]; then
  src="$REPO_ROOT/.pipeline/metrics/events.jsonl"
  dst="$TWINNING_DIR/metrics/events.jsonl"
  if [[ ! -f "$dst" ]] || [[ "$src" -nt "$dst" ]]; then
    cp -p "$src" "$dst"
    log "migrated: events.jsonl ($(wc -l < "$dst" | tr -d ' ') events)"
  else
    log "skip: events.jsonl already migrated"
  fi
fi

# 2. Scope-approval state files.
if [[ -d "$REPO_ROOT/.pipeline/.scope-approval" ]]; then
  shopt -s nullglob
  for f in "$REPO_ROOT/.pipeline/.scope-approval"/*; do
    dst="$TWINNING_DIR/scope-approval/$(basename "$f")"
    if [[ ! -f "$dst" ]] || [[ "$f" -nt "$dst" ]]; then
      cp -p "$f" "$dst"
      log "migrated: scope-approval/$(basename "$f")"
    fi
  done
fi

# 3. Circuit-breaker counter.
if [[ -f "$REPO_ROOT/.pipeline/.consecutive-failures" ]]; then
  if [[ ! -f "$TWINNING_DIR/.consecutive-failures" ]]; then
    cp -p "$REPO_ROOT/.pipeline/.consecutive-failures" "$TWINNING_DIR/.consecutive-failures"
    log "migrated: .consecutive-failures"
  fi
fi

# 4. Verify event counts match.
if [[ -f "$REPO_ROOT/.pipeline/metrics/events.jsonl" ]]; then
  src_count=$(wc -l < "$REPO_ROOT/.pipeline/metrics/events.jsonl" | tr -d ' ')
  dst_count=$(wc -l < "$TWINNING_DIR/metrics/events.jsonl" | tr -d ' ')
  [[ "$src_count" == "$dst_count" ]] || die "event count mismatch: src=$src_count, dst=$dst_count"
fi

log "migration complete. Next: run the 'cleanup' section in docs/plans/2026-04-20-eng-13-pipeline-worktree-isolation.md Task 10."
