#!/usr/bin/env bash
# Tests for bin/plan-scope.sh (ENG-194 — shared plan-structural matcher).
#
# Coverage (final shape, finished in Task 6):
#   T1 — plan_scope::parse_allowed_files snapshot
#   T2 — plan_scope::parse_allowed_dirs snapshot (includes ENG-46 dotfile-dir)
#   T3 — plan_scope::path_in_scope battery (positive + negative)
#   T4 — sourcing assertion (helper available after `source scope-check.sh`
#        and `source render-prompt.sh` — wired in Task 2 / Task 4)
#   T5 — AC #4 byte-for-byte cross-caller assertion: scope-check.sh's
#        refactored parse path and render-prompt.sh's resolver produce
#        byte-equal output for the same fixture plan.
#
# Until Task 2 and Task 4 land, T4 (sourcing into scope-check.sh and
# render-prompt.sh) and the parallel cross-caller leg of T5 are
# wire-up-dependent and added by Task 6 in their own commit. This Task 1
# commit establishes T1/T2/T3 plus a self-equality leg of T5 so the
# helper's correctness is gated independently from the wiring tasks.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_SLUG="${PROJECT_SLUG:-test}"
export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY=test-mock-key

PASS=0
FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2"; }

# Source the helper directly (sentinel-gated main never fires under source).
# common.sh requires TARGET_REPO — set by the pre-commit hook.
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

# ─── T5 (self-equality leg): byte-for-byte cross-caller via plan-scope.sh ──
# Sources plan-scope.sh in a second subshell and asserts byte-equal output
# against the in-process invocation. Catches accidental state leakage
# (e.g. an environment-dependent grep -E pattern). T4 + the second leg of
# T5 (scope-check.sh + render-prompt.sh sourcing) land in Task 6 once the
# wiring tasks are committed.
printf '\n--- T5 (self-equality leg): byte-for-byte cross-process ---\n'
tmp="$(mktemp -d -t plan-scope-xc-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/docs/plans"
cat > "$tmp/docs/plans/2026-06-16-eng-194-foo.md" <<'PLAN'
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

plan_path="$(plan_scope::find_plan ENG-194 "$tmp")"
if [[ -z "$plan_path" ]]; then
  fail_at "T5(self): find_plan" "no plan found for ENG-194 under $tmp/docs/plans/"
else
  body="$(plan_scope::extract_section "$plan_path")"
  # Caller A: in-process invocation.
  out_a_files="$(plan_scope::parse_allowed_files "$body")"
  out_a_dirs="$(plan_scope::parse_allowed_dirs "$body")"
  # Caller B: fresh subshell re-sourcing the helper.
  out_b_files="$(
    bash -c '
      set -euo pipefail
      # shellcheck source=plan-scope.sh
      source "$1/plan-scope.sh"
      plan_scope::parse_allowed_files "$2"
    ' _ "$SCRIPT_DIR" "$body"
  )"
  out_b_dirs="$(
    bash -c '
      set -euo pipefail
      # shellcheck source=plan-scope.sh
      source "$1/plan-scope.sh"
      plan_scope::parse_allowed_dirs "$2"
    ' _ "$SCRIPT_DIR" "$body"
  )"

  if [[ -z "$out_a_files" ]]; then
    fail_at "T5(self): allowed_files non-empty" "in-process call returned empty body"
  elif [[ "$out_a_files" == "$out_b_files" ]]; then
    pass_at "T5(self): allowed_files byte-equal across processes"
  else
    fail_at "T5(self): allowed_files cross-process mismatch" "A=$(tr '\n' '|' <<<"$out_a_files") B=$(tr '\n' '|' <<<"$out_b_files")"
  fi

  if [[ "$out_a_dirs" == "$out_b_dirs" ]]; then
    pass_at "T5(self): allowed_dirs byte-equal across processes"
  else
    fail_at "T5(self): allowed_dirs cross-process mismatch" "A=$(tr '\n' '|' <<<"$out_a_dirs") B=$(tr '\n' '|' <<<"$out_b_dirs")"
  fi
fi

echo
echo "plan-scope-test: passed=$PASS failed=$FAIL"
(( FAIL == 0 )) || exit 1
