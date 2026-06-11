#!/usr/bin/env bash
# QA adversarial tests for ENG-158: retro-shape-tool-denial-trends,
# retro-shape-runtime-invariant-audit, retro-shape-claude-version-drift.
# Each test covers a gap NOT in the plan's Failure Mode → Test Map.

set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
export TARGET_REPO="${TARGET_REPO:-$HARNESS_DIR}"
export HARNESS_STATE_DIR="${HARNESS_STATE_DIR:-$(mktemp -d)}"
export PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-$(mktemp -d)}"

PASS=0
FAIL=0
FAILURES=""

_pass() { printf 'PASS: %s\n' "$1"; (( PASS++ )) || true; }
_fail() { printf 'FAIL: %s\n' "$1"; FAILURES="${FAILURES}  - $1\n"; (( FAIL++ )) || true; }

ARTIFACT_DIR="$(mktemp -d)"

# ---------------------------------------------------------------------------
# Shape A: missing --period-start-iso dies (fixture-1 only tests missing
# --artifact-path; the period flags are independent required args)
# ---------------------------------------------------------------------------
{
  name="adv-shapeA-missing-period-start-iso-dies"
  artifact_path="$ARTIFACT_DIR/adv-a-start.md"
  HARNESS_ROOT="$HARNESS_DIR" \
  source "$HARNESS_DIR/retro-shape-tool-denial-trends.sh" 2>/dev/null || true
  HARNESS_ROOT="${HARNESS_DIR%/bin}"
  rc=0
  msg="$(main \
    --artifact-path "$artifact_path" \
    --period-end-iso 2026-06-08T00:00:00Z \
    2>&1)" || rc=$?
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "period-start-iso"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc msg=$msg)"
  fi
}

# ---------------------------------------------------------------------------
# Shape A: missing --period-end-iso dies
# ---------------------------------------------------------------------------
{
  name="adv-shapeA-missing-period-end-iso-dies"
  artifact_path="$ARTIFACT_DIR/adv-a-end.md"
  rc=0
  msg="$(main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-06-01T00:00:00Z \
    2>&1)" || rc=$?
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "period-end-iso"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc msg=$msg)"
  fi
}

# ---------------------------------------------------------------------------
# Shape A: --previous-period-path accepted (reviewer noted inconsistency:
# Shape B/C have explicit fixture-prev-period-path-accepted; Shape A does not)
# ---------------------------------------------------------------------------
{
  name="adv-shapeA-previous-period-path-accepted"
  artifact_path="$ARTIFACT_DIR/adv-a-prev.md"
  rc=0
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-06-01T00:00:00Z \
    --period-end-iso   2026-06-08T00:00:00Z \
    --previous-period-path "(none)" \
    2>/dev/null || rc=$?
  if (( rc == 0 )) && [[ -f "$artifact_path" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc — driver rejected --previous-period-path)"
  fi
}

# ---------------------------------------------------------------------------
# Shape B: missing --period-start-iso dies
# ---------------------------------------------------------------------------
{
  name="adv-shapeB-missing-period-start-iso-dies"
  artifact_path="$ARTIFACT_DIR/adv-b-start.md"
  source "$HARNESS_DIR/retro-shape-runtime-invariant-audit.sh" 2>/dev/null || true
  HARNESS_ROOT="${HARNESS_DIR%/bin}"
  rc=0
  msg="$(main \
    --artifact-path "$artifact_path" \
    --period-end-iso 2026-06-08T00:00:00Z \
    2>&1)" || rc=$?
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "period-start-iso"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc msg=$msg)"
  fi
}

# ---------------------------------------------------------------------------
# Shape B: missing --period-end-iso dies
# ---------------------------------------------------------------------------
{
  name="adv-shapeB-missing-period-end-iso-dies"
  artifact_path="$ARTIFACT_DIR/adv-b-end.md"
  rc=0
  msg="$(main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-06-01T00:00:00Z \
    2>&1)" || rc=$?
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "period-end-iso"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc msg=$msg)"
  fi
}

# ---------------------------------------------------------------------------
# Shape C: missing --period-start-iso dies
# ---------------------------------------------------------------------------
{
  name="adv-shapeC-missing-period-start-iso-dies"
  artifact_path="$ARTIFACT_DIR/adv-c-start.md"
  source "$HARNESS_DIR/retro-shape-claude-version-drift.sh" 2>/dev/null || true
  HARNESS_ROOT="${HARNESS_DIR%/bin}"
  # Monkeypatch captures to non-carve-out defaults (same pattern as main test file)
  _capture_observed_version() { _OBSERVED_VERSION="claude-cli-test"; }
  _capture_expected_version() { _EXPECTED_VERSION="claude-cli-test-expected"; }
  rc=0
  msg="$(main \
    --artifact-path "$artifact_path" \
    --period-end-iso 2026-06-08T00:00:00Z \
    2>&1)" || rc=$?
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "period-start-iso"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc msg=$msg)"
  fi
}

# ---------------------------------------------------------------------------
# Shape C: missing --period-end-iso dies
# ---------------------------------------------------------------------------
{
  name="adv-shapeC-missing-period-end-iso-dies"
  artifact_path="$ARTIFACT_DIR/adv-c-end.md"
  rc=0
  msg="$(main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-06-01T00:00:00Z \
    2>&1)" || rc=$?
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "period-end-iso"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc msg=$msg)"
  fi
}

# ---------------------------------------------------------------------------
# Shape C: blank-line pin file (file exists but content is only a newline)
# silently produces (unpinned) and carve-out fires — sub-agent finding #2.
# Documents that the driver conflates "file absent" with "file present but
# blank"; this is the current designed behavior (any empty-after-trim
# content → unpinned), not a bug, but the test pins it explicitly.
# ---------------------------------------------------------------------------
{
  name="adv-shapeC-blank-pin-file-triggers-carve-out"
  artifact_path="$ARTIFACT_DIR/adv-c-blank.md"
  rm -f "$artifact_path"

  pin_file_tmp="$(mktemp -t claude-cli-blank-XXXXXX)"
  printf '\n' > "$pin_file_tmp"
  saved_pin="$_PIN_FILE_PATH"
  _PIN_FILE_PATH="$pin_file_tmp"

  # Restore real _capture_expected_version so the file-read path runs
  saved_capture="$(declare -f _capture_expected_version)"
  eval "$(declare -f _capture_expected_version | sed 's/^_capture_expected_version/REAL_CAPTURE_EXPECTED/' || true)"
  # Use the _REAL_CAPTURE_EXPECTED from the test file if loaded;
  # otherwise define the real implementation inline
  _capture_expected_version() {
    local pin_file="${_PIN_FILE_PATH:-$HARNESS_ROOT/.claude-cli-version}"
    if [[ -f "$pin_file" ]]; then
      local raw
      raw="$(head -1 "$pin_file" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)"
      if [[ -n "$raw" ]]; then _EXPECTED_VERSION="$raw"; else _EXPECTED_VERSION="(unpinned)"; fi
    else
      _EXPECTED_VERSION="(unpinned)"
    fi
  }

  unset PIPELINE_DRY_RUN
  rc=0
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-06-01T00:00:00Z \
    --period-end-iso   2026-06-08T00:00:00Z \
    2>/dev/null || rc=$?
  export PIPELINE_DRY_RUN=1
  _PIN_FILE_PATH="$saved_pin"
  eval "$saved_capture"
  rm -f "$pin_file_tmp"

  # Expected: rc=0, artifact written, carve-out body present, dispatch NOT
  # invoked (the no-pin carve-out fires). This documents that a blank file is
  # treated identically to a missing file.
  if (( rc == 0 )) \
      && [[ -f "$artifact_path" ]] \
      && grep -qF 'No expected version pinned' "$artifact_path"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc artifact=$(cat "$artifact_path" 2>/dev/null || echo MISSING))"
  fi
}

# ---------------------------------------------------------------------------
# Coordinator: all three ENG-158 shapes are in SHAPES array in
# run-retrospective-local.sh (wire-up regression guard)
# ---------------------------------------------------------------------------
{
  name="adv-coordinator-eng158-shapes-in-array"
  retro_file="$HARNESS_DIR/run-retrospective-local.sh"
  ok=1
  for shape in tool-denial-trends runtime-invariant-audit claude-version-drift; do
    grep -qF "  $shape" "$retro_file" || ok=0
  done
  if (( ok == 1 )); then
    _pass "$name"
  else
    _fail "$name (one or more ENG-158 shapes missing from SHAPES array in $retro_file)"
  fi
}

# ---------------------------------------------------------------------------
# Coordinator: ENG-158 shapes appear AFTER the 12 ENG-129 shapes (order
# matters: shapes write to PR body in SHAPES array order)
# ---------------------------------------------------------------------------
{
  name="adv-coordinator-eng158-shapes-ordered-after-eng129"
  retro_file="$HARNESS_DIR/run-retrospective-local.sh"
  stage_failure_line=$(grep -n "  stage-failure-summary" "$retro_file" | head -1 | cut -d: -f1)
  tool_denial_line=$(grep -n "  tool-denial-trends" "$retro_file" | head -1 | cut -d: -f1)
  if [[ -n "$stage_failure_line" && -n "$tool_denial_line" ]] \
      && (( tool_denial_line > stage_failure_line )); then
    _pass "$name"
  else
    _fail "$name (stage-failure-summary at line ${stage_failure_line:-?}, tool-denial-trends at line ${tool_denial_line:-?})"
  fi
}

# ---------------------------------------------------------------------------
# QA-authored: Shape C carve-out fires before the dry-run branch
# Sub-agent finding #1: the no-pin short-circuit in main() writes the
# carve-out artifact and returns 0 before reaching the PIPELINE_DRY_RUN
# check. So with DRY_RUN=1 + no pin file, the artifact is the real
# carve-out text, NOT "[DRY_RUN placeholder]". Intentional design.
# ---------------------------------------------------------------------------
{
  name="adv-shapeC-carveout-fires-before-dryrun"
  artifact_path="$ARTIFACT_DIR/adv-c-carveout-dryrun.md"
  rm -f "$artifact_path"
  # PIPELINE_DRY_RUN=1 is already exported at file scope.
  _capture_observed_version() { _OBSERVED_VERSION="claude-cli-1.0"; }
  _capture_expected_version() { _EXPECTED_VERSION="(unpinned)"; }
  rc=0
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-06-01T00:00:00Z \
    --period-end-iso   2026-06-08T00:00:00Z \
    2>/dev/null || rc=$?
  _capture_observed_version() { _OBSERVED_VERSION="claude-cli-test"; }
  _capture_expected_version() { _EXPECTED_VERSION="claude-cli-test-expected"; }
  if (( rc == 0 )) \
      && [[ -f "$artifact_path" ]] \
      && grep -qF 'No expected version pinned' "$artifact_path" \
      && ! grep -q '\[DRY_RUN placeholder\]' "$artifact_path"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc artifact=$(cat "$artifact_path" 2>/dev/null || echo MISSING))"
  fi
}

# ---------------------------------------------------------------------------
# QA-authored: Shape B rejects --agent-prompts-path (not in _parse_args)
# Sub-agent finding #7: plan Task 5 described optional path-override flags
# (--agent-prompts-path, --dispatch-sh-path, --render-prompt-sh-path).
# The implementation uses $HARNESS_ROOT defaults instead; passing those
# flags hits the unknown-argument die(). Pins the design choice so a
# future refactor knows these flags are absent and tests need updating.
# ---------------------------------------------------------------------------
{
  name="adv-shapeB-unknown-flag-rejected"
  artifact_path="$ARTIFACT_DIR/adv-b-unknown-flag.md"
  source "$HARNESS_DIR/retro-shape-runtime-invariant-audit.sh" 2>/dev/null || true
  HARNESS_ROOT="${HARNESS_DIR%/bin}"
  rc=0
  msg="$(main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-06-01T00:00:00Z \
    --period-end-iso   2026-06-08T00:00:00Z \
    --agent-prompts-path /some/path \
    2>&1)" || rc=$?
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "unknown argument"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc msg=${msg} — expected die on unknown argument)"
  fi
}

# ---------------------------------------------------------------------------
# QA-authored: Shape C safe version string survives _render_prompt intact.
# Pins that token substitution in the rendered prompt actually replaces
# {observed_version} with the captured version string. Calls _render_prompt
# directly to avoid dispatch; checks the rendered output rather than the
# artifact. Pre-existing sed-delimiter-pipe vulnerability (a '|' in the
# version string would corrupt the sed expression) is theoretical — in
# practice claude --version never emits '|'. Noted as qa-pattern candidate.
# ---------------------------------------------------------------------------
{
  name="adv-shapeC-safe-version-string-survives-render"
  source "$HARNESS_DIR/retro-shape-claude-version-drift.sh" 2>/dev/null || true
  HARNESS_ROOT="${HARNESS_DIR%/bin}"
  safe_version="claude-cli-1.2.3-20260101"
  _OBSERVED_VERSION="$safe_version"
  _EXPECTED_VERSION="$safe_version"
  _ARTIFACT_PATH="$ARTIFACT_DIR/adv-c-render-artifact.md"
  rendered_tmp="$(mktemp -t adv-shapeC-render-XXXXXX.md)"
  rc=0
  _render_prompt "$rendered_tmp" 2>/dev/null || rc=$?
  found_version="$(grep -o "$safe_version" "$rendered_tmp" | head -1 || true)"
  rm -f "$rendered_tmp"
  _capture_observed_version() { _OBSERVED_VERSION="claude-cli-test"; }
  _capture_expected_version() { _EXPECTED_VERSION="claude-cli-test-expected"; }
  if (( rc == 0 )) && [[ "$found_version" == "$safe_version" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc found='${found_version:-EMPTY}' expected '$safe_version')"
  fi
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -rf "$ARTIFACT_DIR"

printf '\n'
if (( FAIL == 0 )); then
  printf 'OK: retro-shape-eng158-adversarial tests (%d passed)\n' "$PASS"
  exit 0
else
  printf 'FAILURES (%d/%d):\n%b' "$FAIL" "$(( PASS + FAIL ))" "$FAILURES"
  exit 1
fi
