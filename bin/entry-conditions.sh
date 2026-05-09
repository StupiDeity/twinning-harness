#!/usr/bin/env bash
# Orchestrator-side per-stage entry-condition registry (ENG-86).
#
# Provides a generic, config-driven pre-dispatch check stack. The
# orchestrator (run-stage.sh::_entry_conditions_gate) shells out to
# `bash bin/entry-conditions.sh should_dispatch <stage> <issue>`; this
# script reads the per-stage check list from
# `.pipeline-config/config.json::orchestrator.entry_conditions[<stage>]`,
# runs each named check in declaration order, and prints exactly one
# line on stdout:
#
#   proceed                       — every check passed (or list empty)
#   skip:<reason>                 — first check failed; <reason> is the
#                                   short-token reason produced by that
#                                   check (e.g. `awaiting-approval`)
#   error:<check-name>            — the check errored (gh/jq outage); the
#                                   caller fail-opens to dispatch
#
# Always exits 0 — the caller parses stdout, NOT the exit code. This
# matches the validation pattern used by `dispatch.sh:388-403` for the
# ENG-65 per-stage timeout config read.
#
# Phase 1 ships exactly one check (`pr-approved-by-non-bot` for stage
# `building`); new checks land in `_entry_check_handler_for` without
# schema migration.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ─── Checks ────────────────────────────────────────────────────────────
# Each check is a function:
#   - input: $1 issue id
#   - rc=0:  condition met
#   - rc=1:  condition unmet; stdout = short reason token
#   - rc=2:  tooling outage / error; caller fail-opens
# Failures intentionally use rc=1 vs rc=2 so the caller can distinguish
# "predicate said no" (skip) from "predicate could not evaluate" (error,
# fail-open). The error path is the safety valve when the harness host
# loses gh/jq mid-tick — D-010.

# Mirrors AGENT_PROMPTS.md §7 P2 (lines 1287-1289): non-bot APPROVED
# review count >= 1. If the agent-side P2 filter changes, update this
# function in lockstep — see ENG-86 D-008. The agent-side P2 remains
# the defense-in-depth fallback when an operator opts out of this
# orchestrator gate or when `gh` errors fail-open here.
check_pr_approved_by_non_bot() {
  local issue="$1"
  command -v gh >/dev/null 2>&1 || return 2
  local branch
  branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue" 2>/dev/null || printf '')"
  [[ -n "$branch" ]] || return 2
  local reviews_json
  reviews_json="$(gh pr view "$branch" --json reviews 2>/dev/null || printf '')"
  [[ -n "$reviews_json" ]] || return 2
  local approved_count
  approved_count="$(jq -r '
    [.reviews[] | select(.state == "APPROVED" and (.author.login | test("\\[bot\\]$") | not))]
    | length' <<<"$reviews_json" 2>/dev/null || printf '')"
  [[ "$approved_count" =~ ^[0-9]+$ ]] || return 2
  (( approved_count >= 1 )) && return 0
  printf 'awaiting-approval\n'
  return 1
}

# Map a config-declared check name to its handler function. Returns the
# function name on stdout (success) or returns rc=1 (signals "unknown
# check name" to the caller). New checks land here in Phase 2.
_entry_check_handler_for() {
  case "${1:-}" in
    pr-approved-by-non-bot) printf 'check_pr_approved_by_non_bot' ;;
    *) return 1 ;;
  esac
}

# ─── CLI verb ──────────────────────────────────────────────────────────
# `should_dispatch <stage> <issue>` reads the per-stage check list from
# CONFIG, runs each check in order, AND-gates the results, and prints
# the single-line outcome. Empty/null/absent config → proceed
# (back-compat per D-005). An unknown check name is logged and skipped
# (treated as a no-op, NOT a hard error) so a typo in the config does
# not lock the orchestrator out of dispatching forever.
should_dispatch() {
  local stage="${1:-}" issue="${2:-}"
  [[ -n "$stage" && -n "$issue" ]] || die "usage: entry-conditions.sh should_dispatch <stage> <issue>"

  local checks_json
  checks_json="$(jq -c --arg s "$stage" \
    '.orchestrator.entry_conditions[$s] // []' "$CONFIG" 2>/dev/null || printf '[]')"
  # jq emits "null" (literal) when CONFIG is malformed and the // fallback
  # cannot apply; coerce that to an empty array for length-safety below.
  [[ "$checks_json" == "null" || -z "$checks_json" ]] && checks_json='[]'

  local n
  n="$(jq 'length' <<<"$checks_json" 2>/dev/null || printf '0')"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if (( n == 0 )); then
    printf 'proceed\n'
    return 0
  fi

  local i=0 name handler reason rc
  while (( i < n )); do
    name="$(jq -r --argjson i "$i" '.[$i].name // ""' <<<"$checks_json" 2>/dev/null || printf '')"
    if [[ -z "$name" ]]; then
      i=$((i + 1))
      continue
    fi
    handler="$(_entry_check_handler_for "$name" 2>/dev/null || printf '')"
    if [[ -z "$handler" ]]; then
      log "entry-conditions: unknown check '$name' for stage '$stage'; skipping (fall through)"
      i=$((i + 1))
      continue
    fi
    rc=0
    reason="$("$handler" "$issue" 2>/dev/null)" || rc=$?
    case "$rc" in
      0)
        ;;
      1)
        printf 'skip:%s\n' "$reason"
        return 0
        ;;
      2)
        printf 'error:%s\n' "$name"
        return 0
        ;;
      *)
        log "entry-conditions: handler '$handler' returned unexpected rc=$rc; treating as error"
        printf 'error:%s\n' "$name"
        return 0
        ;;
    esac
    i=$((i + 1))
  done
  printf 'proceed\n'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    should_dispatch) shift; should_dispatch "$@" ;;
    *) die "usage: entry-conditions.sh should_dispatch <stage> <issue>" ;;
  esac
fi
