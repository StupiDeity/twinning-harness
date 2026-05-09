#!/usr/bin/env bash
# bin/pipeline.sh — single-entry CLI for pipeline events (ENG-60).
#
# Usage:
#   bin/pipeline.sh status <issue>
#   bin/pipeline.sh event <issue> <event> [args]
#   bin/pipeline.sh decide <issue> --action <continue|approve|abandon> [--gate <gate>]
#
# All writes validate against bin/pipeline-events.json. Lane fences honored
# via PIPELINE_WRITER (set by callers; agent | orchestrator | human).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=run-local-helpers.sh
# Pulled in for issue_dir helpers and the auto_commit_in_scope function used by
# `decide --action continue`. run-local-helpers.sh has no top-level side effects.
source "$SCRIPT_DIR/run-local-helpers.sh"

# Sibling lookup (not via HARNESS_ROOT) so symlink-based test stubs work:
# verdict-adversarial-test.sh symlinks bin/* into a tempdir, so SCRIPT_DIR
# resolves to the symlink dir but HARNESS_ROOT (derived in common.sh from
# common.sh's location) points at the tempdir's parent, where bin/ doesn't
# exist. SCRIPT_DIR/pipeline-events.json works in both production layouts
# and the symlink-based test layout.
REGISTRY="$SCRIPT_DIR/pipeline-events.json"

usage() {
  cat <<'EOF'
Usage:
  bin/pipeline.sh status <issue>
  bin/pipeline.sh event <issue> verdict <pass|fail|halt|wait|pivot> [--stage X] [--target Y] [--reason Z]
  bin/pipeline.sh event <issue> transition <from→to>
  bin/pipeline.sh decide <issue> --action <continue|approve|abandon> [--gate <gate>]

Environment:
  PIPELINE_WRITER  Lane attribution: agent | orchestrator | human (required for writes).
  PIPELINE_DRY_RUN If set, print intended action to stderr and skip the Linear write.
EOF
}

# cmd_status <issue> — read-only summary of pipeline events on an issue.
# Lists every comment whose body parses as a pipeline event, in chronological
# order, one per line: "<createdAt> <event> <key=value ...>"
cmd_status() {
  local issue="$1"
  [[ -n "$issue" ]] || die "status: issue id required"
  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue" 2>&1)" || {
    log "status: could not fetch comments for $issue (linear error above)"
    return 0
  }
  [[ -z "$comments" || "$comments" == "null" ]] && { log "status: no comments"; return 0; }

  local ts body ev
  while IFS=$'\t' read -r ts body; do
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    printf '%s  %s\n' "$ts" "$(jq -c . <<<"$ev")"
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")
}

# cmd_event <issue> <event> [args] — dispatch to event-specific writer.
cmd_event() {
  local issue="${1:-}"; shift || true
  [[ -n "$issue" ]] || die "event: issue id required (e.g., bin/pipeline event ENG-1 verdict pass --stage X)"
  local event="${1:-}"; shift || true
  [[ -n "$event" ]] || die "event: event type required (verdict, transition)"
  case "$event" in
    verdict)    cmd_event_verdict "$issue" "$@" ;;
    transition) cmd_event_transition "$issue" "$@" ;;
    *) die "event: unknown event '$event' (allowed: verdict, transition)" ;;
  esac
}

# Validate $1 is in the named registry array; die with the registry's contents
# in the error message if not.
_validate_registry() {
  local field="$1" value="$2"
  jq -e --arg f "$field" --arg v "$value" '.[$f] | index($v) // empty' "$REGISTRY" >/dev/null 2>&1 \
    || die "registry: '$value' not in $field — allowed: $(jq -r --arg f "$field" '.[$f] | join(", ")' "$REGISTRY")"
}

# cmd_event_verdict <issue> <result> [--stage X] [--target Y] [--reason Z]
cmd_event_verdict() {
  local issue="$1"; shift
  local result="${1:-}"; shift || true
  [[ -n "$issue" && -n "$result" ]] || die "event verdict: usage: <issue> <result> [args]"
  _validate_registry verdict_results "$result"

  local stage="" target="" reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage)  stage="${2:-}"; shift 2 ;;
      --target) target="${2:-}"; shift 2 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      *) die "event verdict: unknown flag '$1'" ;;
    esac
  done

  # Per-result required fields.
  case "$result" in
    pass)  [[ -n "$stage" ]]  || die "event verdict pass: --stage required"
           _validate_registry stages "$stage" ;;
    fail)  [[ -n "$target" ]] || die "event verdict fail: --target required"
           _validate_registry fail_targets "$target" ;;
    halt)  [[ -n "$reason" ]] || die "event verdict halt: --reason required"
           _validate_registry halt_reasons "$reason" ;;
    wait)  [[ -n "$reason" ]] || die "event verdict wait: --reason required"
           _validate_registry wait_reasons "$reason" ;;
    pivot) [[ -n "$target" ]] || die "event verdict pivot: --target required"
           _validate_registry pivot_targets "$target" ;;
  esac

  # Build the marker body.
  local body="<!-- pipeline: verdict result=$result"
  [[ -n "$stage" ]]  && body="$body stage=$stage"
  [[ -n "$target" ]] && body="$body target=$target"
  [[ -n "$reason" ]] && body="$body reason=$reason"
  body="$body -->"

  # Lane fence: agents emit verdicts. dispatch.sh sets PIPELINE_WRITER=agent
  # for the agent path; common.sh defaults it to orchestrator for everything
  # else (operator manual runs, tests). The default-assignment idiom would be
  # a no-op here because common.sh has already exported the var, so we just
  # warn instead and tell the caller how to suppress.
  if [[ "$PIPELINE_WRITER" != "agent" ]]; then
    log "warning: PIPELINE_WRITER=$PIPELINE_WRITER writing a verdict (lane mismatch — set PIPELINE_WRITER=agent to suppress)"
  fi

  if [[ "${PIPELINE_DRY_RUN:-}" == "1" ]]; then
    printf '[DRY_RUN] would post on %s: %s\n' "$issue" "$body" >&2
    return 0
  fi

  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
}

# cmd_event_transition <issue> <from→to>
# The CLI argument uses the spaceful arrow form ("implementing → reviewing") for
# readability; the written marker uses two k=v pairs (from=X to=Y) so that
# parse_pipeline_marker produces {event:"transition",from:X,to:Y} — field-for-field
# consistent with the old-shape pipeline-transition: branch (Unicode U+2192).
cmd_event_transition() {
  local issue="$1"; shift
  local arrow="${1:-}"
  [[ -n "$issue" && -n "$arrow" ]] || die "event transition: usage: <issue> <from→to>"
  [[ "$arrow" == *"→"* ]] || die "event transition: argument must contain → (Unicode U+2192)"

  local from to
  from="${arrow%% → *}"
  to="${arrow##* → }"
  _validate_registry stages "$from"
  _validate_registry stages "$to"

  local body="<!-- pipeline: transition from=$from to=$to -->"

  if [[ "$PIPELINE_WRITER" != "orchestrator" ]]; then
    log "warning: PIPELINE_WRITER=$PIPELINE_WRITER writing a transition (lane mismatch — set PIPELINE_WRITER=orchestrator to suppress)"
  fi

  if [[ "${PIPELINE_DRY_RUN:-}" == "1" ]]; then
    printf '[DRY_RUN] would post on %s: %s\n' "$issue" "$body" >&2
    return 0
  fi

  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
}

# ── ENG-58 atomic-reset helpers (ported from halt.sh::resolve, ENG-60 merge) ──
#
# These run when an operator issues `bin/pipeline.sh decide <issue> --action continue`
# (the ENG-60 replacement for `bin/halt.sh resolve --decision resume`).
# Idempotent: every operation no-ops when the target is absent.

# _pipeline_drain_wait_files <issue>
# Remove every wait-<stage>.json under the per-issue state dir and return a
# count (via stdout) for the audit summary.
_pipeline_drain_wait_files() {
  local issue="$1"
  local d; d="$(issue_dir "$issue")"
  local wait_count=0
  if compgen -G "$d/wait-*.json" >/dev/null 2>&1; then
    wait_count="$(compgen -G "$d/wait-*.json" | wc -l | tr -d ' ')"
    rm -f "$d"/wait-*.json 2>/dev/null || true
  fi
  printf '%d' "$wait_count"
}

# _pipeline_drain_skip_labels <issue>
# Remove pipeline:skip-until-code-changes and pipeline:skip-until-human-acts
# labels if present. Returns count removed (via stdout).
_pipeline_drain_skip_labels() {
  local issue="$1"
  local skip_count=0
  for lbl in "pipeline:skip-until-code-changes" "pipeline:skip-until-human-acts"; do
    if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "$lbl" 2>/dev/null; then
      bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "$lbl" 2>/dev/null || true
      skip_count=$((skip_count + 1))
    fi
  done
  printf '%d' "$skip_count"
}

# _pipeline_drain_issue_state <issue>
# Drain classify-set fields (policy/reason/retry_count/exit_code/evidence/...)
# from issue-state.json when its .policy == "skip-until-human-acts".
# Preserves allocator-set fields (current_dispatch_seq/current_dispatch_id/
# current_stage) so post-resume monotonic increment holds: pre-ENG-87-review-
# iter-3 the rm -f path reset prior_seq to 0, the next allocator re-emitted
# d0001 → collision with the original first dispatch's id and re-introduced
# the V3 vulnerability the strict id-match path was designed to prevent.
# Skip-until-code-changes is unaffected (full file preserved for auto-resume
# evidence trail). Returns "true" when work was done, "false" otherwise.
_pipeline_drain_issue_state() {
  local issue="$1"
  local d; d="$(issue_dir "$issue")"
  local state_file="$d/issue-state.json"
  local state_drained=false
  if [[ -s "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then
    local policy
    policy="$(jq -r '.policy // ""' "$state_file" 2>/dev/null || printf '')"
    if [[ "$policy" == "skip-until-human-acts" ]]; then
      # Project to the allocator-owned subset; rm -f when no allocator
      # fields exist (legacy / pre-cutover issues), preserving the
      # original metric semantics for back-compat with PR-E / PR-N.
      local has_alloc
      has_alloc="$(jq -r 'has("current_dispatch_id") and (.current_dispatch_id // "") != ""' "$state_file" 2>/dev/null || printf 'false')"
      if [[ "$has_alloc" == "true" ]]; then
        local stripped tmp
        stripped="$(jq -c '{current_dispatch_seq, current_dispatch_id, current_stage}' "$state_file" 2>/dev/null || printf '{}')"
        tmp="${state_file}.tmp.$$"
        printf '%s' "$stripped" > "$tmp"
        mv -f "$tmp" "$state_file"
        log "pipeline-decide: stripped classify-set fields from $state_file (preserved current_dispatch_id)"
      else
        rm -f "$state_file"
        log "pipeline-decide: removed $state_file (policy=skip-until-human-acts, no allocator fields)"
      fi
      state_drained=true
    fi
  fi
  printf '%s' "$state_drained"
}

# _pipeline_post_operator_transition <issue> <stage>
# Posts a <!-- pipeline: transition from=X to=X reason=operator-resume -->
# waypoint comment. This is the ENG-60 new-shape equivalent of ENG-58's
# old-shape <!-- pipeline-transition: X → X (operator-resume) --> marker.
# find_fresh_verdict reads via parse_pipeline_marker (new shape only);
# count_marker_since_last_transition (guards.sh) accepts both shapes for
# in-flight back-compat. We emit the new shape here; tests assert on it
# explicitly.
_pipeline_post_operator_transition() {
  local issue="$1" stage="$2"
  # Sanitize stage name per D-014: only lowercase alpha passes; anything else
  # becomes "unknown" to prevent format-string injection.
  [[ "$stage" =~ ^[a-z]+$ ]] || stage="unknown"
  local waypoint_body
  waypoint_body="$(printf '<!-- pipeline: transition from=%s to=%s reason=operator-resume -->\n\nOperator-attributed transition waypoint (pipeline.sh decide --action continue).' \
    "$stage" "$stage")"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$waypoint_body"
}

# _pipeline_format_reset_audit <wait_count> <skip_count> <state_removed>
# Renders a human-readable audit sentence from the three scalar counters.
_pipeline_format_reset_audit() {
  local wf="$1" sl="$2" sf="$3"
  local state_phrase=""
  [[ "$sf" == "true" ]] && state_phrase=", issue-state.json removed"
  printf '_Cleared:_ %s wait file(s), %s skip-until-* label(s)%s.\n' \
    "${wf:-0}" "${sl:-0}" "$state_phrase"
}

# _pipeline_clear_breaker
# Always clear the global circuit breaker on `decide --action continue`.
# No-op when the breaker isn't tripped: set_orchestrator_paused false
# always writes "false" (idempotent), and rm -f shrugs at missing files.
# Returns "true|false" via stdout to indicate whether the breaker WAS
# tripped before the clear (for the audit metric).
#
# Why this lives in decide: ENG-58 promised "atomic reset" on continue,
# but only cleared per-issue side state. Self-leak halts trip the
# breaker on the same tick, so resume needed two operator commands. The
# breaker clear here completes the promise — see ENG-60-followup PR.
_pipeline_clear_breaker() {
  local was_paused="false"
  if [[ "$(is_orchestrator_paused 2>/dev/null)" == "true" ]]; then
    was_paused="true"
  fi
  set_orchestrator_paused false
  rm -f "$PROJECT_STATE_DIR/.consecutive-failures" 2>/dev/null || true
  printf '%s' "$was_paused"
}

# _pipeline_emit_resume_metric <issue> <stage> <wf> <sl> <sf> <waypoint_posted> [<breaker_was_paused>] [<auto_commit_count>]
_pipeline_emit_resume_metric() {
  local issue="$1" stage="$2" wf="$3" sl="$4" sf="$5" wp="$6"
  local breaker_was="${7:-false}" autocommit_n="${8:-0}"
  local stats="wait_files=$wf skip_labels=$sl state_file=$sf waypoint_posted=$wp breaker_was_paused=$breaker_was auto_commit_paths=$autocommit_n"
  bash "$SCRIPT_DIR/metrics.sh" halt-resume "$issue" "$stage" \
    "atomic-reset" 0 "$stats" || true
}

# cmd_decide <issue> --action <continue|approve|abandon> [--gate <gate>]
cmd_decide() {
  local issue="${1:-}"; shift || true
  [[ -n "$issue" ]] || die "decide: usage: <issue> --action <action> [--gate <gate>]"

  local action="" gate=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --action) action="${2:-}"; shift 2 ;;
      --gate)   gate="${2:-}"; shift 2 ;;
      *) die "decide: unknown flag '$1'" ;;
    esac
  done

  [[ -n "$action" ]] || die "decide: --action required"
  _validate_registry decision_actions "$action"

  # `continue` is the only action that may omit --gate; approve and abandon
  # require it.
  case "$action" in
    continue) [[ -z "$gate" ]] || die "decide continue: --gate not allowed (continue is gate-agnostic)" ;;
    approve|abandon)
      [[ -n "$gate" ]] || die "decide $action: --gate required"
      _validate_registry decision_gates "$gate" ;;
  esac

  # ENG-58 atomic reset (ported from halt.sh::resolve, ENG-60 merge).
  # On `continue` only: drain wait files, skip-until labels, issue-state
  # (conditionally), then post an operator-attributed transition waypoint so
  # count_marker_since_last_transition resets the rejection counters and
  # find_fresh_verdict freshness. Order follows D-008: cleanup BEFORE
  # posting the decision comment. The decision comment follows below.
  if [[ "$action" == "continue" ]]; then
    if [[ "${PIPELINE_DRY_RUN:-}" != "1" ]]; then
      # Issue-id validation: guard rm -f path-interpolation (D-014).
      # Only needed on the live path where we perform filesystem writes;
      # dry-run skips all FS ops so the guard is not required there.
      [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
        || die "decide: invalid issue id '$issue' (expected ENG-<digits>)"

      local current_stage
      current_stage="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue" 2>/dev/null || printf 'unknown')"
      current_stage="${current_stage#stage:}"
      # Sanitize: only lowercase alpha (D-014). Falls back to 'unknown'.
      [[ "$current_stage" =~ ^[a-z]+$ ]] || current_stage="unknown"

      local wf sl sf breaker_was autocommit_n
      wf="$(_pipeline_drain_wait_files "$issue")"
      sl="$(_pipeline_drain_skip_labels "$issue")"
      sf="$(_pipeline_drain_issue_state "$issue")"

      # Remove halt label if present (mirrors halt.sh rc=1 branch behavior).
      if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then
        bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
      fi

      # Option B (ENG-60-followup): clear the global circuit breaker. A
      # self-leak halt trips the breaker on the same tick the issue halts,
      # so per-issue state reset alone leaves the orchestrator paused. Always
      # clearing here completes the atomic-resume promise; no-op when the
      # breaker isn't tripped.
      breaker_was="$(_pipeline_clear_breaker)"

      # ENG-69: clear the per-issue consecutive-failures counter, sibling of
      # the global counter cleared by _pipeline_clear_breaker above. The
      # per-issue lane (route_run_stage_exit, tally_leaked_in_scope_failure)
      # writes to $(issue_dir)/.consecutive-failures; the atomic-resume
      # promise has to clear it too or the next escalation re-fires
      # immediately. rm -f is idempotent (no-op when missing). $issue is
      # already validated against ^ENG-[0-9]+$ at L324-325.
      rm -f "$(issue_dir "$issue")/.consecutive-failures" 2>/dev/null || true

      # Auto-commit any in-scope dirty paths in the worktree that the
      # tick-end sweep suppressed (typical: brainstorm doc / plan doc the
      # agent wrote but the breaker prevented from landing on origin).
      # Failures here log and return 0 — they must not block the resume.
      autocommit_n="$(auto_commit_in_scope "$issue" "$current_stage" || printf '0')"

      _pipeline_post_operator_transition "$issue" "$current_stage"
      _pipeline_emit_resume_metric "$issue" "$current_stage" "$wf" "$sl" "$sf" "1" "$breaker_was" "$autocommit_n"
      log "pipeline-decide: $issue action=continue (side state reset: wait_files=$wf skip_labels=$sl state_file=$sf breaker_was_paused=$breaker_was per_issue_counter_cleared=true auto_commit_paths=$autocommit_n; operator-transition posted)"
    else
      log "pipeline-decide: $issue action=continue (dry-run — atomic reset suppressed)"
    fi
  fi

  local body="<!-- pipeline: decision action=$action"
  [[ -n "$gate" ]] && body="$body gate=$gate"
  body="$body -->"

  if [[ "$PIPELINE_WRITER" != "human" ]]; then
    log "warning: PIPELINE_WRITER=$PIPELINE_WRITER writing a decision (lane mismatch — set PIPELINE_WRITER=human to suppress)"
  fi

  if [[ "${PIPELINE_DRY_RUN:-}" == "1" ]]; then
    printf '[DRY_RUN] would post on %s: %s\n' "$issue" "$body" >&2
    return 0
  fi

  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    status) cmd_status "$@" ;;
    event)  cmd_event "$@" ;;
    decide) cmd_decide "$@" ;;
    -h|--help|"") usage; [[ -z "$sub" ]] && exit 1 || exit 0 ;;
    *) usage; die "unknown subcommand: $sub" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
