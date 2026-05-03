#!/usr/bin/env bash
# Verify the implement/ui agent's diff against the plan's File Structure section.
# Usage:
#   scope-check.sh <issue_id> <branch>              — run the scope check
#   scope-check.sh has-scope-approval <issue_id>    — exit 0 iff the issue has a
#       <!-- pipeline-decision: scope-approved --> comment newer than its most
#       recent <!-- pipeline-halt: scope-deviation --> comment (ENG-18).
# Exit 0: all changed files are in plan scope (or only benign escapes).
# Exit 1: one or more files out of plan scope at the NOTABLE tier (list printed to stdout).
# Exit 2: plan not found, or File Structure unparseable.
# Exit 3: one or more files out of plan scope at the SEVERE tier (list printed to stdout).
#
# Tiers (applied to files NOT matching the plan's allowed files/dirs):
#   - BENIGN (silently allowed, counted toward exit 0):
#       * `.pipeline/metrics/**`   — orchestrator-owned telemetry
#       * `Cargo.lock`              — lockfile churn from in-scope dep edits
#       * `docs/knowledge/**`       — learned-rules / knowledge-doc updates
#       * `docs/plans/**`           — plan docs (cannot self-reference pre-creation)
#       * `docs/brainstorms/**`     — brainstorm docs (authored before the plan)
#       * `crates/<name>/tests/**`  — integration tests under an in-scope crate
#   - NOTABLE: top-level path segment (e.g. `crates`, `src-tauri`, `src`) matches
#     the top segment of SOME allowed path. "Adjacent to declared scope."
#   - SEVERE: file is unrelated to any declared scope.
#
# Output on stdout (when tiers fire): one line per file, prefixed by `<tier>\t`.
#
# Parsing rule (best-effort, tolerant):
#   - Locate the plan doc canonically by `linear: <ID>` frontmatter.
#   - Extract the body between the first `## File Structure` (or `### File Structure`)
#     heading and the next heading of the same-or-shallower depth.
#   - Collect (a) file-path tokens (contain `/` + a `.<ext>`) and (b) directory-prefix
#     tokens (ending in `/`). Both are normalised to repo-relative paths.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ENG-41 T3: scope-check lane — all Linear writes from this script are in
# the scope-check lane, which is allowed to add/remove pipeline:skip-until-*
# labels but not stage:* or pipeline:halted labels.
export PIPELINE_WRITER=scope-check

find_canonical_plan() {
  local issue_id="$1" root="$2" f
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
  done < <(find "$root/docs/plans" -maxdepth 1 -type f -name '*.md' -print0)
  return 1
}

extract_scope_section() {
  local plan="$1"
  awk '
    /^(##|###)[[:space:]]+[Ff]ile [Ss]tructure/ { depth=length($1); in_fs=1; next }
    in_fs && /^(##|###)[[:space:]]/ {
      this=length($1)
      if (this <= depth) { in_fs=0; next }
    }
    in_fs { print }
  ' "$plan"
}

# Does $1 look benign regardless of plan?
is_benign() {
  local f="$1"
  case "$f" in
    .pipeline/metrics/*) return 0 ;;
    Cargo.lock)          return 0 ;;
    docs/knowledge/*)    return 0 ;;
    docs/plans/*)        return 0 ;;
    docs/brainstorms/*)  return 0 ;;
  esac
  # Integration tests under an in-scope crate.
  # Requires $allowed_files / $allowed_dirs from main scope.
  if [[ "$f" =~ ^(crates/[^/]+)/tests/ ]]; then
    local crate_dir="${BASH_REMATCH[1]}"
    if grep -qE "^${crate_dir}/" <<<"$allowed_files$allowed_dirs" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# Does $1 share its top-level path segment with any allowed token?
is_notable() {
  local f="$1"
  local top="${f%%/*}"
  [[ -z "$top" || "$top" == "$f" ]] && return 1
  grep -qE "^${top}/" <<<"$allowed_files$allowed_dirs" 2>/dev/null
}

# Returns 0 iff there is a scope-approval decision newer than the most recent
# scope-related halt on the issue. Recognizes both old and new marker shapes
# via parse_pipeline_marker. If no scope-related halt exists, returns 1 (no
# pending decision to match — caller re-runs the normal scope check).
has_scope_approval() {
  local issue="$1"
  [[ -n "$issue" ]] || die "has-scope-approval: issue id required"
  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue")"
  [[ -z "$comments" || "$comments" == "null" ]] && return 1

  # Find latest scope-related halt. After T3.1 removed the old-shape
  # parser branch, only canonical scope-violation reaches here (old-shape
  # no longer parses, and new-shape writers use the registry which
  # canonicalizes to scope-violation). The defensive scope-deviation
  # acceptance was a Phase 2 carryover; it is dead code now.
  local last_halt_ts=""
  local ts body ev reason
  while IFS=$'\t' read -r ts body; do
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
    [[ "$(jq -r '.result' <<<"$ev")" != "halt" ]] && continue
    reason="$(jq -r '.reason' <<<"$ev")"
    [[ "$reason" == "scope-violation" ]] || continue
    [[ "$ts" > "$last_halt_ts" ]] && last_halt_ts="$ts"
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")
  [[ -z "$last_halt_ts" ]] && return 1

  # Find the latest decision approve gate=scope newer than that halt.
  local approved_ts=""
  while IFS=$'\t' read -r ts body; do
    [[ ! "$ts" > "$last_halt_ts" ]] && continue
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    [[ "$(jq -r '.event' <<<"$ev")" != "decision" ]] && continue
    [[ "$(jq -r '.action' <<<"$ev")" != "approve" ]] && continue
    [[ "$(jq -r '.gate // ""' <<<"$ev")" != "scope" ]] && continue
    [[ "$ts" > "$approved_ts" ]] && approved_ts="$ts"
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  [[ -n "$approved_ts" ]]
}

main() {
  local issue_id="${1:-}" branch="${2:-}"
  [[ -n "$issue_id" && -n "$branch" ]] || die "usage: scope-check.sh <issue_id> <branch>"

  # In the worktree flow, run-stage.sh invokes scope-check with cwd inside the
  # per-issue worktree, where the plan has been committed on the feature branch
  # but not merged to main. Resolve plans from that worktree, not from the shared
  # $TARGET_REPO (which points at main via SCRIPT_DIR/../..).
  local worktree_root
  worktree_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$TARGET_REPO")"

  local plan
  plan="$(find_canonical_plan "$issue_id" "$worktree_root")" \
    || { log "scope-check: no canonical plan for $issue_id"; exit 2; }
  log "scope-check: plan=${plan#"$worktree_root/"} branch=$branch"

  local body
  body="$(extract_scope_section "$plan")"
  [[ -n "$body" ]] || { log "scope-check: File Structure section empty/missing"; exit 2; }

  local allowed_files allowed_dirs
  # ENG-25: `*` (not `+`) on the directory-prefix group so repo-root files
  # (CLAUDE.md, README.md, package.json, …) declared in the plan's File Structure
  # are parsed into allowed_files. With `+`, zero-prefix tokens like `CLAUDE.md`
  # never matched and were always SEVERE-flagged.
  #
  # The trailing `|| true` on each pipeline guards against grep-no-match (rc=1)
  # under `set -o pipefail` from aborting the whole script. Plans that declare
  # only repo-root files (no nested paths) produce no allowed_dirs matches; the
  # explicit empty check below handles the empty-allowed-set case.
  allowed_files="$(grep -oE '([a-zA-Z0-9_./-]+/)*[a-zA-Z0-9_.-]+\.[a-zA-Z0-9]+' <<<"$body" | sort -u || true)"
  # Anchored-base awk filter: drop only `<basename>.<ext>/` malformed captures
  # (e.g., `secret-probe-lint.yml/`), NOT `.<name>/` dotfile dirs (e.g.,
  # `.github/`). The earlier `\.[a-zA-Z0-9]+\/$` pattern over-matched and
  # stripped legitimate dotfile directories — first hit by ENG-46's plan
  # introducing `.github/workflows/`.
  allowed_dirs="$(grep -oE '([a-zA-Z0-9_.-]+/){1,}' <<<"$body" \
    | awk '!/^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*\.[a-zA-Z0-9]+\/$/' | sort -u || true)"

  if [[ -z "$allowed_files$allowed_dirs" ]]; then
    log "scope-check: no file or directory tokens parsed from File Structure"
    exit 2
  fi

  local changed
  changed="$(git -C "$worktree_root" diff --name-only "main...${branch}" 2>/dev/null || true)"
  [[ -n "$changed" ]] || { log "scope-check: no file changes on $branch"; exit 0; }

  local notable="" severe="" benign_count=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ -n "$allowed_files" ]] && grep -qxF "$f" <<<"$allowed_files"; then
      continue
    fi
    local in_dir=0 d
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      [[ "$f" == "$d"* ]] && { in_dir=1; break; }
    done <<<"$allowed_dirs"
    (( in_dir )) && continue

    if is_benign "$f"; then
      benign_count=$((benign_count + 1))
      log "scope-check: benign escape: $f"
      continue
    fi
    if is_notable "$f"; then
      notable+="notable	$f"$'\n'
    else
      severe+="severe	$f"$'\n'
    fi
  done <<<"$changed"

  if [[ -n "$severe" ]]; then
    log "scope-check: SEVERE out-of-scope files on $branch:"
    printf '%s' "$severe"
    [[ -n "$notable" ]] && printf '%s' "$notable"
    exit 3
  fi

  if [[ -n "$notable" ]]; then
    log "scope-check: NOTABLE out-of-scope files on $branch (awaiting approval):"
    printf '%s' "$notable"
    exit 1
  fi

  log "scope-check: pass (benign_escapes=$benign_count)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    has-scope-approval)
      shift
      has_scope_approval "$@"
      ;;
    *)
      main "$@"
      ;;
  esac
fi
