#!/usr/bin/env bash
# Adversarial tests for validate_init_sh (bin/common.sh) and
# _assert_init_sh_well_formed (bin/dispatch.sh), per ENG-125.
#
# Covers boundary cases pinning the column-0 / `^…$` regex anchors,
# heredoc-hijack resistance, empty-file behavior, and the
# "runs cleanly under bash" acceptance criterion.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"

PASS=0; FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2" >&2; }

FIXTURE_DIR="$(mktemp -d -t init-sh-validator-adv-test.XXXXXX)"
export TARGET_REPO="$FIXTURE_DIR/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
printf '{"project":{"slug":"test-slug"}}\n' > "$TARGET_REPO/.pipeline-config/config.json"

# shellcheck source=dispatch.sh
source "$SCRIPT_DIR/dispatch.sh"

trap 'rm -rf "$FIXTURE_DIR"' EXIT

printf '\n--- init-sh-validator-adversarial-test: ENG-125 ---\n'

# ─── T_adv_hijack_marker_in_quoted_string ───────────────────────────
# A quoted string containing `# ─── smoke ───` inside a heredoc body must
# NOT count as a real marker. The matcher's `^…$` anchor requires the marker
# line to BE the marker line at column 0 with no surrounding content.
# Here we embed the lookalike line INSIDE a quoted command argument; the
# real column-0 markers for typecheck/lint/test are present, smoke is NOT.
INIT="$FIXTURE_DIR/t-hijack.sh"
cat > "$INIT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "# ─── smoke ───"
# ─── typecheck ───
:
# ─── lint ───
:
# ─── test ───
:
EOF
# bash treats `echo "# ─── smoke ───"` as a single command; the literal "smoke"
# marker text appears inside a double-quoted string. validate_init_sh's grep
# regex `^# ─── smoke ───$` requires the COMPLETE LINE to be the marker; the
# echo wrapper means the smoke-marker line in the file actually reads
# `echo "# ─── smoke ───"` which does NOT match. So this fixture is missing
# the smoke marker and should return rc=40.
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 40 )) && [[ "$out" == *"smoke"* ]]; then
  pass_at "T_adv_hijack_marker_in_quoted_string: echo-wrapped lookalike → rc=40 (no smoke)"
else
  fail_at "T_adv_hijack_marker_in_quoted_string" "rc=$rc out='$out'"
fi

# ─── T_adv_marker_with_trailing_whitespace ──────────────────────────
# A line `# ─── smoke ───  ` (trailing spaces) must NOT match. Pins the `$`
# anchor. The file is otherwise well-formed (other 3 markers present).
# Use printf so trailing spaces are explicit (heredocs would obscure them).
INIT="$FIXTURE_DIR/t-trailing-ws.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf '# ─── smoke ───  \n'
  printf '%s\n' ':'
  printf '%s\n' '# ─── typecheck ───'
  printf '%s\n' ':'
  printf '%s\n' '# ─── lint ───'
  printf '%s\n' ':'
  printf '%s\n' '# ─── test ───'
  printf '%s\n' ':'
} > "$INIT"
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 40 )) && [[ "$out" == *"smoke"* ]]; then
  pass_at "T_adv_marker_with_trailing_whitespace: trailing spaces → rc=40 (\$-anchor pinned)"
else
  fail_at "T_adv_marker_with_trailing_whitespace" "rc=$rc out='$out'"
fi

# ─── T_adv_zero_byte_file ───────────────────────────────────────────
# Empty init.sh → bash -n is clean on empty input; first missing marker is
# smoke; detective falls through to incomplete, not malformed.
INIT="$FIXTURE_DIR/t-empty.sh"
: > "$INIT"
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 40 )) && [[ "$out" == *"smoke"* ]]; then
  pass_at "T_adv_zero_byte_file: empty file → rc=40 (incomplete, not malformed)"
else
  fail_at "T_adv_zero_byte_file" "rc=$rc out='$out'"
fi

# ─── T_adv_bash_n_on_non_bash_shebang ───────────────────────────────
# `#!/bin/sh` shebang with bash-only syntax: bash -n still validates against
# the bash parser (validate_init_sh shells out to `bash -n` regardless of
# shebang). Documents the choice: we validate SHAPE, not portability.
INIT="$FIXTURE_DIR/t-sh-shebang.sh"
cat > "$INIT" <<'EOF'
#!/bin/sh
# ─── smoke ───
[[ -d / ]]
# ─── typecheck ───
:
# ─── lint ───
:
# ─── test ───
:
EOF
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
(( rc == 0 )) \
  && pass_at "T_adv_bash_n_on_non_bash_shebang: /bin/sh shebang + bash syntax → rc=0 (shape, not portability)" \
  || fail_at "T_adv_bash_n_on_non_bash_shebang" "rc=$rc out='$out'"

# ─── T_adv_marker_inside_comment_block ──────────────────────────────
# A marker line indented inside a `cat <<COMMENT` heredoc body must NOT
# match the column-0 anchor. Use a heredoc whose body lines are indented;
# the indented marker-lookalike does not satisfy `^# ─── …$`.
INIT="$FIXTURE_DIR/t-heredoc-hijack.sh"
cat > "$INIT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<COMMENT
    # ─── smoke ───
    indented body — column-4 not column-0
COMMENT
# ─── typecheck ───
:
# ─── lint ───
:
# ─── test ───
:
EOF
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 40 )) && [[ "$out" == *"smoke"* ]]; then
  pass_at "T_adv_marker_inside_comment_block: heredoc-indented marker → rc=40 (column-0 anchor pinned)"
else
  fail_at "T_adv_marker_inside_comment_block" "rc=$rc out='$out'"
fi

# ─── T_adv_runs_cleanly_under_bash ──────────────────────────────────
# Acceptance Criterion #2: a well-formed init.sh with `:` placeholder gates
# must execute cleanly under `bash $init_path` (exit 0). Pins the documented
# shape against "shape is valid but file errors at run-time".
INIT="$FIXTURE_DIR/t-runs.sh"
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
chmod +x "$INIT"
rc=0; validate_init_sh "$INIT" >/dev/null 2>&1 || rc=$?
if (( rc != 0 )); then
  fail_at "T_adv_runs_cleanly_under_bash (precondition)" "validate_init_sh failed rc=$rc on fixture"
else
  rc=0; bash "$INIT" >/dev/null 2>&1 || rc=$?
  (( rc == 0 )) \
    && pass_at "T_adv_runs_cleanly_under_bash: \`bash \$init_path\` exits 0 (AC #2)" \
    || fail_at "T_adv_runs_cleanly_under_bash" "expected rc=0 from bash \$init_path, got rc=$rc"
fi

printf '\ninit-sh-validator-adversarial-test: passed=%d failed=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
