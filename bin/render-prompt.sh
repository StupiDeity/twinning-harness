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
# Schema invariant: every stage section must have exactly TWO column-0 fences (the
# opening and closing of the prompt body). A mismatched count means AGENT_PROMPTS.md
# was edited in a way that breaks prompt extraction — die loudly rather than ship a
# silently-truncated prompt to the agent.
extract_block() {
  local section="$1" prompts="$PIPELINE_ROOT/AGENT_PROMPTS.md"

  # Schema check: count column-0 fences in the section.
  # Boundary regex requires a numeric prefix (`## N. `) so H2 subheadings inside
  # the prompt body (e.g. `## Completion checklist`) do not prematurely end the
  # section and strand the closing fence.
  local fence_count
  fence_count="$(awk -v section="$section" '
    /^## [0-9]+\. / {
      if (in_section) { exit }
      line = $0
      sub(/^## /, "", line)
      if (line == section) { in_section=1 }
      next
    }
    in_section && /^```/ { count++ }
    END { print count+0 }
  ' "$prompts")"

  if [[ "$fence_count" != "2" ]]; then
    die "AGENT_PROMPTS.md schema error: section '$section' has $fence_count column-0 fences (expected 2). Check for stray \`\`\` lines or a missing closing fence."
  fi

  awk -v section="$section" '
    BEGIN { in_section=0; in_block=0; fence_count=0 }
    /^## [0-9]+\. / {
      if (in_section) { exit }
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
  # Canonical-first: find the doc that declares `linear: <ID>` in YAML frontmatter
  # (same rule as reconcile.sh and scope-check.sh). Only if no frontmatter match
  # exists do we fall back to filename-contains (for legacy docs pre-dating the
  # frontmatter convention). Prints a repo-relative path or "".
  local dir="$1" issue_id="$2" slug="$3"
  if [[ ! -d "$dir" ]]; then printf ''; return; fi

  # 1) Canonical: linear: <ID> in frontmatter.
  local f
  while IFS= read -r -d '' f; do
    if awk -v id="$issue_id" '
      NR==1 && $0=="---" { in_fm=1; next }
      in_fm && $0=="---" { exit 1 }
      in_fm && $0 ~ "^linear:[[:space:]]+" id "[[:space:]]*$" { exit 0 }
      NR>20 { exit 1 }
    ' "$f"; then
      printf '%s' "${f#"$REPO_ROOT/"}"
      return
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -print0)

  # 2) Title fallback: `# ENG-5: …` in the first H1.
  while IFS= read -r -d '' f; do
    if awk -v id="$issue_id" '
      /^# / { if ($0 ~ "(^|[^A-Z0-9])" id "([^A-Z0-9-]|$)") exit 0; exit 1 }
      NR>30 { exit 1 }
    ' "$f"; then
      printf '%s' "${f#"$REPO_ROOT/"}"
      return
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -print0)

  # 3) Legacy fallback: filename contains issue_id, then slug.
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
  [[ -n "$stage" ]] || die "usage: render-prompt.sh <stage> <issue_id|release-meta>"

  local section
  section="$(lookup_section "$stage")"
  [[ -n "$section" ]] || die "no prompt section for stage: $stage"

  local block
  block="$(extract_block "$section")"
  [[ -n "$block" ]] || die "could not extract block for section: $section"

  # Release stage is cross-issue: it has no single owning Linear issue. Render with
  # release metadata (version/tag/prev_tag) supplied via env by run-release-observer.sh.
  if [[ "$stage" == "release" ]]; then
    local version="${PIPELINE_RELEASE_VERSION:-}"
    local tag="${PIPELINE_RELEASE_TAG:-}"
    local prev_tag="${PIPELINE_RELEASE_PREV_TAG:-}"
    [[ -n "$version" && -n "$tag" ]] || die "release stage needs PIPELINE_RELEASE_VERSION and PIPELINE_RELEASE_TAG env"
    # Resolve prev_tag if not provided.
    if [[ -z "$prev_tag" ]]; then
      prev_tag="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 "${tag}^" 2>/dev/null \
        || git -C "$REPO_ROOT" rev-list --max-parents=0 HEAD | head -1)"
    fi
    printf '%s' "$block" \
      | sed \
        -e "s|{version}|$version|g" \
        -e "s|{tag}|$tag|g" \
        -e "s|{prev_tag}|$prev_tag|g"
    return 0
  fi

  [[ -n "$issue_id" ]] || die "stage=$stage requires <issue_id>"

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
  local issue_id_lower branch_name
  issue_id_lower="$(tr '[:upper:]' '[:lower:]' <<<"$issue_id")"
  branch_name="feature/${issue_id_lower}-${slug}"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$block" "$issue_id" "$issue_id_lower" "$title" "$description" "$date" "$slug" "$brainstorm_file" "$plan_file" "$branch_name" <<'PY'
import sys
tmpl, issue_id, issue_id_lower, title, description, date, slug, brainstorm_file, plan_file, branch_name = sys.argv[1:]
out = tmpl
repl = {
  "{issue_id}": issue_id,
  "{issue_id_lower}": issue_id_lower,
  "{issue_title}": title,
  "{issue_description}": description,
  "{date}": date,
  "{slug}": slug,
  "{brainstorm_file}": brainstorm_file,
  "{plan_file}": plan_file,
  "{branch_name}": branch_name,
}
for k, v in repl.items():
  out = out.replace(k, v)
sys.stdout.write(out)
PY
  else
    printf '%s' "$block" \
      | sed \
        -e "s|{issue_id}|$issue_id|g" \
        -e "s|{issue_id_lower}|$issue_id_lower|g" \
        -e "s|{date}|$date|g" \
        -e "s|{slug}|$slug|g" \
        -e "s|{brainstorm_file}|$brainstorm_file|g" \
        -e "s|{plan_file}|$plan_file|g" \
        -e "s|{branch_name}|$branch_name|g"
    # title and description may contain sed metacharacters — fall back users: install python3.
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
