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
#   linear.sh add-comment <ENG-n> --sig <cat>/<stage>/<issue> --body <body>
#     # append-only ledger tag: chokepoint suffixes /d<NNNN> from
#     # PIPELINE_DISPATCH_ID and appends <!-- meta: dedup key=… -->
#     # for operator grep (ENG-150 D-006); hash dedup skipped on --sig.
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
# on caller-embedded markers). Operator-lane writes (env unset)
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

# ENG-151: Render the canonical two-line comment header.
#
# `_render_event_header <ident> <event_type> <summary>`
#
# Reads PIPELINE_STAGE, PIPELINE_DISPATCH_ID, PIPELINE_WRITER from the
# env.  Emits exactly two lines on stdout (no trailing newline):
#
#   [<ident> · <stage-or-dash> · <dispatch-tail-or-dash> · <iso-ts> · <actor>]
#   <event_type> — <summary>
#
# Failure mode (D-006): when actor == agent AND PIPELINE_DISPATCH_ID is
# empty OR PIPELINE_STAGE is empty, returns 15 with a structured stderr
# diagnostic.  Routed by failure_outcome_for_exit as
# `header-missing-inputs`.  Operator/classify/scope-check lanes degrade
# to `-` placeholders when env is absent (legitimate during boot/manual
# CLI use); human lane bypasses the helper entirely upstream (D-005).
_render_event_header() {
  local ident="$1" event_type="$2" summary="$3"
  local stage="${PIPELINE_STAGE-}"
  local dispatch_id="${PIPELINE_DISPATCH_ID-}"
  local actor="${PIPELINE_WRITER:-orchestrator}"
  if [[ "$actor" == "agent" && ( -z "$dispatch_id" || -z "$stage" ) ]]; then
    printf 'linear.sh: agent-lane comment missing header inputs (PIPELINE_DISPATCH_ID=%q PIPELINE_STAGE=%q). Set both env vars or change the lane.\n' \
      "$dispatch_id" "$stage" >&2
    return 15
  fi
  local stage_render="${stage:--}"
  local dispatch_tail
  if [[ -z "$dispatch_id" ]]; then
    dispatch_tail='-'
  elif [[ "$dispatch_id" =~ -(d[0-9]+)$ ]]; then
    dispatch_tail="${BASH_REMATCH[1]}"
  else
    # Malformed (regex no-match, non-empty): emit verbatim so the bug
    # is operator-visible rather than silently swallowed (visible-bug
    # surface — caught at re-spec, not at the chokepoint).
    dispatch_tail="$dispatch_id"
  fi
  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s · %s · %s · %s · %s]\n%s — %s' \
    "$ident" "$stage_render" "$dispatch_tail" "$now_iso" "$actor" \
    "$event_type" "$summary"
}

# ENG-151: Derive `<event-type>\t<summary>` from a comment body + optional sig.
#
# `_derive_event_type_and_summary <body> [<sig>]`
#
# Priority ladder (first match wins):
#   P1: sig matches a known dedup-marker class.  Stage segment of the
#       sig (when present) is interpolated into the summary.
#   P2: body carries a `<!-- pipeline: ... -->` marker (verdict /
#       transition / decision).  Token extracted from k=v pairs.
#   P3: body carries a `<!-- meta: ... -->` marker (metric / breadcrumb
#       / forensic).
#   P4: fallback.  Event-type=COMMENT, summary=first non-blank
#       non-marker line truncated to 80 chars.
#
# Output: single line `<event-type>\t<summary>` with trailing newline
# (so `IFS=$'\t' read -r` works at the caller).
_derive_event_type_and_summary() {
  local body="$1" sig="${2:-}"
  local mid=''
  if [[ -n "$sig" ]]; then
    # Extract stage segment: `<class>/<stage>/<ident>` → `<stage>`;
    # flat `<class>/<ident>` → empty.  The stage segment is the slash-
    # delimited middle when the sig has 3 segments AND the middle is
    # NOT itself an issue identifier (ENG-N).
    case "$sig" in
      */*/*)
        mid="${sig#*/}"
        mid="${mid%/*}"
        case "$mid" in
          ENG-*) mid='' ;;
        esac
        ;;
    esac
    case "$sig" in
      completion/*)
        if [[ -n "$mid" ]]; then
          printf 'COMPLETION\tstage %s summary\n' "$mid"
        else
          printf 'COMPLETION\tstage summary\n'
        fi
        return 0
        ;;
      tdd-evidence/*)
        if [[ -n "$mid" ]]; then
          printf 'TDD-EVIDENCE\tstage %s\n' "$mid"
        else
          printf 'TDD-EVIDENCE\tre-emission\n'
        fi
        return 0
        ;;
      last-review-state/*)
        printf 'LAST-REVIEW-STATE\tcanonical review state\n'
        return 0
        ;;
      scope-approval/*)
        if [[ -n "$mid" ]]; then
          printf 'SCOPE-APPROVAL\t%s\n' "$mid"
        else
          printf 'SCOPE-APPROVAL\tapproval request\n'
        fi
        return 0
        ;;
      halt/*)
        if [[ -n "$mid" ]]; then
          printf 'HALT\tstage %s halt\n' "$mid"
        else
          printf 'HALT\thalt\n'
        fi
        return 0
        ;;
      wait/*)
        if [[ -n "$mid" ]]; then
          printf 'WAIT\tstage %s wait\n' "$mid"
        else
          printf 'WAIT\twait\n'
        fi
        return 0
        ;;
      worktree-mutation/*)
        printf 'WORKTREE-MUTATION\tworktree mutation\n'
        return 0
        ;;
      protocol-violation/*)
        printf 'PROTOCOL-VIOLATION\tprotocol violation\n'
        return 0
        ;;
      retry-pending/*)
        printf 'RETRY-PENDING\tretry pending\n'
        return 0
        ;;
    esac
  fi
  # P2: pipeline-marker derivation.
  if [[ "$body" == *'<!-- pipeline: verdict result=pass'* ]]; then
    local _stage
    _stage="$(printf '%s' "$body" | grep -oE 'stage=[a-z]+' | head -1 | cut -d= -f2)"
    printf 'PASS\tstage %s complete\n' "${_stage:-?}"
    return 0
  fi
  if [[ "$body" == *'<!-- pipeline: verdict result=fail'* ]]; then
    local _target
    _target="$(printf '%s' "$body" | grep -oE 'target=[a-z]+' | head -1 | cut -d= -f2)"
    printf 'FAIL\ttarget %s\n' "${_target:-?}"
    return 0
  fi
  if [[ "$body" == *'<!-- pipeline: verdict result=halt'* ]]; then
    local _reason
    _reason="$(printf '%s' "$body" | grep -oE 'reason=[a-z-]+' | head -1 | cut -d= -f2)"
    printf 'HALT\t%s\n' "${_reason:-?}"
    return 0
  fi
  if [[ "$body" == *'<!-- pipeline: verdict result=wait'* ]]; then
    local _reason
    _reason="$(printf '%s' "$body" | grep -oE 'reason=[a-z-]+' | head -1 | cut -d= -f2)"
    printf 'WAIT\t%s\n' "${_reason:-?}"
    return 0
  fi
  if [[ "$body" == *'<!-- pipeline: verdict result=pivot'* ]]; then
    local _target
    _target="$(printf '%s' "$body" | grep -oE 'target=[a-z]+' | head -1 | cut -d= -f2)"
    printf 'PIVOT\ttarget %s\n' "${_target:-?}"
    return 0
  fi
  if [[ "$body" == *'<!-- pipeline: transition '* ]]; then
    local _from _to
    _from="$(printf '%s' "$body" | grep -oE 'from=[a-z]+' | head -1 | cut -d= -f2)"
    _to="$(printf '%s' "$body" | grep -oE 'to=[a-z]+' | head -1 | cut -d= -f2)"
    printf 'TRANSITION\t%s → %s\n' "${_from:-?}" "${_to:-?}"
    return 0
  fi
  if [[ "$body" == *'<!-- pipeline: decision '* ]]; then
    local _action _gate
    _action="$(printf '%s' "$body" | grep -oE 'action=[a-z-]+' | head -1 | cut -d= -f2)"
    _gate="$(printf '%s' "$body" | grep -oE 'gate=[a-z-]+' | head -1 | cut -d= -f2)"
    if [[ -n "$_gate" ]]; then
      printf 'DECISION\t%s (gate=%s)\n' "${_action:-?}" "$_gate"
    else
      printf 'DECISION\t%s\n' "${_action:-?}"
    fi
    return 0
  fi
  # P3: meta-marker derivation.
  if [[ "$body" =~ \<\!--\ meta:\ metric\ name=([a-z_-]+) ]]; then
    printf 'COUNTER-BUMP\t%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$body" =~ \<\!--\ meta:\ breadcrumb\ sig=([^\ ]+) ]]; then
    printf 'BREADCRUMB\tre-emit of %s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$body" =~ \<\!--\ meta:\ forensic\ kind=([a-z-]+) ]]; then
    printf 'FORENSIC\t%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  # P4: prose fallback.
  local first_prose
  first_prose="$(grep -m1 -v -e '^<!--' -e '^$' <<<"$body" | head -c 80 || true)"
  printf 'COMMENT\t%s\n' "${first_prose:-(no body)}"
}

# IMPORTANT (ENG-151 D-011): must be called on the un-headered body.
# The ENG-151 header line (`[ENG-N · …]`) is auto-prepended by the
# chokepoint AFTER this classifier returns. If the order is ever
# reversed, every comment becomes `other_comment` and the
# `add transition_comment` lane fence silently admits agent-lane
# transition writes. Order is asserted indirectly by H-012 in
# bin/linear-test.sh (agent-lane hand-rolled bracket → exit 14).
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

  # ENG-150 D-003: pull --sig out of args BEFORE _resolve_body_arg so
  # the body resolver sees only its native flag set. Empty sig =
  # caller did not opt into the append-only ledger contract; behaviour
  # is bit-identical to today's add_comment (no marker append, hash
  # dedup runs).
  local sig=""
  local _rest=()
  while (( $# > 0 )); do
    case "$1" in
      --sig)
        [[ $# -ge 2 ]] || die "linear.sh add-comment: --sig requires a value"
        sig="$2"; shift 2
        ;;
      --sig=*)
        sig="${1#--sig=}"; shift
        ;;
      *)
        _rest+=("$1"); shift
        ;;
    esac
  done
  if (( ${#_rest[@]} > 0 )); then
    set -- "${_rest[@]}"
  else
    set --
  fi

  # ENG-150 D-007 sig validation: reject characters that would corrupt
  # the marker shape (newline splits the marker over multiple lines;
  # the literal `-->` closes the HTML comment early). Bash strings
  # cannot carry NUL bytes (C string limit) so no NUL check is needed.
  if [[ -n "$sig" ]]; then
    if [[ "$sig" == *$'\n'* || "$sig" == *'-->'* ]]; then
      die "linear.sh add-comment: --sig contains illegal characters (newline / -->)"
    fi
  fi

  local body
  body="$(_resolve_body_arg "$@")"
  [[ -n "$body" ]] || die "add-comment: body is empty (received no --body, --body-file, or stdin via --body -)"
  _reject_legacy_marker_body "add-comment" "$body" || return $?
  # Lane fence: check before any Linear API call (including dry-run).
  local _comment_class
  _comment_class="$(_classify_comment_body "$body")"
  _check_lane "add" "$_comment_class" || return $?

  # ENG-151: auto-prepend bracketed header + event-type/summary line.
  # Placement: AFTER lane fence (so classifier reads un-headered body),
  # BEFORE dispatch-id auto-inject (so footer reads below header), BEFORE
  # the dry-run short-circuit (so unit tests observe the injection).
  # human lane bypasses (D-005); agent lane with hand-rolled header
  # rejected (D-009-b); agent lane with missing dispatch context fails
  # via _render_event_header rc=15 (D-006).
  case "${PIPELINE_WRITER:-orchestrator}" in
    human) ;;
    *)
      if [[ "${PIPELINE_WRITER:-orchestrator}" == "agent" ]]; then
        local _first_nonblank
        _first_nonblank="$(printf '%s' "$body" | grep -m1 '[^ ]' || true)"
        _first_nonblank="$(printf '%s' "$_first_nonblank" | sed 's/^[[:space:]]*//')"
        if [[ "$_first_nonblank" =~ ^\[ENG-[0-9A-Z]+\ · ]]; then
          printf 'linear.sh add-comment: agent-lane comment carries hand-rolled header line — rejected.\n            header line is auto-prepended by the chokepoint; do not emit it manually.\n' >&2
          return 14
        fi
      fi
      local _event_type _summary _header
      IFS=$'\t' read -r _event_type _summary < <(_derive_event_type_and_summary "$body" "$sig")
      _header="$(_render_event_header "$ident" "$_event_type" "$_summary")" || return $?
      body="${_header}"$'\n\n'"${body}"
      ;;
  esac

  # ENG-87: auto-inject dispatch_id marker. Placement is load-bearing —
  # AFTER _check_lane (so the comment-class classification reflects the
  # caller's authoring intent; the marker is appended at the END so
  # _classify_comment_body's first-line-match is unchanged) and BEFORE
  # the dry-run short-circuit (so unit tests under PIPELINE_DRY_RUN=1
  # observe the injection). No-op when PIPELINE_DISPATCH_ID is unset
  # (operator-manual lane).
  body="$(_inject_dispatch_marker "$body")"

  # ENG-150 D-003 + D-007a: when --sig set, defensively strip any
  # caller-embedded `<!-- meta: dedup key=... -->` line (prevents the
  # chokepoint's appended marker from becoming the SECOND such line on
  # the wire when an agent stage-summary quoted a fixture body), then
  # suffix with /d<NNNN> from PIPELINE_DISPATCH_ID and append the
  # canonical dedup marker.
  if [[ -n "$sig" ]]; then
    body="$(printf '%s' "$body" | sed -E '/^<!-- meta: dedup key=.* -->$/d')"
    local dispatch_seq=""
    if [[ -n "${PIPELINE_DISPATCH_ID-}" ]]; then
      dispatch_seq="${PIPELINE_DISPATCH_ID##*-}"
    fi
    local full_sig="${sig}${dispatch_seq:+/${dispatch_seq}}"
    body+=$'\n\n'"<!-- meta: dedup key=${full_sig} -->"
  fi

  if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
    # ENG-151: window widened from 80 → 400.  Post-header bodies open
    # with ~60-byte bracket + event-type line; the legacy 80-char
    # window hid every marker that landed in the body proper.
    log "[DRY_RUN] would comment on $ident: ${body:0:400}..."
    return 0
  fi

  # Pipeline-event markers (verdict, transition, decision) are append-only by
  # design — find_fresh_verdict's freshness floor depends on each emission
  # carrying a distinct createdAt. Hash-dedup against a prior identical body
  # silently breaks that contract: e.g. an agent retrying `verdict pass` after
  # an operator-resume would dedup against the pre-resume verdict, leaving
  # the freshness window empty and tripping `protocol-violation/no-marker`
  # (ENG-73). Skip dedup when the body carries any new-shape pipeline marker.
  # ENG-150 D-007: also skip on any caller that passed --sig (declaring
  # append-only ledger semantics). The two checks are independent —
  # verdict posts via bin/pipeline.sh::cmd_event_verdict don't pass --sig
  # but do carry `<!-- pipeline: verdict ... -->` markers; ledger posts
  # via D-008 don't carry pipeline markers but DO pass --sig.
  if [[ "$body" == *'<!-- pipeline: '* ]] || [[ -n "$sig" ]]; then
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
