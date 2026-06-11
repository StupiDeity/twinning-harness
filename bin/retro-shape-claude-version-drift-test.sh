#!/usr/bin/env bash
# Tests for bin/retro-shape-claude-version-drift.sh (ENG-158 Shape C).

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
    printf '## Observation\n\nplaceholder\n' > "\$artifact_path"
  fi
fi
exit $rc
STUB
  chmod +x "$STUB_DIR/dispatch.sh"
}

_write_dispatch_stub 0 yes

# common.sh OVERWRITES HARNESS_ROOT to (dirname BASH_SOURCE)/.. at source time
# (see bin/common.sh:9), so a test-time `export HARNESS_ROOT=...` is dead.
# We therefore monkeypatch _capture_observed_version / _capture_expected_version
# per-fixture instead of routing the pin-file lookup through a fake HARNESS_ROOT.
export TARGET_REPO="${TARGET_REPO:-$HARNESS_DIR}"
export HARNESS_STATE_DIR="${HARNESS_STATE_DIR:-$(mktemp -d)}"
export PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-$(mktemp -d)}"

source "$HARNESS_DIR/retro-shape-claude-version-drift.sh"

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
# fixture-prev-period-accepted: coordinator (ENG-130) passes
# --previous-period-path to every shape. Shape C does not consume the
# value (drift is a current-vs-pin comparison) but MUST accept the flag.
# ---------------------------------------------------------------------------
{
  name="fixture-prev-period-path-accepted"
  artifact_path="$ARTIFACT_DIR/fprev.md"
  export SHAPE_TEST_ARTIFACT_PATH="$artifact_path"
  rc=0
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    --previous-period-path "(none)" \
    2>/dev/null || rc=$?
  if (( rc == 0 )) && [[ -f "$artifact_path" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc — driver rejected --previous-period-path)"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
}

# ---------------------------------------------------------------------------
# fixture-2: dry-run happy path
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
    _fail "$name (rc=$rc)"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
}

# ---------------------------------------------------------------------------
# fixture-3: token resolution — no leftover {token}
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
    for tok in observed_version expected_version artifact_path; do
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
    _fail "$name (rc=$rc dispatch_called=$dispatch_called placeholder=$placeholder_exists)"
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
    _fail "$name (rc=$rc)"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
}

# ---------------------------------------------------------------------------
# fixture-6: artifact missing
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
# fixture-shapeC-version-file-present: monkeypatch _capture_expected_version
# to simulate the pin file being present → rendered prompt carries the
# expected version string
# ---------------------------------------------------------------------------
{
  name="fixture-shapeC-version-file-present"
  artifact_path="$ARTIFACT_DIR/fC1.md"
  export SHAPE_TEST_ARTIFACT_PATH="$artifact_path"
  rm -f "$RENDERED_PROMPT_COPY" "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 yes

  original_capture_expected="$(declare -f _capture_expected_version)"
  _capture_expected_version() { _EXPECTED_VERSION="claude-cli-1.2.3-rc4"; }

  unset PIPELINE_DRY_RUN
  rc=0
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>/dev/null || rc=$?
  export PIPELINE_DRY_RUN=1
  eval "$original_capture_expected"

  if [[ -f "$RENDERED_PROMPT_COPY" ]] && grep -qF 'claude-cli-1.2.3-rc4' "$RENDERED_PROMPT_COPY"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc expected version string not in rendered prompt)"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
}

# ---------------------------------------------------------------------------
# fixture-shapeC-version-file-absent: monkeypatch _capture_expected_version
# to simulate the pin file being absent → rendered prompt carries (unpinned)
# ---------------------------------------------------------------------------
{
  name="fixture-shapeC-version-file-absent"
  artifact_path="$ARTIFACT_DIR/fC2.md"
  export SHAPE_TEST_ARTIFACT_PATH="$artifact_path"
  rm -f "$RENDERED_PROMPT_COPY" "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 yes

  original_capture_expected="$(declare -f _capture_expected_version)"
  _capture_expected_version() { _EXPECTED_VERSION="(unpinned)"; }

  unset PIPELINE_DRY_RUN
  rc=0
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>/dev/null || rc=$?
  export PIPELINE_DRY_RUN=1
  eval "$original_capture_expected"

  if [[ -f "$RENDERED_PROMPT_COPY" ]] && grep -qF '(unpinned)' "$RENDERED_PROMPT_COPY"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc expected '(unpinned)' in rendered prompt)"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
}

# ---------------------------------------------------------------------------
# fixture-shapeC-claude-binary-unavailable: monkeypatch _capture_observed_version
# to simulate claude absent → (unavailable)
# ---------------------------------------------------------------------------
{
  name="fixture-shapeC-claude-binary-unavailable"
  artifact_path="$ARTIFACT_DIR/fC3.md"
  export SHAPE_TEST_ARTIFACT_PATH="$artifact_path"
  rm -f "$RENDERED_PROMPT_COPY" "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 yes

  # Override _capture_observed_version to force the "claude missing" branch
  # without disturbing PATH (which would break standard utilities used by
  # main/render/dispatch in the same shell).
  original_capture="$(declare -f _capture_observed_version)"
  _capture_observed_version() { _OBSERVED_VERSION="(unavailable)"; }

  unset PIPELINE_DRY_RUN
  rc=0
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>/dev/null || rc=$?
  export PIPELINE_DRY_RUN=1
  eval "$original_capture"

  if [[ -f "$RENDERED_PROMPT_COPY" ]] && grep -qF '(unavailable)' "$RENDERED_PROMPT_COPY"; then
    _pass "$name"
  else
    _fail "$name (rc=$rc expected '(unavailable)' in rendered prompt)"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
}

# ---------------------------------------------------------------------------
# fixture-11: unresolved token in rendered prompt causes die
# ---------------------------------------------------------------------------
{
  name="fixture-11-unresolved-token-die"
  BOGUS_TEMPLATE="$(mktemp -t claude-version-drift-XXXXXX.md)"
  cat "$HARNESS_DIR/retro-prompts/claude-version-drift.md" > "$BOGUS_TEMPLATE"
  printf '\n{bogus_token}\n' >> "$BOGUS_TEMPLATE"

  original_render="$(declare -f _render_prompt)"
  _render_prompt() {
    local rendered="$1"
    sed \
      -e "s|{observed_version}|${_OBSERVED_VERSION}|g" \
      -e "s|{expected_version}|${_EXPECTED_VERSION}|g" \
      -e "s|{artifact_path}|${_ARTIFACT_PATH}|g" \
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
  artifact_path="/no-such-dir-$$-shapeC/artifact.md"
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
  printf 'OK: retro-shape-claude-version-drift tests (%d passed)\n' "$PASS"
  exit 0
else
  printf 'FAILURES (%d/%d):\n%b' "$FAIL" "$(( PASS + FAIL ))" "$FAILURES"
  exit 1
fi
