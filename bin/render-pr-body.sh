#!/usr/bin/env bash
# ENG-49 Gap #1: render-pr-body — assemble a canonical PR body from
# brainstorm doc Overview, plan doc Failure Mode → Test Map, and Linear
# stage-summary comments. Source-able; sentinel-guarded for testing.
#
# Usage:
#   render_pr_body <issue> <branch>   # prints body markdown to stdout

set -euo pipefail
# ENG-53 #7: ${BASH_SOURCE[0]:-$0} so this script is robust when sourced
# from contexts where BASH_SOURCE[0] is unset (e.g., `bash -c '... source
# render-pr-body.sh ...'` from an operator subshell). Without the
# fallback, `set -u` panics with `BASH_SOURCE[0]: parameter not set`,
# `dirname` gets garbage, and the subsequent `source common.sh` fails
# with "no such file or directory" pointing at HARNESS_ROOT instead of
# bin/. Fall back to PATH search if both BASH_SOURCE[0] and $0 fail to
# resolve to the script's actual directory.
_RPB_SOURCE_PATH="${BASH_SOURCE[0]:-${0:-}}"
if [[ -n "$_RPB_SOURCE_PATH" && -f "$_RPB_SOURCE_PATH" ]]; then
  _RPB_SCRIPT_DIR="$(cd "$(dirname "$_RPB_SOURCE_PATH")" && pwd)"
else
  _RPB_SCRIPT_DIR="$(dirname "$(command -v render-pr-body.sh 2>/dev/null || true)" 2>/dev/null || true)"
fi
[[ -n "$_RPB_SCRIPT_DIR" && -f "$_RPB_SCRIPT_DIR/common.sh" ]] \
  || { printf 'render-pr-body.sh: cannot resolve own directory (BASH_SOURCE empty, $0=%s)\n' "${0:-}" >&2; return 1 2>/dev/null || exit 1; }
# shellcheck source=common.sh
source "$_RPB_SCRIPT_DIR/common.sh"

# Default linear.sh path, override in tests.
_RPB_LINEAR_SH="${_RPB_LINEAR_SH:-$_RPB_SCRIPT_DIR/linear.sh}"

# Resolve the brainstorm doc whose YAML frontmatter `linear: <issue>` matches.
# Returns the doc path on stdout, or "" if not found.
_rpb_find_doc() {
  local issue="$1" subdir="$2"
  local dir="$TARGET_REPO/docs/$subdir"
  [[ -d "$dir" ]] || { printf ''; return 0; }
  local f
  for f in "$dir"/*.md; do
    [[ -f "$f" ]] || continue
    head -20 "$f" | grep -qE "^linear:[[:space:]]+${issue}[[:space:]]*$" && { printf '%s' "$f"; return 0; }
  done
  printf ''
}

# Extract the body of an H2 section by name. Stops at the next H2 or EOF.
_rpb_section_body() {
  local file="$1" heading="$2"
  [[ -f "$file" ]] || { printf ''; return 0; }
  awk -v h="$heading" '
    BEGIN{in_section=0}
    /^## /{ if (in_section) exit; if ($0 == h) {in_section=1; next} }
    in_section{print}
  ' "$file"
}

# Extract bullet lines (leading -) from a section's body, up to N items.
_rpb_bullets() {
  local body="$1" max="${2:-3}" n=0 line
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
      printf '%s\n' "$line"
      n=$((n+1))
      (( n >= max )) && return 0
    fi
  done <<<"$body"
}

# Pull the most recent stage-summary comment for a given stage from
# the issue's comment stream.
_rpb_stage_summary() {
  local issue="$1" stage="$2" comments
  comments="$(bash "$_RPB_LINEAR_SH" get-comments "$issue" 2>/dev/null || printf '[]')"
  [[ -z "$comments" || "$comments" == "null" ]] && { printf ''; return 0; }
  jq -r --arg stage "$stage" '
    [.[] | select(.body | contains("**" + $stage + " summary**"))]
    | sort_by(.createdAt) | last | (.body // "")' <<<"$comments"
}

# Extract the TL;DR line from a stage-summary comment body.
_rpb_tldr() {
  local body="$1"
  printf '%s\n' "$body" | awk '
    /\*\*TL;DR\*\*/{
      sub(/^.*\*\*TL;DR\*\*[[:space:]]*/, "")
      print; exit
    }'
}

# Resolve the PR title type from the Linear issue's labels.
# Bug → fix; Feature/Improvement → feat; default → fix.
_rpb_title_type() {
  local issue="$1" labels_json
  labels_json="$(bash "$_RPB_LINEAR_SH" get-issue "$issue" 2>/dev/null \
    | jq -r '.data.issue.labels.nodes[].name' 2>/dev/null || true)"
  if grep -qiE 'feature|improvement' <<<"$labels_json"; then printf 'feat'
  else printf 'fix'
  fi
}

# Resolve the Linear issue title.
_rpb_title() {
  local issue="$1"
  bash "$_RPB_LINEAR_SH" get-issue "$issue" 2>/dev/null \
    | jq -r '.data.issue.title // empty' 2>/dev/null || true
}

render_pr_body() {
  local issue="$1" branch="$2"
  [[ -n "$issue" && -n "$branch" ]] || die "render_pr_body: usage <issue> <branch>"

  local title b_doc p_doc
  title="$(_rpb_title "$issue")"
  [[ -z "$title" ]] && title="$issue"
  b_doc="$(_rpb_find_doc "$issue" brainstorms)"
  p_doc="$(_rpb_find_doc "$issue" plans)"

  # ── Summary ──
  local summary_body summary_bullets
  summary_body="$(_rpb_section_body "$b_doc" "## Overview")"
  summary_bullets="$(_rpb_bullets "$summary_body" 3)"
  if [[ -z "$summary_bullets" ]]; then
    summary_bullets="- $title"
  fi

  # ── Changes ──
  local impl_summary ui_summary impl_tldr ui_tldr
  impl_summary="$(_rpb_stage_summary "$issue" "implementing")"
  ui_summary="$(_rpb_stage_summary "$issue" "ui")"
  impl_tldr="$(_rpb_tldr "$impl_summary")"
  ui_tldr="$(_rpb_tldr "$ui_summary")"
  [[ -z "$impl_tldr" ]] && impl_tldr="see commit log"
  [[ -z "$ui_tldr" ]]   && ui_tldr="pass-through (no-op)"

  # ── Test plan ──
  local plan_body test_map_bullets
  plan_body="$(_rpb_section_body "$p_doc" "## Failure Mode → Test Map")"
  test_map_bullets="$(_rpb_bullets "$plan_body" 5)"
  [[ -z "$test_map_bullets" ]] && test_map_bullets="- Every gate from the Project profile's \"Build & test gates\" section"

  # ── Render ──
  cat <<MD
## Summary
${summary_bullets}

## Linear
- ${issue} — ${title}

## Changes
- Backend: ${impl_tldr}
- Frontend: ${ui_tldr}

## Test plan
${test_map_bullets}

## Screenshots
N/A — added by review if user-visible changes

## Notes
See stage-summary comments on Linear ${issue} for deviations.
MD
}

export -f render_pr_body

# Sentinel — runnable for ad-hoc rendering. ENG-53 #7: guard
# BASH_SOURCE[0] under set -u; default to empty so a no-BASH_SOURCE
# context (e.g., `bash -c '... source render-pr-body.sh ...'`) does not
# fire main when the file is being sourced.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  [[ $# -eq 2 ]] || die "usage: render-pr-body.sh <issue> <branch>"
  render_pr_body "$1" "$2"
fi
