#!/usr/bin/env bash
# bin/plan-scope.sh — shared plan-structural in-plan-scope matcher (ENG-194).
#
# Five `plan_scope::*` functions extracted from bin/scope-check.sh, sourced
# by both bin/scope-check.sh (scope-violation gate) and
# bin/render-prompt.sh (the {plan_scope_allowed_paths} resolver feeding §5
# Plan-scope adjudication). Sharing the matcher byte-for-byte is the
# structural defense against the reviewer/scope-check classifying the same
# path differently (ENG-194 D-001).
#
# STRICTLY plan-structural: this helper does NOT consult benign-path
# classes, stack-conditional lockfiles, or the Rust crates-tests
# carve-out. Those live in bin/scope-check.sh::is_benign and are
# correctly excluded from reviewer adjudication (ENG-194 brainstorm §6
# Edge case 8 / ENG-194-B follow-up).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

plan_scope::find_plan() {
  local issue_id="$1" root="$2" f
  [[ -d "$root/docs/plans" ]] || return 1
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

plan_scope::extract_section() {
  local plan="$1"
  awk '
    /^(##|###)[[:space:]]+([0-9]+\.[[:space:]]+)?[Ff]ile [Ss]tructure/ {
      depth=length($1); in_fs=1; next
    }
    in_fs && /^(##|###)[[:space:]]/ {
      this=length($1)
      if (this <= depth) { in_fs=0; next }
    }
    in_fs { print }
  ' "$plan"
}

# LC_ALL=C pins the sort collation so both callers (scope-check.sh and
# render-prompt.sh's resolver) emit byte-identical ordering regardless of
# the dispatch host's LANG/LC_COLLATE. Without it a UTF-8 locale collates
# case-insensitively (CLAUDE.md sorts among lowercase tokens) while C-locale
# orders uppercase first — the exact byte-for-byte divergence ENG-194 D-001
# forbids, and what plan-scope-test.sh T1 asserts against.
plan_scope::parse_allowed_files() {
  local body="$1"
  grep -oE '([a-zA-Z0-9_./-]+/)*[a-zA-Z0-9_.-]+\.[a-zA-Z0-9]+' <<<"$body" | LC_ALL=C sort -u || true
}

plan_scope::parse_allowed_dirs() {
  local body="$1"
  grep -oE '([a-zA-Z0-9_.-]+/){1,}' <<<"$body" \
    | awk '!/^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*\.[a-zA-Z0-9]+\/$/' | LC_ALL=C sort -u || true
}

plan_scope::path_in_scope() {
  local f="$1" allowed_files="$2" allowed_dirs="$3"
  if [[ -n "$allowed_files" ]] && grep -qxF "$f" <<<"$allowed_files"; then
    return 0
  fi
  local d
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    [[ "$f" == "$d"* ]] && return 0
  done <<<"$allowed_dirs"
  return 1
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    find-plan)            plan_scope::find_plan "$@" ;;
    extract-section)      plan_scope::extract_section "$@" ;;
    parse-allowed-files)  plan_scope::parse_allowed_files "$@" ;;
    parse-allowed-dirs)   plan_scope::parse_allowed_dirs "$@" ;;
    path-in-scope)        plan_scope::path_in_scope "$@" ;;
    "")                   die "plan-scope: subcommand required (find-plan|extract-section|parse-allowed-files|parse-allowed-dirs|path-in-scope)" ;;
    *)                    die "plan-scope: unknown subcommand '$sub'" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
