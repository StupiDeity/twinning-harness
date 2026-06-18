#!/usr/bin/env bash
# bin/plan-schema.sh — plan.json schema-v1 validator CLI (ENG-122) +
# plan.md System-invariants section validator (ENG-157) +
# content-body → canonical merge subcommand (ENG-204).
#
# Usage:
#   bash bin/plan-schema.sh validate <file> [--ident <ENG-N>]
#   bash bin/plan-schema.sh validate-md <file>
#   bash bin/plan-schema.sh prepare --body <body> --md <md> --ident <ENG-N>
#
# Exit codes (validate — JSON):
#   0  — valid schema-v1 document
#   33 — malformed: JSON parse error or top-level not an object
#   34 — incomplete: required field missing, wrong type, or unknown kind
#   35 — missing-file: the JSON file does not exist at the given path
#
# Exit codes (prepare — ENG-204 in-agent merge):
#   0  — merged OK; prints `plan-contract-prepared: <canonical-path>` to stdout
#   33 — body parse/symlink/realpath/write-fail (malformed)
#   34 — required flag missing or --ident regex mismatch
#   35 — --body file not found (missing)
#
# Exit codes (validate-md — MD System-invariants section):
#   0  — valid: `## System invariants` H2 section present with ≥1 bullet
#        (CommonMark `-`/`*`/`+` markers), every bullet carries a parseable
#        `verified_by:` token of the form `<path>:<test-name>` OR `task:T<N>`
#        somewhere in its body (first line or a continuation line).
#   33 — malformed: token present but unparseable, OR no file argument.
#        Diagnostic prefix `plan-md-malformed:`.
#   34 — incomplete: H2 section missing, OR zero bullets in the section, OR
#        bullet lacks any `verified_by:` reference. Prefix `plan-md-incomplete:`.
#   35 — missing-file: the MD file does not exist. Prefix `plan-md-missing:`.
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
    # ENG-113 D-007: per-criterion validation lifted into bin/common.sh::
    # _validate_pass_criterion. M7 (review iter-2): the helper sets
    # $_VALIDATE_CRIT_DIAG on rc=34; caller wraps with its own
    # `<contract>-incomplete:` prefix.
    # The `--kinds smoke,file_exists,grep` gate keeps `http_get` (the new
    # qa-predicate kind) out of plan-schema's allowed set; `--shape nested`
    # is the default but is passed explicitly so the call-site documents
    # plan-schema's `features[$i].pass_criteria[$j]` jq path shape.
    local ci
    for (( ci=0; ci<pc_len; ci++ )); do
      _validate_pass_criterion "$file" "$fi" "$ci" \
        --kinds smoke,file_exists,grep \
        --shape nested \
        || { _emit_incomplete "$_VALIDATE_CRIT_DIAG"; return 34; }
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

# cmd_validate_md <file> — MD-side validator (ENG-157).
#
# Enforces the `## System invariants` H2 section contract on plan markdowns:
# the section must exist, contain ≥1 bullet, and every bullet must carry a
# parseable `verified_by:` token of the form `<path>:<test-name>` or
# `task:T<N>` somewhere in its body (first line OR any continuation line).
#
# Implementation: single-pass awk over the file. We track three states —
# outside any section, inside `## System invariants`, inside a different
# H2 section. A bullet starts at a top-level CommonMark marker line
# (`-`, `*`, or `+` followed by a space) and accumulates every following
# line until the next marker, the next `## ` heading, or EOF; the whole
# accumulated body is then scanned for the `verified_by:` token shape.
# This makes the validator robust to:
#   • any of the three CommonMark unordered-list markers (ENG-192:
#     planning agents emit `*` and `+`, not just `-`),
#   • line-wrapped bullets whose `verified_by:` token lands on a
#     continuation line (ENG-192: the common emission shape), and
#   • markdown emphasis runs around the label (ENG-203: planning
#     agents emit `**verified_by:** task:T2`, where the closing `**`
#     sits between the colon and the token). The separator between the
#     `verified_by:` label and the token tolerates `*`/`_`/backtick
#     emphasis characters in addition to whitespace.
# Nesting is still not modelled — an indented marker is treated as a
# continuation line of the enclosing top-level bullet, not a sub-bullet.
# Heading match is strictly the literal `## System invariants`
# (case-sensitive); typos route to rc=34 via the missing-section path.
# The validator does NOT parse code fences — a `verified_by:` token inside
# a backtick span still counts as a hit. This is acceptable per D-001 §8.3.
cmd_validate_md() {
  local file="${1:-}"
  if [[ -z "$file" ]]; then
    printf 'plan-md-malformed: file argument required\n'
    return 33
  fi
  if [[ ! -f "$file" ]]; then
    printf 'plan-md-missing: file not found: %s\n' "$file"
    return 35
  fi

  # Diagnostics + rc decided inside awk. Exit code surfaces via `awk_rc`
  # using BSD awk's `exit <n>` semantics; stdout carries human-readable
  # plan-md-{incomplete,malformed} lines (one per defect).
  local awk_out awk_rc=0
  awk_out="$(awk '
    BEGIN {
      in_section  = 0  # currently inside the "## System invariants" body
      saw_section = 0  # the heading was seen at least once
      bullet_count = 0
      malformed_count = 0
      incomplete_count = 0
      have_bullet = 0  # currently accumulating a top-level bullet
      buf = ""         # accumulated body (marker line + continuation lines)
    }
    # finalize_bullet: classify the accumulated bullet body, then reset.
    # Scans the WHOLE buffer (first line + continuation lines) so a
    # `verified_by:` token that wrapped onto a continuation line still
    # counts. `[[:space:]]*` spans the embedded newline between the
    # `verified_by:` label and a token on the next line.
    function finalize_bullet(   ) {
      if (!have_bullet) return
      bullet_count++
      # `<path>:<test-name>` shape: two non-space tokens separated by `:`.
      # `task:T<N>` shape: literal `task:T` + ≥1 digit. Either form anywhere
      # in the bullet body counts.
      if (match(buf, /verified_by:[[:space:]*_`]*([^[:space:]]+:[^[:space:]]+|task:T[0-9]+)/)) {
        # parseable token — bullet OK
      } else if (match(buf, /verified_by:/)) {
        # token present but neither shape matched
        printf "plan-md-malformed: bullet %d \"verified_by: <token>\" matches neither <path>:<test> nor task:T<N>\n", bullet_count
        malformed_count++
      } else {
        # no `verified_by:` reference anywhere in the bullet body
        printf "plan-md-incomplete: bullet %d (1-indexed) lacks parseable \"verified_by:\" reference\n", bullet_count
        incomplete_count++
      }
      have_bullet = 0
      buf = ""
    }
    # Section heading detection. Treats the literal "## System invariants"
    # (allowing trailing whitespace) as the target heading; any other "## "
    # line closes the section. Either boundary first finalizes an open bullet.
    /^## System invariants[[:space:]]*$/ {
      finalize_bullet()
      in_section  = 1
      saw_section = 1
      next
    }
    /^## / {
      finalize_bullet()
      in_section = 0
      next
    }
    # New top-level bullet within the section. CommonMark unordered-list
    # markers are `-`, `*`, `+` (column 0, followed by a space). Closes the
    # previous bullet before starting this one.
    in_section && /^[-*+] / {
      finalize_bullet()
      have_bullet = 1
      buf = $0
      next
    }
    # Continuation line of the open bullet: blank lines, indented text, and
    # wrapped `verified_by:` tokens all accumulate here until the next
    # marker / heading / EOF closes the bullet.
    in_section && have_bullet {
      buf = buf "\n" $0
      next
    }
    END {
      finalize_bullet()  # close the trailing bullet at EOF
      if (!saw_section) {
        print "plan-md-incomplete: required H2 section \"## System invariants\" missing"
        exit 34
      }
      if (bullet_count == 0) {
        print "plan-md-incomplete: \"## System invariants\" section has 0 bullets (expected >=1)"
        exit 34
      }
      if (malformed_count > 0) {
        # Malformed (token present but unparseable) takes precedence over
        # missing-token incomplete when both occur in the same file.
        exit 33
      }
      if (incomplete_count > 0) {
        exit 34
      }
      exit 0
    }
  ' "$file")" || awk_rc=$?

  if (( awk_rc != 0 )); then
    printf '%s\n' "$awk_out"
    return "$awk_rc"
  fi
  printf 'plan-md-contract-valid: %s\n' "$file"
  return 0
}

# cmd_prepare --body <body> --md <md> --ident <ENG-N>
# ENG-204: in-agent merge subcommand. Reads the content-only body sidecar
# at <body>, merges schema envelope {plan_schema_version: 1, issue_id: <ENG-N>}
# via merge_artifact_envelope, and atomically writes the canonical plan JSON
# at <${md%.md}.json> in the worktree. The agent then git add + git commit
# both the .md and the .json; _validate_plan_contract gates the merged
# canonical post-dispatch unchanged.
#
# Fences: --body must resolve under $PROJECT_STATE_DIR (not a symlink);
# --md must end in .md, must not be a symlink, and its realpath must resolve
# under cwd (prevents ../escape paths). The canonical destination is derived
# from the POST-realpath --md path so a future ln/mv attack on the argv
# literal cannot redirect the write.
cmd_prepare() {
  local ARG_BODY="" ARG_MD="" ARG_IDENT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --body)
        [[ $# -lt 2 ]] && { printf 'plan-schema.sh: --body requires a value\n' >&2; return 33; }
        ARG_BODY="$2"; shift 2 ;;
      --md)
        [[ $# -lt 2 ]] && { printf 'plan-schema.sh: --md requires a value\n' >&2; return 33; }
        ARG_MD="$2"; shift 2 ;;
      --ident)
        [[ $# -lt 2 ]] && { printf 'plan-schema.sh: --ident requires a value\n' >&2; return 33; }
        ARG_IDENT="$2"; shift 2 ;;
      --*) printf 'plan-schema.sh: unknown flag %s\n' "$1" >&2; return 33 ;;
      *)   printf 'plan-schema.sh: unexpected argument %s\n' "$1" >&2; return 33 ;;
    esac
  done

  # (a) All three required.
  if [[ -z "$ARG_BODY" || -z "$ARG_MD" || -z "$ARG_IDENT" ]]; then
    printf 'plan-schema.sh: prepare: --body, --md, and --ident are all required\n' >&2
    return 34
  fi

  # (b) --ident must match ^ENG-[0-9]+$.
  if ! [[ "$ARG_IDENT" =~ ^ENG-[0-9]+$ ]]; then
    printf 'plan-schema.sh: --ident must match ^ENG-[0-9]+$, got: %s\n' "$ARG_IDENT" >&2
    return 34
  fi

  # (c) --md must end in .md.
  if [[ "$ARG_MD" != *.md ]]; then
    printf 'plan-schema.sh: --md must end in .md, got: %s\n' "$ARG_MD" >&2
    return 33
  fi

  # (d) --body fence: not symlink; must exist; realpath must resolve under $PROJECT_STATE_DIR.
  if [[ -L "$ARG_BODY" ]]; then
    printf 'plan-contract-malformed: --body must not be a symlink: %s\n' "$ARG_BODY" >&2
    return 33
  fi
  if [[ ! -f "$ARG_BODY" ]]; then
    printf 'plan-contract-missing: --body file not found: %s\n' "$ARG_BODY"
    return 35
  fi
  local body_dir body_parent_real body_real psd_real
  body_dir="$(dirname "$ARG_BODY")"
  if ! body_parent_real="$(cd "$body_dir" 2>/dev/null && pwd -P)"; then
    printf 'plan-contract-malformed: cannot resolve realpath of --body parent: %s\n' "$body_dir" >&2
    return 33
  fi
  body_real="$body_parent_real/$(basename "$ARG_BODY")"
  psd_real="$(cd "$PROJECT_STATE_DIR" 2>/dev/null && pwd -P)" || {
    printf 'plan-contract-malformed: cannot resolve realpath of $PROJECT_STATE_DIR\n' >&2
    return 33
  }
  if [[ "$body_real" != "$psd_real"/* ]]; then
    printf 'plan-contract-malformed: --body must resolve under $PROJECT_STATE_DIR; got %s\n' "$body_real" >&2
    return 33
  fi

  # (e) --md fence: not symlink; parent dir must resolve; realpath must resolve under cwd.
  if [[ -L "$ARG_MD" ]]; then
    printf 'plan-contract-malformed: --md must not be a symlink: %s\n' "$ARG_MD" >&2
    return 33
  fi
  local md_dir md_parent_real md_real cwd_real
  md_dir="$(dirname "$ARG_MD")"
  if ! md_parent_real="$(cd "$md_dir" 2>/dev/null && pwd -P)"; then
    printf 'plan-contract-malformed: cannot resolve realpath of --md parent: %s\n' "$md_dir" >&2
    return 33
  fi
  md_real="$md_parent_real/$(basename "$ARG_MD")"
  cwd_real="$(pwd -P)"
  if [[ "$md_real" != "$cwd_real"/* ]]; then
    printf 'plan-contract-malformed: --md must resolve under cwd; got %s\n' "$md_real" >&2
    return 33
  fi

  # Derive canonical destination from post-realpath --md path.
  local canonical env_json merge_rc=0
  canonical="${md_real%.md}.json"
  env_json="$(jq -nc --arg ii "$ARG_IDENT" '{plan_schema_version: 1, issue_id: $ii}')"

  PIPELINE_ISSUE_ID="$ARG_IDENT" PIPELINE_STAGE=planning \
    merge_artifact_envelope "$ARG_BODY" "$env_json" "$canonical" \
    || merge_rc=$?

  case "$merge_rc" in
    0)  printf 'plan-contract-prepared: %s\n' "$canonical"; return 0 ;;
    41) return 35 ;;
    39|42|50) return 33 ;;
    *)  return 33 ;;
  esac
}

main() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    validate)    cmd_validate "$@" ;;
    validate-md) cmd_validate_md "$@" ;;
    prepare)     cmd_prepare "$@" ;;
    *)
      printf 'Usage: bash bin/plan-schema.sh {validate <file> [--ident <ENG-N>] | validate-md <file> | prepare --body <body> --md <md> --ident <ENG-N>}\n' >&2
      exit 33
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
