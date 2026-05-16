#!/usr/bin/env bash
# Extract a stage's prompt from AGENT_PROMPTS.md and interpolate tokens.
# Usage: render-prompt.sh <stage> <issue_id>
#   stage: brainstorming | planning | implementing | ui | reviewing | qa | building | released | retrospective
# Reads Linear issue via linear.sh get-issue.
# Emits rendered prompt text to stdout.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

STAGE_TO_SECTION='
brainstorming=1. Brainstorm Agent
planning=2. Plan Agent
implementing=3. Implementation Agent (Backend)
ui=4. UI Agent (Frontend)
reviewing=5. Review Agent
qa=6. QA Agent
building=7. Build Agent
released=8. Release Agent
retrospective=9. Retrospective Agent (Scheduled)
'

# §0 holds rules delivered to every stage's prompt (Secret-handling, Tool
# allowlist & probing, etc.). Maintained as a single source of truth in
# AGENT_PROMPTS.md; render-prompt.sh prepends its fenced block to every
# per-stage block before token interpolation. Editing rules here lets
# operators avoid 9-place edits in §§1-9 (the maintenance hazard ENG-46,
# ENG-53#11, ENG-57, ENG-74 each had to swallow before this consolidation).
COMMON_SECTION='0. Common rules (delivered to every stage)'

# ENG-87: prompt-token resolver registry. Every {token} in
# AGENT_PROMPTS.md is resolved at render time by a function registered
# here. ENG-79 introduced bin/branch-name.sh (a single dedicated helper
# for the {branch} token); ENG-87 extends that one-helper precedent to
# a registry covering all {token}s. Render-time validator dies on any
# unknown {token} encountered in the source. Adding a new token =
# (a) register here, (b) add the resolver function below, (c) emit
# the {token} in AGENT_PROMPTS.md.
PROMPT_RESOLVERS='
issue_id=_resolve_issue_id
issue_id_lower=_resolve_issue_id_lower
issue_title=_resolve_issue_title
issue_description=_resolve_issue_description
date=_resolve_date
slug=_resolve_slug
brainstorm_file=_resolve_brainstorm_file
plan_file=_resolve_plan_file
branch_name=_resolve_branch_name
stage_summary_path=_resolve_stage_summary_path
learned_rules_dir=_resolve_learned_rules_dir
dispatch_id=_resolve_dispatch_id
review_findings=_resolve_review_findings
progress_md_path=_resolve_progress_md_path
plan_json=_resolve_plan_json
'
# ENG-87 review-iter-7 n2: dispatch_id resolver is consistent with the
# _RENDER_* sibling pattern post-M9 — main() binds _RENDER_DISPATCH_ID
# before resolve_block_tokens runs, so test isolation uses the same
# `_RENDER_*=...` setup as every other resolver. See line ~221 for the
# resolver body and the M9 fix that closed the env-namespace divergence
# (was: read ambient ${PIPELINE_DISPATCH_ID-} directly).

# ENG-87 review-iter-7 C1: AGENT_RUNTIME_TOKENS — names the registry
# does NOT resolve at render time because the agent fills them in at
# runtime. Pre-iter-7 these were modelled as `_resolve_passthrough_*`
# functions returning the literal `{name}` string; that produced an
# identity substitution which the residual unknown-token validator
# below then re-detected and died on. The cleaner shape is an explicit
# allowlist: extract tokens, resolve registered ones, and skip
# AGENT_RUNTIME_TOKENS in the residual scan.
#
# Format: space-separated names with leading + trailing spaces so
# `[[ "$AGENT_RUNTIME_TOKENS" == *" $name "* ]]` substring tests are
# unambiguous (no prefix collisions across names like file / file_x).
AGENT_RUNTIME_TOKENS=' file pr_number stage_failure_summary_path '

lookup_section() {
  local stage="$1"
  grep -E "^${stage}=" <<<"$STAGE_TO_SECTION" | head -1 | cut -d= -f2-
}

slugify() {
  tr '[:upper:]' '[:lower:]' <<<"$1" \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

# Extract the fenced ``` block that follows a "## N. <Name>" header.
# Schema invariant: every stage section must have exactly TWO column-0 fences (the
# opening and closing of the prompt body). A mismatched count means AGENT_PROMPTS.md
# was edited in a way that breaks prompt extraction — die loudly rather than ship a
# silently-truncated prompt to the agent.
extract_block() {
  local section="$1" prompts="$HARNESS_ROOT/AGENT_PROMPTS.md"

  # Schema check: count column-0 fences in the section.
  # Boundary regex requires a numeric prefix (`## N. `) so H2 subheadings inside
  # the prompt body (e.g. `## Completion checklist`) do not prematurely end the
  # section and strand the closing fence.
  local fence_count
  fence_count="$(awk -v section="$section" '
    /^## [0-9]+\. / {
      if (in_section) { exit }
      line = $0
      sub(/^## /, "", line)
      if (line == section) { in_section=1 }
      next
    }
    in_section && /^```/ { count++ }
    END { print count+0 }
  ' "$prompts")"

  if [[ "$fence_count" != "2" ]]; then
    die "AGENT_PROMPTS.md schema error: section '$section' has $fence_count column-0 fences (expected 2). Check for stray \`\`\` lines or a missing closing fence."
  fi

  awk -v section="$section" '
    BEGIN { in_section=0; in_block=0; fence_count=0 }
    /^## [0-9]+\. / {
      if (in_section) { exit }
      line = $0
      sub(/^## /, "", line)
      if (line == section) { in_section=1 }
    }
    in_section && /^```/ {
      fence_count++
      if (fence_count == 1) { in_block=1; next }
      if (fence_count == 2) { exit }
    }
    in_section && in_block { print }
  ' "$prompts"
}

find_doc() {
  # Canonical-first: find the doc that declares `linear: <ID>` in YAML frontmatter
  # (same rule as reconcile.sh and scope-check.sh). Only if no frontmatter match
  # exists do we fall back to filename-contains (for legacy docs pre-dating the
  # frontmatter convention). Prints a repo-relative path or "".
  local dir="$1" issue_id="$2" slug="$3"
  if [[ ! -d "$dir" ]]; then printf ''; return; fi

  # 1) Canonical: linear: <ID> in frontmatter.
  local f
  while IFS= read -r -d '' f; do
    if awk -v id="$issue_id" '
      NR==1 && $0=="---" { in_fm=1; next }
      in_fm && $0=="---" { exit 1 }
      in_fm && $0 ~ "^linear:[[:space:]]+" id "[[:space:]]*$" { exit 0 }
      NR>20 { exit 1 }
    ' "$f"; then
      printf '%s' "${f#"$TARGET_REPO/"}"
      return
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -print0)

  # 2) Title fallback: `# ENG-5: …` in the first H1.
  while IFS= read -r -d '' f; do
    if awk -v id="$issue_id" '
      /^# / { if ($0 ~ "(^|[^A-Z0-9])" id "([^A-Z0-9-]|$)") exit 0; exit 1 }
      NR>30 { exit 1 }
    ' "$f"; then
      printf '%s' "${f#"$TARGET_REPO/"}"
      return
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -print0)

  # 3) Legacy fallback: filename contains issue_id, then slug.
  local match
  match="$(find "$dir" -maxdepth 1 -type f -iname "*${issue_id}*.md" 2>/dev/null | head -1)"
  if [[ -z "$match" && -n "$slug" ]]; then
    match="$(find "$dir" -maxdepth 1 -type f -iname "*${slug}*.md" 2>/dev/null | head -1)"
  fi
  if [[ -n "$match" ]]; then
    printf '%s' "${match#"$TARGET_REPO/"}"
  else
    printf ''
  fi
}

# Append the per-slug project profile to <stdin>.
# Reads piped stage prompt on stdin, writes augmented prompt to stdout.
# Skips for stage=retrospective (the retrospective agent is cross-slug).
# Dies if profile is missing or has unresolved <<NEEDS-INPUT:>> markers —
# both are setup-time configuration errors the operator must address via
# `bash bin/setup.sh project-profile`.
append_project_profile() {
  local stage="$1"

  if [[ "$stage" == "retrospective" ]]; then
    cat
    return 0
  fi

  local profile_path="$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md"
  if [[ ! -f "$profile_path" ]]; then
    cat >/dev/null
    die "render-prompt: no project-profile.md for slug=$PROJECT_SLUG; run: bash bin/setup.sh project-profile"
  fi
  if grep -q '<<NEEDS-INPUT:' "$profile_path"; then
    cat >/dev/null
    die "render-prompt: project-profile.md contains unresolved markers; run: bash bin/setup.sh project-profile"
  fi
  # Schema version warning (non-fatal).
  if ! grep -qE '^schema_version:[[:space:]]+1[[:space:]]*$' "$profile_path"; then
    log "render-prompt: WARNING — project-profile schema_version != 1, continuing"
  fi

  cat
  printf '\n\n---\n\n## Project profile (addendum)\n\n'
  cat "$profile_path"
  printf '\n'
}

# ENG-87: per-token resolver functions. Each takes the rendering context
# as global vars (issue_id, stage, etc. — set by main() before calling)
# and prints the resolved value on stdout. The registry's lookup-and-
# call pass treats unknown tokens as a die() — see resolve_block_tokens.
_resolve_issue_id() { printf '%s' "$_RENDER_ISSUE_ID"; }
_resolve_issue_id_lower() { printf '%s' "$_RENDER_ISSUE_ID_LOWER"; }
_resolve_issue_title() { printf '%s' "$_RENDER_TITLE"; }
_resolve_issue_description() { printf '%s' "$_RENDER_DESCRIPTION"; }
_resolve_date() { printf '%s' "$_RENDER_DATE"; }
_resolve_slug() { printf '%s' "$_RENDER_SLUG"; }
_resolve_brainstorm_file() { printf '%s' "$_RENDER_BRAINSTORM_FILE"; }
_resolve_plan_file() { printf '%s' "$_RENDER_PLAN_FILE"; }
_resolve_branch_name() { printf '%s' "$_RENDER_BRANCH_NAME"; }
_resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }
_resolve_progress_md_path() { printf '%s' "$_RENDER_PROGRESS_MD_PATH"; }
_resolve_learned_rules_dir() { printf '%s' "$_RENDER_LEARNED_RULES_DIR"; }
# ENG-87 review-iter-7 M9: read _RENDER_DISPATCH_ID like the sibling
# resolvers (was: read ambient ${PIPELINE_DISPATCH_ID-} directly).
# Test isolation now uses the same `_RENDER_*=...` setup pattern as
# every other resolver. main() binds _RENDER_DISPATCH_ID before
# calling resolve_block_tokens. Empty value is acceptable (agent-side
# auto-injection is no-op when the resolved value is empty).
_resolve_dispatch_id() { printf '%s' "${_RENDER_DISPATCH_ID-}"; }

# Resolves the contents of the prior reviewing stage's summary file
# at $(issue_dir)/stage-summary-reviewing.md — the durable record of
# what the reviewer asked the implementer to change. Inlined into the
# implementing prompt so the implementer cannot silently NOOP after a
# review-loopback (ENG-105 failure mode: reviewer rejects → implementer
# re-emits its prior summary verbatim → branch HEAD unchanged → reviewer
# rejects again, ad infinitum). When no prior review exists (fresh
# implement-stage dispatch from planning), resolves to a literal marker
# the prompt's "Review-loopback handling" block treats as a no-op signal.
_resolve_review_findings() {
  local p="${_RENDER_REVIEW_FINDINGS_PATH-}"
  if [[ -n "$p" && -s "$p" ]]; then
    cat "$p"
  else
    printf '(no prior review for this issue — this dispatch is not a review-loopback)'
  fi
}

# Without a structured plan.json sibling, the implement agent re-interprets
# prose pass-criteria on every dispatch, which drifts across rebases and
# BE↔FE re-readings (ENG-123). Inlining the JSON makes structured fields
# authoritative at dispatch time; `plan_json_missing` in events.jsonl lets
# the retrospective measure how often the fallback path fires.
# Note: explicit `|| return $?` on every metrics.sh call propagates errors
# reliably regardless of set -e scope; resolve_block_tokens wraps resolvers
# with `2>/dev/null || printf ''`, so the practical effect is an empty
# {plan_json} substitution rather than a render-prompt.sh crash.
_resolve_plan_json() {
  local plan_md_rel="$_RENDER_PLAN_FILE"
  local plan_json_rel plan_json_abs
  if [[ -n "$plan_md_rel" ]]; then
    plan_json_rel="${plan_md_rel%.md}.json"
    plan_json_abs="$TARGET_REPO/$plan_json_rel"
    if [[ -L "$plan_json_abs" ]]; then
      log "render-prompt: plan.json is a symlink — refusing to follow ($plan_json_rel)"
      bash "$SCRIPT_DIR/metrics.sh" plan_json_missing "$_RENDER_ISSUE_ID" "implementing" symlink_rejected 0 || return $?
      printf '%s' "(no plan.json — falling back to prose plan)"
      return 0
    fi
    if [[ -s "$plan_json_abs" ]]; then
      if grep -qFe '<<<PLAN_JSON_END>>>' -e '<<<PLAN_JSON_BEGIN>>>' "$plan_json_abs"; then
        log "render-prompt: plan.json contains literal delimiter — falling back"
        bash "$SCRIPT_DIR/metrics.sh" plan_json_missing "$_RENDER_ISSUE_ID" "implementing" delimiter_collision 0 || return $?
        printf '%s' "(no plan.json — falling back to prose plan)"
        return 0
      fi
      cat "$plan_json_abs"
      return 0
    fi
  fi
  if [[ -n "$plan_md_rel" ]]; then
    log "render-prompt: no plan.json sibling for $_RENDER_ISSUE_ID ($plan_json_rel); falling back to prose plan"
  else
    log "render-prompt: no markdown plan resolved for $_RENDER_ISSUE_ID; falling back to prose plan"
  fi
  # Stage label hardcoded per brainstorm §5 (iter-1 scope tightening); QA-sibling decides whether to lift to _RENDER_STAGE.
  bash "$SCRIPT_DIR/metrics.sh" plan_json_missing "$_RENDER_ISSUE_ID" "implementing" fallback 0 || return $?
  printf '%s' "(no plan.json — falling back to prose plan)"
}

# Look up the resolver function name for a token (without surrounding braces).
_lookup_resolver() {
  local token="$1"
  grep -E "^${token}=" <<<"$PROMPT_RESOLVERS" | head -1 | cut -d= -f2-
}

# resolve_block_tokens <block-text>
#   Substitute every {token} in $block via the PROMPT_RESOLVERS registry.
#   Dies on an unknown {token} (render-time validator). Uses bash literal
#   substitution (${var//pat/repl}) — glob-immune for {token} shapes
#   because {} contains no glob metachars; the resolver's value (which
#   may carry sed metachars in title/description) goes through bash
#   string substitution, NOT sed.
resolve_block_tokens() {
  local rendered="$1"
  local tokens t name resolver value
  # Extract distinct tokens from the source. \{[a-z_]+\} matches the
  # established convention in AGENT_PROMPTS.md.
  tokens="$(grep -oE '\{[a-z_]+\}' <<<"$rendered" | sort -u || true)"
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    name="${t#\{}"; name="${name%\}}"
    # ENG-87 review-iter-7 C1: agent-runtime tokens are NOT resolved
    # here. They are intentionally delivered to the agent as literal
    # `{name}` text (e.g., `{file}` is filled in by the agent at runtime
    # to name the file it just wrote). Pre-iter-7 these had identity
    # passthrough resolvers, but the residual scan below then re-detected
    # them and the validator died — every brainstorming and reviewing
    # render dropped to rc!=0. Skip resolution AND skip the residual
    # scan for these names.
    if [[ "$AGENT_RUNTIME_TOKENS" == *" $name "* ]]; then
      continue
    fi
    resolver="$(_lookup_resolver "$name")"
    [[ -n "$resolver" ]] \
      || die "render-prompt: unknown token '$t' in source — register a resolver in PROMPT_RESOLVERS"
    value="$("$resolver" 2>/dev/null || printf '')"
    # Inner expansions are deliberately unquoted: bash 3.2 (macOS system
    # bash) treats double-quotes inside ${var//pat/rep} as literal pattern
    # / replacement characters, wrapping the substituted value in literal
    # quotes. {token} contains no glob metachars and replacements are
    # interpreted literally, so unquoted is both correct and safe.
    rendered="${rendered//$t/$value}"
  done <<<"$tokens"
  # No post-substitution residual scan: the first-pass already dies on
  # any unknown token present in the source template (the `[[ -n
  # "$resolver" ]] || die "unknown token in source"` gate above).
  # A second-pass scan over $rendered conflates two distinct shapes:
  #   (a) template-side directives — already caught by the first pass.
  #   (b) `{token}`-shaped substrings injected by free-text resolver
  #       values (e.g. {review_findings} embedding a prior review summary
  #       that cites `${ident_lower}` bash-var syntax or names another
  #       `{plan_json}` token literally in prose).
  # Pre-fix the second pass false-positived on (b) and halted the
  # implementing dispatch with `unresolved token after registry pass`
  # any time a review summary mentioned a bash variable or token name.
  # Resolver values are content, not template directives, and the
  # renderer must not parse them for template tokens. Drift detection
  # for new tokens added to AGENT_PROMPTS.md without a matching resolver
  # lives in render-prompt-test.sh case ENG-87 R5 (the registry-coverage
  # pin) — a stronger guarantee than a runtime residual scan.
  printf '%s' "$rendered"
}

main() {
  local stage="${1:-}" issue_id="${2:-}"
  [[ -n "$stage" ]] || die "usage: render-prompt.sh <stage> <issue_id|release-meta>"

  local section
  section="$(lookup_section "$stage")"
  [[ -n "$section" ]] || die "no prompt section for stage: $stage"

  local block
  block="$(extract_block "$section")"
  [[ -n "$block" ]] || die "could not extract block for section: $section"

  # Prepend §0 (common rules delivered to every stage). Token interpolation
  # below runs over the full concatenated block, so {issue_id} substitutions
  # inside §0's exit-ramp prose resolve uniformly. Released stage uses sed
  # for substitution; the sed pipeline now also substitutes {issue_id} →
  # `cross-issue-release-${tag}` so §0's exit-ramp prose ships a usable
  # token to the released agent (review-iter-7 m5).
  local common_block
  common_block="$(extract_block "$COMMON_SECTION")"
  [[ -n "$common_block" ]] || die "could not extract common rules block (§0); check that AGENT_PROMPTS.md still has '## $COMMON_SECTION' with exactly two column-0 fences"
  block="${common_block}"$'\n'"${block}"

  # Released stage is cross-issue: it has no single owning Linear issue. Render with
  # release metadata (version/tag/prev_tag) supplied via env by run-release-observer.sh.
  # The release block uses {version}/{tag}/{prev_tag} tokens; these are
  # NOT in PROMPT_RESOLVERS (release-only) and use the legacy sed pass.
  if [[ "$stage" == "released" ]]; then
    local version="${PIPELINE_RELEASE_VERSION:-}"
    local tag="${PIPELINE_RELEASE_TAG:-}"
    local prev_tag="${PIPELINE_RELEASE_PREV_TAG:-}"
    [[ -n "$version" && -n "$tag" ]] || die "release stage needs PIPELINE_RELEASE_VERSION and PIPELINE_RELEASE_TAG env"
    # Resolve prev_tag if not provided.
    if [[ -z "$prev_tag" ]]; then
      prev_tag="$(git -C "$TARGET_REPO" describe --tags --abbrev=0 "${tag}^" 2>/dev/null \
        || git -C "$TARGET_REPO" rev-list --max-parents=0 HEAD | head -1)"
    fi
    # ENG-87 review-iter-7 m5: substitute {issue_id} too. §0's
    # agent-blocked exit-ramp prose carries `bash bin/pipeline.sh event
    # {issue_id} verdict halt --reason agent-blocked`; without this
    # substitution the released agent receives a literal `{issue_id}`
    # token. Released is cross-issue (no single owning Linear issue);
    # `cross-issue-release-${tag}` is a synthetic but human-greppable
    # value the agent's halt comment can reference.
    printf '%s' "$block" \
      | sed \
        -e "s|{version}|$version|g" \
        -e "s|{tag}|$tag|g" \
        -e "s|{prev_tag}|$prev_tag|g" \
        -e "s|{issue_id}|cross-issue-release-${tag}|g" \
      | append_project_profile "$stage"
    return 0
  fi

  [[ -n "$issue_id" ]] || die "stage=$stage requires <issue_id>"

  # Fetch issue metadata.
  local issue_json title description date slug
  issue_json="$(bash "$SCRIPT_DIR/linear.sh" get-issue "$issue_id" 2>/dev/null)"
  title="$(jq -r '.data.issue.title // ""' <<<"$issue_json")"
  description="$(jq -r '.data.issue.description // ""' <<<"$issue_json")"
  date="$(date -u +%Y-%m-%d)"
  slug="$(slugify "$title")"

  local brainstorm_file plan_file
  brainstorm_file="$(find_doc "$TARGET_REPO/docs/brainstorms" "$issue_id" "$slug")"
  plan_file="$(find_doc "$TARGET_REPO/docs/plans" "$issue_id" "$slug")"

  local issue_id_lower branch_name stage_summary_path learned_rules_dir
  issue_id_lower="$(tr '[:upper:]' '[:lower:]' <<<"$issue_id")"
  # ENG-79: source the canonical branch-name resolver instead of hand-rolling
  # the form `feature/<lower>-<slug>`. See git history for context (ENG-74).
  branch_name="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id" 2>/dev/null || printf '')"
  [[ -n "$branch_name" ]] \
    || die "render-prompt: branch-name.sh returned empty for $issue_id (Linear-API outage or bug-label resolution failed). Cannot render prompt without a canonical branch name."
  stage_summary_path="$(issue_dir "$issue_id")/stage-summary-${stage}.md"
  learned_rules_dir="$HARNESS_ROOT/learned-rules/$PROJECT_SLUG"
  # ENG-105 follow-up: per-issue prior-reviewing summary. Preserved across
  # reviewing → implementing transitions by _clear_current_stage_slots
  # (only the CURRENT stage's summary is cleared). Resolver reads this
  # path into the {review_findings} token for the implementing prompt;
  # other stages emit the same token but typically don't reference it.
  local review_findings_path
  review_findings_path="$(issue_dir "$issue_id")/stage-summary-reviewing.md"

  # Bind to the resolver-side globals before calling resolve_block_tokens.
  # The bash literal-substitution path (${var//pat/repl}) is glob-immune
  # for {token} shapes (no glob metachars in `{name}`) and metacharacter-
  # safe for resolver values containing sed-meta chars (titles,
  # descriptions) — replaces the prior python-or-sed branch.
  _RENDER_ISSUE_ID="$issue_id"
  _RENDER_ISSUE_ID_LOWER="$issue_id_lower"
  _RENDER_TITLE="$title"
  _RENDER_DESCRIPTION="$description"
  _RENDER_DATE="$date"
  _RENDER_SLUG="$slug"
  _RENDER_BRAINSTORM_FILE="$brainstorm_file"
  _RENDER_PLAN_FILE="$plan_file"
  _RENDER_BRANCH_NAME="$branch_name"
  _RENDER_STAGE_SUMMARY_PATH="$stage_summary_path"
  _RENDER_LEARNED_RULES_DIR="$learned_rules_dir"
  _RENDER_REVIEW_FINDINGS_PATH="$review_findings_path"
  # ENG-108: per-issue progress notebook path. Composes on
  # bin/common.sh::progress_md_path (exported per common.sh:400). The
  # resolver is path-shaped (D-001); the agent reads via Read at
  # dispatch time. Stage-conditional info-log below fires when the
  # file is absent on an implementing dispatch (D-003).
  _RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"
  if [[ "$stage" == "implementing" && ! -e "$_RENDER_PROGRESS_MD_PATH" ]]; then
    log "render-prompt: progress-md missing for $issue_id at $_RENDER_PROGRESS_MD_PATH (informational; agent's Read will note absence)"
  fi
  # ENG-87 review-iter-7 M9: bind _RENDER_DISPATCH_ID like the sibling
  # _RENDER_* globals so resolver test isolation is uniform across the
  # registry. Falls through to empty when PIPELINE_DISPATCH_ID is unset
  # (release-stage main() never reaches this stanza; direct test paths
  # set _RENDER_DISPATCH_ID directly).
  _RENDER_DISPATCH_ID="${PIPELINE_DISPATCH_ID-}"

  resolve_block_tokens "$block" | append_project_profile "$stage"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
