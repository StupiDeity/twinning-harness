#!/usr/bin/env bash
# bin/verify-qa.sh — qa-predicate-<ident>.json validator + executor CLI (ENG-113).
#
# Usage:
#   bash bin/verify-qa.sh validate <file> [--ident <ENG-N>] [--worktree <path>]
#
# Trust boundary:
#   smoke.command runs UNDER bash -c, wrapped in gtimeout 60s. The QA agent
#   authors the predicate inside a dispatched claude -p sandbox; the operator
#   never types commands here. Treat smoke.command as agent-controlled but
#   sandboxed (no envelope to Linear writes; no access outside worktree;
#   60s wall-clock cap). gtimeout is REQUIRED — absence dies rather
#   than silently downgrading the wall-clock guarantee.
#
# --worktree fence:
#   When --worktree is passed, the value MUST be a subpath of TARGET_REPO
#   OR a subpath of $PROJECT_STATE_DIR (which is where per-issue worktrees
#   live). Bypassing the fence would let a malicious predicate pivot
#   `file_exists` / `grep` authority into arbitrary filesystem regions.
#   When --worktree is OMITTED, and PIPELINE_ISSUE_ID is set, the
#   per-issue worktree at $(issue_dir "$PIPELINE_ISSUE_ID")/worktree is
#   auto-derived — this is the form AGENT_PROMPTS.md §6 invokes.
#
# Exit codes (ENG-113; 42/43/44 — 39/40/41 are held by ENG-117 qa-payload-*):
#   0  — predicate schema valid; per-criterion JSONL report emitted on
#        stdout regardless of how many criteria failed (caller reads the
#        summary line to decide verdict per D-008/D-012).
#   42 — malformed: JSON parse error / not an object / predicate file
#        lives outside $PROJECT_STATE_DIR (D-011 authority surface) /
#        file size > 64 KiB (DoS-meaningful byte cap).
#   43 — incomplete: required field missing, wrong type, unknown kind,
#        --ident mismatch, D-013 path-traversal violation in a
#        file_exists / grep criterion (lexical guard; the executor adds
#        a realpath symlink-pivot guard via `realpath -m`), or
#        host-class denylist hit on an http_get URL.
#   44 — missing: predicate file does not exist at the given path.
#
# Canonical schema (qa_predicate_schema_version: 1):
#
# ```json
# {
#   "qa_predicate_schema_version": 1,
#   "issue_id": "ENG-<NNN>",
#   "pass_criteria": [
#     { "kind": "smoke",       "command": "<non-empty>", "expect_exit": 0, "expect_stdout_match": "<regex|null>" },
#     { "kind": "file_exists", "path": "<worktree-relative; no leading '/'; no '..'>" },
#     { "kind": "grep",        "path": "<worktree-relative>", "pattern": "<non-empty>", "expect_match": true },
#     { "kind": "http_get",    "url": "<http(s):// only; no loopback/RFC1918/IMDS>", "expect_status": 200, "expect_body_match": "<regex|null>" }
#   ]
# }
# ```
#
# Output (JSONL, on stdout):
#   { "index": <int>, "kind": "<kind>", "pass": <bool>, "detail": <string|null> }   (one per criterion)
#   { "summary": true, "total": <int>, "passed": <int>, "failed": <int>, "duration_s": <int> }

# No -e: per-criterion failures flip `pass=false` and the loop continues
# so the JSONL stream always ends with a summary line.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Bytes-per-parse cap at the authority phase (bounds memory/parse cost).
_QA_PREDICATE_MAX_BYTES=65536

# Script-scope so the EXIT trap can clean the snapshot on die-paths
# (e.g. _exec_smoke's gtimeout die) that bypass cmd_validate's `rm -f`.
_VERIFY_QA_SNAP_FILE=""
_verify_qa_cleanup_snap() {
  [[ -n "${_VERIFY_QA_SNAP_FILE:-}" ]] && rm -f "$_VERIFY_QA_SNAP_FILE"
  _VERIFY_QA_SNAP_FILE=""
}
trap '_verify_qa_cleanup_snap' EXIT

# ─── Phase 1: parse argv ──────────────────────────────────────────────
# Returns 0 with parsed values in ARG_FILE/ARG_IDENT/ARG_WORKTREE
# globals; emits diagnostics + returns 42 (malformed) on argv shape errors.
_parse_validate_argv() {
  ARG_FILE=""; ARG_IDENT=""; ARG_WORKTREE=""
  local first=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ident)
        if [[ $# -lt 2 ]]; then
          printf 'verify-qa.sh: --ident requires a value\n' >&2; return 42
        fi
        # Reject `--ident --worktree /path` — the parser would otherwise
        # consume the next flag as ARG_IDENT and silently misroute the
        # `/path` value. A value beginning with `--` is unambiguously a
        # caller mistake.
        if [[ "$2" == --* ]]; then
          printf 'verify-qa.sh: --ident requires a non-flag value, got: %s\n' "$2" >&2; return 42
        fi
        ARG_IDENT="$2"; shift 2 ;;
      --worktree)
        if [[ $# -lt 2 ]]; then
          printf 'verify-qa.sh: --worktree requires a value\n' >&2; return 42
        fi
        if [[ "$2" == --* ]]; then
          printf 'verify-qa.sh: --worktree requires a non-flag value, got: %s\n' "$2" >&2; return 42
        fi
        ARG_WORKTREE="$2"; shift 2 ;;
      --*)     printf 'verify-qa.sh: unknown flag %s\n' "$1" >&2; return 42 ;;
      *)
        if (( first )); then ARG_FILE="$1"; first=0
        else printf 'verify-qa.sh: unexpected argument %s\n' "$1" >&2; return 42
        fi
        shift
        ;;
    esac
  done
  [[ -n "$ARG_FILE" ]] || { printf 'verify-qa.sh: validate: file argument required\n' >&2; return 42; }
  return 0
}

# ─── Phase 2: authority surface (D-011) ──────────────────────────────
# Predicate file must (a) exist (rc=44), (b) live under $PROJECT_STATE_DIR
# realpath (rc=42), (c) be <= _QA_PREDICATE_MAX_BYTES bytes (rc=42).
# Splits the parent-realpath assignment so a failed cd properly trips
# the `if !` — the inlined `if ! file_real="$(cd … && pwd -P)/$(basename …)"`
# shape rolls the last-command exit into basename (always 0) and the
# cd error is silently swallowed.
_authority_check() {
  local file="$1"
  # Reject symlinks at the predicate path. `_authority_check` canonicalises
  # the PARENT but suffixes the basename verbatim — a symlink `predicate.json
  # -> /etc/shadow` would otherwise pass the parent-prefix check and the
  # downstream `cp -f` would follow it. The QA agent emits the predicate
  # via `Write` (no symlink creation surface); a symlink at this path is
  # never legitimate.
  if [[ -L "$file" ]]; then
    printf 'qa-predicate-malformed: predicate file must not be a symlink: %s\n' "$file"
    return 42
  fi
  if [[ ! -f "$file" ]]; then
    printf 'qa-predicate-missing: file not found: %s\n' "$file"
    return 44
  fi
  local size
  size="$(wc -c < "$file" 2>/dev/null | tr -d ' ')"
  if [[ -z "$size" ]] || (( size > _QA_PREDICATE_MAX_BYTES )); then
    printf 'qa-predicate-malformed: predicate file size %s exceeds cap %s bytes\n' \
      "${size:-unknown}" "$_QA_PREDICATE_MAX_BYTES"
    return 42
  fi
  local dir parent_real
  dir="$(dirname "$file")"
  if ! parent_real="$(cd "$dir" 2>/dev/null && pwd -P)"; then
    printf 'qa-predicate-malformed: cannot resolve realpath of predicate file parent: %s\n' "$dir"
    return 42
  fi
  local file_real="$parent_real/$(basename "$file")"
  local prefix_real
  prefix_real="$(cd "$PROJECT_STATE_DIR" && pwd -P)"
  if [[ "$file_real" != "$prefix_real"/* ]]; then
    printf 'qa-predicate-malformed: predicate file must live under $PROJECT_STATE_DIR; got %s\n' "$file"
    return 42
  fi
  return 0
}

# ─── Phase 3: --worktree fence ───────────────────────────────────────
# Accept-list for --worktree's realpath:
#   - subpath of TARGET_REPO, OR
#   - subpath of $PROJECT_STATE_DIR (per-issue worktrees live here).
# When --worktree is empty, auto-derive from PIPELINE_ISSUE_ID
# ($(issue_dir "$PIPELINE_ISSUE_ID")/worktree) — this is the shape
# AGENT_PROMPTS.md §6 invokes (no --worktree flag).
# Returns 0 with RESOLVED_WORKTREE populated, 43 on fence violation.
_worktree_fence() {
  local worktree="$1"
  RESOLVED_WORKTREE=""
  if [[ -z "$worktree" ]]; then
    # Auto-derive: PIPELINE_ISSUE_ID points at the per-issue worktree.
    if [[ -n "${PIPELINE_ISSUE_ID:-}" ]]; then
      local derived="$(issue_dir "$PIPELINE_ISSUE_ID")/worktree"
      if [[ -d "$derived" ]]; then
        RESOLVED_WORKTREE="$(cd "$derived" && pwd -P)"
        return 0
      fi
    fi
    if [[ -n "${TARGET_REPO:-}" && -d "${TARGET_REPO:-}" ]]; then
      RESOLVED_WORKTREE="$(cd "$TARGET_REPO" && pwd -P)"
    else
      RESOLVED_WORKTREE="."
    fi
    return 0
  fi
  if [[ ! -d "$worktree" ]]; then
    printf 'qa-predicate-incomplete: --worktree must be an existing directory, got: %s\n' "$worktree"
    return 43
  fi
  local wt_real
  wt_real="$(cd "$worktree" && pwd -P)"
  # Accept subpath of TARGET_REPO OR subpath of $PROJECT_STATE_DIR.
  # common.sh::require_env enforces TARGET_REPO; PROJECT_STATE_DIR is
  # always derived. Trust both are set + readable here.
  local target_real state_real
  target_real="$(cd "$TARGET_REPO" && pwd -P)"
  state_real="$(cd "$PROJECT_STATE_DIR" && pwd -P)"
  local in_target=0 in_state=0
  if [[ "$wt_real" == "$target_real" || "$wt_real" == "$target_real"/* ]]; then
    in_target=1
  fi
  if [[ "$wt_real" == "$state_real" || "$wt_real" == "$state_real"/* ]]; then
    in_state=1
  fi
  if (( in_target == 0 && in_state == 0 )); then
    printf 'qa-predicate-incomplete: --worktree must be a subpath of $TARGET_REPO or $PROJECT_STATE_DIR (got %s)\n' "$wt_real"
    return 43
  fi
  RESOLVED_WORKTREE="$wt_real"
  return 0
}

# ─── Phase 4: schema validation ──────────────────────────────────────
# Returns 0 with PC_LEN populated; or 42/43 on schema defects.
_validate_predicate_schema() {
  local file="$1" ident="$2"
  PC_LEN=0
  # rc=42: JSON parse error or top-level not an object.
  local jq_type_out jq_rc=0
  jq_type_out="$(jq -r 'type' "$file" 2>&1)" || jq_rc=$?
  if (( jq_rc != 0 )); then
    printf 'qa-predicate-malformed: JSON parse error: %s\n' "$jq_type_out"
    return 42
  fi
  if [[ "$jq_type_out" != "object" ]]; then
    printf 'qa-predicate-malformed: top-level JSON is not an object (got: %s)\n' "$jq_type_out"
    return 42
  fi

  # ── Required top-level fields ──────────────────────────────────────
  local ver
  ver="$(jq -r '.qa_predicate_schema_version // "MISSING"' "$file")"
  if [[ "$ver" == "MISSING" ]]; then
    printf 'qa-predicate-incomplete: missing required field: qa_predicate_schema_version\n'
    return 43
  fi
  if ! jq -e '.qa_predicate_schema_version | type == "number"' "$file" >/dev/null 2>&1; then
    printf 'qa-predicate-incomplete: qa_predicate_schema_version must be an integer, got: %s\n' "$ver"
    return 43
  fi
  if ! jq -e '.qa_predicate_schema_version == 1' "$file" >/dev/null 2>&1; then
    printf 'qa-predicate-incomplete: qa_predicate_schema_version must be 1, got: %s\n' "$ver"
    return 43
  fi

  local issue_id_type issue_id_val
  issue_id_type="$(jq -r '.issue_id | type' "$file" 2>/dev/null || printf 'missing')"
  issue_id_val="$(jq -r '.issue_id // "MISSING"' "$file")"
  if [[ "$issue_id_val" == "MISSING" || "$issue_id_type" != "string" ]]; then
    printf 'qa-predicate-incomplete: issue_id must be a non-empty string (e.g. ENG-1), got type=%s\n' "$issue_id_type"
    return 43
  fi
  if ! [[ "$issue_id_val" =~ ^ENG-[0-9]+$ ]]; then
    printf 'qa-predicate-incomplete: issue_id must match ^ENG-[0-9]+\$, got: %s\n' "$issue_id_val"
    return 43
  fi
  if [[ -n "$ident" && "$issue_id_val" != "$ident" ]]; then
    printf 'qa-predicate-incomplete: issue_id mismatch: JSON has '\''%s'\'' but --ident '\''%s'\'' was passed (stale template?)\n' "$issue_id_val" "$ident"
    return 43
  fi

  # pass_criteria must be an array with len >= 1.
  local pc_type pc_len
  pc_type="$(jq -r '.pass_criteria | type' "$file" 2>/dev/null || printf 'missing')"
  pc_len="$(jq -r '.pass_criteria | length' "$file" 2>/dev/null || printf '0')"
  if [[ "$pc_type" != "array" ]]; then
    printf 'qa-predicate-incomplete: pass_criteria must be an array, got type=%s\n' "$pc_type"
    return 43
  fi
  if (( pc_len == 0 )); then
    printf 'qa-predicate-incomplete: pass_criteria must contain at least 1 entry\n'
    return 43
  fi

  # Per-criterion schema validation via the shared helper. The helper
  # sets $_VALIDATE_CRIT_DIAG on rc=34; this caller wraps with the
  # `qa-predicate-incomplete:` prefix and returns rc=43 — independent
  # of the helper's internal rc.
  local ci
  for (( ci=0; ci<pc_len; ci++ )); do
    if ! _validate_pass_criterion "$file" 0 "$ci" \
      --kinds smoke,file_exists,grep,http_get \
      --shape flat; then
      printf 'qa-predicate-incomplete: %s\n' "$_VALIDATE_CRIT_DIAG"
      return 43
    fi
  done
  PC_LEN="$pc_len"
  return 0
}

# ─── Phase 5: executor ────────────────────────────────────────────────
# Walks pass_criteria and emits one JSONL line per criterion plus a
# summary line. Per-criterion failures NEVER short-circuit the loop —
# the contract is "always emit a summary line".
_execute_predicate() {
  local file="$1" anchor="$2" pc_len="$3"
  # Anchor's realpath (for symlink-resolved path-prefix checks below).
  local anchor_real
  anchor_real="$(cd "$anchor" 2>/dev/null && pwd -P)" || anchor_real="$anchor"

  local start_s now_s duration_s total=0 passed_n=0 failed_n=0
  start_s="$(date +%s 2>/dev/null)"
  local ci
  for (( ci=0; ci<pc_len; ci++ )); do
    local kind
    kind="$(jq -r --argjson j "$ci" '.pass_criteria[$j].kind' "$file")"
    total=$((total+1))
    local pass=false detail=null
    # The schema validator's --kinds gate makes any unrecognised kind
    # unreachable here: we don't need a `*)` fallthrough arm.
    case "$kind" in
      smoke)
        _exec_smoke "$file" "$ci" "$anchor_real"
        ;;
      file_exists)
        _exec_file_exists "$file" "$ci" "$anchor_real"
        ;;
      grep)
        _exec_grep "$file" "$ci" "$anchor_real"
        ;;
      http_get)
        _exec_http_get "$file" "$ci"
        ;;
    esac
    # _exec_* helpers set CRIT_PASS / CRIT_DETAIL; copy to local.
    pass="$CRIT_PASS"
    detail="$CRIT_DETAIL"
    if [[ "$pass" == "true" ]]; then
      passed_n=$((passed_n+1))
    else
      failed_n=$((failed_n+1))
    fi
    if [[ "$detail" == "null" ]]; then
      jq -cn --argjson i "$ci" --arg k "$kind" --argjson p "$pass" \
        '{index: $i, kind: $k, pass: $p, detail: null}'
    else
      jq -cn --argjson i "$ci" --arg k "$kind" --argjson p "$pass" --argjson d "$detail" \
        '{index: $i, kind: $k, pass: $p, detail: $d}'
    fi
  done

  now_s="$(date +%s 2>/dev/null)"
  duration_s=$(( now_s - start_s ))

  jq -cn --argjson t "$total" --argjson p "$passed_n" --argjson f "$failed_n" --argjson d "$duration_s" \
    '{summary: true, total: $t, passed: $p, failed: $f, duration_s: $d}'
}

# ─── Per-kind executor arms ──────────────────────────────────────────
# Each arm sets CRIT_PASS (true|false) and CRIT_DETAIL (jq-quoted JSON
# value or literal `null`) via caller globals.

_exec_smoke() {
  local file="$1" ci="$2" anchor_real="$3"
  local cmd expect_exit expect_stdout_match
  cmd="$(jq -r --argjson j "$ci" '.pass_criteria[$j].command' "$file")"
  expect_exit="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_exit' "$file")"
  expect_stdout_match="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_stdout_match // null' "$file")"
  # gtimeout REQUIRED — silent fallback contradicts the file-header
  # invariant. CLAUDE.md guarantees Homebrew coreutils on PATH for
  # launchd; absence is a host misconfig the operator must fix.
  command -v gtimeout >/dev/null 2>&1 \
    || die "verify-qa.sh: gtimeout required (brew install coreutils); refusing to run smoke without wall-clock cap"
  # Smoke runs at the worktree anchor cwd, not the runner's PWD.
  # Brainstorm D-011 promises "Commands execute with cwd =
  # <worktree-from-flag-or-inferred>".
  local out actual_exit=0
  # Probe `cd` so an "anchor disappeared" race (prior criterion rm'd the
  # worktree, broken-symlink anchor, perms drift) is distinguishable
  # from a plain exit-mismatch in the diagnostic.
  if ! ( cd "$anchor_real" 2>/dev/null ); then
    CRIT_PASS=false
    CRIT_DETAIL='"failed to cd to anchor"'
    return 0
  fi
  out="$( (cd "$anchor_real" && gtimeout 60 bash -c "$cmd") 2>&1)" || actual_exit=$?
  local exit_ok=false stdout_ok=true
  [[ "$actual_exit" == "$expect_exit" ]] && exit_ok=true
  if [[ "$expect_stdout_match" != "null" ]]; then
    local grep_rc=0
    printf '%s' "$out" | grep -Eq "$expect_stdout_match" || grep_rc=$?
    if (( grep_rc == 2 )); then
      CRIT_PASS=false
      CRIT_DETAIL='"expect_stdout_match: regex compile error"'
      return 0
    fi
    if (( grep_rc != 0 )); then stdout_ok=false; fi
  fi
  if [[ "$exit_ok" == "true" && "$stdout_ok" == "true" ]]; then
    CRIT_PASS=true; CRIT_DETAIL=null
  else
    CRIT_PASS=false
    CRIT_DETAIL="$(jq -nc --arg ae "$actual_exit" --arg ee "$expect_exit" \
      '{actual_exit: ($ae|tonumber), expect_exit: ($ee|tonumber)}')"
  fi
}

# Prefer Homebrew coreutils' `grealpath -m` (macOS BSD realpath lacks -m
# and would lie about non-existent paths, losing the symlink-pivot guard);
# fall back to GNU `realpath -m` on Linux. The startup gate
# `_check_canonical_path_available` ensures one of these is present, so
# this helper does not need to die — by the time it runs, the host has
# already been validated.
_canonical_path() {
  local p="$1"
  if command -v grealpath >/dev/null 2>&1; then
    grealpath -m -- "$p" 2>/dev/null
    return $?
  fi
  realpath -m -- "$p" 2>/dev/null
}

# Hoisted from _canonical_path — runs once at cmd_validate startup
# (before any JSONL emission). A die mid-loop would truncate the JSONL
# stream and leave the caller unable to read a summary line.
_check_canonical_path_available() {
  command -v grealpath >/dev/null 2>&1 && return 0
  realpath -m -- / >/dev/null 2>&1 && return 0
  die "verify-qa.sh: grealpath required (brew install coreutils) to canonicalise paths with non-existent leaves"
}

# Resolve a worktree-relative path under the anchor, then assert the
# realpath stays inside the anchor's realpath. `_canonical_path`
# (grealpath -m / realpath -m) canonicalises the FULL symlink chain in
# one call so a two-hop chain `a -> b -> /etc/passwd` cannot escape via
# the bypass a single-hop hand-rolled walker leaves wide open.
# Returns 0 with RESOLVED_PATH populated; returns 1 with RESOLVED_DIAGNOSTIC
# populated on escape.
_resolve_inside_anchor() {
  local anchor_real="$1" path="$2"
  local candidate="$anchor_real/$path"
  RESOLVED_PATH=""
  RESOLVED_DIAGNOSTIC=""
  local canonical
  canonical="$(_canonical_path "$candidate")"
  if [[ -z "$canonical" ]]; then
    RESOLVED_DIAGNOSTIC="realpath failed: $path"
    return 1
  fi
  # Containment check: canonical MUST equal anchor_real OR live under
  # anchor_real + "/".
  if [[ "$canonical" != "$anchor_real" && "$canonical" != "$anchor_real"/* ]]; then
    RESOLVED_DIAGNOSTIC="path escapes worktree via symlink: $path"
    return 1
  fi
  RESOLVED_PATH="$canonical"
  return 0
}

_exec_file_exists() {
  local file="$1" ci="$2" anchor_real="$3"
  local path
  path="$(jq -r --argjson j "$ci" '.pass_criteria[$j].path' "$file")"
  if ! _resolve_inside_anchor "$anchor_real" "$path"; then
    CRIT_PASS=false
    CRIT_DETAIL="$(jq -nc --arg d "$RESOLVED_DIAGNOSTIC" '$d')"
    return 0
  fi
  if [[ -e "$RESOLVED_PATH" ]]; then
    CRIT_PASS=true; CRIT_DETAIL=null
  else
    CRIT_PASS=false
    CRIT_DETAIL="$(jq -nc --arg p "$path" '"missing: " + $p')"
  fi
}

_exec_grep() {
  local file="$1" ci="$2" anchor_real="$3"
  local path pattern expect_match grep_rc=0
  path="$(jq -r --argjson j "$ci" '.pass_criteria[$j].path' "$file")"
  pattern="$(jq -r --argjson j "$ci" '.pass_criteria[$j].pattern' "$file")"
  expect_match="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_match' "$file")"
  if ! _resolve_inside_anchor "$anchor_real" "$path"; then
    CRIT_PASS=false
    CRIT_DETAIL="$(jq -nc --arg d "$RESOLVED_DIAGNOSTIC" '$d')"
    return 0
  fi
  if [[ ! -e "$RESOLVED_PATH" ]]; then
    CRIT_PASS=false
    CRIT_DETAIL="$(jq -nc --arg p "$RESOLVED_PATH" '"target missing: " + $p')"
    return 0
  fi
  # grep against a directory exits rc=2, which a naive executor would
  # mislabel as "regex compile error". Surface a distinct diagnostic.
  if [[ -d "$RESOLVED_PATH" ]]; then
    CRIT_PASS=false
    CRIT_DETAIL="$(jq -nc --arg p "$path" '"target is a directory (grep needs a file): " + $p')"
    return 0
  fi
  grep -Eq "$pattern" "$RESOLVED_PATH" || grep_rc=$?
  if (( grep_rc == 2 )); then
    CRIT_PASS=false; CRIT_DETAIL='"regex compile error"'
    return 0
  fi
  local matched=true
  (( grep_rc == 0 )) || matched=false
  if [[ "$expect_match" == "true" && "$matched" == "true" ]] \
     || [[ "$expect_match" == "false" && "$matched" == "false" ]]; then
    CRIT_PASS=true; CRIT_DETAIL=null
  else
    CRIT_PASS=false; CRIT_DETAIL='"no match"'
  fi
}

# Single curl request that captures BOTH status AND body in one
# round-trip. A two-request shape (`-o /dev/null` for status, then a
# second request for body) is a race against load-balanced / A/B-tested
# servers. Scheme + host-class are gated at schema-validation time;
# this executor trusts the upstream validation.
_exec_http_get() {
  local file="$1" ci="$2"
  local url expect_status expect_body_match code curl_rc=0
  url="$(jq -r --argjson j "$ci" '.pass_criteria[$j].url' "$file")"
  expect_status="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_status' "$file")"
  expect_body_match="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_body_match // null' "$file")"
  local body_tmp
  body_tmp="$(mktemp -t verify-qa-body.XXXXXX 2>/dev/null)"
  if [[ -z "$body_tmp" ]]; then
    CRIT_PASS=false; CRIT_DETAIL='"mktemp failed"'
    return 0
  fi
  code="$(curl -sS -o "$body_tmp" -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)" || curl_rc=$?
  if (( curl_rc != 0 )); then
    rm -f "$body_tmp"
    CRIT_PASS=false; CRIT_DETAIL='"connection failed"'
    return 0
  fi
  if [[ "$code" != "$expect_status" ]]; then
    rm -f "$body_tmp"
    CRIT_PASS=false
    CRIT_DETAIL="$(jq -nc --arg c "$code" --arg e "$expect_status" '"got " + $c + " (expected " + $e + ")"')"
    return 0
  fi
  if [[ "$expect_body_match" == "null" ]]; then
    rm -f "$body_tmp"
    CRIT_PASS=true; CRIT_DETAIL=null
    return 0
  fi
  local grep_rc=0
  grep -Eq "$expect_body_match" "$body_tmp" || grep_rc=$?
  rm -f "$body_tmp"
  if (( grep_rc == 2 )); then
    CRIT_PASS=false; CRIT_DETAIL='"expect_body_match: regex compile error"'
    return 0
  fi
  if (( grep_rc == 0 )); then
    CRIT_PASS=true; CRIT_DETAIL=null
  else
    CRIT_PASS=false; CRIT_DETAIL='"body did not match expect_body_match"'
  fi
}

# ─── Orchestrator: cmd_validate ──────────────────────────────────────
# Sequences phase 1 (argv) → phase 2 (authority) → phase 3 (worktree
# fence) → snapshot the predicate to a mktemp (TOCTOU closure) → phase 4
# (schema) → phase 5 (executor). Each phase short-circuits on failure;
# phase 5's per-criterion failures NEVER short-circuit.
cmd_validate() {
  _parse_validate_argv "$@" || return $?
  _check_canonical_path_available
  _authority_check "$ARG_FILE" || return $?
  _worktree_fence "$ARG_WORKTREE" || return $?
  # Snapshot the predicate to a mktemp inside $PROJECT_STATE_DIR so
  # schema validation and execution operate on the SAME bytes — closes
  # a confused-deputy TOCTOU where a malicious smoke command could
  # mutate the predicate file between validate and execute (the executor
  # would then read different bytes than what the validator approved).
  # Cleanup is explicit on every success/return path AND a script-level
  # EXIT trap (_verify_qa_cleanup_snap) covers the die-path leak from
  # downstream helpers (_canonical_path / _exec_smoke).
  local snap_dir snap_file rc=0
  snap_dir="$PROJECT_STATE_DIR/.verify-qa-snap"
  mkdir -p "$snap_dir" 2>/dev/null || {
    printf 'qa-predicate-malformed: cannot create snapshot dir under $PROJECT_STATE_DIR: %s\n' "$snap_dir"
    return 42
  }
  # `mkdir -p` succeeds if snap_dir is a pre-existing symlink to e.g. /etc;
  # the subsequent mktemp would then write outside $PROJECT_STATE_DIR.
  if [[ -L "$snap_dir" ]]; then
    printf 'qa-predicate-malformed: snapshot dir is a symlink: %s\n' "$snap_dir"
    return 42
  fi
  snap_file="$(mktemp "$snap_dir/predicate.XXXXXX" 2>/dev/null)"
  if [[ -z "$snap_file" ]]; then
    printf 'qa-predicate-malformed: mktemp failed under %s\n' "$snap_dir"
    return 42
  fi
  _VERIFY_QA_SNAP_FILE="$snap_file"
  # Single-pass cp: the bytes the validator and executor see are
  # whatever was on disk at this instant.
  if ! cp -f "$ARG_FILE" "$snap_file" 2>/dev/null; then
    rm -f "$snap_file"
    _VERIFY_QA_SNAP_FILE=""
    printf 'qa-predicate-malformed: failed to snapshot predicate to %s\n' "$snap_file"
    return 42
  fi
  _validate_predicate_schema "$snap_file" "$ARG_IDENT" || rc=$?
  if (( rc == 0 )); then
    _execute_predicate "$snap_file" "$RESOLVED_WORKTREE" "$PC_LEN" || rc=$?
  fi
  rm -f "$snap_file"
  _VERIFY_QA_SNAP_FILE=""
  return "$rc"
}

main() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    validate) cmd_validate "$@" ;;
    *)
      printf 'Usage: bash bin/verify-qa.sh validate <file> [--ident <ENG-N>] [--worktree <path>]\n' >&2
      exit 42
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
