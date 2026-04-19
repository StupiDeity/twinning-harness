#!/usr/bin/env bash
# Run one pipeline tick locally. Launched by the launchd agent at
# ~/Library/LaunchAgents/com.twinning.pipeline.plist every 5 minutes.
#
# Mirrors the dispatch job that used to run in .github/workflows/pipeline.yml:
#   poll -> (entry-action) -> run-stage -> commit+push artifacts.
#
# Responsibilities layered on top of run-stage.sh:
#   - Single-flight lock so overlapping 5-min fires don't stack.
#   - Load LINEAR_API_KEY from .pipeline/.env.local; no ANTHROPIC_API_KEY
#     because `claude` uses the logged-in subscription session.
#   - Respect orchestrator.paused in config.json.
#   - Rolling daily log at logs/pipeline/local-YYYY-MM-DD.log.
#   - Circuit breaker: after 3 consecutive run-stage failures, flip
#     orchestrator.paused=true so subsequent ticks skip until a human resets it.

set -euo pipefail

# launchd hands us a minimal PATH. Prepend the places the tools actually live on
# macOS (Homebrew on Apple Silicon + Intel, npm/bun user-global bins). The plist
# also sets PATH; this is belt-and-braces so the script works if invoked manually.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

LOCK_DIR="$PIPELINE_ROOT/.run-local.lock"
ENV_FILE="$PIPELINE_ROOT/.env.local"
FAIL_COUNTER="$PIPELINE_ROOT/.consecutive-failures"
FAIL_THRESHOLD=3
LOG_DIR="$REPO_ROOT/logs/pipeline"
LOG_FILE="$LOG_DIR/local-$(date -u +%Y-%m-%d).log"
BOT_NAME="twinning-pipeline-bot"
BOT_EMAIL="twinning-pipeline-bot@users.noreply.github.com"

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' $$ > "$LOCK_DIR/pid"
    return 0
  fi
  # Existing lock: break it if the holder process is gone.
  local holder
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo 0)"
  if [[ "$holder" =~ ^[0-9]+$ ]] && (( holder > 0 )) && ! kill -0 "$holder" 2>/dev/null; then
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' $$ > "$LOCK_DIR/pid"
      log "broke stale lock held by dead pid $holder"
      return 0
    fi
  fi
  return 1
}

trip_breaker() {
  log "CIRCUIT BREAKER: setting orchestrator.paused=true after $FAIL_THRESHOLD consecutive failures"
  # Surgical edit (not jq-write) so formatting/blank lines in config.json are preserved.
  # Relies on the single `"paused": false` occurrence under orchestrator.
  if grep -q '"paused": false' "$CONFIG"; then
    sed -i.bak 's/"paused": false/"paused": true/' "$CONFIG"
    rm -f "${CONFIG}.bak"
  else
    log "trip_breaker: could not find '\"paused\": false' in $CONFIG; leaving as-is"
  fi
}

if ! acquire_lock; then
  # Silent skip: overlapping tick is expected if a stage runs >5 min.
  exit 0
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log "== tick start =="

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
require_env LINEAR_API_KEY

paused="$(config_get '.orchestrator.paused')"
if [[ "$paused" == "true" ]]; then
  log "tick skipped: orchestrator.paused=true"
  log "reset with: jq '.orchestrator.paused=false' $CONFIG > /tmp/c && mv /tmp/c $CONFIG"
  exit 0
fi

cd "$REPO_ROOT"

decision="$(bash "$SCRIPT_DIR/poll.sh")"
log "poll decision: $decision"
issue_id="$(jq -r '.issue_id // ""' <<<"$decision")"
stage="$(jq -r '.stage // ""' <<<"$decision")"
entry_action="$(jq -r '.entry_action // "run"' <<<"$decision")"

if [[ -z "$issue_id" ]]; then
  log "no work this tick"
  exit 0
fi

if [[ "$entry_action" == "apply-stage-label" ]]; then
  # Note: inline `case` inside `$( ... )` trips bash 3.2 (macOS default) — the
  # `)` after each pattern closes the command substitution early. Assign
  # directly in the case body instead.
  case "$stage" in
    brainstorm) label_suffix=brainstorming ;;
    plan)       label_suffix=planning ;;
    implement)  label_suffix=implementing ;;
    ui)         label_suffix=ui ;;
    review)     label_suffix=reviewing ;;
    qa)         label_suffix=qa ;;
    build)      label_suffix=building ;;
    release)    label_suffix=released ;;
    *)          label_suffix="$stage" ;;
  esac
  active_state="$(config_get '.linear.native_states.active')"
  bash "$SCRIPT_DIR/linear.sh" transition-state "$issue_id" "$active_state"
  bash "$SCRIPT_DIR/linear.sh" add-label "$issue_id" "stage:$label_suffix"
fi

set +e
bash "$SCRIPT_DIR/run-stage.sh" "$issue_id" "$stage"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  count="$(cat "$FAIL_COUNTER" 2>/dev/null || echo 0)"
  count=$((count + 1))
  printf '%s\n' "$count" > "$FAIL_COUNTER"
  log "run-stage.sh exited $rc; consecutive failures = $count"
  if (( count >= FAIL_THRESHOLD )); then
    trip_breaker
  fi
  exit $rc
fi

rm -f "$FAIL_COUNTER"

if [[ -n "$(git status --porcelain)" ]]; then
  log "committing pipeline artifacts for $issue_id / $stage"
  git add -A
  git \
    -c user.name="$BOT_NAME" \
    -c user.email="$BOT_EMAIL" \
    commit -m "chore(pipeline): $stage for $issue_id"
  git push
else
  log "no artifacts to commit"
fi

log "== tick end (success) =="
