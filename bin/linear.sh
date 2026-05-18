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
#   linear.sh add-comment <ENG-n> --body <body>
#   linear.sh add-comment <ENG-n> --body -                   # body from stdin (heredoc-friendly)
#   linear.sh add-comment <ENG-n> --body-file <path>         # body from file
#   (same flags accepted by add-or-update-comment, after the <sig> argument)
#   linear.sh refresh-cache
#   linear.sh stage-of <ENG-n>   # prints current stage:* label name (or empty)
#   linear.sh all-stage-labels <ENG-n>   # prints all stage:* labels space-separated (or empty)
#   linear.sh has-label <ENG-n> <label_name>   # exit 0 if present, 1 otherwise
#   linear.sh has-comment-since <ENG-n> <iso8601_ts>   # exit 0 if a comment exists whose createdAt >= ts, 1 otherwise
#   linear.sh get-comments <ENG-n>   # prints a JSON array [{id, body, createdAt}, ...] in chronological ascending order (oldest first), paginated to the most recent 50

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_bin curl jq

LINEAR_ENDPOINT="https://api.linear.app/graphql"

# ─── Lane fence (ENG-41) ────────────────────────────────────────────────
# Classify a label name into one of the five object classes used by the
# lane allow-list matrix.
#   stage_label         — matches ^stage:.+$
#   pipeline_halted     — exact match pipeline:halted
#   pipeline_supersede  — exact match pipeline:supersede
#   pipeline_skip_until — matches ^pipeline:skip-until-.+$
#   any_other_label     — everything else
_classify_label() {
  local label="$1"
  case "$label" in
    stage:*)                       printf 'stage_label' ;;
    pipeline:halted)               printf 'pipeline_halted' ;;
    pipeline:supersede)            printf 'pipeline_supersede' ;;
    pipeline:skip-until-*)         printf 'pipeline_skip_until' ;;
    *)                             printf 'any_other_label' ;;
  esac
}

# ─── Dispatch-id auto-injection (ENG-87) ─────────────────────────────
# Append `<!-- meta: dispatch id=ENG-N-d<NNNN> stage=<gerund> -->` to a
# comment body when PIPELINE_DISPATCH_ID is set. Idempotent — skip if
# the body already contains the marker (defends against double-injection
# on add-or-update-comment re-applies). Operator-lane writes (env unset)
# bypass injection by design. ${VAR-} (single-dash empty fallback) is
# the set -u-safe form for set-but-may-be-empty env probing.
_inject_dispatch_marker() {
  local body="$1"
  [[ -n "${PIPELINE_DISPATCH_ID-}" ]] || { printf '%s' "$body"; return 0; }
  # ENG-87 review-iter-7 m2: idempotency check matches the CURRENT
  # dispatch id specifically. Pre-fix, `grep -qF '<!-- meta: dispatch id='`
  # matched ANY dispatch marker — including STALE markers from prior
  # dispatches (e.g., a body that already carries `id=ENG-N-d0050` from
  # a re-apply with PIPELINE_DISPATCH_ID=ENG-N-d0099 would skip
  # injection, leaving the operator-visible marker out of sync with
  # the freshness rule). Trailing space avoids prefix collisions
  # (id=ENG-N-d100 vs id=ENG-N-d10).
  if grep -qF "<!-- meta: dispatch id=${PIPELINE_DISPATCH_ID-} " <<<"$body"; then
    printf '%s' "$body"
    return 0
  fi
  printf '%s\n\n<!-- meta: dispatch id=%s stage=%s -->' \
    "$body" "${PIPELINE_DISPATCH_ID-}" "${PIPELINE_STAGE-}"
}

# Classify a comment body into transition_comment or other_comment.
# transition_comment: the first non-blank line of the body is the
# orchestrator transition waypoint marker. Recognized shapes:
#   <!-- pipeline: transition from=<from> to=<to> -->   (current, ENG-60)
#   <!-- pipeline-transition: <from> → <to> -->         (legacy; in-flight back-compat)
_classify_comment_body() {
  local body="$1"
  local first_nonblank
  first_nonblank="$(printf '%s' "$body" | grep -m1 '[^ ]' || true)"
  # Trim leading whitespace from the first non-blank line.
  first_nonblank="$(printf '%s' "$first_nonblank" | sed 's/^[[:space:]]*//')"
  if [[ "$first_nonblank" =~ ^'<!--'\ pipeline:\ transition\ .+\ '-->' ]] \
     || [[ "$first_nonblank" =~ ^'<!--'\ pipeline-transition:\ .+\ '-->' ]]; then
    printf 'transition_comment'
  else
    printf 'other_comment'
  fi
}

# Lane allow-list matrix.  Rows = "action object_class", columns = lanes.
# Value "allow" or "deny".  All unlisted combinations default to deny.
# Source of truth: docs/plans/2026-04-27-eng-41-pipeline-trust-model-enforce-write-lanes.md
#   §Command API contract.
_lane_decision() {
  local action="$1" object_class="$2" lane="$3"
  # Key: "<action> <object_class>" → per-lane array of allowed lanes.
  case "${action} ${object_class}" in
    "add stage_label")            case "$lane" in orchestrator|human) printf 'allow';; *) printf 'deny';; esac ;;
    "remove stage_label")         case "$lane" in orchestrator|human) printf 'allow';; *) printf 'deny';; esac ;;
    "add pipeline_halted")        printf 'allow' ;;  # all lanes allowed
    "remove pipeline_halted")     case "$lane" in orchestrator|human) printf 'allow';; *) printf 'deny';; esac ;;
    "add pipeline_supersede")     case "$lane" in orchestrator|human) printf 'allow';; *) printf 'deny';; esac ;;
    "remove pipeline_supersede")  case "$lane" in orchestrator|agent|human) printf 'allow';; *) printf 'deny';; esac ;;
    "add pipeline_skip_until")    case "$lane" in classify|human) printf 'allow';; *) printf 'deny';; esac ;;
    "remove pipeline_skip_until") case "$lane" in orchestrator|classify|human) printf 'allow';; *) printf 'deny';; esac ;;
    "add transition_comment")     case "$lane" in orchestrator|human) printf 'allow';; *) printf 'deny';; esac ;;
    "add other_comment")          printf 'allow' ;;  # all lanes allowed
    "add any_other_label")        case "$lane" in orchestrator|human) printf 'allow';; *) printf 'deny';; esac ;;
    "remove any_other_label")     case "$lane" in orchestrator|human) printf 'allow';; *) printf 'deny';; esac ;;
    *)                            printf 'deny' ;;
  esac
}

# Allowed lanes for a given action × object_class (for the deny error message).
_allowed_lanes_for() {
  local action="$1" object_class="$2"
  case "${action} ${object_class}" in
    "add stage_label")            printf 'orchestrator,human' ;;
    "remove stage_label")         printf 'orchestrator,human' ;;
    "add pipeline_halted")        printf 'orchestrator,agent,classify,scope-check,human' ;;
    "remove pipeline_halted")     printf 'orchestrator,human' ;;
    "add pipeline_supersede")     printf 'orchestrator,human' ;;
    "remove pipeline_supersede")  printf 'orchestrator,agent,human' ;;
    "add pipeline_skip_until")    printf 'classify,human' ;;
    "remove pipeline_skip_until") printf 'orchestrator,classify,human' ;;
    "add transition_comment")     printf 'orchestrator,human' ;;
    "add other_comment")          printf 'orchestrator,agent,classify,scope-check,human' ;;
    "add any_other_label")        printf 'orchestrator,human' ;;
    "remove any_other_label")     printf 'orchestrator,human' ;;
    *)                            printf 'none' ;;
  esac
}

# _check_lane <action> <object_class>
# Reads ${PIPELINE_WRITER:-orchestrator}, looks up the lane allow-list,
# and on denial prints a structured error to stderr and returns 11.
# Returns 0 on allow.
_check_lane() {
  local action="$1" object_class="$2"
  local lane="${PIPELINE_WRITER:-orchestrator}"

  # Validate lane.
  case "$lane" in
    orchestrator|agent|classify|scope-check|human) ;;
    *)
      printf 'linear.sh: unrecognized lane: %s (valid: orchestrator,agent,classify,scope-check,human)\n' \
        "$lane" >&2
      return 13
      ;;
  esac

  local decision
  decision="$(_lane_decision "$action" "$object_class" "$lane")"
  if [[ "$decision" == "allow" ]]; then
    return 0
  fi

  local allowed
  allowed="$(_allowed_lanes_for "$action" "$object_class")"
  printf 'linear.sh: lane=%s denied: %s %s\n            (allowed lanes for %s %s: %s)\n' \
    "$lane" "$action" "$object_class" "$action" "$object_class" "$allowed" >&2
  return 13
}

# all_stage_labels <issue>
# Emits all stage:* labels on an issue, space-separated.
# Used by verdict-handler's multi-stage-label guard (ENG-41 Task 4).
all_stage_labels() {
  local ident="$1"
  get_issue "$ident" \
    | jq -r '[.data.issue.labels.nodes[] | select(.name | startswith("stage:")) | .name] | join(" ")'
}

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

_require_project_id() {
  local pid; pid="$(config_get '.linear.project_id')"
  [[ -n "$pid" && "$pid" != "null" ]] || die "config.linear.project_id is required (scopes issue listings to one Linear project; an unscoped poller would pick up issues from sibling projects in the same team)"
  printf '%s' "$pid"
}

list_issues_in_state() {
  local state_name="$1" team_id project_id
  team_id="$(config_get '.linear.team_id')"
  project_id="$(_require_project_id)"
  local q='query($teamId: ID!, $projectId: ID!, $state: String!) { issues(first: 50, filter: { team: { id: { eq: $teamId } }, project: { id: { eq: $projectId } }, state: { name: { eq: $state } } }) { nodes { id identifier title state { name } labels { nodes { name } } priority updatedAt createdAt } } }'
  local vars
  vars="$(jq -cn --arg teamId "$team_id" --arg projectId "$project_id" --arg state "$state_name" '{teamId:$teamId, projectId:$projectId, state:$state}')"
  linear_query "$q" "$vars"
}

list_issues_with_label() {
  local label_name="$1" team_id project_id
  team_id="$(config_get '.linear.team_id')"
  project_id="$(_require_project_id)"
  local q='query($teamId: ID!, $projectId: ID!, $label: String!) { issues(first: 50, filter: { team: { id: { eq: $teamId } }, project: { id: { eq: $projectId } }, labels: { name: { eq: $label } } }) { nodes { id identifier title state { name } labels { nodes { name } } priority updatedAt } } }'
  local vars
  vars="$(jq -cn --arg teamId "$team_id" --arg projectId "$project_id" --arg label "$label_name" '{teamId:$teamId, projectId:$projectId, label:$label}')"
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
  # Lane fence: check before any Linear API call.
  local _object_class
  _object_class="$(_classify_label "$label_name")"
  _check_lane "add" "$_object_class" || return $?

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
  # Lane fence: check before any Linear API call.
  local _object_class
  _object_class="$(_classify_label "$label_name")"
  _check_lane "remove" "$_object_class" || return $?

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

get_comments() {
  # Emits a JSON array `[{id, body, createdAt}, ...]` in chronological
  # ascending order (oldest first), paginated to the most recent 50.
  # Downstream Verdict Handler scans forward for the fresh verdict marker
  # without another sort step.
  local ident="$1"
  [[ -n "$ident" ]] || die "get-comments: issue id required"
  local q='query($id: String!) { issue(id: $id) { comments(first: 50) { nodes { id body createdAt } } } }'
  local vars resp
  vars="$(jq -cn --arg id "$ident" '{id:$id}')"
  resp="$(linear_query "$q" "$vars")"
  jq -c '[.data.issue.comments.nodes[]? ] | sort_by(.createdAt)' <<<"$resp"
}

# Dedup gotcha for callers: a body whose normalized hash matches any of
# the last 10 normalized comments is silently suppressed. The two regexes
# below strip anything that varies *only* by timestamp or SHA — including
# 10-digit unix epochs and uuidgen output. To force a fresh post on a
# recurring body, embed a token that survives both regexes — e.g. a
# space-separated date ("2026-04-29 03:14:00Z", no literal T) or a 6-digit
# HHMMSS (under the 7-char SHA threshold).
# ENG-55: parse `<body>` from a flexible argv tail. Accepts:
#   * legacy positional: `<body>`
#   * `--body <text>` (or `--body -` to read from stdin)
#   * `--body=<text>`
#   * `--body-file <path>`
# Prints the resolved body to stdout. Caller checks for empty.
#
# Stdin is read only when `--body -` is explicitly requested. Bare positional
# bodies stay positional (no implicit stdin) to keep legacy callers stable.
# ENG-60-followup write-time guard. Rejects bodies that contain a legacy-shape
# pipeline marker (`<!-- pipeline-(stage-summary|rejection|halt|wait|decision|
# sig|metric|transition): ... -->`). Hand-rolled writers were the failure mode
# that Phase 3 missed: validators in bin/pipeline.sh only fire when callers go
# through `pipeline.sh event/decide`, so any direct add-comment that printf'd
# a marker body bypassed the closed registry. This guard closes that hole.
#
# Returns 0 (allow) on any non-legacy body. On a legacy match, prints a
# structured error to stderr and returns 14 (a fresh exit code added to
# common.sh::failure_outcome_for_exit as `legacy-marker-write`).
#
# `_reject_legacy_marker_body <caller> <body>`
_reject_legacy_marker_body() {
  local caller="$1" body="$2"
  local match
  match="$(grep -oE '<!-- pipeline-(stage-summary|rejection|rejection-target|halt|wait|decision|sig|metric|transition): [^>]+ -->' <<<"$body" 2>/dev/null | head -1 || true)"
  if [[ -n "$match" ]]; then
    printf 'linear.sh %s: body contains legacy-shape pipeline marker — rejected.\n' "$caller" >&2
    printf '            offending substring: %s\n' "$match" >&2
    printf '            use bin/pipeline.sh event/decide to emit verdicts/decisions/transitions,\n' >&2
    printf '            or the new `<!-- meta: <kind> ... -->` family for dedup/metrics.\n' >&2
    printf '            registry: bin/pipeline-events.json · vocab: docs/pipeline-vocabulary.md\n' >&2
    return 14
  fi
  return 0
}

_resolve_body_arg() {
  local body=""
  local got_flag=0
  while (( $# > 0 )); do
    case "$1" in
      --body-file)
        [[ -n "${2:-}" ]] || die "linear.sh: --body-file requires a path"
        [[ -f "$2" ]] || die "linear.sh: --body-file path not found: $2"
        body="$(cat "$2")"
        got_flag=1
        shift 2
        ;;
      --body-file=*)
        local p="${1#--body-file=}"
        [[ -f "$p" ]] || die "linear.sh: --body-file path not found: $p"
        body="$(cat "$p")"
        got_flag=1
        shift
        ;;
      --body)
        [[ $# -ge 2 ]] || die "linear.sh: --body requires a value (use - for stdin)"
        if [[ "$2" == "-" ]]; then
          body="$(cat)"
        else
          body="$2"
        fi
        got_flag=1
        shift 2
        ;;
      --body=*)
        body="${1#--body=}"
        got_flag=1
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        # Legacy positional body. Only honored if no flag form was seen and
        # this is the last remaining arg — we don't try to collapse multiple
        # positional args into a single body.
        if (( ! got_flag )) && (( $# == 1 )); then
          body="$1"
        fi
        shift
        ;;
    esac
  done
  printf '%s' "$body"
}

add_comment() {
  local ident="$1"; shift
  local body
  body="$(_resolve_body_arg "$@")"
  [[ -n "$body" ]] || die "add-comment: body is empty (received no --body, --body-file, or stdin via --body -)"
  _reject_legacy_marker_body "add-comment" "$body" || return $?
  # Lane fence: check before any Linear API call (including dry-run).
  local _comment_class
  _comment_class="$(_classify_comment_body "$body")"
  _check_lane "add" "$_comment_class" || return $?

  # ENG-87: auto-inject dispatch_id marker. Placement is load-bearing —
  # AFTER _check_lane (so the comment-class classification reflects the
  # caller's authoring intent; the marker is appended at the END so
  # _classify_comment_body's first-line-match is unchanged) and BEFORE
  # the dry-run short-circuit (so unit tests under PIPELINE_DRY_RUN=1
  # observe the injection). No-op when PIPELINE_DISPATCH_ID is unset
  # (operator-manual lane).
  body="$(_inject_dispatch_marker "$body")"

  if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
    log "[DRY_RUN] would comment on $ident: ${body:0:80}..."
    return 0
  fi

  # Pipeline-event markers (verdict, transition, decision) are append-only by
  # design — find_fresh_verdict's freshness floor depends on each emission
  # carrying a distinct createdAt. Hash-dedup against a prior identical body
  # silently breaks that contract: e.g. an agent retrying `verdict pass` after
  # an operator-resume would dedup against the pre-resume verdict, leaving
  # the freshness window empty and tripping `protocol-violation/no-marker`
  # (ENG-73). Skip dedup when the body carries any new-shape pipeline marker.
  if [[ "$body" == *'<!-- pipeline: '* ]]; then
    : # fall through to the post; verdict/transition/decision are append-only
  else

  # Normalize body for dedup: strip ISO timestamps + git SHAs so that
  # reworded-only-by-timestamp comments (ENG-14 TDD evidence pattern) dedup.
  local norm_body
  norm_body="$(printf '%s' "$body" \
    | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<TS>/g' \
    | sed -E 's/[0-9a-f]{7,40}/<SHA>/g')"
  local new_hash
  new_hash="$(printf '%s' "$norm_body" | shasum -a 256 | awk '{print $1}')"

  # Fetch last 10 comments, normalize, hash, compare.
  local q='query($id: String!) { issue(id: $id) { comments(first: 10, orderBy: updatedAt) { nodes { body } } } }'
  local vars resp
  vars="$(jq -cn --arg id "$ident" '{id:$id}')"
  resp="$(linear_query "$q" "$vars")"

  local dup_found=0
  while IFS= read -r b64; do
    [[ -z "$b64" ]] && continue
    local prev_body prev_norm prev_hash
    prev_body="$(printf '%s' "$b64" | base64 -d 2>/dev/null)"
    prev_norm="$(printf '%s' "$prev_body" \
      | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<TS>/g' \
      | sed -E 's/[0-9a-f]{7,40}/<SHA>/g')"
    prev_hash="$(printf '%s' "$prev_norm" | shasum -a 256 | awk '{print $1}')"
    if [[ "$prev_hash" == "$new_hash" ]]; then
      dup_found=1; break
    fi
  done < <(jq -r '.data.issue.comments.nodes[]? | .body | @base64' <<<"$resp")

  if (( dup_found == 1 )); then
    log "add-comment: duplicate suppressed on $ident (hash=${new_hash:0:12}...)"
    return 0
  fi
  fi  # close pipeline-marker bypass

  local issue_uuid
  issue_uuid="$(_resolve_issue_uuid "$ident")"
  local m='mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }'
  local mvars
  mvars="$(jq -cn --arg id "$issue_uuid" --arg body "$body" '{id:$id, body:$body}')"
  linear_query "$m" "$mvars" >/dev/null
  log "commented on $ident"
}

add_or_update_comment() {
  # $1 = sig (e.g., "halt/implement/ENG-14")
  # $2 = ident (e.g., "ENG-14")
  # $3+ = body, accepted via the same --body / --body-file / --body - / legacy
  #       positional shapes as add-comment (ENG-55).
  local sig="$1" ident="$2"; shift 2
  [[ -n "$sig" && -n "$ident" ]] \
    || die "add-or-update-comment: <sig> and <ident> required"
  local body
  body="$(_resolve_body_arg "$@")"
  [[ -n "$body" ]] \
    || die "add-or-update-comment: body is empty (received no --body, --body-file, or stdin via --body -)"
  _reject_legacy_marker_body "add-or-update-comment" "$body" || return $?

  # ENG-87: auto-inject dispatch_id marker. Same placement rationale as
  # add_comment — after the legacy-marker reject, before the dedup-marker
  # append. The dedup-append (line ~573) runs on the already-injected
  # body so both meta-markers coexist on the same comment. Idempotent
  # on re-apply.
  body="$(_inject_dispatch_marker "$body")"

  # ENG-60 vocabulary: write `<!-- meta: dedup key=... -->` (new shape).
  # Look up matches against the legacy `<!-- pipeline-sig: ... -->` shape too,
  # so in-flight issues whose comment threads were created under the legacy
  # writer continue to be updated in place rather than duplicated.
  local marker="<!-- meta: dedup key=$sig -->"
  local marker_legacy="<!-- pipeline-sig: $sig -->"
  if ! grep -qF -e "$marker" -e "$marker_legacy" <<<"$body"; then
    body+=$'\n\n'"$marker"
  fi

  if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
    log "[DRY_RUN] would upsert $sig on $ident: ${body:0:80}..."
    return 0
  fi

  local issue_uuid
  issue_uuid="$(_resolve_issue_uuid "$ident")"

  # Look for an existing comment carrying the sig (new or legacy shape).
  # ENG-111: also request `url` per node so the breadcrumb body (below) can
  # carry a Linear permalink to the canonical comment without a second
  # roundtrip. Missing `url` (schema change / null payload) degrades to the
  # URL-less breadcrumb shape — see body construction below.
  local q='query($id: String!) { issue(id: $id) { comments(first: 50, orderBy: updatedAt) { nodes { id body url } } } }'
  local vars resp existing_id
  vars="$(jq -cn --arg id "$ident" '{id:$id}')"
  resp="$(linear_query "$q" "$vars")"
  existing_id="$(jq -r --arg m "$marker" --arg l "$marker_legacy" \
    '[.data.issue.comments.nodes[]? | select(.body | contains($m) or contains($l)) | .id] | first // ""' <<<"$resp")"

  if [[ -n "$existing_id" ]]; then
    # ENG-63: when the existing comment's body (with any prior
    # `<!-- meta: reapplied at=… -->` line stripped) is byte-equal to the
    # caller's body (also stripped), append a fresh footer so Linear's
    # updatedAt advances and operators see an inspectable signal of the
    # latest re-apply moment. The strip regex is line-anchored (^…$) to
    # avoid matching a quoted mention of the marker shape inside fenced
    # prose.
    # ENG-111: track whether this is an identical-body re-apply so the
    # breadcrumb post (below) fires ONLY on the body-change path.
    local is_identical_reapply=0
    local existing_body strip_re existing_norm new_norm now_iso
    existing_body="$(jq -r --arg id "$existing_id" \
      '[.data.issue.comments.nodes[]? | select(.id == $id) | .body] | first // ""' \
      <<<"$resp")"
    # ENG-87 review-iter-7 Critical 4: extend the strip to ALSO remove
    # `<!-- meta: dispatch id=… -->` lines. Post-ENG-87 every comment body
    # carries an auto-injected dispatch marker (line-anchored, last
    # line of body); a re-apply across two different dispatches now has
    # different markers in existing vs new body, so the byte-equal arm
    # would never fire and ENG-63's reapplied-footer + comment-reapplied
    # metric signal would be silently absent for every halt re-apply
    # post-cutover. Stripping both noise lines preserves ENG-63's
    # byte-equal-modulo-meta-noise normalisation under dispatch-id
    # rotation.
    strip_re='/^<!-- meta: (reapplied at=|dispatch id=)[^>]* -->$/d'
    existing_norm="$(printf '%s' "$existing_body" | sed -E "$strip_re")"
    new_norm="$(printf '%s' "$body" | sed -E "$strip_re")"
    # Defensive trailing-newline trim. Shell `$()` already strips trailing
    # newlines from the cmdsub above; the explicit trim documents intent and
    # guards a refactor that loses the cmdsub property.
    existing_norm="${existing_norm%$'\n'}"
    new_norm="${new_norm%$'\n'}"
    if [[ "$existing_norm" == "$new_norm" && -n "$existing_norm" ]]; then
      is_identical_reapply=1
      now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      body="${new_norm}"$'\n'"<!-- meta: reapplied at=${now_iso} -->"
      bash "$SCRIPT_DIR/metrics.sh" comment-reapplied "$ident" "" \
        "reapplied" 0 || true
    fi
    local mu='mutation($id: String!, $body: String!) { commentUpdate(id: $id, input: { body: $body }) { success } }'
    local mvars
    mvars="$(jq -cn --arg id "$existing_id" --arg body "$body" '{id:$id, body:$body}')"
    linear_query "$mu" "$mvars" >/dev/null
    log "updated-in-place $sig on $ident (comment=$existing_id)"

    # ENG-111: body-change re-emission posts a sig-less chronological
    # breadcrumb so a top-down scan of the Linear feed surfaces the re-fire
    # (the canonical's createdAt is the FIRST emission's moment and stays
    # fixed across commentUpdate calls). Identical-body re-applies stay
    # silent at the breadcrumb level — ENG-63's rotating footer is the
    # canonical signal for that mode.
    if (( is_identical_reapply == 0 )); then
      local canonical_url breadcrumb_body prose trailer
      canonical_url="$(jq -r --arg id "$existing_id" \
        '[.data.issue.comments.nodes[]? | select(.id == $id) | .url] | first // ""' \
        <<<"$resp")"
      prose=$'Re-emitted (body changed) under sig `'"$sig"$'`. Canonical comment was updated in place; this pointer marks the moment.'
      trailer=$'<!-- meta: breadcrumb sig='"$sig"$' comment_id='"$existing_id"$' -->'
      if [[ -n "$canonical_url" ]]; then
        breadcrumb_body="${prose}"$'\n'"${canonical_url}"$'\n\n'"${trailer}"
      else
        breadcrumb_body="${prose}"$'\n\n'"${trailer}"
      fi
      # add_comment runs the lane fence + dispatch-id auto-injection
      # + last-10 hash dedup. Non-fatal on failure — the canonical
      # update has already succeeded and is the load-bearing call.
      if add_comment "$ident" --body "$breadcrumb_body"; then
        bash "$SCRIPT_DIR/metrics.sh" comment-breadcrumb "$ident" "" \
          "posted" 0 || true
      else
        log "add-or-update-comment: breadcrumb post failed for $sig on $ident (non-fatal)"
      fi
    fi
  else
    local mc='mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }'
    local mcvars
    mcvars="$(jq -cn --arg id "$issue_uuid" --arg body "$body" '{id:$id, body:$body}')"
    linear_query "$mc" "$mcvars" >/dev/null
    log "created $sig on $ident"
  fi
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
    add-or-update-comment) add_or_update_comment "$@" ;;
    stage-of)               stage_of "$@" ;;
    all-stage-labels)       all_stage_labels "$@" ;;
    has-label)              has_label "$@" ;;
    has-comment-since)      has_comment_since "$@" ;;
    get-comments)           get_comments "$@" ;;
    refresh-cache)          refresh_cache ;;
    *)                      die "unknown command: $cmd (see linear.sh header)" ;;
  esac
}

# Only run main when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
