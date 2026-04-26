#!/usr/bin/env bash
# Idempotent creation of pipeline stage + control labels in Linear.
# Safe to re-run. Reads label names from config.json; skips labels already in the cache.
#
# Usage:
#   LINEAR_API_KEY=... bash .pipeline/bin/setup-labels.sh
# After success, run `linear.sh refresh-cache` to update .pipeline/schemas/linear-ids.json.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_env LINEAR_API_KEY
require_bin curl jq

TEAM_ID="$(config_get '.linear.team_id')"

declare -a LABEL_SPECS=(
  "stage:brainstorming|#A78BFA|Pipeline: brainstorm agent is generating a design doc"
  "stage:planning|#818CF8|Pipeline: plan agent is producing the implementation plan"
  "stage:implementing|#60A5FA|Pipeline: implementation (backend) agent is working the branch"
  "stage:ui|#38BDF8|Pipeline: UI agent is building the frontend portion"
  "stage:reviewing|#22D3EE|Pipeline: review agent is evaluating the PR"
  "stage:qa|#2DD4BF|Pipeline: QA agent is running tests and adversarial checks"
  "stage:building|#34D399|Pipeline: merged to main, awaiting CI build + release"
  "stage:released|#4ADE80|Pipeline: feature released; terminal state"
  "pipeline:paused|#F59E0B|Halt pipeline advancement on this issue until removed"
  "pipeline:halted|#DC2626|Pipeline: agent finished; orchestrator owes a decision or human owes one (ENG-18)"
  "pipeline:supersede|#F97316|Reconcile: existing brainstorm/plan is superseded; generate fresh"
  "pipeline:extend|#EAB308|Reconcile: extend existing brainstorm/plan rather than replace"
  "pipeline:ignore|#A3A3A3|Reconcile: existing work is canonical; link and advance without regenerating"
  "pipeline:reviewed|#84CC16|Human-gate ack: review-rejection threshold acknowledged, resume pipeline"
  "pipeline:knowledge-reviewed|#10B981|Human-gate ack: gotcha trigger threshold acknowledged, resume pipeline"
  "pipeline:rule-reviewed|#14B8A6|Human-gate ack: learned-rule renewal threshold acknowledged, resume pipeline"
  "pipeline:scope-approval-needed|#FBBF24|Pipeline: scope-check saw notable (adjacent-to-scope) edits; remove label to approve and resume"
  "pipeline:skip-until-code-changes|#F97316|Pipeline: issue skipped until .pipeline/{bin,config.json,AGENT_PROMPTS.md} content hash or branch HEAD SHA changes. Indicates a pipeline bug."
  "pipeline:skip-until-human-acts|#EF4444|Pipeline: issue skipped until a human resolves the underlying issue (scope violation, guards, etc.) and removes this label."
)

label_exists() {
  # Prefer the cache when available (fast, no Linear hit). On a fresh
  # install the cache is populated by `linear.sh refresh-cache` AFTER
  # this script runs — at that point the cache file may not exist.
  # In that case fall back to the live team-labels snapshot we fetch
  # once at script start (see EXISTING_LABEL_NAMES below).
  local name="$1"
  if [[ -f "$IDS_CACHE" ]]; then
    local id
    id="$(ids_get ".labels[\"$name\"]" 2>/dev/null || echo "null")"
    if [[ "$id" != "null" && -n "$id" ]]; then
      return 0
    fi
  fi
  grep -Fxq -- "$name" <<<"$EXISTING_LABEL_NAMES"
}

# Fetch existing labels in this team in a single GraphQL call. The list
# is consumed by label_exists() above when the IDs cache is absent or
# missing the entry. Linear scopes labels to the team, not the project,
# so this catches the case where a sibling project in the same team has
# already provisioned the pipeline labels.
_fetch_existing_label_names() {
  local q='query($teamId: String!) { team(id: $teamId) { labels(first: 250) { nodes { name } } } }'
  local vars; vars="$(jq -cn --arg teamId "$TEAM_ID" '{teamId:$teamId}')"
  bash "$SCRIPT_DIR/linear.sh" query "$q" "$vars" \
    | jq -r '.data.team.labels.nodes[]?.name'
}

create_label() {
  local name="$1" color="$2" desc="$3"
  local q='mutation($name: String!, $color: String!, $description: String, $teamId: String) { issueLabelCreate(input: { name: $name, color: $color, description: $description, teamId: $teamId }) { success issueLabel { id name } } }'
  local vars
  vars="$(jq -cn --arg name "$name" --arg color "$color" --arg description "$desc" --arg teamId "$TEAM_ID" \
    '{name:$name, color:$color, description:$description, teamId:$teamId}')"
  bash "$SCRIPT_DIR/linear.sh" query "$q" "$vars" >/dev/null
  log "created label: $name"
}

main() {
  EXISTING_LABEL_NAMES="$(_fetch_existing_label_names)"
  local created=0 skipped=0
  for spec in "${LABEL_SPECS[@]}"; do
    IFS='|' read -r name color desc <<<"$spec"
    if label_exists "$name"; then
      log "skipped (exists in cache): $name"
      skipped=$((skipped + 1))
      continue
    fi
    create_label "$name" "$color" "$desc"
    created=$((created + 1))
  done
  log "done: created=$created skipped=$skipped"
  log "next: bash .pipeline/bin/linear.sh refresh-cache"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
