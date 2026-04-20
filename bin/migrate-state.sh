#!/usr/bin/env bash
# ENG-15: one-shot migration from flat ~/.twinning-pipeline/ layout to
# per-issue-dir layout. Idempotent — re-runs skip already-migrated items.
#
# Usage:
#   bash .pipeline/bin/migrate-state.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

if [[ -d "$TWINNING_DIR/.run-local.lock" ]]; then
  die "pipeline tick in progress (lock at $TWINNING_DIR/.run-local.lock). Wait for tick completion before migrating."
fi

paused="$(config_get '.orchestrator.paused')"
if [[ "$paused" != "true" ]]; then
  log "WARN: orchestrator.paused is false. You should pause before migrating."
  log "      Ctrl-C to abort, or wait 5 seconds to continue."
  sleep 5
fi

# ─── 1. Worktrees → $TWINNING_DIR/ENG-N/worktree ───────────────────────
if [[ -d "$TWINNING_DIR/worktrees" ]]; then
  shopt -s nullglob
  for wt in "$TWINNING_DIR/worktrees"/*; do
    [[ -d "$wt" ]] || continue
    dir_name="$(basename "$wt")"
    issue=""
    # Format 1: "feat-eng-14-..." (ENG-13 worktree naming)
    if [[ "$dir_name" =~ ^feat-(eng-[0-9]+)- ]]; then
      issue="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"
    # Format 2: "eng-12" (legacy short form)
    elif [[ "$dir_name" =~ ^(eng-[0-9]+)$ ]]; then
      issue="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"
    else
      log "skip: unrecognized worktree dir name: $dir_name"
      continue
    fi
    new_path="$TWINNING_DIR/$issue/worktree"
    if [[ -e "$new_path" ]]; then
      log "skip: already migrated: $wt → $new_path"
      continue
    fi
    mkdir -p "$TWINNING_DIR/$issue"
    git -C "$REPO_ROOT" worktree move "$wt" "$new_path"
    log "migrated worktree: $wt → $new_path"
  done
  # Clean up the old worktrees/ parent if empty.
  rmdir "$TWINNING_DIR/worktrees" 2>/dev/null || log "note: $TWINNING_DIR/worktrees still has entries; leaving for manual inspection"
fi

# ─── 2. scope-approval files → $TWINNING_DIR/ENG-N/scope-approval ──────
if [[ -d "$TWINNING_DIR/scope-approval" ]]; then
  shopt -s nullglob
  for f in "$TWINNING_DIR/scope-approval"/*; do
    [[ -f "$f" ]] || continue
    issue="$(basename "$f")"
    new_path="$TWINNING_DIR/$issue/scope-approval"
    mkdir -p "$TWINNING_DIR/$issue"
    if [[ -e "$new_path" ]]; then
      log "skip: scope-approval already migrated for $issue"
      continue
    fi
    mv "$f" "$new_path"
    log "migrated scope-approval: $f → $new_path"
  done
  rmdir "$TWINNING_DIR/scope-approval" 2>/dev/null || true
fi

log "migration complete. Run bash .pipeline/bin/setup-labels.sh next to register new labels."
