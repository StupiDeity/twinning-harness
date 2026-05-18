---
linear: ENG-112
title: Linear ledger — ledger schema in pipeline-events.json
date: 2026-05-18
status: draft
---

# Linear ledger — ledger schema in pipeline-events.json

## 1. Overview / Problem

`bin/pipeline-events.json` today is a registry of **value enums** —
`verdict_results`, `halt_reasons`, `stages`, `decision_actions`, etc.
It says which tokens are legal but it does NOT say which tokens
combine into a legal **comment body**.

The "what combines" rules live as inline `case` branches in
`bin/pipeline.sh`:

- `cmd_event_verdict` (L86-139) hand-codes required-field-per-result
  (`pass` requires `--stage`, `fail` requires `--target`, `halt`
  requires `--reason`, `wait` requires `--reason`, `pivot` requires
  `--target`).
- `cmd_event_transition` (L146-170) hand-codes `from`/`to` required.
- `cmd_decide` (L302-401) hand-codes `--gate` conditionally required
  by action.
- Body shape (`<!-- pipeline: <event> k=v ... -->`) is duplicated as
  printf strings in three places.
- The **dedup sig** policy (when a writer should route through
  `add_or_update_comment` instead of `add_comment`, and what sig to
  use) is implicit — `cmd_event_verdict` always calls `add-comment`;
  the sig-bearing flow lives in `classify-failure.sh`, `run-stage.sh`,
  `guards.sh`, etc., each rolling its own `halt/<stage>/<issue>` or
  `scope-approval/<stage>/<issue>` literal.

Two consequences:

1. A new event (or a new arm of an existing event) requires three
   edits (registry enum, validation `case`, body printf) plus
   convention-by-grep for the dedup sig. ENG-58, ENG-60, ENG-87,
   ENG-111 all touched at least two of those sites; nothing forced
   them to stay coherent.
2. There is no machine-readable description of "what a halt comment
   for the implementing stage looks like" — the retrospective agent,
   the vocabulary doc, and any future tooling have to re-derive it
   from the call sites.

ENG-112 codifies the contract: every ledger-emitting event gets a
`linear_comment` schema object in `pipeline-events.json` that names
required + optional fields, the body shape, the dedup-sig policy,
and the writer lane. `bin/pipeline.sh` consults the schema instead
of hand-coding the rules. `docs/pipeline-vocabulary.md` regenerates
a section from the schema so the public contract reads the same way
the validator does.

Acceptance criteria from the ticket, mapped to the design below:

| AC | What | Where covered |
|---|---|---|
| #1 | `pipeline-events.json` carries `linear_comment` schema for every ledger-emitting event | D-001 |
| #2 | `bin/pipeline.sh event ...` rejects payloads that violate the schema | D-002 |
| #3 | `docs/pipeline-vocabulary.md` surfaces the new schema section | D-003 |

Out of scope (per the ticket): refactoring **call sites** that emit
markers outside `bin/pipeline.sh` (`classify-failure.sh` writes halt
markers directly via `linear.sh add-or-update-comment`;
`run-local.sh` writes its own halt comments). Those are separate
follow-ups — this ticket lands the schema + the `pipeline.sh`
validator only.

## 2. Decisions

### D-001. Add a single top-level `events` object in `pipeline-events.json`; each event carries one `linear_comment` schema object.

**Decision.** Extend `bin/pipeline-events.json` with a new top-level
key:

```json
{
  "events": {
    "verdict": {
      "linear_comment": {
        "body_shape": "<!-- pipeline: verdict result=<result> [stage=<stage>] [target=<target>] [reason=<reason>] -->",
        "writer_lane": "agent",
        "required": ["result"],
        "required_by_arm": {
          "pass":  ["stage"],
          "fail":  ["target"],
          "halt":  ["reason"],
          "wait":  ["reason"],
          "pivot": ["target"]
        },
        "field_registry": {
          "result": "verdict_results",
          "stage":  "stages",
          "target": "fail_targets|pivot_targets",
          "reason": "halt_reasons|wait_reasons"
        },
        "dedup_sig_by_arm": {
          "pass":  null,
          "fail":  null,
          "halt":  "halt/<stage>/<issue>",
          "wait":  "wait/<stage>/<issue>",
          "pivot": null
        }
      }
    },
    "transition": {
      "linear_comment": {
        "body_shape": "<!-- pipeline: transition from=<from> to=<to> [reason=<reason>] -->",
        "writer_lane": "orchestrator",
        "required": ["from", "to"],
        "optional": ["reason"],
        "field_registry": {
          "from":   "stages",
          "to":     "stages",
          "reason": null
        },
        "dedup_sig": null
      }
    },
    "decision": {
      "linear_comment": {
        "body_shape": "<!-- pipeline: decision action=<action> [gate=<gate>] -->",
        "writer_lane": "human",
        "required": ["action"],
        "optional": ["gate"],
        "required_by_arm": {
          "continue": [],
          "approve":  ["gate"],
          "abandon":  ["gate"]
        },
        "field_registry": {
          "action": "decision_actions",
          "gate":   "decision_gates"
        },
        "dedup_sig": null
      }
    }
  }
}
```

**Reasoning.** Three events drive the ledger today (`verdict`,
`transition`, `decision`). Wrapping each in an `events.<name>.linear_comment`
object keeps the schema co-located with the value registry it
references (`field_registry` points at sibling enum arrays) so the
generator script and the validator can resolve everything from one
file. The shape mirrors what `bin/pipeline.sh::cmd_event_*` already
hand-codes — see §3.

**Alternative considered.** A separate `pipeline-comment-schema.json`
file. Rejected: the schema is dead weight without the value enums
it references, and the call sites already read `pipeline-events.json`;
adding a second file means two `jq` calls per validation and a
cross-file drift risk.

### D-002. `bin/pipeline.sh` consults `events.<name>.linear_comment` via a single shared validator.

**Decision.** Add a helper `_validate_event_payload <event> <arm> <k=v>...`
in `bin/pipeline.sh` that:

1. Loads `events.<event>.linear_comment` from `pipeline-events.json`.
2. Resolves the `required_by_arm[<arm>]` (if present) ∪ `required[]` set.
3. For each `k=v` in the supplied args:
   - If `field_registry[k]` is set, run `_validate_registry` against
     it (existing helper, line 80-84). For pipe-union shapes like
     `"fail_targets|pivot_targets"`, split and try each.
   - If `field_registry[k]` is null/absent and `k` isn't a known
     required/optional field, die with "unknown field 'k'".
4. Die if any required field is missing.
5. Return the canonical body via `_render_body <event> <k=v>...` — a
   second helper that walks the body_shape template and substitutes
   the supplied values, omitting bracketed `[k=<v>]` segments where
   `v` wasn't supplied.

`cmd_event_verdict`, `cmd_event_transition`, `cmd_decide` collapse
from ~50 lines of case-statements into ~10 lines each: parse flags
into a `k=v` array, call `_validate_event_payload`, call
`_render_body`, post via `linear.sh add-comment` (or
`add-or-update-comment` when `dedup_sig_by_arm[<arm>]` is non-null —
see D-004).

**Reasoning.** Two helpers, one schema, three call sites. The
inline `case` branches become DATA, which means a new event arm
ships as a single-file diff to `pipeline-events.json` plus a
regenerated doc — no validator code change.

**Alternative considered.** A full JSON Schema with `ajv` /
`python jsonschema` validation. Rejected: introduces a runtime
dependency the harness doesn't have today (every script is bash +
`jq`); the field set is small enough that `jq` walks the schema
directly.

### D-003. `docs/pipeline-vocabulary.md` gets a new generated section "Comment schemas" between the Anatomy and the closed-registry block.

**Decision.** Extend `bin/generate-vocabulary-doc.sh` to emit a
**Comment schemas** section before the existing
`<!-- GENERATED:registry -->` block. The new section uses a second
sentinel pair:

```markdown
<!-- GENERATED:event-schemas -->
## Comment schemas

Source: `bin/pipeline-events.json::events` — edit there, not here.

### `verdict`

- **Body shape:** `<!-- pipeline: verdict result=<result> ... -->`
- **Writer lane:** `agent`
- **Required fields:** `result`
- **Required by arm:**
  - `pass`: `stage`
  - `fail`: `target`
  - `halt`: `reason`
  - `wait`: `reason`
  - `pivot`: `target`
- **Dedup sig:**
  - `halt`: `halt/<stage>/<issue>`
  - `wait`: `wait/<stage>/<issue>`
  - (other arms: append-only)

(transition, decision sections follow the same template.)
<!-- /GENERATED:event-schemas -->
```

The existing `docs/pipeline-vocabulary.template.md` (sibling of the
generated doc) gains a `<!-- GENERATED:event-schemas -->` /
`<!-- /GENERATED:event-schemas -->` pair; the generator's
substitution loop fills both.

**Reasoning.** The pre-existing generator already does a perl-based
sentinel substitution for the registry section (see
`bin/generate-vocabulary-doc.sh:30-42`). Adding a second sentinel
pair is a mechanical extension; the template file owns the prose
around each generated block.

### D-004. Carry an internal-only `dedup_sig` route flag; **do NOT switch existing pipeline.sh writers to `add-or-update-comment`** in this ticket.

**Decision.** `pipeline-events.json::events.verdict.linear_comment.dedup_sig_by_arm`
documents the canonical sig for `halt` and `wait`, but
`bin/pipeline.sh::cmd_event_verdict` continues to call
`linear.sh add-comment` for every arm (today's behavior). Reason:
the halt-comment sig writers today are `classify-failure.sh` and
`run-local.sh`, NOT `pipeline.sh` — `pipeline.sh event verdict halt`
is the operator's manual override path, where append-only is the
right shape (an operator-emitted halt should never silently rewrite
the orchestrator's prior halt).

Surfacing the sig in the schema lets the documentation + future
refactors of `classify-failure.sh` (out of scope here) read the
contract from one place.

**Reasoning.** Migration of existing call sites is explicitly out of
scope per the ticket's "OUT" section. Schema + validator only, no
call-site refactor; the dedup-sig field is documentation today and
hook point tomorrow.

### D-005. Schema validation is a die-loud `set -euo pipefail` path; no fail-open soft fallback.

**Decision.** A schema mismatch in `_validate_event_payload`
terminates with `die "..."`, surfacing the offending field name and
the allowed registry. There is no warn-and-emit-anyway path.

**Reasoning.** `bin/pipeline.sh` is operator-and-agent-facing: a
malformed marker that lands silently in Linear corrupts the
state-machine read path (`parse_pipeline_marker`, `find_fresh_verdict`)
in non-obvious ways. The cost of die-loud is one operator retry; the
cost of fail-open is a corrupt ledger.

**Alternative considered.** A `PIPELINE_SCHEMA_STRICT=0` env-var
that downgrades die to warn. Rejected for the same reason as D-002's
runtime dep: extra knob, more failure modes, no observed need.

### D-006. Add tests in `bin/pipeline-test.sh` covering the validator's pass/fail paths for each event arm.

**Decision.** Extend `bin/pipeline-test.sh` with one test function
per event arm covering:

- B-001 (verdict.pass): missing `--stage` → die.
- B-002 (verdict.fail): missing `--target` → die; unknown `target` value → die.
- B-003 (verdict.halt): missing `--reason` → die; unknown reason → die; success path produces canonical body shape.
- B-004 (verdict.wait): same shape as halt with `wait_reasons` registry.
- B-005 (verdict.pivot): missing `--target` → die.
- B-006 (transition): missing arrow → die; unknown stage in `from` or `to` → die.
- B-007 (decision.continue): no `--gate` succeeds; with `--gate` → die.
- B-008 (decision.approve / abandon): missing `--gate` → die.
- B-009 (unknown field): supplying `--bogus foo` → die.
- B-010 (generator round-trip): generate `docs/pipeline-vocabulary.md`, grep for one verdict schema section, assert presence.

**Reasoning.** The existing `bin/pipeline-test.sh` is 599 lines and
already tests the registry-validation paths; the new tests slot
into the same harness pattern. B-010 catches generator-template
drift.

## 3. Reference: today's code paths to refactor

### 3.1 `cmd_event_verdict` — `bin/pipeline.sh:86-139`

Today's hand-coded shape (excerpt):

```bash
case "$result" in
  pass)  [[ -n "$stage" ]]  || die "event verdict pass: --stage required"
         _validate_registry stages "$stage" ;;
  fail)  [[ -n "$target" ]] || die "event verdict fail: --target required"
         _validate_registry fail_targets "$target" ;;
  ...
esac

# Build the marker body.
local body="<!-- pipeline: verdict result=$result"
[[ -n "$stage" ]]  && body="$body stage=$stage"
[[ -n "$target" ]] && body="$body target=$target"
[[ -n "$reason" ]] && body="$body reason=$reason"
body="$body -->"
```

After the refactor: parse flags into `args=(result=$result
[stage=$stage] [target=$target] [reason=$reason])` (omitting empty
slots), call `_validate_event_payload verdict "$result" "${args[@]}"`,
call `body="$(_render_body verdict "${args[@]}")"`, post.

### 3.2 `cmd_event_transition` — `bin/pipeline.sh:146-170`

Similar transformation. The arrow-parse stays inline (it's a CLI
ergonomics layer — schema describes the body, not the CLI flags);
schema validates `from` and `to` against `stages`.

### 3.3 `cmd_decide` — `bin/pipeline.sh:302-401`

`continue` / `approve` / `abandon` per-action `--gate` rules collapse
into `required_by_arm`. The atomic-reset side effects (drain wait
files, skip labels, breaker, etc.) stay untouched — they're not part
of the comment-shape contract.

## 4. Risks / open questions

- **R-001.** `_render_body` template substitution needs an escape
  strategy for arrows / brackets in the body_shape. Mitigation:
  template uses literal `<field>` placeholders, validator rejects
  values containing `<` or `>` or `-->`; the field-registry
  validation already restricts most fields to enum tokens (no
  symbols).
- **R-002.** `field_registry` pipe-union (`"fail_targets|pivot_targets"`)
  is unusual. The single field where this matters is `target`,
  whose legal set depends on the arm. An alternative is to put
  `target` into `required_by_arm.<arm>.registry` overrides. Decided
  against that to keep the schema flat — verdict has only two arms
  using `target` (`fail`, `pivot`) and the pipe-union is one extra
  jq split.
- **OQ-1.** Should the schema record a marker's parsing partner
  (`parse_pipeline_marker` in `common.sh`)? Today the parser is
  hand-rolled regex; one could imagine generating it from the
  body_shape. Out of scope for ENG-112 — file as ENG-X follow-up
  if observed need.

## 5. Out of scope

- Refactoring `classify-failure.sh`, `run-local.sh`, `guards.sh`,
  `poll.sh` halt/wait/scope-approval emitters to route through the
  new validator. Each is its own follow-up; per the ticket "OUT"
  section.
- A JSON Schema (RFC) implementation. The schema described here is
  a domain-specific shape, validated by ~30 lines of jq + bash.
- Generating `parse_pipeline_marker` from the body_shape (see OQ-1).
