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
# Install cleanup trap BEFORE sourcing — if dispatch.sh sourcing dies
# (e.g. common.sh missing) we still want FIXTURE_DIR removed.
trap 'rm -rf "$FIXTURE_DIR"' EXIT
export TARGET_REPO="$FIXTURE_DIR/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
printf '{"project":{"slug":"test-slug"}}\n' > "$TARGET_REPO/.pipeline-config/config.json"

# shellcheck source=dispatch.sh
source "$SCRIPT_DIR/dispatch.sh"

printf '\n--- init-sh-validator-adversarial-test: ENG-125 ---\n'

# ─── T_adv_marker_in_double_quoted_argument ─────────────────────────
# The literal file line is `echo "# ─── smoke ───"` which begins with `e`,
# so the `^#` anchor in validate_init_sh's grep rejects it. Renamed from
# T_adv_hijack_marker_in_quoted_string ([nit]): the original name overstated
# what the test exercised — quoted-string semantics are not relevant here;
# the column-0 `^` anchor alone is the load-bearing matcher rejection. The
# heredoc-body-at-column-0 case below pins the truly-quoted-string semantics.
INIT="$FIXTURE_DIR/t-double-quoted-arg.sh"
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
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 40 )) \
   && [[ "$out" == *"init-sh-incomplete: missing shape marker"* && "$out" == *"# ─── smoke ───"* ]]; then
  pass_at "T_adv_marker_in_double_quoted_argument: \`echo \"# ─── smoke ───\"\` (line starts with 'e') → rc=40 (^# anchor rejects)"
else
  fail_at "T_adv_marker_in_double_quoted_argument" "rc=$rc out='$out'"
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
if (( rc == 40 )) \
   && [[ "$out" == *"init-sh-incomplete: missing shape marker"* && "$out" == *"# ─── smoke ───"* ]]; then
  pass_at "T_adv_marker_with_trailing_whitespace: trailing spaces → rc=40 (\$-anchor pinned)"
else
  fail_at "T_adv_marker_with_trailing_whitespace" "rc=$rc out='$out'"
fi

# ─── T_adv_zero_byte_file ───────────────────────────────────────────
# Empty init.sh → bash -n is clean on empty input; ALL four markers are
# missing; detective returns rc=40 with the collect-all-missing diagnostic.
INIT="$FIXTURE_DIR/t-empty.sh"
: > "$INIT"
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 40 )) \
   && [[ "$out" == *"init-sh-incomplete: missing shape marker"* && "$out" == *"# ─── smoke ───"* ]]; then
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
if (( rc == 40 )) \
   && [[ "$out" == *"init-sh-incomplete: missing shape marker"* && "$out" == *"# ─── smoke ───"* ]]; then
  pass_at "T_adv_marker_inside_comment_block: heredoc-indented marker → rc=40 (column-0 anchor pinned)"
else
  fail_at "T_adv_marker_inside_comment_block" "rc=$rc out='$out'"
fi

# ─── T_adv_marker_in_heredoc_body_at_col0 ───────────────────────────
# Documented limitation: a `cat <<COMMENT` body line written at column 0 with
# a marker glyph (e.g. `# ─── smoke ───`) WOULD match validate_init_sh's grep
# anchor because grep operates on file content, not on bash's parse tree. Bash
# treats the line as heredoc body, but the validator treats it as a real
# marker — they disagree, and we choose the lossy-but-cheap path: shape match
# via grep is sufficient. The Failure Mode → Test Map row "Marker hijack
# inside quoted string" promises that an embedded `# ─── smoke ───` in a
# heredoc body is treated as ABSENT — but only when the heredoc body line is
# INDENTED (T_adv_marker_inside_comment_block above). At column 0, the
# validator can't distinguish heredoc-body from real source line. Pin the
# behavior so a future reader doesn't mistakenly assume otherwise.
INIT="$FIXTURE_DIR/t-heredoc-col0.sh"
cat > "$INIT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<COMMENT
# ─── smoke ───
COMMENT
# ─── typecheck ───
:
# ─── lint ───
:
# ─── test ───
:
EOF
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 0 )); then
  pass_at "T_adv_marker_in_heredoc_body_at_col0: col-0 marker in heredoc body counts as present (documented limitation; grep operates pre-parse)"
else
  fail_at "T_adv_marker_in_heredoc_body_at_col0" "rc=$rc out='$out' (expected rc=0 — documented limitation)"
fi

# ─── T_adv_crlf_line_endings ────────────────────────────────────────
# CRLF line endings (e.g. `# ─── smoke ───\r\n`) must NOT fail the column-0
# matcher with a misleading "missing shape marker" diagnostic. The `$`-anchor
# would historically reject `…─\r`, even though the marker IS present
# byte-for-byte. The validator pre-normalises CR before matching, so a CRLF
# init.sh validates as well-formed regardless of authoring editor.
INIT="$FIXTURE_DIR/t-crlf.sh"
{
  printf '%s\r\n' '#!/usr/bin/env bash'
  printf '%s\r\n' 'set -euo pipefail'
  printf '%s\r\n' '# ─── smoke ───'
  printf '%s\r\n' ':'
  printf '%s\r\n' '# ─── typecheck ───'
  printf '%s\r\n' ':'
  printf '%s\r\n' '# ─── lint ───'
  printf '%s\r\n' ':'
  printf '%s\r\n' '# ─── test ───'
  printf '%s\r\n' ':'
} > "$INIT"
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
(( rc == 0 )) \
  && pass_at "T_adv_crlf_line_endings: CRLF endings → rc=0 (CR pre-normalised)" \
  || fail_at "T_adv_crlf_line_endings" "rc=$rc out='$out'"

# ─── T_adv_collect_all_missing ──────────────────────────────────────
# An init.sh missing multiple markers should produce a single diagnostic
# naming EVERY missing marker, not just the first. Pre-fix, the validator
# short-circuited on the first missing gate; each plan dispatch wasted a
# ~5-10 minute cycle iterating one marker at a time. Post-fix, the
# diagnostic enumerates all four when all four are absent.
INIT="$FIXTURE_DIR/t-all-missing.sh"
cat > "$INIT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
:
EOF
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 40 )) \
   && [[ "$out" == *"# ─── smoke ───"* ]] \
   && [[ "$out" == *"# ─── typecheck ───"* ]] \
   && [[ "$out" == *"# ─── lint ───"* ]] \
   && [[ "$out" == *"# ─── test ───"* ]]; then
  pass_at "T_adv_collect_all_missing: all four markers absent → rc=40 + diagnostic names every missing marker"
else
  fail_at "T_adv_collect_all_missing" "rc=$rc out='$out'"
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

# ─── T_adv_ascii_em_dash ────────────────────────────────────────────
# An LLM plan agent may emit `# --- smoke ---` (three ASCII hyphens) instead
# of `# ─── smoke ───` (three U+2500 BOX DRAWINGS LIGHT HORIZONTAL glyphs).
# The two render almost identically in many fonts but are different bytes
# entirely. The matcher's `^# ─── <gate> ───$` regex requires the unicode
# triple-dash on both sides; the ASCII form must be treated as ABSENT → rc=40.
# Most likely real-world emission failure for this contract.
INIT="$FIXTURE_DIR/t-ascii-em-dash.sh"
cat > "$INIT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# --- smoke ---
:
# --- typecheck ---
:
# --- lint ---
:
# --- test ---
:
EOF
rc=0; out="$(validate_init_sh "$INIT" 2>&1)" || rc=$?
if (( rc == 40 )) \
   && [[ "$out" == *"init-sh-incomplete: missing shape marker"* && "$out" == *"# ─── smoke ───"* ]]; then
  pass_at "T_adv_ascii_em_dash: ASCII '# --- smoke ---' → rc=40 (unicode box-drawing required)"
else
  fail_at "T_adv_ascii_em_dash" "rc=$rc out='$out'"
fi

printf '\ninit-sh-validator-adversarial-test: passed=%d failed=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
