#!/usr/bin/env bash
# bin/verify-qa.sh — qa-predicate-<ident>.json validator + executor CLI (ENG-113).
#
# Usage:
#   bash bin/verify-qa.sh validate <file> [--ident <ENG-N>] [--worktree <path>]
#
# Exit codes:
#   0  — predicate schema valid; per-criterion JSONL report emitted on
#        stdout regardless of how many criteria failed (caller reads the
#        summary line to decide verdict per D-008/D-012).
#   36 — malformed: JSON parse error / not an object / predicate file lives
#        outside $PROJECT_STATE_DIR (D-011 authority surface).
#   37 — incomplete: required field missing, wrong type, unknown kind,
#        --ident mismatch, OR D-013 path-traversal violation in a
#        file_exists / grep criterion.
#   38 — missing: predicate file does not exist at the given path.
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
#     { "kind": "http_get",    "url": "<non-empty>", "expect_status": 200, "expect_body_match": "<regex|null>" }
#   ]
# }
# ```
#
# Output (JSONL, on stdout):
#   { "index": <int>, "kind": "<kind>", "pass": <bool>, "detail": <string|null> }   (one per criterion)
#   { "summary": true, "total": <int>, "passed": <int>, "failed": <int>, "duration_ms": <int> }

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# cmd_validate <file> [--ident <ENG-N>] [--worktree <path>]
cmd_validate() {
  local file="" ident="" worktree=""
  local first=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ident)
        if [[ $# -lt 2 ]]; then
          printf 'verify-qa.sh: --ident requires a value\n' >&2; return 36
        fi
        ident="$2"; shift 2 ;;
      --worktree)
        if [[ $# -lt 2 ]]; then
          printf 'verify-qa.sh: --worktree requires a value\n' >&2; return 36
        fi
        worktree="$2"; shift 2 ;;
      --*)     printf 'verify-qa.sh: unknown flag %s\n' "$1" >&2; return 36 ;;
      *)
        if (( first )); then file="$1"; first=0
        else printf 'verify-qa.sh: unexpected argument %s\n' "$1" >&2; return 36
        fi
        shift
        ;;
    esac
  done

  [[ -n "$file" ]] || { printf 'verify-qa.sh: validate: file argument required\n' >&2; return 36; }

  # rc=38: predicate file absent.
  if [[ ! -f "$file" ]]; then
    printf 'qa-predicate-missing: file not found: %s\n' "$file"
    return 38
  fi

  # D-011 authority surface: predicate file must live under $PROJECT_STATE_DIR.
  # Resolve realpaths so $PROJECT_STATE_DIR/foo/../qa-predicate-ENG-1.json
  # collapses to a single canonical form before the prefix check.
  local file_real prefix_real
  file_real="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)/$(basename "$file")"
  prefix_real="$(cd "${PROJECT_STATE_DIR:-/nonexistent}" 2>/dev/null && pwd -P || printf '/nonexistent')"
  if [[ "$file_real" != "$prefix_real"/* ]]; then
    printf 'qa-predicate-malformed: predicate file must live under $PROJECT_STATE_DIR; got %s\n' "$file"
    return 36
  fi

  # rc=36: JSON parse error or top-level not an object.
  local jq_type_out jq_rc=0
  jq_type_out="$(jq -r 'type' "$file" 2>&1)" || jq_rc=$?
  if (( jq_rc != 0 )); then
    printf 'qa-predicate-malformed: JSON parse error: %s\n' "$jq_type_out"
    return 36
  fi
  if [[ "$jq_type_out" != "object" ]]; then
    printf 'qa-predicate-malformed: top-level JSON is not an object (got: %s)\n' "$jq_type_out"
    return 36
  fi

  # ── Required top-level fields ──────────────────────────────────────

  local ver
  ver="$(jq -r '.qa_predicate_schema_version // "MISSING"' "$file")"
  if [[ "$ver" == "MISSING" ]]; then
    printf 'qa-predicate-incomplete: missing required field: qa_predicate_schema_version\n'
    return 37
  fi
  if ! jq -e '.qa_predicate_schema_version | type == "number"' "$file" >/dev/null 2>&1; then
    printf 'qa-predicate-incomplete: qa_predicate_schema_version must be an integer, got: %s\n' "$ver"
    return 37
  fi
  if ! jq -e '.qa_predicate_schema_version == 1' "$file" >/dev/null 2>&1; then
    printf 'qa-predicate-incomplete: qa_predicate_schema_version must be 1, got: %s\n' "$ver"
    return 37
  fi

  local issue_id_type issue_id_val
  issue_id_type="$(jq -r '.issue_id | type' "$file" 2>/dev/null || printf 'missing')"
  issue_id_val="$(jq -r '.issue_id // "MISSING"' "$file")"
  if [[ "$issue_id_val" == "MISSING" || "$issue_id_type" != "string" ]]; then
    printf 'qa-predicate-incomplete: issue_id must be a non-empty string (e.g. ENG-1), got type=%s\n' "$issue_id_type"
    return 37
  fi
  if ! [[ "$issue_id_val" =~ ^ENG-[0-9]+$ ]]; then
    printf 'qa-predicate-incomplete: issue_id must match ^ENG-[0-9]+\$, got: %s\n' "$issue_id_val"
    return 37
  fi
  if [[ -n "$ident" && "$issue_id_val" != "$ident" ]]; then
    printf 'qa-predicate-incomplete: issue_id mismatch: JSON has '\''%s'\'' but --ident '\''%s'\'' was passed (stale template?)\n' "$issue_id_val" "$ident"
    return 37
  fi

  # pass_criteria must be an array with len >= 1.
  local pc_type pc_len
  pc_type="$(jq -r '.pass_criteria | type' "$file" 2>/dev/null || printf 'missing')"
  pc_len="$(jq -r '.pass_criteria | length' "$file" 2>/dev/null || printf '0')"
  if [[ "$pc_type" != "array" ]]; then
    printf 'qa-predicate-incomplete: pass_criteria must be an array, got type=%s\n' "$pc_type"
    return 37
  fi
  if (( pc_len == 0 )); then
    printf 'qa-predicate-incomplete: pass_criteria must contain at least 1 entry\n'
    return 37
  fi

  # Per-criterion schema validation via the shared helper.
  # _PASS_CRITERION_CALLER=qa-predicate flips the diagnostic prefix from
  # plan-contract-incomplete to qa-predicate-incomplete. The helper returns
  # rc=34 on any per-criterion failure (plan-schema's incomplete code);
  # translate to rc=37 (qa-predicate-incomplete) here so the verify-qa
  # caller sees a stable contract independent of the shared helper's
  # internal rc.
  local ci
  for (( ci=0; ci<pc_len; ci++ )); do
    _PASS_CRITERION_CALLER=qa-predicate \
      _validate_pass_criterion "$file" 0 "$ci" \
        --kinds smoke,file_exists,grep,http_get \
      || return 37
  done

  # ── Per-criterion execution ────────────────────────────────────────
  local anchor="${worktree:-${TARGET_REPO:-.}}"
  local start_ns now_ns duration_ms total=0 passed_n=0 failed_n=0
  start_ns="$(date +%s 2>/dev/null)"
  start_ns="$(printf '%s000' "$start_ns")"  # convert s → ms-ish

  for (( ci=0; ci<pc_len; ci++ )); do
    local kind
    kind="$(jq -r --argjson j "$ci" '.pass_criteria[$j].kind' "$file")"
    total=$((total+1))
    local pass=false detail=null
    case "$kind" in
      smoke)
        local cmd expect_exit expect_stdout_match
        cmd="$(jq -r --argjson j "$ci" '.pass_criteria[$j].command' "$file")"
        expect_exit="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_exit' "$file")"
        expect_stdout_match="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_stdout_match // null' "$file")"
        local out actual_exit=0
        out="$(bash -c "$cmd" 2>&1)" || actual_exit=$?
        local exit_ok=false stdout_ok=true
        [[ "$actual_exit" == "$expect_exit" ]] && exit_ok=true
        if [[ "$expect_stdout_match" != "null" ]]; then
          if ! printf '%s' "$out" | grep -Eq "$expect_stdout_match"; then
            stdout_ok=false
          fi
        fi
        if [[ "$exit_ok" == "true" && "$stdout_ok" == "true" ]]; then
          pass=true; detail=null
        else
          pass=false
          detail="$(jq -nc --arg ae "$actual_exit" --arg ee "$expect_exit" \
            '{actual_exit: ($ae|tonumber), expect_exit: ($ee|tonumber)}')"
        fi
        ;;
      file_exists)
        local path resolved
        path="$(jq -r --argjson j "$ci" '.pass_criteria[$j].path' "$file")"
        resolved="$anchor/$path"
        if [[ -e "$resolved" ]]; then
          pass=true; detail=null
        else
          pass=false; detail="$(jq -nc --arg p "$path" '"missing: " + $p')"
        fi
        ;;
      grep)
        local path pattern expect_match resolved grep_rc=0
        path="$(jq -r --argjson j "$ci" '.pass_criteria[$j].path' "$file")"
        pattern="$(jq -r --argjson j "$ci" '.pass_criteria[$j].pattern' "$file")"
        expect_match="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_match' "$file")"
        resolved="$anchor/$path"
        if [[ ! -e "$resolved" ]]; then
          pass=false; detail="$(jq -nc --arg p "$resolved" '"target missing: " + $p')"
        else
          grep -Eq "$pattern" "$resolved" || grep_rc=$?
          if (( grep_rc == 2 )); then
            pass=false; detail='"regex compile error"'
          else
            local matched=true
            (( grep_rc == 0 )) || matched=false
            if [[ "$expect_match" == "true" && "$matched" == "true" ]] \
               || [[ "$expect_match" == "false" && "$matched" == "false" ]]; then
              pass=true; detail=null
            else
              pass=false; detail='"no match"'
            fi
          fi
        fi
        ;;
      http_get)
        local url expect_status expect_body_match code curl_rc=0
        url="$(jq -r --argjson j "$ci" '.pass_criteria[$j].url' "$file")"
        expect_status="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_status' "$file")"
        expect_body_match="$(jq -r --argjson j "$ci" '.pass_criteria[$j].expect_body_match // null' "$file")"
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)" || curl_rc=$?
        if (( curl_rc != 0 )); then
          pass=false; detail='"connection failed"'
        elif [[ "$code" != "$expect_status" ]]; then
          pass=false; detail="$(jq -nc --arg c "$code" --arg e "$expect_status" '"got " + $c + " (expected " + $e + ")"')"
        else
          local body_ok=true
          if [[ "$expect_body_match" != "null" ]]; then
            local body
            body="$(curl -sS --max-time 10 "$url" 2>/dev/null)" || true
            if ! printf '%s' "$body" | grep -Eq "$expect_body_match"; then
              body_ok=false
            fi
          fi
          if [[ "$body_ok" == "true" ]]; then
            pass=true; detail=null
          else
            pass=false; detail='"body did not match expect_body_match"'
          fi
        fi
        ;;
    esac
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

  now_ns="$(date +%s 2>/dev/null)"
  now_ns="$(printf '%s000' "$now_ns")"
  duration_ms=$(( now_ns - start_ns ))

  jq -cn --argjson t "$total" --argjson p "$passed_n" --argjson f "$failed_n" --argjson d "$duration_ms" \
    '{summary: true, total: $t, passed: $p, failed: $f, duration_ms: $d}'
  return 0
}

main() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    validate) cmd_validate "$@" ;;
    *)
      printf 'Usage: bash bin/verify-qa.sh validate <file> [--ident <ENG-N>] [--worktree <path>]\n' >&2
      exit 36
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
