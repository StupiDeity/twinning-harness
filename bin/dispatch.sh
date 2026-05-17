#!/usr/bin/env bash
# Invoke the Claude Code CLI headlessly with a rendered prompt.
# Usage: dispatch.sh <stage> <prompt_file> [<log_file>]
# In PIPELINE_DRY_RUN=1, echoes what it would do without calling claude.
#
# CWD is the feature's worktree when called from run-local.sh (ENG-13 D-011),
# or the main repo root for legacy feature/* branches.
#
# Cost telemetry (ENG-26): when env var PIPELINE_ISSUE_ID is set, the
# stream-json renderer extracts the final `result` event and writes a
# six-field usage-<stage>.json into $issue_dir. Other callers (release,
# retrospective, mutex-test, dry-run-self-check) leave PIPELINE_ISSUE_ID
# unset and the renderer block is bypassed.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# _dispatch_cleanup — composed EXIT trap (ENG-131 D-001 + D-002).
# Single trap that:
#  1. Signals the cmd's process-group (D-002 pgrp reap of MCP orphans).
#     `_cmd_pgid` is set after the cmd subshell spawns; guards make this
#     no-op safely when cmd never spawned (die-before-spawn path).
#  2. Removes the per-issue capture file (D-001 cleanup).
#  3. Calls release_claude_mutex (preserves AC-TRAP-BEFORE-ACQUIRE
#     semantic — release on EVERY exit path between trap install and any
#     later die()).
# Integer-validate _cmd_pgid before `kill -- -$pgid` (defense against
# future regressions that could leave it empty / non-numeric).
_dispatch_cleanup() {
  if [[ -n "${_cmd_pgid:-}" && "$_cmd_pgid" =~ ^[0-9]+$ ]]; then
    kill -TERM -- "-$_cmd_pgid" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-$_cmd_pgid" 2>/dev/null || true
  fi
  if [[ -n "${_capture_path:-}" && -f "$_capture_path" ]]; then
    rm -f "$_capture_path"
  fi
  release_claude_mutex
}

# ─── Stream-json renderer (ENG-26 D-002) ─────────────────────────────────
# Reads NDJSON on stdin; emits prose-ish progress lines on STDOUT (so the
# caller's `tee "$log_file"` captures them); mirrors the raw NDJSON to a
# private capture file under $issue_dir; after the stream ends, extracts
# only six fields from the LAST type==result line and writes them to
# $usage_file at mode 0600 (umask 077).
#
# Args: $1 = usage_file, $2 = issue_dir.
#
# Tolerances:
#   - F2 (D-002): malformed NDJSON lines are silently dropped via
#     `fromjson? // empty`. One bad line cannot abort dispatch.
#   - D-010: missing result event → no usage file, soft-fail log line,
#     return 0. Cost telemetry is observability, not control flow.
#
# Defenses:
#   - SEC-001: tool_use input payloads never logged. Renderer emits
#     `[tool] <name>` only.
#   - SEC-002: usage file holds exactly six fields. session_id /
#     permission_denials / result text / modelUsage rollup never written.
#   - SEC-005: usage file written under `(umask 077; …)` so default-022
#     hosts cannot leave it world-readable.
#   - SEC-008: intermediate raw-NDJSON capture lives under $issue_dir
#     (per-issue trust scope), prefixed with `.` (artifact-scanner-invisible),
#     and is removed by a RETURN trap.
#   - SEC-010: C0 control chars stripped from agent text before logging
#     (defends against `\r[FAKE LOG]` log forging).
_render_and_capture_stream() {
  local usage_file="$1" issue_dir="$2" stage="${3:-}"
  local raw_capture="${issue_dir}/.raw-stream.ndjson.tmp"
  local violation_file="${issue_dir}/.transcript-violation-${stage}"
  # ENG-87: the envelope-validator sidecar persists across the RETURN
  # trap below so run-stage.sh::_validate_dispatch_envelope can scan
  # it post-dispatch. Idempotent pre-clean (D-008).
  local envelope_sidecar="${issue_dir}/.envelope-transcript-${stage}"
  rm -f "$violation_file" "$envelope_sidecar"
  trap 'rm -f "$raw_capture"' RETURN
  mkdir -p "$issue_dir"

  # Single jq fork for the whole stream (F4 P0). `tee` mirrors raw NDJSON
  # to $raw_capture; jq -nRr --unbuffered reads via `inputs` and emits
  # raw (unquoted) prose lines on stdout, letting the caller's
  # `tee "$log_file"` catch them. `fromjson? // empty` silently drops
  # malformed lines. The `-r` flag is load-bearing — without it jq
  # emits JSON-encoded strings (`"[claude] session=…"` with literal
  # quote bytes), breaking the D-002 / F3 prose-on-STDOUT contract.
  tee "$raw_capture" \
    | jq -nRr --unbuffered '
        def strip_ctrl: gsub("[\u0000-\u001f]"; " ");
        inputs
        | (fromjson? // empty) as $e
        | if   $e.type == "system" and $e.subtype == "init"
                 then "[claude] session=\($e.session_id[0:8]) model=\($e.model // "?")"
          elif $e.type == "assistant"
                 then (([$e.message.content[]? | select(.type=="text")    | .text  | strip_ctrl] | join(" "))
                      + ([$e.message.content[]? | select(.type=="tool_use") | "[tool] " + .name] | join(" ")))
          elif $e.type == "user"
                 then ([$e.message.content[]? | select(.type=="tool_result") | "[tool-result] " + ((.tool_use_id // "?")[0:12])] | join(" "))
          else empty
          end
        | select(. != "")
      '

  # Post-stream: extract only the six required fields from the LAST
  # type==result line. Allowlist by construction (SEC-002). On parse
  # failure, remove any partial and log soft-fail (D-010).
  local last_result
  last_result="$(grep '"type":"result"' "$raw_capture" 2>/dev/null | tail -1 || true)"
  if [[ -n "$last_result" ]]; then
    if ( umask 077; printf '%s' "$last_result" \
         | jq -c '{
             tokens_in:    (.usage.input_tokens // 0),
             tokens_out:   (.usage.output_tokens // 0),
             cache_read:   (.usage.cache_read_input_tokens // 0),
             cache_create: (.usage.cache_creation_input_tokens // 0),
             cost_usd:     (.total_cost_usd // 0),
             model:        ((.modelUsage // {}) | keys | (.[0] // ""))
           }' > "$usage_file" ); then
      log "[cost] result event captured: cost=$(jq -r '.cost_usd' "$usage_file" 2>/dev/null)"
    else
      log "[cost] no result event found in stream (post-extract jq failed; usage-<stage>.json not written)"
      rm -f "$usage_file"
    fi
  else
    # ENG-65 D-003: SIGTERM (or any path leaving no result event) loses
    # cost telemetry pre-fix. Sum per-message assistant.message.usage
    # so the metrics stream isn't biased toward zero on watchdog kills.
    # cost_usd is set to JSON null because total_cost_usd is only on the
    # result event; downstream `_cost_flags_for` coerces null → 0 via
    # `// 0`. The `partial: true` field is the on-disk discriminator the
    # retrospective reads to separate "captured under SIGTERM" from
    # "clean zero-cost dispatch."
    local _partial_json
    _partial_json="$(jq -nR '
      [inputs | (fromjson? // empty)] as $events
      | ($events | map(select(.type=="system" and .subtype=="init"))[0].model // "") as $model
      | ($events | map(select(.type=="assistant") | (.message.usage // {}))) as $usages
      | { tokens_in:    ($usages | map(.input_tokens // 0)             | add // 0),
          tokens_out:   ($usages | map(.output_tokens // 0)            | add // 0),
          cache_read:   ($usages | map(.cache_read_input_tokens // 0)  | add // 0),
          cache_create: ($usages | map(.cache_creation_input_tokens // 0) | add // 0),
          cost_usd:     null,
          model:        $model,
          partial:      true }
    ' < "$raw_capture" 2>/dev/null || printf '')"
    local _partial_sum=0
    if [[ -n "$_partial_json" ]]; then
      _partial_sum="$(printf '%s' "$_partial_json" | jq -r '(.tokens_in + .tokens_out)' 2>/dev/null || printf 0)"
    fi
    if [[ -n "$_partial_json" && "$_partial_sum" =~ ^[0-9]+$ && "$_partial_sum" -gt 0 ]]; then
      ( umask 077; printf '%s' "$_partial_json" > "$usage_file" )
      log "[cost] partial usage captured (no result event; SIGTERM-style termination): tokens_in+out=${_partial_sum}"
    else
      log "[cost] no result event found in stream (soft fail; usage-<stage>.json not written)"
    fi
  fi

  # ENG-87: persist a copy of the transcript for the post-dispatch
  # envelope validator. The trap above removes $raw_capture on RETURN;
  # the validator (run-stage.sh::_validate_dispatch_envelope) needs an
  # inspection target after dispatch.sh exits. Same dir as the existing
  # .transcript-violation-${stage} sidecar.
  if [[ -s "$raw_capture" && -n "$stage" ]]; then
    cp "$raw_capture" "$envelope_sidecar" 2>/dev/null || true
  fi

  # ENG-43: defense-in-depth assertion. Tool lane should already deny
  # Bash(gh:*) for implementing (allowed_tools_for case above); this is the
  # second line of defense if the lane is ever misconfigured. Gated on
  # stage == "implementing" only — other stages observe no behavior change.
  if [[ "$stage" == "implementing" ]]; then
    local _matched_cmd
    if _matched_cmd="$(assert_no_tool_invocation "$raw_capture" "gh pr create")"; then
      :   # rc 0: no match, fall through
    else
      printf '%s\n' "$_matched_cmd" > "$violation_file"
      log "[assert] implement-stage transcript invoked forbidden tool: ${_matched_cmd}"
      return 22
    fi
  fi

  # ENG-71: defense-in-depth assertion. Build's tool lane denies
  # Bash(git checkout:*), Bash(git switch:*), Bash(git pull:*), and
  # Bash(git reset:*) by omission (only Bash(git fetch:*),
  # Bash(git clone:*), Bash(git rebase:*) are permitted; verified at
  # allowed_tools_for "building" in this file). This is the second line
  # of defense if the lane's prefix-matcher is bypassed (ENG-61 observed;
  # chained-command hypothesis in ENG-71 brainstorm §1). Stage-gated to
  # "building" only — other stages observe no behavior change. Modulo the
  # inherited `startswith` blind spot on chained commands (e.g., `git fetch
  # origin main && git checkout main` starts with `git fetch` and bypasses
  # this loop's matcher); D-003 in run-stage.sh is the catch-net for that
  # surface (ENG-71 §7 / O-4).
  if [[ "$stage" == "building" ]]; then
    local _pat _matched_cmd
    for _pat in 'git checkout' 'git switch' 'git pull' 'git reset'; do
      if _matched_cmd="$(assert_no_tool_invocation "$raw_capture" "$_pat")"; then
        :   # rc 0: no match, fall through to next pattern
      else
        printf '%s\n' "$_matched_cmd" > "$violation_file"
        log "[assert] build-stage transcript invoked forbidden tool: ${_matched_cmd}"
        return 26
      fi
    done
  fi
  # ENG-66: forbid agent-side branch-creation across ALL stages.
  # AGENT_PROMPTS.md §3 rule 2 lists exactly these four banned forms.
  # The orchestrator has already created and checked out {branch_name}
  # in the per-issue worktree; an agent that creates a new branch is
  # forking off the canonical path and will (a) push to a wrong-named
  # remote ref, (b) trip the legacy feature/* coexistence path in
  # run-local.sh (ENG-67), (c) make scope-check evaluate against the
  # wrong worktree. Cross-stage by design (mirrors ENG-68's shape).
  # Inherits the `startswith` chained-command blind spot (BC6 fixture).
  local _branch_pattern _matched_branch
  for _branch_pattern in \
      "git checkout -b" \
      "git checkout -B" \
      "git branch -m" \
      "git switch -c"; do
    if _matched_branch="$(assert_no_tool_invocation "$raw_capture" "$_branch_pattern")"; then
      :   # rc 0: no match, fall through to next pattern
    else
      printf '%s\n' "$_matched_branch" > "$violation_file"
      log "[assert] stage=$stage transcript invoked forbidden branch-creation form: ${_matched_branch}"
      return 23
    fi
  done
  # ENG-68 D-003: forbid `core.bare`-touching git forms across ALL stages.
  # Defense-in-depth on top of D-002 (the implementing/ui base allowlist
  # no longer carries Bash(git:*)). Catches future allowlist drift on any
  # stage AND covers stages whose base allowlist still has wide Bash(git:*)
  # (qa). The five patterns cover:
  #   1. `git config core.bare ...` (the literal write)
  #   2. `git init --bare`           (creates bare init in pwd)
  #   3. `git --bare ...`            (top-level option that flips per-invocation)
  #   4. `git config --add core.bare ...` (rare but valid syntax)
  #   5. `git -c core.bare=...`      (top-level config override)
  # `assert_no_tool_invocation`'s startswith semantics match each form's
  # leading prefix exactly; compound shells (`git status; git config core.bare`)
  # are an acknowledged residual gap (brainstorm OQ-3).
  local _git_pattern _matched_git
  for _git_pattern in \
      "git config core.bare" \
      "git init --bare" \
      "git --bare" \
      "git config --add core.bare" \
      "git -c core.bare="; do
    if _matched_git="$(assert_no_tool_invocation "$raw_capture" "$_git_pattern")"; then
      :   # rc 0: no match, fall through to next pattern
    else
      printf '%s\n' "$_matched_git" > "$violation_file"
      log "[assert] stage=$stage transcript invoked forbidden git form: ${_matched_git}"
      return 13
    fi
  done
  # ENG-109: forbid Write-tool truncation of progress.md across
  # ALL stages. The append-only contract of progress.md
  # (docs/runbooks/progress-md.md §3) is a CONVENTION, not a
  # filesystem ACL; this detective is the catch-net for an agent
  # that uses Write where Edit-with-append (or
  # `cat >> {progress_md_path} <<'EOF'`) was the correct shape.
  # Reuses rc=29 (dispatch-envelope-violation) per the brainstorm
  # D-004 reading "the envelope is the agent's tool-use contract
  # surface" — operators inspecting $violation_file see the
  # matched file_path string for triage.
  local _matched_write
  if _matched_write="$(assert_no_write_to_path "$raw_capture" "/progress.md")"; then
    :   # rc 0: no match, fall through
  else
    printf '%s\n' "$_matched_write" > "$violation_file"
    log "[assert] stage=$stage transcript invoked forbidden Write on progress.md: ${_matched_write}"
    return 29
  fi
  # ENG-106: filesystem detective — confirm the plan agent appended
  # one well-formed progress.md H2 entry stamped with the current
  # PIPELINE_DISPATCH_ID. Stage-gated to "planning" only (other stages
  # have no contractual writer yet — see brainstorm OQ-3). Unlike the
  # transcript-scan detectives above, this is a FILESYSTEM check
  # (brainstorm D-005). Helper defined directly below this function;
  # writes its diagnostic to $violation_file and returns 0 / 31.
  #
  # M2 guard: skip if no result event so rc=124 (gtimeout) wins; with result
  # event, missing progress.md is a real protocol violation — rc=31 is correct
  # even when SIGKILL races post-result (agent completed its turn).
  if [[ "$stage" == "planning" && -n "$last_result" ]]; then
    if ! _assert_progress_md_entry "$issue_dir" "$violation_file"; then
      return 31
    fi
  fi
}

# ENG-106 — stage-gated to planning; rc=31 maps to progress-md-entry-missing
# in failure_outcome_for_exit. Single-dash on PIPELINE_DISPATCH_ID: ENG-46
# idiom, consistent with other callers (var not on the secret regex).
_assert_progress_md_entry() {
  local issue_dir="$1" violation_file="$2"
  local progress_path entry_count
  progress_path="${issue_dir}/progress.md"
  if [[ ! -s "$progress_path" ]]; then
    printf 'progress.md missing entirely (expected one H2 stamped %s)\n' \
      "${PIPELINE_DISPATCH_ID-<empty>}" > "$violation_file"
    log "[assert] plan-stage progress.md missing for dispatch_id=${PIPELINE_DISPATCH_ID-<empty>}"
    return 31
  fi
  entry_count="$(grep -c "^## ${PIPELINE_DISPATCH_ID-} - " "$progress_path" 2>/dev/null || printf 0)"
  if [[ "$entry_count" != "1" ]]; then
    printf 'progress.md: expected exactly 1 entry for dispatch_id=%s, found %s\n' \
      "${PIPELINE_DISPATCH_ID-<empty>}" "$entry_count" > "$violation_file"
    log "[assert] plan-stage progress.md entry count for ${PIPELINE_DISPATCH_ID-<empty>}: $entry_count (expected 1)"
    return 31
  fi
  return 0
}

# ENG-48 isolation: platform tools whose call from a headless dispatch
# either demonstrated a runaway (ScheduleWakeup → 2026-04-28 ENG-45 7h
# wedge) or could enable one (subagent escape, plan-mode entry, cron
# creation, network egress not guarded by per-stage allowlists). The
# --allowed-tools flag is a permission allowlist, not an availability
# list — these tools are still callable unless explicitly denied.
disallowed_platform_tools() {
  # Excluded from this list: Task / WebFetch. Task may alias the Agent tool
  # that ui/review/qa/retrospective stages legitimately allow; WebFetch is
  # in brainstorm's allowed-tools. Denials win over allows in claude's
  # tool-resolution, so denying either would break working stages.
  printf 'ScheduleWakeup TodoWrite Skill EnterPlanMode ExitPlanMode EnterWorktree ExitWorktree RemoteTrigger PushNotification CronCreate CronDelete CronList Monitor WebSearch ToolSearch AskUserQuestion'
}

# ENG-51: read a per-stage tool-extension list from CONFIG and emit a
# comma-joined string ready to splice onto the hardcoded base. Returns
# empty string when the key is missing, the value isn't an array, or
# the array contains no strings. Defensive jq filter — non-string
# entries are silently dropped rather than poisoning the allowlist.
_dispatch_tools_extras() {
  local stage="$1"
  [[ -f "${CONFIG:-}" ]] || return 0
  jq -r --arg s "$stage" '
    (.dispatch.tools[$s] // []) as $arr
    | if ($arr | type) == "array"
      then $arr | map(select(type == "string")) | join(",")
      else "" end
  ' "$CONFIG" 2>/dev/null || true
}

# ENG-94: read the per-stage Tool allowlist block from the slug-aware
# project profile and emit a comma-joined string ready to splice into
# allowed_tools_for's base+extras composition. Sibling of
# _dispatch_tools_extras; same soft-fail contract (empty string on
# missing/malformed input, no die).
#
# Resolution: $HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md
#
# Fail-soft branches (D-3):
#   - file absent OR HARNESS_ROOT/PROJECT_SLUG empty → empty, NO warning.
#   - frontmatter missing OR schema_version != 2 → empty + ONE log warn.
#   - schema_version 2, '## Tool allowlist' section absent → empty + ONE log warn.
#   - section present, stage line absent OR sub-bullets empty/"(none)" → empty, NO warn.
#   - awk parse failure → empty + ONE log warn.
#
# SEC (D-8): awk-side hygiene rejects Bash patterns containing shell
# metacharacters (;, &, |, `, $(, >, <, newline, paren-imbalance) as
# defense-in-depth against a profile commit that smuggles a chained
# command into the allowlist. The warning text NEVER includes the
# matched pattern text (ENG-46 secret-handling) — the pattern could
# legitimately contain a $VAR reference that log's expansion would
# leak into the per-stage transcript.
_dispatch_tools_from_profile() {
  local stage="$1"
  [[ -n "${HARNESS_ROOT:-}" && -n "${PROJECT_SLUG:-}" ]] || return 0
  local profile_path="${HARNESS_ROOT}/learned-rules/${PROJECT_SLUG}/project-profile.md"
  [[ -f "$profile_path" ]] || return 0

  # Schema-version gate. Must be exactly `schema_version: 2` inside
  # frontmatter. Anything else (missing frontmatter, v1, malformed)
  # falls through with one warning.
  local has_v2
  has_v2="$(awk '
    NR==1 && $0=="---" { in_fm=1; next }
    in_fm && $0=="---" { exit }
    in_fm && /^schema_version:[[:space:]]+2[[:space:]]*$/ { print "yes"; exit }
  ' "$profile_path" 2>/dev/null)"
  if [[ "$has_v2" != "yes" ]]; then
    log "[allowed-tools] project-profile.md schema_version != 2; Tool allowlist not loaded for stage=$stage"
    return 0
  fi

  # Section presence gate. If '## Tool allowlist' header is absent,
  # warn and fall through.
  if ! grep -qE '^## Tool allowlist[[:space:]]*$' "$profile_path"; then
    log "[allowed-tools] project-profile.md::## Tool allowlist section not found; stage=$stage"
    return 0
  fi

  # Extract this stage's patterns. State machine: track section presence,
  # track current stage (top-level `- <stage>:` bullets), emit any
  # sub-bullet matching `^  - `Bash(...)`` for the requested stage.
  # D-8 hygiene rejects shell-metachar payloads. BSD-awk compatible
  # (no match($0, /<pat>/, m) capture groups — capture via sub()
  # prefix-strip instead).
  local result
  result="$(awk -v STAGE="$stage" '
    BEGIN { in_section=0; current_stage=""; first=1 }
    # Strip CRLF for cross-platform editor tolerance.
    { sub(/\r$/, "") }
    # Enter the Tool allowlist section.
    /^## Tool allowlist[ \t]*$/ { in_section=1; next }
    # Any subsequent H2 closes the section.
    in_section && /^## / { in_section=0; next }
    !in_section { next }
    # Top-level `- <stage>:` bullets switch the current stage.
    /^- [a-z]+:/ {
      line = $0
      sub(/^- /, "", line)
      sub(/:.*$/, "", line)
      current_stage = line
      next
    }
    # Sub-bullet `  - `Bash(...)`` lines belong to current_stage.
    current_stage == STAGE && /^  - `Bash\(/ {
      line = $0
      # Strip leading "  - `"
      sub(/^  - `/, "", line)
      # Strip trailing "`" plus anything after (paranoia).
      sub(/`.*$/, "", line)
      # line is now "Bash(<inner>)". Extract <inner> for hygiene.
      inner = line
      sub(/^Bash\(/, "", inner)
      sub(/\)$/, "", inner)
      # D-8 hygiene: reject shell metachars and command-substitution.
      if (inner ~ /[;&|`<>]/) next
      if (inner ~ /\$\(/) next
      if (inner ~ /\n/)   next
      # Paren-balance check.
      tmp = inner; opens = 0; closes = 0
      while (match(tmp, /\(/)) { opens++; tmp = substr(tmp, RSTART+1) }
      tmp = inner
      while (match(tmp, /\)/)) { closes++; tmp = substr(tmp, RSTART+1) }
      if (opens != closes) next
      # Emit Bash(<inner>) joined by commas.
      if (!first) printf ","
      printf "Bash(%s)", inner
      first = 0
    }
  ' "$profile_path" 2>/dev/null)" || {
    log "[allowed-tools] awk parse failure for stage=$stage"
    return 0
  }

  printf '%s' "$result"
}

allowed_tools_for() {
  # Every stage gets BOTH `Bash(bash .pipeline/bin/linear.sh:*)` AND
  # `Bash(bash bin/linear.sh:*)` so agents can post Linear comments
  # regardless of whether the worktree has the harness symlinked at
  # `.pipeline/` (target repos) or carries the harness scripts directly
  # at `bin/` (the harness driving itself). Without the second path, the
  # harness-self path leaves agents with no allowed way to post their
  # mandatory end-of-stage Linear comment, and they halt with a
  # protocol-violation/no-marker. MCP Linear remains available in
  # parallel; this guarantees a bash fallback works on either layout.
  # Same dual-path pattern applied to slug-aware bin/* invocations
  # (slack.sh, guards.sh, metrics.sh) for consistency.
  #
  # ENG-51: the hardcoded base preserves Tauri's behavior. Per-stage
  # extras come from config.json::dispatch.tools.<stage>[] and are
  # appended (not replaced) so a non-Tauri target can grant `pytest`,
  # `go test`, `bash bin/*-test.sh`, etc., without rewriting the base.
  local base
  case "$1" in
    # Canonical gerund-form stage names.
    brainstorming)  base='Read,Write,Edit,Grep,Glob,TaskCreate,WebFetch,Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
    planning)       base='Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git log:*),Bash(git diff:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
    implementing)   base='Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git show:*),Bash(git add:*),Bash(git rm:*),Bash(git mv:*),Bash(git restore:*),Bash(git commit:*),Bash(git checkout:*),Bash(git switch:*),Bash(git fetch:*),Bash(git pull:*),Bash(git push:*),Bash(git rebase:*),Bash(git merge:*),Bash(git branch:*),Bash(git stash:*),Bash(git ls-files:*),Bash(git rev-parse:*),Bash(git rev-list:*),Bash(git for-each-ref:*),Bash(git tag:*),Bash(git describe:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
    ui)             base='Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git show:*),Bash(git add:*),Bash(git rm:*),Bash(git mv:*),Bash(git restore:*),Bash(git commit:*),Bash(git checkout:*),Bash(git switch:*),Bash(git fetch:*),Bash(git pull:*),Bash(git push:*),Bash(git rebase:*),Bash(git merge:*),Bash(git branch:*),Bash(git stash:*),Bash(git ls-files:*),Bash(git rev-parse:*),Bash(git rev-list:*),Bash(git for-each-ref:*),Bash(git tag:*),Bash(git describe:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
    reviewing)      base='Read,Write,Grep,Glob,TaskCreate,Agent,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr list:*),Bash(gh pr review:*),Bash(gh pr comment:*),Bash(gh issue create:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),Bash(bash .pipeline/bin/guards.sh:*),Bash(bash bin/guards.sh:*)' ;;
    qa)             base='Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(jq:*),Bash(awk:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh issue create:*),Bash(gh issue list:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),Bash(bash .pipeline/bin/guards.sh:*),Bash(bash bin/guards.sh:*)' ;;
    building)       base='Read,Write,Grep,Glob,Bash(git fetch:*),Bash(git clone:*),Bash(git rebase:*),Bash(gh run:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr checks:*),Bash(gh pr edit:*),Bash(gh pr merge:*),Bash(jq:*),Bash(mktemp:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),Bash(bash .pipeline/bin/slack.sh:*),Bash(bash bin/slack.sh:*)' ;;
    released)       base='Read,Grep,Glob,Bash(git log:*),Bash(git show:*),Bash(git rev-list:*),Bash(git describe:*),Bash(gh release view:*),Bash(gh release list:*),Bash(jq:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),Bash(bash .pipeline/bin/slack.sh:*),Bash(bash bin/slack.sh:*),Bash(bash .pipeline/bin/metrics.sh:*),Bash(bash bin/metrics.sh:*)' ;;
    retrospective)  base='Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git log:*),Bash(git diff:*),Bash(git show:*),Bash(git rev-list:*),Bash(git describe:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),Bash(bash .pipeline/bin/guards.sh:*),Bash(bash bin/guards.sh:*),Bash(bash .pipeline/bin/metrics.sh:*),Bash(bash bin/metrics.sh:*)' ;;
    *)              die "no allowed-tools profile for stage: $1" ;;
  esac
  # ENG-94 composition order (D-2, D-4): base (case arm) → profile
  # (auto-discovered from learned-rules/<slug>/project-profile.md)
  # → extras (operator-curated via .pipeline-config/config.json::
  # dispatch.tools.<stage>[]). Empty segments are elided so no stray
  # commas leak into the --allowed-tools argv (claude's matcher is
  # delimiter-strict). The helper is invoked for EVERY stage; stages
  # whose profile section is `(none)` or absent return empty and
  # collapse to base+extras (pre-ENG-94 behavior preserved).
  local profile_tools
  profile_tools="$(_dispatch_tools_from_profile "$1")"
  local extras
  extras="$(_dispatch_tools_extras "$1")"
  local result="$base"
  [[ -n "$profile_tools" ]] && result="${result},${profile_tools}"
  [[ -n "$extras"        ]] && result="${result},${extras}"
  printf '%s' "$result"
}

main() {
  local stage="${1:-}" prompt_file="${2:-}" log_file="${3:-}"
  [[ -n "$stage" && -n "$prompt_file" ]] || die "usage: dispatch.sh <stage> <prompt_file> [<log_file>]"
  [[ -f "$prompt_file" ]] || die "prompt file not found: $prompt_file"

  local tools
  tools="$(allowed_tools_for "$stage")"

  # Resolve the per-stage usage-file path. Empty string when
  # PIPELINE_ISSUE_ID is unset (release / retrospective / dry-run-self-check
  # / mutex-test): the renderer block is then bypassed and the live pipe
  # keeps its pre-ENG-26 shape. Resolution lives inside main() because
  # $stage is local to main (D-012 / F-IT3-001).
  local usage_file=""
  local issue_state_dir=""
  if [[ -n "${PIPELINE_ISSUE_ID:-}" ]]; then
    issue_state_dir="$(issue_dir "$PIPELINE_ISSUE_ID")"
    usage_file="${issue_state_dir}/usage-${stage}.json"
    # Pre-emptive cleanup so a missing file is the canonical "no usage to
    # report" signal — applies to BOTH branches below (E-04 / D-006).
    rm -f "$usage_file"
  fi

  # Install the release trap BEFORE the acquire so a die() between the two
  # cannot leak the slot. release_claude_mutex is a no-op when
  # _ACQUIRED_SLOT_DIR is empty, so arming the trap pre-acquire is safe.
  trap _dispatch_cleanup EXIT
  acquire_claude_mutex

  local denies
  denies="$(disallowed_platform_tools)"

  # ENG-48/ENG-65 watchdog budget. Brainstorming/planning iterate through
  # ≤2 persona-review passes that legitimately span >30 min; everything
  # else stays at the historical 30-min cap. Resolution precedence:
  #   1. orchestrator.dispatch_timeout_minutes_per_stage[<stage>]  (ENG-65)
  #   2. orchestrator.dispatch_timeout_minutes                     (ENG-48)
  #   3. per-stage built-in default (60 for brainstorm/plan, 30 otherwise)
  # A non-integer value at layer 1 or 2 falls through. A 0 minute resolved
  # value would disable the wrapper (gtimeout's no-timeout sentinel) so it
  # is rejected explicitly, restoring the per-stage built-in default. The
  # CONFIG read is defensive — the mutex-test contract assumes dispatch.sh
  # needs TARGET_REPO only for the directory-existence check, not for a
  # real config.json.
  local timeout_minutes
  case "$stage" in
    brainstorming|planning) timeout_minutes=60 ;;
    *)                      timeout_minutes=30 ;;
  esac
  if [[ -f "$CONFIG" ]]; then
    local _cfg_minutes
    _cfg_minutes="$(jq -r --arg s "$stage" \
      '.orchestrator.dispatch_timeout_minutes_per_stage[$s] // empty' \
      "$CONFIG" 2>/dev/null || true)"
    if [[ -z "$_cfg_minutes" ]]; then
      _cfg_minutes="$(jq -r '.orchestrator.dispatch_timeout_minutes // empty' "$CONFIG" 2>/dev/null || true)"
    fi
    [[ -n "$_cfg_minutes" && "$_cfg_minutes" =~ ^[0-9]+$ ]] && timeout_minutes="$_cfg_minutes"
  fi
  if (( timeout_minutes < 1 )); then
    case "$stage" in
      brainstorming|planning) timeout_minutes=60 ;;
      *)                      timeout_minutes=30 ;;
    esac
  fi
  local timeout_seconds=$(( timeout_minutes * 60 ))

  # ENG-81 Phase 1: optional gtime -v wrapper for resource-sample metric.
  # `gtime` ships in Homebrew's `gnu-time` package (NOT `coreutils` — that
  # package only ships gtimeout). Discovery is best-effort; absence
  # degrades to "no metric emit" and is non-fatal so hosts that haven't
  # installed gnu-time keep dispatching.
  #
  # _PIPELINE_GTIME_DISABLED=1 (test-only) skips discovery so the
  # degraded-mode test (G8.B) is deterministic on hosts that DO have
  # gnu-time installed — PATH-strip alone is fragile when the test PATH
  # has to keep /opt/homebrew for jq/awk reachability.
  local _gtime_bin="" _gtime_out=""
  if [[ "${_PIPELINE_GTIME_DISABLED:-0}" == "1" ]]; then
    log "[dispatch-resource-sample] gtime discovery forced off (_PIPELINE_GTIME_DISABLED=1)"
  elif command -v gtime >/dev/null 2>&1; then
    _gtime_bin="$(command -v gtime)"
    _gtime_out="$(mktemp -t pipeline-gtime-XXXXXX)"
  else
    log "[dispatch-resource-sample] gtime not on PATH; resource sample will be skipped (install: brew install gnu-time)"
  fi

  if [[ "$PIPELINE_DRY_RUN" == "1" ]]; then
    # ENG-103: inline the --model flag when PIPELINE_DISPATCH_MODEL is set so
    # the dispatch-test.sh fixture can grep for it. The env-var name does NOT
    # match secret-probe-lint's regex (no KEY/TOKEN/SECRET/ANTHROPIC/GITHUB/
    # LINEAR substring), so `${VAR:-}` is ENG-46-clean here (mirrors
    # _cfg_minutes' presence check at dispatch.sh:481).
    local _dry_model_seg=""
    if [[ -n "${PIPELINE_DISPATCH_MODEL:-}" ]]; then
      _dry_model_seg=" --model $PIPELINE_DISPATCH_MODEL"
    fi
    log "[DRY_RUN] would invoke: gtimeout --signal=TERM --kill-after=10 ${timeout_seconds} claude -p --output-format stream-json --verbose${_dry_model_seg} --setting-sources project,local --disable-slash-commands --disallowed-tools \"$denies\" --allowed-tools \"$tools\" < $prompt_file"
    log "[DRY_RUN] prompt preview (first 500 chars):"
    head -c 500 "$prompt_file" >&2
    printf '\n' >&2
    return 0
  fi

  require_bin claude gtimeout
  # Auth: ANTHROPIC_API_KEY for CI/headless; claude CLI subscription session for local.
  # Don't require either here — claude errors at invocation time if no auth is available.
  # gtimeout: GNU coreutils. macOS operators install via `brew install coreutils`.

  # ENG-41 T3: set the agent lane only for the claude -p subprocess.
  # Any orchestrator-side Linear writes above (none currently, but guarding for
  # future additions) stay in the default orchestrator lane.
  # ENG-26: `--output-format stream-json --verbose` emits one NDJSON event
  # per message and a final `{"type":"result", …}` carrying total_cost_usd
  # and the aggregated `usage` block. The renderer extracts cost; the
  # operator-facing log keeps prose-ish progress lines via the renderer's
  # stdout (D-002 / F3 / F4).
  # ENG-48: --setting-sources project,local skips ~/.claude (so the
  # operator's installed plugins and SessionStart hooks don't fire);
  # --disable-slash-commands blocks skill auto-load (using-superpowers,
  # /loop, etc.); --disallowed-tools denies platform tools that aren't
  # in any stage's allowlist and could enable a runaway (ScheduleWakeup
  # was the demonstrated escape on 2026-04-28). gtimeout wraps claude
  # with a wall-clock budget — on expiry SIGTERM is sent, then SIGKILL
  # after 10s if claude ignores the term. gtimeout's exit 124 propagates
  # via the pipeline (set -o pipefail) so failure_outcome_for_exit can
  # classify it as dispatch-timeout.
  # ENG-87: PIPELINE_DISPATCH_ID is the per-dispatch glue carried into the
  # agent's subshell so its `bash bin/linear.sh add-comment` calls auto-
  # inject the `<!-- meta: dispatch id=… stage=… -->` marker. PIPELINE_STAGE
  # is the gerund-form stage name used by the auto-inject marker. Both are
  # ${VAR-} (single-dash) so the test path that invokes dispatch.sh
  # directly (without going through run-stage.sh::main) propagates an
  # empty value rather than a "literal-when-set" leak — neither name
  # matches secret-probe-lint.sh's regex, so this is lint-clean.
  # ENG-81: the optional gtime prefix slots BETWEEN the env block and
  # gtimeout. Order: env <vars> | gtime -v -o <tmp> | gtimeout … | claude.
  # gtime captures the resource sample of the entire wrapped tree (gtimeout
  # + claude), giving an honest "what did one dispatch cost" baseline.
  local cmd=(env PIPELINE_WRITER=agent
    "PIPELINE_DISPATCH_ID=${PIPELINE_DISPATCH_ID-}"
    "PIPELINE_STAGE=$stage"
  )
  if [[ -n "$_gtime_bin" ]]; then
    cmd+=("$_gtime_bin" -v -o "$_gtime_out")
  fi
  cmd+=(gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
    claude -p
    --output-format stream-json --verbose
  )
  # ENG-103: when PIPELINE_DISPATCH_MODEL is set, splice `--model <value>`
  # as two distinct argv elements (a single `cmd+=(--model "$VAR")` correctly
  # appends two array elements; `${VAR:+--model "$VAR"}` would collapse the
  # value into one element with shell word-splitting). The env-var name does
  # NOT match secret-probe-lint's regex, so the `${VAR:-}` presence check
  # is ENG-46-clean (mirrors _cfg_minutes at line 481).
  if [[ -n "${PIPELINE_DISPATCH_MODEL:-}" ]]; then
    cmd+=(--model "$PIPELINE_DISPATCH_MODEL")
  fi
  cmd+=(
    --setting-sources project,local
    --disable-slash-commands
    --disallowed-tools "$denies"
    --allowed-tools "$tools"
  )
  # ENG-131 D-001 + D-002: sequential capture file + perl-setsid wrap of cmd.
  # cmd's stdout lands in a per-issue ndjson file; the renderer reads it
  # post-process (D-001 file-decoupling — no upstream pipe, so MCP orphans
  # holding inherited fd1 cannot block our reader). perl execs into setsid
  # then the gtimeout/claude chain so the wrapped tree is its own session +
  # pgrp leader; $! is that leader's PID. _dispatch_cleanup (installed at
  # the pre-acquire trap above) signals the pgrp on EXIT. The renderer's
  # internal `tee | jq` pipe (line ~66) is preserved — `tee` is a
  # short-lived non-spawning writer, distinct from the long-lived MCP-
  # descendant tree the outer pipe used to host.
  local _capture_path=""
  if [[ -n "$issue_state_dir" ]]; then
    _capture_path="${issue_state_dir}/.cmd-capture-${stage}.ndjson.tmp"
    ( umask 077; : > "$_capture_path" )    # pre-clean stale (EC-1b)
  else
    _capture_path="$( umask 077; mktemp -t pipeline-cmd-XXXXXX )"
  fi

  local dispatch_rc=0
  local _cmd_pgid=""
  if [[ -n "$log_file" ]]; then
    mkdir -p "$(dirname "$log_file")"
    log "dispatching stage=$stage, log=$log_file"
  else
    log "dispatching stage=$stage"
  fi

  ( exec /usr/bin/perl -e 'use POSIX qw(setsid); setsid; exec @ARGV' \
      "${cmd[@]}" < "$prompt_file" > "$_capture_path" ) &
  _cmd_pgid=$!
  if ! [[ "$_cmd_pgid" =~ ^[0-9]+$ ]]; then
    log "[dispatch] _cmd_pgid not numeric ($_cmd_pgid); pgrp cleanup disabled"
    _cmd_pgid=""
  fi
  wait "$_cmd_pgid" || dispatch_rc=$?

  local render_rc=0
  if [[ -n "$usage_file" && -n "$issue_state_dir" ]]; then
    # Renderer prose (and raw stream-json on the no-renderer branch) lands in
    # the per-stage log only. Letting it bubble up to local-*.log via `tee`
    # duplicates every [tool] / [tool-result] line into the orchestrator's
    # day-log, which (post-ENG-26 stream-json renderer) made local-*.log
    # nearly unreadable on busy days.
    if [[ -n "$log_file" ]]; then
      _render_and_capture_stream "$usage_file" "$issue_state_dir" "$stage" \
        < "$_capture_path" > "$log_file" || render_rc=$?
    else
      _render_and_capture_stream "$usage_file" "$issue_state_dir" "$stage" \
        < "$_capture_path" || render_rc=$?
    fi
  else
    # No-renderer arms (ungated callers — release / retrospective /
    # mutex-test / dry-run-self-check): forward captured ndjson to log_file
    # (if set) or stdout.
    if [[ -n "$log_file" ]]; then
      cat "$_capture_path" > "$log_file" 2>/dev/null || true
    else
      cat "$_capture_path" 2>/dev/null || true
    fi
  fi

  # Renderer rc takes precedence — mirrors today's pipefail "rightmost
  # non-zero" semantics where renderer violations 22/23/26/29/31 override
  # gtimeout's 124 when both fire.
  if (( render_rc != 0 )); then
    dispatch_rc=$render_rc
  fi

  # Preserve pre-ENG-131 behavior: ENG-81 metric block + clean function exit
  # are gated on dispatch_rc == 0. Non-zero exits early with rc; the EXIT
  # trap (_dispatch_cleanup) reaps the capture file and the pgrp regardless.
  if (( dispatch_rc != 0 )); then
    exit "$dispatch_rc"
  fi

  # ENG-81 Phase 1: parse gtime -v output and emit dispatch-resource-sample
  # metric. Best-effort — a missing/empty file, missing fields, or a
  # metrics.sh failure must NOT propagate to dispatch's exit code.
  # PIPELINE_ISSUE_ID is the same gate the cost-renderer uses for the
  # usage-<stage>.json write; ungated callers (release / retrospective /
  # mutex-test / dry-run-self-check) don't have an issue dir to attribute
  # the sample to, so they skip.
  if [[ -n "$_gtime_out" && -s "$_gtime_out" && -n "${PIPELINE_ISSUE_ID:-}" ]]; then
    local _wall_raw _wall_seconds _rss_kb _cpu_pct
    _wall_raw="$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$_gtime_out" | head -1)"
    # gtime emits wall in `h:mm:ss`, `m:ss.ff`, or `ss.ff`. Normalise
    # to total seconds so downstream consumers (status.sh, retro) can
    # `tonumber` the field.
    _wall_seconds="$(awk -F: -v v="$_wall_raw" 'BEGIN {
      n = split(v, p, /:/)
      if (n == 3)      printf "%.2f\n", p[1]*3600 + p[2]*60 + p[3]
      else if (n == 2) printf "%.2f\n", p[1]*60 + p[2]
      else if (n == 1) printf "%.2f\n", p[1]+0
    }')"
    _rss_kb="$(awk -F': ' '/Maximum resident set size/ {print $2}' "$_gtime_out" | head -1)"
    _cpu_pct="$(awk -F': ' '/Percent of CPU this job got/ {print $2}' "$_gtime_out" | tr -d '%' | head -1)"
    bash "$SCRIPT_DIR/metrics.sh" dispatch-resource-sample \
      "$PIPELINE_ISSUE_ID" "$stage" measured 0 \
      "wall_seconds=${_wall_seconds:-?} max_rss_kb=${_rss_kb:-?} cpu_pct=${_cpu_pct:-?}" \
      || log "[dispatch-resource-sample] metric emit failed (non-blocking)"
  fi
  # `if` form (not `[[ ]] && rm`) — when `_gtime_out` is empty the bare
  # `[[ -n "" ]]` returns rc=1 as the function's last statement, which
  # `set -euo pipefail` (common.sh) propagates as dispatch.sh exit 1.
  # run-stage.sh classifies any unrecognized non-zero rc as exit 20 →
  # retry-immediately, halting after 3 ticks even on a clean agent run.
  if [[ -n "$_gtime_out" ]]; then rm -f "$_gtime_out"; fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
