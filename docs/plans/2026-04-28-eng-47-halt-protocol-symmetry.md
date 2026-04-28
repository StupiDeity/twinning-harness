---
linear: ENG-47
date: 2026-04-28
topic: Halt protocol symmetry — atomic operator resume, generalized pipeline-wait, marker-emission compliance, stage applicability + idempotent PR creation
depends_on: [ENG-45]
---

# Plan — ENG-47 halt protocol symmetry

Implements the design in
`docs/brainstorms/2026-04-28-halt-protocol-symmetry-design.md`.

## Goal

Land one PR off `main` (after ENG-45 merges) that closes the halt-protocol
asymmetry surfaced today across ENG-26 / ENG-24 / ENG-45. After this lands:

- A pipeline `pipeline-wait` exit on **any** stage that opts in (via the
  per-stage→reasons allow-list) re-dispatches the same stage on the next
  tick, bounded by a per-stage budget. Build keeps its existing
  `{awaiting-approval, awaiting-ci}` reasons unchanged.
- `bash bin/halt.sh resolve <issue> --decision resume` is a single atomic
  operation that clears the gate AND its causes — rejection counters,
  stale verdict markers, `wait-{stage}.json`, `pipeline:skip-until-*`,
  and orphan `issue-state.json` policy=skip-until-human-acts.
- Defensive halt-add at `bin/run-stage.sh:445-450` (main) /
  `bin/run-stage.sh:542-545` (after ENG-45 lands) trusts the agent when
  any of the four verdict shapes is present in Linear newer than the
  most recent transition. A `marker-emission-audit` log line + metric
  field surface confabulated exits.
- Stages that don't apply to an issue (no surfaces, plan task list empty)
  exit with a `pipeline-stage-summary: <stage>` whose body begins
  `Not applicable: <reason>`. The verdict-handler advances the stage
  label exactly as it would for a real pass; a new metric field
  `applicability=skipped|applied` distinguishes for retrospective.
- PR creation is decoupled from the UI stage: any code-changing stage
  opens the PR via the idempotent `gh pr list --head <branch> --state
  open --json number --jq 'length'` precondition; not-applicable exits
  do not open a PR. Backend-only issues open their PR from implement;
  combined issues open from implement and UI just pushes additional
  commits.

The four-shape verdict-marker vocabulary
(`stage-summary | rejection | halt | wait`) stays bounded. New failure
modes ride on reason fields, not new shapes.

## Assumption Inventory

Each modified file's current state quoted by `path:line` so the implement
agent can find the insertion / replacement target verbatim. Line numbers
on `main` are listed; the post-ENG-45 line numbers are noted parenthetically
where they differ.

### A-001 — `bin/halt.sh::resolve` source location

`bin/halt.sh:16-29`:

```bash
resolve() {
  local issue="$1" decision="$2"
  [[ -n "$issue" && -n "$decision" ]] \
    || die "usage: halt.sh resolve <ENG-XX> --decision <scope-approved|scope-rejected|resume>"
  case "$decision" in
    scope-approved|scope-rejected|resume) ;;
    *) die "unknown decision: $decision" ;;
  esac
  local body
  body="$(printf '<!-- pipeline-decision: %s -->\n\nHalt resolved by human via halt.sh (decision=%s).' "$decision" "$decision")"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
  bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
  log "halt resolved: $issue decision=$decision"
}
```

`PIPELINE_WRITER=human` is exported at line 14 (already covers the new
write-lane requirements; no ENG-41 lane changes needed).

### A-002 — `bin/halt.sh` argument-parsing region

`bin/halt.sh:31-48`:

```bash
main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    resolve)
      local issue="" decision=""
      while (( $# )); do
        case "$1" in
          --decision) decision="$2"; shift 2 ;;
          ENG-*)      issue="$1"; shift ;;
          *)          die "unknown arg: $1" ;;
        esac
      done
      resolve "$issue" "$decision"
      ;;
    *) die "usage: halt.sh resolve <ENG-XX> --decision <scope-approved|scope-rejected|resume>" ;;
  esac
}
```

The decision dispatch lives entirely in `resolve`; argument parsing already
funnels every decision to the same call site.

### A-003 — `bin/run-stage.sh` defensive halt-add (target of Track C)

`bin/run-stage.sh:445-450` on `main`:

```bash
  # Post-dispatch halt check: every stage agent must apply pipeline:halted.
  # If it did not, apply it on the agent's behalf and let the Verdict Handler
  # surface a protocol violation on the next tick.
  if ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:halted"; then
    log "post-dispatch: agent did not apply pipeline:halted; applying on its behalf"
    bash "$SCRIPT_DIR/linear.sh" add-label "$ident" "pipeline:halted" || true
  fi
```

After ENG-45, the equivalent block sits at lines 542-545 (verified via the
ENG-45 brainstorm assumption inventory). The implement agent must rebase
on top of ENG-45 first; line numbers here use the post-ENG-45 base.

### A-004 — `bin/guards.sh::count_marker_since_last_transition` freshness rule

`bin/guards.sh:42-55`:

```bash
count_marker_since_last_transition() {
  local ident="$1" marker="$2"
  local comments last_ts
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$ident")"
  last_ts="$(jq -r '
    [.[] | select(.body | contains("<!-- pipeline-transition:"))]
    | sort_by(.createdAt) | last | .createdAt // ""' <<<"$comments")"
  if [[ -z "$last_ts" ]]; then
    jq -r --arg m "<!-- pipeline-metric: $marker -->" \
      '[.[] | select(.body | contains($m))] | length' <<<"$comments"
  else
    jq -r --arg m "<!-- pipeline-metric: $marker -->" --arg t "$last_ts" \
      '[.[] | select(.createdAt > $t) | select(.body | contains($m))] | length' <<<"$comments"
  fi
}
```

A new transition comment (createdAt > all prior rejection markers) makes
the count return 0. Track B's posting of an operator-attributed transition
exploits exactly this. **No change to `guards.sh` is required.**

### A-005 — `bin/verdict-handler.sh::find_fresh_verdict` freshness rule

`bin/verdict-handler.sh:69-127`. Same freshness anchor: most recent
`<!-- pipeline-transition: -->` comment. Recognizes only three (post-ENG-45:
the regex still recognizes only three) verdict shapes. **No change to
`verdict-handler.sh` is required** — Track B's new operator-attributed
transition uses the existing `pipeline-transition` shape, picked up
unchanged by `find_fresh_verdict`'s freshness anchor.

### A-006 — `bin/run-stage.sh::_fresh_wait_reason` build-only gate (Track A target)

Post-ENG-45, `bin/run-stage.sh:302-`:

```bash
_fresh_wait_reason() {
  local ident="$1" stage="$2"
  [[ "$stage" == "build" ]] || return 1
  ...
}
```

Track A replaces the `[[ "$stage" == "build" ]] || return 1` line with a
per-stage→reasons allow-list lookup. The rest of the function stays.

### A-007 — `bin/run-stage.sh::_handle_wait` budget logic

Post-ENG-45, `bin/run-stage.sh:338-`. Reads
`orchestrator.external_signal_budget` from `config.json` (currently a flat
shape `{max_attempts, max_minutes}`). Track A's per-stage budget config
generalizes the read pattern to a three-tier lookup
(per-stage → default → legacy flat) preserving backwards-compat.

### A-008 — `bin/linear.sh` subcommand surface

`bin/linear.sh` already exposes every subcommand the new code needs, per
`bin/linear.sh:9-17,520-528`:

- `add-label`, `remove-label`, `add-comment`, `stage-of`, `has-label`,
  `get-comments`.

No new linear.sh subcommand is required.

### A-009 — `~/.pipeline-config/config.json::orchestrator` schema

Currently:

```json
{
  "orchestrator": {
    "paused": false,
    "max_concurrent_features": ...,
    "alert_on_halted_over": ...,
    "external_signal_budget": {
      "max_attempts": 12,
      "max_minutes": 60
    }
  }
}
```

Track A's three-tier lookup means the existing flat shape continues to
work as a `default` fallback; no migration script is required, but the
plan's tests assert backwards-compat explicitly (T-A5).

### A-010 — `AGENT_PROMPTS.md` "Non-verdict markers" preamble

Introduced by ENG-45 commit `f59acf8`. Section title: *Non-verdict markers*.
Track A and Track C each add one paragraph to this preamble. Plan T-6 and
T-9 below.

### A-011 — Test sentinel pattern

Each `bin/foo.sh` ends with the sentinel
`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`. Tests source
the file to call its functions directly. New test file
`bin/halt-resolve-test.sh` follows this pattern by sourcing `bin/halt.sh`
after exporting `PIPELINE_DRY_RUN=1` and `LINEAR_API_KEY=test-mock-key`,
then invoking `resolve` directly. (`bin/halt.sh` already has the sentinel
at lines 50-52.)

### A-012 — `bin/run-stage.sh::main` `dispatched_stage_label` and `current_stage_label` are in scope at the defensive halt-add line

`bin/run-stage.sh:430-450` (post-ENG-45 region). Both variables are
populated upstream by the existing stage-drift guard. Track C's audit
helper invocation at line 445 reuses `dispatched_stage_label` directly
without re-fetching from Linear.

### A-013 — `bin/metrics.sh stage-end` outcome string is free-form

Verified by ENG-45 §8.3: outcome is a free-form string at line 67, no
allow-list. Track C's `marker_emitted=<shape>|missing` rides as a key=value
arg without schema change.

### A-014 — `_marker_emission_audit` is a new helper; no existing function collides

`grep -n _marker_emission_audit bin/run-stage.sh` returns nothing on main
or on the ENG-45 branch. New helper, no shadowing concern.

### A-015 — `~/.local/state/twinning-harness/<slug>/<issue>/issue-state.json` schema field `policy`

Per `bin/classify-failure.sh` and the existing `issue-state.json` files
visible during today's debugging: `.policy` is a top-level string field
holding values like `skip-until-human-acts`, `skip-until-code-changes`.
Track B's conditional removal reads this field with `jq -r '.policy // ""'`.

### A-016 — `AGENT_PROMPTS.md` §3 "Do NOT create a PR" instruction (Track D target)

Verified at `AGENT_PROMPTS.md:462`:

> Run `cargo build`, `cargo test --workspace`, and `bun run check` before finishing.
>   All three MUST pass.
> - **Do NOT create a PR. The UI agent opens the combined backend+frontend PR.**

Track D replaces the bolded sentence with the idempotent open from §D-D2.

### A-017 — `AGENT_PROMPTS.md` §4 idempotent PR-open precondition (already in place from ENG-45 cycle 2)

The UI agent's cycle-2 stage summary at 12:57 referenced:

> Idempotency precondition: `gh pr list --head feat/eng-45-… --state open --json number --jq 'length'` returned 1 (PR #15). Per the system prompt, that means: "Skip `gh pr create` entirely; do NOT attempt to re-create or amend the PR. Proceed to the rest of the UI stage (stage summary, push, completion)."

Track D leaves §4's precondition in place; only adds the "Not applicable"
exit clause and the cross-reference back to the §D-D2 rule.

### A-018 — Plan-doc convention for `## Backend Tasks` and `## Frontend Tasks`

Recent plans (ENG-26, ENG-41, ENG-42, ENG-45) all use these two H2
sections under "Backend Tasks" and "Frontend Tasks" with `N/A` marker
when empty. Track D's applicability check reads these sections by name.

### A-019 — `bin/verdict-handler.sh` advances on `pipeline-stage-summary` regardless of body content

`bin/verdict-handler.sh:259-266`: the marker shape (`pipeline-stage-summary`)
is what triggers the forward transition; the body is for human readability
only. This means a `Not applicable: <reason>` body still triggers the
same stage-label swap as a real pass. No verdict-handler changes required
for Track D.

### A-020 — `bin/run-stage.sh` `dispatched_stage_label` is in scope at the audit/applicability site

Same scope analysis as A-012; both Track C's audit and Track D's
metric-event extension run at the same call-site.

## File Structure

| Path | Action | Track |
|---|---|---|
| `bin/halt.sh` | modify (extend `resolve()`) | B |
| `bin/halt-resolve-test.sh` | **new** | B |
| `bin/run-stage.sh` | modify (`_WAIT_REASONS_BY_STAGE`, three-tier budget lookup, `_marker_emission_audit`, defensive halt-add tightening, `applicability=` metric key) | A + C + D |
| `bin/run-stage-test.sh` | modify (new ENG-47 cases for A, C, D) | A + C + D |
| `AGENT_PROMPTS.md` | modify (preamble updates for A and C; per-stage self-verification step; §3/§4/§5/§6/§7 prompt edits for stage-applicability + idempotent PR creation) | A + C + D |
| `~/.pipeline-config/config.json` | optional — only needed if extending budgets to non-build stages | A |
| `docs/plans/2026-04-28-eng-47-halt-protocol-symmetry.md` | this file (already on branch) | — |
| `docs/brainstorms/2026-04-28-halt-protocol-symmetry-design.md` | reference (already on branch) | — |

No new directories. No new top-level scripts. No new MCP integrations. No
new external dependencies.

## Command API Contract

N/A. The harness has no Tauri command surface; this is bash orchestration
plus prompt-text edits only. The operator-facing CLI surfaces are:

- `bash bin/halt.sh resolve <issue> --decision <scope-approved|scope-rejected|resume>` — flag set unchanged; behavior changes per Track B but the invocation contract is identical.
- `~/.pipeline-config/config.json::orchestrator.external_signal_budget` — schema additively extends to a per-stage map; legacy flat shape preserved.

## Backend Tasks

Tasks numbered T-N. Each has `depends_on`, `touches`, and a code block
showing the change. The implement agent should commit per the grouping
indicated under "Commits" at the end.

### T-1 — Track B: extend `resolve()` to post operator-attributed transition

`depends_on: []` (independent of ENG-45)
`touches: [bin/halt.sh]`

Replace `bin/halt.sh::resolve` (lines 16-29) with a decision-aware
implementation:

```bash
resolve() {
  local issue="$1" decision="$2"
  [[ -n "$issue" && -n "$decision" ]] \
    || die "usage: halt.sh resolve <ENG-XX> --decision <scope-approved|scope-rejected|resume>"
  case "$decision" in
    scope-approved|scope-rejected|resume) ;;
    *) die "unknown decision: $decision" ;;
  esac

  # 1. Operator decision marker (audit trail; same as today).
  local decision_body
  decision_body="$(printf '<!-- pipeline-decision: %s -->\n\nHalt resolved by human via halt.sh (decision=%s).' "$decision" "$decision")"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$decision_body"

  # 2. For resuming decisions, post an operator-attributed transition that
  #    invalidates prior verdict markers AND resets rejection counters via
  #    the existing pipeline-transition freshness rule (see guards.sh:42-55,
  #    verdict-handler.sh:69-127). The (operator-resume) suffix in the body
  #    is the human-readable discriminator; lane attribution
  #    (PIPELINE_WRITER=human, exported at line 14) is the structural one.
  case "$decision" in
    resume|scope-approved)
      local stage; stage="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue" 2>/dev/null || printf '')"
      local stage_short="${stage#stage:}"
      [[ -z "$stage_short" ]] && stage_short=none
      local transition_body
      transition_body="$(printf '<!-- pipeline-transition: %s → %s (operator-resume) -->\n\nCounter reset and verdict-marker invalidation by operator authority via halt.sh resolve (decision=%s).' "$stage_short" "$stage_short" "$decision")"
      bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$transition_body"
      ;;
  esac

  # 3. Clear the halt label.
  bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"

  # 4. For resuming decisions, atomically clean the four other halt-causes.
  case "$decision" in
    resume|scope-approved)
      local stage; stage="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue" 2>/dev/null || printf '')"
      local stage_short="${stage#stage:}"
      if [[ -n "$stage_short" && "$stage_short" != "none" ]]; then
        rm -f "$(issue_dir "$issue")/wait-${stage_short}.json" 2>/dev/null || true
      fi
      bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:skip-until-human-acts"  2>/dev/null || true
      bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:skip-until-code-changes" 2>/dev/null || true
      local state_file; state_file="$(issue_dir "$issue")/issue-state.json"
      if [[ -f "$state_file" ]]; then
        local policy; policy="$(jq -r '.policy // ""' "$state_file" 2>/dev/null)"
        [[ "$policy" == "skip-until-human-acts" ]] && rm -f "$state_file"
      fi
      ;;
  esac

  log "halt resolved: $issue decision=$decision"
}
```

Note: `issue_dir` is provided by `common.sh`; `bin/halt.sh` already
sources `common.sh` at line 11.

`scope-rejected` keeps the prior behavior intact — no transition, no
state cleanup. The operator is rejecting the work, not greenlighting a
retry. They will manually apply `pipeline:abandoned` or move the issue
back to a prior stage.

### T-2 — Track B: tests for the atomic resume

`depends_on: [T-1]`
`touches: [bin/halt-resolve-test.sh]`

New file. Mirrors the test shape used by `bin/classify-failure-test.sh`:
sets `PIPELINE_DRY_RUN=1` and `LINEAR_API_KEY=test-mock-key`, creates a
`STUB_DIR` with a mock `bin/linear.sh` that captures every subcommand
invocation to a CAPTURE_FILE for grep-based assertions, sources
`bin/halt.sh`, calls `resolve` directly per-case.

Cases (one assertion bundle each):

- **T-2-A — `resume` posts decision marker.** `resolve ENG-1 resume`.
  Assert `grep -F 'SUBCMD=add-comment' "$CAPTURE_FILE"` shows two adds
  (decision + transition). Assert the first body contains
  `<!-- pipeline-decision: resume -->`. Assert the second body contains
  `<!-- pipeline-transition: <stage> → <stage> (operator-resume) -->`.

- **T-2-B — `resume` posts transition with `(operator-resume)` suffix.**
  Same setup. Stub `linear.sh stage-of` returns `stage:implementing`.
  Assert capture contains literal `(operator-resume)`.

- **T-2-C — `resume` removes halt label.** Assert capture contains
  `SUBCMD=remove-label` with `pipeline:halted`.

- **T-2-D — `resume` removes `wait-{stage}.json`.** Pre-seed
  `$(issue_dir ENG-1)/wait-implementing.json`. Run resolve. Assert file is
  removed.

- **T-2-E — `resume` removes `pipeline:skip-until-*` labels.** Assert
  capture contains both `remove-label … pipeline:skip-until-human-acts`
  and `remove-label … pipeline:skip-until-code-changes`.

- **T-2-F — `resume` removes orphan `issue-state.json` policy=skip-until-human-acts.**
  Pre-seed `$(issue_dir ENG-1)/issue-state.json` with
  `{"policy": "skip-until-human-acts"}`. Run resolve. Assert file is
  removed.

- **T-2-G — `resume` does NOT remove `issue-state.json` with other policy.**
  Pre-seed `{"policy": "skip-until-code-changes"}`. Run resolve. Assert
  file still exists.

- **T-2-H — `scope-approved` behaves identically to `resume`.** Run
  `resolve ENG-1 scope-approved`. Same assertions as T-2-A through T-2-F.

- **T-2-I — `scope-rejected` does NOT post transition.** Assert
  `grep -F 'pipeline-transition' "$CAPTURE_FILE"` returns nothing. Assert
  capture still has the decision marker (`pipeline-decision: scope-rejected`)
  and the halt-label remove. Assert wait file and skip labels are NOT
  touched (no `remove-label` for skip-* and no `rm` of wait-*.json).

- **T-2-J — Empty stage gracefully handled.** Stub `linear.sh stage-of`
  returns empty string. Run `resolve ENG-1 resume`. Assert the transition
  body uses literal `none → none` (or analogous fallback). No crash.

- **T-2-K — Counter reset effect via downstream guards.sh.** Sentinel
  test: source `bin/guards.sh`'s `count_marker_since_last_transition`
  with mocked comments containing two `pipeline-metric: implement_rejection`
  before the new transition. Verify count = 0 (the new transition resets
  the counter). This ties Track B's behavior change to AC #3.

PASS/FAIL helpers and harness mirror existing test files. Per file
convention, exit code is 0 with FAIL summary if any case fails (the
existing footer `(( FAIL == 0 )) || exit 1` handles this).

### T-3 — Track C: add `_marker_emission_audit` helper to `bin/run-stage.sh`

`depends_on: []`
`touches: [bin/run-stage.sh]`

Insert a new helper near the top of `bin/run-stage.sh` (before `main()`),
adjacent to other helpers like `_fresh_wait_reason` (introduced by ENG-45):

```bash
# ENG-47: Returns the most recent verdict-marker shape (one of
# stage-summary | rejection | halt | wait) emitted in a Linear comment
# newer than the most recent <!-- pipeline-transition: --> comment.
# Empty stdout iff no shape is fresh. Used by Track C's tightened
# defensive halt-add to trust agents that did emit a marker.
#
# Important: pipeline-sig is dedup metadata, NOT a verdict marker, and
# is excluded from the regex below by design.
_marker_emission_audit() {
  local issue="$1"
  local comments last_ts
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue" 2>/dev/null || printf '[]')"
  last_ts="$(jq -r '
    [.[] | select(.body | contains("<!-- pipeline-transition:"))]
    | sort_by(.createdAt) | last | .createdAt // ""' <<<"$comments" 2>/dev/null)"
  if [[ -z "$last_ts" ]]; then
    jq -r '
      [.[] | .body
        | capture("<!-- pipeline-(?<m>stage-summary|rejection|halt|wait): [a-z-]+ -->") // empty
        | .m]
      | last // ""' <<<"$comments" 2>/dev/null
  else
    jq -r --arg t "$last_ts" '
      [.[] | select(.createdAt > $t) | .body
        | capture("<!-- pipeline-(?<m>stage-summary|rejection|halt|wait): [a-z-]+ -->") // empty
        | .m]
      | last // ""' <<<"$comments" 2>/dev/null
  fi
}
```

Fail-closed semantics: on any jq error or empty stdout, treat as "no
fresh marker" (which routes to defensive halt-add as today). This means
a Linear read failure mid-tick falls back to today's behavior — no new
silent-success risk introduced.

### T-4 — Track C: tighten defensive halt-add

`depends_on: [T-3]`
`touches: [bin/run-stage.sh]`

Replace the existing block at `bin/run-stage.sh:445-450` (main; or
542-545 post-ENG-45) with:

```bash
  # ENG-47: Post-dispatch verdict-marker audit. If the agent emitted any
  # of the four verdict shapes (stage-summary | rejection | halt | wait)
  # in Linear newer than the most recent pipeline-transition, trust the
  # agent's exit and let verdict-handler advance the stage. Otherwise
  # fall back to the defensive halt-add the harness used to do
  # unconditionally — confabulated exits still get caught.
  local _emap_marker
  _emap_marker="$(_marker_emission_audit "$ident")"
  log "marker-emission-audit: $dispatched_stage_label $ident marker=${_emap_marker:-missing}"

  if [[ -z "$_emap_marker" ]] && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:halted"; then
    log "post-dispatch: agent did not apply pipeline:halted AND emitted no verdict marker; applying defensive halt"
    bash "$SCRIPT_DIR/linear.sh" add-label "$ident" "pipeline:halted" || true
  fi
```

Key invariant: if `_emap_marker` is non-empty (any of the four shapes),
the `if` block is skipped entirely — defensive halt-add does not fire,
even when the halt label isn't already present. This is the desired
behavior for clean-pass exits (`stage-summary`, `wait`, etc.). For halt
or rejection markers, the halt label is set by the agent itself, so the
`has-label` check would skip the add anyway; the new short-circuit just
makes the intent explicit.

### T-5 — Track C: ride `marker_emitted` on the existing metric event

`depends_on: [T-4]`
`touches: [bin/run-stage.sh]`

The metric event is already emitted at the success path
(`bin/run-stage.sh:467+` post-ENG-45) and the various failure paths
(T-3 in ENG-45's plan covers the wait branch). Add `marker_emitted=$_emap_marker`
to the `metrics.sh stage-end` invocations that fire after the audit
runs. Specifically:

```bash
bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "success" "$duration" \
  "verdict=transitioned" "marker_emitted=${_emap_marker:-missing}"
```

(and equivalents on the other success/failure arms in the same `case "$vh_rc" in` block)

`bin/metrics.sh stage-end` accepts arbitrary trailing key=value pairs
per ENG-45 §8.3. Retrospective queries (post-ENG-26 cost telemetry) can
filter on `marker_emitted=missing` to surface confabulation patterns.

### T-6 — Track C: AGENT_PROMPTS.md preamble + per-stage self-verification

`depends_on: []`
`touches: [AGENT_PROMPTS.md]`

Add to the "Verdict-marker protocol" preamble (after ENG-45's
"Non-verdict markers" subsection):

```markdown
### Self-verification at exit (ENG-47)

Before claiming any stage exited cleanly, verify your verdict marker is
actually present in Linear. The narration in your transcript ≠ a Linear
comment. The orchestrator inspects Linear, not your narration.

```bash
bash bin/linear.sh get-comments {issue_id} | jq -r --arg s "{stage}" '
  [.[] | .body | select(test("<!-- pipeline-(stage-summary|rejection|halt|wait): " + $s + " -->|<!-- pipeline-(halt|wait): [a-z-]+"))] | length'
```

If this returns 0, your verdict marker did NOT post. Re-post via
`bash bin/linear.sh add-comment {issue_id} "<!-- pipeline-stage-summary:
{stage} -->\n\n<short body>"` (or the appropriate verdict shape) before
exit.

The `<!-- pipeline-sig: completion/{stage}/{issue_id} -->` metadata is
**NOT** a verdict marker. Verdict markers are exactly the four shapes
listed under "Verdict-marker protocol".
```

Apply this as a single new subsection. No per-stage edits required —
every stage prompt already reads the preamble at dispatch time.

### T-7 — Track C: tests for tightened defensive halt-add

`depends_on: [T-3, T-4]`
`touches: [bin/run-stage-test.sh]`

Insert before the existing case-15 latent abort (mirroring ENG-45's
insertion strategy per its plan §"Test insertion location"):

- **T-7-A — `_marker_emission_audit` returns `stage-summary` when fresh.**
  Stub `linear.sh get-comments` to return JSON with a transition
  followed by a `pipeline-stage-summary: implementing` comment. Assert
  function prints `stage-summary`.

- **T-7-B — Returns `wait` when only a wait marker is fresh.** Mock a
  `pipeline-wait: awaiting-approval` newer than the last transition.
  Assert `wait`.

- **T-7-C — Returns empty for `pipeline-sig` only.** Mock a
  `pipeline-sig: completion/implement/ENG-1` comment. No verdict shape.
  Assert empty.

- **T-7-D — Returns empty for `pipeline-decision` only.** Mock a
  `pipeline-decision: resume` comment. Assert empty (decisions are not
  verdicts).

- **T-7-E — Stale halt marker (older than last transition) does NOT
  count.** Mock a `pipeline-halt: agent-blocked` BEFORE the most recent
  transition. Assert empty. (This is the bug-fix invariant; same shape
  as the freshness rule both `find_fresh_verdict` and
  `count_marker_since_last_transition` already use.)

- **T-7-F — Defensive halt-add stays its hand when audit returns
  non-empty.** Source `bin/run-stage.sh::main`'s defensive halt-add
  block in isolation; mock audit to return `stage-summary`. Assert no
  `add-label … pipeline:halted` call is captured.

- **T-7-G — Defensive halt-add applies when audit returns empty AND no
  halt label.** Mock audit empty; mock `has-label` returns 1 (no label).
  Assert capture contains `add-label … pipeline:halted`.

- **T-7-H — Defensive halt-add does NOT double-apply when label already
  set.** Mock audit empty; mock `has-label` returns 0 (label present).
  Assert no extra `add-label` call.

- **T-7-I — `marker-emission-audit` log line fires unconditionally.**
  Run the post-dispatch block under any combination. Assert `grep -F
  'marker-emission-audit:' "$LOG_CAPTURE"` returns ≥1 hit per dispatch.

PASS/FAIL helpers and shared scaffolding mirror existing cases.

### T-8 — Track A: replace build-only gate with per-stage→reasons allow-list

`depends_on: []` (independent of B/C; depends on ENG-45 having merged so
`_fresh_wait_reason` exists)
`touches: [bin/run-stage.sh]`

In `_fresh_wait_reason` (post-ENG-45 line ~302), replace the line:

```bash
  [[ "$stage" == "build" ]] || return 1
```

with:

```bash
  # ENG-47: per-stage allow-list of accepted wait reasons. Build's
  # original {awaiting-approval, awaiting-ci} pair is preserved as the
  # only declared (stage, reason) entries on first land. New stages
  # opting into the wait primitive add an entry here; the per-stage
  # gate keeps the cross-stage forgery defense ENG-45 §D-003 motivated.
  declare -A _WAIT_REASONS_BY_STAGE=(
    [build]="awaiting-approval awaiting-ci"
    # [review]="awaiting-codeowners"      # future
    # [qa]="awaiting-flake-rerun"         # future
  )
  local allowed_reasons="${_WAIT_REASONS_BY_STAGE[$stage]:-}"
  [[ -n "$allowed_reasons" ]] || return 1
  [[ " $allowed_reasons " == *" $reason "* ]] || return 1
```

`$reason` is already populated upstream in `_fresh_wait_reason` from the
parsed marker body. Verify the local-array declaration is bash-3.2-safe
(macOS launchd host) — `declare -A` is bash-4 only. **Mitigation:** use a
case statement instead, which is bash-3.2-safe:

```bash
  # ENG-47: per-stage allow-list of accepted wait reasons (bash-3.2 safe).
  local allowed_reasons=""
  case "$stage" in
    build) allowed_reasons="awaiting-approval awaiting-ci" ;;
    # future: review) allowed_reasons="awaiting-codeowners" ;;
    # future: qa)     allowed_reasons="awaiting-flake-rerun" ;;
    *) return 1 ;;
  esac
  [[ " $allowed_reasons " == *" $reason "* ]] || return 1
```

The case-statement form is the implement-side change; the assoc-array
form is the reference. Implement agent: use the case-statement form;
add a comment block above noting the bash-3.2 portability constraint
(see CLAUDE.md "macOS system bash is 3.2.57; no `mapfile`/`readarray`").

### T-9 — Track A: AGENT_PROMPTS.md preamble update for `pipeline-wait` discipline

`depends_on: []`
`touches: [AGENT_PROMPTS.md]`

Append one paragraph to ENG-45's "Non-verdict markers" subsection in the
preamble:

```markdown
The `pipeline-wait` shape is the **canonical soft-pause primitive** for
any agent stage. New soft-pause failure modes are NOT to be expressed as
new marker shapes; they are added as new entries in the per-stage reasons
allow-list (`bin/run-stage.sh::_fresh_wait_reason`'s case statement) via
a code change reviewed under the standard pipeline. The four shapes
(`pipeline-stage-summary`, `pipeline-rejection`, `pipeline-halt`,
`pipeline-wait`) are bounded; sub-cases live in reason fields.
```

### T-10 — Track A (optional): three-tier budget config lookup

`depends_on: [T-8]`
`touches: [bin/run-stage.sh]`

Replace the budget read in `_handle_wait` (post-ENG-45 line ~338-) with:

```bash
  # ENG-47: three-tier budget lookup. Per-stage entry > default > legacy
  # flat shape. All three tiers tested under T-A3/A4/A5.
  local max_attempts max_minutes
  max_attempts="$(config_get ".orchestrator.external_signal_budget.${stage}.max_attempts // .orchestrator.external_signal_budget.default.max_attempts // .orchestrator.external_signal_budget.max_attempts // 12")"
  max_minutes="$(config_get  ".orchestrator.external_signal_budget.${stage}.max_minutes  // .orchestrator.external_signal_budget.default.max_minutes  // .orchestrator.external_signal_budget.max_minutes  // 60")"
```

Existing behavior preserved: with the current flat config, the first
two `// ...` arms fall through to the legacy flat read. With a per-stage
entry, the per-stage value wins. Default fallback values match the
hardcoded fallbacks in ENG-45's existing implementation (defensive
against null config).

This task is **optional for v1** — it can ship with T-8 or be deferred.
The brainstorm marks it as part of Track A but the user-facing benefit
(differentiated budgets per stage) is not required to ship the broader
"generalize wait" outcome. Plan the implement-stage agent to ship T-10
in v1 unless it adds material risk; if so, defer.

### T-11 — Track A: tests for the per-stage allow-list and budget

`depends_on: [T-8, T-10]`
`touches: [bin/run-stage-test.sh]`

Insert before the latent case-15 abort:

- **T-11-A1 — Existing build cases preserved.** Re-run ENG-45's case A
  (well-formed `pipeline-wait: awaiting-approval` on stage=build,
  newest-after-transition). Assert `_fresh_wait_reason` returns
  `awaiting-approval`.

- **T-11-A2 — Cross-stage forgery blocked.** Same fixture but stage=review.
  Assert `_fresh_wait_reason` returns 1 (no review entry in the case
  statement).

- **T-11-A3 — Future-stage opt-in works (synthetic).** Temporarily
  patch the case statement at runtime (e.g., test eval) to add a
  `[review]="awaiting-codeowners"` entry. Verify
  `_fresh_wait_reason` accepts a (review, awaiting-codeowners) pair.
  Restore the case statement at end of test. (This documents the
  extension shape as a test rather than a comment.)

- **T-11-A4 — Per-stage budget config: per-stage entry wins.**
  `config.json::orchestrator.external_signal_budget.build.max_attempts=24`
  set; legacy flat `max_attempts=12` set. Assert `_handle_wait` reads 24.

- **T-11-A5 — Per-stage budget config: default fallback.**
  `default.max_attempts=18` set; no per-stage entry; legacy flat
  `max_attempts=12` set. Assert `_handle_wait` reads 18.

- **T-11-A6 — Per-stage budget config: legacy flat fallback.**
  Only `external_signal_budget.max_attempts=12` set; no per-stage, no
  default. Assert `_handle_wait` reads 12 (backwards-compat).

- **T-11-A7 — Hardcoded default fallback.** No config at all. Assert
  `_handle_wait` reads 12 (the hardcoded fallback in T-10's jq path).

Existing ENG-45 cases (B, C, D, E, F, G, H, I, J, K, M, P6) all stay
green — none of them touch the gate or budget read paths in a
backwards-incompatible way.

### T-12 — Regression test: ENG-24 reproduction does not recur

`depends_on: [T-1, T-2]`
`touches: [bin/halt-resolve-test.sh]`

End-to-end fixture mocking the ENG-24 shape:

- Set up an issue at `stage:implementing` with two `pipeline-metric:
  implement_rejection` comments newer than the last `pipeline-transition`.
- Run `resolve ENG-24 resume`.
- Source `bin/guards.sh::count_marker_since_last_transition`. Assert it
  returns 0 (the new transition resets the counter).
- Source `bin/verdict-handler.sh::find_fresh_verdict`. Assert it returns
  empty (no fresh verdict, since the operator-attributed transition
  invalidates prior halt markers).

This test ties Track B's behavior change to the user-visible bug it
fixes.

### T-13 — Regression test: ENG-45 confabulated implement halt does not recur

`depends_on: [T-3, T-4, T-7]`
`touches: [bin/run-stage-test.sh]`

Replicate the ENG-45 14:09Z scenario:

- Mock comments where the most recent comment is an implement-summary
  body containing only `<!-- pipeline-sig: completion/implement/ENG-45 -->`,
  with no verdict-shape marker.
- Source the post-dispatch defensive-halt block.
- Assert `_marker_emission_audit` returns empty (`pipeline-sig` is not a
  verdict shape).
- Assert `marker-emission-audit:` log line fires with `marker=missing`.
- Assert defensive halt-add fires (label gets added).

Then a positive case:

- Mock the same scenario but with an additional comment containing
  `<!-- pipeline-stage-summary: implementing -->` newer than the last
  transition.
- Assert `_marker_emission_audit` returns `stage-summary`.
- Assert `marker-emission-audit:` log line fires with `marker=stage-summary`.
- Assert defensive halt-add does NOT fire.

This test ties Track C's behavior change to the user-visible bug it
fixes.

### T-14 — Track D: AGENT_PROMPTS.md `Stage applicability` preamble

`depends_on: []`
`touches: [AGENT_PROMPTS.md]`

Add a new subsection to the verdict-marker preamble (next to ENG-45's
"Non-verdict markers" subsection introduced by `f59acf8`):

```markdown
### Stage applicability (ENG-47)

Some stages apply to some issues but not to others. The harness operates
on multiple project types (Tauri+SvelteKit, bash harness, Python service,
docs-only repos), and not every stage has work to do on every project.
Examples: a bash harness has no SvelteKit/Tauri surface for the UI
stage; a docs-only repo has no implementation surface.

**Before starting your stage work, evaluate applicability.** If your
stage is not applicable to this issue's project, exit immediately with:

```
<!-- pipeline-stage-summary: <stage> -->

Not applicable: <one-sentence reason citing the plan section or repo evidence>.
```

Do NOT halt; do NOT fabricate work in scope; do NOT silently no-op.
The pass marker advances the stage label via the existing forward
transition; `Not applicable:` body prefix is the operator-readable
discriminator. Telemetry: emit
`bash bin/metrics.sh stage-end {issue_id} {stage} success $duration applicability=skipped`
to surface the skip for retrospective.

A stage that DOES apply emits its normal stage-summary marker (no
`Not applicable:` prefix) and the metric ride defaults to
`applicability=applied`.
```

### T-15 — Track D: §3 (Implement Backend) applicability + idempotent PR open

`depends_on: [T-14]`
`touches: [AGENT_PROMPTS.md]`

In `AGENT_PROMPTS.md` §3 (Implementation Agent (Backend)):

1. After the existing "Read these files first" block and before the
   precondition section, insert an "Applicability check" paragraph:

```markdown
**Applicability check (ENG-47):** Before any code work, determine
whether the backend stage applies to this issue. The backend stage is
applicable iff:

- The plan's `## Backend Tasks` section is non-empty (NOT just `N/A`); AND
- The repo has at least one of these surfaces present in the worktree:
  - `Cargo.toml` (Rust workspace)
  - `bin/*.sh` (bash harness)
  - `*.py` files at the repo root (Python service)
  - `package.json` WITHOUT `src/routes/` (Node service, not SvelteKit)
  - `api/*.ts` (any other TS API surface)

If neither condition holds, exit with the stage-applicability shape from
the verdict-marker preamble:
- `bash bin/linear.sh add-comment {issue_id} "<!-- pipeline-stage-summary: implementing -->\n\nNot applicable: <reason>"`
- `bash bin/metrics.sh stage-end {issue_id} implement success $duration applicability=skipped`
- exit 0

Do NOT proceed to the rest of this prompt. Do NOT open a PR.
```

2. Replace the existing line at `AGENT_PROMPTS.md:462` (verified via
   grep on main):

```markdown
- Do NOT create a PR. The UI agent opens the combined backend+frontend PR.
```

with:

```markdown
- After all code commits are pushed and tests pass, open the PR
  idempotently. Run:
  ```
  PR_COUNT=$(gh pr list --head {branch_name} --state open --json number --jq 'length')
  ```
  If `PR_COUNT` is 0, run `gh pr create --base main --head {branch_name}
  --title "<conventional-commit-shape title>" --body "<body referencing
  ENG-N + summary>"`. If 1, skip — a PR already exists; subsequent
  stages (UI if applicable, review, qa, build) will operate on the
  existing PR. The PR description should be backend-focused if implement
  is the only code-changing stage; if UI runs after, UI will amend the
  description (existing §4 instruction).
```

3. Sweep §3's body for any other "UI opens the PR" references and
   update to read "the first applicable code-changing stage opens the PR
   idempotently."

### T-16 — Track D: §4 (UI Frontend) applicability

`depends_on: [T-14]`
`touches: [AGENT_PROMPTS.md]`

§4 already has the idempotent PR-open precondition (per ENG-45 cycle 2).
Add the applicability check above the existing UI-stage instructions:

```markdown
**Applicability check (ENG-47):** Before any code work, determine
whether the UI stage applies to this issue. The UI stage is applicable
iff:

- The plan's `## Frontend Tasks` section is non-empty (NOT just `N/A`); AND
- The repo has at least one of these surfaces present in the worktree:
  - `package.json` WITH `src/routes/` (SvelteKit)
  - `src-tauri/` (Tauri)
  - `src/lib/*.svelte` (any Svelte components)
  - `src/components/*.tsx` (React components, future-proof)

If neither condition holds, exit with the stage-applicability shape:
- `bash bin/linear.sh add-comment {issue_id} "<!-- pipeline-stage-summary: ui -->\n\nNot applicable: <reason>"`
- `bash bin/metrics.sh stage-end {issue_id} ui success $duration applicability=skipped`
- exit 0

Do NOT open a PR. Do NOT proceed to the rest of this prompt. The
backend stage (§3) will have opened the PR if it was applicable; if
backend was also not applicable, no PR opens — that's correct, since
there is nothing to ship.
```

The existing idempotent PR-open precondition at the top of §4 already
handles "PR exists from §3" → skip. No change to the precondition itself
in this task; only the applicability gate is added.

### T-17 — Track D: §5 (Review), §6 (QA), §7 (Build) prompt edits

`depends_on: [T-15, T-16]`
`touches: [AGENT_PROMPTS.md]`

Sweep §5, §6, §7 for any wording that says or implies "the UI agent
opened the PR" or "the PR is opened by UI." Replace with neutral
language: "the PR opened by the most recent applicable code-changing
stage" or simply "the PR on this branch."

Examples of phrases to update (manual sweep — exact line numbers depend
on current state of §5/§6/§7):

- "the PR opened by UI" → "the PR on this branch"
- "after UI opens the PR" → "after a code-changing stage has opened the PR"
- "Review the PR opened by the UI stage" → "Review the PR on the
  branch"

These prompts already operate on `PR #N` discovered via
`gh pr list --head <branch> --state open`; the change is documentation
only (no behavioral change at runtime). The intent: future readers of
§5/§6/§7 don't get confused into thinking the UI stage is the canonical
PR creator — it's whichever code-changing stage ran last.

### T-18 — Track D: tests for stage-applicability exits + idempotent PR creation

`depends_on: [T-14, T-15, T-16]`
`touches: [bin/run-stage-test.sh]`

Insert before the latent case-15 abort (mirroring ENG-45's insertion
strategy). These cases test the orchestrator's handling of agent-emitted
applicability markers — not the agent prompts themselves (which are
text). The test fixtures simulate agent output via stub Linear comment
state.

- **T-18-D1 — Stage-summary with `Not applicable:` body advances stage.**
  Mock comments containing
  `<!-- pipeline-stage-summary: ui -->\n\nNot applicable: harness-self has
  no UI surface (plan §Frontend Tasks: N/A).`. Source verdict-handler;
  assert it transitions ui → reviewing exactly as it would for any pass
  marker. Validates §A-019 — body content doesn't affect transition.

- **T-18-D2 — `_marker_emission_audit` returns `stage-summary` for
  not-applicable pass.** Mock the same comment. Assert
  `_marker_emission_audit` returns `stage-summary` (the audit doesn't
  inspect body).

- **T-18-D3 — Defensive halt-add stays its hand on not-applicable pass.**
  Mock the same comment plus the audit. Source the post-dispatch block.
  Assert no `add-label … pipeline:halted` is captured.

- **T-18-D4 — `applicability=skipped` rides on metric event.** Mock a
  not-applicable agent exit including the metric call. Assert the
  captured `bin/metrics.sh stage-end` invocation includes
  `applicability=skipped` as a key=value arg. (This is a prompt-prose
  test in practice — the orchestrator doesn't enforce the key. The test
  validates that if the agent emits the key, downstream metrics-event
  ingestion (per ENG-26) carries it through. Sanity check.)

- **T-18-D5 — Idempotent PR creation: implement opens when zero.** Mock
  `gh pr list --head <branch> --state open --json number --jq 'length'`
  returning 0. Assert the implement agent's PR-open code path triggers
  `gh pr create`. (This is also prompt-prose enforcement; the test is a
  scaffold demonstrating the contract.)

- **T-18-D6 — Idempotent PR creation: UI skips when one.** Mock the
  same query returning 1. Assert UI does NOT call `gh pr create`. (This
  case actually exists in ENG-45 cycle 2 stage summary as evidence; the
  test pins the behavior.)

- **T-18-D7 — Both N/A: no PR opens, pipeline reaches stage:reviewing
  cleanly.** Mock implement and UI both exit not-applicable. Source
  verdict-handler twice. Assert stage label progresses
  `implementing → ui → reviewing` with no halt label and no PR creation
  attempt. (Edge case — flagged as a planning-stage gap per §D-D2.)

### T-19 — Regression test: ENG-45 cycle-2 misroute exits cleanly

`depends_on: [T-14, T-15, T-16, T-17]`
`touches: [bin/run-stage-test.sh]`

Replicate the ENG-45 cycle-2 scenario with the post-fix behavior:

- Mock a harness-self issue at `stage:ui` with no PR open initially.
- Mock implement run: applicable (bash backend work present), opens the
  PR via the idempotent-zero path.
- Mock UI run: not-applicable (no SvelteKit/Tauri surface), exits with
  `pipeline-stage-summary: ui` + `Not applicable:` body.
- Source verdict-handler; assert it advances ui → reviewing.
- Assert no halt label was applied at any point.
- Assert exactly one `gh pr create` was called (from implement, not
  from UI).

This test ties Track D's behavior change to the user-visible bug it
fixes — the same shape that required operator intervention three times
on ENG-45 today.

## Frontend Tasks

N/A. The harness has no SvelteKit / Tauri / web UI surface. Operator-facing
surface changes are CLI behavior of `bin/halt.sh resolve` (input contract
unchanged), one new metric event field, and three new lines in
`AGENT_PROMPTS.md`.

## Failure Mode → Test Map

(Single source of truth; the implement agent should ensure every row maps
to a named test in this PR before claiming completion.)

| # | Failure mode | Layer | Test case |
|---|---|---|---|
| 1 | `halt.sh resolve --decision resume` only clears label, leaves causes | T-2-A,C | tests for decision marker, transition, halt-label removal |
| 2 | Operator-attributed transition body lacks `(operator-resume)` discriminator | T-2-B | grep for literal in capture |
| 3 | Wait state file leaked across operator resume | T-2-D | seed file → run resolve → assert removed |
| 4 | `pipeline:skip-until-*` labels survive resume | T-2-E | both labels removed |
| 5 | Orphan `issue-state.json` skip-policy survives resume | T-2-F | conditional removal verified |
| 6 | `issue-state.json` with non-skip policy wrongly removed | T-2-G | negative assertion |
| 7 | `scope-approved` behaves differently from `resume` | T-2-H | parity assertion |
| 8 | `scope-rejected` over-reaches and posts transition | T-2-I | negative assertion on transition |
| 9 | Empty `stage-of` crashes the resolve flow | T-2-J | `none → none` fallback |
| 10 | Counter not reset by Track B's transition | T-2-K, T-12 | downstream guards.sh count = 0 |
| 11 | Defensive halt-add fires on clean-pass exit | T-7-F | audit returns shape → no defensive add |
| 12 | Audit ignores `pipeline-sig` (not a verdict shape) | T-7-C | empty return |
| 13 | Audit ignores `pipeline-decision` (not a verdict shape) | T-7-D | empty return |
| 14 | Audit treats stale halt marker as fresh | T-7-E | freshness rule applied |
| 15 | Defensive halt-add skipped when label already present | T-7-H | no double-apply |
| 16 | `marker-emission-audit` log line missing | T-7-I | unconditional fire |
| 17 | Cross-stage wait-marker forgery accepted | T-11-A2 | review with awaiting-approval rejected |
| 18 | Per-stage budget config: per-stage entry not preferred | T-11-A4 | three-tier order |
| 19 | Per-stage budget config: legacy flat shape silently broken | T-11-A6 | backwards-compat |
| 20 | Confabulated marker (sig only) treated as success | T-13 | regression-bound to ENG-45 |
| 21 | Stale rejection counter re-trips guard immediately after resume | T-12 | regression-bound to ENG-24 |
| 22 | Stage-summary `Not applicable:` body fails to advance | T-18-D1 | verdict-handler body-blind |
| 23 | Audit treats `Not applicable:` as missing-marker | T-18-D2 | audit body-blind |
| 24 | Defensive halt-add fires on not-applicable pass | T-18-D3 | clean exit honored |
| 25 | `applicability=skipped` metric not propagated | T-18-D4 | metric ingestion sanity |
| 26 | Implement opens PR when none exists | T-18-D5 | idempotency-zero path |
| 27 | UI re-creates PR when one exists | T-18-D6 | idempotency-one path |
| 28 | Both N/A — pipeline gets stuck at UI | T-18-D7 | reaches reviewing cleanly |
| 29 | Regression: harness-self UI misroute requires manual intervention | T-19 | regression-bound to ENG-45 cycle 2 |

Two rows are explicitly invariant-covered, no test required:

- A row in the brainstorm ("operator-attributed transition would be
  written outside the human lane") is structurally guaranteed by
  `bin/halt.sh:14` exporting `PIPELINE_WRITER=human`. ENG-41's lane
  fence test in `bin/linear.sh` covers this.
- A row in the brainstorm ("operator-resume body could be misparsed by
  consumers that don't expect the suffix") is non-blocking because all
  current consumers (`find_fresh_verdict`, `count_marker_since_last_transition`)
  are body-prefix-only and the suffix is in the body's middle/end.

## Commits

Implement agent should ship in four feature commits, in this order:

1. **`docs(ENG-47): plan for halt protocol symmetry`** — already on branch
   from this plan-stage commit. Implement agent does NOT add to this
   commit.
2. **`feat(ENG-47): atomic halt.sh resolve (Track B)`** — T-1, T-2, T-12.
   Independent of ENG-45.
3. **`feat(ENG-47): defensive halt-add audit (Track C)`** — T-3, T-4, T-5,
   T-6, T-7, T-13. Depends on ENG-45 ONLY for the line numbers; the
   functional change is also independent.
4. **`feat(ENG-47): stage applicability + idempotent PR creation (Track D)`**
   — T-14, T-15, T-16, T-17, T-18, T-19. Functionally independent of
   ENG-45 (prompt-prose edits + tests); depends on Track C for clean
   exit semantics (Track C's audit recognizes the stage-summary shape
   regardless of body, enabling D's not-applicable exit to bypass
   defensive halt-add).
5. **`feat(ENG-47): generalize pipeline-wait gate (Track A)`** — T-8, T-9,
   T-10, T-11. **Depends on ENG-45 having merged.**

Four feature commits, one doc commit; the doc commit is already in
place. If ENG-45 hasn't merged at implement time, the implement agent
should rebase ENG-47 onto ENG-45's tip before starting Track A — same
pattern as the ENG-26 rebase we did today (per the
`project_implement_agent_loopback_competence` learned rule).

Track ordering rationale: B is independent and smallest; C is a
prerequisite for D's not-applicable exit recognition; D is the
prompt-heavy track but small in code; A modifies ENG-45-introduced
functions and goes last.

## Persona Reviews

To be filled in by plan-stage personas if running through pipeline.
Manual review notes:

- **Coherence (P0):** the wait-gate sequencing in `_handle_wait` is
  preserved by Track A's gate change (only the inner `[[ "$stage" ==
  "build" ]]` line moves to a per-stage allow-list; everything else
  unchanged). Track D's applicability check fires before Track C's audit
  in the agent flow but doesn't interact with C in the orchestrator —
  the audit reads Linear comments regardless of whether they came from a
  "real pass" or a "not-applicable pass". No new ordering risk across
  tracks.
- **Scope (P0):** Tracks B, C, and D are net additions. Track A is a
  1-line replacement of an existing gate with a case statement.
  Behavior identical for build (post-A); behavior on harness-self
  improves substantially (post-D). No scope creep beyond the brainstorm.
- **Security (P0):** Track A preserves ENG-45's cross-stage-forgery
  defense (case statement default returns 1). Track B's
  operator-attributed transition is written under
  `PIPELINE_WRITER=human`. Track C's audit is read-only. Track D's
  applicability check is agent-prose; the orchestrator-side enforcement
  (audit on `pipeline-stage-summary` shape) is unchanged. No new write
  permissions, no new secret handling.
- **Test (P0):** every modified function has at least one positive +
  one negative case. Three regression cases (T-12, T-13, T-19) tie back
  to the user-visible bugs.
- **Performance (P1):** `_marker_emission_audit` adds one `linear.sh
  get-comments` call per dispatch. The same call is already made by
  `find_fresh_verdict` later in the same flow; if performance becomes a
  concern, fold the two into a single read with a shared output. Not in
  v1.
- **Product (P1):** Track D's `applicability=skipped` metric is the
  retrospective hook to detect "this project type never uses this stage"
  patterns. After ENG-47 lands, expect a follow-up retrospective ticket
  that consumes these events to either (a) propose stage-skip lists per
  project, or (b) inform the longer-term master+sub-agent architecture
  brainstorm (out of scope here, mentioned in §3.4 D-D5 rejected
  alternatives).

## Open Questions

(Mirror of brainstorm §9, restated here for the implement agent.)

**Q1.** `--decision scope-rejected` — should the operator's expected
follow-up be automated? **Plan answer:** no, status-quo behavior; the
operator manually applies `pipeline:abandoned` or moves the stage label.

**Q2.** Should the marker-emission audit also fire for `pipeline-decision`
shapes? **Plan answer:** no — `pipeline-decision` is operator authority
(written by `halt.sh`), not an agent verdict. The audit's purpose is to
catch confabulating agents.

**Q3.** Is the metric outcome literal a free-form string? **Plan
answer:** yes — verified per ENG-45 §8.3. `marker_emitted=<shape>|missing`
rides as a key=value arg without schema change.

**Q4.** Slack notification on `halt.sh resolve --decision resume`?
**Plan answer:** out of scope here; file as a separate small ticket if
the operator wants it.

**Q5 (new during planning).** Should `_marker_emission_audit` cache the
`get-comments` result for the duration of the dispatch's post-flight
block, since `verdict_handler` will read the same comments later?
**Plan answer:** out of scope for v1; if performance becomes an issue,
add a `--cached` flag to `bin/linear.sh get-comments` in a follow-up.

**Q6 (Track D).** Should Track D's per-stage applicability rules extend
to brainstorm/plan/review/qa/build? **Plan answer:** no for v1.
brainstorm and plan are always applicable. review/qa/build need a PR;
if no PR exists they trip their own preconditions and halt, which is
correct. Scope to implement and UI for v1.

**Q7 (Track D).** Should the orchestrator pre-flight applicability
before dispatching `claude -p` (saving the cost of a no-op claude run)?
**Plan answer:** defer. Pre-flight requires duplicating the agent's
plan-reading + repo-inspection logic in bash. Cost of a no-op claude
run is small. Revisit if cost telemetry from ENG-26 shows persistent
skip-stage waste.

**Q8 (Track D).** Should `applicability=skipped` events trigger
operator alerts? **Plan answer:** no. Skip is a normal expected state
for multi-target operation. Patterns are retrospective-level
observations, not per-event alerts.

Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing
