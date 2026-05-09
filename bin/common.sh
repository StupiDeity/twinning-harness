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

# Bot identity used by every git commit the harness creates (run-local.sh's
# tick-end sweep and pipeline.sh decide --action continue's auto-commit).
# Override in env to substitute (e.g. test fixtures).
: "${BOT_NAME:=twinning-pipeline-bot}"
: "${BOT_EMAIL:=twinning-pipeline-bot@users.noreply.github.com}"
export BOT_NAME BOT_EMAIL

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
# ─── Dispatch identifier (ENG-87) ─────────────────────────────────────
# Per-issue monotonic dispatch counter. Allocated at run-stage.sh::main
# per dispatch (after preconditions, before render-prompt), exported as
# PIPELINE_DISPATCH_ID, persisted in $(issue_dir)/issue-state.json. Format
# ENG-N-d<NNNN> (4-digit zero-padded). The id is the glue layer for the
# cross-dispatch staleness contract: every cross-dispatch read becomes a
# single-equality check on this counter instead of secondary inference
# (mtime, createdAt window, label state, prompt-token textual equality).
allocate_dispatch_id() {
  local issue="$1"
  [[ -n "$issue" ]] || die "allocate_dispatch_id: missing issue id"
  local state_file; state_file="$(issue_dir "$issue")/issue-state.json"
  local lock_dir="$(issue_dir "$issue")/.allocate.lock"
  mkdir -p "$(issue_dir "$issue")"
  # Per-issue mkdir-lock around the read-modify-write. mv -f's rename
  # atomicity guarantees readers see whole-or-prior, not a partial; the
  # lock guarantees two concurrent allocators serialise instead of both
  # reading the same prior_seq and double-writing seq+1.
  acquire_lock "$lock_dir" 60 || die "allocate_dispatch_id: lock timeout for $issue"
  # Use a trap to ensure the lock is released even on early die / jq
  # parse failure inside the critical section.
  local _alloc_rc=0
  _allocate_dispatch_id_locked "$issue" "$state_file" || _alloc_rc=$?
  release_lock "$lock_dir"
  return "$_alloc_rc"
}

_allocate_dispatch_id_locked() {
  local issue="$1" state_file="$2"
  local prior_seq=0 prior_json="{}"
  # Resilient prior-seq read: corrupt-JSON / torn-write / non-numeric
  # current_dispatch_seq all reset to 0.
  if [[ -s "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then
    prior_seq="$(jq -r '.current_dispatch_seq // 0' "$state_file" 2>/dev/null || printf '0')"
    [[ "$prior_seq" =~ ^[0-9]+$ ]] || prior_seq=0
    prior_json="$(cat "$state_file")"
  fi
  local next_seq=$((prior_seq + 1))
  local id; id="$(printf '%s-d%04d' "$issue" "$next_seq")"
  # Merge: write current_dispatch_seq, current_dispatch_id, current_stage
  # without losing classify-failure's existing fields (policy, reason,
  # exit_code, retry_count, ...). jq -n + ($prior + {…}) preserves them.
  local merged
  merged="$(jq -cn --argjson prior "$prior_json" --argjson seq "$next_seq" \
                 --arg id "$id" --arg stage "${PIPELINE_STAGE-}" '
    $prior + {current_dispatch_seq: $seq, current_dispatch_id: $id, current_stage: $stage}')"
  local tmp="${state_file}.tmp.$$"
  printf '%s' "$merged" > "$tmp"
  mv -f "$tmp" "$state_file"
  export PIPELINE_DISPATCH_ID="$id"
  printf '%s' "$id"
}

# Read-only sibling: returns current_dispatch_id from issue-state.json,
# or empty string if absent. Used by verdict-handler.sh's dispatch_id-
# primary filter (find_fresh_verdict, resume_in_progress_transition).
current_dispatch_id() {
  local issue="$1"
  [[ -n "$issue" ]] || die "current_dispatch_id: missing issue id"
  local state_file; state_file="$(issue_dir "$issue")/issue-state.json"
  [[ -s "$state_file" ]] || { printf ''; return 0; }
  jq -r '.current_dispatch_id // ""' "$state_file" 2>/dev/null || printf ''
}

# ─── Exit-code → outcome taxonomy (ENG-10 D-002) ─────────────────────
# Map a run-stage.sh exit code (and optional subcode) to the canonical
# typed outcome name the retrospective agent's §1 filter and status.sh's
# red/yellow predicate recognise. Callers: classify-failure.sh (all
# classify_failure emissions), run-stage.sh (paused — exit 11; lane-violation — exit 13).
# Reconcile-human (run-local.sh) does NOT call this helper: it emits the
# direct string "reconcile-human" per D-004 because exit_code=0
# subcode="" would route to unknown-exit-0. ENG-69: self-leak (exit 26)
# and leaked-in-scope-threshold (exit 27) are emitted by classify_failure
# calls from run-local.sh's tick-end sweep (via halt_issue_for_self_leak
# and tally_leaked_in_scope_failure in run-local-helpers.sh), not from
# run-stage.sh.
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
    14) printf 'legacy-marker-write' ;;
    20) printf 'dispatch-failed' ;;
    21) printf 'scope-violation' ;;
    22) printf 'pr-opened-too-early' ;;
    23) printf 'branch-creation-forbidden' ;;
    24) printf 'linear-post-failed' ;;
    25) printf 'agent-contract-missing' ;;
    26) printf 'worktree-mutation-forbidden' ;;
    27) printf 'self-leak' ;;
    28) printf 'leaked-in-scope-threshold' ;;
    29) printf 'envelope-violation' ;;
    124) printf 'dispatch-timeout' ;;
    *)  printf 'unknown-exit-%s' "$exit_code" ;;
  esac
}
# ─── Pipeline-marker parser (ENG-60) ──────────────────────────
# _strip_code_blocks_and_spans <body> — pre-strip the body before the
# parse_pipeline_marker grep so prose-quoted markers (backticked spans,
# triple-backtick fences, 4-space-indented blocks) do NOT push the
# freshness floor or trip protocol-violation halts (ENG-61 Bug A).
#
# Same-file private; not added to the export -f list (F-3 lane discipline).
# Markers are written at column 0 by contract (AGENT_PROMPTS.md +
# bin/pipeline.sh writes raw HTML comments unindented), so over-stripping
# indented lines is benign.
#
_strip_code_blocks_and_spans() {
  local body="$1"
  # Step 1 (multi-line bodies only): strip 4-space-indented blocks.
  # Production callers (run-stage.sh, verdict-handler.sh, scope-check.sh,
  # pipeline.sh) pre-collapse newlines via jq gsub("\n"; " ") before
  # passing the body, so this is a no-op for them. Activates for direct
  # callers (tests, future call sites that preserve newlines).
  if [[ "$body" == *$'\n'* ]]; then
    body="$(awk '!/^( {4,}|\t)/' <<<"$body")"
  fi
  # Collapse newlines to spaces so the steps below scan in a single pass.
  body="${body//$'\n'/ }"
  # Steps 2/3: strip triple-backtick fences then single-backtick spans.
  # sed-based substitution (brainstorm A15/A16). The earlier
  # ${var//pat/repl} form treated BASH_REMATCH[0] as a glob, not a
  # literal substring; when the matched span contained glob metachars
  # ([, ], *, ?) the substitution silently did nothing and the regex
  # match held → infinite loop on any body with backticked code spans
  # quoting paths/globs (P17). sed regex is glob-immune and anchors
  # to literal positions.
  body="$(printf '%s' "$body" | sed -E 's/`{3}[^`]*`{3}/ /g; s/`[^`]*`/ /g')"
  printf '%s' "$body"
}

# parse_pipeline_marker <body> — translate a Linear comment body containing
# a pipeline marker (new shape) into a uniform JSON event.
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
# New shape only (`pipeline: <event> k=v` or `meta: <kind> k=v`); old-shape
# `<!-- pipeline-X: ... -->` branch was removed in T3.1.
parse_pipeline_marker() {
  local body="$1"
  local marker

  # ENG-61 Bug A: pre-strip backtick-quoted spans/fences so prose-quoted
  # markers in stage summaries, plan bodies, and discussion comments do
  # NOT register as real state-driving events.
  body="$(_strip_code_blocks_and_spans "$body")"

  # Match either family. The grep is intentionally unanchored so a marker
  # appearing anywhere in the body is found; we take the LAST one (`tail -1`)
  # because mechanical summary writers append the dedup marker to the end.
  marker="$(grep -oE '<!-- (pipeline|meta): [^>]+ -->' <<<"$body" 2>/dev/null | tail -1 || true)"
  [[ -z "$marker" ]] && return 1

  local family payload
  if [[ "$marker" == "<!-- pipeline:"* ]]; then
    family="pipeline"
    payload="$(sed -E 's|<!-- pipeline: (.+) -->|\1|' <<<"$marker")"
  else
    family="meta"
    payload="$(sed -E 's|<!-- meta: (.+) -->|\1|' <<<"$marker")"
  fi

  # First whitespace-token: for pipeline family, the event verb
  # (verdict|transition|decision); for meta family, the kind
  # (dedup|metric|evidence).
  local first="${payload%% *}"
  local rest="${payload#$first}"
  rest="${rest# }"

  local json
  if [[ "$family" == "pipeline" ]]; then
    json="$(jq -nc --arg e "$first" '{event:$e}')"
  else
    json="$(jq -nc --arg k "$first" '{event:"meta", kind:$k}')"
  fi

  # Parse remaining whitespace-separated k=v pairs.
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
}

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

export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id

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
