#!/usr/bin/env bash
# ENG-98: QA-authored adversarial coverage for bin/dry-run-test.sh's
# _has_bun_e matcher and bin/dry-run.sh's "GH Actions workflow structure"
# check.
#
# Pins the bypass shapes that current matchers DO NOT catch — so a future
# fix that tightens the matchers (or a regression that loosens them) must
# update these expectations explicitly. Each case has a one-line rationale
# documenting the current trade-off.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the matcher under test from the canonical test file. The function
# is defined at top-level (no sentinel guard around it), so sourcing the
# file gives us _has_bun_e without firing main(). NOTE: dry-run-test.sh
# sets `set -euo pipefail` which leaks into this shell; we re-disable -e
# below because the adversarial cases intentionally exercise non-zero
# exits from the structural-check body and from _has_bun_e (its "no
# match" path returns 1).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/dry-run-test.sh"
set +e

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  reason: %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# Per-test isolated tmpfile (the matcher reads from a file path).
mk_fixture() {
  local body="$1"
  local f
  f="$(mktemp -t dry-run-adv.XXXXXX)"
  printf '%s\n' "$body" > "$f"
  printf '%s' "$f"
}

main() {
  local tmpfiles=()
  cleanup() { local f; for f in "${tmpfiles[@]}"; do rm -f "$f"; done; }
  trap cleanup RETURN

  # ─── _has_bun_e matcher: known bypass shapes ───────────────────────

  # ADV-1: variable indirection — `$BUN -e "x"` reintroduces bun without
  # the literal token. Matcher requires the literal `bun` followed by
  # whitespace then `-e`. Current behavior: bypass succeeds (no match).
  # Rationale: matcher is a regression-prevention hint, not a
  # taint-tracking analyser; documented trade-off.
  local f1
  f1="$(mk_fixture 'BUN=bun; $BUN -e "console.log(1)"')"
  tmpfiles+=("$f1")
  if _has_bun_e "$f1"; then
    nope 'ADV-1-bun-via-var' \
      "matcher unexpectedly caught \$BUN -e — pin says current behavior is bypass"
  else
    ok 'ADV-1-bun-via-var (bypass confirmed; future tightening welcome)'
  fi

  # ADV-2: line-continuation — `bun \` on one line, `-e "x"` on the next.
  # awk scans line-by-line so `bun[[:space:]]+-e` never matches across
  # the newline. Pin: bypass succeeds.
  local f2
  f2="$(mktemp -t dry-run-adv.XXXXXX)"
  printf 'bun \\\n  -e "console.log(1)"\n' > "$f2"
  tmpfiles+=("$f2")
  if _has_bun_e "$f2"; then
    nope 'ADV-2-line-continuation' \
      "matcher unexpectedly caught multi-line bun -e — pin says current behavior is bypass"
  else
    ok 'ADV-2-line-continuation (bypass confirmed; line-by-line scan limitation)'
  fi

  # ADV-3: inline-comment-after-code — `cargo build  # bun -e demo`. The
  # awk script's "skip if first non-whitespace is #" rule treats this as
  # CODE (first non-whitespace is `c`), so the matcher fires. Documented
  # known false positive — dry-run.sh has no legitimate reason to embed
  # `bun -e` in a comment-after-code, but we pin the behavior to prevent
  # silent drift.
  local f3
  f3="$(mk_fixture 'cargo build  # bun -e demo')"
  tmpfiles+=("$f3")
  if _has_bun_e "$f3"; then
    ok 'ADV-3-inline-comment (false-positive pinned; see dry-run-test.sh:24-27)'
  else
    nope 'ADV-3-inline-comment' \
      "matcher missed inline-comment shape — drift from documented limitation"
  fi

  # ADV-4: pure-string-literal — `echo "uses bun -e in 2024"`. Matcher
  # cannot distinguish string-literal context from executable code, so
  # this fires too. Same trade-off as ADV-3; pinned for visibility.
  local f4
  f4="$(mk_fixture 'echo "we used to call bun -e here"')"
  tmpfiles+=("$f4")
  if _has_bun_e "$f4"; then
    ok 'ADV-4-string-literal (false-positive pinned; matcher is regex, not parser)'
  else
    nope 'ADV-4-string-literal' \
      "matcher missed string-literal shape — drift from documented limitation"
  fi

  # ─── structural-check-present anchor: known bypass shape ───────────

  # ADV-5: indirect invocation — `MSG="GH Actions..."; check "$MSG"`.
  # The anchor regex requires the literal string immediately after
  # `check "` so a future refactor extracting the label into a variable
  # would silently defeat the test. Pin: variable-form does NOT match.
  local f5
  f5="$(mktemp -t dry-run-adv.XXXXXX)"
  printf '%s\n' \
    'MSG="GH Actions workflow structure (top-level)"' \
    'check "$MSG" bash -c "true"' > "$f5"
  tmpfiles+=("$f5")
  if grep -qE '^[[:space:]]*check[[:space:]]+"GH Actions workflow structure' "$f5"; then
    nope 'ADV-5-var-msg' \
      "anchor unexpectedly matched variable-form invocation — pin says it should not"
  else
    ok 'ADV-5-var-msg (bypass confirmed; anchor is literal-only)'
  fi

  # ADV-6: leading-`#` comment — `# check "GH Actions workflow structure"`.
  # Anchor is `^[[:space:]]*check`; a `#` between whitespace and `check`
  # makes the match fail. Pin: comments do NOT spoof the anchor.
  local f6
  f6="$(mk_fixture '# check "GH Actions workflow structure" — TODO')"
  tmpfiles+=("$f6")
  if grep -qE '^[[:space:]]*check[[:space:]]+"GH Actions workflow structure' "$f6"; then
    nope 'ADV-6-comment-prefix' \
      "anchor matched a comment line — spoofing risk; tighten anchor"
  else
    ok 'ADV-6-comment-prefix (comment correctly rejected)'
  fi

  # ─── GH Actions workflow structure check: YAML edge cases ──────────

  # The check's body is inlined inside `check "..." bash -c '...'` —
  # replicate the same body verbatim so we can exercise it against
  # fixture YAML files without invoking the full dry-run.sh.
  _run_workflow_structure_check() {
    local dir="$1"
    (
      cd "$dir" || exit 99
      shopt -s nullglob
      for f in .github/workflows/*.yml; do
        [[ -s "$f" ]] || { echo "empty file: $f"; exit 1; }
        grep -qE "^on[[:space:]]*:" "$f" || { echo "missing top-level on: in $f"; exit 1; }
        grep -qE "^jobs[[:space:]]*:" "$f" || { echo "missing top-level jobs: in $f"; exit 1; }
        awk '/^\t/ { found=1 } END { exit found?1:0 }' "$f" \
          || { echo "tab indentation (YAML forbids tabs): $f"; exit 1; }
      done
    )
  }

  # ADV-7: empty workflow file (`: > foo.yml`) — check must fail with
  # "empty file" message. Plan FMTM lists this as "manual smoke"; we
  # automate it.
  local dir7
  dir7="$(mktemp -d -t dry-run-adv.XXXXXX)"
  tmpfiles+=("$dir7")  # mktemp -d → rm -rf below
  mkdir -p "$dir7/.github/workflows"
  : > "$dir7/.github/workflows/empty.yml"
  out="$(_run_workflow_structure_check "$dir7" 2>&1)"; rc=$?
  if (( rc != 0 )) && [[ "$out" == *"empty file:"* ]]; then
    ok 'ADV-7-empty-yml (structural check rejects empty file with clear error)'
  else
    nope 'ADV-7-empty-yml' \
      "expected rc=1 + 'empty file:' message; got rc=$rc, out=$out"
  fi

  # ADV-8: missing top-level `on:` — check must fail with "missing
  # top-level on:" message.
  local dir8
  dir8="$(mktemp -d -t dry-run-adv.XXXXXX)"
  tmpfiles+=("$dir8")
  mkdir -p "$dir8/.github/workflows"
  printf 'name: x\njobs:\n  a:\n    runs-on: ubuntu-latest\n' \
    > "$dir8/.github/workflows/no-on.yml"
  out="$(_run_workflow_structure_check "$dir8" 2>&1)"; rc=$?
  if (( rc != 0 )) && [[ "$out" == *"missing top-level on:"* ]]; then
    ok 'ADV-8-missing-on (structural check rejects missing on: with clear error)'
  else
    nope 'ADV-8-missing-on' \
      "expected rc=1 + 'missing top-level on:' message; got rc=$rc, out=$out"
  fi

  # ADV-9: missing top-level `jobs:` — check must fail with "missing
  # top-level jobs:" message.
  local dir9
  dir9="$(mktemp -d -t dry-run-adv.XXXXXX)"
  tmpfiles+=("$dir9")
  mkdir -p "$dir9/.github/workflows"
  printf 'name: x\non:\n  push:\n' > "$dir9/.github/workflows/no-jobs.yml"
  out="$(_run_workflow_structure_check "$dir9" 2>&1)"; rc=$?
  if (( rc != 0 )) && [[ "$out" == *"missing top-level jobs:"* ]]; then
    ok 'ADV-9-missing-jobs (structural check rejects missing jobs: with clear error)'
  else
    nope 'ADV-9-missing-jobs' \
      "expected rc=1 + 'missing top-level jobs:' message; got rc=$rc, out=$out"
  fi

  # ADV-10: tab indentation — YAML forbids tabs; check must fail with
  # "tab indentation" message.
  local dir10
  dir10="$(mktemp -d -t dry-run-adv.XXXXXX)"
  tmpfiles+=("$dir10")
  mkdir -p "$dir10/.github/workflows"
  printf 'name: x\non:\n  push:\njobs:\n\ta:\n\t\truns-on: ubuntu-latest\n' \
    > "$dir10/.github/workflows/tab.yml"
  out="$(_run_workflow_structure_check "$dir10" 2>&1)"; rc=$?
  if (( rc != 0 )) && [[ "$out" == *"tab indentation"* ]]; then
    ok 'ADV-10-tab-indent (structural check rejects tab indentation with clear error)'
  else
    nope 'ADV-10-tab-indent' \
      "expected rc=1 + 'tab indentation' message; got rc=$rc, out=$out"
  fi

  # ADV-11: quoted `on:` key — `'on':` or `"on":` (legitimate YAML; `on`
  # is a YAML 1.1 boolean alias). Current structural regex `^on:` does
  # NOT match `'on':`. Pin the current behavior so a future broadening
  # to `^["']?on["']?[[:space:]]*:` is explicit.
  local dir11
  dir11="$(mktemp -d -t dry-run-adv.XXXXXX)"
  tmpfiles+=("$dir11")
  mkdir -p "$dir11/.github/workflows"
  printf "name: x\n'on':\n  push:\njobs:\n  a:\n    runs-on: ubuntu-latest\n" \
    > "$dir11/.github/workflows/quoted-on.yml"
  out="$(_run_workflow_structure_check "$dir11" 2>&1)"; rc=$?
  if (( rc != 0 )) && [[ "$out" == *"missing top-level on:"* ]]; then
    ok 'ADV-11-quoted-on (current behavior pinned: quoted on: triggers false-positive miss)'
  else
    nope 'ADV-11-quoted-on' \
      "expected rc=1 + 'missing top-level on:' message — drift from documented behavior; got rc=$rc, out=$out"
  fi

  # ADV-12: clean workflow file — control case. Must pass cleanly.
  local dir12
  dir12="$(mktemp -d -t dry-run-adv.XXXXXX)"
  tmpfiles+=("$dir12")
  mkdir -p "$dir12/.github/workflows"
  printf 'name: x\non:\n  push:\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps: []\n' \
    > "$dir12/.github/workflows/clean.yml"
  out="$(_run_workflow_structure_check "$dir12" 2>&1)"; rc=$?
  if (( rc == 0 )); then
    ok 'ADV-12-clean-yml (well-formed workflow passes structural check)'
  else
    nope 'ADV-12-clean-yml' \
      "expected rc=0 on clean fixture; got rc=$rc, out=$out"
  fi

  # ADV-13: empty workflows directory — `shopt -s nullglob` skips the
  # for loop entirely; check passes (no workflows = no errors). Pin the
  # current behavior so a future "require at least one workflow" tweak
  # is explicit.
  local dir13
  dir13="$(mktemp -d -t dry-run-adv.XXXXXX)"
  tmpfiles+=("$dir13")
  mkdir -p "$dir13/.github/workflows"  # empty dir, no files
  out="$(_run_workflow_structure_check "$dir13" 2>&1)"; rc=$?
  if (( rc == 0 )) && [[ -z "$out" ]]; then
    ok 'ADV-13-empty-workflows-dir (no-op behavior pinned via nullglob)'
  else
    nope 'ADV-13-empty-workflows-dir' \
      "expected rc=0 + empty stdout on empty dir; got rc=$rc, out=$out"
  fi

  # Cleanup mktemp -d directories
  rm -rf "$dir7" "$dir8" "$dir9" "$dir10" "$dir11" "$dir12" "$dir13"

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  (( FAIL == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
