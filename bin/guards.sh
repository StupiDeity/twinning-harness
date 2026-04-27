#!/usr/bin/env bash
# Enforce human_checkpoints.require_human_on_threshold from .pipeline/config.json.
# Counters are maintained as marker comments on the Linear issue:
#   <!-- pipeline-metric: review_rejection -->
#   <!-- pipeline-metric: qa_rejection -->
#   <!-- pipeline-metric: implement_rejection -->
#   <!-- pipeline-metric: gotcha_triggered -->
#   <!-- pipeline-metric: learned_rule_renewal -->
# Each occurrence = 1 tick. The rejection counters (review_rejection,
# qa_rejection, implement_rejection) reset on every forward
# `<!-- pipeline-transition: -->` marker so that distinct loopback cycles
# don't accumulate into a false circuit-breaker trip (brainstorm §Counter
# unification). gotcha_triggered and learned_rule_renewal count across the
# whole issue lifetime by design, cleared only by their explicit ack labels:
#   pipeline:knowledge-reviewed -> clears gotcha_triggered threshold
#   pipeline:rule-reviewed      -> clears learned_rule_renewal threshold
#
# Usage:
#   guards.sh check <issue_id>
#     exit 0 if clear, exit 10 if a threshold is tripped (prints which)
#   guards.sh bump <issue_id> <counter_name>
#     counter_name: review_rejection | qa_rejection | implement_rejection | gotcha_triggered | learned_rule_renewal

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

count_marker() {
  local ident="$1" marker="$2"
  local q='query($id: String!) { issue(id: $id) { comments(first: 100) { nodes { body } } } }'
  local vars resp
  vars="$(jq -cn --arg id "$ident" '{id:$id}')"
  resp="$(bash "$SCRIPT_DIR/linear.sh" query "$q" "$vars")"
  jq -r --arg m "<!-- pipeline-metric: $marker -->" '[.data.issue.comments.nodes[]? | .body | select(contains($m))] | length' <<<"$resp"
}

# Count comment bodies containing $marker whose createdAt is newer than
# the most recent <!-- pipeline-transition: --> comment. Used by the
# rejection-counter gates so that distinct loopback cycles don't
# accumulate into a false circuit-breaker trip.
count_marker_since_last_transition() {
  local ident="$1" marker="$2"
  local comments last_ts
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$ident")"
  last_ts="$(jq -r '
    [.[] | select(.body | contains("<!-- pipeline-transition:"))]
    | sort_by(.createdAt) | last | .createdAt // ""' <<<"$comments")"
  if [[ -z "$last_ts" ]]; then
    jq -r --arg m "<!-- pipeline-metric: $marker -->" \
      '[.[] | select(.body | contains($m))] | length' <<<"$comments"
  else
    jq -r --arg m "<!-- pipeline-metric: $marker -->" --arg t "$last_ts" \
      '[.[] | select(.createdAt > $t) | select(.body | contains($m))] | length' <<<"$comments"
  fi
}

check() {
  local ident="$1"
  local review_threshold gotcha_threshold rule_threshold qa_threshold impl_threshold
  review_threshold="$(config_get '.human_checkpoints.require_human_on_threshold.review_rejections_per_feature')"
  gotcha_threshold="$(config_get '.human_checkpoints.require_human_on_threshold.gotcha_trigger_count')"
  rule_threshold="$(config_get '.human_checkpoints.require_human_on_threshold.learned_rule_renewals')"
  qa_threshold="$(config_get '.human_checkpoints.require_human_on_threshold.qa_rejections_per_feature')"
  impl_threshold="$(config_get '.human_checkpoints.require_human_on_threshold.implement_rejections_per_feature')"
  # Default each threshold to 2 if the key is absent (older / minimal configs).
  # Without these, `null: unbound variable` trips the arithmetic gates below.
  [[ "$review_threshold" == "null" || -z "$review_threshold" ]] && review_threshold=2
  [[ "$gotcha_threshold" == "null" || -z "$gotcha_threshold" ]] && gotcha_threshold=2
  [[ "$rule_threshold"   == "null" || -z "$rule_threshold"   ]] && rule_threshold=2
  [[ "$qa_threshold"     == "null" || -z "$qa_threshold"     ]] && qa_threshold=2
  [[ "$impl_threshold"   == "null" || -z "$impl_threshold"   ]] && impl_threshold=2

  local rev got rule qa impl
  rev="$(count_marker_since_last_transition "$ident" review_rejection)"
  got="$(count_marker "$ident" gotcha_triggered)"
  rule="$(count_marker "$ident" learned_rule_renewal)"
  qa="$(count_marker_since_last_transition "$ident" qa_rejection)"
  impl="$(count_marker_since_last_transition "$ident" implement_rejection)"

  local tripped=""
  if (( rev >= review_threshold )); then
    tripped+="review_rejection($rev>=$review_threshold) "
  fi
  if (( got >= gotcha_threshold )) && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" pipeline:knowledge-reviewed; then
    tripped+="gotcha_triggered($got>=$gotcha_threshold) "
  fi
  if (( rule >= rule_threshold )) && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" pipeline:rule-reviewed; then
    tripped+="learned_rule_renewal($rule>=$rule_threshold) "
  fi
  if (( qa >= qa_threshold )); then
    tripped+="qa_rejection($qa>=$qa_threshold) "
  fi
  if (( impl >= impl_threshold )); then
    tripped+="implement_rejection($impl>=$impl_threshold) "
  fi

  if [[ -n "$tripped" ]]; then
    log "guards: tripped on $ident: $tripped"
    printf '%s\n' "$tripped"
    exit 10
  fi
  log "guards: clear on $ident (rev=$rev got=$got rule=$rule qa=$qa impl=$impl)"
}

bump() {
  local ident="$1" counter="$2"
  case "$counter" in
    review_rejection|gotcha_triggered|learned_rule_renewal|qa_rejection|implement_rejection) ;;
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
