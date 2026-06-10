#!/usr/bin/env bash
# bin/verify-qa.sh — qa-predicate-<ident>.json validator + executor CLI (ENG-113).
#
# Usage:
#   bash bin/verify-qa.sh validate <file> [--ident <ENG-N>] [--worktree <path>]
#
# Trust boundary (file header — finding #7):
#   smoke.command runs UNDER bash -c, wrapped in gtimeout 60s. The QA agent
#   authors the predicate inside a dispatched claude -p sandbox; the operator
#   never types commands here. Treat smoke.command as agent-controlled but
#   sandboxed (no envelope to Linear writes; no access outside worktree;
#   60s wall-clock cap). DO NOT remove the gtimeout wrap or the bash -c
#   isolation without a brainstorm decision.
#
# --worktree fence (finding #15): when --worktree is passed, the value
#   MUST be a subpath of TARGET_REPO (realpath-normalised). Bypassing the
#   fence would let a malicious predicate pivot `file_exists` / `grep`
#   authority into $PROJECT_STATE_DIR (where stage-summary, dispatch_history,
#   issue-state.json live) and read those files as a byte-level oracle.
#
# Exit codes:
#   0  — predicate schema valid; per-criterion JSONL report emitted on
#        stdout regardless of how many criteria failed (caller reads the
#        summary line to decide verdict per D-008/D-012).
#   39 — malformed: JSON parse error / not an object / predicate file lives
#        outside $PROJECT_STATE_DIR (D-011 authority surface).
#   40 — incomplete: required field missing, wrong type, unknown kind,
#        --ident mismatch, OR D-013 path-traversal violation in a
#        file_exists / grep criterion (lexical guard; the executor adds
#        a realpath symlink-pivot guard).
#   41 — missing: predicate file does not exist at the given path.
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
#     { "kind": "http_get",    "url": "<http(s):// only>", "expect_status": 200, "expect_body_match": "<regex|null>" }
#   ]
# }
# ```
#
# Output (JSONL, on stdout):
#   { "index": <int>, "kind": "<kind>", "pass": <bool>, "detail": <string|null> }   (one per criterion)
#   { "summary": true, "total": <int>, "passed": <int>, "failed": <int>, "duration_s": <int> }

# set -uo pipefail (no -e): per-criterion failures must NOT abort the loop —
# the executor's contract is "always emit a summary line". A grep that
# fails to match, a curl that times out, or a smoke command that exits
# non-zero are NOT script-fatal; they flip `pass=false` and the loop
# continues. Adding `-e` would short-circuit on the first failing
# criterion and produce a truncated JSONL stream — the caller's
# `passed/failed` tally would diverge from `total`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Predicate-size cap (finding #28): bound pass_criteria length so a
# malicious or runaway predicate cannot DoS the executor.
_QA_PREDICATE_MAX_CRITERIA=64

# ─── Phase 1: parse argv ──────────────────────────────────────────────
# Returns 0 with parsed values in CALLER_FILE/CALLER_IDENT/CALLER_WORKTREE
# globals; emits diagnostics + returns 39 (malformed) on argv shape errors.
_parse_validate_argv() {
  CALLER_FILE=""; CALLER_IDENT=""; CALLER_WORKTREE=""
  local first=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ident)
        if [[ $# -lt 2 ]]; then
          printf 'verify-qa.sh: --ident requires a value\n' >&2; return 39
        fi
        CALLER_IDENT="$2"; shift 2 ;;
      --worktree)
        if [[ $# -lt 2 ]]; then
          printf 'verify-qa.sh: --worktree requires a value\n' >&2; return 39
        fi
        CALLER_WORKTREE="$2"; shift 2 ;;
      --*)     printf 'verify-qa.sh: unknown flag %s\n' "$1" >&2; return 39 ;;
      *)
        if (( first )); then CALLER_FILE="$1"; first=0
        else printf 'verify-qa.sh: unexpected argument %s\n' "$1" >&2; return 39
        fi
        shift
        ;;
    esac
  done
  [[ -n "$CALLER_FILE" ]] || { printf 'verify-qa.sh: validate: file argument required\n' >&2; return 39; }
  return 0
}

# ─── Phase 2: authority surface (D-011) ──────────────────────────────
# Predicate file must (a) exist (rc=41), (b) live under $PROJECT_STATE_DIR
# realpath (rc=39). When the file's parent dir doesn't exist, fail closed —
# do NOT degrade to lexical prefix match (finding #6: realpath check
# fails-open when dirname doesn't exist).
_authority_check() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    printf 'qa-predicate-missing: file not found: %s\n' "$file"
    return 41
  fi
  local dir
  dir="$(dirname "$file")"
  local file_real prefix_real
  if ! file_real="$(cd "$dir" 2>/dev/null && pwd -P)/$(basename "$file")"; then
    printf 'qa-predicate-malformed: cannot resolve realpath of predicate file: %s\n' "$file"
    return 39
  fi
  if [[ -z "${PROJECT_STATE_DIR:-}" || ! -d "${PROJECT_STATE_DIR:-}" ]]; then
    printf 'qa-predicate-malformed: $PROJECT_STATE_DIR is unset or not a directory: %s\n' "${PROJECT_STATE_DIR:-}"
    return 39
  fi
  prefix_real="$(cd "$PROJECT_STATE_DIR" && pwd -P)"
  if [[ "$file_real" != "$prefix_real"/* ]]; then
    printf 'qa-predicate-malformed: predicate file must live under $PROJECT_STATE_DIR; got %s\n' "$file"
    return 39
  fi
  return 0
}

# ─── Phase 3: --worktree fence (finding #15) ─────────────────────────
# Resolve --worktree to its realpath and assert it's a subpath of
# TARGET_REPO. Bypassing this fence would let a predicate read
# $PROJECT_STATE_DIR via file_exists / grep authority. Empty worktree =
# fall back to TARGET_REPO (already inside the fence).
# Returns 0 on success, 40 (incomplete) on fence violation.
_worktree_fence() {
  local worktree="$1"
  RESOLVED_WORKTREE=""
  if [[ -z "$worktree" ]]; then
    if [[ -n "${TARGET_REPO:-}" && -d "${TARGET_REPO:-}" ]]; then
      RESOLVED_WORKTREE="$(cd "$TARGET_REPO" && pwd -P)"
    else
      RESOLVED_WORKTREE="."
    fi
    return 0
  fi
  if [[ ! -d "$worktree" ]]; then
    printf 'qa-predicate-incomplete: --worktree must be an existing directory, got: %s\n' "$worktree"
    return 40
  fi
  local wt_real target_real
  wt_real="$(cd "$worktree" && pwd -P)"
  if [[ -z "${TARGET_REPO:-}" || ! -d "${TARGET_REPO:-}" ]]; then
    printf 'qa-predicate-incomplete: $TARGET_REPO unset or not a directory; cannot fence --worktree\n'
    return 40
  fi
  target_real="$(cd "$TARGET_REPO" && pwd -P)"
  # Accept exact match OR subpath: realpath equality or prefix + "/".
  if [[ "$wt_real" != "$target_real" && "$wt_real" != "$target_real"/* ]]; then
    printf 'qa-predicate-incomplete: --worktree must be a subpath of $TARGET_REPO (got %s; target %s)\n' "$wt_real" "$target_real"
    return 40
  fi
  RESOLVED_WORKTREE="$wt_real"
  return 0
}

# ─── Phase 4: schema validation ──────────────────────────────────────
# Returns 0 with PC_LEN populated; or 39/40 on schema defects.
_validate_predicate_schema() {
  local file="$1" ident="$2"
  PC_LEN=0
  # rc=39: JSON parse error or top-level not an object.
  local jq_type_out jq_rc=0
  jq_type_out="$(jq -r 'type' "$file" 2>&1)" || jq_rc=$?
  if (( jq_rc != 0 )); then
    printf 'qa-predicate-malformed: JSON parse error: %s\n' "$jq_type_out"
    return 39
  fi
  if [[ "$jq_type_out" != "object" ]]; then
    printf 'qa-predicate-malformed: top-level JSON is not an object (got: %s)\n' "$jq_type_out"
    return 39
  fi

  # ── Required top-level fields ──────────────────────────────────────
  local ver
  ver="$(jq -r '.qa_predicate_schema_version // "MISSING"' "$file")"
  if [[ "$ver" == "MISSING" ]]; then
    printf 'qa-predicate-incomplete: missing required field: qa_predicate_schema_version\n'
    return 40
  fi
  if ! jq -e '.qa_predicate_schema_version | type == "number"' "$file" >/dev/null 2>&1; then
    printf 'qa-predicate-incomplete: qa_predicate_schema_version must be an integer, got: %s\n' "$ver"
    return 40
  fi
  if ! jq -e '.qa_predicate_schema_version == 1' "$file" >/dev/null 2>&1; then
    printf 'qa-predicate-incomplete: qa_predicate_schema_version must be 1, got: %s\n' "$ver"
    return 40
  fi

  local issue_id_type issue_id_val
  issue_id_type="$(jq -r '.issue_id | type' "$file" 2>/dev/null || printf 'missing')"
  issue_id_val="$(jq -r '.issue_id // "MISSING"' "$file")"
  if [[ "$issue_id_val" == "MISSING" || "$issue_id_type" != "string" ]]; then
    printf 'qa-predicate-incomplete: issue_id must be a non-empty string (e.g. ENG-1), got type=%s\n' "$issue_id_type"
    return 40
  fi
  if ! [[ "$issue_id_val" =~ ^ENG-[0-9]+$ ]]; then
    printf 'qa-predicate-incomplete: issue_id must match ^ENG-[0-9]+\$, got: %s\n' "$issue_id_val"
    return 40
  fi
  if [[ -n "$ident" && "$issue_id_val" != "$ident" ]]; then
    printf 'qa-predicate-incomplete: issue_id mismatch: JSON has '\''%s'\'' but --ident '\''%s'\'' was passed (stale template?)\n' "$issue_id_val" "$ident"
    return 40
  fi

  # pass_criteria must be an array with len >= 1.
  local pc_type pc_len
  pc_type="$(jq -r '.pass_criteria | type' "$file" 2>/dev/null || printf 'missing')"
  pc_len="$(jq -r '.pass_criteria | length' "$file" 2>/dev/null || printf '0')"
  if [[ "$pc_type" != "array" ]]; then
    printf 'qa-predicate-incomplete: pass_criteria must be an array, got type=%s\n' "$pc_type"
    return 40
  fi
  if (( pc_len == 0 )); then
    printf 'qa-predicate-incomplete: pass_criteria must contain at least 1 entry\n'
    return 40
  fi
  if (( pc_len > _QA_PREDICATE_MAX_CRITERIA )); then
    printf 'qa-predicate-incomplete: pass_criteria must contain at most %s entries (got %s)\n' "$_QA_PREDICATE_MAX_CRITERIA" "$pc_len"
    return 40
  fi

  # Per-criterion schema validation via the shared helper.
  # `--caller qa-predicate` flips the diagnostic prefix; `--shape flat`
  # selects the top-level `pass_criteria[$j]` jq path (verify-qa's shape).
  # The helper returns rc=34 on any per-criterion failure (plan-schema's
  # internal incomplete code); translate to rc=40 (qa-predicate-incomplete)
  # here so the verify-qa caller sees a stable contract independent of the
  # shared helper's internal rc.
  local ci
  for (( ci=0; ci<pc_len; ci++ )); do
    _validate_pass_criterion "$file" 0 "$ci" \
      --kinds smoke,file_exists,grep,http_get \
      --caller qa-predicate \
      --shape flat \
      || return 40
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
    case "$kind" in
      smoke)
        _exec_smoke "$file" "$ci"
        ;;
      file_exists)
        _exec_file_exists "$file" "$ci" "$anchor" "$anchor_real"
        ;;
      grep)
        _exec_grep "$file" "$ci" "$anchor" "$anchor_real"
        ;;
      http_get)
        _exec_http_get "$file" "$ci"
        ;;
      *)
        # Defense-in-depth: schema validation already gates on the
        # --kinds CSV, so an unknown kind here means a future code-path
        # added the kind to the validator but forgot to wire the
        # executor arm. Emit pass=false with a distinct diagnostic so
        # the gap surfaces in QA's output (finding #14).
        pass=false
        detail="$(jq -nc --arg k "$kind" '"executor missing kind: " + $k')"
        ;;
    esac
    # _exec_* helpers set CRIT_PASS / CRIT_DETAIL; copy to local.
    pass="$CRIT_PASS"
    detail="$CRIT_DETAIL"
    # Emit one JSONL line per criterion.
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
# value or literal `null`). bash-3 lacks namerefs, so caller globals are
# the simplest robust hand-off.

_exec_smoke() {
  local file="$1" ci="$2"
  local cmd expect_exit expect_stdout_match
  cmd="$(jq -r --argjson j "$ci" '.pass_criteria[$j].command' "$file")"
  expect_exit="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_exit' "$file")"
  expect_stdout_match="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_stdout_match // null' "$file")"
  # gtimeout 60s wall-clock cap (finding #7): smoke.command is
  # agent-controlled. Falls back to plain `bash -c` if gtimeout is
  # absent on the host (CLAUDE.md PATH section ships coreutils via
  # Homebrew; absence is a launchd-host misconfig).
  local out actual_exit=0 timeout_bin=""
  if command -v gtimeout >/dev/null 2>&1; then timeout_bin="gtimeout 60"; fi
  if [[ -n "$timeout_bin" ]]; then
    out="$($timeout_bin bash -c "$cmd" 2>&1)" || actual_exit=$?
  else
    out="$(bash -c "$cmd" 2>&1)" || actual_exit=$?
  fi
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

# Resolve a worktree-relative path under the anchor, then assert the
# realpath stays inside the anchor's realpath. Closes the symlink-pivot
# vector (critical #4): a malicious predicate can drop
# `<worktree>/leak -> /etc/passwd` and use `file_exists` / `grep` as a
# byte-level exfiltration oracle. The lexical guard in
# _validate_pass_criterion catches `path: "../escape"`; this run-time
# realpath check catches symlinks the lexical guard cannot see.
# Returns 0 with RESOLVED_PATH populated, 1 with diagnostic.
_resolve_inside_anchor() {
  local anchor="$1" anchor_real="$2" path="$3"
  local candidate="$anchor/$path"
  RESOLVED_PATH=""
  RESOLVED_DIAGNOSTIC=""
  # Resolve realpath even when the leaf doesn't exist yet (file_exists
  # absent-path test): use `cd "$(dirname …)" && pwd -P` for the parent,
  # then append the leaf basename.
  local parent leaf real_parent
  parent="$(dirname "$candidate")"
  leaf="$(basename "$candidate")"
  if ! real_parent="$(cd "$parent" 2>/dev/null && pwd -P)"; then
    # Parent doesn't exist — caller (_exec_file_exists / _exec_grep) will
    # report the missing path in its diagnostic; no escape vector here
    # because the realpath couldn't traverse a symlink we can't enter.
    RESOLVED_PATH="$candidate"
    return 0
  fi
  local resolved="$real_parent/$leaf"
  # The leaf itself may be a symlink: resolve via -P stat trick.
  if [[ -L "$resolved" ]]; then
    if ! resolved="$(cd "$(dirname "$resolved")" && pwd -P)/$leaf"; then
      RESOLVED_DIAGNOSTIC="symlink resolution failed"
      return 1
    fi
    # readlink the leaf and resolve relative to its dir.
    local link_tgt
    link_tgt="$(readlink "$resolved")"
    if [[ "$link_tgt" == /* ]]; then
      resolved="$link_tgt"
    else
      resolved="$real_parent/$link_tgt"
    fi
    # Canonicalise via subshell cd if the resolved leaf is a directory or
    # the resolved leaf's parent exists.
    local rp rl
    rp="$(dirname "$resolved")"
    rl="$(basename "$resolved")"
    if [[ -d "$rp" ]]; then
      resolved="$(cd "$rp" && pwd -P)/$rl"
    fi
  fi
  # Anchor-realpath containment: resolved MUST equal anchor_real OR live
  # under anchor_real + "/".
  if [[ "$resolved" != "$anchor_real" && "$resolved" != "$anchor_real"/* ]]; then
    RESOLVED_DIAGNOSTIC="path escapes worktree via symlink: $path"
    return 1
  fi
  RESOLVED_PATH="$resolved"
  return 0
}

_exec_file_exists() {
  local file="$1" ci="$2" anchor="$3" anchor_real="$4"
  local path
  path="$(jq -r --argjson j "$ci" '.pass_criteria[$j].path' "$file")"
  if ! _resolve_inside_anchor "$anchor" "$anchor_real" "$path"; then
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
  local file="$1" ci="$2" anchor="$3" anchor_real="$4"
  local path pattern expect_match grep_rc=0
  path="$(jq -r --argjson j "$ci" '.pass_criteria[$j].path' "$file")"
  pattern="$(jq -r --argjson j "$ci" '.pass_criteria[$j].pattern' "$file")"
  expect_match="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_match' "$file")"
  if ! _resolve_inside_anchor "$anchor" "$anchor_real" "$path"; then
    CRIT_PASS=false
    CRIT_DETAIL="$(jq -nc --arg d "$RESOLVED_DIAGNOSTIC" '$d')"
    return 0
  fi
  if [[ ! -e "$RESOLVED_PATH" ]]; then
    CRIT_PASS=false
    CRIT_DETAIL="$(jq -nc --arg p "$RESOLVED_PATH" '"target missing: " + $p')"
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

_exec_http_get() {
  local file="$1" ci="$2"
  local url expect_status expect_body_match code curl_rc=0
  url="$(jq -r --argjson j "$ci" '.pass_criteria[$j].url' "$file")"
  expect_status="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_status' "$file")"
  expect_body_match="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_body_match // null' "$file")"
  # Defense-in-depth: validator already restricts scheme to http(s) at
  # schema-validation time; re-check here so a future executor-only call
  # path cannot bypass.
  if [[ ! "$url" =~ ^https?:// ]]; then
    CRIT_PASS=false
    CRIT_DETAIL="$(jq -nc --arg u "$url" '"url scheme must be http(s): " + $u')"
    return 0
  fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)" || curl_rc=$?
  if (( curl_rc != 0 )); then
    CRIT_PASS=false; CRIT_DETAIL='"connection failed"'
    return 0
  fi
  if [[ "$code" != "$expect_status" ]]; then
    CRIT_PASS=false
    CRIT_DETAIL="$(jq -nc --arg c "$code" --arg e "$expect_status" '"got " + $c + " (expected " + $e + ")"')"
    return 0
  fi
  if [[ "$expect_body_match" == "null" ]]; then
    CRIT_PASS=true; CRIT_DETAIL=null
    return 0
  fi
  # Body-match arm issues a single additional request (finding #21 noted
  # the original two-request shape as a race surface; we still need ONE
  # body request because the status-only call used `-o /dev/null`).
  local body grep_rc=0
  body="$(curl -sS --max-time 10 "$url" 2>/dev/null)" || curl_rc=$?
  if (( curl_rc != 0 )); then
    CRIT_PASS=false; CRIT_DETAIL='"body fetch failed"'
    return 0
  fi
  printf '%s' "$body" | grep -Eq "$expect_body_match" || grep_rc=$?
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
# fence) → phase 4 (schema) → phase 5 (executor). Each phase short-
# circuits on failure; phase 5's per-criterion failures NEVER short-
# circuit.
cmd_validate() {
  _parse_validate_argv "$@" || return $?
  _authority_check "$CALLER_FILE" || return $?
  _worktree_fence "$CALLER_WORKTREE" || return $?
  _validate_predicate_schema "$CALLER_FILE" "$CALLER_IDENT" || return $?
  _execute_predicate "$CALLER_FILE" "$RESOLVED_WORKTREE" "$PC_LEN"
  return 0
}

main() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    validate) cmd_validate "$@" ;;
    *)
      printf 'Usage: bash bin/verify-qa.sh validate <file> [--ident <ENG-N>] [--worktree <path>]\n' >&2
      exit 39
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
