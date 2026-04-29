#!/usr/bin/env bash
# Tests for setup.sh::phase_project_profile.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2"; }

# Build a sandbox that looks like a target + harness.
sandbox="$(mktemp -d -t phase-pp-test-XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/target/.pipeline-config"
mkdir -p "$sandbox/state"
mkdir -p "$sandbox/stubs"

cat > "$sandbox/target/.pipeline-config/config.json" <<'JSON'
{
  "linear": {"team_id": "T", "project_id": "P"},
  "project": {"slug": "test-slug"},
  "orchestrator": {"paused": false}
}
JSON

# Stub `claude`. The fixture function below rewrites this on a per-case basis.
write_claude_stub() {
  local out_dir="$1" body="$2"
  cat > "$sandbox/stubs/claude" <<EOF
#!/usr/bin/env bash
# Stub claude. Reads prompt on stdin, writes a fixture profile, exits.
mkdir -p "$out_dir"
cat > "$out_dir/project-profile.md" <<'PROFILE'
$body
PROFILE
# Drain stdin so any upstream pipe doesn't break.
cat > /dev/null
exit 0
EOF
  chmod +x "$sandbox/stubs/claude"
}

GOOD_PROFILE='---
slug: test-slug
generated_at: 2026-04-27T00:00:00Z
generated_by: discovery-agent
schema_version: 1
---

# Project profile — Test

## Stack
bash.

## Build & test gates
- Build: `(n/a)`
- Test: `bash bin/foo-test.sh`
- Lint/check: `(n/a)`
- Integration/E2E: `(n/a)`

## File layout
- `bin/` — scripts.

## Language idioms
- snake_case.

## Don'\''ts
(none observed)
'

MARKED_PROFILE='---
slug: test-slug
generated_at: 2026-04-27T00:00:00Z
generated_by: discovery-agent
schema_version: 1
---

# Project profile — Test

## Stack
<<NEEDS-INPUT: What is the primary language?>>

## Build & test gates
- Build: `(n/a)`
- Test: `bash bin/foo-test.sh`
- Lint/check: `(n/a)`
- Integration/E2E: `(n/a)`

## File layout
- `bin/` — scripts.

## Language idioms
- snake_case.

## Don'\''ts
(none observed)
'

INVALID_PROFILE='not a profile.'

# Helper: source setup.sh in a subshell with stubs in PATH and harness env.
run_phase() {
  local stdin_input="$1"
  (
    export PATH="$sandbox/stubs:$PATH"
    export TARGET_REPO="$sandbox/target"
    export HARNESS_STATE_DIR="$sandbox/state"
    export HARNESS_ROOT="$sandbox/harness-root"
    export PROJECT_SLUG="test-slug"
    export PROJECT_STATE_DIR="$sandbox/state/test-slug"
    export PIPELINE_DRY_RUN=0
    mkdir -p "$HARNESS_ROOT/bin/setup-prompts" "$PROJECT_STATE_DIR/logs" "$HARNESS_ROOT/learned-rules/test-slug"
    cp "$SCRIPT_DIR/setup-prompts/discovery.md" "$HARNESS_ROOT/bin/setup-prompts/discovery.md"
    cp "$SCRIPT_DIR/common.sh" "$HARNESS_ROOT/bin/common.sh"
    cp "$SCRIPT_DIR/setup-helpers.sh" "$HARNESS_ROOT/bin/setup-helpers.sh"
    cp "$SCRIPT_DIR/setup.sh" "$HARNESS_ROOT/bin/setup.sh"
    SCRIPT_DIR="$HARNESS_ROOT/bin"
    # shellcheck disable=SC1091
    source "$HARNESS_ROOT/bin/common.sh" 2>/dev/null || true
    # shellcheck disable=SC1091
    source "$HARNESS_ROOT/bin/setup-helpers.sh"
    PHASE=""
    # shellcheck disable=SC1091
    source "$HARNESS_ROOT/bin/setup.sh"
    # Trailing newline so `read -r` sees a complete line, not an EOF-on-non-empty
    # which the function (intentionally) treats as an empty answer.
    printf '%s\n' "$stdin_input" | phase_project_profile
  )
}

# Case 5.1: happy path — stub-claude writes good profile, no markers.
write_claude_stub "$sandbox/harness-root/learned-rules/test-slug" "$GOOD_PROFILE"
if run_phase "" >/dev/null 2>&1; then
  pass_at "case-5.1: happy path completes"
else
  fail_at "case-5.1: happy path completes" "rc=$?"
fi

# Case 5.2: re-run with valid profile present → discovery skipped (no claude invocation).
rm -f "$sandbox/stubs/claude"  # if claude is invoked, require_bin will fail
if run_phase "" >/dev/null 2>&1; then
  pass_at "case-5.2: skip-discovery when valid profile exists"
else
  fail_at "case-5.2: skip-discovery when valid profile exists" "rc=$?"
fi

# Case 5.3: profile with markers — discovery skipped, marker resolution runs.
rm -f "$sandbox/harness-root/learned-rules/test-slug/project-profile.md"
write_claude_stub "$sandbox/harness-root/learned-rules/test-slug" "$MARKED_PROFILE"
run_phase "" >/dev/null 2>&1 || true  # populate marker file via stub
rm -f "$sandbox/stubs/claude"  # ensure no second claude call
if run_phase "bash" >/dev/null 2>&1; then
  if ! grep -q '<<NEEDS-INPUT' "$sandbox/harness-root/learned-rules/test-slug/project-profile.md"; then
    pass_at "case-5.3: markers resolved without re-invoking claude"
  else
    fail_at "case-5.3: markers resolved without re-invoking claude" "markers remain"
  fi
else
  fail_at "case-5.3: markers resolved without re-invoking claude" "rc=$?"
fi

# Case 5.4: invalid output → file removed, function dies.
rm -f "$sandbox/harness-root/learned-rules/test-slug/project-profile.md"
write_claude_stub "$sandbox/harness-root/learned-rules/test-slug" "$INVALID_PROFILE"
if run_phase "" >/dev/null 2>&1; then
  fail_at "case-5.4: invalid output dies" "returned 0"
else
  if [[ ! -f "$sandbox/harness-root/learned-rules/test-slug/project-profile.md" ]]; then
    pass_at "case-5.4: invalid output dies and file removed"
  else
    fail_at "case-5.4: invalid output dies and file removed" "file persists"
  fi
fi

echo
echo "━━━ Summary ━━━"
echo "PASS: $PASS / FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
