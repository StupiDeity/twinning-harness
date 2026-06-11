#!/usr/bin/env bash
# Tests for bin/run-retrospective-local.sh — coordinator-level SHAPES
# iteration, PR-body composition, and slack/gh notification semantics.
#
# Source-and-stub pattern per CLAUDE.md "How tests work".

set -uo pipefail
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
# Per-test setup helper: prepare a disposable TARGET_REPO + PROJECT_STATE_DIR,
# stub the SHAPES drivers under STUB_BIN, stub gh + slack, then source the
# coordinator and override SCRIPT_DIR.
#
# Globals set:
#   STUB_BIN, ARGV_LOG, SLACK_LOG, GH_LOG, TARGET_REPO, PROJECT_STATE_DIR,
#   PR_BODY_PATH (after running main())
# ---------------------------------------------------------------------------
_new_test_env() {
  STUB_BIN="$(mktemp -d)"
  TARGET_REPO_BASE="$(mktemp -d)"
  PROJECT_STATE_DIR_BASE="$(mktemp -d)"
  HARNESS_STATE_DIR_BASE="$(mktemp -d)"
  ARGV_LOG="$STUB_BIN/argv.log"
  SLACK_LOG="$STUB_BIN/slack.log"
  GH_LOG="$STUB_BIN/gh.log"
  : > "$ARGV_LOG"
  : > "$SLACK_LOG"
  : > "$GH_LOG"

  export TARGET_REPO="$TARGET_REPO_BASE"
  export PROJECT_STATE_DIR="$PROJECT_STATE_DIR_BASE"
  export HARNESS_STATE_DIR="$HARNESS_STATE_DIR_BASE"

  # Initialize disposable git repo as TARGET_REPO.
  (
    cd "$TARGET_REPO"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "init"
    # Establish 'origin' that points at ourselves so fetch origin main works.
    git remote add origin "$TARGET_REPO" 2>/dev/null || true
    git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "noop2"
    git update-ref refs/remotes/origin/main HEAD
  )

  # Stub slack.sh — record argv to SLACK_LOG.
  cat > "$STUB_BIN/slack.sh" <<SLACK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SLACK_LOG"
exit 0
SLACK
  chmod +x "$STUB_BIN/slack.sh"

  # Stub dispatch.sh — should never be called by coordinator (each shape stub
  # is invoked directly; coordinator does not call dispatch.sh).
  cat > "$STUB_BIN/dispatch.sh" <<DISPATCH
#!/usr/bin/env bash
printf 'dispatch.sh invoked: %s\n' "\$*" >> "$ARGV_LOG"
exit 0
DISPATCH
  chmod +x "$STUB_BIN/dispatch.sh"

  # Stub gh in PATH — record argv to GH_LOG.
  cat > "$STUB_BIN/gh" <<GHSTUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
# If --body-file is present, capture the body content too.
for ((i=1; i<=\$#; i++)); do
  if [[ "\${!i}" == "--body-file" ]]; then
    next=\$((i+1))
    if [[ -f "\${!next}" ]]; then
      cp "\${!next}" "$STUB_BIN/gh-body-file.md"
    fi
  fi
done
exit 0
GHSTUB
  chmod +x "$STUB_BIN/gh"

  ORIG_PATH="$PATH"
  export PATH="$STUB_BIN:$PATH"

  unset PIPELINE_DRY_RUN
}

_teardown_test_env() {
  export PIPELINE_DRY_RUN=1
  export PATH="$ORIG_PATH"
  rm -rf "$STUB_BIN" "$TARGET_REPO_BASE" "$PROJECT_STATE_DIR_BASE" "$HARNESS_STATE_DIR_BASE"
}

# Write a per-shape stub. Args:
#   $1 = shape name
#   $2 = rc to return
#   $3 = "yes" to write artifact, "no" to skip
#   $4 = "yes" to write a tracked file in TARGET_REPO, "no" to skip
#   $5 = optional artifact body (default: "## <Shape>\n\nMARKER-<name>\n")
_write_shape_stub() {
  local shape="$1" rc="$2" write_artifact="$3" write_tracked="$4"
  local artifact_body="${5:-}"
  cat > "$STUB_BIN/retro-shape-${shape}.sh" <<SHAPESTUB
#!/usr/bin/env bash
shape="$shape"
printf 'shape=%s argv=%s\n' "\$shape" "\$*" >> "$ARGV_LOG"
artifact_path=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --artifact-path) artifact_path="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$write_artifact" == "yes" ]]; then
  if [[ -n "$artifact_body" ]]; then
    printf '%s' "$artifact_body" > "\$artifact_path"
  else
    printf '## %s\n\nMARKER-%s\n' "\$shape" "\$shape" > "\$artifact_path"
  fi
fi
if [[ "$write_tracked" == "yes" ]]; then
  printf 'tracked-by-%s\n' "\$shape" >> "$TARGET_REPO/tracked-from-shapes.txt"
fi
exit $rc
SHAPESTUB
  chmod +x "$STUB_BIN/retro-shape-${shape}.sh"
}

_write_all_shape_stubs() {
  local rc="$1" write_artifact="$2" write_tracked="$3"
  for shape in "${SHAPES[@]}"; do
    _write_shape_stub "$shape" "$rc" "$write_artifact" "$write_tracked"
  done
}

# Source coordinator once at top — sentinel-guarded so main() does not fire.
# The coordinator's top-level `require_bin claude gh git jq` fires at source
# time; stub claude + gh in PATH BEFORE sourcing so the existence check passes
# even in CI/dev environments without claude installed.
export TARGET_REPO="$HARNESS_DIR/.."
PRESOURCE_STUB_DIR="$(mktemp -d)"
for stub_bin in claude gh; do
  cat > "$PRESOURCE_STUB_DIR/$stub_bin" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$PRESOURCE_STUB_DIR/$stub_bin"
done
ORIG_PATH_PRESOURCE="$PATH"
export PATH="$PRESOURCE_STUB_DIR:$PATH"
source "$HARNESS_DIR/run-retrospective-local.sh"
export PATH="$ORIG_PATH_PRESOURCE"
# common.sh + run-retrospective-local.sh both `set -euo pipefail` at sourcing;
# the `e` flag persists into our test scope and would abort the script on the
# first fixture failure. Reset to `uo pipefail` so we can catch+report fixture
# failures via `_fail` instead of aborting.
set +e
set -uo pipefail

# ---------------------------------------------------------------------------
# cf-1: all shapes succeed, every shape writes a tracked file → PR opened.
# ---------------------------------------------------------------------------
{
  name="cf-1-all-shapes-succeed-pr-opened"
  _new_test_env
  SCRIPT_DIR="$STUB_BIN"
  _write_all_shape_stubs 0 yes yes
  rc=0
  main >/dev/null 2>&1 || rc=$?
  gh_called=$([[ -s "$GH_LOG" ]] && echo yes || echo no)
  body_has_period=$([[ -f "$STUB_BIN/gh-body-file.md" ]] && grep -q '^## Period' "$STUB_BIN/gh-body-file.md" && echo yes || echo no)
  all_shapes_present=yes
  for shape in "${SHAPES[@]}"; do
    if ! grep -qF "MARKER-${shape}" "$STUB_BIN/gh-body-file.md" 2>/dev/null; then
      all_shapes_present=no
      break
    fi
  done
  if (( rc == 0 )) && [[ "$gh_called" == "yes" ]] && [[ "$body_has_period" == "yes" ]] && [[ "$all_shapes_present" == "yes" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc gh_called=$gh_called body_has_period=$body_has_period all_shapes_present=$all_shapes_present)"
  fi
  _teardown_test_env
}

# ---------------------------------------------------------------------------
# cf-2: some shapes fail, others succeed (with edits) → PR opened with
#       failed shapes footer; final slack call is `error` (not info).
# ---------------------------------------------------------------------------
{
  name="cf-2-some-shapes-skip-pr-opened"
  _new_test_env
  SCRIPT_DIR="$STUB_BIN"
  # 3 fail (first three), 9 succeed
  i=0
  for shape in "${SHAPES[@]}"; do
    if (( i < 3 )); then
      _write_shape_stub "$shape" 1 no no
    else
      _write_shape_stub "$shape" 0 yes yes
    fi
    (( i++ )) || true
  done
  rc=0
  main >/dev/null 2>&1 || rc=$?
  gh_called=$([[ -s "$GH_LOG" ]] && echo yes || echo no)
  footer_present=$(grep -q '^## Failed shapes' "$STUB_BIN/gh-body-file.md" 2>/dev/null && echo yes || echo no)
  failed_listed=yes
  for ((j=0; j<3; j++)); do
    fshape="${SHAPES[$j]}"
    if ! grep -q "^- ${fshape}" "$STUB_BIN/gh-body-file.md" 2>/dev/null; then
      failed_listed=no
      break
    fi
  done
  last_slack="$(tail -1 "$SLACK_LOG")"
  slack_error=$(printf '%s' "$last_slack" | grep -q '^error' && echo yes || echo no)
  if (( rc == 0 )) && [[ "$gh_called" == "yes" ]] && [[ "$footer_present" == "yes" ]] \
       && [[ "$failed_listed" == "yes" ]] && [[ "$slack_error" == "yes" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc gh_called=$gh_called footer=$footer_present failed_listed=$failed_listed slack_error=$slack_error last_slack=$last_slack)"
  fi
  _teardown_test_env
}

# ---------------------------------------------------------------------------
# cf-3: every shape succeeds but none writes a tracked file → no PR; info slack.
# ---------------------------------------------------------------------------
{
  name="cf-3-no-shape-produces-changes-no-pr"
  _new_test_env
  SCRIPT_DIR="$STUB_BIN"
  _write_all_shape_stubs 0 yes no  # write artifacts but no tracked-file edits
  rc=0
  out="$(main 2>&1)" || rc=$?
  gh_called=$([[ -s "$GH_LOG" ]] && echo yes || echo no)
  no_changes_logged=$(printf '%s' "$out" | grep -q "no changes proposed" && echo yes || echo no)
  slack_info=$(grep -q '^info' "$SLACK_LOG" && echo yes || echo no)
  if (( rc == 0 )) && [[ "$gh_called" == "no" ]] && [[ "$no_changes_logged" == "yes" ]] && [[ "$slack_info" == "yes" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc gh_called=$gh_called no_changes_logged=$no_changes_logged slack_info=$slack_info)"
  fi
  _teardown_test_env
}

# ---------------------------------------------------------------------------
# cf-4: every shape fails → no PR; slack error listing all 12 failures.
# ---------------------------------------------------------------------------
{
  name="cf-4-all-shapes-fail-no-pr"
  _new_test_env
  SCRIPT_DIR="$STUB_BIN"
  _write_all_shape_stubs 1 no no
  rc=0
  main >/dev/null 2>&1 || rc=$?
  gh_called=$([[ -s "$GH_LOG" ]] && echo yes || echo no)
  slack_last="$(tail -1 "$SLACK_LOG")"
  slack_error=$(printf '%s' "$slack_last" | grep -q '^error' && echo yes || echo no)
  failed_count_listed=$(printf '%s' "$slack_last" | grep -qE "${#SHAPES[@]} of ${#SHAPES[@]} shapes failed" && echo yes || echo no)
  if (( rc == 0 )) && [[ "$gh_called" == "no" ]] && [[ "$slack_error" == "yes" ]] && [[ "$failed_count_listed" == "yes" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc gh_called=$gh_called slack_error=$slack_error failed_count_listed=$failed_count_listed slack_last=$slack_last)"
  fi
  _teardown_test_env
}

# ---------------------------------------------------------------------------
# cf-5: SHAPES array is the source of truth — every name resolves to a
#       bin/retro-shape-<name>.sh on disk in the live repo.
# ---------------------------------------------------------------------------
{
  name="cf-5-shape-array-is-the-source-of-truth"
  expected=(
    stage-failure-summary gotcha-recurrence convention-drift gotcha-promotion
    human-override expiry-verification confirmation-bias-audit recency-bias
    survivorship-bias knowledge-budget pipeline-health-score
    prompt-workflow-amendment
  )
  array_matches=yes
  if (( ${#SHAPES[@]} != ${#expected[@]} )); then
    array_matches=no
  else
    for ((i=0; i<${#expected[@]}; i++)); do
      if [[ "${SHAPES[$i]}" != "${expected[$i]}" ]]; then
        array_matches=no
        break
      fi
    done
  fi
  drivers_exist=yes
  for shape in "${SHAPES[@]}"; do
    if [[ ! -f "$HARNESS_DIR/retro-shape-${shape}.sh" ]]; then
      drivers_exist=no
      break
    fi
  done
  if [[ "$array_matches" == "yes" ]] && [[ "$drivers_exist" == "yes" ]]; then
    _pass "$name"
  else
    _fail "$name (array_matches=$array_matches drivers_exist=$drivers_exist)"
  fi
}

# ---------------------------------------------------------------------------
# cf-6: period passed identically to every shape.
# ---------------------------------------------------------------------------
{
  name="cf-6-period-passed-to-every-shape"
  _new_test_env
  SCRIPT_DIR="$STUB_BIN"
  _write_all_shape_stubs 0 yes yes
  rc=0
  main >/dev/null 2>&1 || rc=$?
  # Each shape's argv line in $ARGV_LOG should carry --period-start-iso and
  # --period-end-iso. Extract start/end values per shape; verify all 12 share
  # the same values.
  starts="$(grep -oE '\-\-period-start-iso [^ ]+' "$ARGV_LOG" | awk '{print $2}' | sort -u | wc -l | tr -d ' ')"
  ends="$(grep -oE '\-\-period-end-iso [^ ]+' "$ARGV_LOG" | awk '{print $2}' | sort -u | wc -l | tr -d ' ')"
  if (( rc == 0 )) && [[ "$starts" == "1" ]] && [[ "$ends" == "1" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc unique_starts=$starts unique_ends=$ends)"
  fi
  _teardown_test_env
}

# ---------------------------------------------------------------------------
# cf-7: previous-period helper fallback returns "(none)" when no prior dir.
# ---------------------------------------------------------------------------
{
  name="cf-7-previous-period-helper-fallback"
  _new_test_env
  SCRIPT_DIR="$STUB_BIN"
  result="$(_resolve_previous_period_artifact stage-failure-summary 2026-05-16)"
  if [[ "$result" == "(none)" ]]; then
    _pass "$name"
  else
    _fail "$name (got: $result)"
  fi
  _teardown_test_env
}

# ---------------------------------------------------------------------------
# cf-8: previous-period helper finds prior artifact when present.
# ---------------------------------------------------------------------------
{
  name="cf-8-previous-period-helper-finds-prior"
  _new_test_env
  SCRIPT_DIR="$STUB_BIN"
  mkdir -p "$PROJECT_STATE_DIR/retrospective-2026-05-09"
  printf 'prior\n' > "$PROJECT_STATE_DIR/retrospective-2026-05-09/stage-failure-summary.md"
  result="$(_resolve_previous_period_artifact stage-failure-summary 2026-05-16)"
  expected="$PROJECT_STATE_DIR/retrospective-2026-05-09/stage-failure-summary.md"
  if [[ "$result" == "$expected" ]]; then
    _pass "$name"
  else
    _fail "$name (got: $result expected: $expected)"
  fi
  _teardown_test_env
}

# ---------------------------------------------------------------------------
# cf-9: PIPELINE_DRY_RUN=1 — no git commit, no gh pr create.
#       (Note: coordinator itself does NOT branch on DRY_RUN — the shapes do.
#       With dry-run, shapes produce placeholder artifacts but no tracked-file
#       changes, so the coordinator's "no diff → no PR" branch fires.)
# ---------------------------------------------------------------------------
{
  name="cf-9-dry-run-no-git-commit-no-gh-pr"
  _new_test_env
  SCRIPT_DIR="$STUB_BIN"
  _write_all_shape_stubs 0 yes no   # artifacts but no tracked-file edits
  export PIPELINE_DRY_RUN=1
  rc=0
  main >/dev/null 2>&1 || rc=$?
  gh_called=$([[ -s "$GH_LOG" ]] && echo yes || echo no)
  if (( rc == 0 )) && [[ "$gh_called" == "no" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc gh_called=$gh_called)"
  fi
  _teardown_test_env
}

# ---------------------------------------------------------------------------
# cf-10: PR body omits zero-byte artifacts.
# ---------------------------------------------------------------------------
{
  name="cf-10-pr-body-omits-empty-artifacts"
  _new_test_env
  SCRIPT_DIR="$STUB_BIN"
  # First shape writes a zero-byte artifact; others write normal content.
  i=0
  for shape in "${SHAPES[@]}"; do
    if (( i == 0 )); then
      # Custom stub: write empty file
      cat > "$STUB_BIN/retro-shape-${shape}.sh" <<EMPTYSHAPE
#!/usr/bin/env bash
artifact_path=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --artifact-path) artifact_path="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
: > "\$artifact_path"
printf 'tracked-empty\n' >> "$TARGET_REPO/tracked-from-shapes.txt"
exit 0
EMPTYSHAPE
      chmod +x "$STUB_BIN/retro-shape-${shape}.sh"
    else
      _write_shape_stub "$shape" 0 yes yes
    fi
    (( i++ )) || true
  done
  rc=0
  main >/dev/null 2>&1 || rc=$?
  # The empty shape's MARKER must NOT appear; the rest must appear.
  empty_shape="${SHAPES[0]}"
  empty_in_body=$(grep -qF "MARKER-${empty_shape}" "$STUB_BIN/gh-body-file.md" 2>/dev/null && echo yes || echo no)
  second_in_body=$(grep -qF "MARKER-${SHAPES[1]}" "$STUB_BIN/gh-body-file.md" 2>/dev/null && echo yes || echo no)
  if (( rc == 0 )) && [[ "$empty_in_body" == "no" ]] && [[ "$second_in_body" == "yes" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc empty_in_body=$empty_in_body second_in_body=$second_in_body)"
  fi
  _teardown_test_env
}

# ---------------------------------------------------------------------------
# cf-11: aggregator orders by SHAPES array, not filesystem.
# ---------------------------------------------------------------------------
{
  name="cf-11-aggregator-orders-by-shapes-array"
  _new_test_env
  SCRIPT_DIR="$STUB_BIN"
  _write_all_shape_stubs 0 yes yes
  rc=0
  main >/dev/null 2>&1 || rc=$?
  # Extract MARKER-* lines in body order, then compare order against SHAPES.
  body_markers="$(grep -oE 'MARKER-[a-z-]+' "$STUB_BIN/gh-body-file.md" 2>/dev/null | sed 's/^MARKER-//')"
  expected_markers="$(printf '%s\n' "${SHAPES[@]}")"
  if (( rc == 0 )) && [[ "$body_markers" == "$expected_markers" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc; body_markers=$body_markers; expected=$expected_markers)"
  fi
  _teardown_test_env
}

# ---------------------------------------------------------------------------
# cf-12: gh pr create fails → slack error + exit 20.
# ---------------------------------------------------------------------------
{
  name="cf-12-gh-pr-create-fails-slack-error"
  _new_test_env
  SCRIPT_DIR="$STUB_BIN"
  _write_all_shape_stubs 0 yes yes
  # Override gh to fail
  cat > "$STUB_BIN/gh" <<'GHFAIL'
#!/usr/bin/env bash
exit 1
GHFAIL
  chmod +x "$STUB_BIN/gh"
  rc=0
  main >/dev/null 2>&1 || rc=$?
  slack_last="$(tail -1 "$SLACK_LOG")"
  slack_error=$(printf '%s' "$slack_last" | grep -q '^error.*gh pr create failed' && echo yes || echo no)
  if (( rc == 20 )) && [[ "$slack_error" == "yes" ]]; then
    _pass "$name"
  else
    _fail "$name (rc=$rc slack_error=$slack_error last_slack=$slack_last)"
  fi
  _teardown_test_env
}

printf '\n'
if (( FAIL == 0 )); then
  printf 'OK: run-retrospective-local tests (%d passed)\n' "$PASS"
  exit 0
else
  printf 'FAILURES (%d/%d):\n%b' "$FAIL" "$(( PASS + FAIL ))" "$FAILURES"
  exit 1
fi
