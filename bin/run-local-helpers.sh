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

  local issue_lower=""
  if (( apply_d004 )); then
    issue_lower="$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')"
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
        if [[ "$base_lower" =~ (^|[^a-z0-9])${issue_lower}([^a-z0-9]|$) ]]; then
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
