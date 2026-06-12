---
linear: ENG-34
status: brainstorm
date: 2026-06-12
stage: brainstorming
---

# ENG-34 — Track human-decision events as first-class metric records

## Overview

The harness has no top-level metric record for "a human explicitly
overrode an agent." The calibration retrospective shape (P2a) wants to
measure agent-vs-operator divergence — for that to be possible at all,
the operator's explicit interventions must show up in `events.jsonl` as
a single typed event with a small, stable payload. Today only
`halt-resume` exists, it only fires on `continue`, and its
notes-payload is shaped for state-reset accounting (`wait_files=…
skip_labels=…`), not for "who decided what."

ENG-34 ships a new `human-decision` event emitted from
`bin/pipeline.sh::cmd_decide` for **every** action the operator runs
through that subcommand (`continue`, `approve`, `abandon`), capturing
actor, the action token, the gate (when relevant), and a coarse
before-state. `halt-resume` stays — it remains the source of truth for
atomic-reset side-effect counts; `human-decision` is the top-level
"decision happened" signal that downstream calibration is going to grep
for.

The known limitation (Linear-UI label edits by humans NOT captured)
stands as documented in the ticket. v1 is harness-mediated decisions
only; inferred detection is deferred.

## Decisions (with rationale)

### D-001 — Emission site is `cmd_decide`, not a per-action wrapper

**Decision.** Emit one `human-decision` event from
`bin/pipeline.sh::cmd_decide`, after `linear.sh add-comment "$body"`
returns success. One call site, one event per CLI invocation.

**Why.** `cmd_decide` is the chokepoint for all three explicit-decision
actions (`continue | approve | abandon`); the registry-validated body
is already rendered there (`bin/pipeline.sh:559-574`). Putting the
emission inside the function — past dry-run, past `add-comment` —
means we record exactly the decisions that landed on Linear and skip
the ones that didn't (dry-run / Linear-write failure).

**Constraint reference.** `CLAUDE.md§"When wiring a new script"`
mandates that "Metric writes go through `bin/metrics.sh`." This
decision keeps the new emission inside that chokepoint pattern (no
direct `jq … >> events.jsonl`).

**Rejected alternative.** Adding emission inside the three
`_pipeline_drain_*` helpers (continue-only) plus parallel ones for
approve/abandon. Rejected because each helper has a single responsibility
(drain a specific medium); a cross-cutting "audit the decision"
emission belongs at the boundary, not threaded through each helper.

### D-002 — Reuse existing flat schema; ride in `notes`

**Decision.** The event uses `metrics.sh`'s existing 7-key flat shape:

```
event="human-decision"
issue_id="$issue"
stage="<resolved current_stage or '-'>"
outcome="<after_state token: resumed|approved|abandoned>"
duration_ms=0
notes="actor=<sanitized> action=<continue|approve|abandon> [gate=<scope|build-cap>] before_state=<token>"
```

No new flag pairs added to `metrics.sh`. No new fields in the JSONL
row.

**Why.** Per ticket decision #2: "Reuses existing events.jsonl schema;
legacy readers ignore unknown event types." `metrics.sh` already
treats `event` as a free-form string (no enum validation —
`bin/metrics.sh:41` only checks non-emptiness; see test case ENG-120 at
`bin/metrics-test.sh:211-228`). Existing `halt-resume` already encodes
its payload as `key=value` tokens in `notes` (see
`_pipeline_emit_resume_metric`, `bin/pipeline.sh:462-469`), so this is
the codebase's established pattern for structured-but-unindexed
metadata.

**Constraint reference.** `CLAUDE.md§"Tests"` — keeping the row
shape unchanged means existing parsers and tests do not regress.

**Rejected alternative.** Adding `--actor`, `--action`, `--before-state`,
`--after-state`, `--gate` flag pairs to `metrics.sh` (mirroring the
`--tokens-in / --tokens-out / …` pattern). Rejected because: (a) the
new fields are decision-event-specific, not generally useful — every
other event would carry empty columns; (b) the unknown-flag arm in
`metrics.sh:35` would already absorb stray flags into `notes`, so
notes-tokens are the path of least surprise; (c) downstream calibration
parses notes regardless.

### D-003 — Actor capture: `git config user.email` → `$USER` → `unknown`

**Decision.** Resolve the actor token as:

```
actor=$(git -C "$HARNESS_ROOT" config user.email 2>/dev/null \
        || printf "%s" "${USER:-unknown}")
actor=$(printf "%s" "$actor" | tr -dc 'A-Za-z0-9._@+-' | head -c 64)
[[ -z "$actor" ]] && actor=unknown
```

Plain text into `events.jsonl`.

**Why.** Per ticket decisions #4 and #5: "git config user.email with
`$USER` fallback. Not security-grade; informative." and "actor goes
plain-text into events.jsonl, same as git commit metadata." `git
config user.email` is the same surface the rest of the codebase
already trusts for commit attribution (`bin/run-local.sh:311`,
`bin/run-local-helpers.sh:758`). The character-class filter and
length cap match the spirit of the actor-sanitization already done by
`linear.sh::_render_event_header` (`bin/linear.sh:98-124`) for the
comment-header `[ENG-N · stage · … · actor]` token.

**Constraint reference.** `CLAUDE.md§"When wiring a new script"` —
"use `log` / `die` / `require_env` / `require_bin` from common.sh."
Actor resolution is best-effort: it never `die`s, never blocks the
decision from landing. The `git -C "$HARNESS_ROOT"` makes the resolver
worktree-independent (operator can run `bin/pipeline.sh` from anywhere
once `HARNESS_ROOT` resolves via `common.sh`).

**Rejected alternative.** Reading the GitHub App identity used by
`bin/gh-app-token.sh`. Rejected because: (a) the App identity is the
*bot*, not the operator who typed the command; (b) the App token is
short-lived and refreshed asynchronously — fetching it on every decide
call would introduce a non-trivial dependency on the network. The
ticket's "not security-grade; informative" disposition makes the
simpler local resolver correct.

### D-004 — Stage capture: reuse `linear.sh stage-of` once

**Decision.** Hoist the `linear.sh stage-of "$issue"` call from inside
the `continue` branch (`bin/pipeline.sh:511-515`) to before the
action-dispatch so all three actions get the same stage resolution.
On failure or non-`stage:*` label, render `-`.

**Why.** `current_stage` is computed in `cmd_decide` today only for the
operator-transition waypoint and the resume metric. To make
`human-decision` carry a useful `stage` field across all three actions,
the helper has to run on the approve/abandon paths too. The sanitization
already in place (lowercase-alpha-only or `unknown`) keeps the column
safe for downstream readers.

**Constraint reference.** `docs/architecture.md§"Discovery and the
project profile"` — "Per-issue scratch lives under
`$PROJECT_STATE_DIR/ENG-N/`." Stage is a per-issue Linear-label
attribute; one cheap `stage-of` call is the existing path.

**Rejected alternative.** Reading `issue-state.json::current_stage`.
Rejected because the file is allocator-owned and can be stale by ticks
relative to the current Linear label set; `stage-of` reads the
authoritative source.

### D-005 — `before_state` is a coarse symbolic token, not a state snapshot

**Decision.** Capture `before_state` as the highest-priority halt-class
label present on the issue at decide-time, resolved via
`linear.sh has-label`:

| Priority | Label                              | Token                       |
| -------- | ---------------------------------- | --------------------------- |
| 1        | `pipeline:halted`                  | `halted`                    |
| 2        | `pipeline:skip-until-human-acts`   | `skip-until-human-acts`     |
| 3        | `pipeline:skip-until-code-changes` | `skip-until-code-changes`   |
| 4        | (none of the above)                | `none`                      |

`after_state` is the deterministic outcome of the action: `resumed`
(continue) / `approved` (approve) / `abandoned` (abandon). It is the
metric's `outcome` field, not a notes token.

**Why.** Ticket decision goal lists `before_state` and `after_state`
as optional fields. The only states this CLI actually mutates that a
human-divergence calibrator cares about are: was-the-issue-halted, and
what-resolution-did-the-operator-pick. A coarse 4-token enum is enough
for the retrospective shape's count-and-bucket math; deeper snapshots
(wait-files contents, issue-state JSON, breaker state) are forensic
data and already live in `dispatch_history.jsonl` plus the existing
`halt-resume` notes.

**Constraint reference.** `CLAUDE.md§"Per-issue state directory"` —
the durable per-issue state is mediated by labels + `issue-state.json`
+ `wait-*.json`. The `before_state` token names the *label* axis, the
only axis the `decide` CLI is directly conditioned on (continue clears
the halt label; approve/abandon don't toggle halt labels).

**Rejected alternative.** Snapshotting the full label set and serializing
into notes. Rejected because notes become unboundedly large and the
calibrator does not need it — it needs to count "decisions per stage
per actor per week."

### D-006 — Test surface lives in `bin/pipeline-test.sh`, NOT `halt-sprawl-test.sh`

**Decision.** Add new test cases to `bin/pipeline-test.sh` exercising
the `human-decision` emission for all three actions. Do NOT edit
`bin/halt-sprawl-test.sh`.

**Why.** `halt-sprawl-test.sh` tests `poll.sh`'s halt-sprawl alert
emission (header at `bin/halt-sprawl-test.sh:1-3`); it has zero
coverage of `cmd_decide`. The Linear ticket's reference to
"halt-sprawl-test" appears to conflate two surfaces — `halt-resume`
metric emission is already tested in `bin/pipeline-test.sh:320-489`
(PR-N, PR-T, PR-X1, PR-X2, PR-X3). Adding `human-decision` cases
alongside the existing PR-N family is the colocated, low-surprise
choice.

**Flag (scope).** This deviates from the ticket's "Test coverage"
bullet. The deviation is mechanical (the same metric-capture stub
infrastructure already exists in `pipeline-test.sh`); the implementing
agent should NOT edit `halt-sprawl-test.sh` on the strength of the
ticket bullet alone.

**Rejected alternative.** Add a parallel `_AR_HD_METRICS_CALLS` capture
to `halt-sprawl-test.sh` purely to honor the ticket's bullet. Rejected
because it builds a second copy of the metric-stub apparatus far from
the SUT.

### D-007 — Keep `halt-resume` emission unchanged

**Decision.** The existing `bin/metrics.sh halt-resume` call from
`_pipeline_emit_resume_metric` continues to fire on `continue`
(post-resume side-effect accounting). `human-decision` is purely
additive.

**Why.** Per ticket decision #7: "new event type only; legacy code
ignoring unknown types continues to work." `halt-resume` is consumed
by tests (`bin/pipeline-test.sh:325`) and is the source of truth for
the atomic-reset counters (wait_files, skip_labels, state_file,
waypoint_posted, breaker_was_paused, auto_commit_paths). The new event
serves a different consumer (calibration shape) and a different shape
(decision-level, not side-effect-level).

**Rejected alternative.** Subsume `halt-resume` into `human-decision`
and drop the legacy event. Rejected because: (a) ticket decision #7
forbids it; (b) the existing tests pin `halt-resume`-prefix substring
matches that would have to be migrated in lockstep; (c) the two events
record orthogonal facts.

### D-008 — `human-decision` is NOT added to `bin/pipeline-events.json`

**Decision.** Do not extend the closed-vocabulary registry at
`bin/pipeline-events.json` with `human-decision`.

**Why.** That registry validates **Linear comment markers** (verdict /
transition / decision / meta), not **metric event names**. `metrics.sh`
intentionally accepts any string for the `event` argument
(`bin/metrics.sh:41`); `bin/metrics-test.sh:211-228` (case ENG-120) pins
this behavior. Adding the name to `pipeline-events.json` would imply
that the registry covers metrics, which it doesn't.

**Constraint reference.** `CLAUDE.md§"Pipeline vocabulary"` —
"`bin/pipeline-events.json` … via `bin/generate-vocabulary-doc.sh`. All
state-driving comments use `<!-- pipeline: <event> ... -->`."
`human-decision` is not state-driving — it's an audit trail.

**Rejected alternative.** Adding the name to the registry "for
discoverability." Rejected because the registry's `_validate_registry`
machinery would then have to either gain a new arm or silently accept
something it doesn't validate. The right discoverability move is a one-
liner in `CLAUDE.md` documenting the event shape — covered by the
ticket's "Files likely to change" bullet on `CLAUDE.md`.

## Architecture (where code goes)

### Modified files

| File                       | Change                                                                                                                                                                                                                                              |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bin/pipeline.sh`          | New `_pipeline_resolve_actor` and `_pipeline_resolve_before_state` helpers (8-12 lines each). New `_pipeline_emit_human_decision` helper that shells to `metrics.sh`. One call site at the tail of `cmd_decide`, post-`add-comment` success.         |
| `bin/pipeline-test.sh`     | New PR-HD-1 … PR-HD-N cases. Each invokes `_ar_decide` for a {continue, approve, abandon} action, asserts a `human-decision` line appears in the metrics capture, asserts notes contain the expected `action=…`, `actor=…`, `before_state=…` tokens. |
| `CLAUDE.md`                | Two-line addition under a new bullet noting `human-decision` event shape and the Linear-UI-edits limitation.                                                                                                                                        |

### Files NOT modified (despite ticket bullets)

| File                       | Reason                                                                                                                                                                                                                                |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bin/halt.sh`              | Does not exist. Merged into `bin/pipeline.sh::cmd_decide` via ENG-58/ENG-60 (see `bin/pipeline.sh:342-345`). The ticket name is stale.                                                                                                |
| `bin/metrics.sh`           | No schema change required (D-002). The free-form `event` argument already accepts `human-decision` verbatim; `notes` already carries `key=value` tokens; emission is via standard CLI call.                                          |
| `bin/halt-sprawl-test.sh`  | Wrong surface for the test (D-006). The file tests `poll.sh`'s halt-sprawl alert — adding cmd_decide cases there builds a second copy of the metric-capture apparatus far from the SUT.                                              |

### Code shape (sketch)

```bash
# bin/pipeline.sh — near the existing _pipeline_emit_resume_metric helper

_pipeline_resolve_actor() {
  local raw
  raw="$(git -C "$HARNESS_ROOT" config user.email 2>/dev/null || true)"
  [[ -z "$raw" ]] && raw="${USER-}"
  raw="$(printf '%s' "$raw" | tr -dc 'A-Za-z0-9._@+-' | head -c 64)"
  [[ -z "$raw" ]] && raw="unknown"
  printf '%s' "$raw"
}

_pipeline_resolve_before_state() {
  local issue="$1"
  for pair in \
    "pipeline:halted halted" \
    "pipeline:skip-until-human-acts skip-until-human-acts" \
    "pipeline:skip-until-code-changes skip-until-code-changes"; do
    local label="${pair% *}" token="${pair#* }"
    if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "$label" 2>/dev/null; then
      printf '%s' "$token"; return 0
    fi
  done
  printf 'none'
}

# _pipeline_emit_human_decision <issue> <stage> <action> [<gate>]
_pipeline_emit_human_decision() {
  local issue="$1" stage="$2" action="$3" gate="${4-}"
  local actor before_state outcome notes
  actor="$(_pipeline_resolve_actor)"
  before_state="$(_pipeline_resolve_before_state "$issue")"
  case "$action" in
    continue) outcome="resumed" ;;
    approve)  outcome="approved" ;;
    abandon)  outcome="abandoned" ;;
    *)        outcome="unknown" ;;
  esac
  notes="actor=$actor action=$action"
  [[ -n "$gate" ]] && notes+=" gate=$gate"
  notes+=" before_state=$before_state"
  bash "$SCRIPT_DIR/metrics.sh" human-decision "$issue" "$stage" \
    "$outcome" 0 "$notes" || true
}
```

Inside `cmd_decide`, after the `add-comment` success line:

```bash
# bin/pipeline.sh — append after `bash "$SCRIPT_DIR/linear.sh" add-comment …`
if [[ "${PIPELINE_DRY_RUN:-}" != "1" ]]; then
  local current_stage
  current_stage="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue" 2>/dev/null || printf 'unknown')"
  current_stage="${current_stage#stage:}"
  [[ "$current_stage" =~ ^[a-z]+$ ]] || current_stage="unknown"
  _pipeline_emit_human_decision "$issue" "$current_stage" "$action" "$gate"
fi
```

`continue` path already computed `current_stage` earlier (line 511);
the implementer can either hoist that variable to function scope or
call `stage-of` twice (the call is cheap and the dry-run/live branches
make hoisting awkward). The dry-run guard mirrors the rest of the
function: no metric emission on dry-run, matching the existing
`add-comment` dry-run behavior.

## Data flow

```
operator ──> bin/pipeline.sh decide ENG-N --action X [--gate G]
              │
              ├──> (action=continue only) atomic-reset side state
              │       └──> bin/metrics.sh halt-resume …      ← existing (D-007)
              │
              ├──> _render_body decision → linear.sh add-comment
              │       └──> Linear comment with `<!-- pipeline: decision … -->`
              │
              └──> _pipeline_emit_human_decision (this brainstorm)
                      ├── resolve actor (git config / $USER / unknown)
                      ├── resolve before_state (halt-class label scan)
                      ├── reuse current_stage from stage-of
                      └──> bin/metrics.sh human-decision …
                              └──> events.jsonl row:
                                  {"event":"human-decision",
                                   "issue_id":"ENG-N",
                                   "stage":"building",
                                   "outcome":"resumed",
                                   "notes":"actor=op@example.com action=continue before_state=halted",
                                   …}
```

Consumer (future calibration retrospective shape, P2a): `jq` over
`events.jsonl` filtering `.event == "human-decision"`, parsing
`notes` for `actor=`, `action=`, `before_state=`, joining against
verdict markers in the same issue's Linear comment stream to count
agent-recommended-vs-human-chose divergence.

## Error handling

| Failure mode                                                | Behavior                                                                                                                                                                  |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `git config user.email` not set, `$USER` empty              | Actor resolves to literal `unknown`. Metric still emitted.                                                                                                                |
| `linear.sh has-label` returns non-zero (network outage)     | `_pipeline_resolve_before_state` falls through to `none`. Metric still emitted.                                                                                           |
| `linear.sh stage-of` fails                                  | `current_stage` falls to `unknown` (existing fallback). Metric still emitted.                                                                                             |
| `metrics.sh` exits non-zero (disk full, jq missing)         | Call is followed by `|| true`. Decide CLI returns 0; emission failure is logged at metrics.sh level (existing behavior). Operator never sees a halted decide.             |
| Dry-run                                                     | Emission suppressed (mirrors `add-comment` dry-run gate).                                                                                                                  |
| Operator passes an invalid action (`--action banana`)       | `_validate_registry decision_actions` rejects before reaching the emission site (existing behavior, `bin/pipeline.sh:486`).                                                |
| Actor contains shell meta (`; rm -rf /`)                    | `tr -dc 'A-Za-z0-9._@+-'` strips it; `head -c 64` caps length. Notes is a `--arg` to jq inside `metrics.sh:60`, so payload is sanitized at the JSON layer too.            |

The guiding principle is "audit emission is never load-bearing." A
metric write failure must not surface to the operator as a failed
decision.

## Edge cases

### EC-1 — Operator runs `decide --action continue` twice in a row

Two rows land in `events.jsonl`. The second row's `before_state` will
be `none` (because the first call cleared `pipeline:halted`). This is
correct — it pins that the operator made two distinct decisions, and
the second was a no-op against an unhalted issue.

### EC-2 — Multiple humans run decisions on the same issue

Each invocation's `actor` is the local `git config user.email` at
invocation time. Cross-actor attribution works trivially because each
event is a separate row. The ticket explicitly carves out
"Cross-actor attribution for multi-human issues" as out-of-scope;
this is the minimum honest carry-through.

### EC-3 — `current_stage` is `released`, `null`, or `-`

`stage-of` returns the literal Linear label minus the `stage:` prefix;
on issues with no `stage:*` label, it returns empty or `unknown`. The
sanitization regex `^[a-z]+$` collapses anything else to `unknown`,
matching the existing operator-resume-waypoint sanitization
(`bin/pipeline.sh:424`).

### EC-4 — `PIPELINE_WRITER != human` on the decide path

`cmd_decide` already logs a warning for non-`human` writers
(`bin/pipeline.sh:565-567`). The `human-decision` event records the
attempt regardless — if the warning fires, the actor token will still
reflect the local git user, and a grep over `events.jsonl` for
`PIPELINE_WRITER != human` calls is a legitimate audit query.

### EC-5 — `approve --gate scope` vs `approve --gate build-cap`

`gate` token lands in notes as `gate=scope` or `gate=build-cap`. Both
are validated by `_validate_registry decision_gates`
(`bin/pipeline.sh:494`) before reaching the emission site, so notes is
guaranteed to carry a registry-blessed token or no `gate=` at all.

### EC-6 — Worktree is in `HARNESS_ROOT` vs `TARGET_REPO`

The actor resolver uses `git -C "$HARNESS_ROOT"`. Operators usually
run `bin/pipeline.sh` from either directory; the explicit `-C` makes
the result deterministic (and matches the harness convention of
attributing operator actions to the harness repo's git user, not the
target's).

### EC-7 — Calibration shape consumes events.jsonl with no `human-decision` rows yet

Empty result on the calibration filter is the honest signal. The
shape's prompt will say "0 human-decision events in window" — that is
the correct calibration baseline for harness deployments that have
not yet rolled the ENG-34 code.

## Open questions

### OQ-1 — Should `progress.md` also carry a human-decision breadcrumb?

`bin/progress-md` is the per-issue cross-dispatch notebook. The
ticket scope is `events.jsonl`. Writing to `progress.md` from
`cmd_decide` is tempting (a human-readable thread) but conflicts with
"orchestrator never reads or writes the file" (CLAUDE.md§"Per-issue
state directory" — the file is dispatch-agent-owned). **Disposition:**
out of scope for v1; the Linear comment thread + events.jsonl row are
the durable record. Re-open if the retrospective shape proves it
needs per-issue narrative context.

### OQ-2 — Capture `--gate` value for `continue`?

`continue` rejects `--gate` (`bin/pipeline.sh:491`). The notes
omission is therefore structural, not a bug. **Disposition:** leave
the `gate=` omission as the signal.

### OQ-3 — Should `human-decision` rows live in a separate JSONL?

A separate `decisions.jsonl` would isolate the audit trail. Per
ticket decision #6 ("existing `$PROJECT_STATE_DIR/metrics/events.jsonl`.
One metric file, multiple event types"), no — explicitly rejected.
Closed.

### OQ-4 — What about `set_orchestrator_paused` invoked by hand?

`bin/poll.sh::set_orchestrator_paused` and direct edits to
`state.local.json` are also operator-mediated state changes. They're
not routed through `cmd_decide` and so are not captured in v1. The
ticket's "Out of scope" explicitly covers this. **Disposition:**
documented limitation; possible v2 if the calibration shape says it's
load-bearing.

## Honest scope notes / ticket conflicts

1. **`bin/halt.sh` is a stale name.** The ticket says "emit on
   `bin/halt.sh resolve`"; that file has not existed since ENG-58/ENG-60
   merged its resolve logic into `bin/pipeline.sh::cmd_decide`. The
   brainstorm targets the correct chokepoint (see `bin/pipeline.sh:342-345`,
   which is the verbatim migration breadcrumb).
2. **`bin/halt-sprawl-test.sh` is the wrong test surface.** That file
   tests `poll.sh`'s halt-sprawl alert. The right test surface is
   `bin/pipeline-test.sh`, where `cmd_decide` and `halt-resume` are
   already exercised.
3. **`bin/metrics.sh` does not require a schema change.** `event` is
   already free-form (`bin/metrics.sh:41`, pinned by test case ENG-120
   at `bin/metrics-test.sh:211-228`); a CLAUDE.md note documenting the
   new event shape is sufficient.

These are flags for the planning agent — none are blockers; the ticket's
*intent* (a typed human-decision event) is fully preserved.

## ADR pressure / stress test

This feature does NOT contradict any existing ADR. It exercises
already-established patterns:

- **Append-only metrics** (`CLAUDE.md§"When wiring a new script"`):
  fully consistent — emission is via `metrics.sh`.
- **Lane-fenced writes** (ENG-41 / ENG-87 / `bin/linear.sh:341-369`):
  fully consistent — emission rides in metrics.sh, not in Linear; no
  new lane.
- **Closed-vocabulary registry for Linear markers**
  (`bin/pipeline-events.json`): fully consistent — `human-decision`
  is a metric event, not a Linear marker; registry is unaffected.
- **Dispatch-staleness contract (ENG-87):** fully consistent — the
  emission is on the **operator** path (no `PIPELINE_DISPATCH_ID`
  required, no marker auto-injection, no envelope-validator surface).

The one pressure point is small: D-002 chooses to encode actor /
action / before_state as `notes`-tokens rather than first-class
columns. If future calibration consumers want indexed queries over
those fields, they will have to either re-parse notes or migrate to
flag-pair columns. We are betting that the calibration shape's
weekly-volume aggregations are cheap enough to do that re-parsing
each week. If that proves false, a later ticket can promote the
fields to flag pairs without changing the schema of existing rows.

## Assumption inventory

All items below are verified against the current code unless marked
`(assumed)`.

| Assumption                                                                                                                                                                                                                                            | Status     | Evidence                                                                                          |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------ |
| `bin/halt.sh` does not exist in the worktree; resolve logic lives in `bin/pipeline.sh::cmd_decide`.                                                                                                                                                   | verified   | `bin/pipeline.sh:342-345` ("ported from halt.sh::resolve, ENG-60 merge"); `ls bin/halt*.sh` returns only `halt-sprawl-{test,adversarial-test}.sh`. |
| `bin/pipeline.sh::cmd_decide` is the single chokepoint for `continue|approve|abandon`.                                                                                                                                                                | verified   | `bin/pipeline.sh:472-575` (function definition + body); dispatched from `main` at line 583.       |
| `bin/metrics.sh` accepts any event name (no enum validation).                                                                                                                                                                                          | verified   | `bin/metrics.sh:41` (only non-empty check); test case ENG-120 at `bin/metrics-test.sh:211-228`.   |
| Existing `halt-resume` event is emitted from `_pipeline_emit_resume_metric` on continue only.                                                                                                                                                          | verified   | `bin/pipeline.sh:462-469` (caller); tests at `bin/pipeline-test.sh:320-489`.                      |
| `decision_actions = [continue, approve, abandon]` and `decision_gates = [scope, build-cap]` registry entries are present.                                                                                                                              | verified   | `bin/pipeline-events.json:41-48`.                                                                 |
| `linear.sh stage-of` returns the `stage:*` label, sanitizable to lowercase-alpha.                                                                                                                                                                      | verified   | `bin/pipeline.sh:511-515` (existing usage and sanitization pattern).                              |
| `linear.sh has-label` returns 0/non-zero usable as a `if` predicate.                                                                                                                                                                                   | verified   | `bin/pipeline.sh:369` (existing usage in `_pipeline_drain_skip_labels`); `bin/pipeline.sh:523`.   |
| `git -C "$HARNESS_ROOT" config user.email` is the canonical operator-attribution surface used elsewhere in the codebase.                                                                                                                              | verified   | `bin/run-local.sh:311`, `bin/run-local-helpers.sh:758`, `bin/run-retrospective-local.sh:230`.    |
| Actor sanitization mirrors the `linear.sh::_render_event_header` actor-token treatment.                                                                                                                                                                 | verified   | `bin/linear.sh:98-124` (header-render path).                                                      |
| `bin/pipeline-test.sh` already exercises `halt-resume` metric emission via `_ar_decide` + `_AR_METRICS_CALLS` capture.                                                                                                                                  | verified   | `bin/pipeline-test.sh:320-489` (PR-N, PR-T, PR-X1, PR-X2, PR-X3 cases).                           |
| `bin/halt-sprawl-test.sh` tests `poll.sh`'s halt-sprawl alert, not halt resolution.                                                                                                                                                                    | verified   | `bin/halt-sprawl-test.sh:1-3` (file header comment).                                              |
| `cmd_decide` skips metric emission under `PIPELINE_DRY_RUN=1`.                                                                                                                                                                                          | verified   | `bin/pipeline.sh:569-572` (add-comment dry-run gate). Our new emission mirrors this pattern.      |
| `metrics.sh` writes one JSONL row per call; appends to `$PROJECT_STATE_DIR/metrics/events.jsonl`.                                                                                                                                                       | verified   | `bin/metrics.sh:43,67-74`.                                                                        |
| ENG-42 brainstorm cross-references this ticket's event name verbatim, so `human-decision` is the agreed-on spelling.                                                                                                                                    | verified   | `docs/brainstorms/2026-04-28-eng-42-reframe-implement-pr-guard-design.md:84,181`.                 |
| The calibration retrospective shape (P2a) is the consumer; it does not exist yet and will be designed against whatever `events.jsonl` carries.                                                                                                          | assumed    | No shape file exists at `bin/retro-shape-calibration*.sh` as of this brainstorm. The ticket states this is a prerequisite; implementing agent should not add the shape. |
| Notes-token parsing (`key=value` space-separated) is acceptable to the future calibration consumer.                                                                                                                                                     | assumed    | Mirrors `halt-resume`'s existing notes shape; the consumer doesn't exist yet so this is forward-looking. |

## Persona review

(All six personas executed by this brainstorming agent in the order
design → security → scope → coherence → product → feasibility.)

### Persona 1 — Design — PASS

The chokepoint is correctly identified. `cmd_decide` is the single
entrypoint, the emission is placed past `add-comment`'s success line
so we don't record decisions that didn't land. The `_pipeline_emit_*`
helper naming matches the existing module convention. Schema
extension via notes-tokens matches the `halt-resume` precedent.

One nit: the function does two `stage-of` calls on the `continue`
path (once inside the existing block, once again on the human-decision
path). The implementing agent can either hoist or accept the
duplication. Either is acceptable; flagged as implementation detail,
not a design defect.

### Persona 2 — Security — PASS

- Actor token is `tr -dc 'A-Za-z0-9._@+-'`-sanitized and length-capped
  before reaching the JSONL writer; defense-in-depth at the `jq --arg`
  layer in `metrics.sh:60`.
- `before_state` token is drawn from a closed enumeration, never
  user-supplied.
- `stage` token is regex-checked to `^[a-z]+$` (existing pattern).
- No new shell-eval surface, no new env-var ingestion path.
- Per CLAUDE.md§"Secret-handling (ENG-46)": no `${VAR:-FALLBACK}`
  pattern against KEY/TOKEN/SECRET variables anywhere in the new code.
- The `notes` field is passed through `jq --arg` (`bin/metrics.sh:60`),
  not concatenated into shell-evaluable strings — log-injection safe.
- No PII beyond what's already in git commits.

### Persona 3 — Scope — PASS (with two flags)

The brainstorm matches the ticket's "explicit human actions only" v1
scope. The two scope flags are:

1. **D-006 deviates from the ticket's "extend `bin/halt-sprawl-test.sh`"
   bullet** — flagged in §D-006 with the rationale (wrong test
   surface). Implementing agent should NOT edit `halt-sprawl-test.sh`.
2. **D-007 / D-008: no changes to `bin/metrics.sh` or
   `bin/pipeline-events.json`** — flagged. The ticket's "Files likely
   to change" bullet on `metrics.sh` is mooted by D-002 (existing
   schema already accepts the event); only the documentation in
   CLAUDE.md changes.

Both flags are ticket-implementation-detail divergences, not scope
expansions. The v1 surface stays "emit on harness-mediated explicit
operator actions." Out-of-scope items (inferred detection, Slack-side
decisions, PR-review signals, cross-actor attribution, sentiment
capture) are NOT touched by any decision in this doc.

### Persona 4 — Coherence — PASS

- ENG-42 brainstorm referenced `human-decision` by name → this doc
  produces that exact event name. **Coherent.**
- ENG-58 / ENG-60 atomic-reset contract preserved; `halt-resume` event
  unchanged. **Coherent.**
- ENG-87 dispatch-staleness contract not exercised on this path
  (operator-lane, no dispatch ID). **Coherent.**
- ENG-41 lane-fencing not exercised on the metric-write path. The
  Linear comment that `cmd_decide` already posts is the only
  lane-fenced surface and it is unchanged. **Coherent.**
- `bin/pipeline-events.json` registry contract preserved — no metric
  event names sneak into it. **Coherent.**

### Persona 5 — Product — PASS

The ticket's product motivation is "calibration retrospective shape
needs this as its primary divergence signal." This brainstorm produces
exactly the signal the calibration shape will need (per-decision row
with actor, action, before-state). The honest limitation about
Linear-UI direct edits is preserved per the ticket. v1 is the minimum
shippable surface; the brainstorm does not over-build.

### Persona 6 — Feasibility — PASS (zero P0)

Every named function, file, line range, and pattern referenced in this
brainstorm has been verified against the current code (see Assumption
inventory). Specifically:

- `bin/pipeline.sh::cmd_decide` exists at line 472 — verified.
- `bin/pipeline.sh::_pipeline_emit_resume_metric` exists at line 462 —
  verified.
- `bin/metrics.sh` is generic (free-form event) — verified
  (`bin/metrics.sh:41`, `bin/metrics-test.sh:211`).
- `bin/halt.sh` does NOT exist — verified (`ls bin/halt*.sh` →
  `halt-sprawl-test.sh`, `halt-sprawl-adversarial-test.sh`).
- `bin/pipeline-events.json` contains `decision_actions` and
  `decision_gates` — verified (lines 41-48).
- `linear.sh has-label`, `stage-of` exist and are usable as predicates
  — verified (`bin/pipeline.sh:369,523,512`).
- `git config user.email` is the canonical operator-attribution
  surface — verified across `run-local.sh:311`,
  `run-local-helpers.sh:758`, `run-retrospective-local.sh:230`.
- The cross-reference to ENG-42's mention of `human-decision` is
  exact — verified at `docs/brainstorms/2026-04-28-eng-42-reframe-implement-pr-guard-design.md:84,181`.

No code-level claim in this brainstorm references a method or file
that doesn't exist. Zero P0 findings. Feasible to implement in a
single ticket against the current codebase.

### Persona gate

| Persona      | Verdict | P0 |
|--------------|---------|----|
| Design       | PASS    | 0  |
| Security     | PASS    | 0  |
| Scope        | PASS    | 0  |
| Coherence    | PASS    | 0  |
| Product      | PASS    | 0  |
| Feasibility  | PASS    | 0  |

**Gate: 6/6 PASS · Feasibility P0: 0 · proceeding to planning.**
