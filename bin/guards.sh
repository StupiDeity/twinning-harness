#!/usr/bin/env bash
# Enforce human_checkpoints.require_human_on_threshold from .pipeline/config.json.
# Counters are maintained as marker comments on the Linear issue:
#   <!-- meta: metric name=review_rejection -->
#   <!-- meta: metric name=qa_rejection -->
#   <!-- meta: metric name=implement_rejection -->
#   <!-- meta: metric name=gotcha_triggered -->
#   <!-- meta: metric name=learned_rule_renewal -->
# Each occurrence = 1 tick. The rejection counters (review_rejection,
# qa_rejection, implement_rejection) accumulate across loopback cycles
# and are cleared ONLY by an operator-resume waypoint
# `<!-- pipeline: transition ... reason=operator-resume -->` (posted by
# `bin/pipeline.sh decide --action continue`). Auto-transitions
# (forward stage advance and build/review loopbacks) do NOT reset the
# counter. ENG-123 demonstrated the prior "reset on any transition"
# semantic let review/implement loops churn indefinitely: every
# `reviewing → implementing` auto-transition zeroed the counter, so the
# threshold could never trip from review_rejection alone, and the
# `building → implementing` merge-conflict loopback handed each rebase
# round a fresh budget.
# ENG-138/ENG-145 narrow the firing-side for all three rejection
# counters: each threshold (review_rejection, qa_rejection,
# implement_rejection) trips only when the dispatched stage is
# 'implementing' — the loopback continuation edge shared by all
# three loops (verdict-handler.sh:35-37). Reaching a downstream
# stage after a clean upstream PASS no longer halts even when the
# cumulative count is at or over the threshold. The counter still
# accumulates across loopback cycles for operator audit (visible
# in the `guards: clear` log line), and reset semantics
# (operator-resume waypoint clears) are unchanged.
# gotcha_triggered and learned_rule_renewal count
# across the whole issue lifetime by design, cleared only by their explicit
# ack labels:
#   pipeline:knowledge-reviewed -> clears gotcha_triggered threshold
#   pipeline:rule-reviewed      -> clears learned_rule_renewal threshold
#
# Reads tolerate the legacy `<!-- pipeline-metric: ... -->` /
# `<!-- pipeline-transition: ... -->` shapes for in-flight issues whose
# history predates the ENG-60 vocabulary cutover.
#
# Usage:
#   guards.sh check <issue_id> [stage]
#     exit 0 if clear, exit 10 if a threshold is tripped (prints which).
#     When [stage] is omitted, the review_rejection, qa_rejection,
#     and implement_rejection trips fire as today (operator-triage /
#     case-15 back-compat). When [stage] is provided (e.g. by
#     bin/run-stage.sh), all three trips are scoped to stage ==
#     implementing — see header comment above for the ENG-138/ENG-145
#     contract.
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
  jq -r \
    --arg m  "<!-- meta: metric name=$marker -->" \
    --arg m_legacy "<!-- pipeline-metric: $marker -->" \
    '[.data.issue.comments.nodes[]? | .body | select(contains($m) or contains($m_legacy))] | length' <<<"$resp"
}

# Count comment bodies containing $marker whose createdAt is newer than
# the most recent operator-resume waypoint
# (`<!-- pipeline: transition ... reason=operator-resume -->`). Used by the
# rejection-counter gates so loopback cycles accumulate across the issue
# lifetime, cleared only by operator action (`bin/pipeline.sh decide
# --action continue`). Pre-ENG-123 the helper reset on any transition,
# which let auto-transitions silently zero the counter every loopback.
# When no operator-resume waypoint exists, falls back to counting all
# markers across the issue's lifetime — back-compat for in-flight issues
# that pre-date the cutover, and for any issue that has never been
# operator-resumed.
count_marker_since_last_operator_resume() {
  local ident="$1" marker="$2"
  local comments last_ts
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$ident")"
  last_ts="$(jq -r '
    [.[] | select(.body | test("<!-- pipeline: transition[^>]*reason=operator-resume"))]
    | sort_by(.createdAt) | last | .createdAt // ""' <<<"$comments")"
  if [[ -z "$last_ts" ]]; then
    jq -r \
      --arg m  "<!-- meta: metric name=$marker -->" \
      --arg m_legacy "<!-- pipeline-metric: $marker -->" \
      '[.[] | select(.body | contains($m) or contains($m_legacy))] | length' <<<"$comments"
  else
    jq -r \
      --arg m  "<!-- meta: metric name=$marker -->" \
      --arg m_legacy "<!-- pipeline-metric: $marker -->" \
      --arg t "$last_ts" \
      '[.[] | select(.createdAt > $t) | select(.body | contains($m) or contains($m_legacy))] | length' <<<"$comments"
  fi
}

check() {
  local ident="$1"
  local stage="${2:-}"
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
  rev="$(count_marker_since_last_operator_resume "$ident" review_rejection)"
  got="$(count_marker "$ident" gotcha_triggered)"
  rule="$(count_marker "$ident" learned_rule_renewal)"
  qa="$(count_marker_since_last_operator_resume "$ident" qa_rejection)"
  impl="$(count_marker_since_last_operator_resume "$ident" implement_rejection)"

  local tripped=""
  # ENG-138: trip review_rejection only when the next dispatched stage is
  # 'implementing' (the loopback-continuation edge). Empty-stage CLI
  # invocations preserve the trip-as-today path used by bin/run-stage-
  # test.sh::case-15 and operator triage flows. The counter still
  # accumulates across loopback cycles; reset semantics from ENG-116
  # (operator-resume only) are unchanged.
  if (( rev >= review_threshold )) && [[ -z "$stage" || "$stage" == "implementing" ]]; then
    tripped+="review_rejection($rev>=$review_threshold) "
  fi
  if (( got >= gotcha_threshold )) && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" pipeline:knowledge-reviewed; then
    tripped+="gotcha_triggered($got>=$gotcha_threshold) "
  fi
  if (( rule >= rule_threshold )) && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" pipeline:rule-reviewed; then
    tripped+="learned_rule_renewal($rule>=$rule_threshold) "
  fi
  if (( qa >= qa_threshold )) && [[ -z "$stage" || "$stage" == "implementing" ]]; then
    tripped+="qa_rejection($qa>=$qa_threshold) "
  fi
  if (( impl >= impl_threshold )) && [[ -z "$stage" || "$stage" == "implementing" ]]; then
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
  bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "<!-- meta: metric name=$counter --> Counter bumped by guards.sh."
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
