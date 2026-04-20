#!/usr/bin/env bash
# Linear GraphQL wrapper. All Linear reads/writes go through this script.
# Auth: $LINEAR_API_KEY (personal API key, no Bearer prefix).
# Subcommands:
#   linear.sh query "<graphql>" '<variables_json>'
#   linear.sh get-issue <ENG-n>
#   linear.sh list-issues-in-state <state_name>
#   linear.sh list-issues-with-label <label_name>
#   linear.sh add-label <ENG-n> <label_name>
#   linear.sh remove-label <ENG-n> <label_name>
#   linear.sh swap-stage <ENG-n> <new_stage_name_without_prefix>
#   linear.sh transition-state <ENG-n> <state_name>
#   linear.sh add-comment <ENG-n> <body>
#   linear.sh refresh-cache
#   linear.sh stage-of <ENG-n>   # prints current stage:* label name (or empty)
#   linear.sh has-label <ENG-n> <label_name>   # exit 0 if present, 1 otherwise
#   linear.sh has-comment-since <ENG-n> <iso8601_ts>   # exit 0 if a comment exists whose createdAt >= ts, 1 otherwise

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_bin curl jq

LINEAR_ENDPOINT="https://api.linear.app/graphql"

linear_query() {
  local query="$1" variables="${2:-{\}}"
  require_env LINEAR_API_KEY

  if [[ "$PIPELINE_DRY_RUN" == "1" && "$query" =~ mutation ]]; then
    log "[DRY_RUN] linear mutation suppressed: ${query:0:80}..."
    printf '{"data":{"dry_run":true}}\n'
    return 0
  fi

  local body
  body="$(jq -cn --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')"

  local attempt=0 max_attempts=3 resp http_code
  while (( attempt < max_attempts )); do
    attempt=$((attempt+1))
    resp="$(curl -sS -w '\n%{http_code}' -X POST "$LINEAR_ENDPOINT" \
      -H "Authorization: $LINEAR_API_KEY" \
      -H 'Content-Type: application/json' \
      --data "$body" 2>/dev/null || true)"
    http_code="${resp##*$'\n'}"
    resp="${resp%$'\n'*}"
    if [[ "$http_code" =~ ^2 ]]; then
      if jq -e '.errors' >/dev/null 2>&1 <<<"$resp"; then
        log "linear GraphQL error: $(jq -c '.errors' <<<"$resp")"
        return 1
      fi
      printf '%s\n' "$resp"
      return 0
    fi
    log "linear HTTP $http_code (attempt $attempt/$max_attempts)"
    sleep $(( attempt * 2 ))
  done
  die "linear query failed after $max_attempts attempts"
}

get_issue() {
  local identifier="$1"
  local q='query($id: String!) { issue(id: $id) { id identifier title description state { id name } labels { nodes { id name } } url createdAt updatedAt } }'
  local vars
  vars="$(jq -cn --arg id "$identifier" '{id:$id}')"
  linear_query "$q" "$vars"
}

list_issues_in_state() {
  local state_name="$1" team_id
  team_id="$(config_get '.linear.team_id')"
  local q='query($teamId: ID!, $state: String!) { issues(first: 50, filter: { team: { id: { eq: $teamId } }, state: { name: { eq: $state } } }) { nodes { id identifier title state { name } labels { nodes { name } } updatedAt } } }'
  local vars
  vars="$(jq -cn --arg teamId "$team_id" --arg state "$state_name" '{teamId:$teamId, state:$state}')"
  linear_query "$q" "$vars"
}

list_issues_with_label() {
  local label_name="$1" team_id
  team_id="$(config_get '.linear.team_id')"
  local q='query($teamId: ID!, $label: String!) { issues(first: 50, filter: { team: { id: { eq: $teamId } }, labels: { name: { eq: $label } } }) { nodes { id identifier title state { name } labels { nodes { name } } updatedAt } } }'
  local vars
  vars="$(jq -cn --arg teamId "$team_id" --arg label "$label_name" '{teamId:$teamId, label:$label}')"
  linear_query "$q" "$vars"
}

_resolve_issue_uuid() {
  local ident="$1" uuid
  uuid="$(get_issue "$ident" | jq -r '.data.issue.id')"
  [[ "$uuid" != "null" && -n "$uuid" ]] || die "issue not found: $ident"
  printf '%s' "$uuid"
}

add_label() {
  local ident="$1" label_name="$2"
  local issue_uuid label_uuid
  issue_uuid="$(_resolve_issue_uuid "$ident")"
  label_uuid="$(label_id "$label_name")"
  [[ "$label_uuid" != "null" && -n "$label_uuid" ]] || die "label not in cache: $label_name (run refresh-cache)"

  # Idempotent: skip if already present.
  if has_label "$ident" "$label_name"; then
    log "label already present on $ident: $label_name"
    return 0
  fi

  if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
    log "[DRY_RUN] would add label $label_name to $ident"
    return 0
  fi
  local q='mutation($id: String!, $labelId: String!) { issueAddLabel(id: $id, labelId: $labelId) { success } }'
  local vars
  vars="$(jq -cn --arg id "$issue_uuid" --arg labelId "$label_uuid" '{id:$id, labelId:$labelId}')"
  linear_query "$q" "$vars" >/dev/null
  log "added label $label_name to $ident"
}

remove_label() {
  local ident="$1" label_name="$2"
  local issue_uuid label_uuid
  issue_uuid="$(_resolve_issue_uuid "$ident")"
  label_uuid="$(label_id "$label_name")"
  [[ "$label_uuid" != "null" && -n "$label_uuid" ]] || die "label not in cache: $label_name"

  if ! has_label "$ident" "$label_name"; then
    log "label not present on $ident: $label_name (noop)"
    return 0
  fi

  if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
    log "[DRY_RUN] would remove label $label_name from $ident"
    return 0
  fi
  local q='mutation($id: String!, $labelId: String!) { issueRemoveLabel(id: $id, labelId: $labelId) { success } }'
  local vars
  vars="$(jq -cn --arg id "$issue_uuid" --arg labelId "$label_uuid" '{id:$id, labelId:$labelId}')"
  linear_query "$q" "$vars" >/dev/null
  log "removed label $label_name from $ident"
}

stage_of() {
  local ident="$1"
  get_issue "$ident" | jq -r '[.data.issue.labels.nodes[] | select(.name | startswith("stage:")) | .name] | first // ""'
}

has_label() {
  local ident="$1" label_name="$2"
  local names
  names="$(get_issue "$ident" | jq -r '.data.issue.labels.nodes[].name')"
  grep -Fxq "$label_name" <<<"$names"
}

swap_stage() {
  local ident="$1" new_stage="$2"
  local prefix new_label current
  prefix="$(config_get '.linear.stage_label_prefix')"
  new_label="${prefix}${new_stage}"

  # Remove any existing stage:* label, then add new one.
  current="$(stage_of "$ident")"
  if [[ -n "$current" && "$current" != "$new_label" ]]; then
    remove_label "$ident" "$current"
  fi
  if [[ "$current" != "$new_label" ]]; then
    add_label "$ident" "$new_label"
  fi
}

transition_state() {
  local ident="$1" state_name="$2"
  local issue_uuid state_uuid
  issue_uuid="$(_resolve_issue_uuid "$ident")"
  state_uuid="$(state_id "$state_name")"
  [[ "$state_uuid" != "null" && -n "$state_uuid" ]] || die "state not in cache: $state_name"

  # Idempotent.
  local current
  current="$(get_issue "$ident" | jq -r '.data.issue.state.name')"
  if [[ "$current" == "$state_name" ]]; then
    log "state already $state_name on $ident (noop)"
    return 0
  fi

  if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
    log "[DRY_RUN] would transition $ident: $current -> $state_name"
    return 0
  fi
  local q='mutation($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success } }'
  local vars
  vars="$(jq -cn --arg id "$issue_uuid" --arg stateId "$state_uuid" '{id:$id, stateId:$stateId}')"
  linear_query "$q" "$vars" >/dev/null
  log "transitioned $ident: $current -> $state_name"
}

has_comment_since() {
  # Exit 0 iff the issue has at least one comment with createdAt >= the provided ISO8601
  # timestamp. Used by run-stage.sh to verify the agent honored the "Post Linear comment"
  # completion-checklist step.
  local ident="$1" since="$2"
  [[ -n "$since" ]] || die "has-comment-since requires a timestamp"
  local q='query($id: String!) { issue(id: $id) { comments(first: 50) { nodes { createdAt } } } }'
  local vars resp
  vars="$(jq -cn --arg id "$ident" '{id:$id}')"
  resp="$(linear_query "$q" "$vars")"
  # Lex-compare ISO8601 strings (Linear normalises to Z, same length). jq -e returns
  # nonzero if no element matches.
  jq -e --arg since "$since" \
    '[.data.issue.comments.nodes[]? | select(.createdAt >= $since)] | length > 0' \
    >/dev/null 2>&1 <<<"$resp"
}

add_comment() {
  local ident="$1" body="$2"
  local issue_uuid
  issue_uuid="$(_resolve_issue_uuid "$ident")"
  if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
    log "[DRY_RUN] would comment on $ident: ${body:0:80}..."
    return 0
  fi
  local q='mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }'
  local vars
  vars="$(jq -cn --arg id "$issue_uuid" --arg body "$body" '{id:$id, body:$body}')"
  linear_query "$q" "$vars" >/dev/null
  log "commented on $ident"
}

refresh_cache() {
  require_env LINEAR_API_KEY
  local team_id
  team_id="$(config_get '.linear.team_id')"
  log "refreshing Linear ID cache for team $team_id..."

  local q='query($teamId: String!) { team(id: $teamId) { id key name states { nodes { id name type } } labels { nodes { id name } } organization { id name } } project(id: "'"$(config_get '.linear.project_id')"'") { id name } }'
  local vars
  vars="$(jq -cn --arg teamId "$team_id" '{teamId:$teamId}')"
  local resp
  resp="$(linear_query "$q" "$vars")"

  local states_json labels_json project_id project_name
  states_json="$(jq '[.data.team.states.nodes[] | {key: .name, value: .id}] | from_entries' <<<"$resp")"
  labels_json="$(jq '[.data.team.labels.nodes[] | {key: .name, value: .id}] | from_entries' <<<"$resp")"
  project_id="$(jq -r '.data.project.id' <<<"$resp")"
  project_name="$(jq -r '.data.project.name' <<<"$resp")"

  local team_name team_key
  team_name="$(jq -r '.data.team.name' <<<"$resp")"
  team_key="$(jq -r '.data.team.key' <<<"$resp")"

  jq -n \
    --arg generated_at "$(date -u +%Y-%m-%d)" \
    --arg generated_by "linear.sh refresh-cache" \
    --arg team_id "$team_id" \
    --arg team_key "$team_key" \
    --arg team_name "$team_name" \
    --arg project_id "$project_id" \
    --arg project_name "$project_name" \
    --argjson states "$states_json" \
    --argjson labels "$labels_json" \
    '{
      "$comment": "UUID cache for Linear entities. Regenerated by linear.sh refresh-cache.",
      generated_at: $generated_at,
      generated_by: $generated_by,
      team: { id: $team_id, key: $team_key, name: $team_name },
      project: { id: $project_id, name: $project_name },
      states: $states,
      labels: $labels
    }' > "$IDS_CACHE.tmp"
  mv "$IDS_CACHE.tmp" "$IDS_CACHE"
  log "cache refreshed: $IDS_CACHE"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    query)                  linear_query "$@" ;;
    get-issue)              get_issue "$@" ;;
    list-issues-in-state)   list_issues_in_state "$@" ;;
    list-issues-with-label) list_issues_with_label "$@" ;;
    add-label)              add_label "$@" ;;
    remove-label)           remove_label "$@" ;;
    swap-stage)             swap_stage "$@" ;;
    transition-state)       transition_state "$@" ;;
    add-comment)            add_comment "$@" ;;
    stage-of)               stage_of "$@" ;;
    has-label)              has_label "$@" ;;
    has-comment-since)      has_comment_since "$@" ;;
    refresh-cache)          refresh_cache ;;
    *)                      die "unknown command: $cmd (see linear.sh header)" ;;
  esac
}

# Only run main when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
