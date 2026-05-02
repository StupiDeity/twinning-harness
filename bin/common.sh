#!/usr/bin/env bash
# Shared helpers sourced by every harness script.
# Provides: HARNESS_ROOT, TARGET_REPO, HARNESS_STATE_DIR, TARGET_CONFIG_DIR,
#           CONFIG, IDS_CACHE, STATE_FILE, HARNESS_CONFIG_DIR, PROJECT_SLUG,
#           PROJECT_STATE_DIR, log, die, require_env, acquire_lock, release_lock.

set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${TARGET_REPO:?TARGET_REPO env var required — path to the target repo this harness drives}"
[[ -d "$TARGET_REPO" ]] || { printf '[%s] FATAL: TARGET_REPO does not exist: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TARGET_REPO" >&2; exit 1; }

HARNESS_STATE_DIR="${HARNESS_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/twinning-harness}"
TARGET_CONFIG_DIR="${TARGET_REPO}/.pipeline-config"
CONFIG="${TARGET_CONFIG_DIR}/config.json"
IDS_CACHE="${TARGET_CONFIG_DIR}/schemas/linear-ids.json"
STATE_FILE="${TARGET_CONFIG_DIR}/state.local.json"

export HARNESS_ROOT TARGET_REPO HARNESS_STATE_DIR TARGET_CONFIG_DIR CONFIG IDS_CACHE STATE_FILE

# log/die defined early so slug resolution (below) can call die.
log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
  printf '[%s] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
  exit 1
}

HARNESS_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/twinning-harness"

# Project slug resolution. Three modes:
#   1. Caller pre-set $PROJECT_SLUG (test fixtures, setup.sh's slug-freeze
#      phase) — respect it.
#   2. TWINNING_BOOTSTRAPPING=1 — soft-empty (setup.sh phases that run before
#      slug-freeze).
#   3. Otherwise — read from config.json::project.slug; die loudly if absent.
if [[ -z "${PROJECT_SLUG:-}" ]]; then
  if [[ -n "${TWINNING_BOOTSTRAPPING:-}" ]]; then
    PROJECT_SLUG=""
  else
    [[ -f "$CONFIG" ]] || die "config.json not found at $CONFIG — run bin/setup.sh /path/to/target first"
    PROJECT_SLUG="$(jq -r '.project.slug // empty' "$CONFIG" 2>/dev/null || true)"
    [[ -n "$PROJECT_SLUG" ]] || die "config.json::project.slug missing — run bin/setup.sh /path/to/target first"
  fi
fi
if [[ -n "$PROJECT_SLUG" ]]; then
  PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-${HARNESS_STATE_DIR}/${PROJECT_SLUG}}"
else
  PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-}"
fi

export HARNESS_CONFIG_DIR PROJECT_SLUG PROJECT_STATE_DIR

# ─── Per-issue state directory (ENG-15) ──────────────────────────────
# Resolve the per-issue state directory. Callers: run-stage.sh,
# run-local.sh, poll.sh, classify-failure.sh. The directory holds
# issue-state.json, the worktree/ subdir, and the scope-approval file.
issue_dir() {
  local issue="$1"
  [[ -n "$issue" ]] || die "issue_dir: missing issue id"
  printf '%s/%s' "$PROJECT_STATE_DIR" "$issue"
}
# Compute a stable sha256 over the set of files that drive pipeline
# behavior from the main dev dir. Intentionally excludes metrics/ and
# learned-rules/ (churn every tick). Emits a single hex digest, no
# filename. Used by classify_failure (failure time) and poll.sh (tick
# time) to detect pipeline-code changes that should un-skip an issue.
compute_pipeline_content_hash() {
  # Produce an ordered list of files, then concatenate with sha256.
  # Sort by path so ordering is deterministic across filesystems.
  local files
  files="$(
    {
      find "$HARNESS_ROOT/bin" -type f -name '*.sh' 2>/dev/null
      printf '%s\n' "$CONFIG"
      printf '%s\n' "$HARNESS_ROOT/AGENT_PROMPTS.md"
    } | LC_ALL=C sort
  )"
  # shasum each, then hash the concatenation of per-file digests.
  printf '%s\n' "$files" \
    | xargs -I{} shasum -a 256 {} \
    | awk '{print $1}' \
    | shasum -a 256 \
    | awk '{print $1}'
}
# ─── Exit-code → outcome taxonomy (ENG-10 D-002) ─────────────────────
# Map a run-stage.sh exit code (and optional subcode) to the canonical
# typed outcome name the retrospective agent's §1 filter and status.sh's
# red/yellow predicate recognise. Callers: classify-failure.sh (all
# classify_failure emissions), run-stage.sh (paused — exit 11; lane-violation — exit 13).
# Reconcile-human (run-local.sh) does NOT call this helper: it emits the
# direct string "reconcile-human" per D-004 because exit_code=0
# subcode="" would route to unknown-exit-0.
#
# Usage: failure_outcome_for_exit <exit_code> <subcode>
#   subcode may be "" (empty). Case matching is exact.
failure_outcome_for_exit() {
  local exit_code="$1" subcode="${2:-}"
  case "$exit_code" in
    0)
      case "$subcode" in
        1) printf 'scope-approval-pending' ;;
        *) printf 'unknown-exit-0' ;;
      esac
      ;;
    10) printf 'guards-tripped' ;;
    11) printf 'paused' ;;
    12) printf 'stage-drift' ;;
    13) printf 'lane-violation' ;;
    20) printf 'dispatch-failed' ;;
    21) printf 'scope-violation' ;;
    22) printf 'pr-opened-too-early' ;;
    24) printf 'linear-post-failed' ;;
    25) printf 'agent-contract-missing' ;;
    124) printf 'dispatch-timeout' ;;
    *)  printf 'unknown-exit-%s' "$exit_code" ;;
  esac
}
# parse_pipeline_marker <body> — translate a Linear comment body containing
# a pipeline marker (old or new shape) into a uniform JSON event.
#
# Output JSON shapes:
#   {"event":"verdict","result":"pass","stage":"implementing"}
#   {"event":"verdict","result":"fail","target":"planning"}
#   {"event":"verdict","result":"halt","reason":"agent-blocked"}
#   {"event":"verdict","result":"wait","reason":"awaiting-approval"}
#   {"event":"transition","from":"implementing","to":"reviewing"}
#   {"event":"decision","action":"approve","gate":"scope"}
#   {"event":"decision","action":"continue"}            (no gate)
#   {"event":"meta","kind":"dedup","key":"<ns/stage/issue>"}
#   {"event":"meta","kind":"metric","name":"<metric>"}
#
# Returns 0 with JSON on stdout when a marker is found.
# Returns 1 with empty stdout when no recognizable marker is in the body.
#
# Accepts BOTH old (`pipeline-X: value`) and new (`pipeline: event k=v`)
# shapes during phases 1-2; phase 3 simplifies to new-shape only.
parse_pipeline_marker() {
  local body="$1"
  local marker

  # New shape: `<!-- pipeline: <event> [k=v ...] -->`
  marker="$(grep -oE '<!-- pipeline: [^>]+ -->' <<<"$body" 2>/dev/null | tail -1 || true)"
  if [[ -n "$marker" ]]; then
    local payload
    payload="$(sed -E 's/<!-- pipeline: (.+) -->/\1/' <<<"$marker")"
    local event="${payload%% *}"
    local rest="${payload#$event}"
    rest="${rest# }"
    local json
    json="$(jq -nc --arg e "$event" '{event:$e}')"
    # Parse remaining `k=v` pairs (whitespace-separated).
    if [[ -n "$rest" ]]; then
      local pair k v
      for pair in $rest; do
        [[ "$pair" == *=* ]] || continue
        k="${pair%%=*}"
        v="${pair#*=}"
        json="$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$json")"
      done
    fi
    printf '%s' "$json"
    return 0
  fi

  # Old shape: `<!-- pipeline-<kind>: <value> -->`
  marker="$(grep -oE '<!-- pipeline-(stage-summary|rejection|rejection-target|halt|wait|transition|decision|sig|metric): [^>]+ -->' <<<"$body" 2>/dev/null | tail -1 || true)"
  if [[ -n "$marker" ]]; then
    local kind value
    kind="$(sed -E 's/<!-- pipeline-([^:]+): .+ -->/\1/' <<<"$marker")"
    value="$(sed -E 's/<!-- pipeline-[^:]+: (.+) -->/\1/' <<<"$marker")"
    case "$kind" in
      stage-summary)
        jq -nc --arg s "$value" '{event:"verdict",result:"pass",stage:$s}' ;;
      rejection|rejection-target)
        jq -nc --arg t "$value" '{event:"verdict",result:"fail",target:$t}' ;;
      halt)
        # Apply legacy aliases (e.g. scope-deviation → scope-violation).
        local canon
        canon="$(jq -r --arg r "$value" '.legacy_halt_reason_aliases[$r] // $r' "$HARNESS_ROOT/bin/pipeline-events.json" 2>/dev/null || printf '%s' "$value")"
        jq -nc --arg r "$canon" '{event:"verdict",result:"halt",reason:$r}' ;;
      wait)
        jq -nc --arg r "$value" '{event:"verdict",result:"wait",reason:$r}' ;;
      transition)
        local from to
        from="$(sed -E 's/(.+) → .+/\1/' <<<"$value")"
        to="$(sed -E 's/.+ → (.+)/\1/' <<<"$value")"
        jq -nc --arg f "$from" --arg t "$to" '{event:"transition",from:$f,to:$t}' ;;
      decision)
        case "$value" in
          scope-approved) jq -nc '{event:"decision",action:"approve",gate:"scope"}' ;;
          scope-rejected) jq -nc '{event:"decision",action:"abandon",gate:"scope"}' ;;
          resume)         jq -nc '{event:"decision",action:"continue"}' ;;
          *)              jq -nc --arg v "$value" '{event:"decision",legacy:$v}' ;;
        esac ;;
      sig)
        jq -nc --arg k "$value" '{event:"meta",kind:"dedup",key:$k}' ;;
      metric)
        jq -nc --arg n "$value" '{event:"meta",kind:"metric",name:$n}' ;;
    esac
    return 0
  fi

  printf ''
  return 1
}
export -f parse_pipeline_marker

# ─── Orchestrator paused flag (ENG-23) ────────────────────────────────
# Read priority: STATE_FILE (runtime override) > CONFIG (static default) > "false".
# Writes go ONLY to STATE_FILE so the target repo is never asked to
# commit transient state.
is_orchestrator_paused() {
  if [[ -f "$STATE_FILE" ]]; then
    local override
    # Don't simplify to '// empty': false is jq-falsy and would silently
    # eat a paused=false override. See ENG-44 / ENG-49 / bin/common-test.sh.
    override="$(jq -r 'if .orchestrator.paused != null then .orchestrator.paused else empty end' "$STATE_FILE" 2>/dev/null || true)"
    if [[ -n "$override" ]]; then
      printf '%s' "$override"
      return
    fi
  fi
  jq -r '.orchestrator.paused // "false"' "$CONFIG"
}

set_orchestrator_paused() {
  local paused="$1"   # "true" or "false"
  [[ "$paused" == "true" || "$paused" == "false" ]] || die "set_orchestrator_paused: expected true|false, got $paused"
  mkdir -p "$(dirname "$STATE_FILE")"
  local tmp="$STATE_FILE.tmp"
  if [[ -f "$STATE_FILE" ]]; then
    jq ".orchestrator.paused = $paused" "$STATE_FILE" > "$tmp"
  else
    printf '{"orchestrator":{"paused":%s}}\n' "$paused" > "$tmp"
  fi
  mv "$tmp" "$STATE_FILE"
}

export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit is_orchestrator_paused set_orchestrator_paused

# ─── Lock helpers (mkdir-based; atomic on POSIX) ─────────────────────
# Used by run-local.sh (per-project tick lock) and dispatch.sh (cross-
# project claude mutex). mkdir is atomic across processes; rmdir is
# safe even if multiple holders lose the race to release.
acquire_lock() {
  local dir="$1" timeout="${2:-0}" waited=0
  while ! mkdir "$dir" 2>/dev/null; do
    (( timeout > 0 && waited >= timeout )) && return 1
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

release_lock() {
  local dir="$1"
  rmdir "$dir" 2>/dev/null || true
}

export -f acquire_lock release_lock

PIPELINE_DRY_RUN="${PIPELINE_DRY_RUN:-0}"
export PIPELINE_DRY_RUN

PIPELINE_WRITER="${PIPELINE_WRITER:-orchestrator}"
export PIPELINE_WRITER

require_env() {
  for var in "$@"; do
    [[ -n "${!var:-}" ]] || die "required env var not set: $var"
  done
}

require_bin() {
  for b in "$@"; do
    command -v "$b" >/dev/null 2>&1 || die "required binary not on PATH: $b"
  done
}

config_get() {
  local path="$1"
  jq -r "$path" "$CONFIG"
}

ids_get() {
  local path="$1"
  jq -r "$path" "$IDS_CACHE"
}

label_id() {
  ids_get ".labels[\"$1\"]"
}

state_id() {
  ids_get ".states[\"$1\"]"
}
