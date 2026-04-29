#!/usr/bin/env bash
# bin/secret-probe-lint.sh — ENG-46 forward-looking guard against the
# `${SECRET:-FALLBACK}` / `${SECRET:+ALT}` env-probe anti-pattern.
#
# This script does NOT source common.sh. It must run in CI without
# TARGET_REPO and without config.json (D-007 rationale): it operates on
# the harness repo itself via plain `git grep`, with no harness-specific
# state.
#
# See:
# - docs/brainstorms/2026-04-28-agent-env-probe-pattern-secret-unset-leaks-key-values-into-agent-context-design.md (D-001)
# - AGENT_PROMPTS.md "Secret-handling preamble (ENG-46)"
#
# Exit codes:
#   0  — zero hits across both regexes (clean)
#   1  — one or more hits (lint fail)
#   2  — environment failure (e.g. invoked outside a git checkout)

set -euo pipefail

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf 'lint requires a git checkout\n' >&2
  exit 2
fi

EXCLUDE=(
  ':!bin/secret-probe-lint.sh'
  ':!bin/secret-probe-lint-test.sh'
  ':!bin/secret-probe-lint-adversarial-test.sh'
  ':!AGENT_PROMPTS.md'
  ':!docs/**'
  ':!learned-rules/**'
)

# Strict superset of the AC1/AC2 regexes — covers both `:-` and `:+`
# halves (security-iter-2 finding S-P0). Single source of truth: any
# change here must be mirrored in AGENT_PROMPTS.md "Secret-handling
# preamble (ENG-46)".
PAT_KTS='\$\{[A-Z_]*(KEY|TOKEN|SECRET)[A-Z_]*:[\+\-]'
PAT_PROVIDER='\$\{(ANTHROPIC|GITHUB|LINEAR)[A-Z_]*:[\+\-]'

# `git grep` exits 1 on no-match, 0 on match — invert the convention.
collect_hits() {
  local pat="$1"
  local out
  set +e
  out="$(git grep -nE "$pat" -- "${EXCLUDE[@]}")"
  set -e
  printf '%s' "$out"
}

hits_kts="$(collect_hits "$PAT_KTS")"
hits_provider="$(collect_hits "$PAT_PROVIDER")"

# Union the two streams; sort -u so the same line matched by both
# regexes (common — most hits will satisfy both) is reported once.
all_hits=""
[[ -n "$hits_kts"      ]] && all_hits+="$hits_kts"$'\n'
[[ -n "$hits_provider" ]] && all_hits+="$hits_provider"$'\n'
all_hits="${all_hits%$'\n'}"

if [[ -z "$all_hits" ]]; then
  exit 0
fi

# Print three lines per hit per D-001:
#   <path:line:matched-text>
#     hint: …
#     see:  AGENT_PROMPTS.md "Secret-handling preamble (ENG-46)"
printf '%s\n' "$all_hits" | LC_ALL=C sort -u | while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  printf '%s\n' "$hit"
  printf '  hint: use ${VAR-} (single-dash, no fallback string) for presence-only checks\n'
  printf '  see:  AGENT_PROMPTS.md "Secret-handling preamble (ENG-46)"\n'
done

exit 1
