#!/usr/bin/env bash
# Halt resolution CLI (ENG-18). Posts a <!-- pipeline-decision: --> comment
# and removes pipeline:halted in one step.
#
# Usage:
#   halt.sh resolve <ENG-XX> --decision <scope-approved|scope-rejected|resume>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ENG-41 T3: human lane — operator CLI; all Linear writes are unrestricted.
export PIPELINE_WRITER=human

# ENG-58 D-001/D-005/D-006/D-007: atomic side-state reset. Removes the
# pipeline:skip-until-* labels, deletes wait-*.json under the per-issue
# state dir, and conditionally deletes issue-state.json (only when
# .policy == "skip-until-human-acts" — we preserve the evidence trail
# for skip-until-code-changes so poll.sh's auto-resume still works).
# Writes machine-shorthand stats to stdout and human-readable log lines
# to stderr. Idempotent: every operation no-ops when the target is
# absent.
_resolve_reset_side_state() {
  local issue="$1"
  local d; d="$(issue_dir "$issue")"
  [[ -n "$d" ]] || die "halt-resolve: empty issue_dir for $issue"

  local skip_count=0
  for lbl in "pipeline:skip-until-code-changes" "pipeline:skip-until-human-acts"; do
    if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "$lbl" 2>/dev/null; then
      bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "$lbl" 2>/dev/null || true
      skip_count=$((skip_count + 1))
    fi
  done

  local wait_count=0
  if compgen -G "$d/wait-*.json" >/dev/null 2>&1; then
    wait_count="$(compgen -G "$d/wait-*.json" | wc -l | tr -d ' ')"
    rm -f "$d"/wait-*.json 2>/dev/null || true
  fi

  local state_file="$d/issue-state.json"
  local state_removed=false
  if [[ -s "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then
    local policy
    policy="$(jq -r '.policy // ""' "$state_file" 2>/dev/null || printf '')"
    if [[ "$policy" == "skip-until-human-acts" ]]; then
      rm -f "$state_file"
      state_removed=true
      log "halt-resolve: removed $state_file (policy=skip-until-human-acts)"
    fi
  fi

  printf 'wait_files=%d skip_labels=%d state_file=%s' \
    "$wait_count" "$skip_count" "$state_removed"
}

# ENG-58 D-013: render the machine-shorthand stats string into a
# human-readable sentence appended to the operator-resume waypoint body.
# Input shape: "wait_files=N skip_labels=M state_file=true|false".
_format_reset_audit() {
  local stats="$1"
  local wf sl sf
  wf="$(printf '%s' "$stats" | sed -nE 's/.*wait_files=([0-9]+).*/\1/p')"
  sl="$(printf '%s' "$stats" | sed -nE 's/.*skip_labels=([0-9]+).*/\1/p')"
  sf="$(printf '%s' "$stats" | sed -nE 's/.*state_file=(true|false).*/\1/p')"
  local state_phrase
  if [[ "$sf" == "true" ]]; then
    state_phrase=", issue-state.json removed"
  else
    state_phrase=""
  fi
  printf '_Cleared:_ %s wait file(s), %s skip-until-* label(s)%s.\n' \
    "${wf:-0}" "${sl:-0}" "$state_phrase"
}

# ENG-58 D-013: emit a halt-resume metrics event capturing the cleanup
# stats. Wrapped in `|| true` so an emission failure does not fail the
# resume operation.
_emit_halt_resume_metric() {
  local issue="$1" stage="$2" stats="$3" waypoint_posted="$4"
  bash "$SCRIPT_DIR/metrics.sh" halt-resume "$issue" "$stage" \
    "atomic-reset" 0 "$stats waypoint_posted=$waypoint_posted" || true
}

# ENG-58 D-012: stderr-only advisory printed from the non-resume scope-*
# branch when stale halt-related side state coexists with a scope
# decision. Points the operator to the documented chained step.
_observe_stale_side_state() {
  local issue="$1"
  local d; d="$(issue_dir "$issue")"
  local hits=()
  bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:skip-until-code-changes" 2>/dev/null \
    && hits+=("pipeline:skip-until-code-changes")
  bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:skip-until-human-acts" 2>/dev/null \
    && hits+=("pipeline:skip-until-human-acts")
  compgen -G "$d/wait-*.json" >/dev/null 2>&1 && hits+=("$d/wait-*.json")
  [[ -s "$d/issue-state.json" ]] && hits+=("$d/issue-state.json")
  if (( ${#hits[@]} > 0 )); then
    printf 'halt.sh: NOTE — stale side state detected on %s (%s); run `bash "%s/bin/halt.sh" resolve %s --decision resume` to clear.\n' \
      "$issue" "$(IFS=', '; printf '%s' "${hits[*]}")" "$HARNESS_ROOT" "$issue" >&2
  fi
}

resolve() {
  local issue="$1" decision="$2"
  # ENG-58 D-014: strict issue-id validation before ANY filesystem or
  # Linear write. Closes the path-traversal vector via the case-glob
  # ENG-* in main(): an ident like "ENG-../../etc" would otherwise be
  # interpolated into rm -f paths and Linear queries.
  [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
    || die "halt.sh: invalid issue id '$issue' (expected ENG-<digits>)"
  [[ -n "$issue" && -n "$decision" ]] \
    || die "usage: halt.sh resolve <ENG-XX> --decision <scope-approved|scope-rejected|resume>"
  case "$decision" in
    scope-approved|scope-rejected|resume) ;;
    *) die "unknown decision: $decision" ;;
  esac

  local body
  body="$(printf '<!-- pipeline-decision: %s -->\n\nHalt resolved by human via halt.sh (decision=%s).' "$decision" "$decision")"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"

  if [[ "$decision" == "resume" ]]; then
    # ENG-49 Gap #2: invoke verdict-handler BEFORE clearing pipeline:halted
    # so any fresh forward verdict marker actually advances the stage.
    # shellcheck source=verdict-handler.sh
    source "$SCRIPT_DIR/verdict-handler.sh"
    local current_stage rc=0 had_halt=0 cleared_waypoint=0
    current_stage="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue")"
    current_stage="${current_stage#stage:}"
    # ENG-58 D-014: validate stage-name shape before %s interpolation
    # into the operator-resume waypoint body. Falls back to 'unknown'
    # for a missing or malformed stage label so a crafted Linear label
    # cannot inject format-string content.
    [[ "$current_stage" =~ ^[a-z]+$ ]] || current_stage="unknown"

    # ENG-58 D-011: skip verdict_handler when pipeline:halted is absent.
    # The chained scope-approved → resume flow lands here; calling
    # verdict_handler with no halt + no fresh marker would fire
    # _vh_protocol_violation, which unconditionally re-applies
    # pipeline:halted (bin/verdict-handler.sh:58) — strictly worse than
    # the bug ENG-58 set out to fix. Synthesize vh_rc=1 so the cleanup-
    # and-waypoint path runs without the trap.
    if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted"; then
      had_halt=1
      verdict_handler "$issue" "$current_stage" || rc=$?
    else
      log "halt-resolve: pipeline:halted absent; skipping verdict_handler (D-011)"
      rc=1
    fi

    case "$rc" in
      0)
        # ENG-58 D-004: cleanup runs on the transitioned arm too.
        # ENG-58 D-003: NO operator-resume waypoint — apply_transition's
        # own <!-- pipeline-transition: from → to --> is the freshness
        # boundary on this arm.
        local stats; stats="$(_resolve_reset_side_state "$issue")"
        _emit_halt_resume_metric "$issue" "$current_stage" "$stats" "$cleared_waypoint"
        log "halt resolved: $issue decision=resume (verdict-handler transitioned; side state reset: $stats)"
        return 0
        ;;
      1)
        # ENG-58 D-008 atomic ordering: cleanup → halt-remove (only if
        # had_halt) → operator-resume waypoint LAST. Posting last means
        # a partial-failure earlier in the sequence is idempotently
        # recoverable by re-running halt.sh resolve.
        local stats; stats="$(_resolve_reset_side_state "$issue")"
        if (( had_halt )); then
          bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
        fi
        local waypoint_body
        waypoint_body="$(printf '<!-- pipeline-transition: %s → %s (operator-resume) -->\n\nOperator-attributed transition waypoint (halt.sh resolve --decision resume).\n\n%s' \
                          "$current_stage" "$current_stage" \
                          "$(_format_reset_audit "$stats")")"
        bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$waypoint_body"
        cleared_waypoint=1
        _emit_halt_resume_metric "$issue" "$current_stage" "$stats" "$cleared_waypoint"
        if (( had_halt )); then
          log "halt resolved: $issue decision=resume (halt label cleared; side state reset: $stats; operator-resume waypoint posted)"
        else
          log "halt resolved: $issue decision=resume (halt label absent; side state reset: $stats; operator-resume waypoint posted)"
        fi
        return 0
        ;;
      2)
        # ENG-58 D-004: NO cleanup, NO waypoint, NO halt removal.
        # Operator must investigate the protocol violation before
        # resuming.
        printf 'halt.sh: verdict-handler reported protocol violation on %s; halt label preserved.\n' "$issue" >&2
        printf 'halt.sh: see Linear comment with sig protocol-violation/<case_id>/%s for details.\n' "$issue" >&2
        return 2
        ;;
      *)
        die "verdict_handler returned unknown rc=$rc"
        ;;
    esac
  fi

  # ENG-58 D-009: scope-approved / scope-rejected — narrower path.
  # Posts decision marker (above), removes pipeline:halted, leaves all
  # side state intact (scope-deviation halts don't accrue skip labels /
  # wait files / issue-state.json by themselves). D-012: emit a stderr
  # advisory if stale halt-related side state coexists, pointing the
  # operator to the chained resume step.
  _observe_stale_side_state "$issue"
  bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
  log "halt resolved: $issue decision=$decision"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    resolve)
      local issue="" decision=""
      while (( $# )); do
        case "$1" in
          --decision) decision="$2"; shift 2 ;;
          ENG-*)      issue="$1"; shift ;;
          *)          die "unknown arg: $1" ;;
        esac
      done
      resolve "$issue" "$decision"
      ;;
    *) die "usage: halt.sh resolve <ENG-XX> --decision <scope-approved|scope-rejected|resume>" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
