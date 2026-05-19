#!/usr/bin/env bash
# Scan a feature branch for `Gotcha-hit:` commit trailers and bump the
# `gotcha_triggered` counter on the associated Linear issue once per distinct gotcha ID.
# Usage: scan-gotcha-trailers.sh <issue_id> <branch>
# Exit 0 on success (no output on zero hits, list printed on non-zero).
#
# Rationale: implement/ui agents add `Gotcha-hit: G-<id>` trailers when they touch
# documented gotchas. Retrospective reads the aggregate trailer history; guards.sh
# reads a per-issue counter. This script is the bridge: it scans the branch's
# feature-local commits (branch vs main) and bumps the counter per distinct gotcha ID.
# Same gotcha ID hit multiple times in the same feature = 1 bump (we care about
# "how many documented gotchas did this feature trip", not trailer volume).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

main() {
  local issue_id="${1:-}" branch="${2:-}"
  [[ -n "$issue_id" && -n "$branch" ]] || die "usage: scan-gotcha-trailers.sh <issue_id> <branch>"

  # Extract distinct Gotcha-hit IDs from commit messages on the branch (since main).
  local hits
  hits="$(git -C "$TARGET_REPO" log --pretty=%B "main..${branch}" 2>/dev/null \
    | awk -F'[: ]+' 'tolower($1)=="gotcha-hit" { print $2 }' \
    | sort -u || true)"

  if [[ -z "$hits" ]]; then
    log "scan-gotcha-trailers: no Gotcha-hit trailers on $branch"
    return 0
  fi

  local count=0
  while IFS= read -r gid; do
    [[ -z "$gid" ]] && continue
    log "scan-gotcha-trailers: bumping gotcha_triggered on $issue_id (gotcha=$gid)"
    bash "$SCRIPT_DIR/guards.sh" bump "$issue_id" gotcha_triggered \
      --reason "Gotcha-hit: $gid trailer found on commit on $branch" \
      --reason-code gotcha-hit
    count=$((count + 1))
  done <<<"$hits"

  log "scan-gotcha-trailers: bumped $count distinct gotcha(s) for $issue_id"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
