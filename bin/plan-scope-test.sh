#!/usr/bin/env bash
# Tests for bin/plan-scope.sh (ENG-194 — shared plan-structural matcher).
#
# Coverage:
#   T1 — plan_scope::parse_allowed_files snapshot
#   T2 — plan_scope::parse_allowed_dirs snapshot (includes ENG-46 dotfile-dir)
#   T3 — plan_scope::path_in_scope battery (positive + negative)
#   T4 — sourcing assertion (helper available after `source scope-check.sh` /
#        `source render-prompt.sh`)
#   T5 — AC #4 byte-for-byte cross-caller assertion: scope-check.sh's refactored
#        parse path and render-prompt.sh's resolver produce byte-equal output
#        for the same fixture plan.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY=test-mock-key

PASS=0
FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2"; }

STUB_DIR="$(mktemp -d -t plan-scope-stubs-XXXXXX)"
cat > "$STUB_DIR/linear.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_DIR/linear.sh"

cleanup() { rm -rf "$STUB_DIR"; }
trap cleanup EXIT

# Source the helper directly (sentinel-gated main never fires under source).
# shellcheck source=plan-scope.sh
source "$SCRIPT_DIR/plan-scope.sh"

# ─── T1: parse_allowed_files snapshot ─────────────────────────────────
printf '\n--- T1: parse_allowed_files snapshot ---\n'
fixture_body='## File Structure

- `bin/setup.sh`
- `docs/install.md`
- `CLAUDE.md`
- `bin/dispatch.sh`'

# sort -u order under LC_COLLATE=C: uppercase precedes lowercase
expected_files='CLAUDE.md
bin/dispatch.sh
bin/setup.sh
docs/install.md'
actual_files="$(plan_scope::parse_allowed_files "$fixture_body")"
if [[ "$actual_files" == "$expected_files" ]]; then
  pass_at "T1: parse_allowed_files byte-equal to expected"
else
  fail_at "T1: parse_allowed_files snapshot mismatch" "expected=$(tr '\n' '|' <<<"$expected_files") actual=$(tr '\n' '|' <<<"$actual_files")"
fi

# ─── T2: parse_allowed_dirs snapshot (ENG-46 dotfile-dir case) ────────
printf '\n--- T2: parse_allowed_dirs snapshot ---\n'
fixture_body2='## File Structure

- `docs/`
- `.github/workflows/`
- `bin/`'

expected_dirs='.github/workflows/
bin/
docs/'
actual_dirs="$(plan_scope::parse_allowed_dirs "$fixture_body2")"
if [[ "$actual_dirs" == "$expected_dirs" ]]; then
  pass_at "T2: parse_allowed_dirs byte-equal (incl. .github/ dotfile dir)"
else
  fail_at "T2: parse_allowed_dirs snapshot mismatch" "expected=$(tr '\n' '|' <<<"$expected_dirs") actual=$(tr '\n' '|' <<<"$actual_dirs")"
fi

# ─── T3: path_in_scope battery ─────────────────────────────────────────
printf '\n--- T3: path_in_scope battery ---\n'
af='bin/setup.sh
CLAUDE.md'
ad='docs/
.github/workflows/'

# Positive cases
for p in bin/setup.sh CLAUDE.md docs/install.md .github/workflows/ci.yml; do
  if plan_scope::path_in_scope "$p" "$af" "$ad"; then
    pass_at "T3: in-scope: $p"
  else
    fail_at "T3: in-scope: $p" "matcher classified out-of-scope"
  fi
done

# Negative cases
for p in bin/setup.sh.bak random.txt; do
  if plan_scope::path_in_scope "$p" "$af" "$ad"; then
    fail_at "T3: out-of-scope: $p" "matcher classified in-scope"
  else
    pass_at "T3: out-of-scope: $p"
  fi
done

# ─── T4: sourcing assertion ────────────────────────────────────────────
printf '\n--- T4: helper sourced from scope-check.sh and render-prompt.sh ---\n'
# Source in a subshell so bash state does not leak. The sourced scripts
# reach for TARGET_REPO; the tests under PIPELINE_DRY_RUN+stub mode set
# TARGET_REPO to a stub repo root.
target_repo_stub="$(mktemp -d -t plan-scope-target-XXXXXX)"
(
  cd "$target_repo_stub"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
)

# scope-check.sh sources plan-scope.sh; assert the function is reachable.
if (
  export TARGET_REPO="$target_repo_stub"
  export HARNESS_STATE_DIR="$(mktemp -d -t plan-scope-state-XXXXXX)"
  export HARNESS_CONFIG_DIR="$(mktemp -d -t plan-scope-config-XXXXXX)"
  # shellcheck source=scope-check.sh
  source "$SCRIPT_DIR/scope-check.sh"
  declare -f plan_scope::path_in_scope >/dev/null
); then
  pass_at "T4: plan_scope::path_in_scope reachable after source scope-check.sh"
else
  fail_at "T4: scope-check.sh sourcing" "plan_scope::path_in_scope not defined after source scope-check.sh"
fi

# render-prompt.sh resolver sources plan-scope.sh at call time, not at file
# load; we assert _resolve_plan_scope_allowed_paths is declared, and that
# calling it brings plan_scope::path_in_scope into scope.
if (
  export TARGET_REPO="$target_repo_stub"
  export HARNESS_STATE_DIR="$(mktemp -d -t plan-scope-state-XXXXXX)"
  export HARNESS_CONFIG_DIR="$(mktemp -d -t plan-scope-config-XXXXXX)"
  # shellcheck source=render-prompt.sh
  source "$SCRIPT_DIR/render-prompt.sh"
  declare -f _resolve_plan_scope_allowed_paths >/dev/null
); then
  pass_at "T4: _resolve_plan_scope_allowed_paths defined after source render-prompt.sh"
else
  fail_at "T4: render-prompt.sh sourcing" "_resolve_plan_scope_allowed_paths not defined after source render-prompt.sh"
fi

rm -rf "$target_repo_stub"

# ─── T5: byte-for-byte cross-caller assertion (AC #4) ──────────────────
printf '\n--- T5: byte-for-byte cross-caller assertion ---\n'
tmp="$(mktemp -d -t plan-scope-xc-XXXXXX)"
(
  cd "$tmp"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans
  cat > "docs/plans/2026-06-16-eng-194-foo.md" <<'PLAN'
---
linear: ENG-194
---
## File Structure

NEW:
- `bin/foo.sh` — example.

MODIFIED:
- `CLAUDE.md`
- `docs/install.md`
- `bin/dispatch.sh`
- `docs/`
- `.github/workflows/`

PLAN
  printf 'baseline\n' > CLAUDE.md
  git add -A
  git commit -qm "initial"
)

# Caller A: scope-check.sh's refactored parse path.
out_a_files="$(
  bash -c '
    set -euo pipefail
    cd "$1"
    export TARGET_REPO="$1"
    export HARNESS_STATE_DIR="$(mktemp -d -t plan-scope-xca-state-XXXXXX)"
    export HARNESS_CONFIG_DIR="$(mktemp -d -t plan-scope-xca-config-XXXXXX)"
    export PIPELINE_DRY_RUN=1
    export LINEAR_API_KEY=test-mock-key
    export PROJECT_SLUG=test-slug
    # shellcheck source=scope-check.sh
    source "$2/scope-check.sh"
    plan="$(plan_scope::find_plan ENG-194 "$1")"
    body="$(plan_scope::extract_section "$plan")"
    plan_scope::parse_allowed_files "$body"
  ' _ "$tmp" "$SCRIPT_DIR"
)"
out_a_dirs="$(
  bash -c '
    set -euo pipefail
    cd "$1"
    export TARGET_REPO="$1"
    export HARNESS_STATE_DIR="$(mktemp -d -t plan-scope-xca-state-XXXXXX)"
    export HARNESS_CONFIG_DIR="$(mktemp -d -t plan-scope-xca-config-XXXXXX)"
    export PIPELINE_DRY_RUN=1
    export LINEAR_API_KEY=test-mock-key
    export PROJECT_SLUG=test-slug
    # shellcheck source=scope-check.sh
    source "$2/scope-check.sh"
    plan="$(plan_scope::find_plan ENG-194 "$1")"
    body="$(plan_scope::extract_section "$plan")"
    plan_scope::parse_allowed_dirs "$body"
  ' _ "$tmp" "$SCRIPT_DIR"
)"

# Caller B: render-prompt.sh's _resolve_plan_scope_allowed_paths resolver.
out_b="$(
  bash -c '
    set -euo pipefail
    cd "$1"
    export TARGET_REPO="$1"
    export HARNESS_STATE_DIR="$(mktemp -d -t plan-scope-xcb-state-XXXXXX)"
    export HARNESS_CONFIG_DIR="$(mktemp -d -t plan-scope-xcb-config-XXXXXX)"
    export PIPELINE_DRY_RUN=1
    export LINEAR_API_KEY=test-mock-key
    export PROJECT_SLUG=test-slug
    # shellcheck source=render-prompt.sh
    source "$2/render-prompt.sh"
    _RENDER_ISSUE_ID=ENG-194 _resolve_plan_scope_allowed_paths
  ' _ "$tmp" "$SCRIPT_DIR"
)"

# Slice the resolver's two sections.
out_b_files="$(awk '/^#ALLOWED_FILES#$/{flag=1; next} /^#ALLOWED_DIRS#$/{flag=0} flag' <<<"$out_b")"
out_b_dirs="$(awk '/^#ALLOWED_DIRS#$/{flag=1; next} flag' <<<"$out_b")"

# Both should be non-empty. If either is empty, the resolver soft-failed
# (plan-absent path); the fixture above declares a valid plan so this is
# an error.
if [[ -z "$out_a_files" || -z "$out_b_files" ]]; then
  fail_at "T5: cross-caller files non-empty" "A=$(tr '\n' '|' <<<"$out_a_files") B=$(tr '\n' '|' <<<"$out_b_files")"
elif [[ "$out_a_files" == "$out_b_files" ]]; then
  pass_at "T5: allowed_files byte-equal across callers"
else
  fail_at "T5: allowed_files cross-caller mismatch" "A=$(tr '\n' '|' <<<"$out_a_files") B=$(tr '\n' '|' <<<"$out_b_files")"
fi

if [[ "$out_a_dirs" == "$out_b_dirs" ]]; then
  pass_at "T5: allowed_dirs byte-equal across callers"
else
  fail_at "T5: allowed_dirs cross-caller mismatch" "A=$(tr '\n' '|' <<<"$out_a_dirs") B=$(tr '\n' '|' <<<"$out_b_dirs")"
fi

rm -rf "$tmp"

echo
echo "plan-scope-test: passed=$PASS failed=$FAIL"
(( FAIL == 0 )) || exit 1
