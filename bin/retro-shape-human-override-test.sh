#!/usr/bin/env bash
# Tests for bin/retro-shape-human-override.sh.

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
    printf '## Human override analysis\n\nnone\n' > "\$artifact_path"
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

source "$HARNESS_DIR/retro-shape-human-override.sh"
SCRIPT_DIR="$STUB_DIR"

{
  name="fixture-1-argv-missing-artifact-path"
  rc=0
  msg="$(main --period-start-iso 2026-05-08T00:00:00Z --period-end-iso 2026-05-15T00:00:00Z 2>&1)" || rc=$?
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "artifact-path"; then _pass "$name"; else _fail "$name (rc=$rc msg=$msg)"; fi
}

{
  name="fixture-2-argv-happy-path-dryrun"
  artifact_path="$ARTIFACT_DIR/f2.md"
  rc=0
  main --artifact-path "$artifact_path" --period-start-iso 2026-05-08T00:00:00Z --period-end-iso 2026-05-15T00:00:00Z 2>/dev/null || rc=$?
  if (( rc == 0 )) && [[ -f "$artifact_path" ]]; then _pass "$name"; else _fail "$name (rc=$rc)"; fi
}

{
  name="fixture-3-token-resolution"
  artifact_path="$ARTIFACT_DIR/f3.md"
  export SHAPE_TEST_ARTIFACT_PATH="$artifact_path"
  rm -f "$RENDERED_PROMPT_COPY" "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 yes
  unset PIPELINE_DRY_RUN
  rc=0
  main --artifact-path "$artifact_path" --period-start-iso 2026-05-08T00:00:00Z --period-end-iso 2026-05-15T00:00:00Z 2>/dev/null || rc=$?
  export PIPELINE_DRY_RUN=1
  if [[ -f "$RENDERED_PROMPT_COPY" ]]; then
    unresolved=""
    for tok in events_jsonl_path period_start_iso period_end_iso artifact_path previous_period_path project_profile_path; do
      if grep -qF "{${tok}}" "$RENDERED_PROMPT_COPY"; then unresolved="${unresolved} {${tok}}"; fi
    done
    if [[ -z "$unresolved" ]]; then _pass "$name"; else _fail "$name (unresolved:$unresolved)"; fi
  else
    _fail "$name (rendered prompt not captured; rc=$rc)"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
}

{
  name="fixture-4-dryrun-no-dispatch"
  artifact_path="$ARTIFACT_DIR/f4.md"
  rm -f "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 yes
  rc=0
  main --artifact-path "$artifact_path" --period-start-iso 2026-05-08T00:00:00Z --period-end-iso 2026-05-15T00:00:00Z 2>/dev/null || rc=$?
  dispatch_called=$([[ -f "$DISPATCH_INVOKED" ]] && echo yes || echo no)
  if (( rc == 0 )) && [[ "$dispatch_called" == "no" ]] && [[ -f "$artifact_path" ]]; then _pass "$name"; else _fail "$name (rc=$rc dispatched=$dispatch_called)"; fi
}

{
  name="fixture-5-artifact-missing-die"
  artifact_path="$ARTIFACT_DIR/f5.md"
  rm -f "$artifact_path" "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 no
  unset PIPELINE_DRY_RUN
  rc=0
  msg="$(main --artifact-path "$artifact_path" --period-start-iso 2026-05-08T00:00:00Z --period-end-iso 2026-05-15T00:00:00Z 2>&1)" || rc=$?
  export PIPELINE_DRY_RUN=1
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "artifact not written"; then _pass "$name"; else _fail "$name (rc=$rc msg=$msg)"; fi
}

{
  name="fixture-6-dispatch-rc-non-zero"
  artifact_path="$ARTIFACT_DIR/f6.md"
  rm -f "$DISPATCH_INVOKED"
  _write_dispatch_stub 29 no
  unset PIPELINE_DRY_RUN
  rc=0
  msg="$(main --artifact-path "$artifact_path" --period-start-iso 2026-05-08T00:00:00Z --period-end-iso 2026-05-15T00:00:00Z 2>&1)" || rc=$?
  export PIPELINE_DRY_RUN=1
  if (( rc != 0 )) && printf '%s' "$msg" | grep -q "rc=29"; then _pass "$name"; else _fail "$name (rc=$rc msg=$msg)"; fi
}

# fixture-7: per-shape extra token (project_profile_path) renders
{
  name="fixture-7-extra-token-project-profile-path-rendered"
  artifact_path="$ARTIFACT_DIR/f7.md"
  export SHAPE_TEST_ARTIFACT_PATH="$artifact_path"
  rm -f "$RENDERED_PROMPT_COPY" "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 yes
  unset PIPELINE_DRY_RUN
  rc=0
  main --artifact-path "$artifact_path" --period-start-iso 2026-05-08T00:00:00Z --period-end-iso 2026-05-15T00:00:00Z 2>/dev/null || rc=$?
  export PIPELINE_DRY_RUN=1
  if [[ -f "$RENDERED_PROMPT_COPY" ]] && grep -qF "learned-rules/${PROJECT_SLUG}/project-profile.md" "$RENDERED_PROMPT_COPY"; then
    _pass "$name"
  else
    _fail "$name (project_profile_path not substituted; rc=$rc)"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
}

rm -rf "$STUB_DIR" "$ARTIFACT_DIR"

printf '\n'
if (( FAIL == 0 )); then
  printf 'OK: retro-shape-human-override tests (%d passed)\n' "$PASS"
  exit 0
else
  printf 'FAILURES (%d/%d):\n%b' "$FAIL" "$(( PASS + FAIL ))" "$FAILURES"
  exit 1
fi
