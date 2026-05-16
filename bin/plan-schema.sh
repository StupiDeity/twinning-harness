#!/usr/bin/env bash
# bin/plan-schema.sh — plan.json schema-v1 validator CLI (ENG-122).
#
# Usage:
#   bash bin/plan-schema.sh validate <file> [--ident <ENG-N>]
#
# Exit codes:
#   0  — valid schema-v1 document
#   33 — malformed: JSON parse error or top-level not an object
#   34 — incomplete: required field missing, wrong type, or unknown kind
#   35 — missing-file: the JSON file does not exist at the given path
#
# Canonical schema-v1 shape (single source of truth):
#
# ```json
# {
#   "plan_schema_version": 1,
#   "issue_id": "ENG-<NNN>",
#   "features": [
#     {
#       "id": "F-<n>",
#       "summary": "<non-empty string>",
#       "pass_criteria": [
#         { "kind": "smoke",       "command": "<non-empty>", "expect_exit": 0, "expect_stdout_match": "<regex|null>" },
#         { "kind": "file_exists", "path": "<non-empty>" },
#         { "kind": "grep",        "path": "<non-empty>", "pattern": "<non-empty>", "expect_match": true }
#       ]
#     }
#   ]
# }
# ```
#
# Required: plan_schema_version (==1), issue_id (matches ^ENG-[0-9]+$),
#   features[] (len>=1). Per-feature: id, summary, pass_criteria[] (len>=1).
# Per-criterion: kind in {smoke, file_exists, grep} + kind-specific fields.
# Unknown fields at any level: exit 0 + stderr warning (D-005 permissive).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# _emit_incomplete <message> — emit diagnostic to stdout.
_emit_incomplete() {
  printf 'plan-contract-incomplete: %s\n' "$1"
}

# _emit_malformed <message> — emit diagnostic to stdout.
_emit_malformed() {
  printf 'plan-contract-malformed: %s\n' "$1"
}

# _warn_unknown <level> <field> — emit warning to stderr (exit 0 path).
_warn_unknown() {
  log "[plan-schema] warning: unknown $1 field: $2"
}

# cmd_validate <file> [--ident <ENG-N>]
cmd_validate() {
  local file="" ident=""
  # Parse positional + flags.
  local first=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ident)
        if [[ $# -lt 2 ]]; then
          printf 'plan-schema.sh: --ident requires a value\n' >&2; return 33
        fi
        ident="$2"; shift 2 ;;
      --*)     printf 'plan-schema.sh: unknown flag %s\n' "$1" >&2; return 33 ;;
      *)
        if (( first )); then file="$1"; first=0
        else printf 'plan-schema.sh: unexpected argument %s\n' "$1" >&2; return 33
        fi
        shift
        ;;
    esac
  done

  [[ -n "$file" ]] || { printf 'plan-schema.sh: validate: file argument required\n' >&2; return 33; }

  # rc=35: missing file.
  [[ -f "$file" ]] || { printf 'plan-contract-missing: file not found: %s\n' "$file"; return 35; }

  # rc=33: JSON parse error or top-level not an object.
  local jq_type_out jq_rc=0
  jq_type_out="$(jq -r 'type' "$file" 2>&1)" || jq_rc=$?
  if (( jq_rc != 0 )); then
    _emit_malformed "JSON parse error: $jq_type_out"
    return 33
  fi
  if [[ "$jq_type_out" != "object" ]]; then
    _emit_malformed "top-level JSON is not an object (got: $jq_type_out)"
    return 33
  fi

  # ── Required top-level fields ──────────────────────────────────────

  # plan_schema_version must be integer 1.
  local ver
  ver="$(jq -r '.plan_schema_version // "MISSING"' "$file")"
  if [[ "$ver" == "MISSING" ]]; then
    _emit_incomplete "missing required field: plan_schema_version"
    return 34
  fi
  if ! jq -e '.plan_schema_version | type == "number"' "$file" >/dev/null 2>&1; then
    _emit_incomplete "plan_schema_version must be an integer, got: $ver"
    return 34
  fi
  if ! jq -e '.plan_schema_version == 1' "$file" >/dev/null 2>&1; then
    _emit_incomplete "plan_schema_version must be 1, got: $ver (this validator only handles schema v1)"
    return 34
  fi

  # issue_id must be a string matching ^ENG-[0-9]+$.
  local issue_id_type issue_id_val
  issue_id_type="$(jq -r '.issue_id | type' "$file" 2>/dev/null || printf 'missing')"
  issue_id_val="$(jq -r '.issue_id // "MISSING"' "$file")"
  if [[ "$issue_id_val" == "MISSING" || "$issue_id_type" != "string" ]]; then
    _emit_incomplete "issue_id must be a non-empty string (e.g. ENG-1), got type=$issue_id_type"
    return 34
  fi
  if ! [[ "$issue_id_val" =~ ^ENG-[0-9]+$ ]]; then
    _emit_incomplete "issue_id must match ^ENG-[0-9]+\$, got: $issue_id_val"
    return 34
  fi

  # If --ident was supplied, verify it matches.
  if [[ -n "$ident" && "$issue_id_val" != "$ident" ]]; then
    _emit_incomplete "issue_id mismatch: JSON has '$issue_id_val' but --ident '$ident' was passed (stale template?)"
    return 34
  fi

  # features must be an array with len >= 1.
  local features_type features_len
  features_type="$(jq -r '.features | type' "$file" 2>/dev/null || printf 'missing')"
  features_len="$(jq -r '.features | length' "$file" 2>/dev/null || printf '0')"
  if [[ "$features_type" != "array" ]]; then
    _emit_incomplete "features must be an array, got type=$features_type"
    return 34
  fi
  if (( features_len == 0 )); then
    _emit_incomplete "features must contain at least 1 entry"
    return 34
  fi

  # ── Per-feature validation ─────────────────────────────────────────
  local fi
  for (( fi=0; fi<features_len; fi++ )); do
    local feat_id feat_id_type feat_summary feat_summary_type
    local pc_type pc_len

    feat_id_type="$(jq -r --argjson i "$fi" '.features[$i].id | type' "$file")"
    feat_id="$(jq -r --argjson i "$fi" '.features[$i].id // "MISSING"' "$file")"
    if [[ "$feat_id" == "MISSING" || "$feat_id_type" != "string" || -z "$feat_id" ]]; then
      _emit_incomplete "features[$fi].id must be a non-empty string"
      return 34
    fi

    feat_summary_type="$(jq -r --argjson i "$fi" '.features[$i].summary | type' "$file")"
    feat_summary="$(jq -r --argjson i "$fi" '.features[$i].summary // "MISSING"' "$file")"
    if [[ "$feat_summary" == "MISSING" || "$feat_summary_type" != "string" || -z "$feat_summary" ]]; then
      _emit_incomplete "features[$fi].summary must be a non-empty string"
      return 34
    fi

    pc_type="$(jq -r --argjson i "$fi" '.features[$i].pass_criteria | type' "$file")"
    pc_len="$(jq -r --argjson i "$fi" '.features[$i].pass_criteria | length' "$file" 2>/dev/null || printf '0')"
    if [[ "$pc_type" != "array" ]]; then
      _emit_incomplete "features[$fi].pass_criteria must be an array"
      return 34
    fi
    if (( pc_len == 0 )); then
      _emit_incomplete "features[$fi].pass_criteria must contain at least 1 entry"
      return 34
    fi

    # ── Per-criterion validation ───────────────────────────────────
    local ci
    for (( ci=0; ci<pc_len; ci++ )); do
      local kind
      kind="$(jq -r --argjson i "$fi" --argjson j "$ci" '.features[$i].pass_criteria[$j].kind // "MISSING"' "$file")"
      if [[ "$kind" == "MISSING" ]]; then
        _emit_incomplete "features[$fi].pass_criteria[$ci].kind is required"
        return 34
      fi

      case "$kind" in
        smoke)
          local cmd_val cmd_type exit_val exit_type
          cmd_type="$(jq -r --argjson i "$fi" --argjson j "$ci" '.features[$i].pass_criteria[$j].command | type' "$file")"
          cmd_val="$(jq -r --argjson i "$fi" --argjson j "$ci" '.features[$i].pass_criteria[$j].command // "MISSING"' "$file")"
          if [[ "$cmd_val" == "MISSING" || "$cmd_type" != "string" || -z "$cmd_val" ]]; then
            _emit_incomplete "features[$fi].pass_criteria[$ci] (smoke): command must be a non-empty string"
            return 34
          fi
          exit_type="$(jq -r --argjson i "$fi" --argjson j "$ci" '.features[$i].pass_criteria[$j].expect_exit | type' "$file")"
          if [[ "$exit_type" != "number" ]]; then
            _emit_incomplete "features[$fi].pass_criteria[$ci] (smoke): expect_exit must be an integer, got type=$exit_type"
            return 34
          fi
          # Unknown fields for smoke criterion.
          local smoke_unknown
          smoke_unknown="$(jq -r --argjson i "$fi" --argjson j "$ci" \
            '(.features[$i].pass_criteria[$j] | keys) - ["kind","command","expect_exit","expect_stdout_match"] | .[]' \
            "$file" 2>/dev/null || true)"
          while IFS= read -r uf; do
            [[ -n "$uf" ]] && _warn_unknown "pass_criteria[smoke]" "$uf"
          done <<< "$smoke_unknown"
          ;;
        file_exists)
          local path_val path_type
          path_type="$(jq -r --argjson i "$fi" --argjson j "$ci" '.features[$i].pass_criteria[$j].path | type' "$file")"
          path_val="$(jq -r --argjson i "$fi" --argjson j "$ci" '.features[$i].pass_criteria[$j].path // "MISSING"' "$file")"
          if [[ "$path_val" == "MISSING" || "$path_type" != "string" || -z "$path_val" ]]; then
            _emit_incomplete "features[$fi].pass_criteria[$ci] (file_exists): path must be a non-empty string"
            return 34
          fi
          local fe_unknown
          fe_unknown="$(jq -r --argjson i "$fi" --argjson j "$ci" \
            '(.features[$i].pass_criteria[$j] | keys) - ["kind","path"] | .[]' \
            "$file" 2>/dev/null || true)"
          while IFS= read -r uf; do
            [[ -n "$uf" ]] && _warn_unknown "pass_criteria[file_exists]" "$uf"
          done <<< "$fe_unknown"
          ;;
        grep)
          local path_val path_type pattern_val pattern_type em_type
          path_type="$(jq -r --argjson i "$fi" --argjson j "$ci" '.features[$i].pass_criteria[$j].path | type' "$file")"
          path_val="$(jq -r --argjson i "$fi" --argjson j "$ci" '.features[$i].pass_criteria[$j].path // "MISSING"' "$file")"
          if [[ "$path_val" == "MISSING" || "$path_type" != "string" || -z "$path_val" ]]; then
            _emit_incomplete "features[$fi].pass_criteria[$ci] (grep): path must be a non-empty string"
            return 34
          fi
          pattern_type="$(jq -r --argjson i "$fi" --argjson j "$ci" '.features[$i].pass_criteria[$j].pattern | type' "$file")"
          pattern_val="$(jq -r --argjson i "$fi" --argjson j "$ci" '.features[$i].pass_criteria[$j].pattern // "MISSING"' "$file")"
          if [[ "$pattern_val" == "MISSING" || "$pattern_type" != "string" || -z "$pattern_val" ]]; then
            _emit_incomplete "features[$fi].pass_criteria[$ci] (grep): pattern must be a non-empty string"
            return 34
          fi
          em_type="$(jq -r --argjson i "$fi" --argjson j "$ci" '.features[$i].pass_criteria[$j].expect_match | type' "$file")"
          if [[ "$em_type" != "boolean" ]]; then
            _emit_incomplete "features[$fi].pass_criteria[$ci] (grep): expect_match must be a boolean, got type=$em_type"
            return 34
          fi
          local grep_unknown
          grep_unknown="$(jq -r --argjson i "$fi" --argjson j "$ci" \
            '(.features[$i].pass_criteria[$j] | keys) - ["kind","path","pattern","expect_match"] | .[]' \
            "$file" 2>/dev/null || true)"
          while IFS= read -r uf; do
            [[ -n "$uf" ]] && _warn_unknown "pass_criteria[grep]" "$uf"
          done <<< "$grep_unknown"
          ;;
        *)
          _emit_incomplete "features[$fi].pass_criteria[$ci]: unknown kind \"$kind\" (allowed: smoke, file_exists, grep)"
          return 34
          ;;
      esac
    done

    # Unknown fields per feature.
    local feat_unknown
    feat_unknown="$(jq -r --argjson i "$fi" \
      '(.features[$i] | keys) - ["id","summary","pass_criteria"] | .[]' \
      "$file" 2>/dev/null || true)"
    while IFS= read -r uf; do
      [[ -n "$uf" ]] && _warn_unknown "features[$fi]" "$uf"
    done <<< "$feat_unknown"
  done

  # ── Unknown top-level fields ───────────────────────────────────────
  local top_unknown
  top_unknown="$(jq -r \
    '(keys) - ["plan_schema_version","issue_id","features"] | .[]' \
    "$file" 2>/dev/null || true)"
  while IFS= read -r uf; do
    [[ -n "$uf" ]] && _warn_unknown "top-level" "$uf"
  done <<< "$top_unknown"

  printf 'plan-contract-valid: %s\n' "$file"
  return 0
}

main() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    validate) cmd_validate "$@" ;;
    *)
      printf 'Usage: bash bin/plan-schema.sh validate <file> [--ident <ENG-N>]\n' >&2
      exit 33
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
