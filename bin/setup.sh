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

# ── Phase 5: slug-freeze ──────────────────────────────────────────────
phase_slug_freeze() {
  print_phase_header "slug-freeze"
  local existing; existing="$(jq -r '.project.slug // empty' "$CONFIG")"
  if [[ -n "$existing" ]]; then
    log "slug-freeze: project.slug already frozen as '$existing'"
    _slug_freeze_write_sentinel "$existing"
    return 0
  fi

  [[ -f "$IDS_CACHE" ]] || die "slug-freeze: $IDS_CACHE missing — run linear-schema phase first"
  local proj_name
  proj_name="$(jq -r '.project.name // empty' "$IDS_CACHE")"
  [[ -n "$proj_name" ]] || die "slug-freeze: linear-ids.json::.project.name is empty — re-run linear-schema with the correct project_id"

  local slug
  slug="$(slugify_project_name "$proj_name")" || die "slug-freeze: '$proj_name' did not produce a valid slug. Rename the project in Linear or pre-set project.slug in config.json manually."

  # Collision check.
  local sentinel="$HARNESS_STATE_DIR/$slug/target-repo"
  if [[ -f "$sentinel" ]]; then
    local recorded; recorded="$(cat "$sentinel")"
    if [[ "$recorded" != "$TARGET_REPO" ]]; then
      die "slug-freeze: slug '$slug' already in use by $recorded (sentinel: $sentinel). Rename the Linear project or contact the operator."
    fi
  fi

  local tmp; tmp="$(mktemp)"
  jq --arg s "$slug" '.project = (.project // {}) | .project.slug = $s' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
  log "slug-freeze: project.slug='$slug' frozen in $CONFIG"

  _slug_freeze_write_sentinel "$slug"
}

_slug_freeze_write_sentinel() {
  local slug="$1"
  local sentinel="$HARNESS_STATE_DIR/$slug/target-repo"
  mkdir -p "$(dirname "$sentinel")"
  printf '%s\n' "$TARGET_REPO" > "$sentinel"
  log "slug-freeze: wrote sentinel $sentinel"
  mkdir -p "$HARNESS_ROOT/learned-rules/$slug"
  log "slug-freeze: ensured $HARNESS_ROOT/learned-rules/$slug/ exists"
}

is_slug_freeze_done() {
  local slug; slug="$(jq -r '.project.slug // empty' "$CONFIG")"
  [[ -n "$slug" ]] || return 1
  [[ -f "$HARNESS_STATE_DIR/$slug/target-repo" ]] || return 1
}

# ── Phase 6: github-app ───────────────────────────────────────────────
phase_github_app() {
  print_phase_header "github-app"
  cat >&2 <<'TXT'
GitHub App setup
----------------
1. If you don't already have a "twinning-pipeline-bot" GitHub App, create one at:
     https://github.com/settings/apps/new
   Required permissions: Contents=Read+Write, Pull requests=Read+Write,
                         Issues=Read+Write, Metadata=Read.
   Webhook: not required.
2. After creation, install the App on your target repo via:
     https://github.com/settings/installations
   Note the Installation ID (numeric, in the install URL).
3. Generate a private key from the App's settings page; download the .pem.

TXT
  local app_id install_id pem_src pem_dest
  app_id="$(read_env_file "$SECRETS_FILE" GH_APP_ID | cut -d= -f2-)"
  if [[ -z "$app_id" ]]; then
    printf 'GitHub App ID (numeric): ' >&2
    read -r app_id
    [[ "$app_id" =~ ^[0-9]+$ ]] || die "github-app: invalid App ID: $app_id"
  fi
  install_id="$(read_env_file "$ENV_FILE" GH_APP_INSTALLATION_ID | cut -d= -f2-)"
  if [[ -z "$install_id" ]]; then
    printf 'GitHub App Installation ID (numeric, per-repo): ' >&2
    read -r install_id
    [[ "$install_id" =~ ^[0-9]+$ ]] || die "github-app: invalid Installation ID: $install_id"
  fi
  pem_dest="$HARNESS_CONFIG_DIR/github-app.pem"
  if [[ ! -f "$pem_dest" ]]; then
    printf 'Path to private key .pem (will be moved to %s): ' "$pem_dest" >&2
    read -r pem_src
    [[ -f "$pem_src" ]] || die "github-app: file not found: $pem_src"
    cp "$pem_src" "$pem_dest"
    chmod 0600 "$pem_dest"
    log "github-app: copied $pem_src -> $pem_dest (0600)"
  fi

  write_env_file "$SECRETS_FILE" 0600 \
    "GH_APP_ID=$app_id" \
    "GH_APP_PRIVATE_KEY_PATH=$pem_dest"
  write_env_file "$ENV_FILE" 0600 \
    "GH_APP_INSTALLATION_ID=$install_id"

  # Verify by minting a token.
  set -a; source "$SECRETS_FILE"; set +a
  GH_APP_INSTALLATION_ID="$install_id" \
    bash "$SCRIPT_DIR/gh-app-token.sh" >/dev/null \
    || die "github-app: gh-app-token.sh failed — check App permissions and Installation ID"
  log "github-app: token minted successfully"
}

is_github_app_done() {
  local a p i
  a="$(read_env_file "$SECRETS_FILE" GH_APP_ID | cut -d= -f2-)"
  p="$(read_env_file "$SECRETS_FILE" GH_APP_PRIVATE_KEY_PATH | cut -d= -f2-)"
  i="$(read_env_file "$ENV_FILE" GH_APP_INSTALLATION_ID | cut -d= -f2-)"
  [[ -n "$a" && -n "$p" && -n "$i" && -f "$p" ]]
}

# ── Phase 7: gh-cli ───────────────────────────────────────────────────
phase_gh_cli() {
  print_phase_header "gh-cli"
  if gh auth status >/dev/null 2>&1; then
    log "gh-cli: already authenticated"
    return 0
  fi
  cat >&2 <<'TXT'
gh CLI is not authenticated. The release-watcher in run-local.sh uses
`gh release list` to detect new releases.
Run in a separate terminal:    gh auth login
Press ENTER here when done...
TXT
  read -r _
  gh auth status >/dev/null 2>&1 || die "gh-cli: still not authenticated"
}

is_gh_cli_done() { gh auth status >/dev/null 2>&1; }

# ── Phase 8: slack (optional) ─────────────────────────────────────────
phase_slack() {
  print_phase_header "slack"
  local existing
  existing="$(read_env_file "$SECRETS_FILE" PIPELINE_SLACK_WEBHOOK_URL | cut -d= -f2-)"
  if [[ -n "$existing" ]]; then
    log "slack: PIPELINE_SLACK_WEBHOOK_URL already set"
    return 0
  fi
  printf 'Slack incoming webhook URL (blank to skip): ' >&2
  local url; read -r url
  if [[ -z "$url" ]]; then
    log "slack: skipped (slack.sh will no-op)"
    return 0
  fi
  [[ "$url" =~ ^https://hooks.slack.com/ ]] \
    || die "slack: URL must start with https://hooks.slack.com/"
  write_env_file "$SECRETS_FILE" 0600 "PIPELINE_SLACK_WEBHOOK_URL=$url"
  log "slack: webhook persisted"
}

is_slack_done() {
  # Slack is optional; treat as "done" if either set OR explicitly skipped.
  # The phase asks every time the var is unset, which is fine — the user can
  # press enter to skip.
  local v
  v="$(read_env_file "$SECRETS_FILE" PIPELINE_SLACK_WEBHOOK_URL | cut -d= -f2-)"
  [[ -n "$v" ]]
}

# ── Phase 9: config-defaults ──────────────────────────────────────────
phase_config_defaults() {
  print_phase_header "config-defaults"
  local tmp; tmp="$(mktemp)"
  jq '
    .orchestrator = (.orchestrator // {}) |
    if (.orchestrator.paused // null) == null then
      .orchestrator.paused = false
    else . end |
    .linear = (.linear // {}) |
    if (.linear.stage_label_prefix // null) == null then
      .linear.stage_label_prefix = "stage:"
    else . end |
    if (.linear.workflow_stages // null) == null then
      .linear.workflow_stages = ["brainstorm","plan","implement","ui","review","qa","build","release"]
    else . end |
    .linear.native_states = (.linear.native_states // {}) |
    if (.linear.native_states.active // null) == null then
      .linear.native_states.active = "In Progress"
    else . end
  ' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
  log "config-defaults: $CONFIG normalized"
}

is_config_defaults_done() {
  jq -e '
    (.orchestrator.paused != null) and
    (.linear.stage_label_prefix != null) and
    (.linear.workflow_stages != null and (.linear.workflow_stages | length) == 8) and
    (.linear.native_states.active != null)
  ' "$CONFIG" >/dev/null 2>&1
}

# ── Phase 10: validate ────────────────────────────────────────────────
phase_validate() {
  print_phase_header "validate"
  set -a; source "$SECRETS_FILE"; set +a
  bash "$SCRIPT_DIR/dry-run.sh"
}

is_validate_done() { return 1; }  # always re-run on demand

# ── Phase 11: launchd ─────────────────────────────────────────────────
phase_launchd() {
  print_phase_header "launchd"
  local slug; slug="$(jq -r '.project.slug' "$CONFIG")"
  printf 'Install launchd agents for project '\''%s'\'' now? [Y/n]: ' "$slug" >&2
  local ans; read -r ans
  ans="${ans:-Y}"
  case "$ans" in
    [Yy]*) ( unset PROJECT_STATE_DIR TWINNING_BOOTSTRAPPING PROJECT_SLUG; bash "$SCRIPT_DIR/install-launchd.sh" "$TARGET_REPO" ) ;;
    *) log "launchd: skipped (run install-launchd.sh manually when ready)" ;;
  esac
}

is_launchd_done() {
  local slug label
  slug="$(jq -r '.project.slug // empty' "$CONFIG")"
  [[ -n "$slug" ]] || return 1
  for label in "com.twinning.pipeline.$slug" "com.twinning.retrospective.$slug"; do
    launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || return 1
  done
}

# ── Transitional: migrate ─────────────────────────────────────────────
# One-shot upgrade of the existing single-project install. See spec §6.
phase_migrate() {
  print_phase_header "migrate"

  # 1. Sanity check.
  jq -e '.linear.team_id and .linear.project_id' "$CONFIG" >/dev/null \
    || die "migrate: $CONFIG missing team_id or project_id — abort"

  # Refresh IDs cache if missing.
  if [[ ! -f "$IDS_CACHE" ]]; then
    set -a; source "$SECRETS_FILE" 2>/dev/null || true; set +a
    bash "$SCRIPT_DIR/linear.sh" refresh-cache
  fi

  # 2. Slug freeze (delegate; idempotent).
  phase_slug_freeze

  local slug; slug="$(jq -r '.project.slug' "$CONFIG")"
  local project_state="$HARNESS_STATE_DIR/$slug"

  # 3. Lift shared credentials from per-project .env.local into shared secrets.env.
  mkdir -p "$HARNESS_CONFIG_DIR" && chmod 0700 "$HARNESS_CONFIG_DIR"
  local var
  for var in LINEAR_API_KEY GH_APP_ID GH_APP_PRIVATE_KEY_PATH PIPELINE_SLACK_WEBHOOK_URL; do
    local val; val="$(read_env_file "$ENV_FILE" "$var" | cut -d= -f2-)"
    if [[ -n "$val" ]]; then
      write_env_file "$SECRETS_FILE" 0600 "$var=$val"
      # Strip from per-project .env.local.
      sed -i.bak -E "/^[[:space:]]*${var}=/d" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
      log "migrate: lifted $var → $SECRETS_FILE"
    fi
  done

  # If the GH App private key lives at the legacy state-dir path, move it.
  local key_path; key_path="$(read_env_file "$SECRETS_FILE" GH_APP_PRIVATE_KEY_PATH | cut -d= -f2-)"
  if [[ -n "$key_path" && -f "$key_path" && "$key_path" != "$HARNESS_CONFIG_DIR/github-app.pem" ]]; then
    if [[ "$key_path" == "$HARNESS_STATE_DIR/"* || "$key_path" == "$HOME/.twinning-pipeline/"* ]]; then
      mv "$key_path" "$HARNESS_CONFIG_DIR/github-app.pem"
      chmod 0600 "$HARNESS_CONFIG_DIR/github-app.pem"
      write_env_file "$SECRETS_FILE" 0600 "GH_APP_PRIVATE_KEY_PATH=$HARNESS_CONFIG_DIR/github-app.pem"
      log "migrate: moved GitHub App private key to $HARNESS_CONFIG_DIR/github-app.pem"
    fi
  fi

  # 4. Move state dir contents under <slug>/.
  mkdir -p "$project_state"
  local item src dst
  for item in .consecutive-failures .tick-counter .halt-sprawl-last-alerted last-observed-release; do
    src="$HARNESS_STATE_DIR/$item"
    dst="$project_state/$item"
    [[ -e "$src" && ! -e "$dst" ]] && { mv "$src" "$dst"; log "migrate: moved $item"; }
  done
  for d in logs metrics; do
    src="$HARNESS_STATE_DIR/$d"
    dst="$project_state/$d"
    if [[ -d "$src" && ! -d "$dst" ]]; then
      mv "$src" "$dst"
      log "migrate: moved $d/"
    fi
  done
  # Move ENG-N issue dirs (only direct children that match ENG- prefix and are
  # not already inside a slug dir).
  while IFS= read -r -d '' issue; do
    local name; name="$(basename "$issue")"
    [[ "$name" =~ ^ENG-[0-9]+$ ]] || continue
    [[ -d "$project_state/$name" ]] && continue
    mv "$issue" "$project_state/$name"
    log "migrate: moved $name/"
  done < <(find "$HARNESS_STATE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

  # 5. Move learned-rules.
  local lr="$HARNESS_ROOT/learned-rules"
  mkdir -p "$lr/$slug"
  local rule
  while IFS= read -r -d '' rule; do
    local rname; rname="$(basename "$rule")"
    [[ -f "$lr/$slug/$rname" ]] && continue
    mv "$rule" "$lr/$slug/$rname"
    log "migrate: moved learned-rules/$rname"
  done < <(find "$lr" -mindepth 1 -maxdepth 1 -type f -name '*.md' -print0)

  # 6. Bootout legacy un-suffixed agents.
  local domain="gui/$(id -u)"
  for label in com.twinning.pipeline com.twinning.retrospective; do
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      launchctl bootout "$domain/$label" || true
      log "migrate: bootout legacy $label"
    fi
    [[ -f "$HOME/Library/LaunchAgents/$label.plist" ]] \
      && rm -f "$HOME/Library/LaunchAgents/$label.plist" \
      && log "migrate: removed legacy $label.plist"
  done

  # 7. Install slug-suffixed agents.
  ( unset PROJECT_STATE_DIR TWINNING_BOOTSTRAPPING PROJECT_SLUG; bash "$SCRIPT_DIR/install-launchd.sh" "$TARGET_REPO" )

  # 8. Sanity check.
  ( unset PROJECT_STATE_DIR TWINNING_BOOTSTRAPPING PROJECT_SLUG; bash "$SCRIPT_DIR/dry-run.sh" >/dev/null 2>&1 ) || log "migrate: dry-run.sh reported failures (see above)"
  log "migrate: complete. New labels:"
  launchctl list 2>/dev/null | grep com.twinning >&2 || true
}

is_migrate_done() { return 1; }   # always re-run on demand; substeps are individually idempotent

# Phase dispatch.
ALL_PHASES=(workspace linear-auth linear-identity linear-schema slug-freeze github-app gh-cli slack config-defaults validate launchd)
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
