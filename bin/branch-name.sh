#!/usr/bin/env bash
# Resolve the feature-branch name for a Linear issue.
# Usage: branch-name.sh <issue_id>
# Prints: feat/<issue-lower>-<slug> or fix/<issue-lower>-<slug>
#
# Prefix rule (per ENG-13 D-004):
#   - Linear label "Bug" → fix/
#   - Linear label "Feature" or "Improvement" or absent → feat/

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

main() {
  local ident="${1:-}"
  [[ -n "$ident" ]] || die "usage: branch-name.sh <issue_id>"

  local ident_lower title slug
  ident_lower="$(tr '[:upper:]' '[:lower:]' <<<"$ident")"
  title="$(bash "$SCRIPT_DIR/linear.sh" get-issue "$ident" | jq -r '.data.issue.title // empty')"
  [[ -n "$title" ]] || die "could not fetch title for $ident"

  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"

  local prefix="feat"
  if bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "Bug"; then
    prefix="fix"
  fi

  printf '%s/%s-%s\n' "$prefix" "$ident_lower" "$slug"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
