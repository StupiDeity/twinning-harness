#!/usr/bin/env bash
# Shape: gotcha-recurrence. Pre-computes the gotcha-recurrence section of
# the weekly retrospective. Output: a markdown artifact at $artifact_path
# concatenated into the coordinator's PR body.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

_ARTIFACT_PATH=""
_PERIOD_START_ISO=""
_PERIOD_END_ISO=""
_PREVIOUS_PERIOD_PATH="(none)"

_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --artifact-path)
        [[ -n "${2-}" ]] || die "shape: --artifact-path requires a value"
        _ARTIFACT_PATH="$2"; shift 2 ;;
      --period-start-iso)
        [[ -n "${2-}" ]] || die "shape: --period-start-iso requires a value"
        _PERIOD_START_ISO="$2"; shift 2 ;;
      --period-end-iso)
        [[ -n "${2-}" ]] || die "shape: --period-end-iso requires a value"
        _PERIOD_END_ISO="$2"; shift 2 ;;
      --previous-period-path)
        [[ -n "${2-}" ]] || die "shape: --previous-period-path requires a value"
        _PREVIOUS_PERIOD_PATH="$2"; shift 2 ;;
      *) die "shape: unknown argument: $1" ;;
    esac
  done
  [[ -n "$_ARTIFACT_PATH" ]] \
    || die "shape: --artifact-path is required"
  [[ -n "$_PERIOD_START_ISO" ]] \
    || die "shape: --period-start-iso is required"
  [[ -n "$_PERIOD_END_ISO" ]] \
    || die "shape: --period-end-iso is required"
}

_render_prompt() {
  local rendered="$1"
  local template="$HARNESS_ROOT/bin/retro-prompts/gotcha-recurrence.md"
  [[ -f "$template" ]] || die "shape: prompt template not found: $template"
  sed \
    -e "s|{events_jsonl_path}|${PROJECT_STATE_DIR}/metrics/events.jsonl|g" \
    -e "s|{period_start_iso}|${_PERIOD_START_ISO}|g" \
    -e "s|{period_end_iso}|${_PERIOD_END_ISO}|g" \
    -e "s|{artifact_path}|${_ARTIFACT_PATH}|g" \
    -e "s|{previous_period_path}|${_PREVIOUS_PERIOD_PATH}|g" \
    "$template" > "$rendered"
}

_validate_no_unresolved_tokens() {
  local rendered="$1"
  local unresolved=""
  for tok in events_jsonl_path period_start_iso period_end_iso artifact_path previous_period_path; do
    if grep -qF "{${tok}}" "$rendered" 2>/dev/null; then
      unresolved="${unresolved} {${tok}}"
    fi
  done
  local extra
  extra="$(grep -oE '\{[a-z][a-z_]*[a-z]\}' "$rendered" 2>/dev/null \
    | grep -vE '^\{(artifact_path|events_jsonl_path|period_start_iso|period_end_iso|previous_period_path)\}$' \
    | head -1 || true)"
  if [[ -n "$unresolved" || -n "$extra" ]]; then
    die "shape: unresolved token(s) in rendered prompt:${unresolved} ${extra}"
  fi
}

main() {
  _parse_args "$@"

  local artifact_parent
  artifact_parent="$(dirname "$_ARTIFACT_PATH")"
  [[ -d "$artifact_parent" ]] \
    || die "shape: parent directory does not exist: $artifact_parent"

  local rendered
  rendered="$(mktemp -t retro-shape-gotcha-recurrence-XXXXXX.md)"

  _render_prompt "$rendered"
  _validate_no_unresolved_tokens "$rendered"

  if [[ "${PIPELINE_DRY_RUN-}" == "1" ]]; then
    log "[DRY_RUN] would dispatch.sh retrospective with prompt=$rendered artifact=$_ARTIFACT_PATH (shape=gotcha-recurrence)"
    printf '%s\n' '[DRY_RUN placeholder] gotcha-recurrence' > "$_ARTIFACT_PATH"
    rm -f "$rendered"
    return 0
  fi

  local log_file
  log_file="$PROJECT_STATE_DIR/logs/retro-shape-gotcha-recurrence-$(date -u +%Y%m%dT%H%M%SZ).log"
  mkdir -p "$(dirname "$log_file")"

  local rc=0
  bash "$SCRIPT_DIR/dispatch.sh" retrospective "$rendered" "$log_file" || rc=$?
  rm -f "$rendered"

  (( rc == 0 )) \
    || die "shape: dispatch.sh retrospective failed rc=$rc (log: $log_file)"

  [[ -f "$_ARTIFACT_PATH" ]] \
    || die "shape: artifact not written at $_ARTIFACT_PATH (log: $log_file)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
