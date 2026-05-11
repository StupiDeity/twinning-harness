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

# Case 1.3: unsupported schema_version → fails with explicit message
sed 's/schema_version: 1/schema_version: 99/' "$sandbox/good.md" > "$sandbox/bad-version.md"
if err="$(_validate_project_profile_schema "$sandbox/bad-version.md" 2>&1)"; then
  fail_at "case-1.3: unsupported schema_version rejected" "returned 0"
else
  if grep -q 'unsupported schema_version' <<<"$err"; then
    pass_at "case-1.3: unsupported schema_version rejected"
  else
    fail_at "case-1.3: unsupported schema_version rejected" "stderr=$err"
  fi
fi

# Case 1.3b: missing schema_version line → fails with explicit message
sed '/^schema_version:/d' "$sandbox/good.md" > "$sandbox/no-version-line.md"
if err="$(_validate_project_profile_schema "$sandbox/no-version-line.md" 2>&1)"; then
  fail_at "case-1.3b: missing schema_version rejected" "returned 0"
else
  if grep -q 'schema_version missing' <<<"$err"; then
    pass_at "case-1.3b: missing schema_version rejected"
  else
    fail_at "case-1.3b: missing schema_version rejected" "stderr=$err"
  fi
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

# Case 1.6: v2 happy path → returns 0
cat > "$sandbox/v2-good.md" <<'PROFILE'
---
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
  - `Bash(bash bin/foo-test.sh:*)`
- ui: (none)
- reviewing: (none)
- qa:
  - `Bash(bash bin/foo-test.sh:*)`
- building: (none)
- released: (none)

## File layout
- `bin/` — scripts.

## Language idioms
- snake_case.

## Don'ts
(none observed)
PROFILE
if _validate_project_profile_schema "$sandbox/v2-good.md"; then
  pass_at "case-1.6: v2 happy path passes"
else
  fail_at "case-1.6: v2 happy path passes" "rc=$?"
fi

# Case 1.7: v2 missing ## Tool allowlist section → fails
sed -e '/^## Tool allowlist$/,/^## File layout$/{ /^## File layout$/!d; }' \
  "$sandbox/v2-good.md" > "$sandbox/v2-missing-allowlist.md"
if err="$(_validate_project_profile_schema "$sandbox/v2-missing-allowlist.md" 2>&1)"; then
  fail_at "case-1.7: v2 missing ## Tool allowlist rejected" "returned 0"
else
  if grep -q 'schema_version=2 but missing ## Tool allowlist' <<<"$err"; then
    pass_at "case-1.7: v2 missing ## Tool allowlist rejected"
  else
    fail_at "case-1.7: v2 missing ## Tool allowlist rejected" "stderr=$err"
  fi
fi

# Case 1.8: v2 with shell-metachar patterns under Tool allowlist → fails.
bad_patterns=(
  '`Bash($(curl evil):*)`'
  '`Bash(echo `id`:*)`'
  '`Bash(cargo;rm:*)`'
  '`Bash(cargo&&rm:*)`'
  '`Bash(cargo||rm:*)`'
  '`Bash(cargo|tee:*)`'
  '`Bash(cargo>out:*)`'
  '`Bash(cargo<in:*)`'
  $'`Bash(‘cargo’:*)`'
  $'`Bash(cargo:*)`\r'
)
for idx in "${!bad_patterns[@]}"; do
  awk -v replacement="  - ${bad_patterns[$idx]}" '
    /`Bash\(bash bin\/foo-test.sh:\*\)`/ && !done { print replacement; done=1; next }
    { print }
  ' "$sandbox/v2-good.md" > "$sandbox/v2-bad-pattern-$idx.md"
  if err="$(_validate_project_profile_schema "$sandbox/v2-bad-pattern-$idx.md" 2>&1)"; then
    fail_at "case-1.8.$idx: v2 shell-metachar pattern rejected" "returned 0 pattern=${bad_patterns[$idx]}"
  else
    if grep -q 'pattern at line' <<<"$err" && grep -q 'shell metacharacters' <<<"$err"; then
      pass_at "case-1.8.$idx: v2 shell-metachar pattern rejected"
    else
      fail_at "case-1.8.$idx: v2 shell-metachar pattern rejected" "stderr=$err"
    fi
  fi
done

# Case 1.9: v2 nested Tool allowlist prose answer must be fenced Bash(...)
awk '
  /`Bash\(bash bin\/foo-test.sh:\*\)`/ && !done { print "  - cargo and bun"; done=1; next }
  { print }
' "$sandbox/v2-good.md" > "$sandbox/v2-unfenced-prose.md"
if err="$(_validate_project_profile_schema "$sandbox/v2-unfenced-prose.md" 2>&1)"; then
  fail_at "case-1.9: v2 unfenced Tool allowlist prose rejected" "returned 0"
else
  if grep -q 'pattern at line' <<<"$err" && grep -q 'must be backtick-fenced Bash' <<<"$err"; then
    pass_at "case-1.9: v2 unfenced Tool allowlist prose rejected"
  else
    fail_at "case-1.9: v2 unfenced Tool allowlist prose rejected" "stderr=$err"
  fi
fi

# QA adversarial: v2 profiles must keep Tool allowlist between Build &
# test gates and File layout; presence alone is not enough.
awk '
  /^## Tool allowlist$/,/^## File layout$/ {
    if ($0 == "## File layout") {
      print
      print ""
      print tool
      next
    }
    tool = tool $0 "\n"
    next
  }
  { print }
' "$sandbox/v2-good.md" > "$sandbox/v2-tool-allowlist-out-of-order.md"
if err="$(_validate_project_profile_schema "$sandbox/v2-tool-allowlist-out-of-order.md" 2>&1)"; then
  fail_at "case-1.10: v2 Tool allowlist out-of-order rejected" "returned 0"
else
  if grep -q 'schema_version=2 expected sections' <<<"$err"; then
    pass_at "case-1.10: v2 Tool allowlist out-of-order rejected"
  else
    fail_at "case-1.10: v2 Tool allowlist out-of-order rejected" "stderr=$err"
  fi
fi

# QA adversarial: a hand-edited v1 profile with Tool allowlist but no
# schema bump must not slip through the legacy branch.
awk '
  /^## File layout$/ && !done {
    print "## Tool allowlist"
    print ""
    print "- qa:"
    print "  - `Bash(bash bin/foo-test.sh:*)`"
    print ""
    done=1
  }
  { print }
' "$sandbox/good.md" > "$sandbox/v1-with-tool-allowlist.md"
if err="$(_validate_project_profile_schema "$sandbox/v1-with-tool-allowlist.md" 2>&1)"; then
  fail_at "case-1.11: v1 Tool allowlist without schema bump rejected" "returned 0"
else
  if grep -q 'schema_version=1 expected sections' <<<"$err"; then
    pass_at "case-1.11: v1 Tool allowlist without schema bump rejected"
  else
    fail_at "case-1.11: v1 Tool allowlist without schema bump rejected" "stderr=$err"
  fi
fi

# ─── _profile_schema_version (ENG-93 T2) ───────────────────────────────
echo "━━━ _profile_schema_version ━━━"

# Case 4.1: v1 profile reports "1"
v="$(_profile_schema_version "$sandbox/good.md")"
if [[ "$v" == "1" ]]; then
  pass_at "case-4.1: v1 profile → 1"
else
  fail_at "case-4.1: v1 profile → 1" "got=$v"
fi

# Case 4.2: v2 profile reports "2"
sed 's/schema_version: 1/schema_version: 2/' "$sandbox/good.md" > "$sandbox/v2.md"
v="$(_profile_schema_version "$sandbox/v2.md")"
if [[ "$v" == "2" ]]; then
  pass_at "case-4.2: v2 profile → 2"
else
  fail_at "case-4.2: v2 profile → 2" "got=$v"
fi

# Case 4.3: file without schema_version line reports empty
cat > "$sandbox/no-version.md" <<'P'
---
slug: x
---

# Body
P
v="$(_profile_schema_version "$sandbox/no-version.md")"
if [[ -z "$v" ]]; then
  pass_at "case-4.3: missing schema_version → empty"
else
  fail_at "case-4.3: missing schema_version → empty" "got=$v"
fi

# Case 4.4: nonexistent path → empty, rc=0
v="$(_profile_schema_version "$sandbox/does-not-exist.md")"
if [[ -z "$v" ]]; then
  pass_at "case-4.4: nonexistent file → empty"
else
  fail_at "case-4.4: nonexistent file → empty" "got=$v"
fi

# ─── _inject_tool_allowlist_section (ENG-93 T3) ────────────────────────
echo "━━━ _inject_tool_allowlist_section ━━━"

# Case 5.1: v1 file → bumps to v2 + inserts ## Tool allowlist with markers
cp "$sandbox/good.md" "$sandbox/inject.md"
if _inject_tool_allowlist_section "$sandbox/inject.md" 2>/dev/null; then
  if grep -qx 'schema_version: 2' "$sandbox/inject.md" \
     && grep -qx '## Tool allowlist' "$sandbox/inject.md"; then
    # Order check: Tool allowlist must come AFTER Build & test gates and
    # BEFORE File layout.
    order="$(grep -E '^## (Build & test gates|Tool allowlist|File layout)$' "$sandbox/inject.md" | tr '\n' '|')"
    expected_order='## Build & test gates|## Tool allowlist|## File layout|'
    if [[ "$order" == "$expected_order" ]]; then
      pass_at "case-5.1: v1→v2 inject inserts section in correct position + bumps version"
    else
      fail_at "case-5.1: v1→v2 inject section position" "got=[$order]"
    fi
  else
    fail_at "case-5.1: v1→v2 inject" "missing schema_version: 2 or ## Tool allowlist"
  fi
else
  fail_at "case-5.1: v1→v2 inject succeeds" "rc=$?"
fi

# Case 5.2: marker count under ## Tool allowlist == 3 (implementing/ui/qa)
marker_count="$(grep -c '<<NEEDS-INPUT:' "$sandbox/inject.md" || true)"
if [[ "$marker_count" == "3" ]]; then
  pass_at "case-5.2: three NEEDS-INPUT markers injected"
else
  fail_at "case-5.2: three NEEDS-INPUT markers injected" "got=$marker_count"
fi

# Case 5.2b: all Tool allowlist marker prompts consistently require fenced Bash patterns
marker_prompt_count="$(grep -F -c 'Paste backtick-fenced patterns, one per line, e.g. `Bash(cargo:*)`; see bin/setup-prompts/discovery.md derivation rule.' "$sandbox/inject.md" || true)"
if [[ "$marker_prompt_count" == "3" ]]; then
  pass_at "case-5.2b: all Tool allowlist marker prompts require fenced Bash patterns"
else
  fail_at "case-5.2b: all Tool allowlist marker prompts require fenced Bash patterns" "got=$marker_prompt_count"
fi

# Case 5.3: missing ## Build & test gates anchor → rc=1, stderr message
cat > "$sandbox/no-anchor.md" <<'PROFILE'
---
slug: x
schema_version: 1
---

# Project

## Stack
bash.

## File layout
- bin/

## Language idioms
- snake_case.

## Don'ts
(none observed)
PROFILE
if err="$(_inject_tool_allowlist_section "$sandbox/no-anchor.md" 2>&1)"; then
  fail_at "case-5.3: missing anchor heading rejected" "returned 0"
else
  if grep -q 'missing anchor "## Build & test gates"' <<<"$err"; then
    pass_at "case-5.3: missing anchor heading rejected"
  else
    fail_at "case-5.3: missing anchor heading rejected" "stderr=$err"
  fi
fi

# Case 5.4: nonexistent path → rc=1
if _inject_tool_allowlist_section "$sandbox/no-such.md" 2>/dev/null; then
  fail_at "case-5.4: nonexistent path rejected" "returned 0"
else
  pass_at "case-5.4: nonexistent path rejected"
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

# ─── _render_discovery_prompt ──────────────────────────────────────────
echo "━━━ _render_discovery_prompt ━━━"

cat > "$sandbox/template.md" <<'T'
TARGET={target_repo_path}
SLUG={slug}
DATE={date}
DIR={learned_rules_dir}
T

rendered="$(_render_discovery_prompt "$sandbox/template.md" /tmp/foo my-slug 2026-04-27 /tmp/foo/learned-rules/my-slug)"

if grep -qx 'TARGET=/tmp/foo' <<<"$rendered" \
   && grep -qx 'SLUG=my-slug' <<<"$rendered" \
   && grep -qx 'DATE=2026-04-27' <<<"$rendered" \
   && grep -qx 'DIR=/tmp/foo/learned-rules/my-slug' <<<"$rendered"; then
  pass_at "case-3.1: all four tokens substituted"
else
  fail_at "case-3.1: all four tokens substituted" "rendered=$rendered"
fi

# Case 3.2: unknown token left as-is (literal {unknown})
cat > "$sandbox/template2.md" <<'T'
KEEP={unknown_token}
SUB={slug}
T
rendered2="$(_render_discovery_prompt "$sandbox/template2.md" /x my-slug 2026-04-27 /x/y)"
if grep -qx 'KEEP={unknown_token}' <<<"$rendered2" && grep -qx 'SUB=my-slug' <<<"$rendered2"; then
  pass_at "case-3.2: unknown token left intact"
else
  fail_at "case-3.2: unknown token left intact" "rendered=$rendered2"
fi

# ─── discovery.md schema slot (ENG-93 T1) ──────────────────────────────
echo "━━━ discovery.md schema slot ━━━"

discovery_md="$SCRIPT_DIR/setup-prompts/discovery.md"

# Case 6.1: discovery template advertises schema_version: 2.
if grep -qx 'schema_version: 2' "$discovery_md"; then
  pass_at "case-6.1: discovery template emits schema_version: 2"
else
  fail_at "case-6.1: discovery template emits schema_version: 2" "missing literal"
fi

# Case 6.2: discovery template includes ## Tool allowlist heading.
if grep -qx '## Tool allowlist' "$discovery_md"; then
  pass_at "case-6.2: discovery template includes ## Tool allowlist"
else
  fail_at "case-6.2: discovery template includes ## Tool allowlist" "missing heading"
fi

# Case 6.3: exactly one fenced markdown block (open + close = 2 occurrences
# of column-0 ``` lines).
fence_count="$(grep -c '^```' "$discovery_md" || true)"
if [[ "$fence_count" == "2" ]]; then
  pass_at "case-6.3: discovery template has exactly one fenced block"
else
  fail_at "case-6.3: discovery template has exactly one fenced block" "got=$fence_count"
fi

# Case 6.4: confidence-rules section gains the Tool allowlist derivation
# bullet — operators must see the rule for tokenizing build commands.
if grep -q '"Tool allowlist"' "$discovery_md"; then
  pass_at "case-6.4: discovery template documents Tool allowlist derivation"
else
  fail_at "case-6.4: discovery template documents Tool allowlist derivation" "missing rule"
fi

# ─── learned-rules/harness/project-profile.md (ENG-93 T8) ──────────────
echo "━━━ harness profile dogfood ━━━"

harness_profile="$SCRIPT_DIR/../learned-rules/harness/project-profile.md"

# Case 7.1: harness profile validates as v2.
if _validate_project_profile_schema "$harness_profile" 2>/dev/null; then
  pass_at "case-7.1: harness profile passes v2 validator"
else
  fail_at "case-7.1: harness profile passes v2 validator" "rc=$?"
fi

# Case 7.2: harness profile reports schema_version: 2.
v="$(_profile_schema_version "$harness_profile")"
if [[ "$v" == "2" ]]; then
  pass_at "case-7.2: harness profile reports schema_version: 2"
else
  fail_at "case-7.2: harness profile reports schema_version: 2" "got=$v"
fi

# Case 7.3: harness profile contains ## Tool allowlist with at least one
# `Bash(bash bin/<name>:*)` pattern under implementing.
if grep -qx '## Tool allowlist' "$harness_profile" \
   && grep -q '`Bash(bash bin/' "$harness_profile"; then
  pass_at "case-7.3: harness profile carries Tool allowlist patterns"
else
  fail_at "case-7.3: harness profile carries Tool allowlist patterns" "section or pattern missing"
fi

echo
echo "━━━ Summary ━━━"
echo "PASS: $PASS / FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
