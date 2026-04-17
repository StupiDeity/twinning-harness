#!/usr/bin/env bash
# Extract a stage's prompt from AGENT_PROMPTS.md and interpolate tokens.
# Usage: render-prompt.sh <stage> <issue_id>
#   stage: brainstorm | plan | implement | ui | review | qa | build | release | retrospective
# Reads Linear issue via linear.sh get-issue.
# Emits rendered prompt text to stdout.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

STAGE_TO_SECTION='
brainstorm=1. Brainstorm Agent
plan=2. Plan Agent
implement=3. Implementation Agent (Backend)
ui=4. UI Agent (Frontend)
review=5. Review Agent
qa=6. QA Agent
build=7. Build Agent
release=8. Release Agent
retrospective=9. Retrospective Agent (Scheduled)
'

lookup_section() {
  local stage="$1"
  grep -E "^${stage}=" <<<"$STAGE_TO_SECTION" | head -1 | cut -d= -f2-
}

slugify() {
  tr '[:upper:]' '[:lower:]' <<<"$1" \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

# Extract the fenced ``` block that follows a "## N. <Name>" header.
extract_block() {
  local section="$1" prompts="$PIPELINE_ROOT/AGENT_PROMPTS.md"
  awk -v section="$section" '
    BEGIN { in_section=0; in_block=0; fence_count=0 }
    /^## / {
      if (in_section) { exit }
      # Strip "## " prefix and compare.
      line = $0
      sub(/^## /, "", line)
      if (line == section) { in_section=1 }
    }
    in_section && /^```/ {
      fence_count++
      if (fence_count == 1) { in_block=1; next }
      if (fence_count == 2) { exit }
    }
    in_section && in_block { print }
  ' "$prompts"
}

find_doc() {
  # Best-effort: find a file in the given dir whose name contains the issue id
  # (case-insensitive) or the slug. Prints the relative path or "".
  local dir="$1" issue_id="$2" slug="$3"
  if [[ ! -d "$dir" ]]; then printf ''; return; fi
  local match
  match="$(find "$dir" -maxdepth 1 -type f -iname "*${issue_id}*.md" 2>/dev/null | head -1)"
  if [[ -z "$match" && -n "$slug" ]]; then
    match="$(find "$dir" -maxdepth 1 -type f -iname "*${slug}*.md" 2>/dev/null | head -1)"
  fi
  if [[ -n "$match" ]]; then
    printf '%s' "${match#"$REPO_ROOT/"}"
  else
    printf ''
  fi
}

main() {
  local stage="${1:-}" issue_id="${2:-}"
  [[ -n "$stage" && -n "$issue_id" ]] || die "usage: render-prompt.sh <stage> <issue_id>"

  local section
  section="$(lookup_section "$stage")"
  [[ -n "$section" ]] || die "no prompt section for stage: $stage"

  local block
  block="$(extract_block "$section")"
  [[ -n "$block" ]] || die "could not extract block for section: $section"

  # Fetch issue metadata.
  local issue_json title description date slug
  issue_json="$(bash "$SCRIPT_DIR/linear.sh" get-issue "$issue_id" 2>/dev/null)"
  title="$(jq -r '.data.issue.title // ""' <<<"$issue_json")"
  description="$(jq -r '.data.issue.description // ""' <<<"$issue_json")"
  date="$(date -u +%Y-%m-%d)"
  slug="$(slugify "$title")"

  local brainstorm_file plan_file
  brainstorm_file="$(find_doc "$REPO_ROOT/docs/brainstorms" "$issue_id" "$slug")"
  plan_file="$(find_doc "$REPO_ROOT/docs/plans" "$issue_id" "$slug")"

  # Interpolate. Using python for safe substitution (handles multiline description).
  # Falls back to sed if python unavailable.
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$block" "$issue_id" "$title" "$description" "$date" "$slug" "$brainstorm_file" "$plan_file" <<'PY'
import sys
tmpl, issue_id, title, description, date, slug, brainstorm_file, plan_file = sys.argv[1:]
out = tmpl
repl = {
  "{issue_id}": issue_id,
  "{issue_title}": title,
  "{issue_description}": description,
  "{date}": date,
  "{slug}": slug,
  "{brainstorm_file}": brainstorm_file,
  "{plan_file}": plan_file,
}
for k, v in repl.items():
  out = out.replace(k, v)
sys.stdout.write(out)
PY
  else
    printf '%s' "$block" \
      | sed \
        -e "s|{issue_id}|$issue_id|g" \
        -e "s|{date}|$date|g" \
        -e "s|{slug}|$slug|g" \
        -e "s|{brainstorm_file}|$brainstorm_file|g" \
        -e "s|{plan_file}|$plan_file|g"
    # title and description may contain sed metacharacters — fall back users: install python3.
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
