#!/usr/bin/env bash
# External observer of run-local.sh's per-tick heartbeat. Invoked by
# com.twinning.stuck-tick-alarm.<slug> every 15 min. ENG-132.
#
# Reads $PROJECT_STATE_DIR/.last-tick-end mtime; posts to Slack via
# bin/slack.sh warn when age exceeds the configured threshold.
# Level-triggered metric on every fire; edge-triggered Slack with 24h debounce.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

HEARTBEAT_FILE="$PROJECT_STATE_DIR/.last-tick-end"
DEBOUNCE_FILE="$PROJECT_STATE_DIR/.stuck-tick-last-alerted"
DEBOUNCE_WINDOW_SECONDS=86400   # 24h, mirrors _poll_emit_halt_sprawl_alert
ALARM_MINUTES_DEFAULT=30
ALARM_MINUTES_FLOOR=10

_resolve_alarm_minutes() {
  local v floor="$ALARM_MINUTES_FLOOR" default="$ALARM_MINUTES_DEFAULT"
  # Layer 1: env var (single-dash form per ENG-46 secret-handling preamble)
  v="${STUCK_TICK_ALARM_MINUTES-}"
  if [[ -n "$v" ]]; then
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= floor )); then
      printf '%s\n' "$v"; return 0
    fi
    log "_resolve_alarm_minutes: invalid env STUCK_TICK_ALARM_MINUTES=$v (must be integer >= $floor); falling through"
  fi
  # Layer 2: config.json
  if [[ -f "$CONFIG" ]]; then
    v="$(jq -r '.orchestrator.stuck_tick_alarm_minutes // empty' "$CONFIG" 2>/dev/null || true)"
    if [[ -n "$v" ]]; then
      if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= floor )); then
        printf '%s\n' "$v"; return 0
      fi
      log "_resolve_alarm_minutes: invalid config stuck_tick_alarm_minutes=$v (must be integer >= $floor); falling through"
    fi
  fi
  # Layer 3: built-in default
  printf '%s\n' "$default"
}

_heartbeat_age_seconds() {
  local mtime now
  if [[ -f "$HEARTBEAT_FILE" ]]; then
    mtime="$(date -r "$HEARTBEAT_FILE" +%s 2>/dev/null || printf '0')"
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  else
    mtime=0
  fi
  now="$(date -u +%s)"
  if (( mtime <= 0 )); then
    printf '%s\n' '99999999'
  else
    printf '%s\n' "$(( now - mtime ))"
  fi
}

_lock_holder_pid() {
  local pid_file="$PROJECT_STATE_DIR/.run-local.lock/pid"
  if [[ -f "$pid_file" ]]; then
    cat "$pid_file" 2>/dev/null || printf 'none'
  else
    printf 'none'
  fi
}

_ps_excerpt_for_pid() {
  local pid="$1"
  if [[ "$pid" == "none" ]]; then
    printf '<no live tick holder>\n'
    return 0
  fi
  ps -p "$pid" -o pid,ppid,user,command 2>/dev/null \
    || printf '<ps unavailable for pid=%s>\n' "$pid"
}

_log_tail_for_today() {
  local log_file="$PROJECT_STATE_DIR/logs/local-$(date -u +%Y-%m-%d).log"
  tail -n 40 "$log_file" 2>/dev/null || true
}

_debounced() {
  local now_epoch last_epoch=0
  now_epoch="$(date -u +%s)"
  if [[ -f "$DEBOUNCE_FILE" ]]; then
    local raw
    raw="$(cat "$DEBOUNCE_FILE" 2>/dev/null || true)"
    if [[ -n "$raw" ]]; then
      local ts
      ts="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$raw" +%s 2>/dev/null \
            || date -d "$raw" +%s 2>/dev/null \
            || printf '0')"
      [[ "$ts" =~ ^[0-9]+$ ]] && last_epoch="$ts" || last_epoch=0
    fi
  fi
  (( now_epoch - last_epoch <= DEBOUNCE_WINDOW_SECONDS ))
}

_stamp_debounce() {
  date -u +%Y-%m-%dT%H:%M:%SZ > "$DEBOUNCE_FILE"
}

main() {
  local threshold age holder_pid last_iso payload
  threshold="$(_resolve_alarm_minutes)"
  age="$(_heartbeat_age_seconds)"

  if (( age <= threshold * 60 )); then
    return 0
  fi

  holder_pid="$(_lock_holder_pid)"

  # Level-triggered metric on every fire above threshold.
  bash "$SCRIPT_DIR/metrics.sh" stuck-tick "" "" alert 0 \
    "age=$age threshold=$((threshold * 60)) holder_pid=$holder_pid" \
    || true

  if _debounced; then
    log "stuck-tick: Slack suppressed by debounce ($age sec age, $DEBOUNCE_WINDOW_SECONDS sec window)"
    return 0
  fi

  last_iso="$(cat "$HEARTBEAT_FILE" 2>/dev/null || printf '<none>')"
  payload="$(printf 'Stuck tick alarm: %s has not completed a tick for %s sec (threshold %sm; last good %s)\nLock holder: pid=%s\nps excerpt:\n%s\nLog tail:\n%s' \
    "$PROJECT_SLUG" "$age" "$threshold" "$last_iso" \
    "$holder_pid" "$(_ps_excerpt_for_pid "$holder_pid")" \
    "$(_log_tail_for_today)")"

  bash "$SCRIPT_DIR/slack.sh" warn "$payload" || true
  _stamp_debounce
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
