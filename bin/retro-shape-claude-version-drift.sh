#!/usr/bin/env bash
# Shape: claude-version-drift. Compares `claude --version` against
# $HARNESS_ROOT/.claude-cli-version and emits a one-paragraph observation
# for the weekly retrospective.
# Output: a markdown artifact at $artifact_path consumed by the parent
# retrospective's §9 prompt via {claude_version_drift_path} interpolation.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

_ARTIFACT_PATH=""
_PERIOD_START_ISO=""
_PERIOD_END_ISO=""
_OBSERVED_VERSION=""
_EXPECTED_VERSION=""

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
        # Coordinator (ENG-130) passes this to every shape. Shape C compares
        # current claude --version against the checked-in pin file; period
        # context is not consumed.
        [[ -n "${2-}" ]] || die "shape: --previous-period-path requires a value"
        shift 2 ;;
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

_capture_observed_version() {
  if command -v claude >/dev/null 2>&1; then
    local raw
    raw="$(claude --version 2>/dev/null | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)"
    if [[ -n "$raw" ]]; then
      _OBSERVED_VERSION="$raw"
    else
      _OBSERVED_VERSION="(unavailable)"
    fi
  else
    _OBSERVED_VERSION="(unavailable)"
  fi
}

_capture_expected_version() {
  local pin_file="$HARNESS_ROOT/.claude-cli-version"
  if [[ -f "$pin_file" ]]; then
    local raw
    raw="$(head -1 "$pin_file" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)"
    if [[ -n "$raw" ]]; then
      _EXPECTED_VERSION="$raw"
    else
      _EXPECTED_VERSION="(unpinned)"
    fi
  else
    _EXPECTED_VERSION="(unpinned)"
  fi
}

_render_prompt() {
  local rendered="$1"
  local template="$HARNESS_ROOT/bin/retro-prompts/claude-version-drift.md"
  [[ -f "$template" ]] || die "shape: prompt template not found: $template"
  sed \
    -e "s|{observed_version}|${_OBSERVED_VERSION}|g" \
    -e "s|{expected_version}|${_EXPECTED_VERSION}|g" \
    -e "s|{artifact_path}|${_ARTIFACT_PATH}|g" \
    "$template" > "$rendered"
}

_validate_no_unresolved_tokens() {
  local rendered="$1"
  local unresolved=""
  for tok in observed_version expected_version artifact_path; do
    if grep -qF "{${tok}}" "$rendered" 2>/dev/null; then
      unresolved="${unresolved} {${tok}}"
    fi
  done
  local extra
  extra="$(grep -oE '\{[a-z][a-z_]*[a-z]\}' "$rendered" 2>/dev/null \
    | grep -vE '^\{(artifact_path|observed_version|expected_version)\}$' \
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

  _capture_observed_version
  _capture_expected_version

  local rendered
  rendered="$(mktemp -t retro-shape-claude-version-drift-XXXXXX.md)"

  _render_prompt "$rendered"
  _validate_no_unresolved_tokens "$rendered"

  if [[ "${PIPELINE_DRY_RUN-}" == "1" ]]; then
    log "[DRY_RUN] would dispatch.sh retrospective with prompt=$rendered artifact=$_ARTIFACT_PATH"
    printf '%s\n' '[DRY_RUN placeholder] claude-version-drift' > "$_ARTIFACT_PATH"
    rm -f "$rendered"
    return 0
  fi

  local log_file
  log_file="$PROJECT_STATE_DIR/logs/retro-shape-claude-version-drift-$(date -u +%Y%m%dT%H%M%SZ).log"
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
