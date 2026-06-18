#!/usr/bin/env bash
# "main is green" invariant monitor. Invoked by
# com.twinning.main-green-check.<slug> every 30 min.
#
# Why this exists: the pre-commit gate (.githooks/pre-commit, run by every
# agent commit) blocks the commit on any non-KNOWN_BROKEN test failure. When
# origin/<default-branch> goes RED, EVERY agent dispatch on the host is then
# silently blocked at the hook layer — agents either halt with a no-op or fall
# back to `--no-verify` (defeating the gate). The failure is invisible until an
# operator notices the queue stalling. This monitor makes "main is green" a
# loud invariant: it runs the target repo's own pre-commit gate against a clean
# checkout of origin/<branch> and pages Slack (via bin/slack.sh warn) when red.
#
# Cost control: the gate is only re-run when origin/<branch> MOVES. In steady
# state each fire is a `git fetch` + SHA compare; the (expensive) suite runs
# only on a new SHA. Verdict is cached in $PROJECT_STATE_DIR/.main-green-state.
#
# Level-triggered metric on every red fire; edge-triggered Slack with 24h
# debounce (mirrors stuck-tick-alarm.sh / _poll_emit_halt_sprawl_alert).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Load shared secrets so PIPELINE_SLACK_WEBHOOK_URL reaches slack.sh under
# launchd (the plist injects PATH/HOME/TARGET_REPO/HARNESS_STATE_DIR/
# PROJECT_SLUG only). Mirrors stuck-tick-alarm.sh:17-21.
SECRETS_FILE="$HARNESS_CONFIG_DIR/secrets.env"
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$SECRETS_FILE"; set +a
fi

STATE_FILE="$PROJECT_STATE_DIR/.main-green-state"          # "<sha> <ok|red>"
DEBOUNCE_FILE="$PROJECT_STATE_DIR/.main-green-last-alerted"
DEBOUNCE_WINDOW_SECONDS=86400   # 24h

# Resolve the default branch once (origin/HEAD → e.g. "main"). Falls back to
# "main" when symbolic-ref is unavailable (fresh clone / detached origin/HEAD).
_default_branch() {
  local ref
  ref="$(git -C "$TARGET_REPO" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$ref" ]]; then
    printf '%s\n' "${ref#origin/}"
  else
    printf 'main\n'
  fi
}

# Echo the post-fetch origin/<branch> SHA, or empty string on fetch failure
# (network outage → caller skips this run; fail-open, never a false RED).
# Overridable seam for tests.
_origin_main_sha() {
  local branch="$1"
  git -C "$TARGET_REPO" fetch -q origin "$branch" 2>/dev/null || { printf '\n'; return 0; }
  git -C "$TARGET_REPO" rev-parse -q --verify "refs/remotes/origin/$branch" 2>/dev/null || printf '\n'
}

# Run the target repo's pre-commit gate against origin/<branch> in a throwaway
# detached worktree. Returns the gate's rc; echoes a short failing-summary on
# stdout. No hooksPath / no pre-commit hook → rc 0 (nothing gates agent
# commits, so "green" is the correct verdict). Overridable seam for tests.
_run_main_gate() {
  local branch="$1" sha="$2"
  local hookspath hook wt rc=0 out
  hookspath="$(git -C "$TARGET_REPO" config --get core.hooksPath 2>/dev/null || true)"
  [[ -n "$hookspath" ]] || { log "main-green-check: no core.hooksPath; nothing to gate"; printf '\n'; return 0; }
  hook="$TARGET_REPO/$hookspath/pre-commit"
  [[ -f "$hook" ]] || { log "main-green-check: no pre-commit hook at $hook"; printf '\n'; return 0; }

  wt="$(mktemp -d -t twinning-main-green.XXXXXX)"
  case "$wt" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;;
    *) log "main-green-check: refusing non-temp worktree path $wt"; printf '\n'; return 0 ;;
  esac
  if ! git -C "$TARGET_REPO" worktree add -q --detach "$wt" "$sha" 2>/dev/null; then
    log "main-green-check: worktree add failed for $sha; skipping (fail-open)"
    rmdir "$wt" 2>/dev/null || true
    printf '\n'; return 0
  fi

  # Run the gate from inside the clean worktree. `|| rc=$?` keeps set -e happy.
  out="$(cd "$wt" && bash "$wt/$hookspath/pre-commit" 2>&1)" || rc=$?
  git -C "$TARGET_REPO" worktree remove --force "$wt" 2>/dev/null || true

  if (( rc != 0 )); then
    # Surface the failing test lines (the hook prints "N passed, M failed" +
    # per-file FAIL rows). Compress to a one-liner for Slack/metric notes.
    printf '%s\n' "$(printf '%s\n' "$out" | grep -iE 'failed|FAIL ' | grep -v '0 failed' | head -5 | tr '\n' ';' | cut -c1-300)"
  else
    printf '\n'
  fi
  return "$rc"
}

_read_state() {   # echoes "<sha> <verdict>" or empty
  [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" 2>/dev/null || printf '\n'
}

_write_state() {  # $1=sha $2=verdict(ok|red)
  printf '%s %s\n' "$1" "$2" > "$STATE_FILE"
}

_debounced() {
  local now_epoch last_epoch=0 raw ts
  now_epoch="$(date -u +%s)"
  if [[ -f "$DEBOUNCE_FILE" ]]; then
    raw="$(cat "$DEBOUNCE_FILE" 2>/dev/null || true)"
    if [[ -n "$raw" ]]; then
      ts="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$raw" +%s 2>/dev/null \
            || date -d "$raw" +%s 2>/dev/null || printf '0')"
      [[ "$ts" =~ ^[0-9]+$ ]] && last_epoch="$ts" || last_epoch=0
    fi
  fi
  (( now_epoch - last_epoch < DEBOUNCE_WINDOW_SECONDS ))
}

_stamp_debounce() { date -u +%Y-%m-%dT%H:%M:%SZ > "$DEBOUNCE_FILE"; }
_clear_debounce() { rm -f "$DEBOUNCE_FILE"; }

# Emit metric (always, level-triggered) + Slack (edge-triggered, debounced).
_alert_red() {   # $1=sha $2=failing-summary
  local sha="$1" summary="$2" payload
  bash "$SCRIPT_DIR/metrics.sh" main-green-check "" "" red 0 \
    "sha=$sha branch=$(_default_branch) failing=$summary" || true

  if _debounced; then
    log "main-green-check: Slack suppressed by debounce (origin/main $sha RED)"
    return 0
  fi
  payload="$(printf 'Main gate RED: %s origin/%s @ %s fails the pre-commit gate.\nEvery agent commit on this host is blocked until main is green (agents halt or resort to --no-verify).\nFailing: %s\nReproduce: bash .githooks/pre-commit' \
    "$PROJECT_SLUG" "$(_default_branch)" "${sha:0:12}" "${summary:-<see hook output>}")"
  bash "$SCRIPT_DIR/slack.sh" warn "$payload" || true
  _stamp_debounce
}

main() {
  # Planned-maintenance silence: MAIN_GREEN_CHECK_DISABLED=1 (mirrors
  # stuck-tick's STUCK_TICK_ALARM_MINUTES=9999 escape hatch).
  if [[ "${MAIN_GREEN_CHECK_DISABLED-}" == "1" ]]; then
    log "main-green-check: disabled via MAIN_GREEN_CHECK_DISABLED=1"
    return 0
  fi

  local branch sha state last_sha last_verdict summary
  branch="$(_default_branch)"
  sha="$(_origin_main_sha "$branch")"
  if [[ -z "$sha" ]]; then
    log "main-green-check: could not resolve origin/$branch SHA (fetch failed?); skipping (fail-open)"
    return 0
  fi

  state="$(_read_state)"
  last_sha="${state%% *}"
  last_verdict="${state##* }"

  if [[ "$sha" == "$last_sha" ]]; then
    # SHA unchanged → verdict unchanged; do NOT re-run the gate.
    if [[ "$last_verdict" == "red" ]]; then
      _alert_red "$sha" "<unchanged since last check>"
    fi
    return 0
  fi

  # New SHA → run the gate.
  summary="$(_run_main_gate "$branch" "$sha")" && {
    _write_state "$sha" "ok"
    if [[ "$last_verdict" == "red" ]]; then
      log "main-green-check: origin/$branch recovered to green at $sha"
      bash "$SCRIPT_DIR/slack.sh" info \
        "Main gate GREEN again: $PROJECT_SLUG origin/$branch @ ${sha:0:12} passes the pre-commit gate." || true
      _clear_debounce
    fi
    return 0
  }
  # Gate failed.
  _write_state "$sha" "red"
  _alert_red "$sha" "$summary"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
