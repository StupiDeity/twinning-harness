#!/usr/bin/env bash
# Pure-function library for run-local.sh's sweep-partition logic.
# Defines functions only; no top-level side effects. Do NOT set
# `set -euo pipefail` here — option side effects belong to the caller.
# Assumes common.sh has been sourced first (provides `die`).

stage_output_paths() {
  local stage="$1"
  case "$stage" in
    brainstorm)
      printf '%s\n' \
        'docs/brainstorms/' \
        'docs/knowledge/decisions.md'
      ;;
    plan)
      printf '%s\n' 'docs/plans/'
      ;;
    implement|ui|qa)
      printf '%s\n' \
        'src/' 'src-tauri/' 'crates/' 'tests/' 'docs/' \
        'package.json' 'package-lock.json' 'bun.lock' 'bun.lockb' \
        'Cargo.toml' 'Cargo.lock'
      ;;
    retrospective)
      printf '%s\n' \
        '.pipeline/learned-rules/' \
        'docs/knowledge/gotchas.md' \
        'docs/knowledge/qa-patterns.md' \
        'docs/knowledge/conventions.md' \
        'docs/knowledge/decisions.md' \
        '.pipeline/AGENT_PROMPTS.md' \
        '.pipeline/config.json' \
        '.github/workflows/'
      ;;
    review|build|release)
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
  for s in brainstorm plan implement ui review qa build release retrospective; do
    stage_output_paths "$s" >/dev/null \
      || die "stage_output_paths missing entry for stage: $s"
  done
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
  case "$stage" in brainstorm|plan) apply_d004=1 ;; esac

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
