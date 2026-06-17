#!/usr/bin/env bash
# Verify the implement/ui agent's diff against the plan's File Structure section.
# Usage:
#   scope-check.sh <issue_id> <branch>              — run the scope check
#   scope-check.sh has-scope-approval <issue_id>    — exit 0 iff the issue has a
#       <!-- pipeline: decision action=approve gate=scope --> comment newer than
#       its most recent <!-- pipeline: verdict result=halt reason=scope-violation -->
#       comment (ENG-18 / ENG-60).
# Exit 0: all changed files are in plan scope (or only benign escapes).
# Exit 1: one or more files out of plan scope at the NOTABLE tier (list printed to stdout).
# Exit 2: plan not found, or File Structure unparseable.
# Exit 3: one or more files out of plan scope at the SEVERE tier (list printed to stdout).
#
# Tiers (applied to files NOT matching the plan's allowed files/dirs):
#   - BENIGN (silently allowed, counted toward exit 0):
#       * `.scratch/**`                 — sanctioned agent scratch namespace
#                                         (gitignored; sweep-invisible on
#                                         implementing|ui|qa; tick-end auto-
#                                         clean on reviewing|building|released)
#       * `.pipeline/metrics/**`        — orchestrator-owned telemetry
#       * `docs/knowledge/**`           — learned-rules / knowledge-doc updates
#       * `docs/plans/**`               — plan docs (cannot self-reference pre-creation)
#       * `docs/brainstorms/**`         — brainstorm docs (authored before the plan)
#       * `<profile-derived lockfile>`  — lockfile churn from in-scope dep edits;
#                                         basenames inferred per dispatch from
#                                         learned-rules/<slug>/project-profile.md's
#                                         `## Build & test gates` section (ENG-96).
#                                         E.g. `cargo` token → `Cargo.lock`;
#                                         `poetry` token → `poetry.lock`; etc.
#       * `crates/<name>/tests/**`      — integration tests under an in-scope crate
#                                         (Rust-specific; not yet generalised)
#   - NOTABLE: top-level path segment (e.g. `crates`, `src-tauri`, `src`) matches
#     the top segment of SOME allowed path. "Adjacent to declared scope."
#   - SEVERE: file is unrelated to any declared scope.
#
# Output on stdout (when tiers fire): one line per file, prefixed by `<tier>\t`.
#
# Parsing rule (best-effort, tolerant):
#   - Locate the plan doc canonically by `linear: <ID>` frontmatter.
#   - Extract the body between the first `## File Structure` (or `### File Structure`)
#     heading and the next heading of the same-or-shallower depth.
#   - Collect (a) file-path tokens (contain `/` + a `.<ext>`) and (b) directory-prefix
#     tokens (ending in `/`). Both are normalised to repo-relative paths.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ENG-41 T3: scope-check lane — all Linear writes from this script are in
# the scope-check lane, which is allowed to add/remove pipeline:skip-until-*
# labels but not stage:* or pipeline:halted labels.
export PIPELINE_WRITER=scope-check

# ENG-194: shared plan-structural matcher (5 plan_scope::* functions).
# scope-check.sh and bin/render-prompt.sh's plan_scope_allowed_paths
# resolver both source this so the reviewer-defer / scope-check-halt
# split cannot diverge on identical input.
# shellcheck source=plan-scope.sh
source "$SCRIPT_DIR/plan-scope.sh"

# ENG-96: benign-path classes are the four harness-owned globs that are
# always benign regardless of stack (orchestrator owns these paths:
# docs/{knowledge,plans,brainstorms}/, .pipeline/metrics/). Compare to
# the lockfile array below, which is profile-derived and stack-conditional.
_BENIGN_PATH_CLASSES=(
  '.pipeline/metrics/*'
  'docs/knowledge/*'
  'docs/plans/*'
  'docs/brainstorms/*'
  'docs/pipeline-vocabulary.md'
)

# ENG-96: profile-derived lockfile basenames, populated once per main()
# invocation by _profile_lockfile_basenames. Empty when no profile or no
# recognised PM token (D-005 fallback). is_benign reads via dynamic scope.
# TEST-AUTHOR CONTRACT: tests that source scope-check.sh and call
# is_benign directly MUST populate this array themselves; the
# production caller is main()'s per-file loop.
SCOPE_BENIGN_LOCKFILES=()

# ENG-96: map a single PM CLI token (cargo, npm, ...) to one or more
# canonical lockfile basenames, emitted one per line. Unknown tokens
# emit nothing. The token table is the de-Tauri inference surface;
# extending to a new stack is a single case-arm edit.
# NOTE: npx is included as an inference signal — a profile mentioning
# `npx playwright` implies npm-managed; npx itself is not a manager.
# NOTE: the table is non-exhaustive; maven/gradle/composer/pdm/hatch
# land via separate tickets when a stack adoption surfaces them.
_lockfile_for_pm() {
  case "$1" in
    cargo)             printf '%s\n' 'Cargo.lock' ;;
    bun)               printf '%s\n' 'bun.lock' 'bun.lockb' ;;
    pnpm)              printf '%s\n' 'pnpm-lock.yaml' ;;
    yarn)              printf '%s\n' 'yarn.lock' ;;
    npm|npx)           printf '%s\n' 'package-lock.json' ;;
    poetry)            printf '%s\n' 'poetry.lock' ;;
    pipenv)            printf '%s\n' 'Pipfile.lock' ;;
    uv)                printf '%s\n' 'uv.lock' ;;
    go)                printf '%s\n' 'go.sum' ;;
    bundle|bundler)    printf '%s\n' 'Gemfile.lock' ;;
  esac
}

# ENG-96: resolve the profile path. Honors a $SCOPE_CHECK_PROFILE_PATH
# env-var override (TEST-ONLY convention; production callers must NOT
# set this). Falls back to the canonical slug-relative path matching
# bin/render-prompt.sh:149.
_resolve_profile_path() {
  if [[ -n "${SCOPE_CHECK_PROFILE_PATH:-}" ]]; then
    printf '%s' "$SCOPE_CHECK_PROFILE_PATH"
    return 0
  fi
  printf '%s' "$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md"
}

# ENG-96: parse `## Build & test gates` from a profile, word-grep for
# known PM CLI tokens, emit canonical lockfile basenames (one per line,
# sorted-unique). Returns 0 with empty stdout on:
#   - missing profile file (D-005 case 1)
#   - missing `## Build & test gates` section (D-005 case 2)
#   - present section, no recognised PM token (D-005 case 3 — harness-self)
#
# SECURITY INVARIANT: $pm in `grep -qwE "$pm"` MUST originate from this
# function's hardcoded `for pm in ...` loop. NEVER pass profile-derived
# content into the regex — that would allow a malicious profile to
# inject arbitrary patterns into the scope-check gate.
_profile_lockfile_basenames() {
  local profile_path="$1"
  [[ -f "$profile_path" ]] || return 0

  local section
  section="$(awk '
    /^## Build & test gates[[:space:]]*$/ { in_section=1; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$profile_path")"
  [[ -n "$section" ]] || return 0

  local pm
  {
    for pm in cargo bun pnpm yarn npm npx poetry pipenv uv go bundle bundler; do
      if grep -qwE "$pm" <<<"$section"; then
        _lockfile_for_pm "$pm"
      fi
    done
  } | sort -u
}

# ENG-194: kept as back-compat wrappers so callers (tests, sourced
# modules) that resolved the old function names continue to work.
# Body delegates to bin/plan-scope.sh — the parse + match logic now
# has exactly one home.
find_canonical_plan() {
  plan_scope::find_plan "$1" "$2"
}

extract_scope_section() {
  plan_scope::extract_section "$1"
}

# Does $1 look benign regardless of plan?
is_benign() {
  local f="$1"
  # (a) sanctioned agent scratch namespace — gitignored, sweep-invisible
  # on implementing|ui|qa. Mirrored from partition_dirty_paths so the
  # agent-side scope-check accepts the same paths the orchestrator-side
  # sweep already filters.
  case "$f" in .scratch/*) return 0 ;; esac
  # (b) stack-agnostic harness-owned path classes (ENG-96 D-001)
  local cls
  for cls in "${_BENIGN_PATH_CLASSES[@]}"; do
    # shellcheck disable=SC2053
    case "$f" in $cls) return 0 ;; esac
  done
  # (c) profile-derived lockfile basenames (ENG-96 D-002 / D-003).
  # Bash 3.2 + set -u: an empty-array `"${arr[@]}"` expansion errors with
  # "unbound variable". Guard with explicit count check so the empty-set
  # fallback (D-005) does not crash the script.
  if (( ${#SCOPE_BENIGN_LOCKFILES[@]} > 0 )); then
    local lf
    for lf in "${SCOPE_BENIGN_LOCKFILES[@]}"; do
      [[ "$f" == "$lf" ]] && return 0
    done
  fi
  # (d) Rust crate-tests carve-out (OUT of ENG-96 scope per Linear; preserved verbatim).
  # Requires $allowed_files / $allowed_dirs from main scope.
  if [[ "$f" =~ ^(crates/[^/]+)/tests/ ]]; then
    local crate_dir="${BASH_REMATCH[1]}"
    if grep -qE "^${crate_dir}/" <<<"$allowed_files$allowed_dirs" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# Does $1 share its top-level path segment with any allowed token?
is_notable() {
  local f="$1"
  local top="${f%%/*}"
  [[ -z "$top" || "$top" == "$f" ]] && return 1
  grep -qE "^${top}/" <<<"$allowed_files$allowed_dirs" 2>/dev/null
}

# Returns 0 iff there is a scope-approval decision newer than the most recent
# scope-related halt on the issue. Recognizes both old and new marker shapes
# via parse_pipeline_marker. If no scope-related halt exists, returns 1 (no
# pending decision to match — caller re-runs the normal scope check).
has_scope_approval() {
  local issue="$1"
  [[ -n "$issue" ]] || die "has-scope-approval: issue id required"
  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue")"
  [[ -z "$comments" || "$comments" == "null" ]] && return 1

  # Find latest scope-related halt. After T3.1 removed the old-shape
  # parser branch, only canonical scope-violation reaches here (old-shape
  # no longer parses, and new-shape writers use the registry which
  # canonicalizes to scope-violation). The defensive scope-deviation
  # acceptance was a Phase 2 carryover; it is dead code now.
  local last_halt_ts=""
  local ts body ev reason
  while IFS=$'\t' read -r ts body; do
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
    [[ "$(jq -r '.result' <<<"$ev")" != "halt" ]] && continue
    reason="$(jq -r '.reason' <<<"$ev")"
    [[ "$reason" == "scope-violation" ]] || continue
    [[ "$ts" > "$last_halt_ts" ]] && last_halt_ts="$ts"
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")
  [[ -z "$last_halt_ts" ]] && return 1

  # Find the latest decision approve gate=scope newer than that halt.
  local approved_ts=""
  while IFS=$'\t' read -r ts body; do
    [[ ! "$ts" > "$last_halt_ts" ]] && continue
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    [[ "$(jq -r '.event' <<<"$ev")" != "decision" ]] && continue
    [[ "$(jq -r '.action' <<<"$ev")" != "approve" ]] && continue
    [[ "$(jq -r '.gate // ""' <<<"$ev")" != "scope" ]] && continue
    [[ "$ts" > "$approved_ts" ]] && approved_ts="$ts"
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  [[ -n "$approved_ts" ]]
}

main() {
  local issue_id="${1:-}" branch="${2:-}"
  [[ -n "$issue_id" && -n "$branch" ]] || die "usage: scope-check.sh <issue_id> <branch>"

  # In the worktree flow, run-stage.sh invokes scope-check with cwd inside the
  # per-issue worktree, where the plan has been committed on the feature branch
  # but not merged to main. Resolve plans from that worktree, not from the shared
  # $TARGET_REPO (which points at main via SCRIPT_DIR/../..).
  local worktree_root
  worktree_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$TARGET_REPO")"

  # ENG-59: refresh the upstream main reference so the diff below resolves
  # against origin/main rather than a possibly-stale refs/heads/main. The
  # harness's bot identity ticks every 5 min; the operator's `git pull`
  # cadence may lag upstream merges by hours, and any merge that lands in
  # the gap would otherwise be falsely attributed to the agent's diff. On
  # fetch failure the script proceeds against whatever refs/remotes/origin/main
  # was left by run-local.sh's worktree-creation fetch, falling back to local
  # main only if no origin/main ref exists at all.
  local fetch_ok=1
  if ! git -C "$worktree_root" fetch --quiet --no-tags origin main 2>/dev/null; then
    fetch_ok=0
    log "scope-check: fetch origin main failed; falling back to local refs"
  fi

  local plan
  plan="$(find_canonical_plan "$issue_id" "$worktree_root")" \
    || { log "scope-check: plan not found for $issue_id (no docs/plans/*.md with frontmatter linear: $issue_id)"; exit 2; }
  local plan_rel="${plan#"$worktree_root/"}"
  log "scope-check: plan=$plan_rel branch=$branch"

  local body
  body="$(extract_scope_section "$plan")"
  [[ -n "$body" ]] \
    || { log "scope-check: plan=$plan_rel: File Structure section missing or empty (expected a '## File Structure' or '### File Structure' heading)"; exit 2; }

  local allowed_files allowed_dirs
  # ENG-194: parse via the shared plan-structural matcher. The pre-refactor
  # `grep -oE … | sort -u` pipelines lived inline at this site; both have
  # moved verbatim to bin/plan-scope.sh:plan_scope::parse_allowed_files /
  # parse_allowed_dirs. Keeping the regex source-of-truth in one place is
  # the structural defense behind AC #4 (reviewer + scope-check parse
  # the same body byte-for-byte). The ENG-25 `*` vs `+` directory-prefix
  # fix and the ENG-46 dotfile-dir awk anchor are preserved in the helper.
  allowed_files="$(plan_scope::parse_allowed_files "$body")"
  allowed_dirs="$(plan_scope::parse_allowed_dirs "$body")"

  if [[ -z "$allowed_files$allowed_dirs" ]]; then
    log "scope-check: plan=$plan_rel: File Structure section parsed but contains no file or directory tokens"
    exit 2
  fi

  # ENG-96: populate the profile-derived lockfile array once per dispatch.
  # Read in is_benign via dynamic scope (same pattern as $allowed_files /
  # $allowed_dirs). D-005: missing profile / missing section / no PM token
  # → empty array + one warning log line.
  local _profile_path
  _profile_path="$(_resolve_profile_path)"
  # mapfile not portable on bash 3.2; use read-while loop.
  SCOPE_BENIGN_LOCKFILES=()
  local _lf
  while IFS= read -r _lf; do
    [[ -n "$_lf" ]] && SCOPE_BENIGN_LOCKFILES+=("$_lf")
  done < <(_profile_lockfile_basenames "$_profile_path")
  if (( ${#SCOPE_BENIGN_LOCKFILES[@]} == 0 )); then
    log "scope-check: profile-derived lockfile set empty (path=$_profile_path; missing or no Build & test gates section); falling back to path-class benign only"
  fi

  # ENG-59: prefer origin/main as the diff base. With the fetch above,
  # refs/remotes/origin/main is fresh on every online tick. On
  # offline/no-remote ticks, fall back to local main with a warning so
  # the operator sees the degraded mode in the per-stage transcript.
  # The two-arm guard is necessary because bin/scope-check-test.sh's
  # cases 2-5 fixtures don't configure an origin remote — without the
  # guard those fixtures would hard-fail.
  local diff_base
  if git -C "$worktree_root" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then
    diff_base="origin/main"
  else
    diff_base="main"
    log "scope-check: origin/main ref absent; using local main (fewer guarantees)"
  fi
  local changed
  changed="$(git -C "$worktree_root" diff --name-only "${diff_base}...${branch}" 2>/dev/null || true)"
  [[ -n "$changed" ]] || { log "scope-check: no file changes on $branch"; exit 0; }

  local notable="" severe="" benign_count=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # ENG-194: delegate in-plan check to the shared helper. The
    # `grep -qxF` + dir-prefix `case` loop are now inside
    # plan_scope::path_in_scope; keeping them in one home is the
    # AC #4 invariant. is_benign / is_notable below remain
    # scope-check-only — those reach into $allowed_files /
    # $allowed_dirs via dynamic scope (the Rust crates-tests
    # carve-out at line 200) so the variable names are preserved.
    if plan_scope::path_in_scope "$f" "$allowed_files" "$allowed_dirs"; then
      continue
    fi

    if is_benign "$f"; then
      benign_count=$((benign_count + 1))
      log "scope-check: benign escape: $f"
      continue
    fi
    if is_notable "$f"; then
      notable+="notable	$f"$'\n'
    else
      severe+="severe	$f"$'\n'
    fi
  done <<<"$changed"

  if [[ -n "$severe" ]]; then
    log "scope-check: SEVERE out-of-scope files on $branch:"
    printf '%s' "$severe"
    [[ -n "$notable" ]] && printf '%s' "$notable"
    exit 3
  fi

  if [[ -n "$notable" ]]; then
    log "scope-check: NOTABLE out-of-scope files on $branch (awaiting approval):"
    printf '%s' "$notable"
    exit 1
  fi

  log "scope-check: pass (benign_escapes=$benign_count)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    has-scope-approval)
      shift
      has_scope_approval "$@"
      ;;
    *)
      main "$@"
      ;;
  esac
fi
