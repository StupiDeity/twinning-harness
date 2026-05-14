#!/usr/bin/env bash
# Pipeline status dashboard — one terminal-friendly snapshot of everything live.
# Usage: bash .pipeline/bin/status.sh
#
# Aggregates four sources:
#   1. In-flight / recent pipeline.yml runs (via `gh`).
#   2. Active Linear issues carrying any stage:* label (label + state + age).
#   3. Last 10 JSONL metrics events (.pipeline/metrics/events.jsonl).
#   4. pipeline-metric:* marker comments posted on active issues in the last hour.
#
# Read-only. Exits 0 even if sections partially fail — partial signal is better
# than no signal. Colour highlights in ANSI; pipe through `less -R` if needed.
#
# Thresholds for colour flags (red / yellow):
#   - stage:implementing       red  if label age > 120 min
#   - any other active stage   yellow if label age > 60 min
#   - workflow run             red  on conclusion=failure, yellow on in_progress/pending/queued
#
# Designed to run locally or in CI (status comment). No external deps beyond jq,
# gh, curl; no network calls beyond Linear's /graphql and GitHub's API via gh.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ANSI helpers (no colour when NO_COLOR is set or stdout isn't a TTY).
if [[ -n "${NO_COLOR:-}" ]] || ! [[ -t 1 ]]; then
  C_RED= C_YEL= C_CYA= C_DIM= C_BLD= C_RST=
else
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_CYA=$'\033[36m'
  C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
fi

now_epoch() { date -u +%s; }

# Format minutes into a short human string: 5m, 1h12m, 2d3h.
fmt_age() {
  local m="$1"
  if   (( m < 60 ));   then printf '%dm' "$m"
  elif (( m < 1440 )); then printf '%dh%dm' $((m/60)) $((m%60))
  else                      printf '%dd%dh' $((m/1440)) $(((m%1440)/60))
  fi
}

section() {
  printf '\n%s== %s ==%s\n' "$C_BLD$C_CYA" "$1" "$C_RST"
}

# ───────────────────────────────────────────────────────────── Section 1: runs

show_runs() {
  section "Pipeline.yml runs (last 10)"
  if ! command -v gh >/dev/null 2>&1; then
    printf '  %s(gh not installed; skip)%s\n' "$C_DIM" "$C_RST"
    return 0
  fi

  local json now
  now="$(now_epoch)"
  if ! json="$(gh run list --workflow=pipeline.yml --limit 10 \
    --json databaseId,conclusion,status,createdAt,displayTitle 2>/dev/null)"; then
    printf '  %s(gh run list failed; skip)%s\n' "$C_DIM" "$C_RST"
    return 0
  fi

  jq -r --arg now "$now" '
    .[] | [
      .databaseId,
      .status,
      (if (.conclusion // "") == "" then "-" else .conclusion end),
      ((($now | tonumber) - (.createdAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601))/60 | floor),
      ((.displayTitle // "Pipeline") | if . == "" then "Pipeline" else . end)
    ] | @tsv
  ' <<<"$json" \
  | while IFS=$'\t' read -r id status conclusion age_min title; do
      local col="" reset=""
      case "$status" in
        in_progress|pending|queued) col="$C_YEL" ;;
      esac
      [[ "$conclusion" == "failure" ]] && col="$C_RED"
      [[ -n "$col" ]] && reset="$C_RST"
      printf '  %s●%s  %-11s  %-11s  %-7s  age=%-6s  %s\n' \
        "$col" "$reset" "$id" "$status" "$conclusion" "$(fmt_age "$age_min")" "$title"
    done
}

# ─────────────────────────────────────────────────────── Section 2: active issues

show_active_issues() {
  section "Active issues (stage:* labels)"

  if [[ -z "${LINEAR_API_KEY-}" ]]; then
    printf '  %s(LINEAR_API_KEY not set; skip)%s\n' "$C_DIM" "$C_RST"
    return 0
  fi

  local now rows=""
  now="$(now_epoch)"

  # Iterate every configured workflow_stage (except released) — one query each.
  local stage
  while IFS= read -r stage; do
    [[ -z "$stage" || "$stage" == "released" ]] && continue
    local label="stage:$stage"
    local json
    json="$(bash "$SCRIPT_DIR/linear.sh" list-issues-with-label "$label" 2>/dev/null || printf '{}')"
    rows+="$(jq -r --arg label "$label" --arg now "$now" '
      .data.issues.nodes[]?
      | select(.state.name != "Done")
      | [
          .identifier,
          $label,
          .state.name,
          ((($now | tonumber) - (.updatedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601))/60 | floor),
          (([.labels.nodes[].name] | map(select(startswith("pipeline:"))) | join(",")) | if . == "" then "-" else . end)
        ] | @tsv
    ' <<<"$json")"$'\n'
  done < <(jq -r '.linear.workflow_stages[]?' "$CONFIG")

  if [[ -z "${rows// /}" ]]; then
    printf '  %s(no issues carrying any stage:* label)%s\n' "$C_DIM" "$C_RST"
    return 0
  fi

  # Sort by age DESC (stalls float to top) and colour-flag.
  printf '%s' "$rows" | grep -v '^$' | sort -t$'\t' -k4 -nr \
  | while IFS=$'\t' read -r ident label native_state age_min controls; do
      local col="" reset=""
      if [[ "$label" == "stage:implementing" && "$age_min" -gt 120 ]]; then
        col="$C_RED"
      elif [[ "$age_min" -gt 60 ]]; then
        col="$C_YEL"
      fi
      [[ -n "$col" ]] && reset="$C_RST"
      printf '  %s%-6s%s  %-22s  native=%-12s  age=%-6s%s%s\n' \
        "$col" "$ident" "$reset" "$label" "$native_state" "$(fmt_age "$age_min")" \
        "${controls:+  ctrl=[$controls]}" ""
    done
}

# ──────────────────────────────────────────────────────── Section 3: JSONL events

show_metrics() {
  section "Last 10 JSONL metrics events"
  local jsonl="$PROJECT_STATE_DIR/metrics/events.jsonl"
  if [[ ! -f "$jsonl" ]]; then
    printf '  %s(no events.jsonl yet)%s\n' "$C_DIM" "$C_RST"
    return 0
  fi
  tail -n 10 "$jsonl" | jq -r '
    [
      .ts[0:19],
      .event,
      (if (.issue_id // "") == "" then "-" else .issue_id end),
      (if (.stage // "") == "" then "-" else .stage end),
      .outcome,
      .duration_ms,
      (if (.notes // "") == "" then "-" else (.notes | .[0:80]) end)
    ] | @tsv
  ' | awk -F'\t' -v red="$C_RED" -v yel="$C_YEL" -v rst="$C_RST" '{
    col = "";
    if ($5 == "failed" || $5 == "scope-violation" || $5 == "pr-opened-too-early" || $5 == "premise-failure" || $5 == "dispatch-failed" || $5 == "linear-post-failed" || $5 == "guards-tripped") col = red;
    else if ($5 == "linked" || $5 == "paused" || $5 == "scope-approval-pending" || $5 == "scope-approval-replay" || $5 == "reconcile-human") col = yel;
    reset = col ? rst : "";
    dur_s = ($6 > 0) ? sprintf("%ds", $6/1000) : "-";
    printf "  %s%s  %s/%s  %s  %-7s  dur=%-6s  %s%s\n", col, $1, $3, $4, $2, $5, dur_s, $7, reset
  }'
}

# ─────────────────────────────────────────────── Section 3.5: cost summary (ENG-26)
# Read $PROJECT_STATE_DIR/metrics/events.jsonl. Aggregates `stage-end`
# events with a present `cost_usd` field; legacy lines (no cost field)
# read through `// 0` defaults so historical events do not skew totals.
# Time-window boundaries are UTC (D-007 — stated in the section header
# so an operator reading at 11pm Pacific understands the boundary).

# Internal helper: per-stage breakdown table. Reads $1 = jsonl path,
# emits one tab-separated row per stage sorted by cost desc:
#   stage<TAB>events<TAB>cost_usd<TAB>tokens_in<TAB>tokens_out<TAB>cache_pct
# When the cache_read+cache_create denominator is zero for a stage, the
# cache_pct column is "--" rather than "0%" (D-007 — same convention as
# the Linear footer).
_aggregate_cost_by_stage() {
  local jsonl="$1"
  jq -s -r '
    map(select(.event == "stage-end" and (.cost_usd != null)))
    | group_by(.stage)
    | map({
        stage:        (.[0].stage // "-"),
        events:       length,
        cost:         (map(.cost_usd        // 0) | add),
        tokens_in:    (map(.tokens_in       // 0) | add),
        tokens_out:   (map(.tokens_out      // 0) | add),
        cache_read:   (map(.cache_read      // 0) | add),
        cache_create: (map(.cache_create    // 0) | add)
      })
    | sort_by(-.cost)
    | .[]
    | [
        .stage,
        .events,
        (.cost),
        (.tokens_in),
        (.tokens_out),
        (if (.cache_read + .cache_create) > 0
         then ((100.0 * .cache_read / (.cache_read + .cache_create)) + 0.5 | floor)
         else "--"
         end)
      ]
    | @tsv
  ' "$jsonl" 2>/dev/null
}

show_cost_summary() {
  section "Cost summary (subscription proxy, UTC)"

  local jsonl="$PROJECT_STATE_DIR/metrics/events.jsonl"
  if [[ ! -f "$jsonl" ]]; then
    printf '  %s(no events.jsonl yet)%s\n' "$C_DIM" "$C_RST"
    return 0
  fi

  # UTC window boundaries computed in shell so jq can compare strings.
  local today_iso week_iso month_iso
  today_iso="$(date -u +%Y-%m-%dT00:00:00Z)"
  if ! week_iso="$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
    week_iso="$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  fi
  month_iso="$(date -u +%Y-%m-01T00:00:00Z)"

  # Totals + legacy counter in one jq pass.
  local totals
  totals="$(jq -s -r --arg today "$today_iso" --arg week "$week_iso" --arg month "$month_iso" '
    [.[] | select(.event == "stage-end")] as $ends
    | {
        today_cost: ([$ends[] | select(.ts >= $today) | (.cost_usd // 0)] | add // 0),
        week_cost:  ([$ends[] | select(.ts >= $week)  | (.cost_usd // 0)] | add // 0),
        month_cost: ([$ends[] | select(.ts >= $month) | (.cost_usd // 0)] | add // 0),
        legacy_in_week:  ([$ends[] | select(.ts >= $week) | select(.cost_usd == null)] | length),
        total_in_week:   ([$ends[] | select(.ts >= $week)] | length)
      }
    | "\(.today_cost)\t\(.week_cost)\t\(.month_cost)\t\(.legacy_in_week)\t\(.total_in_week)"
  ' "$jsonl" 2>/dev/null || printf '0\t0\t0\t0\t0')"

  IFS=$'\t' read -r today_cost week_cost month_cost legacy_n total_n <<<"$totals"
  awk -v t="${today_cost:-0}" -v w="${week_cost:-0}" -v m="${month_cost:-0}" \
      -v lg="${legacy_n:-0}"   -v tn="${total_n:-0}" \
    'BEGIN{ printf("  today=$%.2f · 7d=$%.2f · MTD=$%.2f  (legacy events: %d/%d)\n", t, w, m, lg, tn) }'

  # Per-stage breakdown.
  local rows
  rows="$(_aggregate_cost_by_stage "$jsonl")"
  if [[ -z "${rows// /}" ]]; then
    printf '  %s(no stage-end events with cost data)%s\n' "$C_DIM" "$C_RST"
    return 0
  fi

  printf '\n  %-12s %7s %9s %9s %9s %7s\n' "stage" "events" "cost" "in" "out" "cache%"
  printf '  %s\n' "------------ ------- --------- --------- --------- -------"
  while IFS=$'\t' read -r stage events cost ti to cache; do
    [[ -z "$stage" ]] && continue
    if [[ "$cache" == "--" ]]; then
      cache_disp="--"
    else
      cache_disp="${cache}%"
    fi
    awk -v st="$stage" -v ev="$events" -v co="$cost" -v ti="$ti" -v to="$to" -v ch="$cache_disp" \
      'BEGIN{ printf("  %-12s %7d %9s %9s %9s %7s\n",
                     st, ev,
                     sprintf("$%.2f", co),
                     sprintf("%.1fk", ti/1000.0),
                     sprintf("%.1fk", to/1000.0),
                     ch) }'
  done <<<"$rows"
}

# ───────────────────────────────────────────────────── Section 4: marker comments

show_markers() {
  section "meta:metric markers on active issues (last 60 min)"

  if [[ -z "${LINEAR_API_KEY-}" ]]; then
    printf '  %s(LINEAR_API_KEY not set; skip)%s\n' "$C_DIM" "$C_RST"
    return 0
  fi

  # Collect identifiers for active issues across all non-released stage labels.
  local ids=()
  local stage json
  while IFS= read -r stage; do
    [[ -z "$stage" || "$stage" == "released" ]] && continue
    json="$(bash "$SCRIPT_DIR/linear.sh" list-issues-with-label "stage:$stage" 2>/dev/null || printf '{}')"
    while IFS= read -r ident; do
      [[ -n "$ident" ]] && ids+=("$ident")
    done < <(jq -r '.data.issues.nodes[]? | select(.state.name != "Done") | .identifier' <<<"$json")
  done < <(jq -r '.linear.workflow_stages[]?' "$CONFIG")

  if (( ${#ids[@]} == 0 )); then
    printf '  %s(no active issues to scan)%s\n' "$C_DIM" "$C_RST"
    return 0
  fi

  # Cutoff = 60 min ago (ISO-8601 UTC).
  local cutoff
  cutoff="$(date -u -v-60M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d '60 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"

  local found=0 ident
  for ident in "${ids[@]}"; do
    # One query per issue (comments per issue is Linear's natural unit).
    local c
    c="$(bash "$SCRIPT_DIR/linear.sh" query \
      'query($id: String!) { issue(id: $id) { identifier comments(first: 100) { nodes { body createdAt } } } }' \
      "$(jq -cn --arg id "$ident" '{id:$id}')" 2>/dev/null || printf '{}')"
    while IFS=$'\t' read -r ts marker body; do
      [[ -z "$ts" ]] && continue
      printf '  %s  %-6s  %s  %s\n' "${ts:0:19}" "$ident" "$marker" "${body:0:100}"
      found=1
    # Recognize both new-shape `<!-- meta: metric name=... -->` and legacy
    # `<!-- pipeline-metric: ... -->` so the dashboard surfaces in-flight
    # issues whose comment history predates the ENG-60 vocabulary cutover.
    done < <(jq -r --arg cutoff "$cutoff" '
      .data.issue.comments.nodes[]?
      | select(.createdAt >= $cutoff)
      | select(.body | test("<!-- meta: metric name=[a-z_-]+ -->|<!-- pipeline-metric: [a-z_-]+ -->"))
      | [.createdAt,
         (if (.body | test("<!-- meta: metric name=[a-z_-]+ -->"))
            then (.body | capture("<!-- meta: metric name=(?<m>[a-z_-]+) -->").m)
          elif (.body | test("<!-- pipeline-metric: [a-z_-]+ -->"))
            then (.body | capture("<!-- pipeline-metric: (?<m>[a-z_-]+) -->").m)
          else "?" end),
         .body] | @tsv
    ' <<<"$c")
  done

  if (( found == 0 )); then
    printf '  %s(none)%s\n' "$C_DIM" "$C_RST"
  fi
}

# ─────────────────────────────────────── Section: concurrent dispatches (ENG-81)

# Surface live slot occupancy from $HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid.
# Each slot directory holds the dispatch.sh pid that owns it. Empty listing ⇒
# no live dispatches. This is the per-tick K cap operator-visible inspection
# point referenced from CLAUDE.md "Per-project dispatch concurrency".
show_concurrent_dispatches() {
  section "Concurrent dispatches active right now"
  local sem_dir="$HARNESS_STATE_DIR/.claude-semaphore"
  if [[ ! -d "$sem_dir" ]]; then
    printf '  %s(no semaphore dir; harness has not run yet)%s\n' "$C_DIM" "$C_RST"
    return 0
  fi
  local n=0 slot pid
  for slot in "$sem_dir"/slot-*/; do
    [[ -d "$slot" ]] || continue
    n=$((n + 1))
    pid="$(cat "$slot/pid" 2>/dev/null || printf '?')"
    printf '  slot=%s pid=%s\n' "$(basename "$slot" | sed 's/slot-//')" "$pid"
  done
  (( n == 0 )) && printf '  %s(no active dispatches)%s\n' "$C_DIM" "$C_RST"
}

# Tail recent dispatch-resource-sample events from events.jsonl. This is the
# wall_seconds/max_rss_kb/cpu_pct baseline emitted post-dispatch by
# bin/dispatch.sh::main when gtime is on PATH (ENG-81 Phase 1 instrumentation).
show_resource_baseline() {
  section "Dispatch resource baseline (last 20 samples)"
  local ev="$PROJECT_STATE_DIR/metrics/events.jsonl"
  [[ -f "$ev" ]] || { printf '  %s(no events.jsonl)%s\n' "$C_DIM" "$C_RST"; return 0; }
  local lines
  lines="$(jq -r 'select(.event == "dispatch-resource-sample") | "  \(.ts // "?")  \(.issue_id // "?")/\(.stage // "?")  \(.notes // "")"' \
    "$ev" 2>/dev/null | tail -20 || true)"
  if [[ -z "$lines" ]]; then
    printf '  %s(no dispatch-resource-sample events yet — gtime may be absent on host)%s\n' \
      "$C_DIM" "$C_RST"
  else
    printf '%s\n' "$lines"
  fi
}

# ────────────────────────────────────────────────────────────────────────── main

main() {
  printf '%sTwinning pipeline status — %s UTC%s\n' "$C_BLD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$C_RST"
  show_runs                  || true
  show_active_issues         || true
  show_concurrent_dispatches || true
  show_resource_baseline     || true
  show_cost_summary          || true
  show_metrics               || true
  show_markers               || true
  printf '\n'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
