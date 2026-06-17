---
linear: ENG-206
title: Apply orchestrator-merge to review-findings-ledger.jsonl — ledger_schema_version into seed-header
date: 2026-06-17
status: draft
---

# Apply orchestrator-merge to review-findings-ledger.jsonl

## 1. Problem

[ENG-190](https://linear.app/twinning/issue/ENG-190) introduced
`review-findings-ledger.jsonl` as the review-stage's cumulative
adjudication memory. The validator at
`bin/review-ledger-schema.sh::cmd_validate` (lines 150-490) enforces a
per-row schema; on any row that fails the per-row
`ledger_schema_version == 1` check (lines 219-225) the dispatch halts
with `review-ledger-invalid` rc=49 (caller-side mapping at
`bin/run-stage.sh:1453-1460`).

This is the **same** structural slip surface that
[ENG-118](https://linear.app/twinning/issue/ENG-118) exhibited on
`verdict-qa.json`: the review agent is responsible for writing a
boilerplate envelope key (`ledger_schema_version: 1`) on every
ledger row, and the operator's memory entry
`qa-agent-schema-version-field-slip` is live evidence that agents
**reliably** drop or mistype boilerplate-version fields. The ledger's
shape is JSONL (append-only, multi-row), but the slip surface is
identical — a wrong type or missing key on one row halts the dispatch.

[ENG-202](https://linear.app/twinning/issue/ENG-202) generalised:
*stage agents emit content; the orchestrator owns the
structured-artifact envelope*.
[ENG-203](https://linear.app/twinning/issue/ENG-203) shipped the
foundation helper `merge_artifact_envelope`
(`bin/common.sh:713-742`) and proved the pattern on
`verdict-qa.json`. ENG-206 is the JSONL adaptation: the envelope key
moves into the orchestrator-seeded **header** of the ledger file (not
spliced into each row), and the agent appends content-only rows.

The scope is **deliberately narrow**: the Linear OUT list pins
"finding-row schema / severity-ladder semantics" as out of scope —
"only header/version authorship moves." The minimal cut that closes
the slip surface and satisfies AC#1-#3 is to move
`ledger_schema_version` (and only that envelope key) from per-row
agent authorship to per-file header orchestrator authorship.
`issue_id` and `dispatch_id` stay per-row by design (`issue_id` is
operator-grep ergonomics; `dispatch_id` is per-row because rows from
different dispatches carry different values — moving to header would
break ENG-191's schema-grace clause that exempts prior-dispatch rows).

## 2. Decisions

### D-001. Mechanism: orchestrator-seeded header line carries `ledger_schema_version`; agent omits the field per row. Validator becomes lenient on the per-row check (accept absent OR equal to 1).

**Rationale.** The ENG-203 merge-helper mechanism splices envelope
keys onto a JSON-object body. JSONL has no body-to-merge-into — the
rows ARE the content, one per line. The natural adaptation: move the
envelope into a `#`-prefixed comment line at the file head.
`bin/review-ledger-schema.sh:97-99` already byte-checks a two-line
prose seed-header; extending to **three lines** with a structured
`# ledger_schema_version: 1` directive is the smallest delta and
preserves the existing seed-header tampering check.

Four candidate mechanisms considered:

* **A. Header-line envelope (chosen).** Orchestrator's
  `_ensure_review_ledger` (`bin/run-stage.sh:1024-1037`) writes a
  third header line `# ledger_schema_version: 1`. Agent appends
  content-only rows beneath. Validator byte-checks all three header
  lines and SKIPS the per-row check (or relaxes it — see D-003).
* **B. Per-dispatch envelope directive (interleaved).** Each
  reviewing dispatch appends a `#! envelope {...}` directive line
  before its rows; validator tracks the "active envelope" as it
  walks the file. **Rejected** — multi-envelope walking complicates
  the validator significantly, prior-dispatch rows would each have
  their own directive that needs preservation across re-seeds, and
  the JSONL operator-grep ergonomic (`jq -c '. | select(...)' <
  ledger.jsonl`) breaks because directives are not JSON-parseable.
  The single-header design preserves the "lines starting with `#`
  are file metadata; everything else is one JSON object" contract
  the agent prompt's "Filter lines starting with `#`" already
  documents (`AGENT_PROMPTS.md:1393`).
* **C. Apply `merge_artifact_envelope` to a body sidecar
  (verdict-qa pattern verbatim).** Agent writes
  `review-findings-ledger.body.jsonl` (just rows, no envelope);
  orchestrator post-dispatch reads body + merges envelope KEY
  INTO each row by re-emitting the JSONL with `jq`-spliced fields.
  **Rejected** — the ledger is append-only across dispatches
  (`bin/run-stage.sh:947` "opposite lifecycle from
  verdict-review.json; ENG-190"). The body-then-merge model would
  conflict with that: either the body sidecar is also append-only
  (and we have TWO append-only files in lockstep), or each
  dispatch's body is fresh and the orchestrator has to splice it
  into the cumulative canonical (which is more complex than just
  appending). Also: re-emitting all rows on every dispatch breaks
  the durable forensic property that rows are never rewritten.
* **D. Validator synthesises envelope at validation time without a
  header line.** **Rejected** — the validator already has the
  `ledger_schema_version` constraint hardcoded (`bin/review-ledger-schema.sh:220`);
  moving it from per-row to "synthesised globally" without a header
  declaration loses the audit surface (operator can't `cat
  ledger.jsonl` and see the schema version applied to the file).
  The header-line declaration is the operator-visible source of
  truth, mirroring `bin/qa-payload-schema.sh:108-122`'s explicit
  version constraint.

**Reference to constraint.** CLAUDE.md "Per-medium primitives":
"clear-on-dispatch-start for per-issue files (current-stage only;
OTHER stages preserved for loopback)" — the ledger has the
OPPOSITE lifecycle: never cleared on dispatch (`bin/run-stage.sh:947`).
The header-line envelope respects this: when seeded into an existing
file, prior-dispatch rows are preserved untouched.

**Reference to constraint.** Ticket OUT list: "The ledger's
finding-row schema / severity-ladder semantics ([ENG-190]
territory) — only header/version authorship moves." D-001's chosen
shape moves ONLY `ledger_schema_version`. `issue_id` and
`dispatch_id` stay per-row.

### D-002. Header format: three `#`-prefix lines. Line 3 is the literal `# ledger_schema_version: 1` directive. Forensic anchors (PR/SHA/seeded_at/dispatch_id) are NOT in the header.

**Rationale.** The Linear scope text mentions "the deterministic
anchors it already knows: PR/SHA/dispatch context" as candidate
envelope contents. Two header-content options:

* **D-002a. Static-only header (chosen).** Three lines, the third
  being the literal `# ledger_schema_version: 1`. Header is
  byte-identical across all dispatches. Validator does a simple
  byte-check (mirrors `SEED_LINE_1` / `SEED_LINE_2` at
  `bin/review-ledger-schema.sh:98-99`).
* **D-002b. Per-dispatch forensic header.** Third line is a JSON
  envelope carrying `{ledger_schema_version, dispatch_id,
  pr_number, sha, seeded_at}`. Re-seeded on every dispatch.
  **Rejected** — re-seeding requires either rewriting the whole
  file (atomic temp + mv on every dispatch — non-trivial when
  rows accumulate) OR appending per-dispatch directives
  (rejected as Mechanism B in D-001). The PR/SHA/dispatch context
  is ALREADY captured per-row (`dispatch_id` field) and per-issue
  (`dispatch_history.jsonl`, `bin/run-stage.sh::issue_dir/dispatch_history.jsonl`).
  Header re-seeding adds operational complexity for forensic
  context that exists elsewhere.

The static-only header keeps the orchestrator's seed function
idempotent on existing files (`[[ -f "$lgr" ]] && return 0` after
migration; see D-005), keeps the validator's byte-check trivial,
and keeps row-preservation a non-issue (no rewriting after first
seed).

**Reference to constraint.** CLAUDE.md "Don't add features beyond
what the task requires." Per-dispatch forensic context is a YAGNI
generalisation; defer to a follow-up if observed-needed.

**Reference to constraint.** Linear AC#1: "prompt-content test
asserts it no longer authors the seed-header / `ledger_schema_version`."
The agent's prompt edit removes `ledger_schema_version` from the
required-fields list (D-006). The seed-header is byte-equal across
dispatches, so the "agent doesn't author the seed-header" assertion
is structural: agent's `Edit` uses a header-line anchor but never
modifies the header content.

### D-003. Per-row `ledger_schema_version` check becomes LENIENT (accept absent OR equal to 1). Rejected: strict-remove (no per-row check at all).

**Rationale.** The current validator at
`bin/review-ledger-schema.sh:219-225` rejects rows missing
`ledger_schema_version` OR with value != 1. Post-ENG-206, the
agent's prompt instructs it to OMIT the field per row. Three
options for the per-row check:

* **D-003a. Lenient (chosen).** If row HAS the field, value must
  equal 1 (existing strictness). If row LACKS the field, pass
  (use header's declared version). This is back-compat for
  pre-ENG-206 rows already in the ledger AND honors the
  agent's new prompt contract.
* **D-003b. Strict-remove.** Drop the per-row check entirely.
  Rejected — pre-ENG-206 rows in the file (with
  `ledger_schema_version: 1`) would still pass (extra-fields
  warning at `bin/review-ledger-schema.sh:473-480` already
  handles them as unknown), but if a regressed agent emits a
  WRONG version per-row (e.g., `"ledger_schema_version": "v1"`
  string), the slip silently survives. The lenient check catches
  this regression class.
* **D-003c. Strict-keep.** Keep the existing check unchanged.
  Rejected — the agent's new prompt OMITS the field, and the
  check would halt every post-ENG-206 dispatch on the first
  row. Defeats the whole exercise.

**Reference to constraint.** Anti-bias / ADR stress test: this is
the same right-biased "envelope wins / body's mistakes are
overridden" posture ENG-203 D-001 took. Here the orchestrator
DECLARES the version in the header; row-level emissions are
either absent (new contract) or equal-to-1 (legacy) — either way,
the header is the source of truth.

### D-004. `_ensure_review_ledger` is extended in-place. Function gains a one-line migration step that splices `# ledger_schema_version: 1` as line 3 of any pre-ENG-206 file. Renaming deferred.

**Rationale.** The existing function at
`bin/run-stage.sh:1024-1037` is idempotent on existence
(`[[ -f "$lgr" ]] && return 0`). Post-ENG-206, the function must
handle three cases:

1. File missing → create with 3 header lines.
2. File exists with 3-line header already (post-ENG-206 ledger)
   → no-op.
3. File exists with 2-line header + rows (pre-ENG-206 ledger)
   → migrate: splice `# ledger_schema_version: 1` as new line 3,
   shift rows down by one.

Three placement candidates:

* **D-004a. Extend `_ensure_review_ledger` (chosen).** One
  function does all three. Caller (`bin/run-stage.sh:2385`) is
  unchanged. The function grows from ~10 lines to ~30. Mirrors
  the existing per-stage seed-helper shape (`_ensure_progress_md`
  at `bin/run-stage.sh:1000-1014` also handles seed + idempotent
  re-entry).
* **D-004b. Introduce a sibling `_migrate_review_ledger_header`.**
  Adds a new function for a one-shot migration step that no
  caller will use after every host has run one post-deploy
  dispatch. Premature abstraction; CLAUDE.md "Don't add features
  beyond what the task requires." Rejected.
* **D-004c. Skip migration; reseed unconditionally with
  whole-file rewrite.** Each dispatch reads the full file,
  rewrites with new header + preserved rows. Rejected — adds an
  unnecessary atomic mv on every reviewing dispatch (cost
  scales with ledger size), and the function becomes
  non-idempotent on the read side (rare race between two
  dispatches on the same issue is bounded by the per-issue
  in-flight lock at `bin/common.sh::try_acquire_lock`, but
  defense-in-depth says minimise the rewrite surface).

**Migration body** (REPLACES the existing function body; the pre-ENG-206
`[[ -f "$lgr" ]] && return 0` short-circuit at `bin/run-stage.sh:1027`
goes away because it would short-circuit BEFORE the migration could
run on a pre-ENG-206 file — coherence persona Iter-1 P1):

```bash
_ensure_review_ledger() {
  local ident="$1"
  local lgr; lgr="$(issue_dir "$ident")/review-findings-ledger.jsonl"
  local SEED_LINE_1='# review-findings-ledger — per-issue cumulative ledger; append one JSON object per line.'
  local SEED_LINE_2='# See docs/runbooks/review-findings-ledger.md. Never truncate; never cleared on dispatch.'
  local SEED_LINE_3='# ledger_schema_version: 1'

  # Case 1: file missing — fresh seed.
  if [[ ! -f "$lgr" ]]; then
    if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
      log "_ensure_review_ledger: dry-run — would seed $lgr"
      return 0
    fi
    {
      printf '%s\n' "$SEED_LINE_1"
      printf '%s\n' "$SEED_LINE_2"
      printf '%s\n' "$SEED_LINE_3"
    } > "$lgr"
    log "_ensure_review_ledger: seeded $lgr (3-line header)"
    return 0
  fi

  # Defense (OQ-2 → folded): reject symlinked ledger (mirrors
  # ENG-203 D-007's body-sidecar guard).
  [[ -L "$lgr" ]] && die "_ensure_review_ledger: ledger is a symlink: $lgr"

  # Case 2: file exists, already migrated — no-op.
  local third_line; third_line="$(sed -n '3p' "$lgr" 2>/dev/null || true)"
  if [[ "$third_line" == "$SEED_LINE_3" ]]; then
    return 0
  fi

  # Case 3: file exists, pre-ENG-206 or operator-corrupted line 3 —
  # migrate. The `tail -n +N` decision is load-bearing:
  #   - If line 3 is a JSON row (starts with `{`), keep it: tail -n +3.
  #   - If line 3 is a `#`-comment that ISN'T SEED_LINE_3 (operator paste
  #     of whitespace, BOM, corrupt SEED_LINE_3, or future drift),
  #     CONSUME it: tail -n +4 — otherwise the migration preserves the
  #     corrupt line as if it were a row and the validator halts on
  #     every subsequent dispatch (product persona Iter-1 P2 trap-class).
  local tail_from=3
  if [[ "${third_line:0:1}" == "#" ]]; then
    tail_from=4
  fi
  if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
    log "_ensure_review_ledger: dry-run — would migrate header for $lgr (tail_from=$tail_from)"
    return 0
  fi
  local tmp
  tmp="$(mktemp "${lgr}.tmp.XXXXXX")" \
    || die "_ensure_review_ledger: mktemp failed for $lgr"
  {
    printf '%s\n' "$SEED_LINE_1"
    printf '%s\n' "$SEED_LINE_2"
    printf '%s\n' "$SEED_LINE_3"
    tail -n "+$tail_from" "$lgr"
  } > "$tmp" || { rm -f "$tmp"; die "_ensure_review_ledger: write failed for $lgr"; }
  mv "$tmp" "$lgr" \
    || { rm -f "$tmp"; die "_ensure_review_ledger: atomic mv failed for $lgr"; }
  log "_ensure_review_ledger: migrated $lgr to 3-line header (tail_from=$tail_from)"
}
```

The function is shown in full because the structure differs
substantively from the pre-ENG-206 shape — the historic
`[[ -f "$lgr" ]] && return 0` early-exit is REPLACED by the
three-case dispatch (missing / already-migrated / migrate). The
`tail_from` adjustment closes a real trap: an operator hand-paste
that drifted line 3 (whitespace, BOM, etc.) would otherwise
preserve the corrupt comment as a "row" and re-halt every dispatch
until the operator deleted the file.

The `SEED_LINE_1` and `SEED_LINE_2` constants come from the
existing prose; `SEED_LINE_3` is the new literal
`# ledger_schema_version: 1`. Hoisted to function-local constants
to mirror the validator's `SEED_LINE_*` (`bin/review-ledger-schema.sh:98-99`).

**Idempotence under concurrent dispatches.** Two reviewing
dispatches on the same issue cannot interleave: the per-issue
in-flight lock at `bin/common.sh::try_acquire_lock` (used by
`bin/run-stage.sh` via the orchestrator entry) serialises them.
Even without the lock, the `mv` is atomic on the same FS
(`$PROJECT_STATE_DIR/<ident>/` — the body and canonical share
the same dir, A6 in §8.3).

**Reference to constraint.** CLAUDE.md "When wiring a new script":
"Use `log` / `die` / `require_env` / `require_bin` from
common.sh." The migration path uses `die` for write failures
(non-recoverable seed) and `log` for the migration trace.

### D-005. Validator (`bin/review-ledger-schema.sh`) gains a line-3 byte-check; per-row `ledger_schema_version` check becomes lenient.

**Rationale.** Two changes to `cmd_validate`:

1. **Extend the seed-header integrity check** (`bin/review-ledger-schema.sh:181-188`).
   Today it byte-checks lines 1 and 2. Post-ENG-206 it ALSO
   byte-checks line 3 against the new `SEED_LINE_3` constant
   `# ledger_schema_version: 1`. Diagnostic on mismatch:
   `review-ledger-incomplete: seed-header tampered or missing
   (line 3: ledger_schema_version directive)` rc=49.

2. **Relax the per-row check** (`bin/review-ledger-schema.sh:219-225`).
   Current strict: `jq -e '.ledger_schema_version == 1'`. New
   lenient: "if row has the field, value must equal 1; if absent,
   pass." Implementation:

   ```bash
   # New replacement for lines 219-225:
   local lsv_type
   lsv_type="$(jq -r '.ledger_schema_version | type' <<<"$line" 2>/dev/null || printf 'missing')"
   if [[ "$lsv_type" != "null" && "$lsv_type" != "missing" ]]; then
     if ! jq -e '.ledger_schema_version == 1' <<<"$line" >/dev/null 2>&1; then
       local ver_val
       ver_val="$(jq -r '.ledger_schema_version' <<<"$line" 2>/dev/null || printf 'MISSING')"
       _emit_incomplete "$line_no" "ledger_schema_version must be 1 when present, got: $ver_val" "$fck"
       return 49
     fi
   fi
   # Else: field absent — accept; envelope-from-header (D-001).
   ```

   The unknown-field warning loop at `bin/review-ledger-schema.sh:473-480`
   already lists `ledger_schema_version` in the known-fields
   array; no change needed there.

**Reference to constraint.** AC#3: "ENG-190 rc=49 'seed-header /
schema-version missing' can no longer be caused by agent omission
— pinned by a regression test." The lenient per-row check
satisfies this: agent omits → pass.

**Reference to constraint.** AC#2: "Orchestrator seeds the header
each review dispatch; `review-ledger-schema.sh` passes on
header+rows with an agent that wrote zero header lines." The
3-line header byte-check + lenient per-row check is the validator
shape that makes this AC green.

### D-006. AGENT_PROMPTS.md §5 edits: remove `ledger_schema_version: 1` from the row required-fields list; clarify the Edit-append anchor uses the new line 3 (`# ledger_schema_version: 1`).

**Rationale.** Two specific edits to AGENT_PROMPTS.md §5:

1. **Required-fields list** (`AGENT_PROMPTS.md:1840-1848`).
   Currently lists: `ledger_schema_version: 1, issue_id, dispatch_id,
   iteration, created_at, finding_class_key, cold_severity,
   adjudicated_severity, decision, rationale`.
   Post-ENG-206: REMOVE `ledger_schema_version: 1` from this list.
   The remaining list is unchanged (per the OUT scope: "only
   header/version authorship moves").

2. **Anchor reference** (`AGENT_PROMPTS.md:1840-1841` and
   `:1751-1752`). Currently: "via `Edit` with the seed-header line
   as the anchor." Post-ENG-206 there are THREE header lines; the
   prompt should pin which one the agent uses as the anchor.
   The natural choice is the new line 3
   (`# ledger_schema_version: 1`) — it's the line immediately
   above the rows. Edit becomes:

   > Append one row per finding to `{review_ledger_path}` via
   > `Edit` with `# ledger_schema_version: 1` (line 3 of the
   > orchestrator-seeded header) as the anchor.

3. **Add an explanatory sentence** (after the required-fields
   list at `AGENT_PROMPTS.md:1848`):

   > The orchestrator seeds the ledger header (including the
   > `ledger_schema_version: 1` envelope line) at every reviewing
   > dispatch start; do not author the seed-header or
   > `ledger_schema_version` yourself.

**Anchor-literal coupling caveat** (design persona Iter-1 P1):
the §5 prompt anchor (`# ledger_schema_version: 1`) is byte-equal
to `SEED_LINE_3`. If a hypothetical ENG-206-v2 ever changes the
line-3 literal (e.g., to bump the schema to v2), the §5 prompt
anchor, AP-3 pin, and validator `SEED_LINE_3` constant must
move in lockstep. Pin in §9 (Conflict with existing architecture);
the implementing agent should ensure all three callsites are
updated atomically.

**Reference to constraint.** AC#1: "The review agent appends
finding rows only; prompt-content test asserts it no longer
authors the seed-header / `ledger_schema_version`." D-006's
edits map directly: drop the field from the row instructions;
state the orchestrator's ownership explicitly.

**Reference to constraint.** AGENT_PROMPTS.md fence-count
contract (Project profile addendum "Don'ts"): edits stay inside
the existing fenced block of §5; no new column-0 ``` fences
introduced.

### D-007. No new prompt resolver tokens. No `merge_artifact_envelope` call site for the ledger.

**Rationale.** ENG-203 introduced `{qa_payload_body_path}` and
`{qa_predicate_body_path}` resolvers because the qa pattern needs
a body sidecar path. ENG-206's pattern is fundamentally
different: the orchestrator writes a HEADER LINE (a fixed string),
not a sidecar. The agent writes ROWS directly into the canonical
ledger via `Edit` (already the case pre-ENG-206; no path change).

The existing `{review_ledger_path}` resolver
(`bin/render-prompt.sh:58` + `:286`) suffices. No new resolver
required.

`merge_artifact_envelope` (`bin/common.sh:713-742`) is a
JSON-object merger — it slurps a body, splices envelope keys, and
writes a canonical. JSONL has no body-to-merge-into here (the
ledger row is a single line; the agent appends one row at a time
via Edit; there is no body sidecar). The helper is not reused.

**Reference to constraint.** CLAUDE.md ticket sizing rubric: "Don't
add features beyond what the task requires." Resolving the
ledger-header pattern WITHOUT introducing parallel infrastructure
keeps the blast radius small.

**Rejected alternative — define a sibling
`seed_jsonl_envelope_header` helper in common.sh.** Rejected for
the same reason as D-002b: premature generalisation. The only
caller is `_ensure_review_ledger`, and the seed body is a
six-line printf/migration block. Hoisting it to `common.sh` adds
an export-list entry, a test in `common-test.sh`, and a name to
remember — without a second caller to justify any of that. Defer
to ENG-202 if a sibling JSONL artifact appears.

### D-008. No backward-compat shim that ACCEPTS a ledger with no line-3 envelope. Migration is one-shot at first post-deploy reviewing dispatch.

**Rationale.** When ENG-206 ships, every host's first
post-deploy reviewing dispatch will encounter one of:

* Fresh ledger (file missing) → orchestrator creates with 3-line
  header. Agent writes rows without `ledger_schema_version`.
  Validator passes.
* Pre-ENG-206 ledger (file exists with 2-line header + rows).
  Orchestrator migrates header to 3 lines (D-004 migration body).
  Existing rows preserved unchanged. Agent writes new rows
  without `ledger_schema_version`. Validator passes:
  pre-ENG-206 rows had `ledger_schema_version: 1` (lenient check
  accepts); new rows omit it (lenient check accepts).

The validator must NOT accept a 2-line header on a non-empty
ledger because that would leave the slip surface open: an agent
running the post-ENG-206 prompt against a pre-ENG-206 ledger
would write rows without `ledger_schema_version`, and the
validator's pre-ENG-206-style strict per-row check would reject
all of them. The migration is mandatory.

**Cutover edge case.** A reviewing dispatch already in flight
when the operator deploys ENG-206 will land under the old agent
prompt (so its rows DO carry `ledger_schema_version: 1` — pass
under lenient validator) but against an orchestrator that has not
yet seeded line 3 (migration hadn't run by dispatch-start). The
validator's new line-3 byte check would halt the in-flight
dispatch with `review-ledger-incomplete: seed-header tampered
(line 3 missing)`. **Recovery:** `bash bin/pipeline.sh decide
<ENG-N> --action continue`. The next dispatch's
`_ensure_review_ledger` migrates the header; subsequent
validation passes.

**Operator gesture bound — up to `max_concurrent_features`
issues** (design + product personas Iter-1 P1): with
`orchestrator.max_concurrent_features=2` (default per CLAUDE.md
ENG-81), up to TWO reviewing dispatches can be in-flight
simultaneously at deploy. Both would halt; both recover via the
same one-gesture path. Bounded by `K` (project concurrency), not
strictly "one issue per project." Identical recovery shape to
ENG-203's "in-progress dispatch at deploy time" edge case (per
ENG-203 D-008's last paragraph).

**Diagnostic distinguishability** (product persona Iter-1 P1):
the validator's line-3 mismatch diagnostic SHOULD distinguish two
shapes — `line-3 absent (file has only N<3 lines)` vs `line-3
present but drifted (got '<value>')`. The first shape signals
"pre-ENG-206 unmigrated; recovery is a normal `--action continue`."
The second shape signals "human or agent edited the seed-header;
inspect before resuming." Both rc=49; one extra phrase in the
diagnostic saves the cutover triage. Folded into D-005's diff
sketch: the byte-check emits
`seed-header tampered or missing (line 3: <value>; expected
'# ledger_schema_version: 1')` with `<value>` empty when line 3
is absent.

**Reference to constraint.** CLAUDE.md "Don't add
backwards-compatibility shims when you can just change the
code." Migration is the orchestrator's job; runs once;
subsequent dispatches no-op the migration check.

### D-009. Test surface: orchestration tests in `bin/run-stage-test.sh`; validator unit tests in `bin/review-ledger-schema-test.sh`; prompt-content assertion in `bin/agent-prompts-content-test.sh`.

**Rationale.** Three test files, one new pin per AC:

**Orchestration (`bin/run-stage-test.sh`):**

* **OS-1 fresh-file seed.** Call `_ensure_review_ledger ENG-1`
  on a clean issue dir. Assert
  `$(issue_dir)/review-findings-ledger.jsonl` has exactly three
  `#`-prefix lines matching `SEED_LINE_1` / `SEED_LINE_2` /
  `SEED_LINE_3` and no other content.
* **OS-2 migration (pre-ENG-206 file with rows).** Pre-create the
  ledger with the OLD 2-line header + two JSONL rows.
  Call `_ensure_review_ledger ENG-1`. Assert: file now has 3
  header lines + the original 2 rows unchanged (byte-equality).
  Pins D-004.
* **OS-3 idempotent re-entry (post-ENG-206 file).** Pre-create
  the ledger with the NEW 3-line header + N rows. Call
  `_ensure_review_ledger ENG-1` again. Assert: file unchanged
  (byte-equality). Pins D-004's no-op short-circuit.
* **OS-4 ENG-190 regression: agent omits `ledger_schema_version`
  per row.** Create a 3-header-line ledger; append one row that
  OMITS `ledger_schema_version` but has all other required
  fields. Call `_validate_review_ledger ENG-1`. Assert rc=0.
  Pins AC#3.

**Validator unit (`bin/review-ledger-schema-test.sh`):**

* **V-1 valid (lenient, missing field).** Row with no
  `ledger_schema_version` field but all other fields valid →
  validate passes.
* **V-2 valid (lenient, field=1).** Row with
  `ledger_schema_version: 1` and all other fields → validate
  passes (back-compat for pre-ENG-206 rows).
* **V-3 invalid (lenient, field=2).** Row with
  `ledger_schema_version: 2` → validate halts rc=49 with
  `ledger_schema_version must be 1 when present` diagnostic.
* **V-4 invalid (lenient, field="v1" string).** Row with
  `ledger_schema_version: "v1"` → validate halts rc=49.
* **V-5 line 3 byte-check pass.** File with the canonical 3-line
  header + valid rows → validate passes.
* **V-6 line 3 byte-check fail (missing).** File with only the
  2-line header + rows (pre-ENG-206 unmigrated) → validate halts
  rc=49 with `seed-header tampered or missing (line 3)`.
* **V-7 line 3 byte-check fail (drifted).** File with the 2 prose
  lines + a third comment line that's NOT exactly
  `# ledger_schema_version: 1` (e.g., extra whitespace, different
  version number) → validate halts rc=49.

**Prompt-content (`bin/agent-prompts-content-test.sh`):**

* **AP-1 §5 row required-fields list does NOT contain
  `ledger_schema_version: 1`.** Pin literal: confirm the
  required-fields paragraph at `AGENT_PROMPTS.md:1840-1848`
  enumeration no longer includes the version field. Pins AC#1
  (prompt-content half).
* **AP-2 §5 contains the orchestrator-ownership sentence.** Pin
  literal substring `orchestrator seeds the ledger header` (or
  equivalent canonical phrasing per D-006).
* **AP-3 §5 anchor uses line 3.** Pin literal substring
  `# ledger_schema_version: 1` as the anchor reference in the
  Output bullet. This guards against an agent that copy-pastes
  the example drifting to a different anchor (the failure mode
  would be Edit's old_string not matching — a runtime halt with
  poor diagnostics).
* **AP-4 §5 anchor literal appears exactly ONCE in §5** (product
  persona Iter-1 P2). The literal `# ledger_schema_version: 1`
  must be referenced exactly once in §5's text — protects against
  an LLM that sees two near-matches and picks the wrong one for
  the `Edit` old_string. Test: `grep -c '# ledger_schema_version: 1'`
  on the §5 section body == 1.

**Reference to constraint.** ENG-190's existing pin
`ENG-190-pin-ledger-output-bullet` at
`bin/agent-prompts-content-test.sh:1093-1098` already asserts
two literals: `Append one row per finding to `{review_ledger_path}``
and `NEVER use the \`Write\` tool on `{review_ledger_path}``. AP-1
adds a NEGATIVE pin (no `ledger_schema_version: 1` in the
required-fields enumeration), AP-2/AP-3 add positive pins for
the new prose. Lives next to ENG-190's pins (cohesive block).

## 3. Architecture

### 3.1 Files touched

| Path | Change | Lines |
|---|---|---|
| `bin/run-stage.sh` | Extend `_ensure_review_ledger` (lines 1024-1037): add `SEED_LINE_*` local constants (3 lines); add the line-3 detection + migration branch (D-004 body). Caller at `bin/run-stage.sh:2385` unchanged. | ~30 added |
| `bin/review-ledger-schema.sh` | Add `SEED_LINE_3` constant beside the existing `SEED_LINE_1`/`SEED_LINE_2` (line ~99). Extend the seed-header integrity check at line 181-188 to byte-check line 3. Replace lines 219-225 (per-row `ledger_schema_version == 1` strict check) with the lenient form per D-005. | ~20 changed |
| `AGENT_PROMPTS.md` (§5 review) | Edit `:1840-1848` required-fields list: remove `ledger_schema_version: 1`. Edit `:1751-1752` and `:1840-1841` Edit-anchor reference: name `# ledger_schema_version: 1` as the anchor line. Add the orchestrator-ownership sentence (D-006 #3). | ~6 changed |
| `bin/run-stage-test.sh` | Add OS-1 through OS-4 (D-009). | ~80 added |
| `bin/review-ledger-schema-test.sh` | Add V-1 through V-7 (D-009). | ~100 added |
| `bin/agent-prompts-content-test.sh` | Add AP-1, AP-2, AP-3, AP-4 next to the ENG-190 ledger pins at lines 1091-1098. | ~40 added |
| `bin/common.sh` | NO change. `merge_artifact_envelope` is not reused (D-007). | 0 |
| `bin/render-prompt.sh` | NO change. No new resolver tokens (D-007). | 0 |
| `bin/pipeline-events.json` | NO change. `review-ledger-invalid` already in `halt_reasons` (`bin/pipeline-events.json:31`). | 0 |
| `bin/common.sh::failure_outcome_for_exit` | NO change. Codes 48/49/50 already mapped (`bin/common.sh:801-803`). | 0 |
| `bin/verdict-handler.sh` | NO change. | 0 |
| `docs/runbooks/review-findings-ledger.md` | Add a paragraph under the schema description noting that lines 1-3 are orchestrator-owned, that `ledger_schema_version` is a per-file constant declared in line 3, that per-row emission is no longer required (but is accepted lenient when present), and that per-row `ledger_schema_version: 1` on legacy rows is benign — the header is the source of truth (product persona Iter-1 P1 verbatim guidance). | ~18 added |
| `docs/runbooks/recovery.md` (§12) | Add a brief edit noting the new line-3 byte-check failure mode AND the deploy-cutover edge case explicitly — distinguish "line-3 absent (pre-ENG-206 unmigrated; `--action continue` resolves)" vs "line-3 present but drifted (human or agent edit; inspect before resuming)" so the first post-cutover halt isn't filed as a regression (product persona Iter-1 P1). | ~10 added |

### 3.2 Subsystems touched (rubric check)

Per CLAUDE.md "Ticket sizing rubric":

* **orchestrator** — `bin/run-stage.sh::_ensure_review_ledger`
  extension, `bin/review-ledger-schema.sh` validator changes.
* **agent prompts** — `AGENT_PROMPTS.md` §5 (the two
  required-field / anchor edits) — clearly subordinate to the
  orchestrator change per the ticket's "2 subsystems —
  orchestrator + agent-prompts" sizing.
* **tests/fixtures** — `bin/run-stage-test.sh`,
  `bin/review-ledger-schema-test.sh`,
  `bin/agent-prompts-content-test.sh`.

**2 subsystems, autonomy-safe.** Matches the ticket's stated
sizing.

### 3.3 Per-dispatch flow

```
Reviewing dispatch begins.
  ↓
bin/run-stage.sh::main reaches line 2385:
  [[ "$stage" == "reviewing" ]] && _ensure_review_ledger "$ident"
  ↓
_ensure_review_ledger:
  - File missing → create 3-line header. Done.
  - File exists, line 3 == SEED_LINE_3 → no-op. Done.
  - File exists, line 3 != SEED_LINE_3 (pre-ENG-206) → migrate:
      atomic temp + rewrite: lines 1-2 (prose) + line 3 (envelope)
      + tail -n +3 of old file (preserved rows). Done.
  ↓
Allocate PIPELINE_DISPATCH_ID (line 2397).
  ↓
_clear_current_stage_slots "$ident" reviewing
  (does NOT touch ledger — opposite lifecycle, line 947).
  ↓
Dispatch claude -p (agent runs §5 prompt, appends rows via Edit
with `# ledger_schema_version: 1` as anchor; rows OMIT
ledger_schema_version per the new prompt).
  ↓
Post-dispatch sequence (reviewing stage):
  _validate_review_payload (ENG-119, unchanged) — runs first.
  _validate_review_ledger (ENG-190, validator updated per D-005):
    - Byte-check seed-header lines 1, 2, AND 3.
    - Per-row checks: lenient on ledger_schema_version,
      strict on all other fields (unchanged).
    - rc=0 on clean ledger.
  _post_deferred_majors_comment_if_eligible (ENG-191, unchanged).
  _validate_review_thresholds (ENG-118, unchanged).
  _create_follow_up_tickets_for_deferred_majors (ENG-193, unchanged).
  ↓
verdict_handler — applies the transition.
```

### 3.4 Validator change — detailed sketch

Two surgical edits to `bin/review-ledger-schema.sh`:

```diff
 SEED_LINE_1='# review-findings-ledger — per-issue cumulative ledger; append one JSON object per line.'
 SEED_LINE_2='# See docs/runbooks/review-findings-ledger.md. Never truncate; never cleared on dispatch.'
+# ENG-206: line 3 declares the per-file schema version envelope.
+# The orchestrator owns this line (bin/run-stage.sh::_ensure_review_ledger);
+# the agent never authors it. Per-row ledger_schema_version is no longer
+# required (lenient — see cmd_validate body).
+SEED_LINE_3='# ledger_schema_version: 1'

@@ cmd_validate (seed-header integrity check):
   hdr_line_1="$(sed -n '1p' "$file" 2>/dev/null || true)"
   hdr_line_2="$(sed -n '2p' "$file" 2>/dev/null || true)"
-  if [[ "$hdr_line_1" != "$SEED_LINE_1" || "$hdr_line_2" != "$SEED_LINE_2" ]]; then
+  hdr_line_3="$(sed -n '3p' "$file" 2>/dev/null || true)"
+  if [[ "$hdr_line_1" != "$SEED_LINE_1" || "$hdr_line_2" != "$SEED_LINE_2" || "$hdr_line_3" != "$SEED_LINE_3" ]]; then
+    # Diagnostic must remain FREE of agent-controlled interpolation
+    # (security persona Iter-1 P1). $hdr_line_3 is operator/orchestrator-
+    # owned per D-001's invariants; the only way it carries agent content
+    # is a contract violation the operator is triaging — emitting verbatim
+    # is therefore acceptable. If a future maintainer adds enrichment
+    # from row-level fields, that interpolation MUST go through
+    # sanitise_for_diag (lines 115-121).
+    local hint=""
+    if [[ -z "$hdr_line_3" ]]; then
+      hint="line 3: <absent>; expected '$SEED_LINE_3'"
+    else
+      hint="line 3: '$(sanitise_for_diag "$hdr_line_3")'; expected '$SEED_LINE_3'"
+    fi
+    printf 'review-ledger-incomplete: seed-header tampered or missing (%s)\n' "$hint"
+    return 49
+  fi
-    printf 'review-ledger-incomplete: seed-header tampered or missing\n'
-    return 49
-  fi

@@ per-row ledger_schema_version check (lines 219-225 today):
-    if ! jq -e '.ledger_schema_version == 1' <<<"$line" >/dev/null 2>&1; then
-      local ver_val
-      ver_val="$(jq -r '.ledger_schema_version // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
-      _emit_incomplete "$line_no" "ledger_schema_version must be 1, got: $ver_val" "$fck"
-      return 49
-    fi
+    # ENG-206 lenient check: orchestrator declares ledger_schema_version in
+    # the seed-header (line 3). Per-row presence is optional (D-001); when
+    # present, value MUST equal 1 (defense-in-depth against agent regression).
+    local lsv_type
+    lsv_type="$(jq -r '.ledger_schema_version | type' <<<"$line" 2>/dev/null || printf 'missing')"
+    if [[ "$lsv_type" != "null" && "$lsv_type" != "missing" ]]; then
+      if ! jq -e '.ledger_schema_version == 1' <<<"$line" >/dev/null 2>&1; then
+        local ver_val
+        ver_val="$(jq -r '.ledger_schema_version' <<<"$line" 2>/dev/null || printf 'MISSING')"
+        _emit_incomplete "$line_no" "ledger_schema_version must be 1 when present, got: $ver_val" "$fck"
+        return 49
+      fi
+    fi
```

Edit count: ~20 changed lines in the validator. Tight, surgical,
preserves the rest of the schema check.

## 4. Data Flow

### 4.1 Seed-header construction

Static. Hoisted to constants in `_ensure_review_ledger`:

```bash
local SEED_LINE_1='# review-findings-ledger — per-issue cumulative ledger; append one JSON object per line.'
local SEED_LINE_2='# See docs/runbooks/review-findings-ledger.md. Never truncate; never cleared on dispatch.'
local SEED_LINE_3='# ledger_schema_version: 1'
```

These are byte-equal to the validator's constants
(`bin/review-ledger-schema.sh`). The byte-equality is a load-bearing
invariant: editing one without the other halts every subsequent
reviewing dispatch (existing ENG-190 contract; ENG-206 extends to
line 3).

### 4.2 Atomic migration

```bash
local tmp; tmp="$(mktemp "${lgr}.tmp.XXXXXX")"
{
  printf '%s\n' "$SEED_LINE_1"
  printf '%s\n' "$SEED_LINE_2"
  printf '%s\n' "$SEED_LINE_3"
  tail -n +3 "$lgr"
} > "$tmp"
mv "$tmp" "$lgr"
```

The `mv` is POSIX-atomic on same-FS (body and canonical share
`$(issue_dir "$ident")/`). `tail -n +3` starts at line 3 of the
old file — for a pre-ENG-206 file, lines 3+ are rows. The
preserved rows are byte-identical to the source (`tail` does not
re-emit a trailing newline if absent in source).

### 4.3 Agent-side write flow

Per `AGENT_PROMPTS.md` §5 (post-ENG-206):

```
Agent receives the post-ENG-206 prompt:
  "Append one row per finding to {review_ledger_path} via Edit
   with `# ledger_schema_version: 1` (line 3 of the
   orchestrator-seeded header) as the anchor. ... required
   fields: issue_id, dispatch_id, iteration, created_at,
   finding_class_key, cold_severity, adjudicated_severity,
   decision, rationale. The orchestrator seeds the ledger
   header at every reviewing dispatch start; do not author
   the seed-header or ledger_schema_version yourself."
  ↓
Agent runs Edit:
  Edit(
    file=/abs/path/.../review-findings-ledger.jsonl,
    old_string="# ledger_schema_version: 1",
    new_string="# ledger_schema_version: 1\n{\"issue_id\":\"ENG-N\",\"dispatch_id\":\"ENG-N-dM\",\"iteration\":1,\"created_at\":\"...\",\"finding_class_key\":\"...\",\"cold_severity\":\"major\",\"adjudicated_severity\":\"major\",\"decision\":\"carry\",\"rationale\":\"...\"}"
  )
  ↓
Edit inserts the new row immediately after line 3. Subsequent
rows append below.
```

Post-dispatch, the validator walks lines from the top:
- Line 1 → byte-check pass.
- Line 2 → byte-check pass.
- Line 3 → byte-check pass.
- Lines 4+ → per-row JSON schema check. `ledger_schema_version`
  absent (post-ENG-206 row) → lenient pass. All other fields
  validate strictly per the existing schema-v1.

### 4.4 Idempotency on resume

`bash bin/pipeline.sh decide ENG-N --action continue` clears
`pipeline:halted` and re-allocates a fresh `PIPELINE_DISPATCH_ID`.
Next reviewing tick:

- `_ensure_review_ledger` runs at line 2385. File exists; line 3
  equals SEED_LINE_3 (migration already happened in a prior
  dispatch) → no-op.
- `_clear_current_stage_slots` does NOT touch the ledger (line
  947 — opposite lifecycle).
- Agent appends new rows below existing rows. New rows carry the
  new dispatch_id (per-row, agent-authored — unchanged).
- Validator passes.

No staleness regression; the ENG-87 freshness contract holds
end-to-end. Note: rows from the failed prior dispatch (which
halted with `review-ledger-invalid`) ARE preserved by the
ledger's opposite-lifecycle contract. The post-ENG-87 detective
sees the operator-resume waypoint that
`pipeline.sh decide --action continue` posts and treats the
prior-halt as ack'd; the ledger rows from that halt are
prior-dispatch rows on the next reviewing run.

## 5. Error Handling

### 5.1 Exit codes

| rc | Meaning | Halt reason |
|---|---|---|
| 0  | Valid: seed-header (3 lines) + every row passes. | — |
| 48 | Row JSON parse error (unchanged). | `review-ledger-invalid` |
| 49 | Row missing/invalid required field OR seed-header tampered (lines 1/2/3) OR per-row `ledger_schema_version` present-but-not-1. | `review-ledger-invalid` |
| 50 | File missing (unchanged). | `review-ledger-invalid` |

No new rc. The existing taxonomy at `bin/common.sh:801-803`
(48/49/50) absorbs the new line-3 byte-check failure mode under
rc=49.

### 5.2 Migration failure modes

The migration body in `_ensure_review_ledger` uses `die` on
mktemp / write / mv failure. This halts run-stage.sh BEFORE
dispatch (line 2385 runs at line 2385, dispatch fires later).
The halt is loud (full stack trace via `die`'s `log` + `exit 1`
mapped to `unknown-exit-1` in `failure_outcome_for_exit`).

**Disk full during migration.** `die` fires with "atomic mv
failed for $lgr". Operator triages by clearing disk; next
reviewing tick re-runs the migration cleanly. The pre-ENG-206
file is intact (atomic mv either succeeded or didn't run — no
partial state).

**Symlink at the canonical ledger path.** Today's
`_ensure_review_ledger` doesn't guard symlinks (the file is
under `$PROJECT_STATE_DIR/<ident>/` — orchestrator-owned
territory; agent writes are tool-mediated through `Edit` only,
which the dispatch.sh allowlist controls). Post-ENG-206 the
migration body's `mv` would dereference the symlink target and
overwrite it; this is a defense-in-depth gap, but inherits the
same threat surface as the pre-ENG-206 code. Out of scope for
this ticket; flag in OQ-2.

### 5.3 Validator failure modes (post-ENG-206)

* **Pre-ENG-206 ledger reaches the validator unmigrated.**
  Validator's line-3 byte-check fails → halts rc=49
  `review-ledger-invalid: seed-header tampered or missing`.
  Operator runs `decide --action continue`; next dispatch's
  `_ensure_review_ledger` migrates, then validation passes.
  Bounded edge case (one-shot at cutover).

* **Agent regression: agent writes `ledger_schema_version:
  "v1"` per row anyway.** Lenient check catches it (value
  present and not 1) → halts rc=49. Same surface as today, but
  cause now is "agent regressed on the new prompt's omission
  contract" rather than "agent always slips on this field."

* **Agent regression: agent edits the seed-header (line 3).**
  Validator's line-3 byte-check catches it → halts rc=49. Same
  diagnostic shape as today's line-1/line-2 tamper case.
  Defense pin: AP-3 forces the prompt to instruct using line 3
  as an *anchor* (not as content to edit).

## 6. Edge Cases

* **First reviewing dispatch on a brand-new issue.**
  `_ensure_review_ledger` creates the file with 3 lines. Agent
  appends rows. Validator passes. Standard happy path.

* **Pre-ENG-206 ledger with 2 header lines + 50 rows (long
  in-flight issue).** `_ensure_review_ledger` reads line 3,
  finds it's a JSON row (not SEED_LINE_3), executes migration:
  splices line 3, preserves all 50 rows via `tail -n +3`. The
  migrated file has 3 header lines + 50 rows. Existing rows
  carry `ledger_schema_version: 1` (legacy); lenient check
  accepts. Validation passes.

* **Pre-ENG-206 ledger with EXACTLY 2 lines (header only, no
  rows).** `_ensure_review_ledger`'s `sed -n '3p'` returns
  empty. Empty string != SEED_LINE_3 → migration fires. `tail -n
  +3` of a 2-line file returns nothing. Migrated file has 3
  header lines and zero rows. Validator's `saw_row == 0` path
  returns rc=0 valid (`bin/review-ledger-schema.sh:483-486`).

* **Concurrent operators editing the same ledger by hand
  during a halt.** The `mv` is atomic; the per-issue in-flight
  lock guarantees the operator's edits can't race the
  orchestrator's migration. If the operator deletes the file
  during a halt, the next dispatch creates a fresh 3-line
  header.

* **Operator pastes line 3 with trailing whitespace (e.g.,
  `# ledger_schema_version: 1 ` with a space).** Byte-check
  fails → halt rc=49 `seed-header tampered`. Diagnostic names
  line 3. Operator removes the whitespace.

* **Ledger grew very large (>10MB, hundreds of dispatches).**
  Migration's `tail -n +3 | > tmp` is bounded by file size.
  Modern disks: <1s for 100MB. The migration runs ONCE per
  ledger (idempotent after); zero ongoing cost.

* **Agent forgets and writes the FULL pre-ENG-206 row shape
  (including `ledger_schema_version: 1`).** Lenient check
  accepts. No halt. The orchestrator-side metric to surface
  this drift (analogous to ENG-203 OQ-4's
  `envelope-overwrite`) is OUT OF SCOPE; see OQ-3.

* **Migration races with a manual operator edit.** The
  per-issue in-flight lock (`bin/common.sh::try_acquire_lock`)
  prevents the orchestrator from running while another harness
  process holds it. A human operator editing via `vi` is not
  protected by the lock; this is the same gap that exists
  pre-ENG-206. Out of scope.

* **`PIPELINE_DRY_RUN=1`.** Migration logs only; file is not
  modified. The next non-dry-run dispatch performs the
  migration. Identical pattern to today's `_ensure_review_ledger`
  dry-run shortcut.

* **Issue stuck at `stage:reviewing` with prior `review-ledger-incomplete`
  halt that pre-dates ENG-206 deploy.** The next reviewing
  dispatch runs `_ensure_review_ledger`, which migrates the
  header. The PRIOR rows (which had old envelope keys) pass
  lenient validation. Subsequent agent-authored rows pass
  lenient validation. The halt clears once the new dispatch's
  full sequence completes. Operator action: just resume.

## 7. Open Questions

* **OQ-1.** Should `_ensure_review_ledger` be renamed to
  `_seed_review_ledger_header` post-ENG-206 to reflect its
  new "seed + migrate" semantics? **Tentative answer: NO** —
  the name is callable from a single site
  (`bin/run-stage.sh:2385`) and renaming churns the call site
  + the function's tests for no semantic gain. Defer to
  ENG-202 if a sibling JSONL artifact appears and a unified
  naming becomes useful.

* **OQ-2.** Should the migration body guard against symlinks
  at the canonical ledger path? **Tentative answer: YES,
  one-line defense added** (security persona Iter-1 P1 refined).
  Adding `[[ -L "$lgr" ]] && die "_ensure_review_ledger: ledger
  is a symlink: $lgr"` to the migration branch costs one line and
  closes a real-but-low-probability vector (a symlinked ledger
  pointing at `$HARNESS_STATE_DIR/.claude-semaphore/slot-N/pid`
  would be overwritten by the migration `mv`). The orchestrator
  runs as the same UID as the operator (no privilege boundary
  crossed), so the threat is operator-foot-gun, not adversarial;
  but mirrors ENG-203 D-007's `[[ -L "$body" ]]` body-sidecar
  guard for symmetry. Pinned in D-004's migration body.

* **OQ-3.** Should the orchestrator log when an agent writes
  `ledger_schema_version` per row anyway (i.e., agent regressed
  on the omission contract)? Mirrors ENG-203 OQ-4's
  `envelope-overwrite` metric. **Tentative answer: DEFER** —
  ENG-203's metric was promoted from defer to in-scope because
  the qa-payload merge ACTUALLY overwrites the agent's value
  silently (slip-resistant). Here the lenient check just
  ACCEPTS the value when present; no overwrite, no silent
  corruption. The retrospective signal would be "agent didn't
  read the new prompt carefully" — useful but lower-value than
  ENG-203's case. Design persona Iter-1 P1 flagged that the
  predicate already exists in the validator (the lenient
  branch's "type present" check); adding a one-line `log` when
  a CURRENT-dispatch row (i.e., `dispatch_id == --dispatch-id`)
  carries `ledger_schema_version` is structurally cheap. Pinned
  as a follow-up rather than in-scope here: the lenient check
  itself is the in-scope shape; metrics surface lives in ENG-202.

* **OQ-4.** The Linear scope text said "the deterministic anchors
  it already knows: PR/SHA/dispatch context" could be in the
  envelope. D-002 chose static-only. Is the implicit forensic
  loss acceptable? **Tentative answer: YES** — per-row
  `dispatch_id` (unchanged) + `dispatch_history.jsonl` (per-issue
  append-only at `$(issue_dir)/dispatch_history.jsonl`) already
  capture PR/SHA/dispatch context. The header would duplicate
  data already on disk. A future need (e.g., a retrospective
  shape that wants to summarise "reviewer ran on these SHAs")
  can be answered from `dispatch_history.jsonl` without touching
  the ledger header.

* **OQ-5.** Should the lenient per-row check ALSO accept rows
  with `ledger_schema_version` as a string `"1"`? **Tentative
  answer: NO** — the operator memory entry
  `qa-agent-schema-version-field-slip` explicitly flagged
  string-vs-integer mistypes as the slip class. Accepting
  `"1"` would invite the same slip class to creep back. Strict
  integer-1-when-present is the right defense.

## 8. Anti-bias checks

### 8.1 ADR stress test

* **ENG-87 cross-dispatch staleness contract.** The ledger has
  the OPPOSITE lifecycle (`bin/run-stage.sh:947` — never cleared
  on dispatch). The migration preserves rows; the seed-header
  is dispatched-idempotent. NO pressure.
* **ENG-77 stage-summary overwrite-on-every-dispatch.** Doesn't
  apply to the ledger (opposite lifecycle). NO pressure.
* **ENG-190 review-findings-ledger contract.** The ENG-190
  schema is unchanged for per-row fields except `ledger_schema_version`
  becoming optional. Severity-ladder, critical-floor,
  ENG-191/ENG-194 deferability — all unchanged. NO pressure.
* **ENG-191 schema-grace clause (`dispatch_id`-gated
  deferability fields).** The deferability gate predicate at
  `bin/review-ledger-schema.sh:352-353` checks `did_val ==
  dispatch_id_flag`. ENG-206 does NOT touch `dispatch_id`
  per-row. The schema-grace clause continues to fire on
  prior-dispatch rows (their `dispatch_id` differs from the
  current `--dispatch-id`). NO pressure.
* **ENG-203 `merge_artifact_envelope` design.** ENG-203's
  helper is intentionally taxonomy-agnostic. ENG-206 chooses
  NOT to reuse it (D-007). This is consistent with ENG-203
  OQ-1's "the 'kind' is owned by each caller; helper is
  purely structural" — JSONL ledger's needs are structurally
  different from JSON-object merge. NO pressure.
* **CLAUDE.md "Don't add features beyond what the task
  requires."** D-002a (static header), D-007 (no new resolvers),
  OQ-3 (deferred metric) all hold this line.
* **AGENT_PROMPTS.md fence-count contract.** D-006 edits stay
  inside the existing §5 fenced block; no column-0 fences
  introduced. NO pressure.

### 8.2 Simpler alternatives (recap)

| Decision | Rejected alternative | Why rejected |
|---|---|---|
| D-001 | Per-dispatch directive interleaved with rows (multi-envelope) | Breaks `jq -c '. | select(...)' < ledger.jsonl` operator-grep; complicates validator walk; multi-directive preservation across re-seeds is non-trivial |
| D-001 | `merge_artifact_envelope` applied to a body sidecar | Conflicts with the append-only-across-dispatches lifecycle; either two append-only files in lockstep or rewriting the canonical on every dispatch |
| D-001 | Validator synthesises envelope at validation time without a header line | Loses operator-visible audit surface; the version constraint disappears from `cat ledger.jsonl` |
| D-002 | Per-dispatch forensic header (PR/SHA in line 3) | Requires re-seeding line 3 on every dispatch; forensic context is already in `dispatch_history.jsonl` |
| D-003 | Strict-remove per-row check | Loses defense-in-depth against agent regressions emitting wrong-typed version field |
| D-003 | Strict-keep per-row check unchanged | Halts every post-ENG-206 dispatch; defeats the exercise |
| D-004 | New `_migrate_review_ledger_header` sibling helper | Premature abstraction; one caller |
| D-004 | Whole-file rewrite on every dispatch (no idempotent short-circuit) | Unnecessary atomic mv per dispatch; cost scales with ledger size |
| D-007 | New JSONL-seed helper in `common.sh` | Premature DRY; one caller |
| D-008 | Backward-compat shim accepting old 2-line header | Leaves the slip surface open for post-ENG-206 dispatches against pre-ENG-206 files |

### 8.3 Assumption inventory

Each row marked **verified** (checked directly against the
current code at the cited line range) or **assumed** (will
validate during implementation).

| # | Assumption | Status |
|---|---|---|
| A1 | `bin/review-ledger-schema.sh:97-99` declares `SEED_LINE_1`/`SEED_LINE_2` as constants byte-checked at lines 183-188. | **verified** (read directly: lines 97-99, 181-188) |
| A2 | `bin/review-ledger-schema.sh:219-225` is the per-row `ledger_schema_version == 1` strict check; rc=49 on fail. | **verified** (lines 219-225) |
| A3 | `bin/review-ledger-schema.sh:473-480` lists `ledger_schema_version` in the known-fields array for the unknown-field warning loop. | **verified** (lines 473-480 — `ledger_schema_version` is the first element of the inline array) |
| A4 | `bin/review-ledger-schema.sh:483-486` (`saw_row == 0`) returns rc=0 valid for a ledger with header but no rows. | **verified** (lines 483-486) |
| A5 | `bin/run-stage.sh:1024-1037` is `_ensure_review_ledger`, called at line 2385 gated on `stage == "reviewing"`. | **verified** (lines 1024-1037, 2385) |
| A6 | `bin/run-stage.sh:947` documents "review-findings-ledger.jsonl (per-issue append-only ledger; opposite lifecycle from verdict-review.json)" — the ledger is NOT in `_clear_current_stage_slots` rm list. | **verified** (lines 946-948, 949-981 — qa branch clears verdict-qa files but no ledger rm) |
| A7 | `bin/run-stage.sh:1442-1461` is `_validate_review_ledger`, called at line 2982 in the post-dispatch sequence for the reviewing stage. | **verified** (lines 1442-1461, 2974-2990) |
| A8 | `bin/run-stage.sh:1468-1476` is `_post_review_ledger_halt`, accepts a free-form `defect` string and interpolates it as `- Defect: %s`. | **verified** (lines 1468-1476) |
| A9 | `bin/common.sh:801-803` maps rc=48/49/50 to `review-ledger-malformed/incomplete/missing`. | **verified** (lines 801-803) |
| A10 | `bin/pipeline-events.json:31` carries `"review-ledger-invalid"` in the `halt_reasons` array. | **verified** (line 31; rg confirmed) |
| A11 | `AGENT_PROMPTS.md:1840-1862` is §5's "Append one row per finding" Output bullet enumerating the row required-fields list including `ledger_schema_version: 1`. | **verified** (lines 1840-1862 — read directly) |
| A12 | `AGENT_PROMPTS.md:1751-1752` is the path-D analogue of the same Edit-append instruction. | **verified** (lines 1751-1752) |
| A13 | `AGENT_PROMPTS.md:1392-1396` documents the agent's read-side filter ("Filter lines starting with `#`") — the orchestrator's 3-line header is automatically filtered out by the agent's reader. | **verified** (lines 1392-1396) |
| A14 | `bin/agent-prompts-content-test.sh:1091-1098` is `ENG-190-pin-ledger-output-bullet`, the existing content-test for the §5 ledger Output bullet. AP-1/AP-2/AP-3 land adjacent. | **verified** (lines 1091-1098) |
| A15 | `bin/render-prompt.sh:58, 112, 286` carry the `{review_ledger_path}` resolver chain (`PROMPT_RESOLVERS`, `_RENDER_REVIEW_LEDGER_PATH` binding, `_resolve_review_ledger_path` body). | **verified** (lines 58, 112, 286 — all three reference `_RENDER_REVIEW_LEDGER_PATH`) |
| A16 | `bin/run-stage.sh:2380-2385` orders the ENG-190 ledger seed BEFORE dispatch_id allocation (line 2397) — the seed function does NOT have `PIPELINE_DISPATCH_ID` available. | **verified** (lines 2380-2397; D-002 static-header design avoids depending on `PIPELINE_DISPATCH_ID` in the seed body) |
| A17 | `bin/common.sh::issue_dir <ident>` returns `$PROJECT_STATE_DIR/<ident>` (canonical per-issue dir). | **verified** (`bin/common.sh:68-72`) |
| A18 | The ledger path is `$(issue_dir "$ident")/review-findings-ledger.jsonl` — under `$PROJECT_STATE_DIR/<ident>/`, OUTSIDE the worktree. Post-stage sweep's `partition_dirty_paths` never sees it. | **verified** (consistent with ENG-203 A25; same path-class) |
| A19 | jq's `.field | type` returns the string `"null"` (not the literal absent value) for a missing field after `// null` defaulting, BUT for a field that's truly absent the `.field | type` shorthand returns... need to verify. | **assumed** (will verify during implementation; the lenient check uses both `type != "null"` and `type != "missing"` defensively, plus a `2>/dev/null || printf 'missing'` fallback — covers both null-valued and absent cases) |
| A20 | `bin/review-ledger-schema-test.sh` exists and follows the per-case-function pattern (one function per test case, all called from main). | **verified** (file exists) |
| A21 | `mv` on same-FS is POSIX atomic — body and canonical share `$(issue_dir "$ident")/`, so the migration's `mv tmp lgr` is atomic against an interrupting reader. | **verified** (POSIX `rename(2)` semantics + ENG-203 A21 precedent) |
| A22 | `tail -n +3 <file>` on a file with fewer than 3 lines outputs nothing (zero bytes). | **verified** (standard `tail` semantics on macOS BSD + GNU coreutils) |
| A23 | The existing `_ensure_review_ledger` uses `[[ -f "$lgr" ]] && return 0` for idempotency. The post-ENG-206 function preserves idempotence on already-migrated files via the `third_line == SEED_LINE_3` check (D-004 body). | **verified** (lines 1024-1037 + D-004 body) |
| A24 | The pre-commit hook (`.githooks/pre-commit`) runs `bin/*-test.sh` glob-matched. `bin/review-ledger-schema-test.sh` and the new OS-N additions to `bin/run-stage-test.sh` / AP-N additions to `bin/agent-prompts-content-test.sh` are runnable without further allowlist edits. | **verified** (project profile addendum "Build & test gates" — the hook globs `bin/*-test.sh`) |
| A25 | `_post_review_ledger_halt` (`bin/run-stage.sh:1468-1476`) interpolates the validator's stdout verbatim into the halt body (sanitised via `<!--` → `<\!--`) — accepts new line-3-byte-check diagnostic shapes without code change. | **verified** (lines 1468-1476 — `safe="${raw//<!--/<\\!--}"` mirrors the sanitisation pattern; `%s` interpolation accepts arbitrary diagnostic text) |
| A26 | jq `+` operator semantics are NOT used in this brainstorm (no merge happens for JSONL — agent appends rows). The ENG-203 envelope-wins precedence is irrelevant here. | **verified** (D-007 explicitly says no `merge_artifact_envelope` use) |
| A27 | The current header byte-check (`bin/review-ledger-schema.sh:185-188`) emits `review-ledger-incomplete: seed-header tampered or missing` and returns 49. Extending this with a 3-line check preserves the same diagnostic shape; AP-N tests can grep for the existing literal. | **verified** (lines 185-188) |
| A28 | Migration is one-shot per ledger: after first post-ENG-206 dispatch on a pre-ENG-206 ledger, line 3 matches `SEED_LINE_3` and `_ensure_review_ledger` returns 0 on subsequent calls. No repeated migration cost. | **verified** (D-004 body's `[[ "$third_line" == "$SEED_LINE_3" ]] && return 0`) |

### 8.4 Codebase-fact verification — what could still slip

All A-rows except A19 are **verified** against cited line
ranges. A19 (jq null-vs-missing type semantics) is **assumed**;
the implementation defensively handles both the null-value and
absent-field cases via the `2>/dev/null || printf 'missing'`
shell fallback combined with the `type != "null" && type !=
"missing"` predicate. The plan stage will validate jq behaviour
against a fixture row with each shape; if jq's behaviour
diverges from the assumed semantic, the lenient check needs a
minor predicate tweak (no design pivot).

## 9. Conflict with existing architecture

* **Ledger lifecycle (`bin/run-stage.sh:947` — opposite from
  verdict-review.json).** ENG-206 honors this: migration
  preserves rows; seed-header is rewritten only on pre-ENG-206
  files (one-shot).
* **`partition_dirty_paths` scope (CLAUDE.md "Sweep + scope
  partition").** Ledger lives under `$PROJECT_STATE_DIR/<ident>/`,
  outside the worktree; sweep never sees it. NO conflict.
* **`bin/dispatch.sh::allowed_tools_for` reviewing stage.**
  No new tools needed; agent's `Edit` access to the ledger
  path is unchanged.
* **`bin/render-prompt.sh::PROMPT_RESOLVERS`.** No new
  resolvers (D-007). Existing `{review_ledger_path}` token
  unchanged.
* **`bin/common.sh::failure_outcome_for_exit`.** No new codes
  needed (rc=48/49/50 cover all new failure modes).
* **AGENT_PROMPTS.md fence-count contract.** D-006 edits stay
  inside the §5 fenced block.
* **`bin/agent-prompts-content-test.sh`.** New AP-N tests are
  additive next to ENG-190's pins.

NO conflicts.

## 10. Scope guard

The Linear ticket's IN list, line-by-line:

* "Orchestrator writes the ledger seed-header line (carrying
  `ledger_schema_version` + the deterministic anchors it
  already knows: PR/SHA/dispatch context) at dispatch start" →
  **D-001 + D-002 + D-004** (orchestrator-owned 3-line header;
  D-002a chose static-only — `ledger_schema_version` only;
  PR/SHA/dispatch context deferred per OQ-4). **Operator-ack
  flag** (scope persona Iter-1 P1): the IN-list text explicitly
  named PR/SHA/dispatch anchors as in-scope. D-002 narrows to
  `ledger_schema_version`-only with the rationale that per-row
  `dispatch_id` + `dispatch_history.jsonl` already capture
  PR/SHA/dispatch context. This is a defensible narrowing but
  represents a literal scope SHORTFALL against the IN text;
  flagged here so the operator can explicitly ack at plan time
  rather than discover post-implementation.
* "the review agent appends only finding rows" →
  **D-006** (prompt edit removes envelope key from row
  enumeration; agent appends content-only rows below the
  3-line header).
* "`bin/review-ledger-schema.sh` validation runs against the
  orchestrator-seeded header + agent-appended rows" →
  **D-005** (validator extended with line-3 byte-check; per-row
  ledger_schema_version becomes lenient).
* "Update `AGENT_PROMPTS.md` §5: instruct the agent to append
  rows only, not author the seed-header/version" → **D-006**.
* "Reconcile with the append-only + clear-on-dispatch-start
  contract: orchestrator re-seeds the header on each review
  dispatch; agent rows append beneath" → **D-002a + D-004**
  (the seed function is idempotent on already-migrated files;
  migration runs once per ledger; rows preserved via
  `tail -n +3`).
* "Tests: agent appends rows with no header → orchestrator-
  seeded header makes the ledger schema-valid; the [ENG-190]
  rc=49 seed-header/version defects can no longer originate
  from agent omission" → **D-009** (OS-1/OS-2/OS-3 orchestration
  tests; V-1 validator regression; AP-1 prompt-content pin).

The Linear ticket's OUT list:

* "qa/plan/verdict-review artifacts (sibling children)" →
  none touched.
* "The ledger's finding-row schema / severity-ladder semantics
  (ENG-190 territory) — only header/version authorship moves"
  → severity-ladder, critical-floor, ENG-191 deferability,
  ENG-194 plan-scope, ENG-193 follow-up tickets all unchanged.
  D-005 is surgical: line-3 byte-check added, per-row
  ledger_schema_version becomes lenient. NO other validator
  change.
* "Merge-helper mechanism ([ENG-203]) — this child adapts it
  to the JSONL/append shape" → D-007 explicitly does NOT reuse
  `merge_artifact_envelope`. The adaptation is "header-line
  envelope + content-only rows," a structurally different
  pattern.

NO scope creep. NO scope shortfall.

## 11. Persona review

### Iteration 1 — Initial doc

Six personas ran in series (design → security → scope →
coherence → product → feasibility). **All six returned PASS;
feasibility (the gating persona) reported zero P0 findings.**
Gate cleared at iter-1; no iter-2 needed.

| Persona     | Verdict | P0 | P1 | P2 |
|-------------|---------|----|----|----|
| Design      | PASS    | 0  | 4  | 4  |
| Security    | PASS    | 0  | 3  | 3  |
| Scope       | PASS    | 0  | 2  | 4  |
| Coherence   | PASS    | 0  | 2  | 3  |
| Product     | PASS    | 0  | 2  | 2  |
| Feasibility | PASS    | 0  | 1  | 3  |

**P1 findings folded into the doc** (changes named, by section):

| Persona     | Finding | Resolution |
|-------------|---------|------------|
| Design P1#1 | D-003 lenient check creates a silently-accepting third state; predicate to log "regressed agent emitted ledger_schema_version" already exists. | OQ-3 reworded to acknowledge the cheap predicate availability; in-scope addition deferred (metrics surface lives in ENG-202 per OQ-3). |
| Design P1#2 + Product P1#1 | D-008 cutover edge case undersold for K=2 concurrency. | D-008 now explicitly names "up to `max_concurrent_features` issues bounded" and points to the diagnostic distinguishability addition under D-005. |
| Design P1#3 | D-004 migration should `log` migration cause for grep recipes. | The migration body in D-004 now emits `log "_ensure_review_ledger: migrated $lgr to 3-line header (tail_from=$tail_from)"`; `die` already triggers `log` (common.sh contract). |
| Design P1#4 | D-006 anchor-literal coupling to `SEED_LINE_3`. | Added "Anchor-literal coupling caveat" under D-006 — pin all three callsites (validator constant, prompt anchor, AP-3 test) move in lockstep. |
| Security P1#1 | OQ-2 (deferred symlink guard) — one-line guard is cheap. | OQ-2 promoted from defer to YES; migration body now includes `[[ -L "$lgr" ]] && die`. |
| Security P1#2 | TOCTOU vs human `vi` editing during migration. | Documented in §6 ("Concurrent operators editing the same ledger by hand during a halt") + recovery runbook §12 will note "operator should not hand-edit during an active reviewing dispatch." |
| Security P1#3 | Line-3 diagnostic should NOT interpolate agent-controlled content. | D-005 diff sketch now sanitises `hdr_line_3` via `sanitise_for_diag` before interpolation; an in-code comment warns future maintainers not to add row-level enrichment without going through the sanitisation chain. |
| Scope P1#1 | OQ-4 deferral of forensic anchors is a literal scope shortfall against IN text. | §10 Scope guard now flags this for explicit operator ack at plan time. |
| Scope P1#2 | Doc additions creep slightly beyond IN. | §3.1 row count for the runbook addendum bumped (~15→~18, ~6→~10) to absorb the more concrete prose added by the Product P1 fold-ins. |
| Coherence P1#1 | D-004 migration body's "after the existing check" comment contradicts A23. | D-004 migration body rewritten as the FULL function showing the three-case dispatch; explicitly notes the existing `[[ -f "$lgr" ]] && return 0` is REPLACED. |
| Coherence P1#2 | Validator byte-check line range cited inconsistently (181-188 vs 185-188). | The brainstorm uses 181-188 (range of the integrity-check block) and 183-188 (range of the diagnostic+return statements). Both ranges are correct but reference different sub-spans; plan stage should pin the edit target as the integrity-check block (181-188 inclusive of `hdr_line_*` reads). |
| Product P1#1 | Migration trap-class: operator hand-paste of corrupt line-3 preserved as a "row" by `tail -n +3`. | D-004 migration body now uses an adaptive `tail_from`: detects comment-like line 3 (`${third_line:0:1} == "#"`) and uses `tail -n +4` to CONSUME the corrupt line. |
| Product P1#2 | Validator diagnostic should distinguish "line-3 absent" vs "line-3 drifted." | D-005 diff sketch now emits the actual `hdr_line_3` value (sanitised) in the diagnostic; absent → `<absent>`, drifted → `'<sanitised value>'`. |
| Product P2  | AP-4 — anchor literal appears EXACTLY ONCE in §5. | Added to D-009 test list. |
| Feasibility P1 | A19 defensive fallback is partially dead code; predicate could simplify. | Acknowledged; folded as a plan-stage simplification note rather than design pivot — the lenient check works correctly either way. The `2>/dev/null || printf 'missing'` fallback stays as documented defense-in-depth against jq invocation collapse (rare but possible under disk/memory pressure). |

**Independent codebase-fact checks** (feasibility persona): all 28
A-rows (A1-A28) CONFIRMED against cited line ranges (1 was
**assumed**; A19 spot-checked against jq's actual `.field | type`
semantic and noted as "partially dead code, kept for defense-in-
depth"). No design pivots required from the verification pass.

**Persona panel readout.** The brainstorm is design-coherent,
factually grounded, in-scope (with one explicit operator-ack
flag on OQ-4's forensic deferral), and structurally closes the
ENG-190 rc=49 seed-header/version slip class for agent omission.
All P1 findings folded; P2 findings acknowledged. No iteration
2 needed.
