#!/usr/bin/env bash
# Tests for bin/setup-helpers.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
export PIPELINE_DRY_RUN=1
# shellcheck source=setup-helpers.sh
source "$SCRIPT_DIR/setup-helpers.sh"

PASS=0; FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2"; }

# ─── _validate_project_profile_schema ──────────────────────────────────
echo "━━━ _validate_project_profile_schema ━━━"

sandbox="$(mktemp -d -t setup-helpers-test-XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT

# Case 1.1: well-formed file → returns 0
cat > "$sandbox/good.md" <<'PROFILE'
---
slug: test-slug
generated_at: 2026-04-27T00:00:00Z
generated_by: discovery-agent
schema_version: 1
---

# Project profile — Test

## Stack

bash.

## Build & test gates

- Build: `(n/a) — interpreted`
- Test: `bash bin/foo-test.sh`
- Lint/check: `(n/a)`
- Integration/E2E: `(n/a)`

## File layout

- `bin/` — scripts.

## Language idioms

- snake_case.

## Don'ts

(none observed)
PROFILE

if _validate_project_profile_schema "$sandbox/good.md"; then
  pass_at "case-1.1: well-formed file passes"
else
  fail_at "case-1.1: well-formed file passes" "rc=$?"
fi

# Case 1.2: missing frontmatter → fails
cat > "$sandbox/no-frontmatter.md" <<'PROFILE'
# Project profile — Test
## Stack
bash.
## Build & test gates
## File layout
## Language idioms
## Don'ts
PROFILE
if _validate_project_profile_schema "$sandbox/no-frontmatter.md" 2>/dev/null; then
  fail_at "case-1.2: missing frontmatter rejected" "returned 0"
else
  pass_at "case-1.2: missing frontmatter rejected"
fi

# Case 1.3: wrong schema_version → fails
sed 's/schema_version: 1/schema_version: 99/' "$sandbox/good.md" > "$sandbox/bad-version.md"
if _validate_project_profile_schema "$sandbox/bad-version.md" 2>/dev/null; then
  fail_at "case-1.3: schema_version != 1 rejected" "returned 0"
else
  pass_at "case-1.3: schema_version != 1 rejected"
fi

# Case 1.4: missing one section → fails
sed '/^## Don'\''ts$/,$d' "$sandbox/good.md" > "$sandbox/missing-section.md"
if _validate_project_profile_schema "$sandbox/missing-section.md" 2>/dev/null; then
  fail_at "case-1.4: missing section rejected" "returned 0"
else
  pass_at "case-1.4: missing section rejected"
fi

# Case 1.5: sections out of order → fails
awk '
  /^## Stack$/ { print "## Build & test gates"; next }
  /^## Build & test gates$/ { print "## Stack"; next }
  { print }
' "$sandbox/good.md" > "$sandbox/wrong-order.md"
if _validate_project_profile_schema "$sandbox/wrong-order.md" 2>/dev/null; then
  fail_at "case-1.5: sections out of order rejected" "returned 0"
else
  pass_at "case-1.5: sections out of order rejected"
fi

# ─── _resolve_profile_markers ──────────────────────────────────────────
echo "━━━ _resolve_profile_markers ━━━"

# Case 2.1: single marker, single answer
cat > "$sandbox/one-marker.md" <<'P'
## Stack
<<NEEDS-INPUT: What is the build command?>>
## Done
P
printf 'cargo build\n' | _resolve_profile_markers "$sandbox/one-marker.md" >/dev/null
if grep -q 'cargo build' "$sandbox/one-marker.md" && ! grep -q 'NEEDS-INPUT' "$sandbox/one-marker.md"; then
  pass_at "case-2.1: single marker resolved"
else
  fail_at "case-2.1: single marker resolved" "$(cat "$sandbox/one-marker.md")"
fi

# Case 2.2: three markers, three answers in order
cat > "$sandbox/three-markers.md" <<'P'
A: <<NEEDS-INPUT: q1?>>
B: <<NEEDS-INPUT: q2?>>
C: <<NEEDS-INPUT: q3?>>
P
printf 'one\ntwo\nthree\n' | _resolve_profile_markers "$sandbox/three-markers.md" >/dev/null
if grep -qx 'A: one' "$sandbox/three-markers.md" \
   && grep -qx 'B: two' "$sandbox/three-markers.md" \
   && grep -qx 'C: three' "$sandbox/three-markers.md"; then
  pass_at "case-2.2: three markers resolved in order"
else
  fail_at "case-2.2: three markers resolved in order" "$(cat "$sandbox/three-markers.md")"
fi

# Case 2.3: empty answer re-prompts (3 retries then fails)
cat > "$sandbox/empty.md" <<'P'
X: <<NEEDS-INPUT: q?>>
P
if printf '\n\n\n\n' | _resolve_profile_markers "$sandbox/empty.md" >/dev/null 2>&1; then
  fail_at "case-2.3: empty-answer abort after 3 retries" "returned 0"
else
  pass_at "case-2.3: empty-answer abort after 3 retries"
fi

# Case 2.4: clean file → no prompts, exit 0
cat > "$sandbox/clean.md" <<'P'
nothing to resolve here.
P
if </dev/null _resolve_profile_markers "$sandbox/clean.md" >/dev/null; then
  pass_at "case-2.4: clean file exits 0 with no input"
else
  fail_at "case-2.4: clean file exits 0 with no input" "rc=$?"
fi

# Case 2.5: marker with embedded ':' in question
cat > "$sandbox/colon.md" <<'P'
Q: <<NEEDS-INPUT: ratio of frontend:backend code?>>
P
printf '50:50\n' | _resolve_profile_markers "$sandbox/colon.md" >/dev/null
if grep -qx 'Q: 50:50' "$sandbox/colon.md"; then
  pass_at "case-2.5: marker question with embedded colon"
else
  fail_at "case-2.5: marker question with embedded colon" "$(cat "$sandbox/colon.md")"
fi

echo
echo "━━━ Summary ━━━"
echo "PASS: $PASS / FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
