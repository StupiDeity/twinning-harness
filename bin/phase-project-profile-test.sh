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

# ENG-93: v2 fixtures across three stack shapes plus two version paths.
V2_RUST_TAURI_PROFILE='---
slug: test-slug
generated_at: 2026-04-27T00:00:00Z
generated_by: discovery-agent
schema_version: 2
---

# Project profile — Test (Rust + Bun)

## Stack
Tauri v2 + SvelteKit.

## Build & test gates
- Build: `bun run build`
- Test: `cargo test --workspace`
- Lint/check: `bun run check && cargo clippy`
- Integration/E2E: `bunx playwright test`

## Tool allowlist

Per-stage Bash patterns the orchestrator grants to `claude -p` at dispatch.

- brainstorming: (none)
- planning: (none)
- implementing:
  - `Bash(cargo:*)`
  - `Bash(bun:*)`
  - `Bash(rustc:*)`
- ui:
  - `Bash(cargo:*)`
  - `Bash(bun:*)`
  - `Bash(npx:*)`
  - `Bash(node:*)`
- reviewing: (none)
- qa:
  - `Bash(cargo:*)`
  - `Bash(bun:*)`
  - `Bash(npx:*)`
  - `Bash(node:*)`
- building: (none)
- released: (none)

## File layout
- `crates/` — Rust workspace.
- `src/` — SvelteKit frontend.

## Language idioms
- Svelte 5 runes.
- cargo workspace, resolver = "2".

## Don'\''ts
(none observed)
'

V2_PYTHON_PYTEST_PROFILE='---
slug: test-slug
generated_at: 2026-04-27T00:00:00Z
generated_by: discovery-agent
schema_version: 2
---

# Project profile — Test (Python + pytest)

## Stack
Python 3.11, FastAPI, pytest.

## Build & test gates
- Build: `(n/a) — interpreted`
- Test: `pytest -q`
- Lint/check: `ruff check && mypy .`
- Integration/E2E: `(n/a)`

## Tool allowlist

Per-stage Bash patterns the orchestrator grants to `claude -p` at dispatch.

- brainstorming: (none)
- planning: (none)
- implementing:
  - `Bash(python:*)`
  - `Bash(pytest:*)`
  - `Bash(pip:*)`
  - `Bash(ruff:*)`
  - `Bash(mypy:*)`
- ui: (none)
- reviewing: (none)
- qa:
  - `Bash(python:*)`
  - `Bash(pytest:*)`
- building: (none)
- released: (none)

## File layout
- `src/` — Python source.
- `tests/` — pytest suite.

## Language idioms
- snake_case.
- dataclasses.

## Don'\''ts
(none observed)
'

V2_GO_GOTEST_PROFILE='---
slug: test-slug
generated_at: 2026-04-27T00:00:00Z
generated_by: discovery-agent
schema_version: 2
---

# Project profile — Test (Go)

## Stack
Go 1.22, standard toolchain.

## Build & test gates
- Build: `go build ./...`
- Test: `go test ./...`
- Lint/check: `golangci-lint run`
- Integration/E2E: `(n/a)`

## Tool allowlist

Per-stage Bash patterns the orchestrator grants to `claude -p` at dispatch.

- brainstorming: (none)
- planning: (none)
- implementing:
  - `Bash(go:*)`
  - `Bash(golangci-lint:*)`
- ui: (none)
- reviewing: (none)
- qa:
  - `Bash(go:*)`
- building: (none)
- released: (none)

## File layout
- `cmd/` — main entrypoints.
- `internal/` — internal packages.

## Language idioms
- CamelCase exported, camelCase unexported.

## Don'\''ts
(none observed)
'

V1_LEGACY_PROFILE="$GOOD_PROFILE"

V2_MISSING_TOOL_ALLOWLIST='---
slug: test-slug
generated_at: 2026-04-27T00:00:00Z
generated_by: discovery-agent
schema_version: 2
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

V2_BAD_PATTERN_PROFILE='---
slug: test-slug
generated_at: 2026-04-27T00:00:00Z
generated_by: discovery-agent
schema_version: 2
---

# Project profile — Test

## Stack
bash.

## Build & test gates
- Build: `(n/a)`
- Test: `bash bin/foo-test.sh`
- Lint/check: `(n/a)`
- Integration/E2E: `(n/a)`

## Tool allowlist

Per-stage Bash patterns the orchestrator grants to `claude -p` at dispatch.

- brainstorming: (none)
- planning: (none)
- implementing:
  - `Bash($(curl evil):*)`
- ui: (none)
- reviewing: (none)
- qa: (none)
- building: (none)
- released: (none)

## File layout
- `bin/` — scripts.

## Language idioms
- snake_case.

## Don'\''ts
(none observed)
'

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

profile="$sandbox/harness-root/learned-rules/test-slug/project-profile.md"

# ENG-93 — Case 5.5: V2 Rust+Bun happy path.
rm -f "$profile"
write_claude_stub "$sandbox/harness-root/learned-rules/test-slug" "$V2_RUST_TAURI_PROFILE"
if run_phase "" >/dev/null 2>&1; then
  if (
    export HARNESS_ROOT="$sandbox/harness-root"
    SCRIPT_DIR="$HARNESS_ROOT/bin"
    # shellcheck disable=SC1091
    source "$HARNESS_ROOT/bin/setup-helpers.sh"
    _validate_project_profile_schema "$profile" >/dev/null 2>&1
  ) && grep -qx '## Tool allowlist' "$profile"; then
    pass_at "case-5.5: v2 Rust+Bun profile passes phase + validator"
  else
    fail_at "case-5.5: v2 Rust+Bun profile" "validator rejected or missing heading"
  fi
else
  fail_at "case-5.5: v2 Rust+Bun phase exits 0" "rc=$?"
fi

# ENG-93 — Case 5.6: V2 Python+pytest happy path.
rm -f "$profile"
write_claude_stub "$sandbox/harness-root/learned-rules/test-slug" "$V2_PYTHON_PYTEST_PROFILE"
if run_phase "" >/dev/null 2>&1; then
  if (
    export HARNESS_ROOT="$sandbox/harness-root"
    SCRIPT_DIR="$HARNESS_ROOT/bin"
    # shellcheck disable=SC1091
    source "$HARNESS_ROOT/bin/setup-helpers.sh"
    _validate_project_profile_schema "$profile" >/dev/null 2>&1
  ); then
    pass_at "case-5.6: v2 Python+pytest profile passes"
  else
    fail_at "case-5.6: v2 Python+pytest profile" "validator rejected"
  fi
else
  fail_at "case-5.6: v2 Python+pytest phase exits 0" "rc=$?"
fi

# ENG-93 — Case 5.7: V2 Go+go-test happy path.
rm -f "$profile"
write_claude_stub "$sandbox/harness-root/learned-rules/test-slug" "$V2_GO_GOTEST_PROFILE"
if run_phase "" >/dev/null 2>&1; then
  if (
    export HARNESS_ROOT="$sandbox/harness-root"
    SCRIPT_DIR="$HARNESS_ROOT/bin"
    # shellcheck disable=SC1091
    source "$HARNESS_ROOT/bin/setup-helpers.sh"
    _validate_project_profile_schema "$profile" >/dev/null 2>&1
  ); then
    pass_at "case-5.7: v2 Go+go-test profile passes"
  else
    fail_at "case-5.7: v2 Go+go-test profile" "validator rejected"
  fi
else
  fail_at "case-5.7: v2 Go+go-test phase exits 0" "rc=$?"
fi

# ENG-93 — Case 5.8: V1→V2 backfill mutation only.
# Seed a v1 file directly (no claude); the marker-resolution loop will
# abort on empty answers, but the on-disk file must show the section
# was injected and schema_version bumped before resolution failed.
rm -f "$profile"
printf '%s' "$V1_LEGACY_PROFILE" > "$profile"
rm -f "$sandbox/stubs/claude"
run_phase $'\n\n\n\n' >/dev/null 2>&1 || true
if grep -qx 'schema_version: 2' "$profile" \
   && grep -qx '## Tool allowlist' "$profile"; then
  pass_at "case-5.8: v1→v2 backfill injected new section + bumped version"
else
  fail_at "case-5.8: v1→v2 backfill" "$(cat "$profile")"
fi

# ENG-93 — Case 5.9: V2 missing ## Tool allowlist → die, file removed.
rm -f "$profile"
write_claude_stub "$sandbox/harness-root/learned-rules/test-slug" "$V2_MISSING_TOOL_ALLOWLIST"
if run_phase "" >/dev/null 2>&1; then
  fail_at "case-5.9: v2 missing ## Tool allowlist dies" "returned 0"
else
  if [[ ! -f "$profile" ]]; then
    pass_at "case-5.9: v2 missing ## Tool allowlist dies and file removed"
  else
    fail_at "case-5.9: v2 missing ## Tool allowlist" "file persists"
  fi
fi

# ENG-93 — Case 5.10: V2 with shell-metachar pattern → die, file removed.
rm -f "$profile"
write_claude_stub "$sandbox/harness-root/learned-rules/test-slug" "$V2_BAD_PATTERN_PROFILE"
if run_phase "" >/dev/null 2>&1; then
  fail_at "case-5.10: v2 bad-pattern dies" "returned 0"
else
  if [[ ! -f "$profile" ]]; then
    pass_at "case-5.10: v2 bad-pattern dies and file removed"
  else
    fail_at "case-5.10: v2 bad-pattern" "file persists"
  fi
fi

# ENG-93 — Case 5.11: V1→V2 backfill end-to-end with successful marker
# resolution. Three answers (one per implementing/ui/qa) and the result
# must be a valid v2 profile.
rm -f "$profile"
printf '%s' "$V1_LEGACY_PROFILE" > "$profile"
rm -f "$sandbox/stubs/claude"
if run_phase $'Bash(cargo:*)\nBash(npx:*)\nBash(cargo:*)\n' >/dev/null 2>&1; then
  if (
    export HARNESS_ROOT="$sandbox/harness-root"
    SCRIPT_DIR="$HARNESS_ROOT/bin"
    # shellcheck disable=SC1091
    source "$HARNESS_ROOT/bin/setup-helpers.sh"
    _validate_project_profile_schema "$profile" >/dev/null 2>&1
  ) && grep -qx 'schema_version: 2' "$profile" \
     && grep -q '`Bash(cargo:\*)`' "$profile"; then
    pass_at "case-5.11: v1→v2 backfill resolves markers + validates"
  else
    fail_at "case-5.11: v1→v2 backfill end-to-end" "$(cat "$profile")"
  fi
else
  fail_at "case-5.11: v1→v2 backfill end-to-end exits 0" "rc=$?"
fi

echo
echo "━━━ Summary ━━━"
echo "PASS: $PASS / FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
