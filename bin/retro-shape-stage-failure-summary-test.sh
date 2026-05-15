#!/usr/bin/env bash
# Tests for bin/retro-shape-stage-failure-summary.sh and
# the _compute_retro_period helper in bin/run-retrospective-local.sh.
#
# Source-and-stub pattern (per CLAUDE.md "How tests work"):
#   1. PIPELINE_DRY_RUN=1 + LINEAR_API_KEY set before source.
#   2. Source the shape script to get functions without firing main.
#   3. STUB_DIR contains a fake dispatch.sh; SCRIPT_DIR is overridden post-source.

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
# Shared setup: stub dir + temp dirs.
# ---------------------------------------------------------------------------
STUB_DIR="$(mktemp -d)"
ARTIFACT_DIR="$(mktemp -d)"
DISPATCH_INVOKED="$STUB_DIR/dispatch_invoked"
RENDERED_PROMPT_COPY="$STUB_DIR/rendered_prompt_copy"
DISPATCH_RC=0

# Default stub: capture call, write a placeholder artifact (path comes from env).
_write_dispatch_stub() {
  local rc="${1:-0}"
  local write_artifact="${2:-yes}"
  cat > "$STUB_DIR/dispatch.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "dispatched \$*" >> "$DISPATCH_INVOKED"
# capture rendered prompt for inspection
if [[ -f "\${2:-}" ]]; then cp "\${2:-}" "$RENDERED_PROMPT_COPY"; fi
if [[ "$write_artifact" == "yes" ]]; then
  artifact_path="\${SHAPE_TEST_ARTIFACT_PATH:-}"
  if [[ -n "\$artifact_path" ]]; then
    printf '## Outcome breakdown (period vs previous)\n\nnone\n\n## Recurring reasons (stages with >=3 rejections)\n\nnone\n' > "\$artifact_path"
  fi
fi
exit $rc
STUB
  chmod +x "$STUB_DIR/dispatch.sh"
}

_write_dispatch_stub 0 yes

# ---------------------------------------------------------------------------
# Source the shape script (sentinel prevents main from firing).
# HARNESS_ROOT and TARGET_REPO must be set; common.sh needs them.
# ---------------------------------------------------------------------------
export TARGET_REPO="${TARGET_REPO:-$HARNESS_DIR}"
export HARNESS_ROOT="${HARNESS_ROOT:-$HARNESS_DIR}"
export HARNESS_STATE_DIR="${HARNESS_STATE_DIR:-$(mktemp -d)}"
export PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-$(mktemp -d)}"

source "$HARNESS_DIR/retro-shape-stage-failure-summary.sh"

# Override SCRIPT_DIR so bash "$SCRIPT_DIR/dispatch.sh" resolves to STUB_DIR.
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
# fixture-2: argv happy path in dry-run — placeholder artifact created
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
# fixture-3: token resolution — no {token} leftovers in rendered prompt
# ---------------------------------------------------------------------------
{
  name="fixture-3-token-resolution"
  artifact_path="$ARTIFACT_DIR/f3.md"
  export SHAPE_TEST_ARTIFACT_PATH="$artifact_path"
  # Non-dry-run: dispatch stub captures the rendered prompt.
  rm -f "$RENDERED_PROMPT_COPY" "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 yes
  ORIGINAL_DRY_RUN="${PIPELINE_DRY_RUN:-}"
  unset PIPELINE_DRY_RUN
  rc=0
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>/dev/null || rc=$?
  export PIPELINE_DRY_RUN=1
  if [[ -f "$RENDERED_PROMPT_COPY" ]]; then
    leftover="$(grep -oE '\{[a-z_]+\}' "$RENDERED_PROMPT_COPY" | grep -v 'artifact_path\|events_jsonl_path\|period_start_iso\|period_end_iso\|previous_period_path' | head -1 || true)"
    # jq filter lines in the prompt contain literal {field} — those are intentional illustrative uses
    # The validator checks for unresolved tokens: any {snake_case} that was NOT in our 5 known tokens
    # We need to check that none of the 5 declared tokens remain unresolved
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
    _fail "$name (rendered prompt not captured; dispatch may not have been called; rc=$rc)"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
}

# ---------------------------------------------------------------------------
# fixture-4: dry-run — dispatch stub NOT invoked; placeholder artifact exists
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
# fixture-5: artifact production — non-dry-run, stub writes artifact
# ---------------------------------------------------------------------------
{
  name="fixture-5-artifact-production"
  artifact_path="$ARTIFACT_DIR/f5.md"
  export SHAPE_TEST_ARTIFACT_PATH="$artifact_path"
  rm -f "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 yes
  ORIGINAL_DRY_RUN="${PIPELINE_DRY_RUN:-}"
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
# fixture-6: artifact missing — stub returns 0 but does NOT write artifact
# ---------------------------------------------------------------------------
{
  name="fixture-6-artifact-missing"
  artifact_path="$ARTIFACT_DIR/f6.md"
  rm -f "$artifact_path" "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 no
  ORIGINAL_DRY_RUN="${PIPELINE_DRY_RUN:-}"
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
# fixture-7: optional --previous-period-path defaults to (none)
# ---------------------------------------------------------------------------
{
  name="fixture-7-previous-period-default"
  artifact_path="$ARTIFACT_DIR/f7.md"
  export SHAPE_TEST_ARTIFACT_PATH="$artifact_path"
  rm -f "$RENDERED_PROMPT_COPY" "$DISPATCH_INVOKED"
  _write_dispatch_stub 0 yes
  ORIGINAL_DRY_RUN="${PIPELINE_DRY_RUN:-}"
  unset PIPELINE_DRY_RUN
  rc=0
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>/dev/null || rc=$?
  export PIPELINE_DRY_RUN=1
  if [[ -f "$RENDERED_PROMPT_COPY" ]]; then
    if grep -qF '(none)' "$RENDERED_PROMPT_COPY"; then
      _pass "$name"
    else
      _fail "$name (expected '(none)' in rendered prompt for previous_period_path)"
    fi
  else
    _fail "$name (rendered prompt not captured; rc=$rc)"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
}

# ---------------------------------------------------------------------------
# fixture-8: dispatch failure (rc=29) — shape dies with rc != 0, message contains rc=29
# ---------------------------------------------------------------------------
{
  name="fixture-8-dispatch-rc-non-zero"
  artifact_path="$ARTIFACT_DIR/f8.md"
  rm -f "$DISPATCH_INVOKED"
  _write_dispatch_stub 29 no
  ORIGINAL_DRY_RUN="${PIPELINE_DRY_RUN:-}"
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
# fixture-9: prompt body carries empty-events carve-out text
# ---------------------------------------------------------------------------
{
  name="fixture-9-prompt-body-carries-empty-events-carve-out"
  prompt_file="$HARNESS_DIR/retro-prompts/stage-failure-summary.md"
  if grep -q "absent or empty" "$prompt_file"; then
    _pass "$name"
  else
    _fail "$name (carve-out text not found in $prompt_file)"
  fi
}

# ---------------------------------------------------------------------------
# fixture-10: _compute_retro_period — fallback when no prior retrospective merge
# ---------------------------------------------------------------------------
{
  name="fixture-10-period-fallback-no-prior-merge"
  # Source run-retrospective-local.sh to get _compute_retro_period.
  # Stub git to return empty output for the --merges grep call.
  ORIG_SCRIPT_DIR="$SCRIPT_DIR"
  GIT_STUB_DIR="$(mktemp -d)"
  cat > "$GIT_STUB_DIR/git" <<'GITSTUB'
#!/usr/bin/env bash
# Only intercept `git -C <dir> log --merges ...`; pass everything else through.
args=("$@")
is_log=false
for a in "${args[@]}"; do [[ "$a" == "log" ]] && is_log=true; done
if $is_log; then
  exit 0  # emit nothing — simulates no prior retrospective merge
fi
command git "$@"
GITSTUB
  chmod +x "$GIT_STUB_DIR/git"
  ORIG_PATH="$PATH"
  export PATH="$GIT_STUB_DIR:$PATH"

  # Source the retrospective driver for _compute_retro_period only.
  # We need to avoid firing its main; it doesn't have the sentinel guard
  # at definition level, but common.sh's require_env/require_bin would
  # fire if we're not careful. Source it inside a subshell instead.
  period_output="$(
    export PIPELINE_DRY_RUN=1
    export TARGET_REPO="${TARGET_REPO:-$HARNESS_DIR}"
    source "$HARNESS_DIR/run-retrospective-local.sh" 2>/dev/null || true
    _compute_retro_period 2>/dev/null
  )" || true
  export PATH="$ORIG_PATH"

  if [[ -n "$period_output" ]]; then
    start_line="$(printf '%s' "$period_output" | sed -n '1p')"
    end_line="$(printf '%s' "$period_output" | sed -n '2p')"
    # Verify start is roughly 30 days before end (not exact; just check they differ)
    if [[ -n "$start_line" && -n "$end_line" && "$start_line" != "$end_line" ]]; then
      _pass "$name"
    else
      _fail "$name (start=$start_line end=$end_line)"
    fi
  else
    _fail "$name (no output from _compute_retro_period; function may not exist yet)"
  fi
  SCRIPT_DIR="$ORIG_SCRIPT_DIR"
}

# ---------------------------------------------------------------------------
# fixture-11: unresolved token in rendered prompt causes die
# ---------------------------------------------------------------------------
{
  name="fixture-11-unresolved-token-die"
  # Temporarily create a patched template with a bogus token.
  BOGUS_TEMPLATE="$(mktemp -t stage-failure-summary-XXXXXX.md)"
  cat "$HARNESS_DIR/retro-prompts/stage-failure-summary.md" > "$BOGUS_TEMPLATE"
  printf '\n{bogus_token}\n' >> "$BOGUS_TEMPLATE"

  # Override the prompt path inside _render_prompt by monkeypatching.
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

  # Restore original _render_prompt
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
  artifact_path="/no-such-dir-$$-xyz/artifact.md"
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
# fixture-13: same-day rerun overwrites artifact
# ---------------------------------------------------------------------------
{
  name="fixture-13-same-day-rerun-overwrites"
  artifact_path="$ARTIFACT_DIR/f13.md"
  export SHAPE_TEST_ARTIFACT_PATH="$artifact_path"

  # First call: stub writes "CALL1"
  cat > "$STUB_DIR/dispatch.sh" <<STUB1
#!/usr/bin/env bash
printf '%s\n' "dispatched" >> "$DISPATCH_INVOKED"
printf 'CALL1\n' > "${SHAPE_TEST_ARTIFACT_PATH:-}"
exit 0
STUB1
  chmod +x "$STUB_DIR/dispatch.sh"

  ORIGINAL_DRY_RUN="${PIPELINE_DRY_RUN:-}"
  unset PIPELINE_DRY_RUN
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>/dev/null || true

  # Second call: stub writes "CALL2"
  cat > "$STUB_DIR/dispatch.sh" <<STUB2
#!/usr/bin/env bash
printf '%s\n' "dispatched" >> "$DISPATCH_INVOKED"
printf 'CALL2\n' > "${SHAPE_TEST_ARTIFACT_PATH:-}"
exit 0
STUB2
  chmod +x "$STUB_DIR/dispatch.sh"

  rc=0
  main \
    --artifact-path "$artifact_path" \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z \
    2>/dev/null || rc=$?
  export PIPELINE_DRY_RUN=1

  content="$([[ -f "$artifact_path" ]] && cat "$artifact_path" || echo '')"
  if (( rc == 0 )) && [[ "$content" == "CALL2" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc content=$content)"
  fi
  export SHAPE_TEST_ARTIFACT_PATH=""
  # Restore default stub
  _write_dispatch_stub 0 yes
}

# ---------------------------------------------------------------------------
# Cleanup and summary
# ---------------------------------------------------------------------------
rm -rf "$STUB_DIR" "$ARTIFACT_DIR"

printf '\n'
if (( FAIL == 0 )); then
  printf 'OK: retro-shape-stage-failure-summary tests (%d passed)\n' "$PASS"
  exit 0
else
  printf 'FAILURES (%d/%d):\n%b' "$FAIL" "$(( PASS + FAIL ))" "$FAILURES"
  exit 1
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  : # already running as main script
fi
