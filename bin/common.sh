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
    } | LC_ALL=C sort
  )"
  # shasum each, then hash the concatenation of per-file digests.
  printf '%s\n' "$files" \
    | xargs -I{} shasum -a 256 {} \
    | awk '{print $1}' \
    | shasum -a 256 \
    | awk '{print $1}'
}
# ─── Exit-code → outcome taxonomy (ENG-10 D-002) ─────────────────────
# Map a run-stage.sh exit code (and optional subcode) to the canonical
# typed outcome name the retrospective agent's §1 filter and status.sh's
# red/yellow predicate recognise. Callers: classify-failure.sh (all
# classify_failure emissions), run-stage.sh (paused path — exit 11).
# Reconcile-human (run-local.sh) does NOT call this helper: it emits the
# direct string "reconcile-human" per D-004 because exit_code=0
# subcode="" would route to unknown-exit-0.
#
# Usage: failure_outcome_for_exit <exit_code> <subcode>
#   subcode may be "" (empty). Case matching is exact.
failure_outcome_for_exit() {
  local exit_code="$1" subcode="${2:-}"
  case "$exit_code" in
    0)
      case "$subcode" in
        1) printf 'scope-approval-pending' ;;
        *) printf 'unknown-exit-0' ;;
      esac
      ;;
    10) printf 'guards-tripped' ;;
    11) printf 'paused' ;;
    20) printf 'dispatch-failed' ;;
    21) printf 'scope-violation' ;;
    22) printf 'pr-opened-too-early' ;;
    24) printf 'linear-post-failed' ;;
    *)  printf 'unknown-exit-%s' "$exit_code" ;;
  esac
}
export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit

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
