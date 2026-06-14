#!/usr/bin/env bash
# bin/review-ledger-schema.sh — review-findings-ledger schema-v1 validator CLI (ENG-190).
#
# Usage:
#   bash bin/review-ledger-schema.sh validate <file> [--ident <ENG-N>] \
#     [--dispatch-id <ENG-N-dNNNN>]
#
# Exit codes:
#   0  — valid: seed-header intact AND every JSONL row passes schema-v1
#   48 — malformed: any row fails JSON parse (whole file does not partial-validate)
#   49 — incomplete: any row missing a required field, wrong type, malformed
#        enum, ident/dispatch-id mismatch, severity-ladder violation, critical-
#        floor violation, OR seed-header tampered/missing
#   50 — missing-file: the ledger file does not exist at the given path
#
# Canonical schema-v1 row shape (per-line; one JSON object per non-`#` line):
#
# ```json
# {
#   "ledger_schema_version": 1,
#   "issue_id": "ENG-<NNN>",
#   "dispatch_id": "ENG-<NNN>-d<NNNN>",
#   "iteration": <int>=1>,
#   "created_at": "<ISO-8601 UTC>",
#   "finding_class_key": "<dimension>:<scope-anchor>:<concept-slug>",
#   "cold_severity": "critical|major|minor|nit",
#   "adjudicated_severity": "critical|major|minor|nit",
#   "decision": "carry|stabilise|defer-candidate|block",
#   "rationale": "<non-empty string; ≤280 char soft cap>"
# }
# ```
#
# Severity-ladder rule (critical=4>major=3>minor=2>nit=1):
#   adjudicated_severity is never strictly greater than cold_severity.
#
# Critical-floor rule (D-005a):
#   cold_severity == critical  ⇒  decision == block AND adjudicated_severity == critical.
#   No exceptions. The adjudicator may never downgrade a critical.
#
# ENG-191 extension — deferability fields (optional on row, mandatory when gate holds):
#   On every row whose adjudicated_severity ∈ {major, critical} AND
#   dispatch_id == --dispatch-id (this-dispatch row), the following three
#   fields are MANDATORY:
#     "blocks_ship": <boolean>,
#     "ship_classification_rationale": "<non-empty string naming the BLOCK
#         pattern or the DEFER rubric category that justifies the decision>",
#     "decision_factors": {
#       "in_changed_code":      <boolean>,
#       "is_regression":        <boolean>,
#       "user_visible":         <boolean>,
#       "reversible_post_ship": <boolean>,
#       "has_workaround":       <boolean>
#     }
#   Critical-floor-blocks-ship invariant (D-002): when the gate holds AND
#   adjudicated_severity == critical, blocks_ship MUST be true. The
#   validator halts with `critical-floor-blocks-ship-violation` rc=49 on
#   any critical this-dispatch row with blocks_ship != true.
#
#   Schema-grace clause: prior-dispatch rows (dispatch_id != --dispatch-id)
#   are EXEMPT from the three deferability requirements. Existing ledgers
#   written before ENG-191 landed continue to validate under the pre-ENG-191
#   closed contract; only this-dispatch rows enforce the new fields. The
#   gate also fails-open when --dispatch-id is unset (validator invoked
#   without dispatch context — e.g. operator triage).
#
# Seed-header integrity:
#   First two lines MUST byte-equal the canonical seed string emitted by
#   bin/run-stage.sh::_ensure_review_ledger.
#
# Sanitisation contract (MANDATORY before interpolating ANY agent-controlled
# string — rationale AND finding_class_key — into stdout diagnostics):
#   strip \n and \r to single-space; rewrite <!-- to <\!--.
#
# Diagnostic format (operator-visibility):
#   review-ledger-{malformed,incomplete,missing}: row N: <message>
#   When the row's finding_class_key is parseable (i.e. failure is a
#   downstream check like severity-ladder, critical-floor, or enum-out-
#   of-range — NOT a JSON parse error), the diagnostic additionally
#   appends ` finding_class_key=<sanitised>` so the operator triaging the
#   halt comment sees WHICH class tripped without opening the ledger.
#
# Deferred from v1 (per plan Task 2 / brainstorm D-009):
#   In-window cross-check of per-row created_at vs dispatch_history.jsonl
#   started_at is DEFERRED. Cross-reading dispatch_history.jsonl from
#   the validator breaks the sibling-validator pattern (every other
#   bin/*-schema.sh validates exactly one file in isolation). The
#   dispatch_id format check + --ident cross-check cover the bulk of
#   the staleness defense; in-window cross-check is incremental
#   defense-in-depth that can land in a follow-up if observed-needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Canonical seed-header (must byte-equal _ensure_review_ledger's output).
SEED_LINE_1='# review-findings-ledger — per-issue cumulative ledger; append one JSON object per line.'
SEED_LINE_2='# See docs/runbooks/review-findings-ledger.md. Never truncate; never cleared on dispatch.'

# Severity ladder.
_sev_rank() {
  case "$1" in
    critical) printf '4' ;;
    major)    printf '3' ;;
    minor)    printf '2' ;;
    nit)      printf '1' ;;
    *)        printf '0' ;;
  esac
}

# Sanitise an agent-controlled string before interpolation into stdout.
# Strips \n and \r to single space; rewrites <!-- to <\!-- so the halt-
# comment marker parser cannot be hijacked.
sanitise_for_diag() {
  local raw="$1"
  raw="${raw//$'\n'/ }"
  raw="${raw//$'\r'/ }"
  raw="${raw//<!--/<\\!--}"
  printf '%s' "$raw"
}

# Diagnostic emitters. Append ` finding_class_key=<sanitised>` when the
# caller passes a non-empty value (downstream checks only — NOT JSON parse).
_emit_malformed() {
  local row_no="$1" msg="$2" key="${3:-}"
  if [[ -n "$key" ]]; then
    printf 'review-ledger-malformed: row %s: %s finding_class_key=%s\n' \
      "$row_no" "$msg" "$(sanitise_for_diag "$key")"
  else
    printf 'review-ledger-malformed: row %s: %s\n' "$row_no" "$msg"
  fi
}

_emit_incomplete() {
  local row_no="$1" msg="$2" key="${3:-}"
  if [[ -n "$key" ]]; then
    printf 'review-ledger-incomplete: row %s: %s finding_class_key=%s\n' \
      "$row_no" "$msg" "$(sanitise_for_diag "$key")"
  else
    printf 'review-ledger-incomplete: row %s: %s\n' "$row_no" "$msg"
  fi
}

_warn_unknown() {
  log "[review-ledger-schema] warning: unknown $1: $2"
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
          printf 'review-ledger-schema.sh: --ident requires a value\n' >&2; return 48
        fi
        ident="$2"; shift 2 ;;
      --dispatch-id)
        if [[ $# -lt 2 ]]; then
          printf 'review-ledger-schema.sh: --dispatch-id requires a value\n' >&2; return 48
        fi
        dispatch_id_flag="$2"; dispatch_id_flag_set=1; shift 2 ;;
      --*)     printf 'review-ledger-schema.sh: unknown flag %s\n' "$1" >&2; return 48 ;;
      *)
        if (( first )); then file="$1"; first=0
        else printf 'review-ledger-schema.sh: unexpected argument %s\n' "$1" >&2; return 48
        fi
        shift
        ;;
    esac
  done

  [[ -n "$file" ]] || { printf 'review-ledger-schema.sh: validate: file argument required\n' >&2; return 48; }

  # rc=50: missing file.
  [[ -f "$file" ]] || { printf 'review-ledger-missing: file not found: %s\n' "$file"; return 50; }

  # ── Seed-header integrity (run BEFORE per-line loop) ──────────────────
  local hdr_line_1 hdr_line_2
  hdr_line_1="$(sed -n '1p' "$file" 2>/dev/null || true)"
  hdr_line_2="$(sed -n '2p' "$file" 2>/dev/null || true)"
  if [[ "$hdr_line_1" != "$SEED_LINE_1" || "$hdr_line_2" != "$SEED_LINE_2" ]]; then
    printf 'review-ledger-incomplete: seed-header tampered or missing\n'
    return 49
  fi

  # ── Per-row validation loop ───────────────────────────────────────────
  local line_no=0 saw_row=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no+1))
    # Skip empty / whitespace-only lines.
    [[ -z "${line// /}" && -z "${line//	/}" ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    # Skip comment lines (^#).
    [[ "${line:0:1}" == "#" ]] && continue
    saw_row=1

    # rc=48: JSON parse error.
    local parsed_type=""
    if ! parsed_type="$(jq -r 'type' <<<"$line" 2>/dev/null)"; then
      _emit_malformed "$line_no" "JSON parse error"
      return 48
    fi
    if [[ "$parsed_type" != "object" ]]; then
      _emit_malformed "$line_no" "row is not a JSON object (got: $parsed_type)"
      return 48
    fi

    # Once the row is a parseable object, attempt to extract finding_class_key
    # for diagnostic interpolation. May be empty / missing — that itself is
    # a downstream incomplete error which will fire below; we only use the
    # value here for diagnostic enrichment when other checks fail.
    local fck=""
    fck="$(jq -r '.finding_class_key // ""' <<<"$line" 2>/dev/null || printf '')"

    # ledger_schema_version == 1 (integer)
    if ! jq -e '.ledger_schema_version == 1' <<<"$line" >/dev/null 2>&1; then
      local ver_val
      ver_val="$(jq -r '.ledger_schema_version // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
      _emit_incomplete "$line_no" "ledger_schema_version must be 1, got: $ver_val" "$fck"
      return 49
    fi

    # issue_id matches ^ENG-[0-9]+$ AND equals --ident when provided.
    local iid_type iid_val
    iid_type="$(jq -r '.issue_id | type' <<<"$line" 2>/dev/null || printf 'missing')"
    iid_val="$(jq -r '.issue_id // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
    if [[ "$iid_val" == "MISSING" || "$iid_type" != "string" ]]; then
      _emit_incomplete "$line_no" "issue_id must be a non-empty string (e.g. ENG-1), got type=$iid_type" "$fck"
      return 49
    fi
    if ! [[ "$iid_val" =~ ^ENG-[0-9]+$ ]]; then
      _emit_incomplete "$line_no" "issue_id must match ^ENG-[0-9]+\$, got: $iid_val" "$fck"
      return 49
    fi
    if [[ -n "$ident" && "$iid_val" != "$ident" ]]; then
      _emit_incomplete "$line_no" "issue_id mismatch: row has '$iid_val' but --ident '$ident' was passed (stale fixture?)" "$fck"
      return 49
    fi

    # dispatch_id matches ^ENG-[0-9]+-d[0-9]+$.
    local did_type did_val
    did_type="$(jq -r '.dispatch_id | type' <<<"$line" 2>/dev/null || printf 'missing')"
    did_val="$(jq -r '.dispatch_id // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
    if [[ "$did_val" == "MISSING" || "$did_type" != "string" ]]; then
      _emit_incomplete "$line_no" "dispatch_id must be a non-empty string, got type=$did_type" "$fck"
      return 49
    fi
    if ! [[ "$did_val" =~ ^ENG-[0-9]+-d[0-9]+$ ]]; then
      _emit_incomplete "$line_no" "dispatch_id must match ^ENG-[0-9]+-d[0-9]+\$, got: $did_val" "$fck"
      return 49
    fi
    # Fail-open when --dispatch-id flag is absent OR empty (mirror ENG-119 D-006).
    # Cross-check: when --dispatch-id is non-empty, AT LEAST one row should
    # carry it (validator should not fail on prior-dispatch rows in the same
    # ledger — those are the EXPECTED carry-forward shape). Per-row mismatch
    # is therefore NOT a hard error; rely on dispatch_id format check above.

    # iteration: integer >= 1.
    # ENG-191 fix: precedence parens around `(.iteration | floor) == .iteration`.
    # `|` binds looser than `==` in jq, so the prior shape
    # `.iteration | floor == .iteration` parsed as
    # `.iteration | (floor == .iteration)` — inside the pipe `.iteration`
    # dereferences the iteration *value* (a number), yielding null and a
    # false comparison. Result: every valid integer iteration tripped the
    # check. This was the root cause of T-191-1 / T-191-2 / T1 / T2 / T6 /
    # T7 / T9 / T11 failing pre-ENG-191; T-191-* is the QA-loopback carve-
    # out path for the fix (test exposes a real validator bug).
    # (Same one-line fix shipped independently on main as PR #167 / a240c30
    # to unblock the validator before this branch merged; identical predicate.)
    if ! jq -e '(.iteration | type) == "number" and ((.iteration | floor) == .iteration) and .iteration >= 1' <<<"$line" >/dev/null 2>&1; then
      local iter_val
      iter_val="$(jq -r '.iteration // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
      _emit_incomplete "$line_no" "iteration must be integer >= 1, got: $iter_val" "$fck"
      return 49
    fi

    # created_at: non-empty string.
    local ca_type ca_val
    ca_type="$(jq -r '.created_at | type' <<<"$line" 2>/dev/null || printf 'missing')"
    ca_val="$(jq -r '.created_at // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
    if [[ "$ca_val" == "MISSING" || "$ca_type" != "string" || -z "$ca_val" ]]; then
      _emit_incomplete "$line_no" "created_at must be a non-empty string, got type=$ca_type" "$fck"
      return 49
    fi

    # finding_class_key: non-empty string.
    local fck_type
    fck_type="$(jq -r '.finding_class_key | type' <<<"$line" 2>/dev/null || printf 'missing')"
    if [[ "$fck_type" != "string" || -z "$fck" ]]; then
      _emit_incomplete "$line_no" "finding_class_key must be a non-empty string, got type=$fck_type" ""
      return 49
    fi

    # cold_severity in {critical, major, minor, nit}.
    local cs_val
    cs_val="$(jq -r '.cold_severity // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
    case "$cs_val" in
      critical|major|minor|nit) ;;
      *) _emit_incomplete "$line_no" "cold_severity must be in {critical, major, minor, nit}, got: $cs_val" "$fck"; return 49 ;;
    esac

    # adjudicated_severity in {critical, major, minor, nit}.
    local as_val
    as_val="$(jq -r '.adjudicated_severity // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
    case "$as_val" in
      critical|major|minor|nit) ;;
      *) _emit_incomplete "$line_no" "adjudicated_severity must be in {critical, major, minor, nit}, got: $as_val" "$fck"; return 49 ;;
    esac

    # decision in {carry, stabilise, defer-candidate, block}.
    local dec_val
    dec_val="$(jq -r '.decision // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
    case "$dec_val" in
      carry|stabilise|defer-candidate|block) ;;
      *) _emit_incomplete "$line_no" "decision must be in {carry, stabilise, defer-candidate, block}, got: $dec_val" "$fck"; return 49 ;;
    esac

    # rationale: non-empty string.
    local rat_type rat_val
    rat_type="$(jq -r '.rationale | type' <<<"$line" 2>/dev/null || printf 'missing')"
    rat_val="$(jq -r '.rationale // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
    if [[ "$rat_val" == "MISSING" || "$rat_type" != "string" || -z "$rat_val" ]]; then
      _emit_incomplete "$line_no" "rationale must be a non-empty string, got type=$rat_type" "$fck"
      return 49
    fi

    # Severity-ladder: adjudicated_severity NOT strictly greater than cold_severity.
    local cs_rank as_rank
    cs_rank="$(_sev_rank "$cs_val")"
    as_rank="$(_sev_rank "$as_val")"
    if (( as_rank > cs_rank )); then
      _emit_incomplete "$line_no" "severity-ladder violation: adjudicated=$as_val > cold=$cs_val" "$fck"
      return 49
    fi

    # Critical-floor: cold_severity == critical ⇒ decision == block AND adjudicated == critical.
    if [[ "$cs_val" == "critical" ]]; then
      if [[ "$dec_val" != "block" || "$as_val" != "critical" ]]; then
        _emit_incomplete "$line_no" "critical-floor violation: cold=critical but decision=$dec_val adjudicated=$as_val" "$fck"
        return 49
      fi
    fi

    # ENG-191: deferability checks — gated on adjudicated_severity ∈ {major, critical}
    # AND this-dispatch row (dispatch_id == --dispatch-id). Schema-grace clause
    # exempts prior-dispatch rows from the new contract; absent --dispatch-id
    # flag fails open (validator without dispatch context).
    if [[ "$as_val" == "major" || "$as_val" == "critical" ]] \
       && [[ -n "$dispatch_id_flag" && "$did_val" == "$dispatch_id_flag" ]]; then
      # (a) blocks_ship: boolean presence.
      local bs_type bs_val
      bs_type="$(jq -r '.blocks_ship | type' <<<"$line" 2>/dev/null || printf 'missing')"
      bs_val="$(jq -r '.blocks_ship // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
      if [[ "$bs_type" != "boolean" ]]; then
        _emit_incomplete "$line_no" "blocks_ship-missing-on-blocking-severity: adjudicated=$as_val but blocks_ship type=$(sanitise_for_diag "$bs_type")" "$fck"
        return 49
      fi
      # (b) Critical-floor-blocks-ship: as=critical ⇒ blocks_ship=true.
      if [[ "$as_val" == "critical" && "$bs_val" != "true" ]]; then
        _emit_incomplete "$line_no" "critical-floor-blocks-ship-violation: adjudicated=critical but blocks_ship=$(sanitise_for_diag "$bs_val")" "$fck"
        return 49
      fi
      # (c) ship_classification_rationale: non-empty string.
      local scr_type scr_val
      scr_type="$(jq -r '.ship_classification_rationale | type' <<<"$line" 2>/dev/null || printf 'missing')"
      scr_val="$(jq -r '.ship_classification_rationale // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
      if [[ "$scr_val" == "MISSING" || "$scr_type" != "string" || -z "$scr_val" ]]; then
        _emit_incomplete "$line_no" "ship_classification_rationale must be a non-empty string, got type=$(sanitise_for_diag "$scr_type")" "$fck"
        return 49
      fi
      # (d) decision_factors: object with all five required boolean keys.
      local df_type
      df_type="$(jq -r '.decision_factors | type' <<<"$line" 2>/dev/null || printf 'missing')"
      if [[ "$df_type" != "object" ]]; then
        _emit_incomplete "$line_no" "decision_factors must be object, got type=$(sanitise_for_diag "$df_type")" "$fck"
        return 49
      fi
      local missing_keys
      missing_keys="$(jq -r '
        ["in_changed_code","is_regression","user_visible","reversible_post_ship","has_workaround"] as $req
        | ($req - (.decision_factors | keys))
        | join(",")' <<<"$line" 2>/dev/null || printf '')"
      if [[ -n "$missing_keys" ]]; then
        _emit_incomplete "$line_no" "decision_factors missing required keys: $(sanitise_for_diag "$missing_keys")" "$fck"
        return 49
      fi
      local wrong_type_keys
      wrong_type_keys="$(jq -r '
        [.decision_factors | to_entries[] | select(.value | type != "boolean") | .key]
        | join(",")' <<<"$line" 2>/dev/null || printf '')"
      if [[ -n "$wrong_type_keys" ]]; then
        _emit_incomplete "$line_no" "decision_factors keys must be boolean; non-boolean: $(sanitise_for_diag "$wrong_type_keys")" "$fck"
        return 49
      fi
    fi

    # Unknown fields: stderr warning, exit 0 path.
    local unknown_keys
    unknown_keys="$(jq -r \
      '(keys) - ["ledger_schema_version","issue_id","dispatch_id","iteration","created_at","finding_class_key","cold_severity","adjudicated_severity","decision","rationale","blocks_ship","ship_classification_rationale","decision_factors"] | .[]' \
      <<<"$line" 2>/dev/null || true)"
    while IFS= read -r uf; do
      if [[ -n "$uf" ]]; then _warn_unknown "field (row $line_no)" "$uf"; fi
    done <<< "$unknown_keys"
  done < "$file"

  if (( saw_row == 0 )); then
    printf 'review-ledger-valid: %s (0 rows after header strip)\n' "$file"
    return 0
  fi

  printf 'review-ledger-valid: %s\n' "$file"
  return 0
}

main() {
  local subcmd="${1:-}"
  shift || true
  case "$subcmd" in
    validate) cmd_validate "$@" ;;
    *)
      printf 'Usage: bash bin/review-ledger-schema.sh validate <file> [--ident <ENG-N>] [--dispatch-id <ENG-N-dNNNN>]\n' >&2
      exit 48
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
