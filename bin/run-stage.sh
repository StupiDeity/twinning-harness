#!/usr/bin/env bash
# Run a single pipeline stage against a Linear issue.
# Usage: run-stage.sh <issue_id> <stage>
# Exit codes: 0=success, 10=guards-tripped, 11=paused, 12=reconcile-human, 20=dispatch-failed.
#
# Caller contract: run-stage.sh expects the issue to already carry stage:<X> for the
# stage being run (the poller sets this on entry). On success, run-stage.sh advances
# the label to the NEXT stage in the pipeline. On reject loops, guards+metrics handle bookkeeping.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

next_stage() {
  # Canonical happy-path advancement.
  case "$1" in
    brainstorm)    printf 'planning' ;;
    plan)          printf 'implementing' ;;
    implement)     printf 'ui' ;;
    ui)            printf 'reviewing' ;;
    review)        printf 'qa' ;;           # approve-path; reject handled separately
    qa)            printf 'building' ;;     # pass-path; fail handled separately
    build)         printf 'released' ;;
    release)       printf '' ;;             # terminal
    retrospective) printf '' ;;             # not part of per-issue flow
    *)             die "unknown stage: $1" ;;
  esac
}

verify_preconditions() {
  local ident="$1" stage="$2"

  # Global pause?
  local paused
  paused="$(config_get '.orchestrator.paused')"
  if [[ "$paused" == "true" ]]; then
    log "orchestrator globally paused"
    return 11
  fi

  # Per-issue pause?
  if bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:paused"; then
    log "issue paused via pipeline:paused label"
    return 11
  fi

  # Expected stage label present?
  local prefix expected
  prefix="$(config_get '.linear.stage_label_prefix')"
  expected="${prefix}${stage//brainstorm/brainstorming}"  # handle abbreviation
  expected="${expected//implement/implementing}"
  expected="${expected//review/reviewing}"
  expected="${expected//plan/planning}"
  expected="${expected//build/building}"
  expected="${expected//release/released}"
  expected="${expected//qa/qa}"
  expected="${expected//ui/ui}"
  # Simpler: just derive from the canonical ordering.
  expected="$(bash -c "
    case '$stage' in
      brainstorm) echo '${prefix}brainstorming' ;;
      plan)       echo '${prefix}planning' ;;
      implement)  echo '${prefix}implementing' ;;
      ui)         echo '${prefix}ui' ;;
      review)     echo '${prefix}reviewing' ;;
      qa)         echo '${prefix}qa' ;;
      build)      echo '${prefix}building' ;;
      release)    echo '${prefix}released' ;;
    esac
  ")"

  if [[ -n "$expected" ]] && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "$expected"; then
    die "precondition failed: $ident does not carry $expected (must be applied before run-stage)"
  fi

  return 0
}

advance_label() {
  local ident="$1" stage="$2" nxt="$3"
  local prefix
  prefix="$(config_get '.linear.stage_label_prefix')"
  bash "$SCRIPT_DIR/linear.sh" swap-stage "$ident" "$nxt"

  # Release transition: also flip Linear status to Done.
  if [[ "$nxt" == "released" ]]; then
    local done_state
    done_state="$(config_get '.linear.native_states.done')"
    bash "$SCRIPT_DIR/linear.sh" transition-state "$ident" "$done_state"
  fi
}

main() {
  local ident="${1:-}" stage="${2:-}"
  [[ -n "$ident" && -n "$stage" ]] || die "usage: run-stage.sh <issue_id> <stage>"

  local t0 t1 duration
  t0="$(date +%s)"

  # Preconditions.
  verify_preconditions "$ident" "$stage" || {
    local rc=$?
    bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" "paused" 0 \
      || true
    exit "$rc"
  }

  # Guards (threshold-based human gates).
  if ! bash "$SCRIPT_DIR/guards.sh" check "$ident" 2>/dev/null; then
    local tripped
    tripped="$(bash "$SCRIPT_DIR/guards.sh" check "$ident" 2>&1 || true)"
    log "guards tripped: $tripped"
    bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" \
      "Pipeline paused: human review required ($tripped). Apply the corresponding pipeline:*-reviewed label to resume."
    bash "$SCRIPT_DIR/slack.sh" warn "Issue $ident paused pending human review: $tripped"
    bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" "guards-tripped" 0 "$tripped"
    exit 10
  fi

  # Reconcile (brainstorm/plan only).
  if [[ "$stage" == "brainstorm" || "$stage" == "plan" ]]; then
    local reconcile_kind
    [[ "$stage" == "brainstorm" ]] && reconcile_kind="brainstorm" || reconcile_kind="plan"
    local decision
    decision="$(bash "$SCRIPT_DIR/reconcile.sh" "$ident" "$reconcile_kind")"
    case "$decision" in
      proceed)
        log "reconcile: proceed"
        ;;
      link:*)
        local doc_path="${decision#link:}"
        log "reconcile: linking to existing $doc_path"
        bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" \
          "Pipeline reconcile: existing $reconcile_kind doc is canonical: \`$doc_path\`. Advancing without regeneration."
        local nxt; nxt="$(next_stage "$stage")"
        [[ -n "$nxt" ]] && advance_label "$ident" "$stage" "$nxt"
        bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "linked" 0 "doc=$doc_path"
        return 0
        ;;
      human)
        log "reconcile: human required"
        bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" \
          "Pipeline reconcile: an existing $reconcile_kind doc appears to cover this topic. Apply one of: \`pipeline:supersede\` (generate fresh and retire the old), \`pipeline:extend\` (generate fresh, referencing the old), or \`pipeline:ignore\` (link the old as canonical). Until a label is applied, this issue is paused."
        bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" "reconcile-human" 0
        exit 12
        ;;
      *)
        die "unexpected reconcile output: $decision"
        ;;
    esac
  fi

  # Render the prompt.
  local prompt_file log_file
  prompt_file="$(mktemp -t pipeline-prompt-XXXXXX)"
  log_file="$REPO_ROOT/logs/pipeline/${ident}-${stage}-$(date -u +%Y%m%dT%H%M%SZ).log"
  mkdir -p "$(dirname "$log_file")"
  bash "$SCRIPT_DIR/render-prompt.sh" "$stage" "$ident" > "$prompt_file"
  log "rendered prompt: $prompt_file ($(wc -l < "$prompt_file") lines)"

  bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" "dispatching" 0

  # Dispatch.
  if ! bash "$SCRIPT_DIR/dispatch.sh" "$stage" "$prompt_file" "$log_file"; then
    t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
    bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "failed" "$duration" "log=$log_file"
    bash "$SCRIPT_DIR/slack.sh" error "Stage $stage failed for $ident (log: $log_file)"
    rm -f "$prompt_file"
    exit 20
  fi
  rm -f "$prompt_file"

  # Advance label.
  local nxt
  nxt="$(next_stage "$stage")"
  if [[ -n "$nxt" ]]; then
    advance_label "$ident" "$stage" "$nxt"
  fi

  t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
  bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "success" "$duration" "next=$nxt"
  log "stage $stage complete for $ident (next: ${nxt:-terminal})"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
