#!/usr/bin/env bash
# Tests for validate_init_sh (bin/common.sh) and _assert_init_sh_well_formed
# (bin/dispatch.sh), per ENG-125. Pattern: source-and-stub (CLAUDE.md
# "How tests work"). Sources dispatch.sh which in turn sources common.sh,
# yielding both functions in the test process.
#
# Cases follow the plan's Failure Mode → Test Map:
#   T_valid_well_formed
#   T_missing_file
#   T_malformed_bash_n
#   T_incomplete_missing_smoke
#   T_incomplete_missing_typecheck
#   T_incomplete_missing_lint
#   T_incomplete_missing_test
#   T_marker_at_indent_rejected
#   T_detective_well_formed
#   T_detective_missing
#   T_detective_malformed
#   T_detective_incomplete

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"

PASS=0; FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2" >&2; }

FIXTURE_DIR="$(mktemp -d -t init-sh-validator-test.XXXXXX)"
# Install cleanup trap BEFORE sourcing — if dispatch.sh sourcing dies
# (e.g. common.sh missing) we still want FIXTURE_DIR removed.
trap 'rm -rf "$FIXTURE_DIR"' EXIT
export TARGET_REPO="$FIXTURE_DIR/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
printf '{"project":{"slug":"test-slug"}}\n' > "$TARGET_REPO/.pipeline-config/config.json"

# Source dispatch.sh (which sources common.sh) to load both functions.
# shellcheck source=dispatch.sh
source "$SCRIPT_DIR/dispatch.sh"

# ─── Helpers ─────────────────────────────────────────────────────────

# Write a well-formed init.sh fixture to the given path.
write_well_formed() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
# ENG-125: per-issue init.sh — smoke discipline.
set -euo pipefail

# ─── smoke ───
:

# ─── typecheck ───
:

# ─── lint ───
:

# ─── test ───
:
EOF
}

# Write a well-formed init.sh but with one specified marker removed.
write_missing_marker() {
  local path="$1" gate="$2"
  write_well_formed "$path"
  # Replace `# ─── <gate> ───` with `# (removed)` so the file is still bash -n clean
  # but the column-0 marker is absent.
  sed -i.bak "s|^# ─── ${gate} ───\$|# (removed)|" "$path"
  rm -f "${path}.bak"
}

printf '\n--- init-sh-validator-test: validate_init_sh + _assert_init_sh_well_formed ---\n'

# ─── T_valid_well_formed ────────────────────────────────────────────
INIT="$FIXTURE_DIR/t-valid.sh"
write_well_formed "$INIT"
rc=0; validate_init_sh "$INIT" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_valid_well_formed: shebang + 4 markers → rc=0" \
  || fail_at "T_valid_well_formed" "expected rc=0, got rc=$rc"

# ─── T_missing_file ─────────────────────────────────────────────────
rc=0; validate_init_sh "$FIXTURE_DIR/nonexistent.sh" >/dev/null 2>&1 || rc=$?
(( rc == 47 )) \
  && pass_at "T_missing_file: absent file → rc=47" \
  || fail_at "T_missing_file" "expected rc=47, got rc=$rc"

# ─── T_malformed_bash_n ─────────────────────────────────────────────
INIT="$FIXTURE_DIR/t-malformed.sh"
# Unbalanced quote → bash -n fails.
printf '#!/usr/bin/env bash\nset -euo pipefail\necho "unterminated\n' > "$INIT"
rc=0; validate_init_sh "$INIT" >/dev/null 2>&1 || rc=$?
(( rc == 45 )) \
  && pass_at "T_malformed_bash_n: unbalanced quote → rc=45" \
  || fail_at "T_malformed_bash_n" "expected rc=45, got rc=$rc"

# Tighter assertion shared across the four T_incomplete_missing_* cases:
# match BOTH the literal 'init-sh-incomplete: missing shape marker' prefix
# AND the gate-specific marker '# ─── <gate> ───'. The legacy form
# `[[ "$out" == *"<gate>"* ]]` was too loose — the gate name appears in two
# distinct places in the diagnostic (the prefix's "shape marker" sentence is
# the same for every gate; only the marker glyph differs), so any output
# containing the gate name passed even if the prefix had been mangled.

# ─── T_incomplete_missing_smoke ─────────────────────────────────────
INIT="$FIXTURE_DIR/t-no-smoke.sh"
write_missing_marker "$INIT" smoke
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 46 )) \
   && [[ "$out" == *"init-sh-incomplete: missing shape marker"* && "$out" == *"# ─── smoke ───"* ]]; then
  pass_at "T_incomplete_missing_smoke: → rc=46 + 'init-sh-incomplete: missing shape marker # ─── smoke ───'"
else
  fail_at "T_incomplete_missing_smoke" "rc=$rc out='$out'"
fi

# ─── T_incomplete_missing_typecheck ─────────────────────────────────
INIT="$FIXTURE_DIR/t-no-typecheck.sh"
write_missing_marker "$INIT" typecheck
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 46 )) \
   && [[ "$out" == *"init-sh-incomplete: missing shape marker"* && "$out" == *"# ─── typecheck ───"* ]]; then
  pass_at "T_incomplete_missing_typecheck: → rc=46 + 'init-sh-incomplete: missing shape marker # ─── typecheck ───'"
else
  fail_at "T_incomplete_missing_typecheck" "rc=$rc out='$out'"
fi

# ─── T_incomplete_missing_lint ──────────────────────────────────────
INIT="$FIXTURE_DIR/t-no-lint.sh"
write_missing_marker "$INIT" lint
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 46 )) \
   && [[ "$out" == *"init-sh-incomplete: missing shape marker"* && "$out" == *"# ─── lint ───"* ]]; then
  pass_at "T_incomplete_missing_lint: → rc=46 + 'init-sh-incomplete: missing shape marker # ─── lint ───'"
else
  fail_at "T_incomplete_missing_lint" "rc=$rc out='$out'"
fi

# ─── T_incomplete_missing_test ──────────────────────────────────────
INIT="$FIXTURE_DIR/t-no-test.sh"
write_missing_marker "$INIT" test
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 46 )) \
   && [[ "$out" == *"init-sh-incomplete: missing shape marker"* && "$out" == *"# ─── test ───"* ]]; then
  pass_at "T_incomplete_missing_test: → rc=46 + 'init-sh-incomplete: missing shape marker # ─── test ───'"
else
  fail_at "T_incomplete_missing_test" "rc=$rc out='$out'"
fi

# ─── T_marker_at_indent_rejected ────────────────────────────────────
# Marker indented (col 4) instead of col 0 → matcher requires `^# ─── <gate> ───$`,
# so the indented form is treated as ABSENT → rc=46.
INIT="$FIXTURE_DIR/t-indent.sh"
cat > "$INIT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
    # ─── smoke ───
:
# ─── typecheck ───
:
# ─── lint ───
:
# ─── test ───
:
EOF
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 46 )) \
   && [[ "$out" == *"init-sh-incomplete: missing shape marker"* && "$out" == *"# ─── smoke ───"* ]]; then
  pass_at "T_marker_at_indent_rejected: indented marker → rc=46 (column-0 anchor pins ^)"
else
  fail_at "T_marker_at_indent_rejected" "rc=$rc out='$out'"
fi

# ─── T_detective_well_formed ────────────────────────────────────────
# _assert_init_sh_well_formed signature: <issue_dir> <violation_file> <stage>
ISSUE_DIR="$FIXTURE_DIR/detective-ok"; mkdir -p "$ISSUE_DIR"
write_well_formed "$ISSUE_DIR/init.sh"
VIOL="$ISSUE_DIR/.transcript-violation-planning"
rm -f "$VIOL"
rc=0; _assert_init_sh_well_formed "$ISSUE_DIR" "$VIOL" "planning" || rc=$?
if (( rc == 0 )) && [[ ! -s "$VIOL" ]]; then
  pass_at "T_detective_well_formed: → rc=0, no violation file"
else
  fail_at "T_detective_well_formed" "rc=$rc violation=$(cat "$VIOL" 2>/dev/null || echo '<none>')"
fi

# ─── T_detective_missing ────────────────────────────────────────────
ISSUE_DIR="$FIXTURE_DIR/detective-missing"; mkdir -p "$ISSUE_DIR"
rm -f "$ISSUE_DIR/init.sh"
VIOL="$ISSUE_DIR/.transcript-violation-planning"; rm -f "$VIOL"
rc=0; _assert_init_sh_well_formed "$ISSUE_DIR" "$VIOL" "planning" || rc=$?
if (( rc == 47 )) && grep -q "init-sh-missing" "$VIOL"; then
  pass_at "T_detective_missing: → rc=47 + 'init-sh-missing' diagnostic"
else
  fail_at "T_detective_missing" "rc=$rc violation=$(cat "$VIOL" 2>/dev/null || echo '<none>')"
fi

# ─── T_detective_malformed ──────────────────────────────────────────
ISSUE_DIR="$FIXTURE_DIR/detective-malformed"; mkdir -p "$ISSUE_DIR"
printf '#!/usr/bin/env bash\necho "unterminated\n' > "$ISSUE_DIR/init.sh"
VIOL="$ISSUE_DIR/.transcript-violation-planning"; rm -f "$VIOL"
rc=0; _assert_init_sh_well_formed "$ISSUE_DIR" "$VIOL" "planning" || rc=$?
if (( rc == 45 )) && grep -q "init-sh-malformed" "$VIOL"; then
  pass_at "T_detective_malformed: → rc=45 + 'init-sh-malformed' diagnostic"
else
  fail_at "T_detective_malformed" "rc=$rc violation=$(cat "$VIOL" 2>/dev/null || echo '<none>')"
fi

# ─── T_detective_incomplete ─────────────────────────────────────────
ISSUE_DIR="$FIXTURE_DIR/detective-incomplete"; mkdir -p "$ISSUE_DIR"
write_missing_marker "$ISSUE_DIR/init.sh" lint
VIOL="$ISSUE_DIR/.transcript-violation-planning"; rm -f "$VIOL"
rc=0; _assert_init_sh_well_formed "$ISSUE_DIR" "$VIOL" "planning" || rc=$?
if (( rc == 46 )) && grep -q "init-sh-incomplete" "$VIOL"; then
  pass_at "T_detective_incomplete: → rc=46 + 'init-sh-incomplete' diagnostic"
else
  fail_at "T_detective_incomplete" "rc=$rc violation=$(cat "$VIOL" 2>/dev/null || echo '<none>')"
fi

printf '\ninit-sh-validator-test: passed=%d failed=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
