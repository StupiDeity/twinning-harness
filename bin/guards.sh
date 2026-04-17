#!/usr/bin/env bash
# Enforce human_checkpoints.require_human_on_threshold from .pipeline/config.json.
# Counters are maintained as marker comments on the Linear issue:
#   <!-- pipeline-metric: review_rejection -->
#   <!-- pipeline-metric: gotcha_triggered -->
#   <!-- pipeline-metric: learned_rule_renewal -->
# Each occurrence = 1 tick. An explicit human ack is a control label:
#   pipeline:reviewed          -> clears review_rejection threshold
#   pipeline:knowledge-reviewed -> clears gotcha_triggered threshold
#   pipeline:rule-reviewed     -> clears learned_rule_renewal threshold
#
# Usage:
#   guards.sh check <issue_id>
#     exit 0 if clear, exit 10 if a threshold is tripped (prints which)
#   guards.sh bump <issue_id> <counter_name>
#     counter_name: review_rejection | gotcha_triggered | learned_rule_renewal

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

count_marker() {
  local ident="$1" marker="$2"
  local q='query($teamId: ID!, $ident: String!) { issues(first: 1, filter: { team: { id: { eq: $teamId } }, identifier: { eq: $ident } }) { nodes { id comments(first: 100) { nodes { body } } } } }'
  local team_id vars resp
  team_id="$(config_get '.linear.team_id')"
  vars="$(jq -cn --arg teamId "$team_id" --arg ident "$ident" '{teamId:$teamId, ident:$ident}')"
  resp="$(bash "$SCRIPT_DIR/linear.sh" query "$q" "$vars")"
  jq -r --arg m "<!-- pipeline-metric: $marker -->" '[.data.issues.nodes[0].comments.nodes[]? | .body | select(contains($m))] | length' <<<"$resp"
}

check() {
  local ident="$1"
  local review_threshold gotcha_threshold rule_threshold
  review_threshold="$(config_get '.human_checkpoints.require_human_on_threshold.review_rejections_per_feature')"
  gotcha_threshold="$(config_get '.human_checkpoints.require_human_on_threshold.gotcha_trigger_count')"
  rule_threshold="$(config_get '.human_checkpoints.require_human_on_threshold.learned_rule_renewals')"

  local rev got rule
  rev="$(count_marker "$ident" review_rejection)"
  got="$(count_marker "$ident" gotcha_triggered)"
  rule="$(count_marker "$ident" learned_rule_renewal)"

  local tripped=""
  if (( rev >= review_threshold )) && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" pipeline:reviewed; then
    tripped+="review_rejection($rev>=$review_threshold) "
  fi
  if (( got >= gotcha_threshold )) && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" pipeline:knowledge-reviewed; then
    tripped+="gotcha_triggered($got>=$gotcha_threshold) "
  fi
  if (( rule >= rule_threshold )) && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" pipeline:rule-reviewed; then
    tripped+="learned_rule_renewal($rule>=$rule_threshold) "
  fi

  if [[ -n "$tripped" ]]; then
    log "guards: tripped on $ident: $tripped"
    printf '%s\n' "$tripped"
    exit 10
  fi
  log "guards: clear on $ident (rev=$rev got=$got rule=$rule)"
}

bump() {
  local ident="$1" counter="$2"
  case "$counter" in
    review_rejection|gotcha_triggered|learned_rule_renewal) ;;
    *) die "unknown counter: $counter" ;;
  esac
  bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "<!-- pipeline-metric: $counter --> Counter bumped by guards.sh."
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    check) check "$@" ;;
    bump)  bump "$@" ;;
    *)     die "usage: guards.sh <check|bump> <issue_id> [counter]" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
