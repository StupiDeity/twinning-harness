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
# The trap is registered inside cmd_validate (not at source-time) so a
# caller sourcing this script for unit tests does not inherit our EXIT
# handler.
_VERIFY_QA_SNAP_FILE=""
_verify_qa_cleanup_snap() {
  [[ -n "${_VERIFY_QA_SNAP_FILE:-}" ]] && rm -f "$_VERIFY_QA_SNAP_FILE"
  _VERIFY_QA_SNAP_FILE=""
}

# ─── Phase 1: parse argv ──────────────────────────────────────────────
# Returns 0 with parsed values in ARG_FILE/ARG_IDENT/ARG_WORKTREE
# globals; emits diagnostics + returns 42 (malformed) on argv shape errors.
_parse_validate_argv() {
  ARG_FILE=""; ARG_IDENT=""; ARG_WORKTREE=""; ARG_BODY=""
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
      --body)
        if [[ $# -lt 2 ]]; then
          printf 'verify-qa.sh: --body requires a value\n' >&2; return 42
        fi
        if [[ "$2" == --* ]]; then
          printf 'verify-qa.sh: --body requires a non-flag value, got: %s\n' "$2" >&2; return 42
        fi
        ARG_BODY="$2"; shift 2 ;;
      --*)     printf 'verify-qa.sh: unknown flag %s\n' "$1" >&2; return 42 ;;
      *)
        if (( first )); then ARG_FILE="$1"; first=0
        else printf 'verify-qa.sh: unexpected argument %s\n' "$1" >&2; return 42
        fi
        shift
        ;;
    esac
  done
  # ENG-203: --body substitutes for the canonical file argument. The
  # caller writes a content-only body sidecar; cmd_validate's body-merge
  # phase fences the realpath, calls merge_artifact_envelope to splice
  # the schema envelope onto the body, and rewrites ARG_FILE to point at
  # the canonical for the unchanged downstream phases. Defer the
  # `ARG_FILE` requirement when --body is present.
  if [[ -z "$ARG_FILE" && -z "$ARG_BODY" ]]; then
    printf 'verify-qa.sh: validate: file argument required (or --body)\n' >&2; return 42
  fi
  # ENG-203 review M1: --body and a positional ARG_FILE are mutually
  # exclusive. The body-merge phase below would silently clobber the
  # caller's positional with the canonical computed from --ident; reject
  # at the CLI boundary so a future caller cannot misroute.
  if [[ -n "$ARG_FILE" && -n "$ARG_BODY" ]]; then
    printf 'verify-qa.sh: validate: --body and positional file argument are mutually exclusive\n' >&2
    return 42
  fi
  return 0
}

# ─── Phase 2: authority surface (D-011) ──────────────────────────────
# Predicate file must (a) exist (rc=44), (b) not be a symlink (rc=42),
# (c) live under $PROJECT_STATE_DIR realpath (rc=42). The size cap is
# enforced post-snapshot in cmd_validate (the size check on the original
# bytes would open a TOCTOU window — the snapshot is the canonical
# source).
# Splits the parent-realpath assignment so a failed cd properly trips
# the `if !` — the inlined `if ! file_real="$(cd … && pwd -P)/$(basename …)"`
# shape rolls the last-command exit into basename (always 0) and the
# cd error is silently swallowed.
_authority_check() {
  local file="$1"
  # Reject symlinks at the predicate path. `_authority_check` canonicalises
  # the PARENT but suffixes the basename verbatim — a symlink `predicate.json
  # -> /etc/shadow` would otherwise pass the parent-prefix check and the
  # downstream snapshot read would follow it. The QA agent emits the
  # predicate via `Write` (no symlink creation surface); a symlink at this
  # path is never legitimate.
  # Diagnostics route to stderr — the file-header contract is "JSONL on
  # stdout"; mixing prose diagnostics into the JSONL stream breaks
  # downstream `jq -c 'select(.summary == true)'` consumers.
  if [[ -L "$file" ]]; then
    printf 'qa-predicate-malformed: predicate file must not be a symlink: %s\n' "$file" >&2
    return 42
  fi
  if [[ ! -f "$file" ]]; then
    printf 'qa-predicate-missing: file not found: %s\n' "$file" >&2
    return 44
  fi
  local dir parent_real
  dir="$(dirname "$file")"
  if ! parent_real="$(cd "$dir" 2>/dev/null && pwd -P)"; then
    printf 'qa-predicate-malformed: cannot resolve realpath of predicate file parent: %s\n' "$dir" >&2
    return 42
  fi
  local file_real="$parent_real/$(basename "$file")"
  local prefix_real
  prefix_real="$(cd "$PROJECT_STATE_DIR" && pwd -P)"
  if [[ "$file_real" != "$prefix_real"/* ]]; then
    printf 'qa-predicate-malformed: predicate file must live under $PROJECT_STATE_DIR; got %s\n' "$file" >&2
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
# AGENT_PROMPTS.md §6 invokes (no --worktree flag). The auto-derive
# path runs through the SAME fence as the explicit-flag path so a
# symlink at $(issue_dir <ident>)/worktree → /etc cannot pivot
# file_exists/grep authority outside the trust anchor (D-011).
# Returns 0 with RESOLVED_WORKTREE populated, 43 on fence violation.
_assert_worktree_fenced() {
  local wt_real="$1"
  # common.sh::require_env enforces TARGET_REPO; PROJECT_STATE_DIR is
  # always derived. Trust both are set + readable here.
  local target_real state_real
  target_real="$(cd "$TARGET_REPO" && pwd -P)"
  state_real="$(cd "$PROJECT_STATE_DIR" && pwd -P)"
  if [[ "$wt_real" == "$target_real" || "$wt_real" == "$target_real"/* ]]; then
    return 0
  fi
  if [[ "$wt_real" == "$state_real" || "$wt_real" == "$state_real"/* ]]; then
    return 0
  fi
  printf 'qa-predicate-incomplete: --worktree must be a subpath of $TARGET_REPO or $PROJECT_STATE_DIR (got %s)\n' "$wt_real" >&2
  return 43
}

_worktree_fence() {
  local worktree="$1"
  RESOLVED_WORKTREE=""
  if [[ -z "$worktree" ]]; then
    # Auto-derive: PIPELINE_ISSUE_ID points at the per-issue worktree.
    local derived=""
    if [[ -n "${PIPELINE_ISSUE_ID:-}" ]]; then
      local issue_wt="$(issue_dir "$PIPELINE_ISSUE_ID")/worktree"
      if [[ -d "$issue_wt" ]]; then
        derived="$(cd "$issue_wt" && pwd -P)"
      fi
    fi
    if [[ -z "$derived" && -n "${TARGET_REPO:-}" && -d "${TARGET_REPO:-}" ]]; then
      derived="$(cd "$TARGET_REPO" && pwd -P)"
    fi
    if [[ -z "$derived" ]]; then
      die "verify-qa.sh: cannot derive worktree (no --worktree, no PIPELINE_ISSUE_ID worktree, no TARGET_REPO directory)"
    fi
    # The auto-derive path runs through the same fence as the
    # explicit-flag path — a symlink at $(issue_dir <ident>)/worktree
    # would otherwise pivot RESOLVED_WORKTREE outside the trust anchor.
    _assert_worktree_fenced "$derived" || return $?
    RESOLVED_WORKTREE="$derived"
    return 0
  fi
  if [[ ! -d "$worktree" ]]; then
    printf 'qa-predicate-incomplete: --worktree must be an existing directory, got: %s\n' "$worktree" >&2
    return 43
  fi
  local wt_real
  wt_real="$(cd "$worktree" && pwd -P)"
  _assert_worktree_fenced "$wt_real" || return $?
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
    printf 'qa-predicate-malformed: JSON parse error: %s\n' "$jq_type_out" >&2
    return 42
  fi
  if [[ "$jq_type_out" != "object" ]]; then
    printf 'qa-predicate-malformed: top-level JSON is not an object (got: %s)\n' "$jq_type_out" >&2
    return 42
  fi

  # ── Required top-level fields ──────────────────────────────────────
  local ver
  ver="$(jq -r '.qa_predicate_schema_version // "MISSING"' "$file")"
  if [[ "$ver" == "MISSING" ]]; then
    printf 'qa-predicate-incomplete: missing required field: qa_predicate_schema_version\n' >&2
    return 43
  fi
  if ! jq -e '.qa_predicate_schema_version | type == "number"' "$file" >/dev/null 2>&1; then
    printf 'qa-predicate-incomplete: qa_predicate_schema_version must be an integer, got: %s\n' "$ver" >&2
    return 43
  fi
  if ! jq -e '.qa_predicate_schema_version == 1' "$file" >/dev/null 2>&1; then
    printf 'qa-predicate-incomplete: qa_predicate_schema_version must be 1, got: %s\n' "$ver" >&2
    return 43
  fi

  local issue_id_type issue_id_val
  issue_id_type="$(jq -r '.issue_id | type' "$file" 2>/dev/null || printf 'missing')"
  issue_id_val="$(jq -r '.issue_id // "MISSING"' "$file")"
  if [[ "$issue_id_val" == "MISSING" || "$issue_id_type" != "string" ]]; then
    printf 'qa-predicate-incomplete: issue_id must be a non-empty string (e.g. ENG-1), got type=%s\n' "$issue_id_type" >&2
    return 43
  fi
  if ! [[ "$issue_id_val" =~ ^ENG-[0-9]+$ ]]; then
    printf 'qa-predicate-incomplete: issue_id must match ^ENG-[0-9]+\$, got: %s\n' "$issue_id_val" >&2
    return 43
  fi
  if [[ -n "$ident" && "$issue_id_val" != "$ident" ]]; then
    printf 'qa-predicate-incomplete: issue_id mismatch: JSON has '\''%s'\'' but --ident '\''%s'\'' was passed (stale template?)\n' "$issue_id_val" "$ident" >&2
    return 43
  fi

  # pass_criteria must be an array with len >= 1.
  local pc_type pc_len
  pc_type="$(jq -r '.pass_criteria | type' "$file" 2>/dev/null || printf 'missing')"
  pc_len="$(jq -r '.pass_criteria | length' "$file" 2>/dev/null || printf '0')"
  if [[ "$pc_type" != "array" ]]; then
    printf 'qa-predicate-incomplete: pass_criteria must be an array, got type=%s\n' "$pc_type" >&2
    return 43
  fi
  if (( pc_len == 0 )); then
    printf 'qa-predicate-incomplete: pass_criteria must contain at least 1 entry\n' >&2
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
      printf 'qa-predicate-incomplete: %s\n' "$_VALIDATE_CRIT_DIAG" >&2
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
  # --proto / --proto-redir lock curl to http/https for the initial
  # request AND any redirects — closes a file:// / scp:// escape via
  # a 30x Location header even though the validator already gated the
  # initial scheme. Defense in depth, not a duplicate check.
  # `-L` is intentionally NOT set today: redirects are NOT followed, so
  # --proto-redir is preventive-only. A future change that adds `-L`
  # would also need `--max-redirs <N>` (bounded redirect chain) AND a
  # re-application of `_url_host_class_denied` on the final URL — the
  # initial-URL host-class check is bypassed by a 30x to a denylisted
  # host otherwise.
  # --max-filesize 1048576 (1 MiB) caps the body byte count so a
  # legitimate-or-attacker URL streaming hundreds of MB over LAN within
  # the --max-time 10s wall-clock window cannot exhaust disk before the
  # rm cleans body_tmp. Same DoS-byte-cap intent as the predicate-file
  # 64 KiB cap (D-011); expect_body_match grep still works on a
  # truncated body. 1 MiB is well above any reasonable response-body
  # signal the predicate would inspect via grep -E.
  code="$(curl -sS --proto '=http,https' --proto-redir '=http,https' --max-filesize 1048576 -o "$body_tmp" -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)" || curl_rc=$?
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
  # Residual TOCTOU window: between body_tmp's mktemp and the grep
  # open() below, a sibling smoke criterion that runs in parallel could
  # `ln -sfn /etc/passwd "$body_tmp"`. Bounded by (a) `body_tmp` lives
  # under `mktemp -t` (private to the current process's TMPDIR slot),
  # (b) smoke is already arbitrary code execution in the worktree by
  # design (D-002), so a smoke able to symlink-race body_tmp could
  # already read /etc/passwd directly. Not a privilege escalation
  # surface under the current threat model.
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
  # Register the snap-cleanup trap here (not at source-time) so unit
  # tests that source this script do not inherit our EXIT handler.
  trap '_verify_qa_cleanup_snap' EXIT
  _parse_validate_argv "$@" || return $?
  # ─── ENG-203: --body in-dispatch merge phase ───────────────────────
  # When --body is set, the caller wrote a content-only predicate body
  # (no envelope keys). Fence its realpath against $PROJECT_STATE_DIR
  # (mirrors the canonical $ARG_FILE fence), build the schema envelope
  # `{qa_predicate_schema_version, issue_id}`, call merge_artifact_envelope
  # to atomically write the merged canonical at qa_predicate_path(ident),
  # and remap helper rcs (39→42, 41→44, 42→42, 50→42) into the verify-qa
  # taxonomy so downstream callers see a single qa-predicate-* surface.
  # On success, overwrite ARG_FILE to point at the canonical so phases
  # 2-5 (authority check, worktree fence, snapshot, schema validate,
  # execute) run unchanged on the merged file.
  if [[ -n "$ARG_BODY" ]]; then
    if [[ -L "$ARG_BODY" ]]; then
      printf 'qa-predicate-malformed: --body must not be a symlink: %s\n' "$ARG_BODY" >&2
      return 42
    fi
    if [[ ! -f "$ARG_BODY" ]]; then
      printf 'qa-predicate-missing: --body file not found: %s\n' "$ARG_BODY" >&2
      return 44
    fi
    local body_dir body_parent_real body_real
    body_dir="$(dirname "$ARG_BODY")"
    if ! body_parent_real="$(cd "$body_dir" 2>/dev/null && pwd -P)"; then
      printf 'qa-predicate-malformed: cannot resolve realpath of --body parent: %s\n' "$body_dir" >&2
      return 42
    fi
    body_real="$body_parent_real/$(basename "$ARG_BODY")"
    local prefix_real
    prefix_real="$(cd "$PROJECT_STATE_DIR" && pwd -P)"
    if [[ "$body_real" != "$prefix_real"/* ]]; then
      printf 'qa-predicate-malformed: --body must resolve under $PROJECT_STATE_DIR; got %s\n' "$body_real" >&2
      return 42
    fi
    if [[ -z "$ARG_IDENT" ]]; then
      printf 'qa-predicate-incomplete: --body requires --ident <ENG-N>\n' >&2
      return 43
    fi
    local canonical env_json merge_rc=0
    canonical="$(qa_predicate_path "$ARG_IDENT")"
    env_json="$(jq -nc --arg ii "$ARG_IDENT" \
      '{qa_predicate_schema_version: 1, issue_id: $ii}')"
    PIPELINE_ISSUE_ID="$ARG_IDENT" PIPELINE_STAGE=qa \
      merge_artifact_envelope "$ARG_BODY" "$env_json" "$canonical" \
      || merge_rc=$?
    case "$merge_rc" in
      0)  ARG_FILE="$canonical" ;;
      39) return 42 ;;
      41) return 44 ;;
      42) return 42 ;;
      50) return 42 ;;
      *)  return 42 ;;
    esac
  fi
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
    printf 'qa-predicate-malformed: cannot create snapshot dir under $PROJECT_STATE_DIR: %s\n' "$snap_dir" >&2
    return 42
  }
  # `mkdir -p` succeeds if snap_dir is a pre-existing symlink to e.g. /etc;
  # the subsequent mktemp would then write outside $PROJECT_STATE_DIR.
  if [[ -L "$snap_dir" ]]; then
    printf 'qa-predicate-malformed: snapshot dir is a symlink: %s\n' "$snap_dir" >&2
    return 42
  fi
  snap_file="$(mktemp "$snap_dir/predicate.XXXXXX" 2>/dev/null)"
  if [[ -z "$snap_file" ]]; then
    printf 'qa-predicate-malformed: mktemp failed under %s\n' "$snap_dir" >&2
    return 42
  fi
  _VERIFY_QA_SNAP_FILE="$snap_file"
  # Close the symlink-TOCTOU window between _authority_check's `-L`
  # reject and the snapshot read: re-check immediately before opening
  # the file. A swap to a symlink between the two checks would otherwise
  # let the head/redirect follow it.
  #
  # Residual race: a few CPU cycles still elapse between this `-L` test
  # and the `head -c < "$ARG_FILE"` open() below. An attacker who wins
  # that window reads attacker-chosen bytes into snap_file — but those
  # bytes must still pass schema validation (`_validate_predicate_schema`
  # on snap_file enforces JSON object + qa_predicate_schema_version=1 +
  # issue_id + array-shape pass_criteria), so the worst case is reading
  # an attacker-chosen-but-schema-valid predicate. Not exploitable as a
  # confused-deputy escalation; doc gap only.
  if [[ -L "$ARG_FILE" ]]; then
    rm -f "$snap_file"
    _VERIFY_QA_SNAP_FILE=""
    printf 'qa-predicate-malformed: predicate file became a symlink (TOCTOU): %s\n' "$ARG_FILE" >&2
    return 42
  fi
  # head -c bounds the snapshot read to MAX+1 bytes — even a
  # 1-petabyte ARG_FILE produces at most MAX+1 bytes on disk. The
  # post-snapshot wc -c then enforces the byte cap against snap_file
  # (the canonical source) rather than ARG_FILE (TOCTOU-vulnerable).
  if ! head -c $((_QA_PREDICATE_MAX_BYTES + 1)) < "$ARG_FILE" > "$snap_file" 2>/dev/null; then
    rm -f "$snap_file"
    _VERIFY_QA_SNAP_FILE=""
    printf 'qa-predicate-malformed: failed to snapshot predicate to %s\n' "$snap_file" >&2
    return 42
  fi
  local snap_size
  snap_size="$(wc -c < "$snap_file" 2>/dev/null | tr -d ' ')"
  if [[ -z "$snap_size" ]] || (( snap_size > _QA_PREDICATE_MAX_BYTES )); then
    rm -f "$snap_file"
    _VERIFY_QA_SNAP_FILE=""
    printf 'qa-predicate-malformed: predicate file size %s exceeds cap %s bytes\n' \
      "${snap_size:-unknown}" "$_QA_PREDICATE_MAX_BYTES" >&2
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
