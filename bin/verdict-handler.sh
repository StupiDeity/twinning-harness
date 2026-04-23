#!/usr/bin/env bash
# Verdict Handler (ENG-18). Reads Linear comment history, finds the fresh
# verdict marker per the freshness rule, validates against the transition
# tables, performs atomic transitions. Source-able.
#
# Public functions:
#   verdict_handler <issue> <current_stage>   # 0=transitioned, 1=halt preserved, 2=protocol violation
#   find_fresh_verdict <issue>                # prints JSON {marker,source_stage,target_stage,reason,comment_id} or empty
#   apply_transition <issue> <from> <to> <side_effect_labels_csv>
#   resume_in_progress_transition <issue>     # 0=resumed, 1=nothing to resume

set -euo pipefail
_VH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$_VH_SCRIPT_DIR/common.sh"

# Forward transitions: happy-path stage advancement.
# Rows: <from>=<to>.
_VH_FORWARD_TRANSITIONS='
brainstorming=planning
planning=implementing
implementing=ui
ui=reviewing
reviewing=qa
qa=building
building=released
'

# Loopback transitions: rejection-verdict (source, target) pairs and the
# side-effect labels to apply. Rows: <from>|<to>|<csv-of-labels>. The
# pipe delimiter is load-bearing because label names contain `:`.
_VH_LOOPBACK_TRANSITIONS='
planning|brainstorming|pipeline:supersede
reviewing|brainstorming|pipeline:supersede
reviewing|implementing|
qa|implementing|
building|implementing|
'

_vh_lookup_forward() {
  local from="$1"
  grep -E "^${from}=" <<<"$_VH_FORWARD_TRANSITIONS" | head -1 | cut -d'=' -f2-
}

# Print the full row (from|to|labels) iff the (from,to) pair is legal.
_vh_lookup_loopback() {
  local from="$1" to="$2"
  awk -F'|' -v from="$from" -v to="$to" '$1==from && $2==to {print; exit}' \
    <<<"$_VH_LOOPBACK_TRANSITIONS"
}

_vh_protocol_violation() {
  local issue="$1" case_id="$2" reason="$3"
  local body
  body="$(printf '<!-- pipeline-halt: protocol-violation -->\n\nProtocol violation (%s): %s' "$case_id" "$reason")"
  bash "$_VH_SCRIPT_DIR/linear.sh" add-or-update-comment \
    "protocol-violation/$case_id/$issue" "$issue" "$body" || true
  bash "$_VH_SCRIPT_DIR/linear.sh" add-label "$issue" "pipeline:halted" || true
  log "verdict-handler: protocol violation on $issue ($case_id): $reason"
}

# Extract the most recent verdict marker (pipeline-stage-summary,
# pipeline-rejection, or pipeline-halt) that is newer than the most
# recent pipeline-transition comment. pipeline-decision and
# pipeline-transition are not verdict shapes.
#
# Prints JSON {marker, source_stage, target_stage, reason, comment_id}
# or empty string when nothing fresh qualifies.
find_fresh_verdict() {
  local issue="$1"
  local comments
  comments="$(bash "$_VH_SCRIPT_DIR/linear.sh" get-comments "$issue")"
  [[ -z "$comments" || "$comments" == "null" ]] && { printf ''; return 0; }

  local last_transition_ts
  last_transition_ts="$(jq -r '
    [.[] | select(.body | contains("<!-- pipeline-transition:"))]
    | sort_by(.createdAt) | last | .createdAt // ""' <<<"$comments")"

  # Pick the most recent verdict-shaped comment newer than the last
  # transition (or any verdict comment if no transition exists yet).
  local fresh
  fresh="$(jq -c --arg t "$last_transition_ts" '
    [.[]
     | select(.createdAt > $t)
     | select(
         (.body | contains("<!-- pipeline-stage-summary:")) or
         (.body | contains("<!-- pipeline-rejection:")) or
         (.body | contains("<!-- pipeline-halt:"))
       )]
    | sort_by(.createdAt) | last // empty' <<<"$comments")"
  [[ -z "$fresh" ]] && { printf ''; return 0; }

  local body id
  body="$(jq -r '.body' <<<"$fresh")"
  id="$(jq -r '.id' <<<"$fresh")"

  local marker src tgt reason
  marker=""; src=""; tgt=""; reason=""
  if grep -qE '<!-- pipeline-stage-summary: [a-z]+ -->' <<<"$body"; then
    marker="pipeline-stage-summary"
    src="$(grep -oE '<!-- pipeline-stage-summary: [a-z]+ -->' <<<"$body" \
      | head -1 | sed -E 's/<!-- pipeline-stage-summary: ([a-z]+) -->/\1/')"
  elif grep -qE '<!-- pipeline-rejection: [a-z]+ -->' <<<"$body"; then
    marker="pipeline-rejection"
    src="$(grep -oE '<!-- pipeline-rejection: [a-z]+ -->' <<<"$body" \
      | head -1 | sed -E 's/<!-- pipeline-rejection: ([a-z]+) -->/\1/')"
    tgt="$(grep -oE '<!-- pipeline-rejection-target: [a-z]+ -->' <<<"$body" \
      | head -1 | sed -E 's/<!-- pipeline-rejection-target: ([a-z]+) -->/\1/')"
  elif grep -qE '<!-- pipeline-halt: [a-z-]+ -->' <<<"$body"; then
    marker="pipeline-halt"
    reason="$(grep -oE '<!-- pipeline-halt: [a-z-]+ -->' <<<"$body" \
      | head -1 | sed -E 's/<!-- pipeline-halt: ([a-z-]+) -->/\1/')"
  else
    # Malformed; treat as no fresh verdict.
    printf ''
    return 0
  fi

  jq -cn \
    --arg marker "$marker" \
    --arg src "$src" \
    --arg tgt "$tgt" \
    --arg reason "$reason" \
    --arg id "$id" \
    '{marker:$marker, source_stage:$src, target_stage:$tgt, reason:$reason, comment_id:$id}'
}

# Atomic transition order (per brainstorm §Atomic transition order):
#   1. Post <!-- pipeline-transition: from → to --> comment (freshness waypoint).
#   2. Add stage:<to> label.
#   3. Remove stage:<from> label.
#   3.5. Native-state hook: if to == reviewing, flip Linear status to In Review.
#   4. Apply side-effect labels (csv).
#   5. Remove pipeline:halted.
# Each step is idempotent; resume_in_progress_transition can re-enter
# at any point and finish cleanly.
apply_transition() {
  local issue="$1" from="$2" to="$3" side_labels="${4:-}"
  local post_waypoint="${5:-1}"  # internal: resume path passes 0 to skip step 1

  if [[ "$post_waypoint" == "1" ]]; then
    local transition_body
    transition_body="$(printf '<!-- pipeline-transition: %s → %s -->\n\nOrchestrator transition waypoint.' "$from" "$to")"
    bash "$_VH_SCRIPT_DIR/linear.sh" add-comment "$issue" "$transition_body" || true
  fi

  bash "$_VH_SCRIPT_DIR/linear.sh" add-label "$issue" "stage:${to}" || true
  [[ -n "$from" ]] && bash "$_VH_SCRIPT_DIR/linear.sh" remove-label "$issue" "stage:${from}" || true

  if [[ "$to" == "reviewing" ]]; then
    local in_review_state
    in_review_state="$(config_get '.linear.native_states.in_review')"
    bash "$_VH_SCRIPT_DIR/linear.sh" transition-state "$issue" "$in_review_state" || true
  fi

  if [[ -n "$side_labels" ]]; then
    local IFS_SAVE="$IFS"
    IFS=','
    for label in $side_labels; do
      [[ -z "$label" ]] && continue
      bash "$_VH_SCRIPT_DIR/linear.sh" add-label "$issue" "$label" || true
    done
    IFS="$IFS_SAVE"
  fi

  bash "$_VH_SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted" || true
  log "verdict-handler: applied transition $issue: $from → $to (side=${side_labels:-none})"
}

# Detect a mid-transition crash: a <!-- pipeline-transition: X → Y -->
# comment exists and is the most recent transition, but current stage
# is still :X and pipeline:halted is still applied. Complete the
# remaining label operations (skip the transition-comment post; it was
# already done before the crash).
resume_in_progress_transition() {
  local issue="$1"
  local comments last_transition from to current_stage has_halt
  comments="$(bash "$_VH_SCRIPT_DIR/linear.sh" get-comments "$issue")"
  [[ -z "$comments" || "$comments" == "null" ]] && return 1

  last_transition="$(jq -r '
    [.[] | select(.body | contains("<!-- pipeline-transition:"))]
    | sort_by(.createdAt) | last // empty | .body // ""' <<<"$comments")"
  [[ -z "$last_transition" ]] && return 1

  from="$(grep -oE '<!-- pipeline-transition: [a-z]+ → [a-z]+ -->' <<<"$last_transition" \
    | head -1 | sed -E 's/<!-- pipeline-transition: ([a-z]+) → ([a-z]+) -->/\1/')"
  to="$(grep -oE '<!-- pipeline-transition: [a-z]+ → [a-z]+ -->' <<<"$last_transition" \
    | head -1 | sed -E 's/<!-- pipeline-transition: ([a-z]+) → ([a-z]+) -->/\2/')"
  [[ -z "$from" || -z "$to" ]] && return 1

  current_stage="$(bash "$_VH_SCRIPT_DIR/linear.sh" stage-of "$issue")"
  current_stage="${current_stage#stage:}"

  if [[ "$current_stage" != "$to" ]] \
     && bash "$_VH_SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted"; then
    log "verdict-handler: resuming mid-transition $issue: $from → $to"
    apply_transition "$issue" "$from" "$to" "" 0
    return 0
  fi
  return 1
}

# Main entrypoint. Dispatches on the fresh verdict marker shape.
verdict_handler() {
  local issue="$1" current_stage="$2"

  if resume_in_progress_transition "$issue"; then
    log "verdict-handler: resumed in-progress transition for $issue"
    return 0
  fi

  local fresh
  fresh="$(find_fresh_verdict "$issue")"
  if [[ -z "$fresh" ]]; then
    _vh_protocol_violation "$issue" "no-marker" \
      "halt applied without a fresh verdict marker"
    return 2
  fi

  local mtype src tgt
  mtype="$(jq -r '.marker' <<<"$fresh")"
  src="$(jq -r '.source_stage' <<<"$fresh")"
  tgt="$(jq -r '.target_stage' <<<"$fresh")"

  case "$mtype" in
    pipeline-stage-summary)
      if [[ "$src" != "$current_stage" ]]; then
        _vh_protocol_violation "$issue" "stage-mismatch" \
          "stage-summary source=$src != current=$current_stage"
        return 2
      fi
      local fwd; fwd="$(_vh_lookup_forward "$src")"
      if [[ -z "$fwd" ]]; then
        _vh_protocol_violation "$issue" "unknown-forward" \
          "no forward transition from $src"
        return 2
      fi
      apply_transition "$issue" "$src" "$fwd" ""
      return 0
      ;;
    pipeline-rejection)
      local row; row="$(_vh_lookup_loopback "$src" "$tgt")"
      if [[ -z "$row" ]]; then
        _vh_protocol_violation "$issue" "unknown-loopback" \
          "rejection ($src → $tgt) not in loopback table"
        return 2
      fi
      local side; side="$(cut -d'|' -f3 <<<"$row")"
      apply_transition "$issue" "$src" "$tgt" "$side"
      return 0
      ;;
    pipeline-halt)
      log "verdict-handler: halt marker on $issue (reason=$(jq -r '.reason' <<<"$fresh")) — leaving halt intact"
      return 1
      ;;
    *)
      _vh_protocol_violation "$issue" "unknown-marker" "marker=$mtype"
      return 2
      ;;
  esac
}

export -f verdict_handler find_fresh_verdict apply_transition resume_in_progress_transition
