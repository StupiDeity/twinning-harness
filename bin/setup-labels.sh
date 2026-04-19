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
  "pipeline:supersede|#F97316|Reconcile: existing brainstorm/plan is superseded; generate fresh"
  "pipeline:extend|#EAB308|Reconcile: extend existing brainstorm/plan rather than replace"
  "pipeline:ignore|#A3A3A3|Reconcile: existing work is canonical; link and advance without regenerating"
  "pipeline:reviewed|#84CC16|Human-gate ack: review-rejection threshold acknowledged, resume pipeline"
  "pipeline:knowledge-reviewed|#10B981|Human-gate ack: gotcha trigger threshold acknowledged, resume pipeline"
  "pipeline:rule-reviewed|#14B8A6|Human-gate ack: learned-rule renewal threshold acknowledged, resume pipeline"
  "pipeline:scope-approval-needed|#FBBF24|Pipeline: scope-check saw notable (adjacent-to-scope) edits; remove label to approve and resume"
)

label_exists() {
  local name="$1" id
  id="$(ids_get ".labels[\"$name\"]" 2>/dev/null || echo "null")"
  [[ "$id" != "null" && -n "$id" ]]
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
