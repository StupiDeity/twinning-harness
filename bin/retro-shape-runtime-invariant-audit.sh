#!/usr/bin/env bash
# Shape: runtime-invariant-audit. Pre-computes three current-tree
# invariant checks (resolver-path coverage, agent-prompt tool refs vs
# dispatch allowlists, STAGE_TO_SECTION ↔ §N header consistency) for the
# weekly retrospective.
# Output: a markdown artifact at $artifact_path consumed by the parent
# retrospective's §9 prompt via {runtime_invariant_audit_path} interpolation.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

_ARTIFACT_PATH=""
_PERIOD_START_ISO=""
_PERIOD_END_ISO=""

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
        # Coordinator (ENG-130) passes this to every shape. Shape B is a
        # current-tree audit; the value is intentionally ignored.
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

_render_prompt() {
  local rendered="$1"
  local template="$HARNESS_ROOT/bin/retro-prompts/runtime-invariant-audit.md"
  [[ -f "$template" ]] || die "shape: prompt template not found: $template"
  sed \
    -e "s|{agent_prompts_md_path}|${HARNESS_ROOT}/AGENT_PROMPTS.md|g" \
    -e "s|{dispatch_sh_path}|${HARNESS_ROOT}/bin/dispatch.sh|g" \
    -e "s|{render_prompt_sh_path}|${HARNESS_ROOT}/bin/render-prompt.sh|g" \
    -e "s|{artifact_path}|${_ARTIFACT_PATH}|g" \
    "$template" > "$rendered"
}

_validate_no_unresolved_tokens() {
  local rendered="$1"
  local unresolved=""
  for tok in agent_prompts_md_path dispatch_sh_path render_prompt_sh_path artifact_path; do
    if grep -qF "{${tok}}" "$rendered" 2>/dev/null; then
      unresolved="${unresolved} {${tok}}"
    fi
  done
  local extra
  extra="$(grep -oE '\{[a-z][a-z_]*[a-z]\}' "$rendered" 2>/dev/null \
    | grep -vE '^\{(artifact_path|agent_prompts_md_path|dispatch_sh_path|render_prompt_sh_path)\}$' \
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
  rendered="$(mktemp -t retro-shape-runtime-invariant-audit-XXXXXX.md)"

  _render_prompt "$rendered"
  _validate_no_unresolved_tokens "$rendered"

  if [[ "${PIPELINE_DRY_RUN-}" == "1" ]]; then
    log "[DRY_RUN] would dispatch.sh retrospective with prompt=$rendered artifact=$_ARTIFACT_PATH"
    printf '%s\n' '[DRY_RUN placeholder] runtime-invariant-audit' > "$_ARTIFACT_PATH"
    rm -f "$rendered"
    return 0
  fi

  local log_file
  log_file="$PROJECT_STATE_DIR/logs/retro-shape-runtime-invariant-audit-$(date -u +%Y%m%dT%H%M%SZ).log"
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
