#!/usr/bin/env bash
# Check for existing brainstorm/plan docs that cover the same topic as the issue.
# Usage: reconcile.sh <issue_id> <doc_kind>
#   doc_kind: brainstorm | plan
# Outputs one of: proceed | link:<path> | human
#   proceed  -> no match, agent should generate fresh
#   link:P   -> canonical match found (Linear ID embedded in P); orchestrator links and advances
#   human    -> fuzzy match but ambiguous; orchestrator pauses and comments on Linear
# Honors pipeline:supersede / pipeline:extend / pipeline:ignore labels to resolve "human" state:
#   supersede -> proceed
#   extend    -> proceed (agent reads existing doc as input)
#   ignore    -> link:<fuzzy_match>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Jaccard similarity on token sets. Prints 0.00..1.00.
token_sim() {
  local a="$1" b="$2"
  python3 - "$a" "$b" <<'PY'
import sys, re
def tokens(s):
  return set(t for t in re.split(r'[^a-z0-9]+', s.lower()) if len(t) > 2)
a, b = tokens(sys.argv[1]), tokens(sys.argv[2])
if not a or not b:
  print("0.00"); sys.exit(0)
inter = len(a & b); union = len(a | b)
print(f"{inter/union:.2f}")
PY
}

main() {
  local issue_id="${1:-}" kind="${2:-}"
  [[ -n "$issue_id" && -n "$kind" ]] || die "usage: reconcile.sh <issue_id> <brainstorm|plan>"

  local dir
  case "$kind" in
    brainstorm) dir="$REPO_ROOT/docs/brainstorms" ;;
    plan)       dir="$REPO_ROOT/docs/plans" ;;
    *)          die "kind must be brainstorm or plan" ;;
  esac

  [[ -d "$dir" ]] || { printf 'proceed\n'; return 0; }

  # 1) Canonical match: any existing doc mentions the Linear ID (e.g. "ENG-5").
  local canonical
  canonical="$(grep -ril -m1 -E "\\b${issue_id}\\b" "$dir" 2>/dev/null | head -1 || true)"
  if [[ -n "$canonical" ]]; then
    printf 'link:%s\n' "${canonical#"$REPO_ROOT/"}"
    return 0
  fi

  # 2) Fuzzy match by title.
  local title
  title="$(bash "$SCRIPT_DIR/linear.sh" get-issue "$issue_id" | jq -r '.data.issue.title')"
  [[ -n "$title" && "$title" != "null" ]] || die "could not fetch title for $issue_id"

  local best_file="" best_score="0.00"
  while IFS= read -r -d '' f; do
    local name="${f##*/}"
    name="${name%.md}"
    # Strip date prefix if present.
    # Strip "YYYY-MM-DD-" then an optional leading ordinal, then suffixes.
    name="$(sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//; s/^[0-9]+-//; s/-(plan|design|requirements)$//' <<<"$name")"
    local s
    s="$(token_sim "$title" "$name")"
    if awk -v a="$s" -v b="$best_score" 'BEGIN{exit !(a>b)}'; then
      best_score="$s"; best_file="$f"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -print0)

  # Threshold 0.50 on jaccard tokens feels about right; tune with real data.
  if awk -v s="$best_score" 'BEGIN{exit !(s>=0.50)}'; then
    # Resolve via control label.
    if bash "$SCRIPT_DIR/linear.sh" has-label "$issue_id" "pipeline:supersede"; then
      log "reconcile: pipeline:supersede → proceed (supersedes ${best_file#"$REPO_ROOT/"} score=$best_score)"
      printf 'proceed\n'; return 0
    fi
    if bash "$SCRIPT_DIR/linear.sh" has-label "$issue_id" "pipeline:extend"; then
      log "reconcile: pipeline:extend → proceed (extends ${best_file#"$REPO_ROOT/"} score=$best_score)"
      printf 'proceed\n'; return 0
    fi
    if bash "$SCRIPT_DIR/linear.sh" has-label "$issue_id" "pipeline:ignore"; then
      log "reconcile: pipeline:ignore → link (canonical=${best_file#"$REPO_ROOT/"} score=$best_score)"
      printf 'link:%s\n' "${best_file#"$REPO_ROOT/"}"; return 0
    fi
    log "reconcile: fuzzy match needs human (candidate=${best_file#"$REPO_ROOT/"} score=$best_score)"
    printf 'human\n'; return 0
  fi

  printf 'proceed\n'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
