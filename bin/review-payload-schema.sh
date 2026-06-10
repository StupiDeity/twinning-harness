#!/usr/bin/env bash
# bin/review-payload-schema.sh — review-payload schema-v1 validator CLI (ENG-119).
#
# Usage:
#   bash bin/review-payload-schema.sh validate <file> [--ident <ENG-N>] \
#     [--dispatch-id <ENG-N-dNNNN>]
#
# Exit codes:
#   0  — valid schema-v1 document
#   36 — malformed: JSON parse error or top-level not an object
#   37 — incomplete: required field missing, wrong type, malformed enum,
#        or ident/dispatch-id mismatch
#   38 — missing-file: the JSON file does not exist at the given path
#
# Canonical schema-v1 shape (single source of truth):
#
# ```json
# {
#   "review_schema_version": 1,
#   "issue_id": "ENG-<NNN>",
#   "dispatch_id": "ENG-<NNN>-d<NNNN>",
#   "sha": "<non-empty>",
#   "verdict": "approve|request-changes|premise-failure|halt",
#   "dimensions": {
#     "correctness":     { "score": "pass|concern|fail", "rationale": "...",
#                          "thresholds_met": [...], "thresholds_missed": [...] },
#     "testing":         { ...same shape... },
#     "maintainability": { ...same shape... },
#     "scope":           { ...same shape... },
#     "security":        { ...optional... },
#     "performance":     { ...optional... },
#     "api_contract":    { ...optional... },
#     "premise":         { ...optional... }
#   }
# }
# ```
#
# Required top-level: review_schema_version (==1), issue_id (^ENG-[0-9]+$),
#   dispatch_id (^ENG-[0-9]+-d[0-9]+$), sha (non-empty string),
#   verdict (enum), dimensions (object with the 4 required keys).
# Per-dimension required: score (enum pass|concern|fail), rationale (non-empty
#   string), thresholds_met (array, may be empty), thresholds_missed (array,
#   may be empty). Unknown dimension keys: stderr warning, pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# _emit_incomplete <message> — emit diagnostic to stdout.
_emit_incomplete() {
  printf 'review-payload-incomplete: %s\n' "$1"
}

# _emit_malformed <message> — emit diagnostic to stdout.
_emit_malformed() {
  printf 'review-payload-malformed: %s\n' "$1"
}

# _warn_unknown <level> <field> — emit warning to stderr (exit 0 path).
_warn_unknown() {
  log "[review-payload-schema] warning: unknown $1: $2"
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
          printf 'review-payload-schema.sh: --ident requires a value\n' >&2; return 36
        fi
        ident="$2"; shift 2 ;;
      --dispatch-id)
        if [[ $# -lt 2 ]]; then
          printf 'review-payload-schema.sh: --dispatch-id requires a value\n' >&2; return 36
        fi
        dispatch_id_flag="$2"; dispatch_id_flag_set=1; shift 2 ;;
      --*)     printf 'review-payload-schema.sh: unknown flag %s\n' "$1" >&2; return 36 ;;
      *)
        if (( first )); then file="$1"; first=0
        else printf 'review-payload-schema.sh: unexpected argument %s\n' "$1" >&2; return 36
        fi
        shift
        ;;
    esac
  done

  [[ -n "$file" ]] || { printf 'review-payload-schema.sh: validate: file argument required\n' >&2; return 36; }

  # rc=38: missing file.
  [[ -f "$file" ]] || { printf 'review-payload-missing: file not found: %s\n' "$file"; return 38; }

  # rc=36: JSON parse error or top-level not an object.
  local jq_type_out jq_rc=0
  jq_type_out="$(jq -r 'type' "$file" 2>&1)" || jq_rc=$?
  if (( jq_rc != 0 )); then
    _emit_malformed "JSON parse error: $jq_type_out"
    return 36
  fi
  if [[ "$jq_type_out" != "object" ]]; then
    _emit_malformed "top-level JSON is not an object (got: $jq_type_out)"
    return 36
  fi

  # ── Required top-level fields ──────────────────────────────────────

  # review_schema_version must be integer 1.
  local ver
  ver="$(jq -r '.review_schema_version // "MISSING"' "$file")"
  if [[ "$ver" == "MISSING" ]]; then
    _emit_incomplete "missing required field: review_schema_version"
    return 37
  fi
  if ! jq -e '.review_schema_version | type == "number"' "$file" >/dev/null 2>&1; then
    _emit_incomplete "review_schema_version must be an integer, got: $ver"
    return 37
  fi
  if ! jq -e '.review_schema_version == 1' "$file" >/dev/null 2>&1; then
    _emit_incomplete "review_schema_version must be 1, got: $ver (this validator only handles schema v1)"
    return 37
  fi

  # issue_id must be a string matching ^ENG-[0-9]+$.
  local issue_id_type issue_id_val
  issue_id_type="$(jq -r '.issue_id | type' "$file" 2>/dev/null || printf 'missing')"
  issue_id_val="$(jq -r '.issue_id // "MISSING"' "$file")"
  if [[ "$issue_id_val" == "MISSING" || "$issue_id_type" != "string" ]]; then
    _emit_incomplete "issue_id must be a non-empty string (e.g. ENG-1), got type=$issue_id_type"
    return 37
  fi
  if ! [[ "$issue_id_val" =~ ^ENG-[0-9]+$ ]]; then
    _emit_incomplete "issue_id must match ^ENG-[0-9]+\$, got: $issue_id_val"
    return 37
  fi

  if [[ -n "$ident" && "$issue_id_val" != "$ident" ]]; then
    _emit_incomplete "issue_id mismatch: JSON has '$issue_id_val' but --ident '$ident' was passed (stale template?)"
    return 37
  fi

  # dispatch_id must be a string matching ^ENG-[0-9]+-d[0-9]+$.
  local dispatch_id_type dispatch_id_val
  dispatch_id_type="$(jq -r '.dispatch_id | type' "$file" 2>/dev/null || printf 'missing')"
  dispatch_id_val="$(jq -r '.dispatch_id // "MISSING"' "$file")"
  if [[ "$dispatch_id_val" == "MISSING" || "$dispatch_id_type" != "string" ]]; then
    _emit_incomplete "dispatch_id must be a non-empty string (e.g. ENG-1-d0001), got type=$dispatch_id_type"
    return 37
  fi
  if ! [[ "$dispatch_id_val" =~ ^ENG-[0-9]+-d[0-9]+$ ]]; then
    _emit_incomplete "dispatch_id must match ^ENG-[0-9]+-d[0-9]+\$, got: $dispatch_id_val"
    return 37
  fi

  # Fail-open when --dispatch-id flag is absent OR empty.
  if (( dispatch_id_flag_set )) && [[ -n "$dispatch_id_flag" && "$dispatch_id_val" != "$dispatch_id_flag" ]]; then
    _emit_incomplete "dispatch_id mismatch: JSON has '$dispatch_id_val' but --dispatch-id '$dispatch_id_flag' was passed (prior-dispatch payload survived pre-clean?)"
    return 37
  fi

  # sha must be a non-empty string.
  local sha_type sha_val
  sha_type="$(jq -r '.sha | type' "$file" 2>/dev/null || printf 'missing')"
  sha_val="$(jq -r '.sha // "MISSING"' "$file")"
  if [[ "$sha_val" == "MISSING" || "$sha_type" != "string" || -z "$sha_val" ]]; then
    _emit_incomplete "sha must be a non-empty string, got type=$sha_type"
    return 37
  fi

  # verdict must be in enum.
  local verdict_type verdict_val
  verdict_type="$(jq -r '.verdict | type' "$file" 2>/dev/null || printf 'missing')"
  verdict_val="$(jq -r '.verdict // "MISSING"' "$file")"
  if [[ "$verdict_val" == "MISSING" || "$verdict_type" != "string" ]]; then
    _emit_incomplete "verdict must be a string in {approve, request-changes, premise-failure, halt}, got type=$verdict_type"
    return 37
  fi
  case "$verdict_val" in
    approve|request-changes|premise-failure|halt) ;;
    *) _emit_incomplete "verdict must be in {approve, request-changes, premise-failure, halt}, got: $verdict_val"; return 37 ;;
  esac

  # dimensions must be an object.
  local dims_type
  dims_type="$(jq -r '.dimensions | type' "$file" 2>/dev/null || printf 'missing')"
  if [[ "$dims_type" != "object" ]]; then
    _emit_incomplete "dimensions must be an object, got type=$dims_type"
    return 37
  fi

  # ── Per-dimension validation ───────────────────────────────────────
  local required_dim
  for required_dim in correctness testing maintainability scope; do
    if ! jq -e --arg k "$required_dim" '.dimensions | has($k)' "$file" >/dev/null 2>&1; then
      _emit_incomplete "missing required dimension: $required_dim"
      return 37
    fi
    local dim_type
    dim_type="$(jq -r --arg k "$required_dim" '.dimensions[$k] | type' "$file" 2>/dev/null || printf 'missing')"
    if [[ "$dim_type" != "object" ]]; then
      _emit_incomplete "dimensions.$required_dim must be an object, got type=$dim_type"
      return 37
    fi

    # score: string in {pass, concern, fail}.
    local score_type score_val
    score_type="$(jq -r --arg k "$required_dim" '.dimensions[$k].score | type' "$file" 2>/dev/null || printf 'missing')"
    score_val="$(jq -r --arg k "$required_dim" '.dimensions[$k].score // "MISSING"' "$file")"
    if [[ "$score_val" == "MISSING" || "$score_type" != "string" ]]; then
      _emit_incomplete "dimensions.$required_dim.score must be a string in {pass, concern, fail}, got type=$score_type"
      return 37
    fi
    case "$score_val" in
      pass|concern|fail) ;;
      *) _emit_incomplete "dimensions.$required_dim.score must be in {pass, concern, fail}, got: $score_val"; return 37 ;;
    esac

    # rationale: non-empty string.
    local rationale_type rationale_val
    rationale_type="$(jq -r --arg k "$required_dim" '.dimensions[$k].rationale | type' "$file" 2>/dev/null || printf 'missing')"
    rationale_val="$(jq -r --arg k "$required_dim" '.dimensions[$k].rationale // "MISSING"' "$file")"
    if [[ "$rationale_val" == "MISSING" || "$rationale_type" != "string" || -z "$rationale_val" ]]; then
      _emit_incomplete "dimensions.$required_dim.rationale must be a non-empty string, got type=$rationale_type"
      return 37
    fi

    # thresholds_met: array.
    local met_type
    met_type="$(jq -r --arg k "$required_dim" '.dimensions[$k].thresholds_met | type' "$file" 2>/dev/null || printf 'missing')"
    if [[ "$met_type" != "array" ]]; then
      _emit_incomplete "dimensions.$required_dim.thresholds_met must be an array, got type=$met_type"
      return 37
    fi

    # thresholds_missed: array.
    local missed_type
    missed_type="$(jq -r --arg k "$required_dim" '.dimensions[$k].thresholds_missed | type' "$file" 2>/dev/null || printf 'missing')"
    if [[ "$missed_type" != "array" ]]; then
      _emit_incomplete "dimensions.$required_dim.thresholds_missed must be an array, got type=$missed_type"
      return 37
    fi
  done

  # ── Unknown dimension keys ─────────────────────────────────────────
  local dim_unknown
  dim_unknown="$(jq -r \
    '(.dimensions | keys) - ["correctness","testing","maintainability","scope","security","performance","api_contract","premise"] | .[]' \
    "$file" 2>/dev/null || true)"
  while IFS= read -r uf; do
    [[ -n "$uf" ]] && _warn_unknown "dimension" "$uf"
  done <<< "$dim_unknown"

  # ── Unknown top-level fields ───────────────────────────────────────
  local top_unknown
  top_unknown="$(jq -r \
    '(keys) - ["review_schema_version","issue_id","dispatch_id","sha","verdict","dimensions"] | .[]' \
    "$file" 2>/dev/null || true)"
  while IFS= read -r uf; do
    [[ -n "$uf" ]] && _warn_unknown "top-level field" "$uf"
  done <<< "$top_unknown"

  printf 'review-payload-valid: %s\n' "$file"
  return 0
}

main() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    validate) cmd_validate "$@" ;;
    *)
      printf 'Usage: bash bin/review-payload-schema.sh validate <file> [--ident <ENG-N>] [--dispatch-id <ENG-N-dNNNN>]\n' >&2
      exit 36
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
