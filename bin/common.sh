#!/usr/bin/env bash
# Shared helpers sourced by every pipeline script.
# Provides: PIPELINE_ROOT, REPO_ROOT, CONFIG, log, die, require_env.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIPELINE_ROOT="$REPO_ROOT/.pipeline"
CONFIG="$PIPELINE_ROOT/config.json"
IDS_CACHE="$PIPELINE_ROOT/schemas/linear-ids.json"
TWINNING_DIR="${HOME}/.twinning-pipeline"

export REPO_ROOT PIPELINE_ROOT CONFIG IDS_CACHE TWINNING_DIR

# ─── Per-issue state directory (ENG-15) ──────────────────────────────
# Resolve the per-issue state directory. Callers: run-stage.sh,
# run-local.sh, poll.sh, classify-failure.sh. The directory holds
# issue-state.json, the worktree/ subdir, and the scope-approval file.
issue_dir() {
  local issue="$1"
  [[ -n "$issue" ]] || die "issue_dir: missing issue id"
  printf '%s/%s' "$TWINNING_DIR" "$issue"
}
ISSUE_STATE_DIR="$TWINNING_DIR"  # issue-specific paths under $ISSUE_STATE_DIR/ENG-N/
export ISSUE_STATE_DIR

# Compute a stable sha256 over the set of files that drive pipeline
# behavior from the main dev dir. Intentionally excludes metrics/ and
# learned-rules/ (churn every tick). Emits a single hex digest, no
# filename. Used by classify_failure (failure time) and poll.sh (tick
# time) to detect pipeline-code changes that should un-skip an issue.
compute_pipeline_content_hash() {
  # Produce an ordered list of files, then concatenate with sha256.
  # Sort by path so ordering is deterministic across filesystems.
  local files
  files="$(
    {
      find "$REPO_ROOT/.pipeline/bin" -type f -name '*.sh' 2>/dev/null
      printf '%s\n' "$REPO_ROOT/.pipeline/config.json"
      printf '%s\n' "$REPO_ROOT/.pipeline/AGENT_PROMPTS.md"
    } | sort
  )"
  # shasum each, then hash the concatenation of per-file digests.
  printf '%s\n' "$files" \
    | xargs -I{} shasum -a 256 {} 2>/dev/null \
    | awk '{print $1}' \
    | shasum -a 256 \
    | awk '{print $1}'
}
export -f issue_dir compute_pipeline_content_hash

PIPELINE_DRY_RUN="${PIPELINE_DRY_RUN:-0}"
export PIPELINE_DRY_RUN

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
  printf '[%s] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
  exit 1
}

require_env() {
  for var in "$@"; do
    [[ -n "${!var:-}" ]] || die "required env var not set: $var"
  done
}

require_bin() {
  for b in "$@"; do
    command -v "$b" >/dev/null 2>&1 || die "required binary not on PATH: $b"
  done
}

config_get() {
  local path="$1"
  jq -r "$path" "$CONFIG"
}

ids_get() {
  local path="$1"
  jq -r "$path" "$IDS_CACHE"
}

label_id() {
  ids_get ".labels[\"$1\"]"
}

state_id() {
  ids_get ".states[\"$1\"]"
}
