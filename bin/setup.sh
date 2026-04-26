#!/usr/bin/env bash
# One-stop onboarding for a target repo. Walks every prerequisite phase
# idempotently. See docs/brainstorms/2026-04-26-multi-project-harness.md §5.2
# for the phase contract.
#
# Usage:
#   bash bin/setup.sh /path/to/target [phase]
#
# With no phase: runs all unsatisfied phases 1-11 in order.
# With <phase>: jumps to that phase only. Special phases:
#   validate      - re-runs offline checks (health-check shortcut)
#   migrate       - one-shot upgrade for an existing single-project install

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh requires TARGET_REPO and (post-bootstrap) project.slug. setup.sh
# runs before slug-freeze on a fresh project, so set the bootstrap flag for
# our own sourcing.
TARGET_REPO="${TARGET_REPO:-${1:-}}"
[[ -n "$TARGET_REPO" && -d "$TARGET_REPO" ]] || {
  printf 'usage: bash bin/setup.sh /path/to/target [phase]\n' >&2
  exit 64
}
export TARGET_REPO TWINNING_BOOTSTRAPPING=1
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=setup-helpers.sh
source "$SCRIPT_DIR/setup-helpers.sh"

PHASE="${2:-}"
SECRETS_FILE="$HARNESS_CONFIG_DIR/secrets.env"
ENV_FILE="$TARGET_CONFIG_DIR/.env.local"

# ── Phase 1: workspace ────────────────────────────────────────────────
phase_workspace() {
  print_phase_header "workspace"
  mkdir -p "$TARGET_CONFIG_DIR" "$TARGET_CONFIG_DIR/schemas"
  mkdir -p "$HARNESS_CONFIG_DIR" && chmod 0700 "$HARNESS_CONFIG_DIR"
  if [[ ! -f "$CONFIG" ]]; then
    atomic_write_file "$CONFIG" 0644 <<'JSON'
{
  "linear": {},
  "orchestrator": {}
}
JSON
    log "wrote scaffolded $CONFIG"
  else
    log "$CONFIG already present"
  fi
  log "workspace ready"
}

is_workspace_done() {
  [[ -d "$TARGET_CONFIG_DIR/schemas" && -d "$HARNESS_CONFIG_DIR" && -f "$CONFIG" ]]
}

# ── Phase 2: linear-auth ──────────────────────────────────────────────
phase_linear_auth() {
  print_phase_header "linear-auth"
  local existing
  existing="$(read_env_file "$SECRETS_FILE" LINEAR_API_KEY | cut -d= -f2-)"
  local key="$existing"
  if [[ -z "$key" ]]; then
    key="$(prompt_secret 'Linear personal API key (Settings → API)')"
  fi
  [[ -n "$key" ]] || die "linear-auth: empty LINEAR_API_KEY"

  # Verify with viewer query.
  local resp http_code
  resp="$(curl -sS -w '\n%{http_code}' -X POST 'https://api.linear.app/graphql' \
    -H "Authorization: $key" \
    -H 'Content-Type: application/json' \
    --data '{"query":"{ viewer { id name } }"}' 2>/dev/null || true)"
  http_code="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"
  [[ "$http_code" =~ ^2 ]] || die "linear-auth: HTTP $http_code from Linear (resp: $resp)"
  jq -e '.data.viewer.id' >/dev/null 2>&1 <<<"$resp" \
    || die "linear-auth: Linear rejected the key (resp: $resp)"
  log "linear-auth: viewer=$(jq -r '.data.viewer.name' <<<"$resp")"

  write_env_file "$SECRETS_FILE" 0600 "LINEAR_API_KEY=$key"
  log "linear-auth: wrote $SECRETS_FILE"
}

is_linear_auth_done() {
  local k
  k="$(read_env_file "$SECRETS_FILE" LINEAR_API_KEY | cut -d= -f2-)"
  [[ -n "$k" ]] || return 1
  # Verify the cached key still works (cheap call).
  local resp http_code
  resp="$(curl -sS -w '\n%{http_code}' -X POST 'https://api.linear.app/graphql' \
    -H "Authorization: $k" -H 'Content-Type: application/json' \
    --data '{"query":"{ viewer { id } }"}' 2>/dev/null || true)"
  http_code="${resp##*$'\n'}"
  [[ "$http_code" =~ ^2 ]] || return 1
  jq -e '.data.viewer.id' >/dev/null 2>&1 <<<"${resp%$'\n'*}"
}

# ── Phase 3: linear-identity ──────────────────────────────────────────
_linear_post() {
  local query="$1" vars="${2:-{\}}"
  local key resp
  key="$(read_env_file "$SECRETS_FILE" LINEAR_API_KEY | cut -d= -f2-)"
  [[ -n "$key" ]] || die "linear-identity: secrets.env LINEAR_API_KEY missing"
  local body
  body="$(jq -cn --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}')"
  resp="$(curl -sS -X POST 'https://api.linear.app/graphql' \
    -H "Authorization: $key" -H 'Content-Type: application/json' \
    --data "$body")"
  printf '%s' "$resp"
}

phase_linear_identity() {
  print_phase_header "linear-identity"
  local cur_team cur_proj
  cur_team="$(jq -r '.linear.team_id // empty' "$CONFIG")"
  cur_proj="$(jq -r '.linear.project_id // empty' "$CONFIG")"

  # Team selection.
  if [[ -z "$cur_team" ]]; then
    local teams_json team_count
    teams_json="$(_linear_post '{ teams(first: 50) { nodes { id key name } } }')"
    team_count="$(jq -r '.data.teams.nodes | length' <<<"$teams_json")"
    [[ "$team_count" -gt 0 ]] || die "linear-identity: viewer has no teams"
    printf '\nAvailable Linear teams:\n' >&2
    jq -r '.data.teams.nodes | to_entries[] | "  [\(.key + 1)] \(.value.key) — \(.value.name) (\(.value.id))"' <<<"$teams_json" >&2
    local pick
    printf 'Pick team [1-%d]: ' "$team_count" >&2
    read -r pick
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= team_count )) \
      || die "linear-identity: invalid choice: $pick"
    cur_team="$(jq -r ".data.teams.nodes[$((pick - 1))].id" <<<"$teams_json")"
  fi

  # Project selection.
  if [[ -z "$cur_proj" ]]; then
    local projs_json proj_count
    projs_json="$(_linear_post \
      'query($t: String!) { team(id: $t) { projects(first: 50) { nodes { id name } } } }' \
      "$(jq -cn --arg t "$cur_team" '{t:$t}')")"
    proj_count="$(jq -r '.data.team.projects.nodes | length' <<<"$projs_json")"
    if (( proj_count == 0 )); then
      die "linear-identity: team has no projects. Create one in Linear first, then re-run this phase."
    fi
    printf '\nProjects in this team:\n' >&2
    jq -r '.data.team.projects.nodes | to_entries[] | "  [\(.key + 1)] \(.value.name) (\(.value.id))"' <<<"$projs_json" >&2
    local pick
    printf 'Pick project [1-%d]: ' "$proj_count" >&2
    read -r pick
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= proj_count )) \
      || die "linear-identity: invalid choice: $pick"
    cur_proj="$(jq -r ".data.team.projects.nodes[$((pick - 1))].id" <<<"$projs_json")"
  fi

  # Persist.
  local tmp; tmp="$(mktemp)"
  jq --arg t "$cur_team" --arg p "$cur_proj" \
    '.linear.team_id = $t | .linear.project_id = $p' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
  log "linear-identity: team_id=$cur_team project_id=$cur_proj"
}

is_linear_identity_done() {
  [[ -n "$(jq -r '.linear.team_id // empty' "$CONFIG")" \
     && -n "$(jq -r '.linear.project_id // empty' "$CONFIG")" ]]
}

# ── Phase 4: linear-schema ────────────────────────────────────────────
phase_linear_schema() {
  print_phase_header "linear-schema"
  # secrets.env vars must be in env for setup-labels.sh / linear.sh refresh-cache.
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  set +a
  log "linear-schema: invoking bin/setup-labels.sh"
  bash "$SCRIPT_DIR/setup-labels.sh"
  log "linear-schema: invoking bin/linear.sh refresh-cache"
  bash "$SCRIPT_DIR/linear.sh" refresh-cache
}

is_linear_schema_done() {
  [[ -f "$IDS_CACHE" ]] || return 1
  # All 15 pipeline labels must resolve.
  local missing=0 label
  for label in stage:brainstorming stage:planning stage:implementing stage:ui \
    stage:reviewing stage:qa stage:building stage:released \
    pipeline:paused pipeline:supersede pipeline:extend pipeline:ignore \
    pipeline:reviewed pipeline:knowledge-reviewed pipeline:rule-reviewed; do
    local id; id="$(jq -r ".labels[\"$label\"] // empty" "$IDS_CACHE")"
    [[ -n "$id" ]] || { missing=1; break; }
  done
  (( missing == 0 ))
}

# Phase dispatch.
ALL_PHASES=(workspace linear-auth linear-identity linear-schema)
run_phase_or_skip() {
  local phase="$1" check_fn run_fn
  check_fn="is_${phase//-/_}_done"
  run_fn="phase_${phase//-/_}"
  if declare -F "$check_fn" >/dev/null && "$check_fn"; then
    log "phase $phase: already satisfied (skip)"
    return 0
  fi
  "$run_fn"
}

main() {
  if [[ -n "$PHASE" ]]; then
    declare -F "phase_${PHASE//-/_}" >/dev/null \
      || { printf 'unknown phase: %s\n' "$PHASE" >&2; exit 64; }
    "phase_${PHASE//-/_}"
    return
  fi
  local p
  for p in "${ALL_PHASES[@]}"; do
    run_phase_or_skip "$p"
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
