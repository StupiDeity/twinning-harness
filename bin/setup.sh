#!/usr/bin/env bash
# One-stop onboarding for a target repo. Walks every prerequisite phase
# idempotently. See docs/brainstorms/2026-04-26-multi-project-harness.md §5.2
# for the phase contract.
#
# Usage:
#   bash bin/setup.sh /path/to/target [phase]
#
# With no phase: runs all unsatisfied phases 1-11 in order.
# With <phase>: jumps to that phase only. Special phases:
#   validate      - re-runs offline checks (health-check shortcut)
#   migrate       - one-shot upgrade for an existing single-project install

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh requires TARGET_REPO and (post-bootstrap) project.slug. setup.sh
# runs before slug-freeze on a fresh project, so set the bootstrap flag for
# our own sourcing.
TARGET_REPO="${TARGET_REPO:-${1:-}}"
[[ -n "$TARGET_REPO" && -d "$TARGET_REPO" ]] || {
  printf 'usage: bash bin/setup.sh /path/to/target [phase]\n' >&2
  exit 64
}
export TARGET_REPO TWINNING_BOOTSTRAPPING=1
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=setup-helpers.sh
source "$SCRIPT_DIR/setup-helpers.sh"

PHASE="${2:-}"
SECRETS_FILE="$HARNESS_CONFIG_DIR/secrets.env"
ENV_FILE="$TARGET_CONFIG_DIR/.env.local"

# ── Phase 1: workspace ────────────────────────────────────────────────
phase_workspace() {
  print_phase_header "workspace"
  mkdir -p "$TARGET_CONFIG_DIR" "$TARGET_CONFIG_DIR/schemas"
  mkdir -p "$HARNESS_CONFIG_DIR" && chmod 0700 "$HARNESS_CONFIG_DIR"
  if [[ ! -f "$CONFIG" ]]; then
    atomic_write_file "$CONFIG" 0644 <<'JSON'
{
  "linear": {},
  "orchestrator": {}
}
JSON
    log "wrote scaffolded $CONFIG"
  else
    log "$CONFIG already present"
  fi
  log "workspace ready"
}

is_workspace_done() {
  [[ -d "$TARGET_CONFIG_DIR/schemas" && -d "$HARNESS_CONFIG_DIR" && -f "$CONFIG" ]]
}

# Phase dispatch.
ALL_PHASES=(workspace)
run_phase_or_skip() {
  local phase="$1" check_fn run_fn
  check_fn="is_${phase//-/_}_done"
  run_fn="phase_${phase//-/_}"
  if declare -F "$check_fn" >/dev/null && "$check_fn"; then
    log "phase $phase: already satisfied (skip)"
    return 0
  fi
  "$run_fn"
}

main() {
  if [[ -n "$PHASE" ]]; then
    "phase_${PHASE//-/_}"
    return
  fi
  local p
  for p in "${ALL_PHASES[@]}"; do
    run_phase_or_skip "$p"
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
