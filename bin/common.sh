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
