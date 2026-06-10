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
# ENG-107: per-issue progress notebook path. Append-only contract;
# never cleared on dispatch. See docs/runbooks/progress-md.md for
# schema, lifecycle, and ownership boundary. Composed on issue_dir
# so the resolution rules (PROJECT_STATE_DIR, bootstrap-mode
# behaviour, die-on-empty-issue) match exactly.
progress_md_path() {
  local issue="$1"
  [[ -n "$issue" ]] || die "progress_md_path: missing issue id"
  printf '%s/progress.md' "$(issue_dir "$issue")"
}

# ENG-113: per-issue qa-predicate JSON path. Mirrors progress_md_path;
# consumed by bin/verify-qa.sh and the {qa_predicate_path} prompt resolver.
# The file lives under $(issue_dir "$issue") — i.e. inside $PROJECT_STATE_DIR,
# OUTSIDE the worktree (D-011 authority surface: verify-qa.sh asserts the
# file path is anchored under $PROJECT_STATE_DIR before opening it).
qa_predicate_path() {
  local issue="$1"
  [[ -n "$issue" ]] || die "qa_predicate_path: missing issue id"
  printf '%s/qa-predicate-%s.json' "$(issue_dir "$issue")" "$issue"
}

# ENG-113 D-007: shared per-pass_criterion validator; lifted from
# bin/plan-schema.sh:181-260. Callers: plan-schema.sh::cmd_validate
# (plan.json) and verify-qa.sh::cmd_validate (qa-predicate JSON). The
# --kinds CSV restricts the allowed kind set; plan-schema passes
# "smoke,file_exists,grep"; verify-qa passes "smoke,file_exists,grep,http_get".
# The `http_get` kind validates `url` (non-empty string starting with
# http:// or https://), `expect_status` (integer), and optional
# `expect_body_match` (string|null).
# The `file_exists` and `grep` kinds additionally enforce D-013
# path-traversal hardening: reject leading `/` and any `..` path-segment;
# exempt `smoke` (commands run any binary) and `http_get` (URLs are
# not filesystem paths). Returns rc=34 on any failure with a
# `<caller>-incomplete:` diagnostic shape; the `--caller <name>` flag
# overrides the default `plan-contract` prefix (verify-qa passes
# `qa-predicate`). The `--shape flat|nested` flag picks the jq index
# expression — `nested` (default) is plan-schema's
# `features[$i].pass_criteria[$j]`, `flat` is verify-qa's top-level
# `pass_criteria[$j]`.
#
# Usage: _validate_pass_criterion <file> <fi> <ci> [--kinds <csv>] [--caller <name>] [--shape flat|nested]
#   <file>  — JSON file under inspection
#   <fi>    — feature index for diagnostics (verify-qa passes 0)
#   <ci>    — criterion index for diagnostics
#   --kinds  — CSV of allowed kinds (default: smoke,file_exists,grep)
#   --caller — diagnostic prefix (default: plan-contract)
#   --shape  — jq path shape: nested|flat (default: nested)
_validate_pass_criterion() {
  local file="$1" fi="$2" ci="$3"
  shift 3
  local kinds_csv="smoke,file_exists,grep"
  local caller="plan-contract"
  local shape="nested"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kinds)
        [[ $# -ge 2 ]] || { printf '_validate_pass_criterion: --kinds requires a value\n' >&2; return 34; }
        kinds_csv="$2"; shift 2 ;;
      --caller)
        [[ $# -ge 2 ]] || { printf '_validate_pass_criterion: --caller requires a value\n' >&2; return 34; }
        caller="$2"; shift 2 ;;
      --shape)
        [[ $# -ge 2 ]] || { printf '_validate_pass_criterion: --shape requires a value\n' >&2; return 34; }
        case "$2" in flat|nested) shape="$2" ;;
                     *) printf '_validate_pass_criterion: --shape must be flat or nested, got %s\n' "$2" >&2; return 34 ;; esac
        shift 2 ;;
      *) printf '_validate_pass_criterion: unknown flag %s\n' "$1" >&2; return 34 ;;
    esac
  done
  local pc_jq
  if [[ "$shape" == "nested" ]]; then
    pc_jq=".features[\$i].pass_criteria[\$j]"
  else
    pc_jq=".pass_criteria[\$j]"
  fi
  # Diagnostic locator: nested → "features[FI].pass_criteria[CI]";
  # flat → "pass_criteria[CI]". Avoids the §11 "operator confusion"
  # where flat-shape diagnostics referenced a phantom features[0] index.
  local loc
  if [[ "$shape" == "nested" ]]; then
    loc="features[$fi].pass_criteria[$ci]"
  else
    loc="pass_criteria[$ci]"
  fi
  local kind
  kind="$(jq -r --argjson i "$fi" --argjson j "$ci" "$pc_jq.kind // \"MISSING\"" "$file")"
  if [[ "$kind" == "MISSING" ]]; then
    printf '%s-incomplete: %s.kind is required\n' "$caller" "$loc"
    return 34
  fi

  # Enforce --kinds gate (rejects unknown kinds, AND rejects allowed kinds
  # the caller did not enable — e.g. plan-schema rejects http_get).
  local kind_allowed=0
  local IFS_save="$IFS"; IFS=','
  for allowed in $kinds_csv; do
    [[ "$kind" == "$allowed" ]] && kind_allowed=1
  done
  IFS="$IFS_save"
  if (( kind_allowed == 0 )); then
    printf '%s-incomplete: %s: unknown kind "%s" (allowed: %s)\n' \
      "$caller" "$loc" "$kind" "$kinds_csv"
    return 34
  fi

  case "$kind" in
    smoke)
      local cmd_val cmd_type exit_type
      cmd_type="$(jq -r --argjson i "$fi" --argjson j "$ci" "$pc_jq.command | type" "$file")"
      cmd_val="$(jq -r --argjson i "$fi" --argjson j "$ci" "$pc_jq.command // \"MISSING\"" "$file")"
      if [[ "$cmd_val" == "MISSING" || "$cmd_type" != "string" || -z "$cmd_val" ]]; then
        printf '%s-incomplete: %s (smoke): command must be a non-empty string\n' "$caller" "$loc"
        return 34
      fi
      exit_type="$(jq -r --argjson i "$fi" --argjson j "$ci" "$pc_jq.expect_exit | type" "$file")"
      if [[ "$exit_type" != "number" ]]; then
        printf '%s-incomplete: %s (smoke): expect_exit must be an integer, got type=%s\n' "$caller" "$loc" "$exit_type"
        return 34
      fi
      ;;
    file_exists)
      _validate_relative_path "$file" "$fi" "$ci" "$pc_jq" "$caller" "$loc" "file_exists" || return 34
      ;;
    grep)
      local pattern_val pattern_type em_type
      _validate_relative_path "$file" "$fi" "$ci" "$pc_jq" "$caller" "$loc" "grep" || return 34
      pattern_type="$(jq -r --argjson i "$fi" --argjson j "$ci" "$pc_jq.pattern | type" "$file")"
      pattern_val="$(jq -r --argjson i "$fi" --argjson j "$ci" "$pc_jq.pattern // \"MISSING\"" "$file")"
      if [[ "$pattern_val" == "MISSING" || "$pattern_type" != "string" || -z "$pattern_val" ]]; then
        printf '%s-incomplete: %s (grep): pattern must be a non-empty string\n' "$caller" "$loc"
        return 34
      fi
      em_type="$(jq -r --argjson i "$fi" --argjson j "$ci" "$pc_jq.expect_match | type" "$file")"
      if [[ "$em_type" != "boolean" ]]; then
        printf '%s-incomplete: %s (grep): expect_match must be a boolean, got type=%s\n' "$caller" "$loc" "$em_type"
        return 34
      fi
      ;;
    http_get)
      local url_val url_type es_type ebm_type
      url_type="$(jq -r --argjson i "$fi" --argjson j "$ci" "$pc_jq.url | type" "$file")"
      url_val="$(jq -r --argjson i "$fi" --argjson j "$ci" "$pc_jq.url // \"MISSING\"" "$file")"
      if [[ "$url_val" == "MISSING" || "$url_type" != "string" || -z "$url_val" ]]; then
        printf '%s-incomplete: %s (http_get): url must be a non-empty string\n' "$caller" "$loc"
        return 34
      fi
      # Restrict url scheme to http:// or https://. Blocks file://
      # (filesystem exfiltration via curl), gopher:// (SMTP smuggling),
      # ftp:// (unencrypted egress), and cloud-metadata SSRF chains that
      # need a non-http scheme to land. https:// IS accepted so the
      # predicate stays usable against external services.
      if [[ ! "$url_val" =~ ^https?:// ]]; then
        printf '%s-incomplete: %s (http_get): url must use http:// or https:// scheme, got: %s\n' "$caller" "$loc" "$url_val"
        return 34
      fi
      es_type="$(jq -r --argjson i "$fi" --argjson j "$ci" "$pc_jq.expect_status | type" "$file")"
      if [[ "$es_type" != "number" ]]; then
        printf '%s-incomplete: %s (http_get): expect_status must be an integer, got type=%s\n' "$caller" "$loc" "$es_type"
        return 34
      fi
      ebm_type="$(jq -r --argjson i "$fi" --argjson j "$ci" "$pc_jq.expect_body_match | type" "$file")"
      if [[ "$ebm_type" != "string" && "$ebm_type" != "null" ]]; then
        printf '%s-incomplete: %s (http_get): expect_body_match must be string or null, got type=%s\n' "$caller" "$loc" "$ebm_type"
        return 34
      fi
      ;;
  esac
  return 0
}

# Internal helper: validate a `.path` field on a pass_criterion for the
# `file_exists` / `grep` kinds. Enforces D-013 lexical traversal guard
# (rejects leading `/` and any `..` path-segment) and the non-empty /
# string-type contract. Two arms (file_exists, grep) share this body —
# centralised so the security guard cannot drift between them.
# Returns rc=34 on any failure (caller propagates as a single ||).
#
# Symlink resolution (executor side) is NOT done here: the validator is
# pre-execution, and the executor (`bin/verify-qa.sh`) resolves the path
# against the worktree anchor at run time. The lexical guard here closes
# the obvious string-shape attacks; the executor's realpath check closes
# the symlink-pivot vector.
_validate_relative_path() {
  local file="$1" fi="$2" ci="$3" pc_jq="$4" caller="$5" loc="$6" kind="$7"
  local path_val path_type
  path_type="$(jq -r --argjson i "$fi" --argjson j "$ci" "$pc_jq.path | type" "$file")"
  path_val="$(jq -r --argjson i "$fi" --argjson j "$ci" "$pc_jq.path // \"MISSING\"" "$file")"
  # D-013 lexical traversal guard runs BEFORE the non-empty / type check
  # so `path: "/etc/passwd"` cannot slip past the type test (string +
  # non-empty) before the worktree-relative gate fires.
  if [[ "$path_val" == /* \
        || "$path_val" == ../* \
        || "$path_val" == */../* \
        || "$path_val" == */.. ]]; then
    printf '%s-incomplete: %s (%s): path must be worktree-relative (no leading '\''/'\'' and no '\''..'\'' path-segment), got: %s\n' \
      "$caller" "$loc" "$kind" "$path_val"
    return 34
  fi
  if [[ "$path_val" == "MISSING" || "$path_type" != "string" || -z "$path_val" ]]; then
    printf '%s-incomplete: %s (%s): path must be a non-empty string\n' "$caller" "$loc" "$kind"
    return 34
  fi
  return 0
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

# ENG-146 — Strip an issue-state.json file to just the allocator-set
# subset {current_dispatch_seq, current_dispatch_id, current_stage},
# preserving the dispatch_id monotonic counter across success-path
# cleanup (run-stage.sh) and operator-resume drain (pipeline.sh).
# Without this, every stage's first dispatch reads prior_seq=0 and
# re-emits d0001, colliding with the previous stage's id and tripping
# the planning detective on progress.md cross-stage entries.
# When allocator fields are absent (legacy / pre-cutover issue) the
# file is rm -f'd for back-compat. Idempotent on missing file.
strip_state_preserve_alloc() {
  local state_file="$1"
  [[ -n "$state_file" ]] || return 0
  [[ -s "$state_file" ]] || return 0
  jq -e . "$state_file" >/dev/null 2>&1 || { rm -f "$state_file"; return 0; }
  local has_alloc
  has_alloc="$(jq -r 'has("current_dispatch_id") and (.current_dispatch_id // "") != ""' "$state_file" 2>/dev/null || printf 'false')"
  if [[ "$has_alloc" == "true" ]]; then
    local stripped tmp
    stripped="$(jq -c '{current_dispatch_seq, current_dispatch_id, current_stage}' "$state_file" 2>/dev/null || printf '{}')"
    tmp="${state_file}.tmp.$$"
    printf '%s' "$stripped" > "$tmp"
    mv -f "$tmp" "$state_file"
  else
    rm -f "$state_file"
  fi
}

# ─── Transcript-based assertion (ENG-43, hoisted ENG-87) ──────────────
# Single jq fork; reads NDJSON from $transcript line by line, finds
# tool_use blocks invoking Bash whose .input.command starts with
# $pattern, and prints the FIRST match on stdout (returning 1).
# Soft-fail (return 0) on empty/missing transcript so dry-run /
# planning-only paths never synthesize false positives. Pure: no
# harness ambient context (D-010).
#
# Lives in common.sh (not dispatch.sh) because two callers need it:
#   (1) bin/dispatch.sh::_render_and_capture_stream — runs in dispatch.sh's
#       subprocess (gh pr create / branch creation / worktree mutation
#       checks against the live transcript).
#   (2) bin/run-stage.sh::_validate_dispatch_envelope — runs in run-stage.sh's
#       parent process (post-dispatch envelope scan against the persisted
#       sidecar). Pre-ENG-87 review fix, this caller hit `command not found`
#       rc=127 because run-stage.sh sources only common.sh / classify-failure.sh
#       / verdict-handler.sh — never dispatch.sh — and the conditional-context
#       falsy arm halted every dispatch with rc=29.
assert_no_tool_invocation() {
  local transcript="$1" pattern="$2"
  [[ -s "$transcript" ]] || return 0
  local matched
  matched="$(jq -Rr --arg p "$pattern" '
    fromjson? // empty
    | select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Bash")
    | (.input.command // "")
    | select(startswith($p))
  ' "$transcript" 2>/dev/null | head -1)" || true
  if [[ -n "$matched" ]]; then
    printf '%s\n' "$matched"
    return 1
  fi
  return 0
}

# ENG-155 D-003: parameterised generalisation of assert_no_write_to_path.
# Matches any tool_use whose `name` is in $tool_names_csv AND whose
# `input[$input_field]` (string) matches $forbidden_substring under the
# selected match mode. Used to forbid Write+Edit (and any future tool
# that takes a path-like input field) against orchestrator-owned files
# inside $issue_state_dir.
#
# mode (positional arg 5, optional, default "endswith"):
#   - endswith — current ENG-109 semantics; matches a complete trailing
#     suffix like "/progress.md".
#   - contains — required for wildcard prefixes like "/wait-" matching
#     ".../wait-planning.json". Substring match, not suffix.
#
# Returns rc=1 + matched path on first hit, rc=0 + empty stdout on miss.
# Soft-fail (rc=0) on empty/missing transcript so dry-run / planning-only
# paths never synthesize false positives — mirrors the existing helpers.
# Soft-fail (rc=0) on unknown mode (defensive — preserves rc=0-on-miss
# invariant rather than dying inside the dispatch hot path).
assert_no_tool_with_input_path() {
  local transcript="$1" tool_names_csv="$2" input_field="$3" forbidden_substring="$4"
  local mode="${5:-endswith}"
  [[ -s "$transcript" ]] || return 0
  local matched
  matched="$(jq -Rr \
    --arg names "$tool_names_csv" \
    --arg field "$input_field" \
    --arg p "$forbidden_substring" \
    --arg mode "$mode" '
    ($names | split(",")) as $allow
    | fromjson? // empty
    | select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and (.name as $n | $allow | index($n)))
    | (.input[$field] // "")
    | select(type == "string"
            and (   ($mode == "endswith" and endswith($p))
                 or ($mode == "contains" and contains($p)) ))
  ' "$transcript" 2>/dev/null | head -1)" || true
  if [[ -n "$matched" ]]; then
    printf '%s\n' "$matched"
    return 1
  fi
  return 0
}

# ENG-109: forbid Write-tool truncation of the per-issue progress.md.
# Sibling of assert_no_tool_invocation; the contract-shape differs only
# in (a) the tool name (Write, not Bash), (b) the input field
# (file_path, not command), and (c) the matcher direction (endswith,
# because the agent's Write calls carry an absolute path and the
# discriminating signal is the basename suffix). Exported below.
assert_no_write_to_path() {
  local transcript="$1" forbidden_path_suffix="$2"
  assert_no_tool_with_input_path "$transcript" "Write" "file_path" "$forbidden_path_suffix"
}

# ENG-125: validate $issue_dir/init.sh shape. Returns:
#   0  — well-formed (file exists, bash -n clean, all 4 shape markers present)
#   45 — malformed (file exists but bash -n fails)
#   46 — incomplete (file exists, syntax-clean, but ≥1 shape marker absent)
#   47 — missing  (no file at the given path)
# Caller writes the rc-specific diagnostic to its violation_file;
# this helper writes diagnostics to STDOUT (caller captures).
# Shape markers: column-0 comments matching `^# ─── <gate> ───$` (see for-loop
# below for the authoritative gate list).
validate_init_sh() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    printf 'init-sh-missing: %s\n' "$path"
    return 47
  fi
  local bash_n_err
  if ! bash_n_err="$(bash -n "$path" 2>&1)"; then
    # Include bash -n stderr (line + parse error detail) so the operator
    # triage doesn't have to re-run bash -n manually against the halted
    # worktree's init.sh.
    printf 'init-sh-malformed: bash -n failed for %s: %s\n' "$path" "$bash_n_err"
    return 45
  fi
  # CRLF tolerance: an init.sh authored on Windows or via a CRLF-defaulting
  # editor will end every marker line with `…─\r\n`. The `$`-anchor would
  # otherwise reject `# ─── smoke ───\r` even though the marker is present
  # byte-for-byte modulo trailing CR. Pre-normalise CR out of the matched
  # stream rather than complicating the regex.
  local normalized gate missing=()
  normalized="$(tr -d '\r' < "$path")"
  for gate in smoke typecheck lint test; do
    if ! grep -Eq "^# ─── ${gate} ───$" <<<"$normalized"; then
      missing+=("# ─── ${gate} ───")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    # Collect-all-missing: pre-fix the validator short-circuited on the first
    # missing gate, so an agent omitting all four markers got "missing smoke"
    # → fixed smoke → next dispatch "missing typecheck" → and so on. Each
    # iteration burned a ~5-10 minute plan dispatch on one marker at a time.
    # Naming every missing marker in a single diagnostic collapses the loop.
    printf 'init-sh-incomplete: missing shape marker %s\n' "${missing[*]}"
    return 46
  fi
  return 0
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
    15) printf 'header-missing-inputs' ;;
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
    30) printf 'noop-implementation' ;;
    31) printf 'progress-md-entry-missing' ;;
    33) printf 'plan-contract-malformed' ;;
    34) printf 'plan-contract-incomplete' ;;
    35) printf 'plan-contract-missing' ;;
    36) printf 'review-payload-malformed' ;;
    37) printf 'review-payload-incomplete' ;;
    38) printf 'review-payload-missing' ;;
    39) printf 'qa-payload-malformed' ;;
    40) printf 'qa-payload-incomplete' ;;
    41) printf 'qa-payload-missing' ;;
    42) printf 'qa-predicate-malformed' ;;  # ENG-113
    43) printf 'qa-predicate-incomplete' ;; # ENG-113
    44) printf 'qa-predicate-missing' ;;    # ENG-113
    45) printf 'init-sh-malformed' ;;
    46) printf 'init-sh-incomplete' ;;
    47) printf 'init-sh-missing' ;;
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
  # Steps 2/3/4: strip tilde fences, triple-backtick fences, single-backtick spans.
  # Tilde fences (~~~...~~~) are stripped first: _post_plan_contract_halt wraps
  # agent-controlled output in ~~~ to render as a code block in Linear; without
  # stripping, a plan body containing `<!-- pipeline: ... -->` inside ~~~ would
  # survive to the parse_pipeline_marker grep (ENG-122 review Minor 1).
  # sed-based substitution (brainstorm A15/A16). The earlier
  # ${var//pat/repl} form treated BASH_REMATCH[0] as a glob, not a
  # literal substring; when the matched span contained glob metachars
  # ([, ], *, ?) the substitution silently did nothing and the regex
  # match held → infinite loop on any body with backticked code spans
  # quoting paths/globs (P17). sed regex is glob-immune and anchors
  # to literal positions.
  body="$(printf '%s' "$body" | sed -E 's/~{3}[^~]*~{3}/ /g; s/`{3}[^`]*`{3}/ /g; s/`[^`]*`/ /g')"
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

  # Family precedence: pipeline > meta. Pipeline-family markers
  # (verdict, transition, decision) are state-driving — every caller of
  # this function cares about them. Meta-family markers (dedup, metric,
  # dispatch, ...) are bookkeeping that often coexists in the SAME comment
  # body alongside a state-driving pipeline marker (ENG-87 dispatch_id
  # auto-injection appends `<!-- meta: dispatch ... -->` AT THE END of
  # every comment that goes through the linear.sh chokepoint, so a
  # straight `tail -1` would return the dispatch marker for every
  # comment that carries both — hijacking find_fresh_verdict /
  # resume_in_progress_transition / _vh_drain_legacy_labels). Within a
  # family the LAST marker wins (legacy semantics: mechanical summary
  # writers append dedup markers at the end).
  marker="$(grep -oE '<!-- pipeline: [^>]+ -->' <<<"$body" 2>/dev/null | tail -1 || true)"
  if [[ -z "$marker" ]]; then
    marker="$(grep -oE '<!-- meta: [^>]+ -->' <<<"$body" 2>/dev/null | tail -1 || true)"
  fi
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

export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id strip_state_preserve_alloc assert_no_tool_invocation progress_md_path assert_no_write_to_path assert_no_tool_with_input_path validate_init_sh qa_predicate_path _validate_pass_criterion

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

# ENG-81: non-blocking lock acquisition for the per-issue
# .in-flight.lock used by run-local.sh's scheduler arm. Returns rc=0 on
# acquire, rc=1 if the lock is already held. acquire_lock with
# timeout=0 means "wait forever" (existing single-flight contract for
# the tick lock), so a separate try-mode helper is required to keep
# existing callers' semantics intact.
#
# Self-healing stale-lock recovery: a SIGKILL'd / oomkilled / host-
# rebooted holder leaves the lock dir behind because the EXIT trap
# never fired. On every acquire attempt that finds the dir present we
# read the recorded holder pid and reclaim if it is no longer alive
# (or no pid was recorded — legacy locks, or an interrupted acquire
# between mkdir and pid-write). Without this, K=2's larger fork
# surface doubles the chance of producing operator-stuck issues that
# only `rmdir` can recover.
try_acquire_lock() {
  local dir="$1"
  if mkdir "$dir" 2>/dev/null; then
    printf '%s\n' "$$" > "$dir/pid" 2>/dev/null || true
    date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/timestamp" 2>/dev/null || true
    return 0
  fi
  local holder_pid=""
  [[ -f "$dir/pid" ]] && holder_pid="$(cat "$dir/pid" 2>/dev/null || printf '')"
  # Only reclaim when the pid record is non-empty AND its process is dead.
  # An empty/absent pid file means "owner still arming" — another acquirer
  # has the mkdir but has not yet written its pid. Reclaiming in that
  # window would `rm -rf` a LIVE owner's lock dir.
  if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
    log "try_acquire_lock: reclaiming stale lock at $dir (holder=$holder_pid not alive)"
    rm -rf "$dir" 2>/dev/null || true
    if mkdir "$dir" 2>/dev/null; then
      printf '%s\n' "$$" > "$dir/pid" 2>/dev/null || true
      date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/timestamp" 2>/dev/null || true
      # Post-mkdir pid-readback: if a sibling reclaimer's rm-rf interleaved
      # between our mkdir and pid-write (both passed the dead-pid check),
      # the dir is now missing or holds a different pid. Treat that as
      # "lost the recovery race" — return rc=1 so the caller retries.
      local readback=""
      [[ -f "$dir/pid" ]] && readback="$(cat "$dir/pid" 2>/dev/null || printf '')"
      if [[ "$readback" == "$$" ]]; then
        return 0
      fi
      log "try_acquire_lock: post-mkdir pid-readback mismatch at $dir (got '${readback:-<absent>}', expected $$); lost recovery race"
    fi
  fi
  return 1
}

# rm -rf (not rmdir) because try_acquire_lock now writes pid+timestamp
# files into the lock dir. rmdir would silently fail and the lock would
# survive release, blocking the next acquire until the stale-recovery
# branch fires. rm -rf handles both pidless legacy dirs and the new
# shape uniformly.
release_lock() {
  local dir="$1"
  rm -rf "$dir" 2>/dev/null || true
}

export -f acquire_lock try_acquire_lock release_lock

# Counting semaphore: each in-flight `claude -p` dispatch claims one of
# N slot dirs at $HARNESS_STATE_DIR/.claude-semaphore/slot-<N>/. mkdir is
# atomic on POSIX so multiple acquirers race for distinct slots safely.
#
# CLAUDE_MUTEX_TIMEOUT keeps its "MUTEX" name as an env-var contract —
# operators may have set it in launchd plists. The wait log preserves
# the `[claude-mutex] waiting` token that mutex-test.sh's regex anchors.
CLAUDE_SEMAPHORE_DIR="$HARNESS_STATE_DIR/.claude-semaphore"
CLAUDE_MUTEX_TIMEOUT="${CLAUDE_MUTEX_TIMEOUT:-600}"
_ACQUIRED_SLOT_DIR=""

_claude_mutex_format_holders() {
  local d holders="" basename pid
  for d in "$CLAUDE_SEMAPHORE_DIR"/slot-*/; do
    [[ -d "$d" ]] || continue
    basename="${d%/}"; basename="${basename##*/}"
    pid=""
    [[ -f "$d/pid" ]] && pid="$(cat "$d/pid" 2>/dev/null || true)"
    holders="${holders:+${holders},}${basename}:${pid:-<unknown>}"
  done
  printf '%s\n' "${holders:-<none>}"
}

# Verify a freshly-claimed lock dir still carries our pid after mkdir+write.
# A sibling reclaimer that interleaved its own rm-rf between our mkdir and
# pid-write would either blow away the dir or replace our pid with its own.
# Returns 0 on match, 1 on mismatch.
_post_mkdir_readback_check() {
  local dir="$1" expected_pid="$2"
  local readback=""
  [[ -f "$dir/pid" ]] && readback="$(cat "$dir/pid" 2>/dev/null || printf '')"
  [[ "$readback" == "$expected_pid" ]] && return 0
  log "post-mkdir pid-readback mismatch at $dir (got '${readback:-<absent>}', expected $expected_pid)"
  return 1
}

acquire_claude_mutex() {
  [[ -z "${_ACQUIRED_SLOT_DIR:-}" ]] \
    || die "[claude-mutex] acquire_claude_mutex called twice without intervening release (already hold $_ACQUIRED_SLOT_DIR)"
  mkdir -p "$CLAUDE_SEMAPHORE_DIR"
  local cap
  cap="$(_resolve_K)"
  local waited=0 slot last_relog=0
  while :; do
    for (( slot=1; slot <= cap; slot++ )); do
      local d="$CLAUDE_SEMAPHORE_DIR/slot-$slot"
      if mkdir "$d" 2>/dev/null; then
        printf '%s\n' "$$" > "$d/pid"
        if _post_mkdir_readback_check "$d" "$$"; then
          _ACQUIRED_SLOT_DIR="$d"
          return 0
        fi
        log "[claude-mutex] post-mkdir pid-readback mismatch at $d; lost recovery race, retrying"
        continue
      fi
      # Stale-slot reclaim: if the slot's holder pid is dead, free + retake.
      # Mirrors try_acquire_lock's dead-pid recovery.
      local holder_pid=""
      [[ -f "$d/pid" ]] && holder_pid="$(cat "$d/pid" 2>/dev/null || printf '')"
      if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
        log "[claude-mutex] reclaiming stale slot $d (holder=$holder_pid not alive)"
        rm -rf "$d" 2>/dev/null || true
        if mkdir "$d" 2>/dev/null; then
          printf '%s\n' "$$" > "$d/pid"
          if _post_mkdir_readback_check "$d" "$$"; then
            _ACQUIRED_SLOT_DIR="$d"
            return 0
          fi
          log "[claude-mutex] post-mkdir pid-readback mismatch at $d after reclaim; lost race"
        fi
      fi
    done
    # Emit the wait log immediately on first contention, then re-log every
    # ~60s so an operator tailing the log sees that the wait is progressing
    # and which slots are currently held (slot-2's holder may differ from
    # slot-1's after Phase 4 widens cap > 1).
    if (( waited == 0 )) || (( waited - last_relog >= 60 )); then
      local holders
      holders="$(_claude_mutex_format_holders)"
      if (( waited == 0 )); then
        log "[claude-mutex] waiting for lock held by ${holders}"
      else
        log "[claude-mutex] still waiting (${waited}s elapsed) — slots held by ${holders}"
      fi
      last_relog=$waited
    fi
    (( waited >= CLAUDE_MUTEX_TIMEOUT )) \
      && die "[claude-mutex] timeout after ${CLAUDE_MUTEX_TIMEOUT}s (cap=$cap, all slots held)"
    sleep 1
    waited=$((waited + 1))
  done
}

release_claude_mutex() {
  [[ -n "$_ACQUIRED_SLOT_DIR" ]] || return 0
  rm -rf "$_ACQUIRED_SLOT_DIR"
  _ACQUIRED_SLOT_DIR=""
}

export -f acquire_claude_mutex release_claude_mutex

# ENG-81: per-tick concurrency cap.
# Precedence (mirrors the ENG-65 dispatch_timeout_minutes pattern):
#   1. env CLAUDE_MAX_CONCURRENT
#   2. config.json::orchestrator.max_concurrent_features
#   3. built-in default 2
# Non-integer / <1 falls through to the next layer with a `log`
# warning. The warning lands on stderr (log() writes to >&2), so
# stdout stays the resolved integer for `K=$(_resolve_K)` callers.
_resolve_K() {
  local k=""
  if [[ -n "${CLAUDE_MAX_CONCURRENT-}" ]]; then
    if [[ "$CLAUDE_MAX_CONCURRENT" =~ ^[0-9]+$ ]] && (( CLAUDE_MAX_CONCURRENT >= 1 )); then
      printf '%s\n' "$CLAUDE_MAX_CONCURRENT"
      return 0
    else
      log "_resolve_K: invalid CLAUDE_MAX_CONCURRENT=$CLAUDE_MAX_CONCURRENT (ignoring; falling through)"
    fi
  fi
  if [[ -f "${CONFIG:-}" ]]; then
    k="$(jq -r '.orchestrator.max_concurrent_features // empty' "$CONFIG" 2>/dev/null || printf '')"
    if [[ "$k" =~ ^[0-9]+$ ]] && (( k >= 1 )); then
      printf '%s\n' "$k"
      return 0
    elif [[ -n "$k" ]]; then
      log "_resolve_K: invalid orchestrator.max_concurrent_features=$k (ignoring; falling through)"
    fi
  else
    log "_resolve_K: CONFIG not readable at ${CONFIG:-<unset>}; using built-in default 2"
  fi
  printf '%s\n' "2"
}
export -f _resolve_K

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
