#!/usr/bin/env bash
# ENG-49 Gap #1 helper: render-pr-body assembles a PR body from
# brainstorm + plan + Linear stage-summary comments.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

# Allocate temp roots ENG-20-style (only platform tmp dirs allowed).
_TEST_TARGET="$(mktemp -d -t twinning-rpb-target.XXXXXX)"
_TEST_STUB="$(mktemp -d -t twinning-rpb-stub.XXXXXX)"
case "$_TEST_TARGET" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) echo "REFUSING bad tmp" >&2; exit 99 ;; esac
case "$_TEST_STUB"   in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) echo "REFUSING bad tmp" >&2; exit 99 ;; esac

# Register cleanup early so any abnormal exit doesn't leak temp dirs.
# HARNESS_STATE_DIR is added to the cleanup list once it's created.
_rpb_test_cleanup() {
  rm -rf "${_TEST_TARGET:-}" "${_TEST_STUB:-}" "${HARNESS_STATE_DIR:-/dev/null}"
}
trap _rpb_test_cleanup EXIT

# Stub TARGET_REPO with brainstorm + plan docs.
mkdir -p "$_TEST_TARGET/docs/brainstorms" "$_TEST_TARGET/docs/plans" "$_TEST_TARGET/.pipeline-config/schemas"
cat > "$_TEST_TARGET/docs/brainstorms/2026-04-30-eng-999-design.md" <<'MD'
---
linear: ENG-999
title: Test feature
date: 2026-04-30
---

# Test feature

## Overview

- First overview bullet
- Second overview bullet
- Third overview bullet

## Other section
Should not appear in PR body.
MD

cat > "$_TEST_TARGET/docs/plans/2026-04-30-eng-999.md" <<'MD'
---
linear: ENG-999
---

# Plan

## Failure Mode → Test Map
- F-001 → bin/foo-test.sh::test_foo
- F-002 → bin/bar-test.sh::test_bar
MD

cat > "$_TEST_TARGET/.pipeline-config/config.json" <<'JSON'
{"project":{"slug":"test-slug"}, "orchestrator":{"paused":false}}
JSON

# Stub linear.sh to return canned stage-summary comments.
cat > "$_TEST_STUB/linear.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  get-comments)
    cat <<'JSON'
[
  {"id":"c1","createdAt":"2026-04-30T10:00:00Z","body":"**implement summary**\n\n[branch-compare](https://example.com)\n\n**TL;DR** Backend: added widget storage layer with migration.\n\nNotes: none.\n"},
  {"id":"c2","createdAt":"2026-04-30T11:00:00Z","body":"**ui summary**\n\n[branch-compare](https://example.com)\n\n**TL;DR** Frontend: pass-through (no-op).\n\nNotes: none.\n"}
]
JSON
    ;;
  get-issue)
    printf '%s' '{"data":{"issue":{"identifier":"ENG-999","title":"Test feature","state":{"name":"In Progress"},"labels":{"nodes":[{"name":"Bug"}]}}}}'
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/linear.sh"

# Source target script with overridden roots.
export TARGET_REPO="$_TEST_TARGET"
PROJECT_SLUG="test-slug"
HARNESS_STATE_DIR="$(mktemp -d -t twinning-rpb-state.XXXXXX)"
case "$HARNESS_STATE_DIR" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
PROJECT_STATE_DIR="$HARNESS_STATE_DIR/$PROJECT_SLUG"
mkdir -p "$PROJECT_STATE_DIR"
export HARNESS_STATE_DIR PROJECT_STATE_DIR

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=render-pr-body.sh
source "$SCRIPT_DIR/render-pr-body.sh"
# Override post-source so render_pr_body uses our stub.
_RPB_LINEAR_SH="$_TEST_STUB/linear.sh"
export _RPB_LINEAR_SH

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# ─── Case 1: full-stack fixture ───────────────────────────────────────
body="$(render_pr_body ENG-999 eng-999-feature)"

if printf '%s\n' "$body" | grep -q '## Summary'; then ok "case-1 has Summary header"; else nope "case-1 has Summary header" "no header"; fi
if printf '%s\n' "$body" | grep -q 'First overview bullet'; then ok "case-1 includes brainstorm Overview bullet"; else nope "case-1 includes Overview bullet" "missing"; fi
if printf '%s\n' "$body" | grep -qE '## Linear'; then ok "case-1 has Linear section"; else nope "case-1 has Linear" "missing"; fi
if printf '%s\n' "$body" | grep -q 'ENG-999 — Test feature'; then ok "case-1 Linear line"; else nope "case-1 Linear line" "missing"; fi
if printf '%s\n' "$body" | grep -q '## Changes'; then ok "case-1 has Changes header"; else nope "case-1 has Changes" "missing"; fi
if printf '%s\n' "$body" | grep -q 'Backend: added widget storage layer with migration'; then ok "case-1 Backend bullet"; else nope "case-1 Backend bullet" "missing"; fi
if printf '%s\n' "$body" | grep -q 'Frontend: pass-through (no-op)'; then ok "case-1 Frontend bullet"; else nope "case-1 Frontend bullet" "missing"; fi
if printf '%s\n' "$body" | grep -q '## Test plan'; then ok "case-1 has Test plan header"; else nope "case-1 has Test plan" "missing"; fi
if printf '%s\n' "$body" | grep -q 'F-001'; then ok "case-1 includes plan F-001"; else nope "case-1 plan F-001" "missing"; fi
if printf '%s\n' "$body" | grep -q '## Screenshots'; then ok "case-1 has Screenshots header"; else nope "case-1 has Screenshots" "missing"; fi

# ─── Case 2: missing brainstorm Overview falls back to Linear title ───
rm "$_TEST_TARGET/docs/brainstorms/2026-04-30-eng-999-design.md"
body2="$(render_pr_body ENG-999 eng-999-feature 2>/dev/null)"
if printf '%s\n' "$body2" | grep -q 'Test feature'; then ok "case-2 fallback uses Linear issue title"; else nope "case-2 fallback" "no title"; fi

# ─── Case 3: missing stage-summary comments fall back to placeholders ─
# Re-stub linear.sh to return zero comments for the issue. The helper
# must still produce a valid body using the fallback bullets.
cat > "$_TEST_STUB/linear.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  get-comments) printf '%s' '[]' ;;
  get-issue) printf '%s' '{"data":{"issue":{"identifier":"ENG-999","title":"Test feature","state":{"name":"In Progress"},"labels":{"nodes":[{"name":"Bug"}]}}}}' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/linear.sh"

body3="$(render_pr_body ENG-999 eng-999-feature 2>/dev/null)"
if printf '%s\n' "$body3" | grep -q 'Backend: see commit log'; then
  ok "case-3 missing implement summary → 'see commit log' fallback"
else
  nope "case-3 missing implement summary fallback" "no fallback in body: $body3"
fi
if printf '%s\n' "$body3" | grep -q 'Frontend: pass-through (no-op)'; then
  ok "case-3 missing UI summary → 'pass-through (no-op)' fallback"
else
  nope "case-3 missing UI summary fallback" "no fallback in body: $body3"
fi

# ─── ENG-53 #7: source-robustness from a no-BASH_SOURCE context ─────────
# When sourced from `bash -c '... source render-pr-body.sh ...'` (the
# operator-subshell pattern Claude used during ENG-44's dogfood when
# manually opening PR #27), `${BASH_SOURCE[0]}` may be unset or empty.
# Pre-fix, `set -u` panics with "BASH_SOURCE[0]: parameter not set"
# before _RPB_SCRIPT_DIR is computed. The fallback chain
# `${BASH_SOURCE[0]:-${0:-}}` plus the PATH search must keep the script
# source-able. Asserted shape: subshell exits 0 AND `_rpb_title_type`
# is callable afterward.
HARNESS_BIN_DIR="$(cd "$SCRIPT_DIR" && pwd)"
TARGET_REPO="$_TEST_TARGET" \
PROJECT_SLUG="$PROJECT_SLUG" \
HARNESS_STATE_DIR="$HARNESS_STATE_DIR" \
PROJECT_STATE_DIR="$PROJECT_STATE_DIR" \
LINEAR_API_KEY="$LINEAR_API_KEY" \
HARNESS_BIN_DIR="$HARNESS_BIN_DIR" \
  bash -c '
    set -euo pipefail
    # Worst case: start with no BASH_SOURCE entries. The :-${0:-}
    # fallback in render-pr-body.sh:10 must not panic under set -u.
    # PATH-prepend the bin dir so the second branch of the fallback
    # chain (`command -v render-pr-body.sh`) can also resolve if needed.
    PATH="$HARNESS_BIN_DIR:$PATH"
    cd "$HARNESS_BIN_DIR"
    # Source via absolute path. After the fix, the script copes whether
    # BASH_SOURCE[0] arrives populated or not.
    source "$HARNESS_BIN_DIR/render-pr-body.sh"
    # Function must be defined.
    declare -F _rpb_title_type >/dev/null
    declare -F render_pr_body >/dev/null
  ' >/dev/null 2>&1 \
  && ok "ENG-53#7: render-pr-body.sh sources cleanly under set -u from bash -c" \
  || nope "ENG-53#7: source-robustness" \
    "the \${BASH_SOURCE[0]:-\${0:-}} fallback or PATH rescue is broken"

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
