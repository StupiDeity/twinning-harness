---
linear: ENG-63
title: linear.sh add-or-update-comment — identical-body re-applies must be operator-visible
date: 2026-05-04
status: draft
---

# linear.sh `add-or-update-comment` — identical-body re-applies must be operator-visible

## 1. Overview / Problem

`bin/linear.sh::add_or_update_comment` (`bin/linear.sh:529-582`) deduplicates
posts by a per-sig HTML marker. When a caller re-applies the same sig with a
body that is **byte-identical** to the existing in-Linear comment, the
function calls `commentUpdate` (`bin/linear.sh:570-573`) with that identical
body. Linear's API short-circuits no-op updates: `createdAt` stays at the
original emission and `updatedAt` does not advance. The thread therefore
presents to the operator as if the halt fired exactly once, at the first
timestamp.

The acute incident — [ENG-58](https://linear.app/twinning/issue/ENG-58/) —
hit `_vh_protocol_violation` (`bin/verdict-handler.sh:52-60`) three times
across brainstorm (08:39:08Z), plan (12:13:18Z) and implement (13:36:01Z).
All three calls used sig `protocol-violation/no-marker/ENG-58`. The plan and
implement halts re-posted an identical body. Linear surfaced ONE comment,
dated 08:39:08Z, with `updatedAt: null`. Two operator "resume" cycles ran
against an issue whose `pipeline:halted` was being silently re-asserted
within seconds of each clear; ~30 minutes of confusion before the operator
realised the comment thread itself was lying.

This bug is not specific to `_vh_protocol_violation`. Every caller of
`add_or_update_comment` is exposed:

| Caller | Sig shape | Re-apply scenario |
|---|---|---|
| `bin/verdict-handler.sh:56-57` | `protocol-violation/<case_id>/<issue>` | Same case_id firing on a later stage produces an identical body. |
| `bin/classify-failure.sh:146` | `halt/<stage>/<issue>` | Same stage halting twice with same exit code, subcode, retry_count, branch and content hash → identical body. Common on retry-immediately churn. |
| `bin/run-stage.sh:212,216` | `completion/<stage>/<issue>` | Re-dispatched stages whose agent emits a deterministic stage-summary on an unchanged worktree produce identical bodies. |

Identical-body re-apply is the hot path, not an edge case.

## 2. Decisions

### D-001. Inside `add_or_update_comment`, detect "no-op update" and rewrite the body to include a `<!-- meta: reapplied at=<ts> -->` footer line.

**Decision.** After the existing-comment lookup at `bin/linear.sh:566-567`
succeeds, normalise both the existing body and the new body by stripping
any `<!-- meta: reapplied at=... -->` line, then byte-equal compare. If
equal, append a fresh footer line to the new body (rotating the prior
footer, if any) before calling `commentUpdate`. If unequal, post the new
body as-is.

Resulting flows:
- **First post** (no existing comment) → `commentCreate` with the body plus
  its dedup marker. **No footer.**
- **Body genuinely changes** (e.g., new exit code in classify-failure body,
  new retry_count) → `commentUpdate` with the new body. **No footer.**
- **Body is identical to existing** (the bug case) → `commentUpdate` with
  `<existing>\n<!-- meta: reapplied at=<iso8601-utc> -->`. The body
  byte-changes, Linear's `updatedAt` advances, the operator sees a new
  footer line dated NOW.

**Why.** This is the issue's preferred Approach A. It is the smallest
surgical change that closes the visibility gap without touching caller
surfaces, sig naming, or the dedup contract. The `meta:` marker family is
already the documented bookkeeping namespace (`docs/pipeline-vocabulary.md`
header — "`<!-- meta: <kind> ... -->` bookkeeping"). `reapplied` is a new
`kind` in that family but governed by the same closed-vocabulary discipline
(D-005).

**Rejected — Approach B (split protocol-violation sig by stage to
`protocol-violation/<case_id>/<stage>/<issue>`).** Three grounds: (a) the
bug surface is broader than `_vh_protocol_violation` — classify-failure and
post_completion_comment re-applies hit the same invisibility (table in §1).
Approach B fixes one caller; Approach A fixes the function. (b) Linear has
no comment-delete primitive (`docs/runbooks/recovery.md:99-101` — "Linear
comments are append-only at the issue level — the API does not support
comment deletion"); each per-stage protocol-violation comment becomes
permanent thread litter, the failure mode the prompt sweep guards against.
(c) The dedup intent — one canonical comment per logical event — is a
deliberate design property; multiplying it by the stage axis weakens the
invariant for marginal value (the per-stage `createdAt` could already be
reconstructed from the metrics jsonl).

**Rejected — skip the `commentUpdate` API call entirely when the body is
identical.** This is the OPPOSITE of what the operator needs. Today the
call already silently no-ops at Linear's edge; skipping the call ourselves
achieves the same invisibility with less network traffic. The operator
complaint is precisely "I cannot see that the halt re-fired."

**Rejected — bump a hidden whitespace character to force `updatedAt` to
move.** Whitespace edits would move `updatedAt` (giving the "(edited)"
indicator in Linear's web UI) but leave NO inspectable evidence of WHEN the
re-apply occurred. The HTML-comment footer gives both signals — the
"(edited)" indicator for passive readers, and the timestamped footer for
operators inspecting the comment body via `linear.sh get-comments` or
Linear's "view source" affordance.

**Rejected — emit a visible (non-HTML-comment) footer like
`_re-applied: <ts>_`.** Operators reading the comment body in Linear's web
UI would see editorial markup mixed with the actual halt content, and the
line would survive into exported issue snapshots, retrospectives, and any
downstream rendering (Slack notifications, etc.). The hidden HTML comment +
"(edited)" indicator is the right asymmetry: visible to operators
inspecting the situation, invisible to passive readers.

### D-002. The strip regex matches ONLY the `<!-- meta: reapplied at=... -->` line, with explicit line anchors.

**Decision.** Strip the regex `^<!-- meta: reapplied at=[^>]* -->$` from
both bodies before byte-equal comparison. The `^...$` anchors are
load-bearing — they prevent the strip from deleting code-block-quoted prose
that happens to mention the marker shape. Anything else — timestamps inside
the body, git SHAs, retry counters, branch names — counts as a meaningful
change and skips the footer.

**Why.** `add_comment`'s broader timestamp/SHA scrub
(`bin/linear.sh:489-491,506-508`) exists for a different purpose: cross-comment
dedup (avoiding posting a brand-new duplicate when the only difference is a
timestamp). Our case is comparing existing-vs-new for THIS exact comment's
update path. The scope of "meaningful change" is wider here — every
`classify-failure` body carries `pipeline_content_hash` and `branch_head_sha`
fields (`bin/classify-failure.sh:144`); a fresh hash IS a meaningful update
even though both old and new look like SHAs.

**Rejected — reuse `add_comment`'s timestamp+SHA scrub.** Would mask
meaningful retry-count or hash changes in classify-failure halt bodies.
Every legitimate retry would normalise to "same body" and get a footer
instead of the real updated body. The scrub is the wrong abstraction for
the update path.

**Rejected — un-anchored regex `/<!-- meta: reapplied at=… -->/d`.** Would
silently strip a literal mention of the marker shape inside a fenced code
block (e.g., a stage-summary that quotes a prior re-apply). Anchoring
prevents that.

### D-003. Footer rewrite happens BEFORE `commentUpdate`; rotated, not stacked.

**Decision.** The existing body fetched in `bin/linear.sh:566-567` already
carries the prior footer (if any); the comparison strips it; on identity
the function rewrites a fresh footer at the bottom of the normalised new
body — there is exactly ONE footer line per comment, rotated to the latest
re-apply moment.

**Why.** Keeps the footer count at exactly one per comment over any number
of re-applies. The N-th re-apply rewrites the timestamp to the N-th moment.
Operators looking at the comment see "first emitted at `createdAt`, last
re-applied at `<footer ts>`" — two data points telling the full story.

**Rejected — counter footer `<!-- meta: reapplied count=N at=<ts> -->`.**
Tempting but out of scope — the issue's Approach A specifies a timestamp
footer only, no counter. Flagged as Q-001 for follow-up.

**Rejected — keep all prior footers as a stack.** Each re-apply would
extend the body by one line; over many re-applies the comment becomes
unreadable. Single rotating footer is the minimum viable signal.

### D-004. Footer is added on the UPDATE path only, never on CREATE.

**Decision.** The `commentCreate` branch (`bin/linear.sh:576-580`) skips
the footer entirely. A first emission has no "re-application" to signal;
the comment's own `createdAt` carries that information.

**Why.** Clarity. The footer's semantic is "this body was previously
posted under this sig and re-applied at `<ts>`." Putting it on a create
call would be misleading.

### D-005. The new marker `<!-- meta: reapplied at=<iso8601-utc> -->` joins the closed `meta:` vocabulary registry.

**Decision.** Add `reapplied` to the `meta_kinds` array in
`bin/pipeline-events.json` (currently `["dedup","metric","evidence"]` per
`bin/pipeline-events.json:42-46`). `bin/generate-vocabulary-doc.sh:14`
already iterates `meta_kinds`; `docs/pipeline-vocabulary.md` is regenerated
from the registry.

**Why.** `bin/pipeline-events.json` is the source of truth for both
`pipeline:` and `meta:` token sets per the ENG-60 vocabulary closure.
Adding `reapplied` keeps the discipline intact and makes the marker
discoverable in the auto-generated vocabulary doc.

**Lane fence verification.** The body containing the footer rides through
`add_or_update_comment` → `commentUpdate`, the same call path the original
comment used. `add_or_update_comment` does not call `_check_lane` in its
current form (the lane check in `add_comment` at `bin/linear.sh:476-479`
is on a different code path); the footer therefore inherits whatever lane
the original comment was posted under. No new lane consideration.

**Rejected — free-form, non-registered marker shape.** The entire point of
the ENG-60 vocabulary closure was to prevent ad-hoc markers from
accumulating. The footer is operator-facing observability infrastructure;
it gets the same registry treatment.

### D-006. Test fixture lives in `bin/linear-test.sh`, not in a new test file.

**Decision.** Add three test cases plus one metric-emission case at the
bottom of the existing `add_or_update_comment` test block
(`bin/linear-test.sh:493-510`):

1. **C-001** Identical-body re-apply emits a footer. Stub `linear_query`
   to return an existing comment with body B; re-call
   `add_or_update_comment` with body B in non-dry-run mode; assert the
   captured `commentUpdate` body matches `B + footer`.
2. **C-002** Different-body re-apply omits the footer. Stub existing body
   B; re-call with body B'≠B; assert the captured `commentUpdate` body
   equals B' (no footer).
3. **C-003** Repeated identical-body re-apply rotates the footer (does not
   stack). Stub existing body `B + footer1`; re-call with body B; assert
   captured body is `B + footer2` where footer2's timestamp differs from
   footer1's and exactly one footer line is present.
4. **C-004** Identical-body re-apply emits exactly one
   `metrics.sh comment-reapplied` event (D-009).

**Why this file.** `bin/linear-test.sh` already sources `linear.sh` with
`PIPELINE_DRY_RUN=1` (`bin/linear-test.sh:13,82`) and exercises
`add_or_update_comment`'s body-arg shapes (`bin/linear-test.sh:493-510`).
The pre-existing harness scaffolding (lines 18-92) gives us
`pass_at`/`fail_at`, the temp `TARGET_REPO` scaffold, and the linear-ids
stub.

**Why a stub for `linear_query`.** The existing tests run only the
dry-run path (`bin/linear.sh:553-556`), which short-circuits before any
GraphQL is fetched. To exercise the existing-body-comparison branch we
need to (a) bypass the dry-run guard for these specific cases, and (b)
inject a controlled GraphQL response. Override `linear_query` at the
top-level after sourcing — the function is global once sourced, so
re-defining it per test gives deterministic responses. Flip
`PIPELINE_DRY_RUN=0` for the duration of these four cases (and back to
1 afterwards to leave the rest of the file's invariants intact).

**Rejected — new file `bin/linear-reapply-test.sh`.** Test scaffolding
overlap is ~80 lines that would be duplicated. The suite already groups
`add_or_update_comment` cases together.

**Rejected — add to `bin/verdict-handler-test.sh`.** The bug is in
`linear.sh`, not `verdict-handler.sh`. The verdict handler's correctness
does not depend on whether the comment was re-posted with a footer —
that's a Linear-presentation property observable only via the linear.sh
code path.

### D-007. Operator-runbook update goes into `docs/runbooks/recovery.md`, with a one-line decision tree.

**Decision.** Add §4 titled "Halted issue with stale-looking halt comment
timestamp." Required body content:

1. **Symptom.** Linear shows `pipeline:halted` applied recently but the
   most-recent halt comment is dated to an earlier occurrence (and shows
   no "(edited)" indicator, OR shows one but `createdAt` looks stale).
2. **Authoritative signal.** The `pipeline:halted` LABEL is the state of
   record. Comment `createdAt` reflects only the FIRST emission of any
   given halt body; subsequent identical re-applies update the existing
   comment in place.
3. **Recency evidence.** Inspect via
   `bash bin/linear.sh get-comments ENG-N | jq -r '.[-5:][] | .body'`
   and look for a `<!-- meta: reapplied at=<ts> -->` footer line. If
   present, the timestamp shown is the most recent re-application moment
   (not the original `createdAt`).
4. **Operator decision tree** (one line each):
   - Footer present AND timestamp recent (< 1h) → halt is FRESH;
     investigate the halt's `reason=` token; do NOT just re-run
     `decide --action continue`.
   - Footer present BUT timestamp old → halt has not re-fired since;
     safe to investigate at leisure or `decide --action continue` if
     cause was external.
   - Footer absent → halt has only ever been emitted once at
     `createdAt`; treat per existing §3 guidance.

Plus update `CLAUDE.md`'s "Failure-mode quick reference" table row
"Issue stuck in `stage:X`" with a parenthetical: "comment `createdAt`
reflects FIRST emission only; check the `<!-- meta: reapplied at=... -->`
footer for the latest moment."

**Why this file.** `docs/runbooks/recovery.md:8` already advertises itself
as the "Quick reference for fixing issues stuck in three modes." Adding
the fourth mode here is the path of least surprise. No
`docs/operator-runbook.md` exists today (verified: `ls docs/` returns
brainstorms, plans, runbooks, pipeline-vocabulary.md, template).

**Note on stale `bin/halt.sh` references.** `docs/runbooks/recovery.md`
§3 still references `bash bin/halt.sh resolve ENG-N --decision resume`
(at line 176 and 202). `bin/halt.sh` was retired in ENG-58/ENG-60 —
operators use `bash bin/pipeline.sh decide ENG-N --action continue` now
(verified: `ls bin/halt.sh` returns "No such file or directory";
`bin/pipeline.sh:7,36,287` carries the new entrypoint). The new §4 uses
the current command shape. Modernising §3 references is OUT OF SCOPE for
ENG-63 (flagged as cleanup follow-up Q-002) — ENG-63's narrow scope is
the new mode.

### D-008. Comparison and footer rewrite happen inline in `add_or_update_comment`, not in a new helper.

**Decision.** Approximately 14 lines of bash inserted between
`bin/linear.sh:567` (existing_id resolution) and `bin/linear.sh:570` (the
existing_id update branch). No new top-level function.

**Why.** Logic is small enough that extraction adds indirection without
modularity payoff. The function is currently 54 lines (529-582); adding
14 keeps it under 70 — comfortable single-page read. Future tests can
call `add_or_update_comment` directly without setting up helper-call
fixtures.

**Rejected — extract `_strip_reapplied_footer`.** The regex is one line
and used twice in adjacent code; inline is more readable than indirection
here. If a third caller needs the strip, hoist then.

### D-009. Emit a `comment-reapplied` metric event on every footer rewrite.

**Decision.** Inside the identical-body branch (D-001), after the footer
is rewritten and BEFORE `commentUpdate`, fire:

```bash
bash "$SCRIPT_DIR/metrics.sh" comment-reapplied "$ident" "-" \
  "reapplied" 0 "sig=$sig" "comment_id=$existing_id" || true
```

The metrics.sh signature (verified at `bin/metrics.sh:19-22`) is
`<event> <issue_id> <stage> <outcome> <duration_ms> [notes…]`. The
`add_or_update_comment` scope does not always have a stage (the sig
sometimes embeds one — `halt/<stage>/<issue>` — but `protocol-violation/<case_id>/<issue>`
does not), so `-` is passed as the stage placeholder and the sig rides
in `notes`. Failure of the metric write does not fail the comment update
(`|| true`).

**Why (closes the operator-observability gap).** The retrospective agent
(`bin/run-retrospective-local.sh`) consumes `events.jsonl`
(`bin/metrics.sh`-managed). Without this emission, a pattern of "halt
re-fires N times silently" remains invisible to the retrospective: it
sees one halt comment, no churn signal. With the emission, the
retrospective can flag issues whose `comment-reapplied` count for the
same sig exceeds a threshold (e.g., ≥3 within a tick window) as
"halt-loop suspect" — exactly the regression class ENG-63 is hardening
against.

This is purely additive (one `metrics.sh` call); no schema migration, no
caller-facing API change. The `metrics.sh` event taxonomy already accepts
arbitrary event names per the `stage-end`/`halt-resume` precedent.

**Rejected — emit the metric from each caller** (verdict-handler,
classify-failure, post_completion_comment) rather than from
`add_or_update_comment`. (a) Forces every existing and future caller to
remember the metric, recreating the original "easy to overlook" failure
mode in a different shape. (b) The "this was an identical-body re-apply"
determination requires reading the existing comment, which is
`add_or_update_comment`'s job — pushing the metric upstream forces
callers to re-implement that fetch.

## 3. Architecture

### 3.1 Files modified

| File | Change |
|---|---|
| `bin/linear.sh` | Insert ~14 lines into `add_or_update_comment` between existing_id resolution and the existing_id update branch (D-001, D-002, D-003, D-004, D-008). Plus one `metrics.sh comment-reapplied` call (D-009). |
| `bin/pipeline-events.json` | Add `reapplied` to the `meta_kinds` array (D-005). |
| `bin/linear-test.sh` | Add C-001/C-002/C-003 plus the `linear_query` stub override and `PIPELINE_DRY_RUN` flip; add C-004 for metric emission (D-006, D-009). |
| `docs/runbooks/recovery.md` | Add §4 "Halted issue with stale-looking halt comment timestamp" with the four-step body and decision tree (D-007). |
| `CLAUDE.md` | Update "Failure-mode quick reference" row to point at the footer (D-007). |
| `docs/pipeline-vocabulary.md` | Auto-regenerated by `bin/generate-vocabulary-doc.sh` from the updated registry (D-005). |

No changes to `bin/verdict-handler.sh`, `bin/classify-failure.sh`,
`bin/run-stage.sh`, `bin/pipeline.sh`, `bin/poll.sh`, `bin/scope-check.sh`,
or any other caller. The fix is fully contained in `linear.sh`'s update
path; callers continue to pass identical bodies as they do today and
observe the new visibility property as a side effect.

### 3.2 Pseudocode for the `add_or_update_comment` change

```bash
# … existing code through bin/linear.sh:567 (existing_id resolution) …

if [[ -n "$existing_id" ]]; then
  # NEW: detect identical-body update and append a re-applied footer.
  # Compare existing body vs new body, both with any prior
  # `<!-- meta: reapplied at=… -->` line stripped. Regex is LINE-ANCHORED
  # so quoted prose can't be silently dropped (D-002).
  local existing_body
  existing_body="$(jq -r --arg id "$existing_id" \
    '[.data.issue.comments.nodes[]? | select(.id == $id) | .body] | first // ""' \
    <<<"$resp")"
  local strip_re='/^<!-- meta: reapplied at=[^>]* -->$/d'
  local existing_norm new_norm
  existing_norm="$(printf '%s' "$existing_body" | sed -E "$strip_re")"
  new_norm="$(printf '%s' "$body" | sed -E "$strip_re")"
  if [[ "$existing_norm" == "$new_norm" ]]; then
    local now_iso
    now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    body="${new_norm}"$'\n'"<!-- meta: reapplied at=${now_iso} -->"
    bash "$SCRIPT_DIR/metrics.sh" comment-reapplied "$ident" "-" \
      "reapplied" 0 "sig=$sig" "comment_id=$existing_id" || true
  fi

  local mu='mutation($id: String!, $body: String!) { commentUpdate(id: $id, input: { body: $body }) { success } }'
  # … unchanged from bin/linear.sh:570-573 …
fi
```

### 3.3 GraphQL impact

One additional `jq` parse over the already-fetched response (`$resp`,
`bin/linear.sh:565`) — no new GraphQL roundtrips. The existing query
(`bin/linear.sh:562`) already returns `{id body}` for up to 50 comments;
we now use the body field that was previously discarded by the
`existing_id` extractor.

## 4. Data flow

```
Caller (e.g., _vh_protocol_violation)
  │
  └─► bash bin/linear.sh add-or-update-comment <sig> <issue> <body>
        │
        ├─ append dedup marker <!-- meta: dedup key=<sig> --> if missing
        │  (unchanged — bin/linear.sh:547-551)
        │
        ├─ if PIPELINE_DRY_RUN=1 → log + return (unchanged — :553-556)
        │
        ├─ resolve issue uuid (unchanged — :558-559)
        │
        ├─ fetch last 50 comments, find existing comment by sig marker
        │  (unchanged — :562-567)
        │
        ├─ if existing_id is non-empty:
        │    ├─ NEW: extract existing_body from $resp by id
        │    ├─ NEW: strip <!-- meta: reapplied at=… --> from both sides
        │    ├─ NEW: if normalised bodies are byte-equal:
        │    │         body := normalised_body + "\n<!-- meta: reapplied at=<now> -->"
        │    │         metrics.sh comment-reapplied <issue> <sig> reapplied 0 …
        │    └─ commentUpdate(id=existing_id, body=body)
        │       (unchanged endpoint — :570-573)
        │
        └─ else:
             commentCreate(issueId=uuid, body=body)
             (unchanged — :576-580)
```

## 5. Error handling

- **`jq` extraction failure (existing_body parse).** If `jq` returns
  empty or errors, treat as "existing_body unknown" → skip the comparison,
  fall through to a normal `commentUpdate` with the caller's body.
  Functionally equivalent to today's behaviour on the comparison-failure
  path (the bug remains unfixed for that rare case but no new failure is
  introduced).
- **`date -u` failure.** macOS BSD `date` honours `+%Y-%m-%dT%H:%M:%SZ`
  natively (no GNU coreutils required). If for some reason `date` returns
  empty, the footer becomes `<!-- meta: reapplied at= -->` — still a
  body change, still moves `updatedAt`, just less informative. No
  defensive coding required.
- **`commentUpdate` failure.** Unchanged behaviour. The function does not
  retry; the caller (e.g., `bin/run-stage.sh:212-216` which has its own
  one-shot retry) handles retries.
- **`metrics.sh comment-reapplied` failure.** `|| true` suppresses; the
  comment update still proceeds. Rationale: comment visibility is
  load-bearing for the operator; retrospective signal is best-effort.

## 6. Edge cases

- **First-ever post (no existing_id).** D-004 — no footer.
  `commentCreate` runs with the unmodified body. `createdAt` carries the
  first-emission timestamp.
- **Mixed legacy/new dedup marker shapes.** Body fetched from Linear may
  carry `<!-- pipeline-sig: <sig> -->` (legacy ENG-60 predecessor), while
  caller-supplied body carries `<!-- meta: dedup key=<sig> -->` (current
  shape, applied at `bin/linear.sh:547-550`). Stripping the `reapplied`
  footer leaves the marker shape untouched in both. The two normalised
  bodies will differ by the marker shape itself → comparison says "not
  identical" → no footer → caller's body posted (an in-place migration to
  the new marker shape, which is the intended ENG-60 behaviour). No
  regression.
- **Caller passes a body already containing a `meta: reapplied` line.**
  Unexpected (no caller does this today). Decision: tolerate. The strip
  applies symmetrically; caller's footer is treated as a no-op. The body
  equality check then proceeds on the residue. If equal, we rewrite a
  fresh footer (replacing caller's). If unequal, caller's footer rides
  along and gets stripped on the next re-apply.
- **Comment body field missing/null in fetched payload.** The `// ""`
  fallback in §3.2's jq selector handles this — `existing_norm` becomes
  empty, never matches a non-empty new body, no footer emitted, normal
  `commentUpdate` path runs.
- **Body containing literal `<!-- meta: reapplied at=… -->` inside a
  fenced code block** (e.g., a stage-summary that quotes a prior
  re-apply). The strip regex is `^<!-- meta: reapplied at=[^>]* -->$`
  with explicit `^...$` line anchors (D-002, §3.2). A code-block-quoted
  line indented with leading spaces, prefixed with `> `, or surrounded
  by other characters will NOT begin and end with the literal marker
  shape and is left intact. Without the anchors, the un-anchored form
  WOULD silently strip such a line — caught in design persona review,
  regex tightened.
- **Re-apply at the exact same UTC second.** Two re-applies separated by
  sub-second intervals would produce identical timestamps → second
  re-apply's normalised body would match first's normalised body → footer
  rewritten with the same timestamp → body byte-equal to existing →
  Linear short-circuits → bug re-emerges. Practical exposure: zero. The
  harness tick is every 5 minutes; same-stage re-applies within the same
  SECOND are effectively impossible (each Linear roundtrip alone takes
  >100ms). Documented; no defensive code.
- **Test fixture with a stub `linear_query` returning incomplete JSON.**
  The stub MUST return a JSON shape compatible with `bin/linear.sh:562`'s
  query schema — `{data:{issue:{comments:{nodes:[{id,body},…]}}}}`. None
  of today's tests stub `linear_query` for the GraphQL path of
  `add_or_update_comment` (only for the dry-run path, which
  short-circuits before the query); D-006 is therefore the only place
  the new schema requirement matters, and the new fixtures define stubs
  that include `body`.

## 7. Persona review

Run during this session per the brainstorming stage's persona-review
contract. Six personas dispatched against the iter-1 draft.

| Persona | Verdict | P0 | P1/P2 themes addressed in iter-2 |
|---|---|---|---|
| design | PASS | 0 | Regex divergence between D-002 and §3.2 → both canonicalised to `^…$` anchors. |
| security | PASS | 0 | Strip-regex anchoring tightened. `jq --arg` json-encoding noted (no injection risk via footer interpolation). Pre-existing lane-fence asymmetry on `add_or_update_comment` flagged for follow-up but out of scope. |
| scope | PASS | 0 | No creep blockers. AC #1, #3, #4 covered; AC #2 (Approach B) cleanly rejected with rationale. |
| coherence | PASS | 0 | Mis-attribution of `// ""` fallback corrected. Assumption inventory verified against current code. |
| product | PASS | 0 | Web-UI visibility caveat made explicit in D-001 rationale. Operator decision tree added to D-007 §4. Metric emission promoted from open question to D-009 to close the retrospective-observability gap. |
| feasibility (gating) | PASS | 0 | All codebase-fact checks passed against the current worktree. `meta_kinds` registry already present; `bin/generate-vocabulary-doc.sh` already iterates it; macOS BSD `date`/`sed` compatibility confirmed; jq selector valid against the `{id body}` query payload. |

**Gate:** 6/6 PASS, 0 P0 in feasibility. Threshold (≥5/6 PASS AND
feasibility P0=0) cleanly satisfied.

## 8. Anti-bias checks

### 8.1 ADR stress test

- **One canonical comment per logical event** (ENG-60 vocabulary
  closure). D-001 preserves it (one comment per sig, just with a visible
  re-apply footer). Approach B rejected partly because it weakens this
  invariant. NO stress.
- **Closed `pipeline:` and `meta:` token registry**
  (`bin/pipeline-events.json` per ENG-60). D-005 honours the registry —
  `reapplied` added there, not as ad-hoc shape. NO stress.
- **Lane-fence write enforcement** (ENG-41). D-005 verifies the footer
  rides through the existing `commentUpdate` already lane-permitted for
  the original comment's lane. NO stress.
- **Linear comments are append-only** (`docs/runbooks/recovery.md:99-101`).
  The fix LEANS ON this constraint as the reason to prefer Approach A
  over Approach B. REINFORCES.

No existing decision is destabilised.

### 8.2 Simpler alternatives

Inline under each decision's "Rejected" blocks. Summary:

- D-001 rejected: Approach B; skip identical-update API call;
  whitespace-only edits; visible non-HTML footer.
- D-002 rejected: reuse `add_comment`'s broad scrub; un-anchored strip.
- D-003 rejected: counter footer; stacked footers.
- D-006 rejected: separate test file; tests in `verdict-handler-test.sh`.
- D-007 rejected: new operator-runbook file (none exists today).
- D-008 rejected: extracted `_strip_reapplied_footer`.
- D-009 rejected: emit metric from each caller.

### 8.3 Assumption inventory

| # | Assumption | Status | Verification |
|---|---|---|---|
| A-001 | `add_or_update_comment` is at `bin/linear.sh:529-582`; existing-id lookup at `:562-567`; commentUpdate at `:570-573`; commentCreate at `:576-580`. | verified | `Read bin/linear.sh:529-582` (this session). |
| A-002 | `_vh_protocol_violation` calls `add-or-update-comment` with sig `protocol-violation/$case_id/$issue` at `bin/verdict-handler.sh:52-60`. | verified | `Read bin/verdict-handler.sh:52-60`. |
| A-003 | `classify-failure.sh` calls `add-or-update-comment` with sig `halt/$stage/$issue` at `bin/classify-failure.sh:146`. | verified | `Read bin/classify-failure.sh:125-160`. |
| A-004 | `run-stage.sh::post_completion_comment` calls `add-or-update-comment` with sig `completion/$stage/$issue` at `bin/run-stage.sh:212,216`. | verified | `Read bin/run-stage.sh:200-220`. |
| A-005 | Linear's `commentUpdate` short-circuits identical-body updates such that `updatedAt` does not advance and the operator sees only `createdAt`. | assumed | Empirical observation from the [ENG-58](https://linear.app/twinning/issue/ENG-58/) incident reported in the issue body. Not independently re-tested. The fix is robust either way: even if `updatedAt` does move on identical updates, the footer addition still gives an operator-visible cue, which is the actual bug surface. |
| A-006 | `bin/pipeline-events.json` is the source of truth for both `pipeline:` events and `meta:` kinds; `meta_kinds` already exists as a top-level array (currently `["dedup","metric","evidence"]`); D-005 is a one-element append. | verified | `Bash cat bin/pipeline-events.json` shows `meta_kinds` array at lines 42-46. |
| A-007 | `bin/generate-vocabulary-doc.sh` exists and iterates `meta_kinds` so the registry append automatically surfaces in `docs/pipeline-vocabulary.md`. | verified | `Grep "meta_kinds" bin/generate-vocabulary-doc.sh` matches at line 14. |
| A-008 | `bin/linear-test.sh` already exercises `add_or_update_comment` (lines 493-510) and uses the source-and-stub pattern with `PIPELINE_DRY_RUN=1`. | verified | `Read bin/linear-test.sh:1-92,493-510`. |
| A-009 | `docs/runbooks/recovery.md` exists and covers three "stuck" recovery modes today (§§1-3). | verified | `Read docs/runbooks/recovery.md:1-110`. |
| A-010 | `bin/halt.sh` no longer exists; `bin/pipeline.sh decide --action continue` is the current operator command. | verified | `ls bin/halt.sh` returns "No such file or directory"; `Grep "decide\|continue" bin/pipeline.sh` shows entrypoints at lines 7,36,287. |
| A-011 | The `<!-- meta: reapplied at=... -->` shape does not collide with any existing `meta:` kind. | verified | Registry-listed `meta_kinds` are `dedup`, `metric`, `evidence`. `reapplied` is unused. |
| A-012 | The query at `bin/linear.sh:562` returns body in the same payload — no new GraphQL roundtrip needed for D-001. | verified | `Read bin/linear.sh:562` — query is `{ id body }`. |
| A-013 | macOS BSD `date -u +%Y-%m-%dT%H:%M:%SZ` produces a stable iso8601 string; no GNU coreutils dependency. | verified | macOS BSD `date` honours `+` format strings; project profile declares macOS as the runtime. |
| A-014 | `_reject_legacy_marker_body` (`bin/linear.sh`) does not reject bodies carrying `<!-- meta: reapplied … -->`. | verified | The reject helper guards against `pipeline-sig:` and a few other legacy shapes (per the linear-test fixture context); `meta: reapplied` is a NEW shape under the current `meta:` namespace, not a legacy one. |
| A-015 | `bin/metrics.sh` signature is `<event> <issue_id> <stage> <outcome> <duration_ms> [notes…]` and accepts arbitrary event names per the closure of `[[ -n "$event" && -n "$outcome" ]]` validation. Stage may be any non-empty token (no enum-check). | verified | `Read bin/metrics.sh:1-50`. D-009 invocation passes `-` for stage and rides the sig in notes (verified shape). |

A-005 is the only assumed item. The fix degrades gracefully if A-005 is
wrong (the operator-visible footer is the actual signal, not the
`updatedAt` move).

## 9. Open questions

- **Q-001.** Should the footer also include a re-apply COUNTER, e.g.,
  `<!-- meta: reapplied count=3 at=2026-05-04T10:00:00Z -->`? Pro:
  immediate "this halt fired N times" signal at a glance. Con: scope
  creep (issue's Approach A specifies timestamp only); requires
  extracting an existing count from the prior footer. Recommendation:
  implement only if operators report timestamp alone is insufficient.
- **Q-002.** Modernise `docs/runbooks/recovery.md` §3 to reference
  `bash bin/pipeline.sh decide ENG-N --action continue` instead of the
  retired `bin/halt.sh resolve ENG-N --decision resume`. The §3 stale
  references are an unrelated regression from the ENG-58/ENG-60
  refactor. Out of scope for ENG-63; flag as a separate cleanup ticket.
- **Q-003.** Should `bin/pipeline.sh decide --action continue` emit a
  per-issue summary of how many re-applies the most recent halt comment
  carries when the operator resolves a halt? Information now available
  in the comment-body footer (and in `comment-reapplied` metric stream
  from D-009); surfacing at resolution time would close the loop. Out
  of scope; flagged for follow-up.

## 10. Scope flags

Nothing in this brainstorm exceeds the issue's acceptance criteria:

- **AC #1 (Approach A footer)** → D-001, D-002, D-003, D-004, D-008, §3.2.
- **AC #2 (Approach B sig split)** → explicitly rejected with rationale
  in D-001.
- **AC #3 (test fixture asserting body change)** → D-006 (C-001/C-002/C-003).
- **AC #4 (operator runbook update)** → D-007, §3.1.

The `bin/pipeline-events.json` registry update (D-005) is an
acceptance-criteria-implicit ENG-60 requirement: any new `meta:` marker
emitted by harness code MUST be in the closed registry per the ENG-60
vocabulary discipline. Not scope expansion; the price of admission for
the new footer.

The `CLAUDE.md` Failure-mode quick reference table touch-up (D-007
addendum) is a one-line documentation update that the operator runbook
§4 cross-references. Trivial; included for navigability.

The `comment-reapplied` metric emission (D-009) is a one-line additive
observability hook that closes the iter-1 product persona's
retrospective-blindness gap. Operator-facing observability is the bug
class ENG-63 targets, so I'm including it; if a reviewer judges this
as scope creep, remove the `metrics.sh` line and demote to Q-004.

## 11. Conflicts with existing architecture

None identified.

The dedup contract, the lane fence, the closed vocabulary, and the
single-canonical-comment-per-sig invariant are all preserved. The fix is
a strict information ADD: the same comment now carries one extra line of
operator-readable provenance under the documented `meta:` namespace,
plus a hook into the existing metrics stream.
