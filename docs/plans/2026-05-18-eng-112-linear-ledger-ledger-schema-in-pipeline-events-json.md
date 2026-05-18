---
linear: ENG-112
date: 2026-05-18
topic: Linear ledger — ledger schema in pipeline-events.json
---

# ENG-112 — Plan: ledger schema in pipeline-events.json

## 1. Goal

Codify the Linear-comment ledger contract as a machine-readable
`events.<name>.linear_comment` schema in `bin/pipeline-events.json`.
Refactor `bin/pipeline.sh` to consult that schema (instead of inline
`case` branches) when validating and rendering `verdict`,
`transition`, and `decision` marker bodies. Regenerate
`docs/pipeline-vocabulary.md` to surface a "Comment schemas"
section. Land tests in `bin/pipeline-test.sh`.

Brainstorm: [docs/brainstorms/2026-05-18-eng-112-linear-ledger-ledger-schema-in-pipeline-events-json-design.md](../brainstorms/2026-05-18-eng-112-linear-ledger-ledger-schema-in-pipeline-events-json-design.md).

## 2. Assumption Inventory

Branch rebased onto `origin/main` (`2b07c7e`) at plan time. All line
numbers below are anchors valid at this base; the implementer
re-verifies each anchor before each Edit.

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A1 | `bin/pipeline.sh::cmd_event_verdict` at `:86-139`. Per-result required-field branches live at `:103-115`. Body printf at `:117-122`. | **verified** | Read `bin/pipeline.sh:86-139` post-rebase. |
| A2 | `bin/pipeline.sh::cmd_event_transition` at `:146-170`. Arrow parser + stage validation at `:152-156`; body printf at `:158`. | **verified** | Read `bin/pipeline.sh:146-170`. |
| A3 | `bin/pipeline.sh::cmd_decide` at `:302-401`. Per-action --gate branches at `:320-325`; body printf at `:387-389`. | **verified** | Read `bin/pipeline.sh:302-401`. |
| A4 | `bin/pipeline.sh::_validate_registry` (`:80-84`) is the existing value-enum validator; reused by the new helper. | **verified** | Read `bin/pipeline.sh:80-84`. |
| A5 | `bin/pipeline.sh::REGISTRY` constant (`:28`) points at the JSON file via `$SCRIPT_DIR/pipeline-events.json`. | **verified** | Read `bin/pipeline.sh:28`. |
| A6 | `bin/generate-vocabulary-doc.sh` (46 lines) uses one perl-based sentinel substitution `<!-- GENERATED:registry --> ... <!-- /GENERATED:registry -->`. Adding a second sentinel pair is mechanical. | **verified** | Read `bin/generate-vocabulary-doc.sh` end-to-end. |
| A7 | `docs/pipeline-vocabulary.md` contains the single `<!-- GENERATED:registry -->` block at `:147-221`. The template file (`docs/pipeline-vocabulary.template.md`) carries the same sentinel and the prose around it. | **verified** | Read `docs/pipeline-vocabulary.md:147-221`. |
| A8 | `bin/pipeline-test.sh` is 599 lines; uses `STUB_DIR`-style mocks for `linear.sh`; asserts via grep on captured Linear payloads. | **verified** | `wc -l bin/pipeline-test.sh` + spot-read. |
| A9 | `docs/pipeline-vocabulary.template.md` exists and is the perl-substitution target (line 8 of `bin/generate-vocabulary-doc.sh`). | **assumed (verify on first run)** | Generator reads `$HARNESS_ROOT/docs/pipeline-vocabulary.template.md`. |

## 3. File Structure

| File | Change | Status |
|---|---|---|
| `bin/pipeline-events.json` | Modify — append top-level `events.{verdict,transition,decision}.linear_comment` objects. | modified |
| `bin/pipeline.sh` | Modify — add `_validate_event_payload` + `_render_body` helpers; collapse `cmd_event_verdict`, `cmd_event_transition`, `cmd_decide` body-building onto the helpers. Per-action atomic-reset side effects in `cmd_decide` unchanged. | modified |
| `bin/generate-vocabulary-doc.sh` | Modify — add a second sentinel substitution emitting a "Comment schemas" section sourced from `events.*.linear_comment`. | modified |
| `docs/pipeline-vocabulary.template.md` | Modify — insert the `<!-- GENERATED:event-schemas -->` / `<!-- /GENERATED:event-schemas -->` sentinel pair with prose framing. | modified |
| `docs/pipeline-vocabulary.md` | Auto-regenerated via `bash bin/generate-vocabulary-doc.sh`. | regenerated |
| `bin/pipeline-test.sh` | Modify — add ENG-112 test block (B-001..B-010) at the end of the file. | modified |
| `docs/brainstorms/2026-05-18-eng-112-...-design.md` | New (already on disk; staged from this dispatch). | new |
| `docs/plans/2026-05-18-eng-112-...-ledger-schema-in-pipeline-events-json.md` | New (this file). | new |
| `docs/plans/2026-05-18-eng-112-...-ledger-schema-in-pipeline-events-json.json` | New — plan-schema-v1 contract sibling. | new |

**Out of scope:** every call site that emits markers OUTSIDE
`bin/pipeline.sh` (`classify-failure.sh`, `run-local.sh::scope_handle`,
`guards.sh`, `poll.sh`, `verdict-handler.sh`). The schema documents
their dedup-sig contract; refactoring them to consult the schema is
a follow-up.

## 4. API Contract

No new public API. `bin/pipeline.sh event/decide` arguments are
identical to today's CLI. Schema validation runs internally; bad
inputs produce the same `die` messages humans saw before (registry
membership errors come from the same `_validate_registry`).

The `events.<name>.linear_comment` schema in `pipeline-events.json`
becomes a public-doc contract surfaced via
`docs/pipeline-vocabulary.md`.

## 5. Backend Tasks

### Task 1 — `bin/pipeline-events.json`: add `events` schema block

Append a top-level `events` object after the existing `stages`
array. Three sub-objects: `verdict`, `transition`, `decision`. Each
carries a single `linear_comment` schema per brainstorm §2 D-001.

Shape sketch (verbatim from brainstorm D-001):

```json
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
```

Pass criterion: `jq -r '.events | keys[]' bin/pipeline-events.json`
yields three lines: `decision`, `transition`, `verdict` (jq sorts
keys lexicographically). `jq . bin/pipeline-events.json >/dev/null`
parses clean.

### Task 2 — `bin/pipeline.sh`: add `_validate_event_payload` helper

Add a helper between `_validate_registry` (`:80-84`) and
`cmd_event_verdict` (`:86`).

Signature: `_validate_event_payload <event> <arm> <k=v>...`.

Body:

1. Read `events.$event.linear_comment` from `$REGISTRY` into a local
   `schema` JSON blob via `jq -c`.
2. If absent, `die "schema: no linear_comment for event '$event'"`.
3. Compute the union of `required[]` and `required_by_arm.$arm[]`
   into a bash array `req`.
4. Build an associative array `got=([result]=pass [stage]=brainstorming ...)`
   from the `k=v` args.
5. For each `req` field: assert `${got[$f]:+x}` is set; else
   `die "schema: $event $arm requires '$f'"`.
6. For each `got` key `k`:
   - If `field_registry.$k` is non-null, split on `|`, try each
     enum; die if none match. Reuses `_validate_registry`.
   - If `k` is not in (required ∪ optional ∪ field_registry keys),
     `die "schema: unknown field '$k' on event '$event'"`.
7. Return 0.

Pass criterion: grep `^_validate_event_payload\(\)` in
`bin/pipeline.sh` returns one match; `bash -n bin/pipeline.sh`
parses clean.

### Task 3 — `bin/pipeline.sh`: add `_render_body` helper

Add helper signature: `_render_body <event> <k=v>...`. Emits the
canonical body string to stdout.

Body:

1. Read `events.$event.linear_comment.body_shape` into local `tmpl`.
2. Parse `tmpl` into LITERAL segments and PLACEHOLDER segments
   (`<field>`) and OPTIONAL groups (`[k=<field>]`).
3. Build `got` map from args (same as in `_validate_event_payload`).
4. Walk segments: emit literals verbatim; substitute placeholders
   from `got`; include optional groups only if their placeholder
   has a value in `got`.
5. Refuse to emit if any required placeholder is missing —
   defensive, since the validator should have run first.

Implementation hint: keep the parser dumb. The body_shape templates
are flat and follow `prefix <literal> [opt1=<v1>] [opt2=<v2>] -->`.
A bash regex split on ` ` plus per-token classification is enough;
no full templating engine.

Pass criterion: grep `^_render_body\(\)` in `bin/pipeline.sh`
returns one match; `bash -n bin/pipeline.sh` parses clean.

### Task 4 — `bin/pipeline.sh`: collapse `cmd_event_verdict` body construction onto helpers

Replace lines 103-122 (per-result `case` + body printf):

- Build `args=(result=$result)` initially.
- Append `stage=$stage`, `target=$target`, `reason=$reason` for any
  non-empty values.
- Call `_validate_event_payload verdict "$result" "${args[@]}"` —
  validator dies on the same shapes today's `case` dies on (missing
  required field, unknown registry value).
- Call `body="$(_render_body verdict "${args[@]}")"`.
- Lane-warning + dry-run + `linear.sh add-comment` lines below stay
  unchanged.

Pass criterion: grep `_validate_event_payload verdict` in
`bin/pipeline.sh` returns at least one match; the inline `case
"$result"` block at the old `:103-115` is gone (grep for
`pass)  \[\[ -n "\$stage"` returns zero matches).

### Task 5 — `bin/pipeline.sh`: collapse `cmd_event_transition` body construction onto helpers

Replace lines 152-158 (stage registry checks + body printf):

- Parse the arrow (existing `from="${arrow%% → *}"; to="${arrow##* → }"`
  remains the CLI ergonomics layer).
- Build `args=(from=$from to=$to)`.
- Call `_validate_event_payload transition "" "${args[@]}"` — the
  arm slot is empty for transition.
- Call `body="$(_render_body transition "${args[@]}")"`.

Pass criterion: grep `_validate_event_payload transition` in
`bin/pipeline.sh` returns at least one match.

### Task 6 — `bin/pipeline.sh`: collapse `cmd_decide` body construction onto helpers

Replace the body-printf block at `:387-389`:

- Build `args=(action=$action)`; append `gate=$gate` when non-empty.
- Call `_validate_event_payload decision "$action" "${args[@]}"` —
  validator catches the existing "continue: --gate not allowed"
  shape via the `required_by_arm.continue = []` arm AND a generic
  "unknown field" check; replaces the inline `case "$action" in
  continue) ...` rule at `:320-325`.

  Caveat: `required_by_arm.continue = []` says "no extras required";
  it does NOT say "extras forbidden." The "--gate not allowed for
  continue" rule today is an exclusion, not an inclusion check.
  Keep that inline `case` branch (`:320-325`) UNCHANGED — schema
  validation is additive, and the exclusion check survives at the
  CLI layer where it was. Document this in the helper docstring.

- Call `body="$(_render_body decision "${args[@]}")"`.

Pass criterion: grep `_validate_event_payload decision` in
`bin/pipeline.sh` returns at least one match.

### Task 7 — `bin/generate-vocabulary-doc.sh`: add Comment schemas generator

Extend the script:

1. Add a second function `event_schemas()` that emits the
   "Comment schemas" markdown block. Walks
   `jq -r '.events | keys[]'`; for each event prints body shape,
   writer lane, required fields, per-arm required fields, dedup
   sig (when present).
2. Add a second `mktemp` for the event-schemas output.
3. Extend the perl substitution to do TWO sentinel pairs:
   `<!-- GENERATED:event-schemas -->...<!-- /GENERATED:event-schemas -->`
   AND the existing `<!-- GENERATED:registry -->...`.

Pass criterion: `bash bin/generate-vocabulary-doc.sh` exits 0;
`docs/pipeline-vocabulary.md` now contains both
`<!-- GENERATED:event-schemas -->` and `<!-- GENERATED:registry -->`
sentinels.

### Task 8 — `docs/pipeline-vocabulary.template.md`: insert event-schemas sentinel pair

Add the new sentinel pair AFTER the "Anatomy of a marker" section
and BEFORE "Writing markers" prose:

```markdown
<!-- GENERATED:event-schemas -->
## Comment schemas

Source: `bin/pipeline-events.json::events` — edit there, not here.

(generator fills below)
<!-- /GENERATED:event-schemas -->
```

If `docs/pipeline-vocabulary.template.md` does NOT exist (it should,
per A9), create it by copying current `docs/pipeline-vocabulary.md`
and adding the sentinel pair. Existence is verified during Task 7's
first run.

Pass criterion: grep for `<!-- GENERATED:event-schemas -->` in
`docs/pipeline-vocabulary.template.md` returns at least one match.

### Task 9 — `docs/pipeline-vocabulary.md`: regenerate

`bash bin/generate-vocabulary-doc.sh`. Commit the output diff.

Pass criterion: grep for "Comment schemas" in
`docs/pipeline-vocabulary.md` returns at least one match; the
registry section (under `<!-- GENERATED:registry -->`) is unchanged.

### Task 10 — `bin/pipeline-test.sh`: add ENG-112 test block

Add tests B-001..B-010 per brainstorm §2 D-006. Use the existing
test scaffolding (`STUB_DIR` pattern, `PIPELINE_DRY_RUN=1`,
`PIPELINE_WRITER` overrides) to drive `bin/pipeline.sh` and assert
on the captured `linear.sh add-comment` payload.

Pin shapes:

- B-001: `bash bin/pipeline.sh event ENG-1 verdict pass` (no stage)
  → die with `requires 'stage'`.
- B-002: `... verdict fail --target bogus` → die with registry error
  on `fail_targets`.
- B-003: `... verdict halt --reason scope-violation` → succeeds,
  emitted body matches `<!-- pipeline: verdict result=halt reason=scope-violation -->`.
- B-004: `... verdict wait --reason awaiting-approval` → succeeds.
- B-005: `... verdict pivot` (no target) → die.
- B-006: `... transition "bogus → planning"` → die with registry
  error on `stages`.
- B-007: `... decide ENG-1 --action continue` → succeeds, no gate.
- B-008: `... decide ENG-1 --action approve` (no gate) → die.
- B-009: `... event ENG-1 verdict pass --stage brainstorming --bogus foo`
  → die with "unknown field".
- B-010: round-trip — `bash bin/generate-vocabulary-doc.sh` exits 0;
  `docs/pipeline-vocabulary.md` contains "Comment schemas" section.

Pass criterion: `bash bin/pipeline-test.sh` exits 0 and prints
"PASS" for B-001..B-010 (10 new lines).

## 6. Frontend Tasks

None — backend-only.

## 7. Test Plan

Run `bash bin/pipeline-test.sh` end-to-end; assert all existing
tests still pass plus the 10 new ENG-112 cases.

Adversarial sweep (during QA stage):

- Unknown event name (`bash bin/pipeline.sh event ENG-1 bogus`) →
  existing `die` at L74 unchanged; schema doesn't see this path.
- Missing `events` key in `pipeline-events.json` →
  `_validate_event_payload` dies with the helpful "no
  linear_comment for event" message (covered by B-001 indirectly;
  add a defensive B-011 if convenient).
- Body_shape with `<` or `>` inside a field value → renderer emits
  it verbatim; the wire body is technically valid HTML comment as
  long as no `-->` appears mid-value. Out of scope for ENG-112; the
  field_registry restricts values to enum tokens, which contain no
  symbols.

## 8. Risks & Open Questions

- **R-1.** Adding `events` key bumps the JSON file from 63 lines to
  ~110. The generator and `_validate_event_payload` both `jq` it
  per call; latency stays sub-millisecond.
- **R-2.** `docs/pipeline-vocabulary.template.md` may not exist on
  disk (A9 is assumed). Mitigation: Task 8 creates it from the
  current generated doc if absent.
- **OQ-1.** Should `cmd_decide`'s "continue: --gate not allowed"
  rule move into the schema (see Task 6 caveat)? Today schema is
  inclusion-only; expressing exclusion needs a new field
  (`forbidden_by_arm`). Decided not to add it for one rule; revisit
  if a second exclusion case appears.
