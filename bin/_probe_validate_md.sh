#!/usr/bin/env bash
# Probe script for adversarial validate-md analysis.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DRY_RUN=1
export PIPELINE_DRY_RUN
export TARGET_REPO="$SCRIPT_DIR/../"
export PROJECT_SLUG=harness

VALIDATOR="$SCRIPT_DIR/plan-schema.sh"
TMPD="$(mktemp -d -t probe-validate-md.XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT

run_test() {
  local name="$1" file="$2" expect_rc="$3"
  local actual_rc=0
  local out
  out="$(bash "$VALIDATOR" validate-md "$file" 2>/dev/null)" || actual_rc=$?
  if [[ "$actual_rc" == "$expect_rc" ]]; then
    printf "PASS %-50s rc=%d\n" "$name" "$actual_rc"
  else
    printf "FAIL %-50s expected_rc=%d actual_rc=%d out=%s\n" "$name" "$expect_rc" "$actual_rc" "$out"
  fi
}

# ─── CRLF line endings ────────────────────────────────────────────────────────
# The heading regex is /^## System invariants[[:space:]]*$/ which uses $ anchor.
# With CRLF files, the \r at end-of-line becomes part of field in awk.
# `## System invariants\r` does NOT match /^## System invariants[[:space:]]*$/
# because \r is NOT in [[:space:]] on BSD awk (it IS on GNU awk).
printf '## System invariants\r\n\r\n- foo verified_by: bin/foo.sh:T_foo\r\n' > "$TMPD/crlf_heading.md"
run_test "CRLF heading line" "$TMPD/crlf_heading.md" 34
# Expectation: rc=34 (section not found) — CRLF makes heading fail to match

# ─── Section heading inside code fence ───────────────────────────────────────
# The validator does NOT parse code fences. A heading inside a triple-backtick
# block IS treated as a real section heading. This test checks that behavior.
cat > "$TMPD/heading_in_fence.md" <<'EOF'
# Main doc

```
## System invariants

- this is inside the fence, not real markdown
```

## Real section

Content here but no bullets with verified_by
EOF
run_test "Heading in code fence (no real section)" "$TMPD/heading_in_fence.md" 0
# Risk: if awk sees the heading inside the fence, it enters the section.
# Then the bullet (also inside fence) is counted. Expected behavior:
# The awk pattern /^## System invariants/ WILL match inside a code fence,
# so rc=0 even though there's no real System invariants section outside the fence.

# ─── Multiple ## System invariants sections ──────────────────────────────────
# Second occurrence re-enters in_section=1. Bullets from BOTH sections count
# toward the same bullet_count. A valid first section + malformed second
# section may yield different rc depending on ordering.
cat > "$TMPD/double_section_first_valid_second_bad.md" <<'EOF'
## System invariants

- good bullet verified_by: bin/foo.sh:T_foo

## Other

content

## System invariants

- bad bullet no token
EOF
run_test "Double section: first valid, second bad" "$TMPD/double_section_first_valid_second_bad.md" 34
# Expected: rc=34 (bullet in second section has no token)
# Actual behavior: awk re-enters in_section=1 on second heading. The bad bullet
# from the second section increments incomplete_count → rc=34.
# This is probably the CORRECT outcome, but it means: a plan with a valid first
# "System invariants" section that also has a second "System invariants" section
# (perhaps in a quoted block or H2-level aside) with bad bullets HALTS.

cat > "$TMPD/double_section_second_valid_first_bad.md" <<'EOF'
## System invariants

- bad bullet no token here

## Other

content

## System invariants

- good bullet verified_by: bin/foo.sh:T_foo
EOF
run_test "Double section: first bad, second valid" "$TMPD/double_section_second_valid_first_bad.md" 34
# The bad bullet from the first pass increments incomplete_count → rc=34 even
# though the second (authoritative) section is valid.

# ─── verified_by: with no space after colon ───────────────────────────────────
# verified_by:bin/foo.sh:T_foo (no space) — does the regex match?
# Pattern: verified_by:[[:space:]]*([^[:space:]]+:[^[:space:]]+|task:T[0-9]+)
# [[:space:]]* matches zero spaces, so verified_by:bin/foo.sh:T_foo SHOULD match.
cat > "$TMPD/no_space_after_colon.md" <<'EOF'
## System invariants

- I-1: foo verified_by:bin/foo.sh:T_foo
EOF
run_test "no space after colon in token" "$TMPD/no_space_after_colon.md" 0
# Expected: rc=0 (regex allows zero spaces after colon)

# ─── Trailing spaces in section heading ──────────────────────────────────────
# "## System invariants   " (3 trailing spaces)
# Pattern: /^## System invariants[[:space:]]*$/ allows trailing whitespace.
printf '## System invariants   \n\n- foo verified_by: bin/foo.sh:T_foo\n' > "$TMPD/heading_trailing_spaces.md"
run_test "Heading with trailing spaces" "$TMPD/heading_trailing_spaces.md" 0
# Expected: rc=0 (trailing spaces OK per regex)

# ─── Nested list bullet (2-space indent) ─────────────────────────────────────
# "  - sub-bullet" does NOT match /^- / (requires column-0 dash)
# So nested bullets are silently IGNORED, not counted toward bullet_count.
# If the section has ONLY nested bullets, bullet_count stays 0 → rc=34.
cat > "$TMPD/only_nested_bullets.md" <<'EOF'
## System invariants

  - nested bullet verified_by: bin/foo.sh:T_foo
  - nested bullet 2 verified_by: task:T1
EOF
run_test "Only nested bullets in section" "$TMPD/only_nested_bullets.md" 34
# Expected: rc=34 (nested bullets not counted, bullet_count=0)

# ─── Last line is bullet with no trailing newline ─────────────────────────────
# awk's END block fires after all input; bullet_count incremented before END.
# The lack of trailing newline means the last line is still processed by awk.
printf '## System invariants\n\n- foo verified_by: bin/foo.sh:T_foo' > "$TMPD/no_trailing_newline.md"
run_test "Last line bullet, no trailing newline" "$TMPD/no_trailing_newline.md" 0
# Expected: rc=0 — awk processes partial final line normally

# ─── verified_by: with only ONE token part (no second colon) ─────────────────
# verified_by: justonepart (no colon in the value part)
# Pattern requires: [^[:space:]]+:[^[:space:]]+ (two colon-separated parts)
# OR task:T[0-9]+.
# "justonepart" has no colon, so the combined regex must fail.
# Then it falls back to match(/verified_by:/) — which IS present — so: rc=33 (malformed).
cat > "$TMPD/single_part_token.md" <<'EOF'
## System invariants

- foo verified_by: justonepart
EOF
run_test "verified_by: with no colon in value" "$TMPD/single_part_token.md" 33
# Expected: rc=33 (token present but no colon → malformed)
# This is tested by the existing T_validate_md_malformed_token, but confirming
# the single-part case specifically.

# ─── verified_by: with semicolon-injected shell payload in value ──────────────
# verified_by: bin/foo.sh;evil-cmd:T_foo
# The awk output is captured via $() and printed via printf. There's NO shell
# eval of the token value. So shell metacharacters are safe.
cat > "$TMPD/shell_injection_semicolon.md" <<'EOF'
## System invariants

- foo verified_by: bin/foo.sh;evil-cmd:T_foo
EOF
run_test "semicolon in token path" "$TMPD/shell_injection_semicolon.md" 0
# Expected: rc=0 — awk matches [^[:space:]]+:[^[:space:]]+ greedily.
# "bin/foo.sh;evil-cmd" has no space and "T_foo" after the colon, so it matches.
# The semicolon is just part of the token string, never evaluated.

# ─── verified_by: with $() subshell injection in value ───────────────────────
cat > "$TMPD/shell_injection_subshell.md" <<'EOF'
## System invariants

- foo verified_by: $(rm-rf):test-name
EOF
run_test "subshell in token path" "$TMPD/shell_injection_subshell.md" 0
# Expected: rc=0 — awk is not a shell; $() is literal. The token
# "$(rm-rf)" contains no spaces; ":test-name" is the second part. Matches.
# The output is captured via awk_out="$(awk ... file)" — but the awk output is
# "plan-md-contract-valid: /path/to/file", not the token value itself.
# There is NO shell expansion of awk's stdout here.

# ─── verified_by: task:T0 (zero — is it valid?) ───────────────────────────────
# Pattern: task:T[0-9]+ — requires ONE or more digits. T0 matches.
cat > "$TMPD/task_T0.md" <<'EOF'
## System invariants

- foo verified_by: task:T0
EOF
run_test "task:T0 (zero digit)" "$TMPD/task_T0.md" 0
# Expected: rc=0 (T0 matches [0-9]+)

# ─── verified_by: task:T (no digits) — malformed? ────────────────────────────
# Pattern: task:T[0-9]+ requires >=1 digit. "task:T" alone fails the task branch.
# Then falls to `[^[:space:]]+:[^[:space:]]+` check: "task" and "T" are the two
# non-space tokens around ":", both non-empty. So the FIRST branch matches first!
# Wait — let's re-read the regex carefully:
# /verified_by:[[:space:]]*([^[:space:]]+:[^[:space:]]+|task:T[0-9]+)/
# This is one regex matching EITHER form. The first alternative is
# [^[:space:]]+:[^[:space:]]+ which matches "task:T" (task is non-space, T is non-space).
# So "task:T" would match the FIRST alternative and be accepted as rc=0.
cat > "$TMPD/task_T_no_digits.md" <<'EOF'
## System invariants

- foo verified_by: task:T
EOF
run_test "task:T with no digits (still matches path:test pattern)" "$TMPD/task_T_no_digits.md" 0
# Expected: rc=0 — because "task:T" matches the generic [^[:space:]]+:[^[:space:]]+ alternative

# ─── A bullet that IS the heading pattern (won't happen in practice but edge case)
# "- ## foo verified_by: bin/x.sh:T1" — the /^- / pattern wins before /^## /
cat > "$TMPD/bullet_looks_like_heading.md" <<'EOF'
## System invariants

- ## not a heading verified_by: bin/x.sh:T1
EOF
run_test "bullet containing ## not treated as heading" "$TMPD/bullet_looks_like_heading.md" 0
# Expected: rc=0 (^- / wins; ## in body is irrelevant)

printf '\nProbe complete.\n'
