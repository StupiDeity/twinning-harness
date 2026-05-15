#!/usr/bin/env bash
# Pure-function library for run-local.sh's sweep-partition logic.
# Defines functions only; no top-level side effects. Do NOT set
# `set -euo pipefail` here — option side effects belong to the caller.
# Assumes common.sh has been sourced first (provides `die`).

# ENG-51: read a per-stage scope override from CONFIG. Returns one entry
# per line on stdout, or nothing if the override is missing/empty/non-array.
# Empty arrays intentionally fall back (an empty list as configured override
# would route every dirty path to self-leak — almost always a misconfig).
_scope_allowlist_override() {
  local stage="$1"
  [[ -f "${CONFIG:-}" ]] || return 0
  jq -r --arg s "$stage" '
    (.scope.allowlist[$s] // []) as $arr
    | if ($arr | type) == "array" and ($arr | length) > 0
      then $arr[] | select(type == "string")
      else empty end
  ' "$CONFIG" 2>/dev/null || true
}

# ENG-95: parse the `## File layout` section of a project-profile.md into
# a flat list of paths (one per stdout line). Pure helper — no log calls,
# no state mutation, safe to call from tests without stubs. Operator-
# visible diagnostics live in stage_output_paths (D-005), not here. The
# canonical profile path matches bin/render-prompt.sh:149's resolution
# (HARNESS_ROOT/learned-rules/<PROJECT_SLUG>/project-profile.md).
_parse_profile_file_layout() {
  local profile_path="$1" slug="${2:-${PROJECT_SLUG:-}}"
  [[ -f "$profile_path" ]] || return 0

  # D-002 fail-closed: validate slug shape. A slug containing awk regex
  # or gsub replacement metachars (`.`, `|`, `[`, `&`, `\`, …) collapses
  # to empty rather than reaching the parser; the resulting empty
  # substitution drops the bullet via D-006's empty/`<…>` filter chain.
  if [[ ! "$slug" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    slug=""
  fi
  # Belt-and-braces: pre-escape awk gsub replacement metachars even
  # though the validation regex already disallows them. Order matters —
  # `\` first so the subsequent `&` escape's own backslash isn't doubled.
  local slug_esc
  slug_esc="${slug//\\/\\\\}"
  slug_esc="${slug_esc//&/\\&}"

  awk -v slug="$slug_esc" '
    /^## File layout[[:space:]]*$/ { in_section=1; next }
    in_section && /^## / { exit }
    in_section && /^- / {
      prefix = $0
      em_pos = index(prefix, " \xe2\x80\x94 ")
      if (em_pos == 0) em_pos = index(prefix, "—")
      if (em_pos > 0) prefix = substr(prefix, 1, em_pos - 1)
      while (match(prefix, /`[^`]+`/)) {
        token = substr(prefix, RSTART+1, RLENGTH-2)
        gsub(/<slug>/, slug, token)
        if (token != "" && token !~ /</ && token !~ /^\// \
            && token !~ /^\.\.\// && token !~ /\/\.\.\//) {
          print token
        }
        prefix = substr(prefix, RSTART + RLENGTH)
      }
    }
  ' "$profile_path"
}

# ENG-95: stack-agnostic always-include catalog union'd with the profile-
# derived File-layout list (D-003). Hardcoded by design — T1's structured
# schema may eventually move this catalog into per-stack profiles. False-
# positive scope is bounded: every entry is a single literal top-level
# filename (or `docs/`), never granting a broader directory prefix.
_always_include_paths() {
  printf '%s\n' \
    'docs/' \
    'package.json' 'package-lock.json' 'yarn.lock' \
    'pnpm-lock.yaml' 'bun.lock' 'bun.lockb' \
    'Cargo.toml' 'Cargo.lock' \
    'pyproject.toml' 'poetry.lock' 'uv.lock' \
    'Pipfile' 'Pipfile.lock' \
    'go.mod' 'go.sum' \
    'Gemfile' 'Gemfile.lock'
}

# Circuit breaker (ENG-10). Trips after $FAIL_THRESHOLD consecutive
# failures by writing `paused: true` to STATE_FILE — the same path
# `is_orchestrator_paused` reads as a runtime override over CONFIG.
#
# ENG-53 #2: previously this was a `grep '"paused": false' "$CONFIG"
# && sed s/false/true/` against config.json. Two failure modes:
#  - When CONFIG already had `paused: true` (the breaker tripping
#    a second time, or a setup that ships paused-by-default),
#    the grep failed and the breaker logged "leaving as-is" — a
#    silent no-op.
#  - More importantly: post-ENG-23, is_orchestrator_paused reads
#    STATE_FILE first. If state.local.json carries `paused: false`
#    (the operator's "resume" override), the runtime override wins
#    regardless of CONFIG. So even on a successful CONFIG flip,
#    the breaker did not actually halt anything. Observed during
#    ENG-44's dogfood run: 7+ trips, zero halts.
#
# set_orchestrator_paused (common.sh) writes to STATE_FILE — the
# same lane the override reads from — so the breaker now reliably
# halts the orchestrator on the next tick.
trip_breaker() {
  log "CIRCUIT BREAKER: setting orchestrator.paused=true after ${FAIL_THRESHOLD:-3} consecutive failures"
  set_orchestrator_paused true
}

# halt_issue_for_self_leak <issue> <stage> <hash1> [<hash2> ...]  (ENG-69)
# Halts a single issue for self-leak via classify_failure with
# skip-until-human-acts policy. Does NOT trip the global breaker.
#
# Pre-ENG-69, run-local.sh's tick-end sweep called trip_breaker on the
# FIRST occurrence of a self-leak — collapsing a per-issue agent failure
# into a harness-wide pause that froze every other issue's poll until
# manual intervention (the 2026-05-05 ENG-63 → ENG-64/65 incident). The
# new lane keeps the global breaker for genuinely cross-issue
# infrastructure outages (rc=24, linear-post-failed) and routes
# bot-introduced out-of-scope leaks through classify_failure against
# the affected issue only.
#
# The reason string passed to classify_failure carries ONLY sha12 hashes
# (max 5, with "(and N more)" suffix when count > 5); no raw filesystem
# paths flow into the halt-comment body via this entrypoint (security
# P1-1 — adversarial filenames cannot inject HTML markers, Unicode
# direction overrides, or shell metacharacters). The leak metric still
# carries the full hash list for retrospective audit.
halt_issue_for_self_leak() {
  local issue="$1" stage="$2"
  shift 2
  [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
    || die "halt_issue_for_self_leak: invalid issue id '$issue'"
  local hashes=("$@") count=$#
  local leak_csv="" h
  for h in "${hashes[@]}"; do
    leak_csv="${leak_csv:+${leak_csv},}${h}"
  done
  bash "$SCRIPT_DIR/metrics.sh" sweep-self-leak-out-of-scope "$issue" "$stage" \
    "self-leak" 0 "count=${count} hashes=${leak_csv}" \
    || log "metrics.sh sweep-self-leak-out-of-scope emission failed (non-blocking)"
  log "SELF-LEAK: ${count} bot-introduced out-of-scope path(s) on $issue; halting issue (in-scope paths NOT committed)"
  [[ "${PIPELINE_DRY_RUN:-}" == "1" ]] && return 0
  local hash_lines="" h_count=0
  for h in "${hashes[@]}"; do
    (( h_count >= 5 )) && break
    hash_lines="${hash_lines}${hash_lines:+, }${h}"
    h_count=$((h_count + 1))
  done
  local suffix=""
  (( count > 5 )) && suffix=" (and $((count - 5)) more)"
  classify_failure "$issue" "$stage" "skip-until-human-acts" \
    "self-leak: ${count} bot-introduced out-of-scope path(s); leaked hashes: ${hash_lines}${suffix}" \
    27
}

# stage_is_read_mostly <stage>
#
# Single source of truth for "this stage has no legitimate worktree
# writes." Derives the predicate directly from stage_output_paths
# (whose case arm for reviewing|building|released returns empty
# *by design*) — no duplicate stage list to drift.
#
# Reviewing/building/released agents write stage-summary files to
# $(issue_dir)/stage-summary-<stage>.md OUTSIDE the worktree, post
# Linear comments via bin/linear.sh, and target origin via gh/git.
# Their dispatch.sh allowed-tools surface confirms this: released
# has no Write tool at all; reviewing/building have Write only for
# the stage-summary path (verified pre-PR).
#
# Returns 0 if stage is read-mostly (stage_output_paths empty),
# else 1. UNKNOWN stages return 1 (NOT read-mostly) — conservative
# default so a typo'd stage cannot trigger the auto-clean branch and
# silently discard agent output. stage_output_paths dies on unknown
# stage; we catch the non-zero rc explicitly rather than swallowing
# it as empty stdout.
stage_is_read_mostly() {
  local out
  out="$(stage_output_paths "$1" 2>/dev/null)" || return 1
  [[ -z "$out" ]]
}

# stage_auto_cleans_self_leak <stage>
#
# Returns 0 iff a self-leak on this stage should be auto-cleaned by
# clean_self_leak_residue rather than halted via halt_issue_for_self_leak.
# Stage list: brainstorming, planning, reviewing, building, released.
# Returns 1 for implementing, ui, qa, retrospective, and UNKNOWN.
#
# Superset of stage_is_read_mostly (which returns 0 only for
# reviewing|building|released). The two doc-writing stages
# (brainstorming, planning) are added because their --allowed-tools
# surface does not include Bash(rm:*) (operator decision 2026-05-10),
# so they cannot clean up sub-agent debris themselves; the orchestrator
# absorbs the cleanup at the FD5 self-leak gate in run-local.sh.
#
# Distinct from stage_is_read_mostly: the latter is the SoT for "stage
# has no legitimate worktree writes" (consumed by partition's empty-
# allowlist case). Conflating the two would lie about brainstorm being
# read-mostly (it isn't — it writes docs/brainstorms/*).
stage_auto_cleans_self_leak() {
  case "$1" in
    brainstorming|planning|reviewing|building|released) return 0 ;;
    *) return 1 ;;
  esac
}

# clean_self_leak_residue <issue> <stage> <worktree> <path>...
#
# Called from run-local.sh's self-leak handler when the affected
# stage is read-mostly (per stage_is_read_mostly). Removes paths the
# partition sweep already identified as bot-introduced self-leak —
# i.e. NEW since tick-start (the sweep's snapshot comparison at
# run-local.sh has done the observed-vs-self-leak split). Operator's
# pre-existing 'observed' edits are NEVER touched because they don't
# appear in this path list.
#
# Eliminates the operator-touch halt that would otherwise fire (the
# halt_issue_for_self_leak skip-until-human-acts path) — the verdict
# and stage summary are already in Linear, residue has no upstream
# consumer. Implementing/UI/QA self-leaks still halt as before; this
# helper is only invoked for stages where the contract makes residue
# meaning-free.
#
# Forensic audit: emits sha12 hashes for every cleaned path in the
# metric notes payload so the retrospective can reconstruct what was
# wiped. Path strings themselves are NOT logged to Linear comments
# (matches halt_issue_for_self_leak's adversarial-filename
# discipline).
#
# Per-path strategy:
#   - tracked-modified (git ls-files succeeds): git checkout -- <p>
#   - untracked (anything else): rm -rf "$worktree/$p"
#
# Returns 0 always:
#   - empty path list → no-op
#   - missing worktree → no-op + warn
#   - main/master/empty branch → defensive refuse + warn
#   - dry-run → log only, no FS mutation
#   - partial per-path failure → log the rc count and emit metric anyway
clean_self_leak_residue() {
  local issue="$1" stage="$2" worktree="$3"
  shift 3
  local -a paths=("$@")
  local count="${#paths[@]}"
  (( count == 0 )) && return 0

  if [[ ! -d "$worktree" ]]; then
    log "auto-clean: no worktree at $worktree for ENG=$issue stage=$stage; skipping"
    return 0
  fi
  if ! git -C "$worktree" rev-parse --show-toplevel >/dev/null 2>&1; then
    log "auto-clean: $worktree is not a git working tree; skipping"
    return 0
  fi

  local branch
  branch="$(git -C "$worktree" branch --show-current 2>/dev/null || true)"
  case "$branch" in
    main|master|"")
      log "auto-clean: defensive refuse on branch='${branch:-<empty-or-detached>}' for stage=$stage (read-mostly cleanup must never run on main)"
      return 0
      ;;
  esac

  # Audit hashes first so the metric payload is reconstructible even
  # on partial failure (security review #4).
  local hash_csv="" sha p
  for p in "${paths[@]}"; do
    sha="$(sha12 "$p")"
    hash_csv="${hash_csv:+${hash_csv},}${sha}"
  done

  if [[ "${PIPELINE_DRY_RUN:-}" == "1" ]]; then
    log "[DRY_RUN] auto-clean: stage=$stage on $branch — would clean ${count} self-leak path(s); hashes=${hash_csv}"
    return 0
  fi

  log "auto-clean: stage=$stage is read-mostly; cleaning ${count} self-leak path(s) on $branch; hashes=${hash_csv}"

  # Per-path classification + cleanup. Failures are non-blocking — but
  # we DO log the per-class rc count so triage has signal.
  local rm_fail=0 ck_fail=0
  for p in "${paths[@]}"; do
    if git -C "$worktree" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
      git -C "$worktree" checkout -- "$p" >/dev/null 2>&1 || ck_fail=$((ck_fail + 1))
    else
      rm -rf -- "$worktree/$p" 2>/dev/null || rm_fail=$((rm_fail + 1))
    fi
  done
  if (( rm_fail > 0 || ck_fail > 0 )); then
    log "auto-clean: partial failure (rm_fail=${rm_fail} checkout_fail=${ck_fail}); some residue may survive — partition sweep on next tick will catch it"
  fi

  bash "$SCRIPT_DIR/metrics.sh" sweep-readonly-residue-cleaned "$issue" "$stage" \
    "cleaned" 0 "count=${count} branch=${branch} hashes=${hash_csv} rm_fail=${rm_fail} checkout_fail=${ck_fail}" \
    || log "metrics.sh sweep-readonly-residue-cleaned emission failed (non-blocking)"
}

# clean_scratch_dir <worktree>
#
# Tick-end stage-agnostic .scratch/ cleanup. Removes the directory if
# present, regardless of stage. Closes the cross-dispatch persistence
# vector: .scratch/ is gitignored, so its contents do NOT appear in
# `git status --porcelain` and therefore never reach partition_dirty_paths
# on any stage. Without an explicit cleanup, files an agent drops into
# .scratch/ during one dispatch survive into the next dispatch's worktree
# and could be read (via the Read tool, allowlisted on most stages) by
# the subsequent agent — a planted-file behavior-conditioning vector if
# combined with prompt injection on the intervening stage.
#
# Stage-agnostic because:
#   - On implementing/ui/qa, the agent may have used .scratch/ for
#     verification fixtures DURING its dispatch. Those fixtures have no
#     consumer after the dispatch ends (the agent's verdict + Linear
#     comments capture the work product).
#   - On reviewing/building/released, the agent may have done the same.
#     clean_self_leak_residue handles paths visible to git status, but
#     gitignored .scratch/ contents are invisible to that path. This
#     cleanup is the only defense.
#   - On brainstorming/planning, .scratch/* writes would self-leak via
#     partition (the .scratch/* filter is gated to impl/ui/qa). But if
#     somehow the agent dropped a .scratch/ payload that escaped notice
#     (e.g. an unmerged-but-staged write), this catches it.
#
# Returns 0 always. Missing .scratch/ → no-op. rm -rf failures →
# non-blocking warning. Caller is responsible for placing the
# invocation BEFORE any rc-based exit gate so the cleanup fires on
# agent-failure ticks (timeout rc=124, envelope rc=29, scope-check
# rc=21, crash) as well as success ticks. Without that ordering,
# stale .scratch/ payload from a failed dispatch persists across the
# operator's --action continue resume and re-opens the cross-dispatch
# state-injection vector this helper exists to close. The bin/run-local.sh
# wire-up at the post-dispatch line satisfies this ordering invariant;
# bin/run-local-helpers-adversarial-test.sh anchor #6 pins it.
clean_scratch_dir() {
  local worktree="$1"
  [[ -d "$worktree/.scratch" ]] || return 0
  if [[ "${PIPELINE_DRY_RUN:-}" == "1" ]]; then
    log "[DRY_RUN] scratch-clean: would remove $worktree/.scratch (tick-end cross-dispatch persistence guard)"
    return 0
  fi
  if rm -rf -- "$worktree/.scratch" 2>/dev/null; then
    log "scratch-clean: removed $worktree/.scratch (tick-end cross-dispatch persistence guard)"
  else
    log "scratch-clean: failed to remove $worktree/.scratch (rc=$?, non-blocking)"
  fi
}

# tally_leaked_in_scope_failure <issue> <stage> <leaked_count> <leaked_hashes_csv>  (ENG-69)
# Increments the per-issue consecutive-failures counter at
# $(issue_dir <issue>)/.consecutive-failures and escalates to a
# skip-until-human-acts halt at FAIL_THRESHOLD. Does NOT touch the global
# counter or trip the breaker.
#
# Pre-ENG-69, leaked-in-scope counted against the GLOBAL FAIL_COUNTER and
# tripped the breaker at threshold. That collapses three independent
# leak events on three different issues into a harness-wide pause.
# Now each issue gets its own counter; only same-issue accumulation
# escalates, and only against THAT issue.
#
# Counter-file integrity: the file is read with a non-digit sanitizer
# (pic="${pic//[^0-9]/}"; pic="${pic:-0}") so a corrupt body resumes at
# 0+1=1 rather than tripping arithmetic errors under set -e. The write
# is atomic: tmp file + mv -f, so a crash mid-tick cannot leave a torn
# counter (security P1-3 — tampering reverts to a clean integer).
tally_leaked_in_scope_failure() {
  local issue="$1" stage="$2" leaked_count="$3" leaked_hashes="$4"
  [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
    || die "tally_leaked_in_scope_failure: invalid issue id '$issue'"
  bash "$SCRIPT_DIR/metrics.sh" sweep-leaked-in-scope "$issue" "$stage" \
    "leak" 0 "count=${leaked_count} hashes=${leaked_hashes}" \
    || log "metrics.sh sweep-leaked-in-scope emission failed (non-blocking)"
  [[ "${PIPELINE_DRY_RUN:-}" == "1" ]] && return 0
  local pic_file pic
  pic_file="$(issue_dir "$issue")/.consecutive-failures"
  mkdir -p "$(dirname "$pic_file")"
  pic="$(cat "$pic_file" 2>/dev/null || printf '0')"
  pic="${pic//[^0-9]/}"; pic="${pic:-0}"
  pic=$((pic + 1))
  printf '%s\n' "$pic" > "${pic_file}.tmp.$$"
  mv -f "${pic_file}.tmp.$$" "$pic_file"
  log "sweep-leaked-in-scope: ${leaked_count} path(s) on $issue; per-issue consecutive failures = $pic (in-scope paths NOT committed)"
  if (( pic >= ${FAIL_THRESHOLD:-3} )); then
    classify_failure "$issue" "$stage" "skip-until-human-acts" \
      "leaked-in-scope at threshold: ${pic} consecutive failures (last leak: ${leaked_count} path(s))" \
      28
  fi
}

# route_run_stage_exit <issue> <stage> <rc>  (ENG-69)
# Routes a run-stage exit to the appropriate counter lane:
#   rc==0  → clear both global and per-issue counters; return 0.
#   rc==24 → global counter += 1; trip breaker at FAIL_THRESHOLD.
#   else   → per-issue counter += 1; classify_failure halt at threshold,
#            with the original rc passed through unchanged so the existing
#            failure_outcome_for_exit taxonomy entries (21=scope-violation,
#            124=dispatch-timeout, etc.) survive into the retrospective.
#
# Pre-ENG-69, every non-zero run-stage rc accumulated into the GLOBAL
# .consecutive-failures counter, so three independent agent failures on
# three different issues tripped the breaker and froze every other
# issue's poll. rc=24 (linear-post-failed) is the one infrastructure
# failure that GENUINELY portends "the next dispatch on ANY issue will
# also fail" — it stays in the global lane. Everything else is per-issue.
#
# Counter-file integrity: same sanitizer pattern as
# tally_leaked_in_scope_failure (pic="${pic//[^0-9]/}"; pic="${pic:-0}")
# so a corrupt body resumes at 1 rather than tripping arithmetic errors
# under set -e. Atomic write via tmp file + mv -f (security P1-3).
#
# Returns 0 in all cases; the caller in run-local.sh still does
# `[[ $rc -ne 0 ]] && exit $rc` so existing exit semantics are preserved.
route_run_stage_exit() {
  local issue="$1" stage="$2" rc="$3"
  [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
    || die "route_run_stage_exit: invalid issue id '$issue'"
  local pic_file
  pic_file="$(issue_dir "$issue")/.consecutive-failures"
  if (( rc == 0 )); then
    rm -f "$FAIL_COUNTER" 2>/dev/null || true
    rm -f "$pic_file" 2>/dev/null || true
    return 0
  fi
  case "$rc" in
    24)
      local count
      count="$(cat "$FAIL_COUNTER" 2>/dev/null || printf '0')"
      count="${count//[^0-9]/}"; count="${count:-0}"
      count=$((count + 1))
      mkdir -p "$(dirname "$FAIL_COUNTER")"
      printf '%s\n' "$count" > "${FAIL_COUNTER}.tmp.$$"
      mv -f "${FAIL_COUNTER}.tmp.$$" "$FAIL_COUNTER"
      log "run-stage.sh exited $rc on $issue (linear-post-failed; infrastructure); global consecutive failures = $count"
      if (( count >= ${FAIL_THRESHOLD:-3} )); then
        trip_breaker
      fi
      ;;
    *)
      mkdir -p "$(dirname "$pic_file")"
      local pic
      pic="$(cat "$pic_file" 2>/dev/null || printf '0')"
      pic="${pic//[^0-9]/}"; pic="${pic:-0}"
      pic=$((pic + 1))
      printf '%s\n' "$pic" > "${pic_file}.tmp.$$"
      mv -f "${pic_file}.tmp.$$" "$pic_file"
      log "run-stage.sh exited $rc on $issue; per-issue consecutive failures = $pic"
      if (( pic >= ${FAIL_THRESHOLD:-3} )); then
        classify_failure "$issue" "$stage" "skip-until-human-acts" \
          "exceeded ${FAIL_THRESHOLD:-3} consecutive same-issue failures (last exit ${rc})" \
          "$rc"
      fi
      ;;
  esac
  return 0
}

stage_output_paths() {
  local stage="$1"
  case "$stage" in
    brainstorming)
      printf '%s\n' \
        'docs/brainstorms/' \
        'docs/knowledge/decisions.md'
      ;;
    planning)
      printf '%s\n' 'docs/plans/'
      ;;
    implementing|ui|qa)
      # ENG-95 derivation order: (D-004) operator override wins absolutely;
      # absent that, (D-001) parse `## File layout` from the per-slug
      # profile and (D-003) union with the stack-agnostic always-include
      # catalog via `sort -u` (dedup boundary, e.g. profile listing `docs/`
      # coexists with the catalog's `docs/`). D-005 fail-soft: missing or
      # empty profile yields catalog-only and emits one diagnostic via
      # log() with the operator's remediation hint.
      local override
      override="$(_scope_allowlist_override "$stage")"
      if [[ -n "$override" ]]; then
        printf '%s\n' "$override"
      else
        local profile_path="${HARNESS_ROOT:-}/learned-rules/${PROJECT_SLUG:-}/project-profile.md"
        local profile_list
        profile_list="$(_parse_profile_file_layout "$profile_path")"
        if [[ -z "$profile_list" ]]; then
          log "stage_output_paths: profile-derived list empty for stage=$stage" \
              "(slug=${PROJECT_SLUG:-<unset>}, path=$profile_path);" \
              "falling back to docs/ + lockfile catalog." \
              "Run: bash bin/setup.sh project-profile"
        fi
        {
          printf '%s' "$profile_list"
          [[ -n "$profile_list" ]] && printf '\n'
          _always_include_paths
        } | LC_ALL=C sort -u
      fi
      ;;
    retrospective)
      printf '%s\n' \
        'docs/knowledge/gotchas.md' \
        'docs/knowledge/qa-patterns.md' \
        'docs/knowledge/conventions.md' \
        'docs/knowledge/decisions.md' \
        '.pipeline-config/config.json' \
        '.github/workflows/'
      ;;
    reviewing|building|released)
      : # read-mostly; nothing to sweep
      ;;
    *)
      die "stage_output_paths: unknown stage: $stage"
      ;;
  esac
}

bucket_for_path() {
  local p="$1"
  case "$p" in
    */*) printf '%s/' "${p%%/*}" ;;
    *)   printf '%s' "$p" ;;
  esac
}

sha12() {
  printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 12)}'
}

# Fast-fail at script startup if any stage enumerated by run-local.sh
# lacks a stage_output_paths entry. Brainstorm Open Question 6:
# retrospective IS included because run-local.sh defines a retrospective
# allowlist today.
assert_stage_allowlist_coverage() {
  local s
  for s in brainstorming planning implementing ui reviewing qa building released retrospective; do
    stage_output_paths "$s" >/dev/null \
      || die "stage_output_paths missing entry for stage: $s"
  done
}

# ENG-53 #5: frontmatter-based issue-id check, complements D-004's
# basename token. CLAUDE.md states "Doc-to-issue ownership is YAML
# frontmatter, not prose" — reconcile.sh already greps `linear: ENG-N`
# in the first 20 lines as the canonical mapping. partition_dirty_paths
# was inconsistent: it used basename only. Now it accepts EITHER signal.
#
# Returns 0 if file has `linear: ENG-N` in its first ~20 lines.
# Returns 1 if the file is missing (deleted paths can't have frontmatter),
# unreadable, or doesn't carry the matching frontmatter line.
_path_has_linear_frontmatter() {
  local path="$1" issue="$2"
  [[ -n "$path" && -n "$issue" ]] || return 1
  [[ -f "$path" ]] || return 1
  head -20 "$path" 2>/dev/null \
    | grep -qE "^linear:[[:space:]]+${issue}[[:space:]]*$"
}

# Consumes `git status -z --porcelain` on stdin; emits FD3 = in-scope,
# FD4 = leaked-in-scope, FD5 = out-of-scope. D-004 issue-id token check
# applied only to brainstorm|plan. Rename/copy records consume two NUL
# entries.
partition_dirty_paths() {
  local stage="$1" issue_id="$2"
  local -a allowlist=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && allowlist+=("$line")
  done < <(stage_output_paths "$stage")

  local apply_d004=0
  case "$stage" in brainstorming|planning) apply_d004=1 ;; esac

  local issue_lower="" issue_lower_re=""
  if (( apply_d004 )); then
    issue_lower="$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')"
    # Escape POSIX ERE metacharacters so ${issue_lower_re} is matched as a
    # literal substring by the `=~` operator below. Metachars: . [ ] ( ) { } * + ? ^ $ | \
    issue_lower_re="$(printf '%s' "$issue_lower" | sed 's/[][(){}.*+?^$|\\]/\\&/g')"
  fi

  local record code path skip_next=0
  while IFS= read -r -d '' record; do
    if (( skip_next )); then
      skip_next=0
      continue
    fi
    [[ ${#record} -lt 4 ]] && continue
    code="${record:0:2}"
    path="${record:3}"
    if [[ "$code" == R* || "$code" == C* ]]; then
      skip_next=1
    fi

    # Sanctioned agent scratch dir for ALLOWLISTED stages
    # (implementing/ui/qa). On those stages agents drop verification
    # fixtures alongside legitimate in-scope writes; .scratch/* is
    # gitignored and has no upstream consumer, so the sweep skips it
    # rather than misclassifying it as out-of-scope.
    #
    # NOT applied to brainstorming/planning: those stages have D-004
    # issue-id constraints + a tight docs/{brainstorms,plans}/ allow-
    # list. Letting them silently drop .scratch/* would create a
    # cross-dispatch state-injection vector (planted file readable by
    # later-stage agents via Read). Brainstorm/plan .scratch/* writes
    # therefore flow through to out-of-scope and self-leak halt.
    #
    # NOT applied to reviewing/building/released either: those stages
    # are read-mostly (stage_output_paths empty) and the self-leak
    # handler in run-local.sh auto-cleans the residue (per
    # stage_is_read_mostly). This carve-out would be redundant there.
    case "$stage" in
      implementing|ui|qa)
        case "$path" in .scratch/*) continue ;; esac
        ;;
    esac

    local matched_dir=0 matched_exact=0 entry
    if (( ${#allowlist[@]} > 0 )); then
      for entry in "${allowlist[@]}"; do
        if [[ "$entry" == */ ]]; then
          case "$path" in "$entry"?*) matched_dir=1; break ;; esac
        else
          [[ "$path" == "$entry" ]] && { matched_exact=1; break; }
        fi
      done
    fi

    if (( matched_exact )); then
      printf '%s\0' "$path" >&3
    elif (( matched_dir )); then
      if (( apply_d004 )); then
        local base base_lower
        base="${path##*/}"
        base_lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
        if [[ "$base_lower" =~ (^|[^a-z0-9])${issue_lower_re}([^a-z0-9]|$) ]]; then
          printf '%s\0' "$path" >&3
        elif _path_has_linear_frontmatter "$path" "$issue_id"; then
          # ENG-53 #5: basename mismatch but the doc's YAML frontmatter
          # declares this issue. Honor frontmatter as the canonical
          # doc-to-issue mapping (per CLAUDE.md), same as reconcile.sh.
          printf '%s\0' "$path" >&3
        else
          printf '%s\0' "$path" >&4
        fi
      else
        printf '%s\0' "$path" >&3
      fi
    else
      printf '%s\0' "$path" >&5
    fi
  done
}

# auto_commit_in_scope <issue_id> <stage>
# Commit + push every in-scope dirty path in the issue's worktree.
# Used by `bin/pipeline.sh decide --action continue` to complete the
# atomic resume when a self-leak halt suppressed the bot's tick-end
# in-scope commit (the brainstorm doc / plan doc / etc that the agent
# successfully wrote but never landed on origin).
#
# Reuses partition_dirty_paths so the path classification matches
# exactly what the tick-end sweep would do — committing more or less
# than the sweep would risks divergence between the operator-resumed
# and clean-tick paths.
#
# Returns:
#   stdout: count of paths committed (string-decimal; "0" on no-op)
#   rc 0 always — auto-commit failures must not block the atomic resume.
#         Caller distinguishes "did anything commit" via stdout, and
#         the metric stats include the count for audit.
#
# Skips (logs and returns "0"):
#   - worktree path missing or not a git repo
#   - branch is main/master/empty (refuse to auto-commit there)
#   - stage has no allow-list (reviewing/building/released/release/retro
#     read-only paths legitimately have nothing to commit)
#   - worktree clean (zero in-scope dirty paths)
#
# DRY-RUN: when PIPELINE_DRY_RUN=1, lists the paths it WOULD commit and
# returns the count without touching the worktree or origin.
auto_commit_in_scope() {
  local issue="$1" stage="$2"
  local worktree
  worktree="$(issue_dir "$issue")/worktree"

  if [[ ! -d "$worktree" ]]; then
    log "auto-commit: no worktree at $worktree (skip)"
    printf '0'
    return 0
  fi
  if ! git -C "$worktree" rev-parse --show-toplevel >/dev/null 2>&1; then
    log "auto-commit: $worktree is not a git working tree (skip)"
    printf '0'
    return 0
  fi

  local branch
  branch="$(git -C "$worktree" branch --show-current 2>/dev/null || true)"
  case "$branch" in
    main|master|"")
      log "auto-commit: worktree branch is '${branch:-<detached>}'; refusing (skip)"
      printf '0'
      return 0
      ;;
  esac

  # No allow-list = no in-scope paths = nothing to commit. (reviewing,
  # building, released stages legitimately return empty here — they're
  # read-mostly per stage_output_paths.)
  if [[ -z "$(stage_output_paths "$stage" 2>/dev/null || true)" ]]; then
    log "auto-commit: stage=$stage has no output allow-list (skip)"
    printf '0'
    return 0
  fi

  local in_scope_file
  in_scope_file="$(mktemp -t auto-commit-inscope.XXXXXX)"

  # partition_dirty_paths consumes NUL-delimited records straight from
  # `git status -z --porcelain`, INCLUDING the 2-char status prefix
  # (`?? `, ` M`, `R …`). It strips the prefix and tracks rename/copy
  # double-entries internally. Pipe straight in — same shape as
  # run-local.sh:251-253 calls partition. Subshell `cd` so the
  # frontmatter-resolution branch (_path_has_linear_frontmatter) finds
  # the dirty path on disk relative to the worktree.
  # FD4/FD5 routed to /dev/null — auto-commit only acts on FD3.
  git -C "$worktree" status -z --porcelain \
    | (cd "$worktree" && partition_dirty_paths "$stage" "$issue") \
        3>"$in_scope_file" 4>/dev/null 5>/dev/null

  local count
  count="$(tr -cd '\0' < "$in_scope_file" | wc -c | tr -d ' ')"

  if (( count == 0 )); then
    log "auto-commit: worktree $worktree clean (no in-scope dirty paths)"
    rm -f "$in_scope_file"
    printf '0'
    return 0
  fi

  if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
    log "[DRY_RUN] auto-commit: $count in-scope path(s) on $branch"
    tr '\0' '\n' < "$in_scope_file" | sed 's/^/[DRY_RUN]   /' >&2
    rm -f "$in_scope_file"
    printf '%s' "$count"
    return 0
  fi

  log "auto-commit: $count in-scope path(s) on $branch — committing"
  if ! (cd "$worktree" && xargs -0 git add -- < "$in_scope_file"); then
    log "auto-commit: git add failed; in-scope paths NOT committed (operator must commit manually)"
    rm -f "$in_scope_file"
    printf '0'
    return 0
  fi

  if ! git -C "$worktree" \
        -c user.name="$BOT_NAME" \
        -c user.email="$BOT_EMAIL" \
        commit -m "chore(pipeline): $stage for $issue (operator-resumed via decide)" >/dev/null; then
    log "auto-commit: git commit failed; staged in-scope paths left for operator review"
    rm -f "$in_scope_file"
    printf '0'
    return 0
  fi

  if ! git -C "$worktree" push -u origin HEAD 2>&1 | sed 's/^/  push: /' >&2; then
    log "auto-commit: git push failed (commit landed locally; will retry on next clean tick)"
    rm -f "$in_scope_file"
    printf '%s' "$count"
    return 0
  fi

  log "auto-commit: $count path(s) pushed to origin/$branch"
  rm -f "$in_scope_file"
  printf '%s' "$count"
}

# ENG-68 D-001: capture forensic snapshot of $git_dir before the caller's
# self-heal flips core.bare back to false. Side effects only — never raises;
# heal must proceed even if capture fails. Idempotent across retries.
#
# Args: $1 = git_dir (e.g. $HARNESS_ROOT/.git, $TARGET_REPO/.git)
# Returns: 0 always.
capture_core_bare_forensic() {
  local git_dir="$1"
  [[ -n "$git_dir" && -d "$git_dir" ]] || return 0

  local ts forensic_root base
  ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  base="${PROJECT_STATE_DIR:-${HARNESS_STATE_DIR:-${HOME}/.local/state/twinning-harness}/_unscoped}"
  forensic_root="$base/forensics/core-bare-flip-${ts}"
  mkdir -p "$forensic_root" 2>/dev/null || return 0

  # Capture nine artifacts in parallel; each redirects stdout+stderr so a
  # single failing capture leaves a `.error` sibling rather than losing the
  # rest. `|| printf …` covers the redirect itself failing (e.g. RO mount).
  {
    git --git-dir="$git_dir" config --list --show-origin > "$forensic_root/config.before" 2>&1 \
      || printf 'capture failed: %s\n' "$?" > "$forensic_root/config.before.error"
  } &
  {
    stat -f '%Sm %m %N' "$git_dir/config" > "$forensic_root/config-mtime" 2>&1 \
      || printf 'capture failed: %s\n' "$?" > "$forensic_root/config-mtime.error"
  } &
  {
    git --git-dir="$git_dir" reflog HEAD --date=iso 2>&1 | head -50 \
      > "$forensic_root/reflog-HEAD" 2>&1 \
      || printf 'capture failed: %s\n' "$?" > "$forensic_root/reflog-HEAD.error"
  } &
  {
    git --git-dir="$git_dir" reflog --date=iso --all 2>&1 | head -200 \
      > "$forensic_root/reflog-all" 2>&1 \
      || printf 'capture failed: %s\n' "$?" > "$forensic_root/reflog-all.error"
  } &
  {
    git --git-dir="$git_dir" for-each-ref \
      --format='%(objectname:short) %(refname) %(committerdate:iso)' 2>&1 | head -200 \
      > "$forensic_root/branches" 2>&1 \
      || printf 'capture failed: %s\n' "$?" > "$forensic_root/branches.error"
  } &
  {
    git --git-dir="$git_dir" worktree list --porcelain > "$forensic_root/worktrees" 2>&1 \
      || printf 'capture failed: %s\n' "$?" > "$forensic_root/worktrees.error"
  } &
  {
    ps -ef | grep -E '(git|claude|sourcetree|tower|gitkraken|launchd)' \
      | grep -v grep > "$forensic_root/ps-snapshot" 2>&1 \
      || printf 'capture failed: %s\n' "$?" > "$forensic_root/ps-snapshot.error"
  } &
  {
    local _today_log
    _today_log="${PROJECT_STATE_DIR:-}/logs/local-$(date -u +%Y-%m-%d).log"
    if [[ -f "$_today_log" ]]; then
      tail -500 "$_today_log" > "$forensic_root/recent-tick-log" 2>&1
    else
      printf '<no log file at %s>\n' "$_today_log" > "$forensic_root/recent-tick-log"
    fi
  } &
  {
    env | grep -E '^(GIT_|PIPELINE_|TARGET_|HARNESS_|PROJECT_)' | LC_ALL=C sort \
      > "$forensic_root/env-snapshot" 2>&1 \
      || printf 'capture failed: %s\n' "$?" > "$forensic_root/env-snapshot.error"
  } &
  wait

  # Stage transcripts: enumerate the most-recently modified per-stage logs
  # under the project's logs dir and snapshot the last 100 lines of each
  # (best-effort; the tmp NDJSON capture is removed by dispatch.sh's RETURN
  # trap, so per-stage `*.log` is the only post-run signal).
  local _logs_dir="${PROJECT_STATE_DIR:-}/logs"
  if [[ -d "$_logs_dir" ]]; then
    ls -t "$_logs_dir"/*-*.log 2>/dev/null | head -10 \
      > "$forensic_root/recent-stage-transcripts.list" 2>&1
    while IFS= read -r _stage_log; do
      [[ -f "$_stage_log" ]] || continue
      local _base; _base="$(basename "$_stage_log")"
      tail -100 "$_stage_log" > "$forensic_root/stage-tail.${_base}" 2>&1 || true
    done < "$forensic_root/recent-stage-transcripts.list"
  fi

  # Always log the dump location so operators see it in tick logs even
  # without a Linear comment (LINEAR_API_KEY may be unset at heal time).
  if declare -f log >/dev/null 2>&1; then
    log "[forensic] core.bare=true detected on $git_dir; dump at $forensic_root"
  else
    printf '[%s] [forensic] core.bare=true detected on %s; dump at %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$git_dir" "$forensic_root" >&2
  fi

  # Best-effort Linear announcement. Skipped if LINEAR_API_KEY is unset
  # (heal site at run-local.sh:72-80 fires BEFORE secrets sourcing at
  # line 84) or if no fallback issue is configured.
  local _post_issue="${PIPELINE_ISSUE_ID:-${PIPELINE_FORENSIC_FALLBACK_ISSUE:-}}"
  if [[ -n "${LINEAR_API_KEY-}" && -n "$_post_issue" && -n "${HARNESS_ROOT:-}" \
        && -x "$HARNESS_ROOT/bin/linear.sh" ]]; then
    local _utc_day; _utc_day="$(date -u +%Y-%m-%d)"
    bash "$HARNESS_ROOT/bin/linear.sh" add-or-update-comment \
      "core-bare-flip/${_utc_day}" "$_post_issue" --body - <<EOF || true
<!-- meta: forensic kind=core-bare-flip path=${forensic_root} -->
core.bare=true detected on ${git_dir} at ${ts} (UTC).
Self-heal applied; forensic snapshot at:
\`${forensic_root}\`

Inspect: \`ls ${forensic_root}\`

(See ENG-68 for trigger-class investigation; \`docs/runbooks/recovery.md\` §"ENG-68 follow-up" for disposition rules.)
EOF
  fi

  return 0
}

# Single-flight lock for run-local.sh. Uses POSIX-atomic mkdir(2) on
# $1 (the lock directory) to guarantee at most one pipeline tick runs
# concurrently on this host.
#
# Context (ENG-8): On 2026-04-18 UTC, runs 24614671581 (21:50) and
# 24614881559 (22:02) of the former .github/workflows/pipeline.yml
# double-dispatched the `plan` stage for ENG-5. verify_preconditions()
# at run-stage.sh:132-134 caught the second dispatch via label-mismatch
# die — that architecture-agnostic check is the PRIMARY defense against
# stage double-dispatch. This mkdir lock is the SECONDARY,
# per-host-tick-level optimization that stops overlapping run-local.sh
# ticks before they reach verify_preconditions.
#
# After commits 56c8a8a (2026-04-19, cron disabled) and 4f5850e
# (2026-04-20, workflow file deleted) moved the poll loop from
# .github/workflows/pipeline.yml to a local launchd job, the lock's
# scope is one host — if the pipeline ever runs on multiple hosts,
# only verify_preconditions protects the bug class. Do not remove
# this lock without either (a) a distributed alternative or
# (b) reaffirmed reliance on the precondition check.
#
# Returns 0 on success (fresh acquisition OR stale-lock recovery),
# 1 if another live holder owns the lock.
acquire_lock() {
  local lock_dir="$1"
  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' $$ > "$lock_dir/pid"
    return 0
  fi
  # Existing lock: break it if the holder process is gone.
  local holder
  holder="$(cat "$lock_dir/pid" 2>/dev/null || echo 0)"
  if [[ "$holder" =~ ^[0-9]+$ ]] && (( holder > 0 )) && ! kill -0 "$holder" 2>/dev/null; then
    rm -rf "$lock_dir"
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' $$ > "$lock_dir/pid"
      log "broke stale lock held by dead pid $holder"
      return 0
    fi
  fi
  return 1
}
