#!/usr/bin/env bash
# Verdict Handler (ENG-18). Reads Linear comment history, finds the fresh
# verdict marker per the freshness rule, validates against the transition
# tables, performs atomic transitions. Source-able.
#
# Public functions:
#   verdict_handler <issue> <current_stage>   # 0=transitioned, 1=halt preserved, 2=protocol violation
#   find_fresh_verdict <issue>                # prints JSON {marker,source_stage,target_stage,reason,comment_id} or empty
#   apply_transition <issue> <from> <to> <side_effect_labels_csv>
#   resume_in_progress_transition <issue>     # 0=resumed, 1=nothing to resume

set -euo pipefail
_VH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$_VH_SCRIPT_DIR/common.sh"

# Forward transitions: happy-path stage advancement.
# Rows: <from>=<to>.
_VH_FORWARD_TRANSITIONS='
brainstorming=planning
planning=implementing
implementing=ui
ui=reviewing
reviewing=qa
qa=building
building=released
'

# Loopback transitions: rejection-verdict (source, target) pairs and the
# side-effect labels to apply. Rows: <from>|<to>|<csv-of-labels>. The
# pipe delimiter is load-bearing because label names contain `:`.
_VH_LOOPBACK_TRANSITIONS='
planning|brainstorming|pipeline:supersede
reviewing|brainstorming|pipeline:supersede
reviewing|implementing|
qa|implementing|
building|implementing|
'

_vh_lookup_forward() {
  local from="$1"
  grep -E "^${from}=" <<<"$_VH_FORWARD_TRANSITIONS" | head -1 | cut -d'=' -f2-
}

# Print the full row (from|to|labels) iff the (from,to) pair is legal.
_vh_lookup_loopback() {
  local from="$1" to="$2"
  awk -F'|' -v from="$from" -v to="$to" '$1==from && $2==to {print; exit}' \
    <<<"$_VH_LOOPBACK_TRANSITIONS"
}

_vh_protocol_violation() {
  local issue="$1" case_id="$2" reason="$3"
  local body
  body="$(printf '<!-- pipeline: verdict result=halt reason=protocol-violation -->\n\nProtocol violation (%s): %s' "$case_id" "$reason")"
  bash "$_VH_SCRIPT_DIR/linear.sh" add-comment "$issue" \
    --sig "protocol-violation/$case_id/$issue" --body "$body" || true
  bash "$_VH_SCRIPT_DIR/linear.sh" add-label "$issue" "pipeline:halted" || true
  # ENG-87 review-iter-7 M3: cross-file mutation of run-stage.sh's
  # verdict_emitted global is gone — _append_dispatch_end_row reads
  # find_fresh_verdict at trap-fire time and picks up the halt comment
  # this function just posted via add-comment.
  log "verdict-handler: protocol violation on $issue ($case_id): $reason"
}

# Inspect the issue's comment stream and the dispatch state to classify
# WHY find_fresh_verdict returned empty. Disambiguates two failure modes
# the caller (verdict_handler) used to collapse under case_id "no-marker":
#
#   (a) no-marker            — no `<!-- pipeline: verdict ... -->` markers
#                              exist on the issue at all.
#   (b) dispatch-id-mismatch — verdict markers exist AND `<!-- meta:
#                              dispatch id=… -->` markers exist, but none
#                              of the verdict comments carry the CURRENT
#                              dispatch_id (the ENG-87 strict-id path's
#                              "markers exist, none match" branch — see
#                              find_fresh_verdict lines 128-131). Most
#                              commonly an agent that emitted the marker
#                              manually in its stage-summary with a
#                              literal-placeholder (e.g. `$PIPELINE_DISPATCH_ID`),
#                              violating AGENT_PROMPTS.md §0 rule (1).
#
# Returns three pipe-delimited fields on stdout:
#   <case_id>|<curr_dispatch_id>|<observed_marker_csv>
# observed_marker_csv is unique-sorted, capped at 5 entries to keep the
# halt comment human-readable. Empty fields stay empty (never "<unset>"
# placeholder — the caller formats display).
_vh_classify_no_fresh_reason() {
  local issue="$1"
  local comments curr_id has_verdict observed case_id
  comments="$(bash "$_VH_SCRIPT_DIR/linear.sh" get-comments "$issue" 2>/dev/null || printf '[]')"
  curr_id="$(current_dispatch_id "$issue" 2>/dev/null || printf '')"
  has_verdict=0
  # `set -e` safety: a bare `grep && var=1` chain whose grep returns 1
  # (no match) exits the function nonzero. `if grep; then ... fi` is the
  # tested-context form, which set -e ignores.
  if grep -qF '<!-- pipeline: verdict ' <<<"$comments"; then
    has_verdict=1
  fi
  observed="$(grep -oE '<!-- meta: dispatch id=[^[:space:]>]+' <<<"$comments" \
    | sed -E 's|^<!-- meta: dispatch id=||' \
    | sort -u \
    | head -n 5 \
    | tr '\n' ',' \
    | sed 's/,$//' || true)"
  if [[ "$has_verdict" == "1" && -n "$curr_id" && -n "$observed" ]]; then
    case_id="dispatch-id-mismatch"
  else
    case_id="no-marker"
  fi
  printf '%s|%s|%s' "$case_id" "$curr_id" "$observed"
}

# Compose the human-readable halt body for an empty-fresh-verdict
# classification. Centralised so verdict_handler stays a flat dispatch
# table; the formatting is non-trivial enough (multi-line, multi-case)
# that inlining costs readability.
_vh_format_no_fresh_reason() {
  local issue="$1" case_id="$2" curr_id="$3" observed="$4"
  local curr_display="${curr_id:-<unset>}"
  local resolution="Resolution: \`bash bin/pipeline.sh decide $issue --action continue\` (clears halt + resets dispatch state on the next tick)."
  case "$case_id" in
    dispatch-id-mismatch)
      printf 'no verdict comment carries the current_dispatch_id `%s`. Observed dispatch-marker values on this issue: `%s`. Likely cause: an agent emitted `<!-- meta: dispatch id=... -->` manually in its stage-summary file (contract violation per AGENT_PROMPTS.md §0 rule 1 — the chokepoint at bin/linear.sh::add_comment owns this marker). %s' \
        "$curr_display" "$observed" "$resolution"
      ;;
    *)
      printf 'no fresh verdict marker on the issue (current_dispatch_id=`%s`). %s' \
        "$curr_display" "$resolution"
      ;;
  esac
}

# ENG-60 T2.13: drain legacy pipeline-namespace labels on every transition.
# These labels are folded into pipeline:halted / pipeline:abandoned per
# design §7.5; removing them on every transition cleans them out
# without a big-bang migration. linear.sh remove-label is a no-op when
# the label isn't present, so this is safe to run unconditionally.
# NOTE: pipeline:halted and pipeline:abandoned are NOT drained here —
# those are the two legacy-namespace labels we keep. pipeline:rule-reviewed
# is also excluded — it's the retrospective approval gate (orthogonal).
_vh_drain_legacy_labels() {
  local issue="$1"
  local legacy
  for legacy in pipeline:paused pipeline:scope-approval-needed pipeline:supersede pipeline:skip-until-code-changes pipeline:skip-until-human-acts; do
    bash "$_VH_SCRIPT_DIR/linear.sh" remove-label "$issue" "$legacy" 2>/dev/null || true
  done
}

# Extract the most recent verdict marker (verdict result=pass|fail|halt)
# that is newer than the most recent transition comment. decision and
# transition are not verdict shapes.
#
# Prints JSON {marker, source_stage, target_stage, reason, comment_id}
# or empty string when nothing fresh qualifies.
find_fresh_verdict() {
  local issue="$1"
  local comments
  comments="$(bash "$_VH_SCRIPT_DIR/linear.sh" get-comments "$issue")"
  [[ -z "$comments" || "$comments" == "null" ]] && { printf ''; return 0; }

  # ENG-87: dispatch_id-primary filter (D-005). When ANY comment on the
  # issue carries a dispatch marker, filter strictly by current
  # dispatch_id; legacy issues (no markers anywhere) fall through to the
  # timestamp-window code below.
  local _curr_id _has_any_marker
  _curr_id="$(current_dispatch_id "$issue" 2>/dev/null || printf '')"
  _has_any_marker=0
  if grep -qF '<!-- meta: dispatch id=' <<<"$comments"; then
    _has_any_marker=1
  fi

  local fresh_ts="" fresh_body="" fresh_id=""

  if [[ -n "$_curr_id" && "$_has_any_marker" == "1" ]]; then
    # Strict id-match path. Iterate verdict-event comments whose body
    # carries the current dispatch_id marker; pick the latest by ts.
    # Wait verdicts are excluded (not actionable).
    local _id_ts="" _id_body="" _id_id="" body ts id ev
    while IFS=$'\t' read -r ts id body; do
      ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
      [[ -z "$ev" ]] && continue
      [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
      [[ "$(jq -r '.result' <<<"$ev")" == "wait" ]] && continue
      # Comment body must carry the current dispatch_id marker.
      if ! grep -qF "<!-- meta: dispatch id=$_curr_id" <<<"$body"; then
        continue
      fi
      if [[ "$ts" > "$_id_ts" ]]; then
        _id_ts="$ts"; _id_body="$body"; _id_id="$id"
      fi
    done < <(jq -r '.[] | "\(.createdAt)\t\(.id)\t\(.body | gsub("\n"; " "))"' <<<"$comments")
    if [[ -n "$_id_body" ]]; then
      fresh_ts="$_id_ts"; fresh_body="$_id_body"; fresh_id="$_id_id"
    else
      # Markers exist but none match current → strict empty (no fresh
      # verdict from THIS dispatch yet). Caller treats as "no marker".
      printf ''
      return 0
    fi
  else
    # Legacy fallback (no markers on issue, or current_dispatch_id
    # unset): existing timestamp-window logic.
    local last_transition_ts=""
    local body ts id ev
    while IFS=$'\t' read -r ts body; do
      ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
      [[ -z "$ev" ]] && continue
      if [[ "$(jq -r '.event' <<<"$ev")" == "transition" ]]; then
        [[ "$ts" > "$last_transition_ts" ]] && last_transition_ts="$ts"
      fi
    done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

    while IFS=$'\t' read -r ts id body; do
      [[ -n "$last_transition_ts" && ! "$ts" > "$last_transition_ts" ]] && continue
      ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
      [[ -z "$ev" ]] && continue
      [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
      [[ "$(jq -r '.result' <<<"$ev")" == "wait" ]] && continue
      if [[ "$ts" > "$fresh_ts" ]]; then
        fresh_ts="$ts"; fresh_body="$body"; fresh_id="$id"
      fi
    done < <(jq -r '.[] | "\(.createdAt)\t\(.id)\t\(.body | gsub("\n"; " "))"' <<<"$comments")
  fi

  [[ -z "$fresh_body" ]] && { printf ''; return 0; }

  # Re-parse the fresh body and project to the legacy output shape that
  # callers (verdict_handler, run-stage.sh) expect:
  #   {marker, source_stage, target_stage, reason, comment_id}
  # New-shape rejections set source_stage:"" and rely on the T2.2 fallback in
  # apply_transition to read the issue's current stage:* label as the implicit source.
  local ev_json
  ev_json="$(parse_pipeline_marker "$fresh_body")"
  local result
  result="$(jq -nc \
    --argjson e "$ev_json" \
    --arg id "$fresh_id" '
      ($e.result) as $r |
      if $r == "pass" then
        {marker:"pipeline-stage-summary", source_stage:$e.stage, target_stage:"", reason:"", comment_id:$id, event:$e}
      elif $r == "fail" then
        {marker:"pipeline-rejection", source_stage:"", target_stage:$e.target, reason:"", comment_id:$id, event:$e}
      elif $r == "halt" then
        {marker:"pipeline-halt", source_stage:"", target_stage:"", reason:$e.reason, comment_id:$id, event:$e}
      else
        {marker:"unknown", source_stage:"", target_stage:"", reason:"", comment_id:$id, event:$e}
      end')"
  printf '%s' "$result"
}

# ─── ENG-85: wait-only sibling of find_fresh_verdict ────────────────
# Returns the latest wait verdict marker that is newer than the most
# recent transition AND is itself the latest verdict in that window.
# If a later pass/fail/halt exists, the wait has been superseded
# and this returns empty (matching `_fresh_wait_reason`'s ENG-61 Bug B
# rule in bin/run-stage.sh). No stage gate — caller decides.
#
# Output JSON: {"reason": "...", "comment_id": "...", "created_at": "..."}
#              OR empty string when no fresh wait qualifies.
find_fresh_wait_verdict() {
  local issue="$1"
  local comments
  comments="$(bash "$_VH_SCRIPT_DIR/linear.sh" get-comments "$issue" 2>/dev/null)" || { printf ''; return 0; }
  [[ -z "$comments" || "$comments" == "null" ]] && { printf ''; return 0; }

  local last_transition_ts="" ts body ev
  while IFS=$'\t' read -r ts body; do
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    if [[ "$(jq -r '.event' <<<"$ev")" == "transition" ]]; then
      [[ "$ts" > "$last_transition_ts" ]] && last_transition_ts="$ts"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  local fresh_ts="" fresh_id="" fresh_result="" fresh_reason="" id
  while IFS=$'\t' read -r ts id body; do
    [[ -n "$last_transition_ts" && ! "$ts" > "$last_transition_ts" ]] && continue
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
    if [[ "$ts" > "$fresh_ts" ]]; then
      fresh_ts="$ts"
      fresh_id="$id"
      fresh_result="$(jq -r '.result' <<<"$ev")"
      fresh_reason="$(jq -r '.reason // ""' <<<"$ev")"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.id)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  [[ "$fresh_result" != "wait" ]] && { printf ''; return 0; }
  [[ -z "$fresh_reason" ]] && { printf ''; return 0; }

  jq -nc \
    --arg r "$fresh_reason" \
    --arg id "$fresh_id" \
    --arg ts "$fresh_ts" \
    '{reason:$r, comment_id:$id, created_at:$ts}'
}

# Atomic transition order (per brainstorm §Atomic transition order):
#   1. Post <!-- pipeline: transition from=X to=Y --> comment (freshness waypoint).
#   2. Add stage:<to> label.
#   3. Remove stage:<from> label.
#   3.5. Native-state hook: if to == reviewing, flip Linear status to In Review.
#   4. Apply side-effect labels (csv).
#   5. Remove pipeline:halted.
# Each step is idempotent; resume_in_progress_transition can re-enter
# at any point and finish cleanly.
apply_transition() {
  local issue="$1" from="$2" to="$3" side_labels="${4:-}"
  local post_waypoint="${5:-1}"  # internal: resume path passes 0 to skip step 1

  if [[ "$post_waypoint" == "1" ]]; then
    local transition_body
    transition_body="$(printf '<!-- pipeline: transition from=%s to=%s -->\n\nOrchestrator transition waypoint.' "$from" "$to")"
    bash "$_VH_SCRIPT_DIR/linear.sh" add-comment "$issue" "$transition_body" || true
  fi

  bash "$_VH_SCRIPT_DIR/linear.sh" add-label "$issue" "stage:${to}" || true
  _vh_drain_legacy_labels "$issue"
  [[ -n "$from" ]] && bash "$_VH_SCRIPT_DIR/linear.sh" remove-label "$issue" "stage:${from}" || true

  if [[ "$to" == "reviewing" ]]; then
    local in_review_state
    in_review_state="$(jq -r '.linear.native_states.in_review // empty' "$CONFIG")"
    if [[ -n "$in_review_state" ]]; then
      bash "$_VH_SCRIPT_DIR/linear.sh" transition-state "$issue" "$in_review_state" || true
    else
      log "verdict-handler: skipping native-state hook to In Review (config.linear.native_states.in_review not set)"
    fi
  elif [[ "$to" == "released" ]]; then
    local done_state
    done_state="$(jq -r '.linear.native_states.done // empty' "$CONFIG")"
    if [[ -n "$done_state" ]]; then
      bash "$_VH_SCRIPT_DIR/linear.sh" transition-state "$issue" "$done_state" || true
    else
      log "verdict-handler: skipping native-state hook to Done (config.linear.native_states.done not set)"
    fi
  fi

  # ENG-49 Gap #1: orchestrator opens PR when transitioning to reviewing.
  # Idempotent — skipped if a PR already exists on the branch. Failure
  # logs and proceeds; resume_in_progress_transition re-enters next tick.
  #
  # ENG-49 Gap #8 (out-of-scope): the PR is opened by the same GitHub
  # App identity that runs the review stage, so `gh pr review` is
  # blocked. Fix needs a separate bot identity; tracked as a follow-up.
  if [[ "$to" == "reviewing" ]]; then
    local branch pr_count
    # ENG-53 #1: derive the branch via the same convention that creates
    # the worktree (bin/branch-name.sh — `feat/eng-N-<slug>` or
    # `fix/eng-N-<slug>`) instead of via Linear's auto-generated
    # gitBranchName. Two reasons: (1) Linear's format
    # `rajatgoyal/eng-N-with_underscores` does not match the harness's
    # actual branch `feat/eng-N-with-hyphens`, so a populated value would
    # still mis-key `gh pr list --head`; (2) bin/linear.sh::get_issue
    # does not select gitBranchName in its GraphQL query, so the prior
    # `jq -r '.data.issue.gitBranchName // empty'` was unconditionally
    # empty and this hook was DOA since de50f63 (ENG-49).
    branch="$(bash "$_VH_SCRIPT_DIR/branch-name.sh" "$issue" 2>/dev/null || true)"
    if [[ -z "$branch" ]]; then
      log "verdict-handler: skipping PR-create hook (no branch on $issue)"
    else
      pr_count="$(gh pr list --head "$branch" --state open --json number --jq 'length' 2>/dev/null || printf '0')"
      if (( pr_count == 0 )); then
        # Source render-pr-body.sh on demand. Prefer same-dir; fall back to PATH.
        if [[ -z "${_RPB_LOADED:-}" ]]; then
          local rpb
          rpb="$_VH_SCRIPT_DIR/render-pr-body.sh"
          [[ -f "$rpb" ]] || rpb="$(command -v render-pr-body.sh || true)"
          if [[ -f "$rpb" ]]; then
            # shellcheck source=render-pr-body.sh
            source "$rpb"
            _RPB_LOADED=1
          else
            log "verdict-handler: render-pr-body.sh not found; cannot open PR"
            return 0
          fi
        fi
        # Use _rpb_title and _rpb_title_type from render-pr-body.sh.
        # _RPB_LINEAR_SH defaults to $_RPB_SCRIPT_DIR/linear.sh which
        # equals $_VH_SCRIPT_DIR/linear.sh in production; tests override
        # _VH_SCRIPT_DIR and PATH-prepend their stub dir so the stubbed
        # render-pr-body.sh's helpers fire instead.
        # ENG-53 #6: lowercase the issue id in the PR title scope. The
        # harness's merge-title regex (build-stage preflight P7) requires
        # `[a-z0-9-]+` for the scope; passing `$issue` verbatim produces
        # `fix(ENG-44):` which fails the regex. Build agent today auto-
        # fixes via `gh pr edit --title`, but that is silent drift; emit
        # the correct form at the source.
        local title type linear_title body issue_lower
        linear_title="$(_rpb_title "$issue")"
        [[ -z "$linear_title" ]] && linear_title="$issue"
        type="$(_rpb_title_type "$issue")"
        issue_lower="$(printf '%s' "$issue" | tr '[:upper:]' '[:lower:]')"
        title="$(printf '%s(%s): %s' "$type" "$issue_lower" "$linear_title")"
        body="$(render_pr_body "$issue" "$branch" 2>/dev/null || printf '%s\n' "Linear: $issue")"
        if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
          log "verdict-handler: [DRY_RUN] would gh pr create --head $branch --title '$title'"
        else
          gh pr create --head "$branch" --title "$title" --body "$body" >/dev/null 2>&1 \
            || log "verdict-handler: gh pr create failed for $issue (next tick will retry idempotently)"
        fi
      else
        log "verdict-handler: PR already open for $issue on $branch — skipping create"
      fi
    fi
  fi

  # ENG-50: bootstrap last-review-state for poll.sh's review_should_dispatch.
  # Idempotent — overwrites any previous state to all-null on each entry
  # to stage:reviewing (loopback re-entries get a fresh state per tick).
  if [[ "$to" == "reviewing" ]]; then
    bash "$_VH_SCRIPT_DIR/review-state.sh" bootstrap "$issue" || \
      log "verdict-handler: review-state bootstrap failed for $issue (continuing)"
  fi

  if [[ -n "$side_labels" ]]; then
    local IFS_SAVE="$IFS"
    IFS=','
    for label in $side_labels; do
      [[ -z "$label" ]] && continue
      bash "$_VH_SCRIPT_DIR/linear.sh" add-label "$issue" "$label" || true
    done
    IFS="$IFS_SAVE"
  fi

  bash "$_VH_SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted" || true
  log "verdict-handler: applied transition $issue: $from → $to (side=${side_labels:-none})"
}

# Detect a mid-transition crash: a <!-- pipeline: transition from=X to=Y -->
# comment exists and is the most recent transition, but current stage
# is still :X and pipeline:halted is still applied. Complete the
# remaining label operations (skip the transition-comment post; it was
# already done before the crash).
resume_in_progress_transition() {
  local issue="$1"
  local comments from to current_stage has_halt
  comments="$(bash "$_VH_SCRIPT_DIR/linear.sh" get-comments "$issue")"
  [[ -z "$comments" || "$comments" == "null" ]] && return 1

  # Iterate comments through parse_pipeline_marker; pick the latest event=transition
  # by createdAt and extract its from/to. Comments without a recognizable marker
  # are skipped. Capture the body itself (last_body) for the ENG-87 dispatch_id
  # mismatch guard below.
  local last_ts="" last_body="" ts body ev
  from=""; to=""
  while IFS=$'\t' read -r ts body; do
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    [[ "$(jq -r '.event' <<<"$ev")" != "transition" ]] && continue
    if [[ "$ts" > "$last_ts" ]]; then
      last_ts="$ts"
      last_body="$body"
      from="$(jq -r '.from // ""' <<<"$ev")"
      to="$(jq -r '.to // ""' <<<"$ev")"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")
  [[ -z "$from" || -z "$to" ]] && return 1

  # ENG-87 §4.3: dispatch_id-mismatch guard. When the latest transition
  # comment carries a dispatch marker, compare against the current
  # dispatch id. A mismatch means the transition is from a prior cycle —
  # refuse to compound. Strictly stronger than the existing labels-
  # cross-check (which stays as legacy fallback for unmarked transitions
  # per D-005).
  local _curr_id _last_dispatch_id
  _curr_id="$(current_dispatch_id "$issue" 2>/dev/null || printf '')"
  if [[ -n "$_curr_id" ]]; then
    # ENG-87 review-iter-7 m1: tail -1 (not head -1). _inject_dispatch_marker
    # always APPENDS its marker (last line), so the writer's contract is
    # "last marker is canonical." Pre-iter-7 the reader used head -1
    # which on a body that legitimately quotes a prior marker (e.g., a
    # halt body diagnosing cross-dispatch staleness) would return the
    # quoted-prose id, not the auto-injected real id at the tail.
    _last_dispatch_id="$(grep -oE '<!-- meta: dispatch id=[^[:space:]>]+' <<<"$last_body" \
      | tail -1 | sed -E 's/.*id=//')"
    if [[ -n "$_last_dispatch_id" && "$_last_dispatch_id" != "$_curr_id" ]]; then
      log "verdict-handler: skipping resume — transition dispatch_id ($_last_dispatch_id) != current ($_curr_id)"
      return 1
    fi
  fi

  current_stage="$(bash "$_VH_SCRIPT_DIR/linear.sh" stage-of "$issue")"
  current_stage="${current_stage#stage:}"

  # Guard 1: already at destination — nothing to resume.
  [[ "$current_stage" == "$to" ]] && return 1

  # Guard 2 (NEW): comment.from disagrees with labels.from — comment is stale or forged.
  if [[ "$current_stage" != "$from" ]]; then
    log "verdict-handler: skipping resume — labels(from=$current_stage) disagree with comment(from=$from)"
    return 1
  fi

  # Guard 3 (NEW): issue carries multiple stage:* labels — malformed, refuse to compound.
  local all_stages
  all_stages="$(bash "$_VH_SCRIPT_DIR/linear.sh" all-stage-labels "$issue")"
  if [[ "$(wc -w <<<"$all_stages")" -gt 1 ]]; then
    log "verdict-handler: skipping resume — multiple stage:* labels: $all_stages"
    return 1
  fi

  # Existing condition — preserved.
  if bash "$_VH_SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted"; then
    log "verdict-handler: resuming mid-transition $issue: $from → $to"
    apply_transition "$issue" "$from" "$to" "" 0
    return 0
  fi
  return 1
}

# Main entrypoint. Dispatches on the fresh verdict marker shape.
verdict_handler() {
  local issue="$1" current_stage="$2"

  if resume_in_progress_transition "$issue"; then
    log "verdict-handler: resumed in-progress transition for $issue"
    return 0
  fi

  local fresh
  fresh="$(find_fresh_verdict "$issue")"
  if [[ -z "$fresh" ]]; then
    # ENG-96: classify WHY no fresh verdict was found and emit an
    # operator-actionable halt body. The two failure modes used to
    # collapse under case_id "no-marker"; that masked the
    # dispatch-id-mismatch mode (ENG-87 strict-id path empty), which is
    # almost always an agent contract violation rather than a missing
    # verdict marker. See _vh_classify_no_fresh_reason.
    local classification case_id curr_id observed reason
    classification="$(_vh_classify_no_fresh_reason "$issue")"
    IFS='|' read -r case_id curr_id observed <<<"$classification"
    reason="$(_vh_format_no_fresh_reason "$issue" "$case_id" "$curr_id" "$observed")"
    _vh_protocol_violation "$issue" "$case_id" "$reason"
    return 2
  fi

  local mtype src tgt
  mtype="$(jq -r '.marker' <<<"$fresh")"
  src="$(jq -r '.source_stage' <<<"$fresh")"
  tgt="$(jq -r '.target_stage' <<<"$fresh")"

  case "$mtype" in
    pipeline-stage-summary)
      if [[ "$src" != "$current_stage" ]]; then
        _vh_protocol_violation "$issue" "stage-mismatch" \
          "stage-summary source=$src != current=$current_stage"
        return 2
      fi
      local fwd; fwd="$(_vh_lookup_forward "$src")"
      if [[ -z "$fwd" ]]; then
        _vh_protocol_violation "$issue" "unknown-forward" \
          "no forward transition from $src"
        return 2
      fi
      apply_transition "$issue" "$src" "$fwd" ""
      return 0
      ;;
    pipeline-rejection)
      # ENG-60 T2.2 & T3.2: new-shape rejections set source_stage:"" and rely
      # on the issue's current stage:* label as the implicit source.
      if [[ -z "$src" ]]; then
        # Reuse linear.sh's stage-of subcommand instead of inlining the jq —
        # keeps the stage-label extraction logic in one place.
        src="$(bash "$_VH_SCRIPT_DIR/linear.sh" stage-of "$issue")"
        src="${src#stage:}"
        [[ -n "$src" ]] || {
          _vh_protocol_violation "$issue" "rejection-source-unknown" \
            "new-shape rejection has no source marker and no stage:* label"
          return 2
        }
      fi
      local row; row="$(_vh_lookup_loopback "$src" "$tgt")"
      if [[ -z "$row" ]]; then
        _vh_protocol_violation "$issue" "unknown-loopback" \
          "rejection ($src → $tgt) not in loopback table"
        return 2
      fi
      local side; side="$(cut -d'|' -f3 <<<"$row")"
      apply_transition "$issue" "$src" "$tgt" "$side"
      return 0
      ;;
    pipeline-halt)
      log "verdict-handler: halt marker on $issue (reason=$(jq -r '.reason' <<<"$fresh")) — leaving halt intact"
      return 1
      ;;
    *)
      _vh_protocol_violation "$issue" "unknown-marker" "marker=$mtype"
      return 2
      ;;
  esac
}

export -f verdict_handler find_fresh_verdict find_fresh_wait_verdict apply_transition resume_in_progress_transition
