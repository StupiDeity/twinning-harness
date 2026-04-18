#!/usr/bin/env bash
# Verify the implement/ui agent's diff against the plan's File Structure section.
# Usage: scope-check.sh <issue_id> <branch>
# Exit 0: all changed files are in plan scope (or there are no changes).
# Exit 1: one or more files out of plan scope (list printed to stdout).
# Exit 2: plan not found, or File Structure unparseable.
#
# Parsing rule (best-effort, tolerant):
#   - Locate the plan doc canonically by `linear: <ID>` frontmatter.
#   - Extract the body between the first `## File Structure` (or `### File Structure`)
#     heading and the next heading of the same-or-shallower depth.
#   - Collect (a) file-path tokens (contain `/` + a `.<ext>`) and (b) directory-prefix
#     tokens (ending in `/`). Both are normalised to repo-relative paths.
#   - A changed file is in-scope iff it equals any file token exactly OR falls under
#     any directory token.
#
# Rationale: plans declare scope as prose; a tolerant parser catches the 95% case
# (unrelated-crate edits) without forcing a structured schema. For the 5% where a
# plan needs to grant a broad scope, the plan lists the parent directory.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

find_canonical_plan() {
  local issue_id="$1" f
  while IFS= read -r -d '' f; do
    if awk -v id="$issue_id" '
      NR==1 && $0=="---" { in_fm=1; next }
      in_fm && $0=="---" { exit 1 }
      in_fm && $0 ~ "^linear:[[:space:]]+" id "[[:space:]]*$" { exit 0 }
      NR>20 { exit 1 }
    ' "$f"; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(find "$REPO_ROOT/docs/plans" -maxdepth 1 -type f -name '*.md' -print0)
  return 1
}

extract_scope_section() {
  local plan="$1"
  awk '
    /^(##|###)[[:space:]]+File Structure/ { depth=length($1); in_fs=1; next }
    in_fs && /^(##|###)[[:space:]]/ {
      this=length($1)
      if (this <= depth) { in_fs=0; next }
    }
    in_fs { print }
  ' "$plan"
}

main() {
  local issue_id="${1:-}" branch="${2:-}"
  [[ -n "$issue_id" && -n "$branch" ]] || die "usage: scope-check.sh <issue_id> <branch>"

  local plan
  plan="$(find_canonical_plan "$issue_id")" \
    || { log "scope-check: no canonical plan for $issue_id"; exit 2; }
  log "scope-check: plan=${plan#"$REPO_ROOT/"} branch=$branch"

  local body
  body="$(extract_scope_section "$plan")"
  [[ -n "$body" ]] || { log "scope-check: File Structure section empty/missing"; exit 2; }

  # Collect allowed tokens (files + directories), stripping `backticks`, commas, parens.
  local allowed_files allowed_dirs
  allowed_files="$(grep -oE '([a-zA-Z0-9_./-]+/)+[a-zA-Z0-9_.-]+\.[a-zA-Z0-9]+' <<<"$body" | sort -u)"
  allowed_dirs="$(grep -oE '([a-zA-Z0-9_.-]+/){1,}' <<<"$body" \
    | awk '!/\.[a-zA-Z0-9]+\/$/' | sort -u)"

  if [[ -z "$allowed_files$allowed_dirs" ]]; then
    log "scope-check: no file or directory tokens parsed from File Structure"
    exit 2
  fi

  # Diff the branch against main.
  local changed
  changed="$(git -C "$REPO_ROOT" diff --name-only "main...${branch}" 2>/dev/null || true)"
  [[ -n "$changed" ]] || { log "scope-check: no file changes on $branch"; exit 0; }

  local out_of_scope=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # Exact file match?
    if [[ -n "$allowed_files" ]] && grep -qxF "$f" <<<"$allowed_files"; then
      continue
    fi
    # Directory prefix match?
    local in_dir=0 d
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      [[ "$f" == "$d"* ]] && { in_dir=1; break; }
    done <<<"$allowed_dirs"
    (( in_dir )) && continue
    out_of_scope+="$f"$'\n'
  done <<<"$changed"

  if [[ -n "$out_of_scope" ]]; then
    log "scope-check: out-of-scope files on $branch:"
    printf '%s' "$out_of_scope"
    exit 1
  fi

  log "scope-check: all $(wc -l <<<"$changed" | tr -d ' ') changed files in plan scope"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
