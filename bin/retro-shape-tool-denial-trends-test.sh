#!/usr/bin/env bash
# Tests for bin/retro-shape-tool-denial-trends.sh (ENG-158 Shape A).
#
# Source-and-stub pattern, mirroring bin/retro-shape-stage-failure-summary-test.sh.

set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"

PASS=0
FAIL=0
FAILURES=""

_pass() { printf 'PASS: %s\n' "$1"; (( PASS++ )) || true; }
_fail() { printf 'FAIL: %s\n' "$1"; FAILURES="${FAILURES}  - $1\n"; (( FAIL++ )) || true; }

# ---------------------------------------------------------------------------
# Shared setup
# ---------------------------------------------------------------------------
STUB_DIR="$(mktemp -d)"
ARTIFACT_DIR="$(mktemp -d)"
DISPATCH_INVOKED="$STUB_DIR/dispatch_invoked"
RENDERED_PROMPT_COPY="$STUB_DIR/rendered_prompt_copy"

_write_dispatch_stub() {
  local rc="${1:-0}"
  local write_artifact="${2:-yes}"
  cat > "$STUB_DIR/dispatch.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "dispatched \$*" >> "$DISPATCH_INVOKED"
if [[ -f "\${2:-}" ]]; then cp "\${2:-}" "$RENDERED_PROMPT_COPY"; fi
if [[ "$write_artifact" == "yes" ]]; then
  artifact_path="\${SHAPE_TEST_ARTIFACT_PATH:-}"
  if [[ -n "\$artifact_path" ]]; then
    printf '## Denials by (claude_version x stage)\n\nnone\n\n## Top gradient finding\n\nnone\n' > "\$artifact_path"
  fi
fi
exit $rc
STUB
  chmod +x "$STUB_DIR/dispatch.sh"
}

_write_dispatch_stub 0 yes

export TARGET_REPO="${TARGET_REPO:-$HARNESS_DIR}"
export HARNESS_ROOT="${HARNESS_ROOT:-$HARNESS_DIR}"
export HARNESS_STATE_DIR="${HARNESS_STATE_DIR:-$(mktemp -d)}"
export PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-$(mktemp -d)}"

source "$HARNESS_DIR/retro-shape-tool-denial-trends.sh"

SCRIPT_DIR="$STUB_DIR"

# ---------------------------------------------------------------------------
# fixture-1: missing --artifact-path dies
# ---------------------------------------------------------------------------
{
  name="fixture-1-argv-missing-artifact-path"
  rc=0
  msg=""
  msg="$(main --period-start-iso 2026-05-08T00:00:00Z --period-end-iso 2026-05-15T00:00:00Z 2>&1)" || rc=$?
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "artifact-path"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc msg=$msg)"
  fi
}

# ---------------------------------------------------------------------------
# fixture-2: argv happy path in dry-run
# ---------------------------------------------------------------------------
{
  name="fixture-2-argv-happy-path-dryrun"
  artifact_path="$ARTIFACT_DIR/f2.md"
  export SHAPE_TEST_ARTIFACT_PATH="$artifact_path"
  rc=0
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>/dev/null || rc=$?
  if (( rc == 0 )) && [[ -f "$artifact_path" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc artifact_exists=$(test -f "$artifact_path" && echo yes || echo no))"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
}

# ---------------------------------------------------------------------------
# fixture-3: token resolution — no leftover {token} for the 5 declared tokens
# ---------------------------------------------------------------------------
{
  name="fixture-3-token-resolution"
  artifact_path="$ARTIFACT_DIR/f3.md"
  export SHAPE_TEST_ARTIFACT_PATH="$artifact_path"
  rm -f "$RENDERED_PROMPT_COPY" "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 yes
  unset PIPELINE_DRY_RUN
  rc=0
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>/dev/null || rc=$?
  export PIPELINE_DRY_RUN=1
  if [[ -f "$RENDERED_PROMPT_COPY" ]]; then
    unresolved=""
    for tok in events_jsonl_path period_start_iso period_end_iso artifact_path previous_period_path; do
      if grep -qF "{${tok}}" "$RENDERED_PROMPT_COPY"; then
        unresolved="${unresolved} {${tok}}"
      fi
    done
    if [[ -z "$unresolved" ]]; then
      _pass "$name"
    else
      _fail "$name (unresolved tokens:$unresolved)"
    fi
  else
    _fail "$name (rendered prompt not captured; rc=$rc)"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
}

# ---------------------------------------------------------------------------
# fixture-4: dry-run path — dispatch stub NOT invoked
# ---------------------------------------------------------------------------
{
  name="fixture-4-dryrun-path"
  artifact_path="$ARTIFACT_DIR/f4.md"
  rm -f "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 yes
  rc=0
  out="$(main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>&1)" || rc=$?
  dispatch_called=$([[ -f "$DISPATCH_INVOKED" ]] && echo yes || echo no)
  placeholder_exists=$([[ -f "$artifact_path" ]] && echo yes || echo no)
  dryrun_logged=$(printf '%s' "$out" | grep -c '\[DRY_RUN\]' || true)
  if (( rc == 0 )) \
      && [[ "$dispatch_called" == "no" ]] \
      && [[ "$placeholder_exists" == "yes" ]] \
      && (( dryrun_logged >= 1 )); then
    _pass "$name"
  else
    _fail "$name (rc=$rc dispatch_called=$dispatch_called placeholder=$placeholder_exists dryrun_logged=$dryrun_logged)"
  fi
}

# ---------------------------------------------------------------------------
# fixture-5: artifact production — non-dry-run
# ---------------------------------------------------------------------------
{
  name="fixture-5-artifact-production"
  artifact_path="$ARTIFACT_DIR/f5.md"
  export SHAPE_TEST_ARTIFACT_PATH="$artifact_path"
  rm -f "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 yes
  unset PIPELINE_DRY_RUN
  rc=0
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>/dev/null || rc=$?
  export PIPELINE_DRY_RUN=1
  if (( rc == 0 )) && [[ -f "$artifact_path" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc artifact_exists=$([[ -f "$artifact_path" ]] && echo yes || echo no))"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
}

# ---------------------------------------------------------------------------
# fixture-6: artifact missing — stub returns 0 but writes nothing
# ---------------------------------------------------------------------------
{
  name="fixture-6-artifact-missing"
  artifact_path="$ARTIFACT_DIR/f6.md"
  rm -f "$artifact_path" "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 no
  unset PIPELINE_DRY_RUN
  rc=0
  msg="$(main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>&1)" || rc=$?
  export PIPELINE_DRY_RUN=1
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "artifact not written"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc msg=$msg)"
  fi
}

# ---------------------------------------------------------------------------
# fixture-8: dispatch rc non-zero
# ---------------------------------------------------------------------------
{
  name="fixture-8-dispatch-rc-non-zero"
  artifact_path="$ARTIFACT_DIR/f8.md"
  rm -f "$DISPATCH_INVOKED"
  _write_dispatch_stub 29 no
  unset PIPELINE_DRY_RUN
  rc=0
  msg="$(main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>&1)" || rc=$?
  export PIPELINE_DRY_RUN=1
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "rc=29"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc msg=$msg)"
  fi
}

# ---------------------------------------------------------------------------
# fixture-9: prompt body carries insufficient-sample carve-out text
# ---------------------------------------------------------------------------
{
  name="fixture-9-prompt-body-carries-carve-out"
  prompt_file="$HARNESS_DIR/retro-prompts/tool-denial-trends.md"
  if grep -q "No sandbox_denial events in period" "$prompt_file"; then
    _pass "$name"
  else
    _fail "$name (carve-out text not found in $prompt_file)"
  fi
}

# ---------------------------------------------------------------------------
# fixture-shapeA-selector-present: prompt body references sandbox_denial selector
# ---------------------------------------------------------------------------
{
  name="fixture-shapeA-selector-present"
  prompt_file="$HARNESS_DIR/retro-prompts/tool-denial-trends.md"
  if grep -qF 'select(.event == "sandbox_denial")' "$prompt_file"; then
    _pass "$name"
  else
    _fail "$name (sandbox_denial selector not found in $prompt_file)"
  fi
}

# ---------------------------------------------------------------------------
# fixture-11: unresolved token in rendered prompt causes die
# ---------------------------------------------------------------------------
{
  name="fixture-11-unresolved-token-die"
  BOGUS_TEMPLATE="$(mktemp -t tool-denial-trends-XXXXXX.md)"
  cat "$HARNESS_DIR/retro-prompts/tool-denial-trends.md" > "$BOGUS_TEMPLATE"
  printf '\n{bogus_token}\n' >> "$BOGUS_TEMPLATE"

  original_render="$(declare -f _render_prompt)"
  _render_prompt() {
    local rendered="$1"
    sed \
      -e "s|{events_jsonl_path}|${PROJECT_STATE_DIR}/metrics/events.jsonl|g" \
      -e "s|{period_start_iso}|${_PERIOD_START_ISO}|g" \
      -e "s|{period_end_iso}|${_PERIOD_END_ISO}|g" \
      -e "s|{artifact_path}|${_ARTIFACT_PATH}|g" \
      -e "s|{previous_period_path}|${_PREVIOUS_PERIOD_PATH}|g" \
      "$BOGUS_TEMPLATE" > "$rendered"
  }

  artifact_path="$ARTIFACT_DIR/f11.md"
  rc=0
  msg="$(main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>&1)" || rc=$?
  rm -f "$BOGUS_TEMPLATE"
  eval "$original_render"

  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "unresolved token"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc msg=$msg)"
  fi
}

# ---------------------------------------------------------------------------
# fixture-12: parent dir missing causes die
# ---------------------------------------------------------------------------
{
  name="fixture-12-parent-dir-missing-die"
  artifact_path="/no-such-dir-$$-shapeA/artifact.md"
  rc=0
  msg="$(main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>&1)" || rc=$?
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "parent directory"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc msg=$msg)"
  fi
}

# ---------------------------------------------------------------------------
# Cleanup and summary
# ---------------------------------------------------------------------------
rm -rf "$STUB_DIR" "$ARTIFACT_DIR"

printf '\n'
if (( FAIL == 0 )); then
  printf 'OK: retro-shape-tool-denial-trends tests (%d passed)\n' "$PASS"
  exit 0
else
  printf 'FAILURES (%d/%d):\n%b' "$FAIL" "$(( PASS + FAIL ))" "$FAILURES"
  exit 1
fi
