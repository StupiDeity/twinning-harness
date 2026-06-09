---
linear: ENG-153
title: guards.sh — require --reason on bump (fail-closed); emit reason + count/threshold in body
date: 2026-05-19
status: draft
---

# guards.sh — require `--reason` on bump (fail-closed); emit reason + count/threshold in body

## 1. Overview / Problem

`bin/guards.sh::bump` (lines 157-164) accepts only `<issue_id>` and
`<counter>`. The body it posts is hard-coded:

```bash
bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" \
  "<!-- meta: metric name=$counter --> Counter bumped by guards.sh."
```

An operator inspecting the Linear thread sees:

```
<!-- meta: metric name=implement_rejection -->
Counter bumped by guards.sh.
```

— no reason text, no current count, no trip threshold, no link to the
upstream cause. The ENG-81 2026-05-14 incident (umbrella ENG-104,
closed as subsumed) flagged this gap: an unexplained counter bump
appeared between an agent's PASS claim and a halt comment hours
upstream, and operator triage had to cross-reference
`issue-state.json` + the per-stage transcript to recover meaning.

ENG-153 makes the bumper fail-closed without `--reason "<text>"`, bakes
the populated body the ENG-104 §D sketch describes, and registers the
shape under `pipeline-events.json::events.metric` so the schema
contract ENG-112 introduced (single source of truth for "what a
comment for this event looks like") covers metric-family writes too.

Acceptance criteria from the ticket, mapped to the design below:

| AC | What | Where covered |
|---|---|---|
| #1 | `bash bin/guards.sh bump <ident> <counter>` (no `--reason`) exits non-zero | D-001 |
| #2 | All call sites in `bin/run-stage.sh` pass `--reason` | D-006 |
| #3 | Counter-bump body contains: reason text, current count, trip-threshold, `metric` footer marker with `reason-code` | D-002 + D-004 |
| #4 | Test fixture covers a counter-bump from agent rejection — body asserts contain the halt-reason verbatim | D-007 |
| #5 | `bin/pipeline-events.json::events.metric` registers `reason` as required | D-003 |

## 2. Decisions

### D-001. `bump` requires `--reason "<text>"`; fail-closed on missing flag (die rc=2).

**Decision.** `bin/guards.sh::bump`'s signature becomes

```
bash bin/guards.sh bump <issue_id> <counter> --reason "<text>" [--reason-code <token>]
```

A missing `--reason` (or an empty value) terminates via the `die`
helper from `bin/common.sh` (the standard exit path; defaults to
`exit 1` with the message on stderr). `--reason "<text>"` argument
is free-form prose; `--reason-code <token>` is closed vocabulary
validated against a new registry array `metric_reason_codes` (see
D-003).

CLI parse loop (after `<issue_id>` and `<counter>`):

```bash
local reason="" reason_code=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason)      reason="${2:-}";      shift 2 ;;
    --reason-code) reason_code="${2:-}"; shift 2 ;;
    *) die "bump: unknown flag '$1'" ;;
  esac
done
[[ -n "$reason" ]] || die "bump: --reason \"<text>\" required (counter=$counter, ident=$ident)"
```

The fail-closed branch lands BEFORE any Linear write — no half-success
state to clean up.

**Reasoning.** Mirrors the ENG-153 ticket's literal goal statement
(*"`--reason` becomes the required form (fail-closed without
`--reason`)"*) and the ENG-112 die-loud policy (D-005 of that
brainstorm: schema-mismatch surfaces immediately rather than silently
corrupting the ledger). Operators discover broken call sites at the
first stage that exercises them, not via post-mortem grep.

**Reference principle.**
[`CLAUDE.md` "When wiring a new script"](../../CLAUDE.md) — "Use `log` /
`die` / `require_env` / `require_bin` from common.sh"; ENG-112 D-005
"Schema validation is a die-loud `set -euo pipefail` path; no
fail-open soft fallback".

**Alternative considered.** Make `--reason` optional and default the
body to `Reason: (unspecified)`. Rejected — the entire reason this
ticket exists is to eliminate the unexplained-bump category; a
fallback re-creates the bug.

**Alternative considered.** Accept the reason as a positional third
argument (`bump <issue> <counter> <reason>`). Rejected — positional
strings break callers that have an existing `|| true` after the
two-arg call; named flags are explicit, future-proof for
`--reason-code`, and consistent with `pipeline.sh event verdict halt
--reason <token>` which is the closest sibling CLI.

### D-002. Marker shape extends to `<!-- meta: metric name=<name>[ reason-code=<reason-code>] -->`.

**Decision.** The footer marker grows one optional attribute. The
`reason` text does NOT live in the marker (it's free prose; markers
are whitespace-tokenised k=v pairs — `parse_pipeline_marker` in
`bin/common.sh:447-455` splits on whitespace). The `reason-code` is
closed-vocab (a single ASCII token) and CAN live in the marker.

Examples:

```
<!-- meta: metric name=implement_rejection -->                                  # no --reason-code supplied
<!-- meta: metric name=implement_rejection reason-code=scope-severe -->         # with --reason-code
```

**Reasoning.** This is the shape `bin/classify-failure.sh:194` already
emits today (`<!-- meta: metric name=transient-retry stage=X attempt=N -->`),
which proves the marker family tolerates trailing attributes. Free
text cannot go in the marker (whitespace would break `parse_pipeline_marker`'s
pair parser; `bin/common.sh:449` does `for pair in $rest` which
word-splits on IFS).

**Reference principle.**
[`docs/pipeline-vocabulary.md`](../pipeline-vocabulary.md) — closed
registry; meta-family bookkeeping with k=v attributes.

**Alternative considered.** Embed `reason="quoted text"` directly in
the marker (full machine-readability). Rejected — would require
re-engineering `parse_pipeline_marker` to support quoted values
(currently 7 lines of bash whitespace-splitting; ENG-87 explicitly
warns about marker proliferation pressure). The prose-body carries
the human-readable reason; the closed-vocab `reason-code` carries
the machine-readable one.

**Alternative considered.** Drop `reason-code` entirely and put
everything in prose. Rejected — retrospective §1 already classifies
metric markers by the closed name token; adding an optional
`reason-code` lets a future retrospective bucket bumps by underlying
cause (`scope-severe` vs `scope-minor` vs `noop-implementation`)
without text-mining the prose. The ticket explicitly names
`--reason-code` as part of IN scope.

**Alternative considered.** Carry `dispatch=ENG-N-dXXXX` inside the
metric marker (as the ENG-104 §D sketch showed). Rejected — ENG-87
auto-injection already appends a SIBLING marker
`<!-- meta: dispatch id=ENG-N-dXXXX stage=... -->` at the end of every
comment routed through `bin/linear.sh::add_comment` / `add_or_update_comment`
(see "Dispatch identifier and freshness contract" preamble in
AGENT_PROMPTS.md). Duplicating the dispatch token in the metric
marker is redundant and creates a drift hazard.

### D-003. Register `events.metric` in `bin/pipeline-events.json` (ENG-112 schema); add `metric_reason_codes` registry.

**Decision.** Extend `bin/pipeline-events.json` with:

```json
{
  "metric_reason_codes": [
    "scope-violation-severe",
    "scope-violation",
    "noop-implementation",
    "gotcha-hit"
  ],
  "events": {
    "metric": {
      "linear_comment": {
        "body_shape": "<!-- meta: metric name=<name>[ reason-code=<reason-code>] -->",
        "writer_lane": "orchestrator",
        "required": ["name"],
        "cli_required": ["reason"],
        "optional": ["reason-code"],
        "field_registry": {
          "name": "metric_names",
          "reason-code": "metric_reason_codes"
        },
        "dedup_sig": null
      }
    }
  }
}
```

The `scope-violation-severe` / `scope-violation` naming (vs an
earlier draft's `scope-severe` / `scope-violation`) shares the
`scope-violation` prefix so the retrospective's bucketing
("anything starting with `scope-violation`") collapses both into a
single axis without the operator having to maintain a synonym map.
Severity rides as the suffix.

`metric_names` is the existing implicit enumeration of valid counter
names (`review_rejection | qa_rejection | implement_rejection |
gotcha_triggered | learned_rule_renewal | transient-retry |
summary_missing | summary_truncated | worktree-mutated-by-agent`) —
materialised as a closed registry array so the validator can resolve
`field_registry.name`.

`required: ["name"]` is the marker-level invariant (validated by
ENG-112's `_validate_event_payload` against the actual marker body
shape). `cli_required: ["reason"]` is a NEW schema key introduced by
ENG-153 to declare CLI-layer-required fields that don't live in the
marker. This avoids overloading ENG-112's `required[]` (which has a
single, marker-field-oriented semantic — every entry resolves
through `field_registry` and is validated against the wire body).
The two keys carry orthogonal contracts:

- `required[]` — validated by `_validate_event_payload` against the
  marker text on every write through `bin/pipeline.sh`.
- `cli_required[]` — declared in the schema for documentation /
  retrospective tooling, enforced at the `bin/guards.sh::bump` argv
  layer (the marker doesn't carry these fields; they live in the
  comment's prose body or in a separate sibling marker).

This is what AC#5 calls "registers `reason` as required" — the
schema's `cli_required[]` declares it; the bumper enforces it. The
existing `_validate_event_payload` (line 116-177 of `bin/pipeline.sh`)
needs NO change — it ignores any schema keys it doesn't recognise
(`jq -r '... // ""'` defaults to empty on missing); the
`cli_required[]` extension is additive and back-compat with the three
event entries already in `pipeline-events.json`.

**Reasoning.** ENG-112 introduced the events schema as the single
source of truth for "what a Linear comment for this event looks
like". Without an `events.metric` entry, the metric-family
bookkeeping comments are exempt from the schema-driven contract —
which is exactly the gap the ENG-104 retrospective surfaced. The
ticket text says explicitly: *"`bin/pipeline-events.json` `metric`
event schema gains required `reason` attribute (per ENG-112's
contract)"*.

**Reference principle.** ENG-112 D-001
([`docs/brainstorms/2026-05-18-eng-112-linear-ledger-ledger-schema-in-pipeline-events-json-design.md`](2026-05-18-eng-112-linear-ledger-ledger-schema-in-pipeline-events-json-design.md))
— schema co-located with value registry; one file, one validator.

**Alternative considered.** Add `events.metric` but skip the
`metric_reason_codes` enumeration and treat `reason-code` as
free-form. Rejected — opens the closed-vocab discipline back up
(`bin/pipeline-events.json` is the canonical closed registry); the
expected vocabulary is small (3-4 codes) and curated.

**Alternative considered.** Skip the schema entry entirely (CLI-only
enforcement in `bin/guards.sh`). Rejected — splits the contract: the
"what's a legal metric body" rule lives in two places, drift surface.
ENG-112's headline value is centralisation; ENG-153 should consume
the schema, not bypass it.

### D-004. Body composition: 3-line populated body + footer marker.

**Decision.** The new `bump()` body template is:

```
COUNTER — <counter_name> bumped (<count>/<threshold>)
Reason: <free-text reason>
Trips at: <threshold>/<threshold> within current stage iteration → halt with skip-until-human-acts.

<!-- meta: metric name=<counter_name>[ reason-code=<reason-code>] -->
```

`<count>` is the count of existing markers for `<counter_name>` after
this bump (i.e. pre-existing + 1). `<threshold>` is read from
`.pipeline-config/config.json::human_checkpoints.require_human_on_threshold.<key>`
via `config_get` — the same lookup path `check()` uses
(`bin/guards.sh:106-110`); a missing key defaults to 2 (parity with
`check()`'s defaulting at `bin/guards.sh:113-117`).

Counter-name → threshold-key mapping (mirrors `check()`):

| counter | config key | default |
|---|---|---|
| `review_rejection`     | `review_rejections_per_feature`    | 2 |
| `qa_rejection`         | `qa_rejections_per_feature`        | 2 |
| `implement_rejection`  | `implement_rejections_per_feature` | 2 |
| `gotcha_triggered`     | `gotcha_trigger_count`             | 2 |
| `learned_rule_renewal` | `learned_rule_renewals`            | 2 |

The "Trips at" wording is conditional on whether the threshold-trip
results in a `skip-until-human-acts` policy (rejection counters) vs
clearing on the `pipeline:knowledge-reviewed` /
`pipeline:rule-reviewed` ack labels (gotcha/rule). Two prose
variants, switched on counter-name:

- Rejection counters: `Trips at: N/N within current stage iteration → halt with skip-until-human-acts.`
- `gotcha_triggered`: `Trips at: N/N → halt; cleared by label pipeline:knowledge-reviewed.`
- `learned_rule_renewal`: `Trips at: N/N → halt; cleared by label pipeline:rule-reviewed.`

**Reasoning.** The body shape mirrors the ENG-104 §D sketch (the
ticket's design-sketch reference) minus the per-comment header line
which the ticket explicitly defers to a separate follow-up
("Header line on every comment (separate follow-up; counter-bump
body can adopt the header once that ticket ships)"). The trip
threshold's clearing semantics differ across counters per
`bin/guards.sh:136-141`, so the prose must reflect them.

**Reference principle.** ENG-104 §D (ticket-cited canonical sketch);
ENG-63 D-001 (operator-facing chronological signal — bodies should
be self-explanatory at first read, no transcript scavenger hunt).

**Alternative considered.** Single-line body (`COUNTER bumped:
<counter> (<count>/<threshold>) — <reason>`). Rejected — the prose
"Trips at:" line carries the recovery hint (the label that clears
the trip, or the policy that pins it). Operators benefit from the
remediation pointer being inline, not implicit.

### D-005. Update marker-reader sites in lockstep — switch from literal `contains("...-->")` to a tolerant test.

**Decision.** Today's readers anchor on the literal closing `-->`
immediately after `name=X`. Adding `reason-code=` shifts the closing
`-->` past the new attribute, silently breaking these:

| Reader | Today's match (every line) | Fix |
|---|---|---|
| `bin/guards.sh:67` (`count_marker` jq filter) | `contains($m)` where `$m = "<!-- meta: metric name=X -->"` | Switch to single regex: `test("<!-- meta: metric name=X( [^>]*)?-->")` (matches either the immediate close or any whitespace-prefixed continuation — robust to `reason-code` AND any future trailing attribute, including the `stage=` / `attempt=` shape `classify-failure.sh:194` already emits) |
| `bin/guards.sh:92` (`count_marker_since_last_operator_resume`, no-resume branch) | same literal `contains($m)` | same `test()` regex |
| `bin/guards.sh:98` (`count_marker_since_last_operator_resume`, post-resume branch) | same literal `contains($m)` | same `test()` regex |
| `bin/status.sh:326` (dashboard filter) | `test("<!-- meta: metric name=[a-z_-]+ -->")` | Extend regex to `<!-- meta: metric name=[a-z_-]+( [^>]*)?-->` |
| `bin/status.sh:328-330` (dashboard capture — the body extractor that names the metric in the printed row) | `capture("<!-- meta: metric name=(?<m>[a-z_-]+) -->")` | Extend capture to `capture("<!-- meta: metric name=(?<m>[a-z_-]+)( [^>]*)?-->")` |
| `bin/verdict-handler-test.sh:517` | `contains("<!-- meta: metric name=qa_rejection -->")` | Match by prefix `contains("<!-- meta: metric name=qa_rejection")` (test fixture only — safe to broaden) |
| `bin/run-stage-test.sh:1660` | `grep -q '<!-- meta: metric name=implement_rejection -->'` | Match by prefix `grep -qE '<!-- meta: metric name=implement_rejection[ -]'` |
| `bin/classify-failure-test.sh:281` | already prefix-match `*"<!-- meta: metric name=transient-retry"*` | no change |

A single regex shape (`<!-- meta: metric name=X( [^>]*)?-->`) is
preferred to the contains-pair `contains("X ") or contains("X -->")`
because the contains-pair admits false positives where a literal
substring `name=X ` appears elsewhere in the body (e.g. quoted in
prose); the regex anchors to the literal `<!-- meta: ... -->`
envelope.

`bin/classify-failure.sh:194` already emits multi-attribute metric
markers (`<!-- meta: metric name=transient-retry stage=X attempt=N -->`),
so the readers that already tolerate this (e.g. the prefix-match in
`bin/classify-failure-test.sh:281`) prove the design is viable;
ENG-153 closes the gap on the readers that DIDN'T tolerate it.

**Reasoning.** Silent reader breakage would manifest as `check()`
returning 0 on a 2-marker counter (because `count_marker` reports 0
since none of the new-shape markers match the old literal pattern),
allowing infinite loopback past the threshold. The fix is
mechanical but MUST land in the same PR — otherwise the bug surfaces
in production the first time a `reason-code` is supplied.

**Reference principle.**
[`docs/runbooks/operator-mental-model.md`](../runbooks/operator-mental-model.md) —
silently load-bearing assumptions cost operator time;
`bin/run-stage-test.sh::case-15`-style fixtures are the regression
guard.

**Alternative considered.** Two-tier writes — keep the legacy marker
shape forever and append a SECOND marker carrying `reason-code` (e.g.
`<!-- meta: metric name=X --><!-- meta: metric-reason name=X
code=Y -->`). Rejected — duplicates the marker family, fights the
ENG-87 marker-proliferation pressure, and the reader update is the
simpler half of the work.

### D-006. Caller updates — all 4 current sites (3 in `run-stage.sh` + 1 in `scan-gotcha-trailers.sh`).

**Decision.** Four caller updates in this PR:

| Caller | Today | New |
|---|---|---|
| `bin/run-stage.sh:1702` (SEVERE scope violation) | `guards.sh bump "$ident" implement_rejection` | + `--reason "SEVERE scope violation on $branch: <files>" --reason-code scope-violation-severe` |
| `bin/run-stage.sh:1708` (other scope-check fail) | `guards.sh bump "$ident" implement_rejection` | + `--reason "scope-check rc=$scope_rc: <detail>" --reason-code scope-violation` |
| `bin/run-stage.sh:1750` (noop-implementation halt) | `guards.sh bump "$ident" implement_rejection` | + `--reason "implementing dispatch produced zero new commits (HEAD unchanged from $_HEAD_PRE_DISPATCH)" --reason-code noop-implementation` |
| `bin/scan-gotcha-trailers.sh:38` (Gotcha-hit trailer) | `guards.sh bump "$issue_id" gotcha_triggered` | + `--reason "Gotcha-hit: $gid trailer found on commit on $branch" --reason-code gotcha-hit` |

`bin/run-stage.sh` callers each already construct a detailed
classify_failure message right before the bump (e.g. `bin/run-stage.sh:1703-1704`,
`1711-1713`, `1751-1753`); the `--reason` text reuses the same
strings so the body and the classify-failure halt comment carry
the same prose. (One source of truth per dispatch.)

**Reasoning.** The ticket names only `bin/run-stage.sh` in IN scope,
but `bin/scan-gotcha-trailers.sh:38` is the fourth live `bump`
caller and would fail-closed at the first Gotcha-hit trailer on a
branch after this PR ships. The ticket's wording ("All current
callers in `bin/run-stage.sh` updated") undercounts; the only
honest scope is "every live caller". Flagged in §5 Scope.

**Reference principle.** The ticket's own AC#1 ("`bash bin/guards.sh
bump ENG-N implement_rejection` (no `--reason`) exits non-zero") —
if any caller still lacks `--reason`, AC#1 silently turns into a
production landmine the first time that caller fires.

**Alternative considered.** Update only `run-stage.sh` and let
`scan-gotcha-trailers.sh` die-loud on the first Gotcha-hit. Rejected —
that's a known regression we'd be introducing intentionally; the
detector script is one-liner mechanical fix.

### D-007. Tests in `bin/guards-test.sh` covering fail-closed and populated-body paths.

**Decision.** Add new cases to `bin/guards-test.sh`:

- **case-bump-1 (AC#1).** `bash bin/guards.sh bump ENG-T153A implement_rejection` (no flags) → rc != 0, stderr contains `--reason "<text>" required`.
- **case-bump-2 (AC#3, AC#4).** `bash bin/guards.sh bump ENG-T153B implement_rejection --reason "SEVERE scope violation on x.sh" --reason-code scope-severe` → rc=0; capture posted body via the test stub `linear.sh` and assert it contains `Reason: SEVERE scope violation on x.sh`, `(1/2)`, `Trips at: 2/2`, and `<!-- meta: metric name=implement_rejection reason-code=scope-severe -->`.
- **case-bump-3 (AC#3 without reason-code).** Same as case-bump-2 minus `--reason-code` → body contains `<!-- meta: metric name=implement_rejection -->` (no `reason-code=` attribute) and `Reason: ...`.
- **case-bump-4 (D-003 schema-reject).** `--reason-code bogus-token` → die loud (validates against `metric_reason_codes` via the ENG-112 `_validate_event_payload` or a parallel local check).
- **case-bump-5 (counter math).** Stub `linear.sh get-comments` to return one pre-existing `implement_rejection` marker; bump with `--reason "x"`; assert body contains `(2/2)` (1 existing + 1 new).
- **case-bump-6 (gotcha clearing prose).** Counter `gotcha_triggered` produces the alt "Trips at: ... cleared by label pipeline:knowledge-reviewed" wording.
- **case-bump-7 (D-005 regression — reader tolerates `reason-code`).** Seed two `<!-- meta: metric name=implement_rejection reason-code=scope-severe -->` markers in the `get-comments` stub; call `bash bin/guards.sh check ENG-T153G implementing`; assert `rc=10` and output contains `implement_rejection(2>=2)` — i.e. the marker-reader update lands.

The test pattern mirrors `bin/guards-test.sh:48-93` (per-case stub
writer + `set +e` / `set -e` rc capture).

Per the body-posting capture: the existing stub layout writes
`$FAKE_REPO/.pipeline/bin/linear.sh` as an executable shell stub —
extend it to append `add-comment` argv to a file under `$STUB_DIR`
so tests can read the posted body after the bump call returns.

**Reasoning.** AC#4 mandates a fixture asserting the body contains
the rejection's halt-reason verbatim. Case-bump-7 is the regression
guard for D-005 — without it, future readers can silently drop
support for the `reason-code` suffix.

**Reference principle.** [`CLAUDE.md` "Tests"](../../CLAUDE.md) —
source-and-stub pattern; sibling `*-test.sh` is the unit of test
isolation.

## 3. Architecture (where code goes)

| File | Change |
|---|---|
| `bin/guards.sh:50-51`               | Update usage comment: `bump <issue_id> <counter> --reason "<text>" [--reason-code <token>]` |
| `bin/guards.sh:65,90,95`            | Marker-reader update — `contains("<!-- meta: metric name=X -->")` → tolerant match per D-005 |
| `bin/guards.sh:157-164`             | Rewrite `bump()`: parse flags; require `--reason`; validate `--reason-code` against `metric_reason_codes`; read existing count via `count_marker`; resolve threshold via `config_get`; compose body per D-004; post via `linear.sh add-comment` |
| `bin/guards.sh:172`                 | Update `usage:` die-message |
| `bin/pipeline-events.json:1-124`    | Add `metric_reason_codes` registry; add `events.metric.linear_comment` per D-003 |
| `bin/run-stage.sh:1702,1708,1750`   | Pass `--reason "<text>" --reason-code <token>` to each `guards.sh bump` invocation (D-006) |
| `bin/scan-gotcha-trailers.sh:38`    | Pass `--reason "<text>" --reason-code gotcha-hit` to bump (D-006) |
| `bin/status.sh:326-332`             | Marker-reader regex tolerates trailing `reason-code=` (D-005) |
| `bin/verdict-handler-test.sh:517`   | Test fixture: prefix-match `contains("<!-- meta: metric name=qa_rejection")` (D-005) |
| `bin/run-stage-test.sh:1660`        | Test fixture: prefix-match `grep -qE '<!-- meta: metric name=implement_rejection[ -]'` (D-005) |
| `bin/guards-test.sh`                | Append case-bump-1..7 per D-007 |
| `docs/pipeline-vocabulary.md`       | Regenerated by `bin/generate-vocabulary-doc.sh` to surface the new `events.metric` schema section (mechanical — ENG-112's generator already drives the existing 3 event schemas) |

No new files. No new helpers in `bin/common.sh` (the existing
`parse_pipeline_marker` handles the trailing `reason-code=` attribute
since it word-splits and parses k=v pairs at `bin/common.sh:447-455`).

## 4. Data flow

1. `bin/run-stage.sh` (or any other caller) decides to bump:
   ```bash
   bash bin/guards.sh bump "$ident" implement_rejection \
       --reason "scope-check rc=21: <detail>" \
       --reason-code scope-violation || true
   ```
2. `bin/guards.sh::bump`:
   a. Parses flags; dies if `--reason` missing or empty.
   b. Rejects `--reason` values containing `<!-- pipeline:` or
      `<!-- meta:` substrings (§6 marker-injection guard).
   c. Validates `--reason-code` token against `metric_reason_codes`
      (skip if unset).
   d. Reads pre-bump count: `existing=$(count_marker "$ident" "$counter")`.
   e. `<count>` displayed in the body = `existing + 1` (local
      arithmetic — NO post-write Linear re-read; the count rendered
      is the count INCLUDING this bump, computed before the wire
      write so the body is consistent with the marker it carries).
   f. Reads threshold via `config_get '.human_checkpoints.require_human_on_threshold.<key>'`
      (default 2).
   g. Composes the body string (D-004 template).
   h. Posts via `bash linear.sh add-comment "$ident" "$body"` —
      `add-comment` is the append-only path; idempotency is
      irrelevant here because every bump is intentionally a
      distinct event (ENG-104's append-only ledger principle).
3. `bin/linear.sh::add_comment` auto-injects the ENG-87 dispatch marker
   on a separate line, producing a final wire body:
   ```
   COUNTER — implement_rejection bumped (1/2)
   Reason: scope-check rc=21: <detail>
   Trips at: 2/2 within current stage iteration → halt with skip-until-human-acts.

   <!-- meta: metric name=implement_rejection reason-code=scope-violation -->

   <!-- meta: dispatch id=ENG-153-d0001 stage=implementing -->
   ```
4. On the NEXT `guards.sh check` call, `count_marker` /
   `count_marker_since_last_operator_resume` find the new marker via
   the tolerant matcher (D-005); `check()` trips when the running
   count reaches threshold.

## 5. Out of scope

- Header line on every comment (`[<ident> · <stage> · <dispatch-id> · <UTC> · <writer>]`).
  Explicitly deferred by the ticket to a separate follow-up.
- Removing `add-or-update-comment` from any caller — separate follow-up per the ticket.
- Refactoring `bin/classify-failure.sh:194` to route through the new
  `events.metric` schema. That writer composes multi-attribute metric
  markers ALREADY (it's the canonical "marker shape can grow" precedent
  D-002 cites) and post-ENG-153 the schema describes its body shape —
  but consuming the schema is a separate refactor.
- Operator manual `bump` from CLI as documented in `bin/guards.sh:42`.
  The new fail-closed signature applies, but no CLI-ergonomics changes
  beyond what the ticket dictates.

**Scope flag.** The ticket's IN scope names only `bin/run-stage.sh`
as the caller-update surface; `bin/scan-gotcha-trailers.sh:38` is a
4th live `bump` caller. D-006 includes it because skipping it would
introduce a guaranteed production fail-closed on the next Gotcha-hit
trailer (the AC#1 invariant becomes a landmine, not a safety net).
The implement-stage agent on this ticket should post a one-line
comment on the Linear issue calling out this caller-update delta
before opening the PR so the operator can ack the wording-vs-reality
gap. This is a one-line caller fix; the scope expansion is small
and mandatory.

**Ticket sizing rubric (CLAUDE.md "Ticket sizing rubric").**
Subsystems touched: **Linear contract** (`guards.sh`,
`pipeline-events.json`, marker shape) is the primary; **orchestrator**
(`run-stage.sh` caller updates, `status.sh` reader update) is
mechanical pass-through subordinate to the contract change;
**tests/fixtures** is mechanical regression coverage. Per the
rubric "2 subsystems with one clearly subordinate → autonomy-safe
IF the scope boundary is explicit". The boundary IS explicit:
ENG-153 is a contract-shape change; everything else follows
mechanically. Independent design decisions: two —
"fail-closed without `--reason`" (D-001) and "marker grows
`reason-code` attribute" (D-002). D-003 through D-007 are
mechanical consequences. Within rubric.

## 6. Error handling / edge cases

- **Empty `--reason` value** (`--reason ""`): die with same message as
  missing flag. Defensive check: `[[ -n "$reason" ]]` after `shift 2`.
- **Unknown counter name**: existing `case` at `bin/guards.sh:159-162`
  already dies. No change.
- **`config_get` returns `null` or empty for threshold**: default to
  2 (parity with `check()` at `bin/guards.sh:113-117`). Body shows
  `(N/2)` if config absent.
- **Pre-bump count fetch failure** (Linear API down): `count_marker`
  already returns `0` on jq-empty (`length` of an empty array). Body
  shows `(1/threshold)`. The bump still posts (best-effort), and the
  next tick's `check()` re-reads accurately. No new failure mode.
- **Reason text contains markdown / HTML**: prose is passed verbatim
  into the body. Linear renders markdown but does not execute HTML;
  the existing `linear.sh add-comment` path already handles arbitrary
  prose at `bin/run-stage.sh:1670-1672`.
- **Reason text contains a pipeline-family marker** (e.g. an operator
  pasting transcript text containing `<!-- pipeline: verdict result=pass -->`
  into `--reason`): defensive reject before the Linear write. The
  bumper validates `[[ "$reason" != *"<!-- pipeline:"* && "$reason" != *"<!-- meta:"* ]]`
  and dies on a hit. Rationale: `_classify_comment_body` in
  `bin/linear.sh` only inspects the FIRST non-blank line for lane
  attribution, so a marker on a later line of a prose body would slip
  past the lane fence (body classes as `other_comment` which all
  lanes can write) while still being readable by full-body parsers
  (`find_fresh_verdict`, `parse_pipeline_marker`). Today's callers
  emit orchestrator-controlled strings — live risk is low — but the
  one-line guard mirrors `_reject_legacy_marker_body`'s
  defense-in-depth philosophy and costs nothing.
- **Reason-code token contains chars outside `[a-z-]`**: rejected by
  `_validate_registry metric_reason_codes "$reason_code"`. The
  closed-vocab discipline (D-003) is the enforcement mechanism;
  future-proofing against attribute-injection via a malformed token
  is the registry's job.
- **Reason-code token contains shell metacharacters**: validated
  against the closed registry; invalid tokens die loud before the
  Linear write. (Same enforcement path as the "chars outside `[a-z-]`"
  edge case above.)
- **Concurrent bumps on the same issue** (two K=2 dispatches on the
  same issue, hypothetical): TOCTOU on `count_marker` → both could
  report the same pre-count N and post (N+1). Worst case: two bodies
  claim `(N+1/threshold)`. `check()` reads after-the-fact so still
  trips at threshold. Not worth defending against (per-issue
  in-flight lock at `bin/run-stage.sh` already serialises dispatches
  on a single issue).
- **Reader-update gap** (D-005): if any reader still anchors on the
  literal closing `-->` after this PR ships, an in-the-wild bump
  with `--reason-code` produces silent count-zero. Mitigation:
  case-bump-7 in D-007.

## 7. ADR stress test

ENG-153 puts pressure on three accepted decisions:

| Decision | Pressure | Resolution |
|---|---|---|
| **ENG-87** "Cross-dispatch staleness contract" — marker proliferation: every comment carries an auto-injected `<!-- meta: dispatch ... -->` marker. | Adding a `reason-code` attribute to the metric marker grows the marker payload. | No conflict — reason-code lives in the metric marker, not the dispatch one; the auto-injection is order-independent (siblings on the same comment body). |
| **ENG-112** "Ledger schema in pipeline-events.json" — `events.<name>.linear_comment` describes ONE marker shape per event. | ENG-112's three events (verdict, transition, decision) are pipeline-family. ENG-153 introduces an `events.metric` entry that's meta-family. | The schema is family-agnostic (the `body_shape` carries the literal `<!-- meta: ... -->` text); ENG-112 D-001 explicitly says "Three events drive the ledger today" — "today" anticipated extension. No conflict; schema gains a meta-family entry. |
| **ENG-104** "Append-only event ledger" (closed-as-subsumed; canonical sketch §D) | The bump body explicitly states reason + count/threshold — this is the §D shape. | No conflict; ENG-153 IS the §D realisation for this body family. |

No ADR is overturned. ENG-112's design intentionally left room for
the metric-family extension (D-001 wording: "Three events drive the
ledger today"); ENG-153 fills it.

## 8. Assumption inventory

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A1 | `bin/guards.sh::bump` today accepts `<issue_id> <counter>` only | verified | `bin/guards.sh:157-164` (function signature) |
| A2 | The body template today is the literal `<!-- meta: metric name=$counter --> Counter bumped by guards.sh.` | verified | `bin/guards.sh:163` |
| A3 | `bin/run-stage.sh` has exactly 3 `bump` call sites | verified | `bin/run-stage.sh:1702`, `1708`, `1750` |
| A4 | `bin/scan-gotcha-trailers.sh` has 1 `bump` call site | verified | `bin/scan-gotcha-trailers.sh:38` |
| A5 | `learned_rule_renewal` has no live bumper (manual / retrospective only) | verified | grep across `bin/*.sh` non-test files returned no other matches |
| A6 | `count_marker` and `count_marker_since_last_operator_resume` use literal `contains("...-->")` match | verified | `bin/guards.sh:65,90,95` |
| A7 | `bin/status.sh` dashboard regex anchors on closing `-->` | verified | `bin/status.sh:326-332` |
| A8 | `bin/classify-failure.sh:194` already emits multi-attribute metric markers | verified | `bin/classify-failure.sh:194` (`name=transient-retry stage=%s attempt=%d`) |
| A9 | `parse_pipeline_marker` parses meta-family k=v attributes via whitespace split | verified | `bin/common.sh:447-455` |
| A10 | `bin/pipeline-events.json` currently has `events` for `verdict`, `transition`, `decision` only | verified | `bin/pipeline-events.json:63-123` |
| A11 | `_validate_event_payload` and `_render_body` in `bin/pipeline.sh` are reusable for new schema entries | verified | `bin/pipeline.sh:116-258` (event/arm parametric) |
| A12 | `config_get` reads `.pipeline-config/config.json` via jq path | verified | `bin/common.sh:720-723` |
| A13 | The 5 counter→threshold-config-key mappings in D-004 match `check()`'s lookups | verified | `bin/guards.sh:106-110` |
| A14 | `bash bin/guards.sh bump` callers all use `|| true` so a die during the rollout window won't crash the dispatch | verified | `bin/run-stage.sh:1702,1708,1750` and `bin/scan-gotcha-trailers.sh:38` (the gotcha caller does NOT have `|| true` — see B-1 below) |
| A15 | ENG-112's schema validator (`_validate_event_payload`) is portable to event names other than `verdict`/`transition`/`decision` | verified | `bin/pipeline.sh:116` parametric on `<event>` |
| A16 | The `dispatch` auto-injection appends a SIBLING marker on every comment routed through `bin/linear.sh::add_comment` | verified | preamble "Dispatch identifier and freshness contract"; AGENT_PROMPTS.md mention of `_inject_dispatch_marker` |

**B-1 (verified, not assumed).** `bin/scan-gotcha-trailers.sh:38`'s
bump invocation has NO `|| true` suffix (the line reads
`bash "$SCRIPT_DIR/guards.sh" bump "$issue_id" gotcha_triggered`).
A fail-closed bump call without `--reason` would propagate out of
the script's `set -euo pipefail` and break the implementing-stage
dispatch's trailer scan. D-006 updates this caller as part of the
mandatory scope expansion.

No "assumed" entries: every referenced file path, line number,
function name, registry key, and config path was verified against
the worktree before drafting.

## 9. Open questions

- **OQ-1.** Should `metric_reason_codes` be exhaustively pre-populated
  for every existing metric counter, or seeded with only the 4
  caller-emitted codes (`scope-violation-severe`, `scope-violation`,
  `noop-implementation`, `gotcha-hit`) and grown as needed? Proposal:
  seed with the 4 and let the closed-vocab grow per follow-up — adding
  a code is one-line `pipeline-events.json` diff.
- **OQ-2.** `learned_rule_renewal` has no live bumper today (only
  manual ops). Should the schema carve out a per-counter
  required-fields map (e.g. require `reason-code=gotcha-hit` on
  `gotcha_triggered`)? Out of scope unless an operator request
  drives it. (Earlier draft referenced an `events.metric.required_by_arm`
  key by analogy with `events.verdict.required_by_arm` from
  `bin/pipeline-events.json:69-75`; that key would need to be
  introduced if this OQ is acted on — the schema draft in D-003
  doesn't include it.)
- **OQ-3.** Should `bin/pipeline.sh` gain a `bump` sub-command that
  delegates to `bin/guards.sh::bump`, providing the schema-driven CLI
  surface as well? Out of scope — operators rarely manual-bump; the
  current `bin/guards.sh bump` interface is fine for the rare case.
- **OQ-4 (load-bearing follow-up).** The retrospective agent's §1
  metric stream consumer needs to be updated to capture and bucket
  by `reason-code` — that's the whole point of choosing a closed
  vocab over prose. Until that ships, `reason-code` is documentation
  only, with no automated consumer. Marked as a follow-up ticket
  (separate from ENG-153 implementation), recommended title:
  *"Retrospective §1 — bucket metric markers by reason-code"*. The
  ENG-153 PR description should list this as the load-bearing
  follow-up; without it the closed-vocab choice is wasted.

## Persona review

Iteration 1 — all 6 personas reviewed in parallel; gate clean
(6/6 PASS · feasibility P0 = 0). Findings recorded below;
actionable P1s addressed in the doc above before commit.

### design — PASS
- P1: D-003 `required[]` mixed marker/CLI semantics → introduced
  `cli_required[]` schema key to keep marker-side `required[]`
  ENG-112-compatible (addressed in D-003 schema body).
- P1: D-004 count math — `<count>` is local `count_marker(...) + 1`,
  not a Linear re-read (addressed in §4 step c and §6 outage edge).
- P1: D-005 reader fix — switched contains-pair to a single
  `test("name=X( [^>]*)?-->")` regex (addressed in D-005 table).
- P2 (deferred): D-006 cell-content brevity; A14 wording split;
  OQ-2 `required_by_arm` naming (OQ-2 reworded).

### security — PASS
- P1: reason-text marker-injection vector — added explicit defensive
  reject of `<!-- pipeline:` / `<!-- meta:` substrings in `--reason`
  values (addressed in §6 edge cases).
- P1: writer-lane semantics for `scan-gotcha-trailers.sh` subprocess
  (PIPELINE_WRITER inheritance from agent dispatch) — recorded as
  follow-up watchpoint: schema declares `writer_lane: orchestrator`
  but `_check_lane`'s classification of `other_comment` admits all
  lanes, so functional correctness is unaffected; lane-fence tightening
  is a separate follow-up if observed need.
- P2 (deferred): markdown-rendering of reason text (Linear renders
  prose as markdown — known and acceptable); registry char-class
  validator hardening (folded into "reason-code metacharacters"
  edge case).

### scope — PASS
- P1: ticket-sizing rubric borderline (3 subsystems with two
  subordinate) — added explicit rubric subsection to §5 pinning
  the boundary.
- P1: ticket text-vs-reality delta for `scan-gotcha-trailers.sh`
  caller — implement-stage agent should post a Linear comment
  acking the wording gap before opening the PR (noted in §5).
- P2 (deferred): `status.sh` reader framed as Linear-contract
  subsystem, not orchestrator (cosmetic).

### coherence — PASS
- P1: D-005 reader-update table undercounted the jq sites in
  `guards.sh` (4 invocations across 3 functions, not 3) AND
  `status.sh` regex appears at 326 + 328-330 (filter + capture) —
  table expanded to enumerate each line explicitly.
- P2 (deferred): A14 wording split; ENG-112 quote-citation drift;
  OQ-2 `required_by_arm` keyword (OQ-2 reworded).

### product — PASS
- P1: `scope-severe` vs `scope-violation` overlap was a real tell —
  renamed to `scope-violation-severe` / `scope-violation` to share
  the prefix (addressed in D-003 schema + D-006 caller table).
- P1: OQ-4 retrospective consumer is the load-bearing follow-up —
  promoted to explicit follow-up-ticket recommendation with
  recommended title (addressed in §9 OQ-4).
- P2 (deferred): body-shape "COUNTER" leading literal vs sentence
  case (cosmetic — operator-readable as-is); markers-after-prose
  visual hierarchy note (implicit and correct).

### feasibility — PASS · P0 = 0
- P1: `count_marker` outage behavior under `set -euo pipefail`
  is propagation, not return-0 — minor §6 wording imprecision.
  Captured as known caveat; bumper still posts best-effort on
  empty-result paths.
- P1: `bin/pipeline-events.json:1-124` is a whole-file pointer
  (acceptable; insertion will shift line counts).
- P2 (deferred): line-number precision in §2 D-002 citation;
  OQ-2 mentions a hypothetical schema key.
- Verification summary (every file confirmed): guards.sh,
  run-stage.sh, scan-gotcha-trailers.sh, pipeline-events.json,
  pipeline.sh, common.sh, status.sh, classify-failure.sh,
  verdict-handler-test.sh, run-stage-test.sh — all claims match
  the code at the line numbers cited.
