#!/usr/bin/env bash
# bin/qa-payload-schema.sh — qa-payload schema-v1 validator CLI (ENG-117).
#
# Usage:
#   bash bin/qa-payload-schema.sh validate <file> [--ident <ENG-N>] \
#     [--dispatch-id <ENG-N-dNNNN>]
#
# Exit codes:
#   0  — valid schema-v1 document
#   39 — malformed: JSON parse error or top-level not an object
#   40 — incomplete: required field missing, wrong type, malformed enum,
#        or ident/dispatch-id mismatch
#   41 — missing-file: the JSON file does not exist at the given path
#
# Canonical schema-v1 shape (single source of truth):
#
# ```json
# {
#   "qa_payload_schema_version": 1,
#   "issue_id": "ENG-<NNN>",
#   "dispatch_id": "ENG-<NNN>-d<NNNN>",
#   "verdict": "pass|fail|halt",
#   "dimensions": [
#     {
#       "name": "<snake_case identifier>",
#       "score": 0.0,
#       "rationale": "<1-2 sentences citing concrete evidence>",
#       "threshold_met": true
#     }
#   ]
# }
# ```
#
# Required top-level: qa_payload_schema_version (==1), issue_id
#   (^ENG-[0-9]+$), dispatch_id (^ENG-[0-9]+-d[0-9]+$),
#   verdict (string in {pass, fail, halt}), dimensions (array, len>=1).
# Per-dimension required: name (^[a-z][a-z0-9_]*$), score (number in
#   [0.0, 1.0]), rationale (non-empty string), threshold_met (boolean).
# Unknown fields at any level: exit 0 + stderr warning (D-005 permissive).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# _emit_incomplete <message> — emit diagnostic to stdout.
_emit_incomplete() {
  printf 'qa-payload-incomplete: %s\n' "$1"
}

# _emit_malformed <message> — emit diagnostic to stdout.
_emit_malformed() {
  printf 'qa-payload-malformed: %s\n' "$1"
}

# _warn_unknown <level> <field> — emit warning to stderr (exit 0 path).
_warn_unknown() {
  log "[qa-payload-schema] warning: unknown $1: $2"
}

# cmd_validate <file> [--ident <ENG-N>] [--dispatch-id <ENG-N-dNNNN>]
cmd_validate() {
  local file="" ident="" dispatch_id_flag=""
  local dispatch_id_flag_set=0
  local first=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ident)
        if [[ $# -lt 2 ]]; then
          printf 'qa-payload-schema.sh: --ident requires a value\n' >&2; return 39
        fi
        ident="$2"; shift 2 ;;
      --dispatch-id)
        if [[ $# -lt 2 ]]; then
          printf 'qa-payload-schema.sh: --dispatch-id requires a value\n' >&2; return 39
        fi
        dispatch_id_flag="$2"; dispatch_id_flag_set=1; shift 2 ;;
      --*)     printf 'qa-payload-schema.sh: unknown flag %s\n' "$1" >&2; return 39 ;;
      *)
        if (( first )); then file="$1"; first=0
        else printf 'qa-payload-schema.sh: unexpected argument %s\n' "$1" >&2; return 39
        fi
        shift
        ;;
    esac
  done

  [[ -n "$file" ]] || { printf 'qa-payload-schema.sh: validate: file argument required\n' >&2; return 39; }

  # rc=41: missing file.
  [[ -f "$file" ]] || { printf 'qa-payload-missing: file not found: %s\n' "$file"; return 41; }

  # rc=39: JSON parse error or top-level not an object.
  local jq_type_out jq_rc=0
  jq_type_out="$(jq -r 'type' "$file" 2>&1)" || jq_rc=$?
  if (( jq_rc != 0 )); then
    _emit_malformed "JSON parse error: $jq_type_out"
    return 39
  fi
  if [[ "$jq_type_out" != "object" ]]; then
    _emit_malformed "top-level JSON is not an object (got: $jq_type_out)"
    return 39
  fi

  # ── Required top-level fields ──────────────────────────────────────

  # qa_payload_schema_version must be integer 1.
  local ver
  ver="$(jq -r '.qa_payload_schema_version // "MISSING"' "$file")"
  if [[ "$ver" == "MISSING" ]]; then
    _emit_incomplete "missing required field: qa_payload_schema_version"
    return 40
  fi
  if ! jq -e '.qa_payload_schema_version | type == "number"' "$file" >/dev/null 2>&1; then
    _emit_incomplete "qa_payload_schema_version must be an integer, got: $ver"
    return 40
  fi
  if ! jq -e '.qa_payload_schema_version == 1' "$file" >/dev/null 2>&1; then
    _emit_incomplete "qa_payload_schema_version must be 1, got: $ver (this validator only handles schema v1)"
    return 40
  fi

  # issue_id must be a string matching ^ENG-[0-9]+$.
  local issue_id_type issue_id_val
  issue_id_type="$(jq -r '.issue_id | type' "$file" 2>/dev/null || printf 'missing')"
  issue_id_val="$(jq -r '.issue_id // "MISSING"' "$file")"
  if [[ "$issue_id_val" == "MISSING" || "$issue_id_type" != "string" ]]; then
    _emit_incomplete "issue_id must be a non-empty string (e.g. ENG-1), got type=$issue_id_type"
    return 40
  fi
  if ! [[ "$issue_id_val" =~ ^ENG-[0-9]+$ ]]; then
    _emit_incomplete "issue_id must match ^ENG-[0-9]+\$, got: $issue_id_val"
    return 40
  fi

  if [[ -n "$ident" && "$issue_id_val" != "$ident" ]]; then
    _emit_incomplete "issue_id mismatch: JSON has '$issue_id_val' but --ident '$ident' was passed (stale template?)"
    return 40
  fi

  # dispatch_id must be a string matching ^ENG-[0-9]+-d[0-9]+$.
  local dispatch_id_type dispatch_id_val
  dispatch_id_type="$(jq -r '.dispatch_id | type' "$file" 2>/dev/null || printf 'missing')"
  dispatch_id_val="$(jq -r '.dispatch_id // "MISSING"' "$file")"
  if [[ "$dispatch_id_val" == "MISSING" || "$dispatch_id_type" != "string" ]]; then
    _emit_incomplete "dispatch_id must be a non-empty string (e.g. ENG-1-d0001), got type=$dispatch_id_type"
    return 40
  fi
  if ! [[ "$dispatch_id_val" =~ ^ENG-[0-9]+-d[0-9]+$ ]]; then
    _emit_incomplete "dispatch_id must match ^ENG-[0-9]+-d[0-9]+\$, got: $dispatch_id_val"
    return 40
  fi

  # Fail-open when --dispatch-id flag is absent OR empty.
  if (( dispatch_id_flag_set )) && [[ -n "$dispatch_id_flag" && "$dispatch_id_val" != "$dispatch_id_flag" ]]; then
    _emit_incomplete "dispatch_id mismatch: JSON has '$dispatch_id_val' but --dispatch-id '$dispatch_id_flag' was passed (prior-dispatch payload survived pre-clean?)"
    return 40
  fi

  # verdict must be in enum.
  local verdict_type verdict_val
  verdict_type="$(jq -r '.verdict | type' "$file" 2>/dev/null || printf 'missing')"
  verdict_val="$(jq -r '.verdict // "MISSING"' "$file")"
  if [[ "$verdict_val" == "MISSING" || "$verdict_type" != "string" ]]; then
    _emit_incomplete "verdict must be a string in {pass, fail, halt}, got type=$verdict_type"
    return 40
  fi
  case "$verdict_val" in
    pass|fail|halt) ;;
    *) _emit_incomplete "verdict must be in {pass, fail, halt}, got: $verdict_val"; return 40 ;;
  esac

  # dimensions must be an array with len >= 1.
  local dims_type dims_len
  dims_type="$(jq -r '.dimensions | type' "$file" 2>/dev/null || printf 'missing')"
  dims_len="$(jq -r '.dimensions | length' "$file" 2>/dev/null || printf '0')"
  if [[ "$dims_type" != "array" ]]; then
    _emit_incomplete "dimensions must be an array, got type=$dims_type"
    return 40
  fi
  if (( dims_len == 0 )); then
    _emit_incomplete "dimensions must contain at least 1 entry"
    return 40
  fi

  # ── Per-dimension validation ───────────────────────────────────────
  local di
  for (( di=0; di<dims_len; di++ )); do
    # name: non-empty string matching ^[a-z][a-z0-9_]*$.
    local name_type name_val
    name_type="$(jq -r --argjson i "$di" '.dimensions[$i].name | type' "$file" 2>/dev/null || printf 'missing')"
    name_val="$(jq -r --argjson i "$di" '.dimensions[$i].name // "MISSING"' "$file")"
    if [[ "$name_val" == "MISSING" || "$name_type" != "string" || -z "$name_val" ]]; then
      _emit_incomplete "dimensions[$di].name must be a non-empty string, got type=$name_type"
      return 40
    fi
    if ! [[ "$name_val" =~ ^[a-z][a-z0-9_]*$ ]]; then
      _emit_incomplete "dimensions[$di].name fails regex ^[a-z][a-z0-9_]*\$, got: $name_val"
      return 40
    fi

    # score: number in [0.0, 1.0].
    local score_type
    score_type="$(jq -r --argjson i "$di" '.dimensions[$i].score | type' "$file" 2>/dev/null || printf 'missing')"
    if [[ "$score_type" != "number" ]]; then
      _emit_incomplete "dimensions[$di].score must be a number in [0.0, 1.0], got type=$score_type"
      return 40
    fi
    if ! jq -e --argjson i "$di" '.dimensions[$i].score >= 0 and .dimensions[$i].score <= 1' "$file" >/dev/null 2>&1; then
      local score_val
      score_val="$(jq -r --argjson i "$di" '.dimensions[$i].score' "$file")"
      _emit_incomplete "dimensions[$di].score out of range [0.0, 1.0], got: $score_val"
      return 40
    fi

    # rationale: non-empty string.
    local rationale_type rationale_val
    rationale_type="$(jq -r --argjson i "$di" '.dimensions[$i].rationale | type' "$file" 2>/dev/null || printf 'missing')"
    rationale_val="$(jq -r --argjson i "$di" '.dimensions[$i].rationale // "MISSING"' "$file")"
    if [[ "$rationale_val" == "MISSING" || "$rationale_type" != "string" || -z "$rationale_val" ]]; then
      _emit_incomplete "dimensions[$di].rationale must be a non-empty string, got type=$rationale_type"
      return 40
    fi

    # threshold_met: boolean.
    local tm_type
    tm_type="$(jq -r --argjson i "$di" '.dimensions[$i].threshold_met | type' "$file" 2>/dev/null || printf 'missing')"
    if [[ "$tm_type" != "boolean" ]]; then
      _emit_incomplete "dimensions[$di].threshold_met must be a boolean, got type=$tm_type"
      return 40
    fi

    # Per-dimension unknown fields → stderr warning.
    local dim_unknown
    dim_unknown="$(jq -r --argjson i "$di" \
      '(.dimensions[$i] | keys) - ["name","score","rationale","threshold_met"] | .[]' \
      "$file" 2>/dev/null || true)"
    while IFS= read -r uf; do
      [[ -n "$uf" ]] && _warn_unknown "dimensions[$di]" "$uf"
    done <<< "$dim_unknown"
  done

  # ── Unknown top-level fields ───────────────────────────────────────
  local top_unknown
  top_unknown="$(jq -r \
    '(keys) - ["qa_payload_schema_version","issue_id","dispatch_id","verdict","dimensions"] | .[]' \
    "$file" 2>/dev/null || true)"
  while IFS= read -r uf; do
    [[ -n "$uf" ]] && _warn_unknown "top-level field" "$uf"
  done <<< "$top_unknown"

  printf 'qa-payload-valid: %s\n' "$file"
  return 0
}

main() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    validate) cmd_validate "$@" ;;
    *)
      printf 'Usage: bash bin/qa-payload-schema.sh validate <file> [--ident <ENG-N>] [--dispatch-id <ENG-N-dNNNN>]\n' >&2
      exit 39
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
