#!/usr/bin/env bash
# Tests for bin/retro-shape-runtime-invariant-audit.sh (ENG-158 Shape B).

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
    printf '## Resolver-path coverage\n\nnone\n\n## Bash(<x>:*) referenced-but-not-allowed\n\nnone\n\n## Stage-section table consistency\n\nnone\n' > "\$artifact_path"
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

source "$HARNESS_DIR/retro-shape-runtime-invariant-audit.sh"

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
# --previous-period-path to every shape. Shape B is a current-tree audit
# so it ignores the value, but it MUST accept the flag without `die`.
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
# fixture-3: token resolution — no leftover {token} for the 4 declared tokens
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
    for tok in agent_prompts_md_path dispatch_sh_path render_prompt_sh_path artifact_path; do
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
# fixture-4: dry-run path
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
# fixture-shapeB-sub-audit-headers: prompt body enumerates 3 sub-audits
# ---------------------------------------------------------------------------
{
  name="fixture-shapeB-sub-audit-headers"
  prompt_file="$HARNESS_DIR/retro-prompts/runtime-invariant-audit.md"
  ok=1
  for needle in "Resolver-path coverage" "Bash(<x>:*) referenced-but-not-allowed" "Stage-section table consistency"; do
    grep -qF "$needle" "$prompt_file" || ok=0
  done
  if (( ok == 1 )); then
    _pass "$name"
  else
    _fail "$name (one or more sub-audit headers missing from $prompt_file)"
  fi
}

# ---------------------------------------------------------------------------
# fixture-11: unresolved token in rendered prompt causes die
# ---------------------------------------------------------------------------
{
  name="fixture-11-unresolved-token-die"
  BOGUS_TEMPLATE="$(mktemp -t runtime-invariant-audit-XXXXXX.md)"
  cat "$HARNESS_DIR/retro-prompts/runtime-invariant-audit.md" > "$BOGUS_TEMPLATE"
  printf '\n{bogus_token}\n' >> "$BOGUS_TEMPLATE"

  original_render="$(declare -f _render_prompt)"
  _render_prompt() {
    local rendered="$1"
    sed \
      -e "s|{agent_prompts_md_path}|${HARNESS_ROOT}/AGENT_PROMPTS.md|g" \
      -e "s|{dispatch_sh_path}|${HARNESS_ROOT}/bin/dispatch.sh|g" \
      -e "s|{render_prompt_sh_path}|${HARNESS_ROOT}/bin/render-prompt.sh|g" \
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
  artifact_path="/no-such-dir-$$-shapeB/artifact.md"
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
  printf 'OK: retro-shape-runtime-invariant-audit tests (%d passed)\n' "$PASS"
  exit 0
else
  printf 'FAILURES (%d/%d):\n%b' "$FAIL" "$(( PASS + FAIL ))" "$FAILURES"
  exit 1
fi
