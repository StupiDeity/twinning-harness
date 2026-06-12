#!/usr/bin/env bash
# Run the retrospective agent locally, then open a PR with any proposed rule /
# knowledge / workflow changes. Replaces the old pipeline-retrospective.yml
# weekly CI cron so we don't need ANTHROPIC_API_KEY in CI.
#
# Invoked by launchd via com.twinning.retrospective.plist (Mondays 09:00 local).
# Can also be kicked manually: bash .pipeline/bin/run-retrospective-local.sh
#
# Exit codes: 0=success (incl. no-op), 1=setup failure, 20=dispatch failed.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Load shared secrets then per-project .env.local so LINEAR_API_KEY and friends
# are available to the agent. secrets.env is loaded first; .env.local may override.
SECRETS_FILE="$HARNESS_CONFIG_DIR/secrets.env"
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$SECRETS_FILE"; set +a
fi
ENV_FILE="$TARGET_CONFIG_DIR/.env.local"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

require_env LINEAR_API_KEY
require_bin claude gh git jq

# _compute_retro_period — emits two ISO 8601 UTC timestamps on stdout
# (one per line: start, then end). Period semantics mirror
# AGENT_PROMPTS.md §9 "Period of analysis":
#   - Start: timestamp of the last weekly retrospective merge, or
#     30 days ago if none.
#   - End: now (UTC).
_compute_retro_period() {
  local end_iso start_iso last_merge_unix
  end_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  last_merge_unix="$(git -C "$TARGET_REPO" log --merges --format='%ct %s' \
    | grep 'weekly retrospective' | head -1 | awk '{print $1}' || true)"
  if [[ -n "$last_merge_unix" && "$last_merge_unix" =~ ^[0-9]+$ ]]; then
    start_iso="$(date -u -r "$last_merge_unix" +%Y-%m-%dT%H:%M:%SZ)"
  else
    start_iso="$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ)"
  fi
  printf '%s\n%s\n' "$start_iso" "$end_iso"
}

# ENG-130 D-002: hard-coded ordered shape registry. Order mirrors §1-§12
# of the pre-ENG-130 AGENT_PROMPTS.md §9, which encoded the dependency
# order chosen by humans (e.g., expiry decisions in §6 affect §10
# budget counts; §3/§4 candidate harvesting before §7 bias audit).
# Adding a shape: drop a new prompt body under bin/retro-prompts/, write
# a driver + sibling test mirroring bin/retro-shape-stage-failure-summary.sh,
# append the name here.
SHAPES=(
  stage-failure-summary
  gotcha-recurrence
  convention-drift
  gotcha-promotion
  human-override
  expiry-verification
  confirmation-bias-audit
  recency-bias
  survivorship-bias
  knowledge-budget
  pipeline-health-score
  prompt-workflow-amendment
  tool-denial-trends
  runtime-invariant-audit
  claude-version-drift
)

# ENG-130 D-009: find the most-recent prior retrospective directory
# (lexically earlier than today's date) that contains the named shape's
# artifact. Emits absolute path, or literal "(none)" if no prior
# artifact exists. Lexical sort is correct because dirname format is
# frozen at retrospective-YYYY-MM-DD (ISO-8601).
_resolve_previous_period_artifact() {
  local shape="$1" today="$2"
  local most_recent
  # Basename-anchored parse (ENG-130 review m1): split the path on `/`,
  # take the last component, then strip the `retrospective-` prefix.
  # An older `-F'/retrospective-'` split mis-attributed fields when an
  # ancestor directory in PROJECT_STATE_DIR happened to contain
  # `/retrospective-` itself.
  most_recent="$(
    find "$PROJECT_STATE_DIR" -maxdepth 1 -type d \
      -name 'retrospective-*' 2>/dev/null \
      | awk -v today="$today" '
          { n = split($0, a, "/"); basename = a[n] }
          basename ~ /^retrospective-/ {
            date = substr(basename, length("retrospective-") + 1)
            if (date != "" && date < today) print $0
          }
        ' \
      | sort -r | head -1
  )"
  if [[ -n "$most_recent" && -f "$most_recent/${shape}.md" ]]; then
    printf '%s' "$most_recent/${shape}.md"
  else
    printf '%s' '(none)'
  fi
}

main() {
  local today branch log_file
  today="$(date -u +%Y-%m-%d)"
  branch="pipeline/retrospective-${today}"
  log_file="$PROJECT_STATE_DIR/logs/retrospective-$(date -u +%Y%m%dT%H%M%SZ).log"
  mkdir -p "$(dirname "$log_file")"

  log "retrospective: starting for $today"

  # Fresh-checkout guard. Bail if the working tree has uncommitted changes —
  # we run off main and don't want to pollute in-flight work.
  if [[ -n "$(git -C "$TARGET_REPO" status --porcelain)" ]]; then
    die "retrospective: working tree dirty; refusing to run. Commit or stash first."
  fi

  # Make sure we have the latest main.
  git -C "$TARGET_REPO" fetch origin main

  # Checkout working branch off origin/main. Idempotent: if the branch already
  # exists (e.g. re-run same day), reuse it.
  if git -C "$TARGET_REPO" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
    log "retrospective: branch $branch exists; reusing"
    git -C "$TARGET_REPO" checkout "$branch"
    git -C "$TARGET_REPO" reset --hard origin/main
  else
    git -C "$TARGET_REPO" checkout -b "$branch" origin/main
  fi

  local period_lines period_start_iso period_end_iso
  period_lines="$(_compute_retro_period)"
  period_start_iso="$(printf '%s' "$period_lines" | sed -n '1p')"
  period_end_iso="$(printf '%s' "$period_lines"   | sed -n '2p')"

  local shape_artifact_dir="$PROJECT_STATE_DIR/retrospective-${today}"
  mkdir -p "$shape_artifact_dir"

  # ENG-130 D-005: per-shape failure semantics. Each shape is invoked
  # in turn; rc != 0 is logged and the loop continues. Surviving shapes
  # still contribute to the PR. After the loop, the coordinator opens
  # exactly one PR iff `git diff --cached` shows tracked-file changes.
  #
  # ENG-158 grep-discoverability hint: the loop iterates ${shape} →
  # bash retro-shape-${shape}.sh, so the literal driver filenames for
  # the ENG-158 shapes are listed here for maintainers searching by
  # filename — runtime behavior is the SHAPES array above.
  #   - retro-shape-tool-denial-trends.sh
  #   - retro-shape-runtime-invariant-audit.sh
  #   - retro-shape-claude-version-drift.sh
  local -a succeeded_shapes=()
  local -a failed_shapes=()
  local -A shape_rcs=()  # bash 4.4+ (assoc array + set -u empty-array expansion); host runs bash 5 per CLAUDE.md
  local shape artifact prev rc

  for shape in "${SHAPES[@]}"; do
    artifact="$shape_artifact_dir/${shape}.md"
    prev="$(_resolve_previous_period_artifact "$shape" "$today")"
    rc=0
    bash "$SCRIPT_DIR/retro-shape-${shape}.sh" \
      --artifact-path        "$artifact" \
      --period-start-iso     "$period_start_iso" \
      --period-end-iso       "$period_end_iso" \
      --previous-period-path "$prev" \
      || rc=$?
    if (( rc == 0 )); then
      succeeded_shapes+=("$shape")
    else
      failed_shapes+=("$shape")
      shape_rcs[$shape]="$rc"
      log "coordinator: shape '$shape' failed (rc=$rc); continuing with remaining shapes"
    fi
  done

  # ENG-130 D-006: bash-side PR body composition. Mechanical
  # concatenation under a `## Period` preamble + a `## Failed shapes`
  # footer. Shape artifacts that are zero-byte are skipped (D-006
  # `[[ -s ... ]]` guard).
  local pr_body_path="$shape_artifact_dir/pr-body.md"
  {
    printf '## Period\n'
    printf '%s → %s\n' "$period_start_iso" "$period_end_iso"
    for shape in "${succeeded_shapes[@]}"; do
      if [[ -s "$shape_artifact_dir/${shape}.md" ]]; then
        printf '\n---\n\n'
        cat "$shape_artifact_dir/${shape}.md"
      fi
    done
    if (( ${#failed_shapes[@]} > 0 )); then
      printf '\n---\n\n## Failed shapes\n\n'
      for shape in "${failed_shapes[@]}"; do
        # ENG-130 review n2: resolve the actual most-recent log file for
        # this shape rather than emitting a literal `*.log` glob the
        # operator has to expand by hand. Fall back to the logs/ dir hint
        # when no log was produced (e.g., shape crashed before logging).
        local resolved_log
        resolved_log="$(ls -t "$PROJECT_STATE_DIR/logs/retro-shape-${shape}-"*.log 2>/dev/null | head -1)"
        if [[ -n "$resolved_log" ]]; then
          printf '- %s (rc=%s, log=%s)\n' \
            "$shape" "${shape_rcs[$shape]}" "$resolved_log"
        else
          printf '- %s (rc=%s, log=%s/logs/)\n' \
            "$shape" "${shape_rcs[$shape]}" "$PROJECT_STATE_DIR"
        fi
      done
    fi
  } > "$pr_body_path"

  # If no shape produced tracked-file changes, don't open a PR.
  git -C "$TARGET_REPO" add -A
  if git -C "$TARGET_REPO" diff --cached --quiet; then
    log "retrospective: no changes proposed this week"
    if (( ${#failed_shapes[@]} > 0 )); then
      bash "$SCRIPT_DIR/slack.sh" error "Weekly retrospective: ${#failed_shapes[@]} of ${#SHAPES[@]} shapes failed: $(printf '%s,' "${failed_shapes[@]}" | sed 's/,$//'); no PR opened (no diff)."
    else
      bash "$SCRIPT_DIR/slack.sh" info "Weekly retrospective: no changes proposed."
    fi
    git -C "$TARGET_REPO" checkout main
    git -C "$TARGET_REPO" branch -D "$branch" || true
    return 0
  fi

  git -C "$TARGET_REPO" \
    -c user.name="twinning-pipeline-bot" \
    -c user.email="twinning-pipeline-bot@users.noreply.github.com" \
    commit -m "chore(pipeline): weekly retrospective ${today}"
  git -C "$TARGET_REPO" push -u origin "$branch"

  if ! gh pr create \
       --title "chore(pipeline): weekly retrospective ${today}" \
       --body-file "$pr_body_path" \
       --label "pipeline-retrospective"; then
    bash "$SCRIPT_DIR/slack.sh" error "gh pr create failed; commit pushed to $branch but PR not opened"
    exit 20
  fi

  if (( ${#failed_shapes[@]} > 0 )); then
    bash "$SCRIPT_DIR/slack.sh" error "Weekly retrospective: PR opened with ${#succeeded_shapes[@]}/${#SHAPES[@]} shapes succeeded; ${#failed_shapes[@]} failed: $(printf '%s,' "${failed_shapes[@]}" | sed 's/,$//')."
  else
    bash "$SCRIPT_DIR/slack.sh" info "Weekly retrospective opened a PR for review."
  fi
  git -C "$TARGET_REPO" checkout main
  log "retrospective: done"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
