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

# Validate $1 matches at least one of the pipe-separated registry names in $2.
# Used for fields like `target` whose allowed-enum depends on the arm
# (fail_targets for verdict.fail, pivot_targets for verdict.pivot). On no
# match, die with each registry's contents joined for operator triage.
_validate_registry_union() {
  local value="$1" union="$2"
  local IFS='|'
  read -r -a fields <<<"$union"
  local f
  for f in "${fields[@]}"; do
    if jq -e --arg f "$f" --arg v "$value" '.[$f] | index($v) // empty' "$REGISTRY" >/dev/null 2>&1; then
      return 0
    fi
  done
  local msg="registry: '$value' not in $union — allowed: "
  for f in "${fields[@]}"; do
    msg+="[$f: $(jq -r --arg f "$f" '.[$f] | join(", ")' "$REGISTRY")] "
  done
  die "$msg"
}

# ENG-112 schema validator. Reads events.<event>.linear_comment from the
# closed registry and enforces required-field-by-arm + field_registry rules
# against the supplied k=v args. Die-loud on any violation (D-005).
#
# Usage: _validate_event_payload <event> <arm> <k=v>...
#
# <arm> is the value of the result/action field for events that branch on it
# (verdict, decision). Pass empty string for events without arm-dependent
# rules (transition).
_validate_event_payload() {
  local event="$1" arm="$2"; shift 2 || true
  local schema
  schema="$(jq -c --arg e "$event" '.events[$e].linear_comment // empty' "$REGISTRY")"
  [[ -n "$schema" ]] || die "schema: no linear_comment for event '$event'"

  # Collect k=v args into a parallel keys[] + values[] arrays. Bash 3.2 on
  # macOS doesn't carry associative arrays without `declare -A`; pipeline.sh
  # already relies on declare -A elsewhere (TODO: it doesn't here — keep
  # indexed arrays for portability with sourced-test shells).
  local keys=() values=()
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    keys+=("$k")
    values+=("$v")
  done

  # Required-field set = required[] ∪ required_by_arm[$arm][].
  local req
  req="$(jq -r --arg a "$arm" '
    (.required // []) +
    ((.required_by_arm // {})[$a] // [])
    | .[]
  ' <<<"$schema")"
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local found=0 i
    for i in "${!keys[@]}"; do
      [[ "${keys[$i]}" == "$f" ]] && { found=1; break; }
    done
    (( found )) || die "$event ${arm:+$arm: }--$f required (schema: ${event} ${arm:+arm=$arm }got: ${keys[*]:-<none>})"
  done <<<"$req"

  # Per-field registry validation + unknown-field rejection.
  # The known-field set is (required ∪ optional ∪ field_registry keys).
  local known
  known="$(jq -r '
    (.required // []) + (.optional // []) +
    ((.required_by_arm // {}) | to_entries | map(.value[]) | flatten) +
    ((.field_registry // {}) | keys)
    | unique | .[]
  ' <<<"$schema")"

  local i
  for i in "${!keys[@]}"; do
    k="${keys[$i]}"
    v="${values[$i]}"
    grep -Fxq "$k" <<<"$known" \
      || die "schema: unknown field '$k' on event '$event' (known: $(tr '\n' ' ' <<<"$known"))"
    # ENG-115: arm-specific override wins when present. Lets verdict.pivot
    # validate `reason` against pivot_reasons (single registry — clean
    # "not in pivot_reasons" error) instead of widening the top-level
    # field_registry.reason union, which would also relax halt/wait reasons.
    local reg
    reg="$(jq -r --arg a "$arm" --arg k "$k" '
      (.field_registry_by_arm // {})[$a][$k] // .field_registry[$k] // empty
    ' <<<"$schema")"
    [[ -z "$reg" || "$reg" == "null" ]] && continue
    if [[ "$reg" == *"|"* ]]; then
      _validate_registry_union "$v" "$reg"
    else
      _validate_registry "$reg" "$v"
    fi
  done
}

# ENG-112 body renderer. Walks the body_shape template literal-by-literal,
# substitutes <field> placeholders from the supplied k=v args, and omits
# bracketed [k=<v>] groups when the field has no value. Caller is expected
# to have run _validate_event_payload first; defensive die on missing
# required placeholder.
#
# Usage: _render_body <event> <k=v>...  -> body string to stdout
_render_body() {
  local event="$1"; shift
  local tmpl
  tmpl="$(jq -r --arg e "$event" '.events[$e].linear_comment.body_shape // empty' "$REGISTRY")"
  [[ -n "$tmpl" ]] || die "schema: no body_shape for event '$event'"

  local keys=() values=()
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    keys+=("$k")
    values+=("$v")
  done

  # Walk the template token-by-token. Templates use three token shapes:
  #   1. literal text (anything not <field> and not [...])
  #   2. <field>         — required placeholder; die if missing
  #   3. [k=<field>]     — optional group; omit if field has no value
  #
  # Bash regex treats `\<` / `\>` as word boundaries, not literal angle
  # brackets, so we cannot use `[[ var =~ \<...\> ]]` to match placeholders.
  # Use awk-style char scanning instead. The template alphabet is restricted
  # to ASCII (enforced by the closed registry), so the simple parser below
  # is sufficient.
  local out=""
  local n=${#tmpl}
  local i=0
  while (( i < n )); do
    local ch="${tmpl:$i:1}"
    if [[ "$ch" == "[" ]]; then
      # Optional group: find the matching `]`. Templates embed the leading
      # space INSIDE the bracket (e.g. `[ stage=<stage>]`) so dropping the
      # group naturally drops both surrounding spaces — no trim/eat-space
      # gymnastics needed.
      local end=$i
      while (( end < n )) && [[ "${tmpl:$end:1}" != "]" ]]; do ((end++)); done
      (( end < n )) || die "schema: body_shape unterminated '[' at offset $i"
      local group="${tmpl:$((i+1)):$((end-i-1))}"
      # group looks like ` key=<field>` (with leading space). Split on `=`.
      local lit="${group%%=*}"
      local placeholder="${group#*=}"
      local fld="${placeholder#<}"
      fld="${fld%>}"
      local got=""
      local j
      for j in "${!keys[@]}"; do
        if [[ "${keys[$j]}" == "$fld" ]]; then got="${values[$j]}"; break; fi
      done
      [[ -n "$got" ]] && out+="$lit=$got"
      i=$((end+1))
    elif [[ "$ch" == "<" ]] && [[ "${tmpl:$((i+1)):1}" =~ [a-z] ]]; then
      # Required placeholder: `<` followed by `[a-z]` — distinguishes from
      # the literal `<!--` HTML-comment opener. Find the matching `>`.
      local end=$i
      while (( end < n )) && [[ "${tmpl:$end:1}" != ">" ]]; do ((end++)); done
      (( end < n )) || die "schema: body_shape unterminated '<' at offset $i"
      local fld="${tmpl:$((i+1)):$((end-i-1))}"
      local got=""
      local j
      for j in "${!keys[@]}"; do
        if [[ "${keys[$j]}" == "$fld" ]]; then got="${values[$j]}"; break; fi
      done
      [[ -n "$got" ]] || die "schema: body_shape requires '$fld' (got: ${keys[*]:-<none>})"
      out+="$got"
      i=$((end+1))
    else
      out+="$ch"
      ((i++))
    fi
  done
  printf '%s' "$out"
}

# cmd_event_verdict <issue> <result> [--stage X] [--target Y] [--reason Z]
cmd_event_verdict() {
  local issue="$1"; shift
  local result="${1:-}"; shift || true
  [[ -n "$issue" && -n "$result" ]] || die "event verdict: usage: <issue> <result> [args]"

  local stage="" target="" reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage)  stage="${2:-}"; shift 2 ;;
      --target) target="${2:-}"; shift 2 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      *) die "event verdict: unknown flag '$1'" ;;
    esac
  done

  # ENG-112: schema-driven validation + body render.
  local args=("result=$result")
  [[ -n "$stage" ]]  && args+=("stage=$stage")
  [[ -n "$target" ]] && args+=("target=$target")
  [[ -n "$reason" ]] && args+=("reason=$reason")
  _validate_event_payload verdict "$result" "${args[@]}"
  local body
  body="$(_render_body verdict "${args[@]}")"

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

  # ENG-112: schema-driven validation + body render. Arm slot is empty —
  # transition has no arm-dependent rules.
  local args=("from=$from" "to=$to")
  _validate_event_payload transition "" "${args[@]}"
  local body
  body="$(_render_body transition "${args[@]}")"

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
      # ENG-146: delegate the strip-vs-rm branch to common.sh's shared
      # helper so this code path and run-stage.sh's success cleanup
      # cannot drift. has_alloc=true → preserve {seq, id, stage};
      # has_alloc=false → rm -f (legacy back-compat).
      strip_state_preserve_alloc "$state_file"
      if [[ -e "$state_file" ]]; then
        log "pipeline-decide: stripped classify-set fields from $state_file (preserved current_dispatch_id)"
      else
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
# count_marker_since_last_operator_resume (guards.sh) reads this shape to
# clear the rejection counters. We emit the new shape here; tests assert
# on it explicitly.
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

# ENG-180 D-001: shared halt-label-clear used by both continue and
# approve --gate scope arms of cmd_decide. Idempotent: linear.sh
# remove-label is a no-op on missing label; the has-label guard
# short-circuits the call to keep the legacy log noise from the
# continue arm's prior inline shape.
_pipeline_clear_halt_label() {
  local issue="$1"
  if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then
    bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
  fi
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
  # count_marker_since_last_operator_resume resets the rejection counters and
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
      # ENG-180 D-001: shared helper; also called by the approve --gate scope arm below.
      _pipeline_clear_halt_label "$issue"

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

  # ENG-180 D-001: approve --gate scope must clear pipeline:halted, otherwise
  # poll.sh::_poll_classify_labels keeps the slot vacated and the replay
  # never runs. Scope is intentionally narrow: only the halt label, not the
  # full atomic reset. Mirrors the continue arm's cleanup-before-comment
  # ordering (see brainstorm OQ-4) so partial-failure is recoverable on a
  # re-run: halt-clear runs first; the decision comment writes last via
  # the shared add-comment call at the function tail.
  if [[ "$action" == "approve" && "$gate" == "scope" ]]; then
    if [[ "${PIPELINE_DRY_RUN:-}" != "1" ]]; then
      [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
        || die "decide: invalid issue id '$issue' (expected ENG-<digits>)"
      _pipeline_clear_halt_label "$issue"
      log "pipeline-decide: $issue action=approve gate=scope (halt label cleared)"
    else
      log "pipeline-decide: $issue action=approve gate=scope (dry-run — halt-clear suppressed)"
    fi
  fi

  # ENG-112: schema-driven validation + body render. The continue-rejects-gate
  # exclusion above stays inline (D-002 in plan); schema is inclusion-only.
  local _decide_args=("action=$action")
  [[ -n "$gate" ]] && _decide_args+=("gate=$gate")
  _validate_event_payload decision "$action" "${_decide_args[@]}"
  local body
  body="$(_render_body decision "${_decide_args[@]}")"

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
