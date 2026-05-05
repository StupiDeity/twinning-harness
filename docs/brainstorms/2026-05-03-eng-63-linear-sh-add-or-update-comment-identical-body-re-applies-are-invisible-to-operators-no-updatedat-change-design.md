---
linear: ENG-63
title: linear.sh add-or-update-comment — identical-body re-applies must be operator-visible
date: 2026-05-03
status: draft
---

# linear.sh `add-or-update-comment` — identical-body re-applies must be operator-visible

## 1. Problem

`bin/linear.sh::add_or_update_comment` (`bin/linear.sh:529-582`)
deduplicates posts by a per-sig HTML marker. When a caller re-applies
the same sig with a body that is byte-identical to the existing
in-Linear comment, the function calls `commentUpdate`
(`bin/linear.sh:570-573`) with that identical body. Linear's API
short-circuits no-op updates: `createdAt` stays at the original
emission and `updatedAt` does not move. The thread therefore presents
to the operator as if the halt fired exactly once, at the first
timestamp.

The acute incident — [ENG-58](https://linear.app/twinning/issue/ENG-58/)
— hit `_vh_protocol_violation` (`bin/verdict-handler.sh:52-60`) three
times across brainstorm (08:39:08Z), plan (12:13:18Z), and implement
(13:36:01Z). All three calls used sig `protocol-violation/no-marker/ENG-58`.
The plan and implement halts re-posted the same body. Linear showed
ONE comment, dated 08:39:08Z, with `updatedAt: null`. Two operator
"resume" cycles ran against an issue whose `pipeline:halted` was being
silently re-asserted within seconds of each clear, and the operator
spent ~30 minutes concluding the resume command was broken before
realising the comment thread itself was lying.

The bug is not specific to `_vh_protocol_violation`. Every caller of
`add_or_update_comment` is exposed to the same invisibility. Today's
caller set is:

| Caller | Sig shape | Re-apply scenario |
|---|---|---|
| `bin/verdict-handler.sh:56-57` | `protocol-violation/<case_id>/<issue>` | Same case_id (`no-marker`, `stage-mismatch`, `unknown-loopback`) firing on a later stage produces an identical body. |
| `bin/classify-failure.sh:146` | `halt/<stage>/<issue>` | Same stage halting twice with same exit code, subcode, retry_count, branch, and content hash → identical body. Common on retry-immediately churn. |
| `bin/run-stage.sh:212,216` | `completion/<stage>/<issue>` | Re-dispatched stages whose agent emits a deterministic stage-summary (e.g., a fresh tick on an unchanged worktree) produce identical bodies. |

Identical-body re-apply is the hot path, not an edge case.

## 2. Decisions

- **D-001. Detect "no-op update" inside `add_or_update_comment` and
  rewrite the body to include a `<!-- meta: reapplied at=<ts> -->`
  footer line so the byte-level update is non-trivial.**

  After the existing-comment lookup at `bin/linear.sh:562-567`
  succeeds, normalize both the existing body and the new body by
  stripping any `<!-- meta: reapplied at=... -->` line, then byte-equal
  compare. If equal, append a fresh footer line to the new body
  (replacing the prior footer, if any) before calling `commentUpdate`.
  If unequal, post the new body as-is.

  Resulting flows:
  - First post: no existing comment → `commentCreate` with the body
    plus its dedup marker. No footer.
  - Body genuinely changes (e.g., new exit code in classify-failure
    halt body, new retry_count): `commentUpdate` with the new body.
    No footer.
  - Body is identical to existing (the bug case): `commentUpdate` with
    `<existing>\n<!-- meta: reapplied at=<iso8601-utc> -->`. The body
    byte-changes, Linear's `updatedAt` advances, the operator sees a
    new footer line dated NOW.

  *Why:* this is the issue's preferred Approach A. It is the smallest
  surgical change that closes the visibility gap without touching
  caller surfaces, sig naming, or the dedup contract. The `meta:`
  marker family is already the documented bookkeeping namespace
  (`docs/pipeline-vocabulary.md:1-9` — "`<!-- meta: <kind> ... -->`
  bookkeeping (dedup keys, metric counters, evidence bundles)").
  `reapplied` is a new `kind` in that family but governed by the same
  closed-vocabulary discipline (D-005).

  Rejected alternative — Approach B (split protocol-violation sig by
  stage to `protocol-violation/<case_id>/<stage>/<issue>`): rejected
  on three grounds. (a) The bug surface is broader than
  `_vh_protocol_violation`: classify-failure and post_completion_comment
  re-applies hit the same invisibility (table in §1). Approach B fixes
  one caller; Approach A fixes the function. (b) Linear has no
  comment-delete primitive (`docs/runbooks/recovery.md:99-102` —
  "Linear comments are append-only at the issue level — the API does
  not support comment deletion for historical audit reasons"); each
  per-stage protocol-violation comment becomes permanent thread
  litter, exactly the failure mode the prompt sweep guards against
  (`CLAUDE.md` — "probe comments become permanent thread litter").
  (c) The dedup intent — one canonical comment per logical event — is
  a deliberate design property; multiplying it by the stage axis
  weakens the invariant for marginal value (the per-stage `createdAt`
  could already be reconstructed from the metrics jsonl).

  Rejected alternative — skip the `commentUpdate` API call entirely
  when the body is identical: rejected because it is the OPPOSITE of
  what the operator needs. Today the call already silently no-ops at
  Linear's edge; skipping the call ourselves achieves the same
  invisibility with less network traffic. The operator complaint is
  precisely "I cannot see that the halt re-fired." A non-call cannot
  produce that signal.

  Rejected alternative — bump a hidden whitespace character to force
  Linear to update `updatedAt`: rejected because the change must be
  observable to the operator. Web-UI visibility caveat (raised by
  iter-1 product persona, A-006-adjacent): the footer is an HTML
  comment, which Linear's web UI hides in the rendered view. The
  operator-visible cue is therefore the comment's "(edited)"
  indicator — Linear DOES surface this in the web UI when
  `updatedAt > createdAt`. The footer line is observable to anyone
  who views raw markdown (via Linear's "edit" or "view source"
  affordance, or via `bash bin/linear.sh get-comments ENG-N`); it
  carries the timestamp evidence. Whitespace-only edits would move
  `updatedAt` (giving the "(edited)" indicator) but leave NO
  inspectable evidence of when the re-apply occurred. The footer
  gives both signals.

  Rejected alternative — emit a visible (non-HTML-comment) footer
  like `_re-applied: <ts>_`: rejected because operators reading the
  comment body in Linear's web UI would see editorial markup mixed
  with the actual halt content, and the line would survive into
  exported issue snapshots, retrospectives, and any downstream
  rendering (Slack notifications, etc.). The hidden HTML comment
  + "(edited)" indicator is the right asymmetry: visible to
  operators inspecting the situation, invisible to passive readers.

- **D-002. Comparison ignores ONLY the `<!-- meta: reapplied at=... -->`
  line. No timestamp/SHA normalization beyond that.**

  The comparison strips lines matching the LINE-ANCHORED regex
  `^<!-- meta: reapplied at=[^>]* -->$` from both sides before
  byte-equal. The `^...$` anchors are load-bearing — they prevent the
  strip from deleting code-block-quoted prose that happens to mention
  the marker shape (see §6 "Body containing literal …" edge case).
  Anything else — timestamps inside the body, git SHAs, retry
  counters, branch names — counts as a meaningful change and skips
  the footer.

  *Why:* `add_comment`'s broader timestamp/SHA scrub
  (`bin/linear.sh:486-491`) exists for a different purpose:
  cross-comment dedup (avoiding posting a brand-new duplicate when the
  only difference is a timestamp). Our case is comparing existing-vs-new
  for THIS exact comment's update path. The scope of "meaningful change"
  is wider here — an exit code that changed from 47 to 12 IS a
  meaningful update even though both are short numeric tokens. Narrow
  normalization keeps the footer focused on the literal "this body
  was already in Linear" case.

  Rejected alternative: reuse `add_comment`'s timestamp+SHA scrub
  (`bin/linear.sh:486-491`). Rejected because (a) it would mask
  meaningful retry-count or hash changes in classify-failure halt
  bodies (every classify-failure body carries `pipeline_content_hash`
  and `branch_head_sha` fields — `bin/classify-failure.sh:144` — so
  every legitimate retry would normalize to "same body" and get a
  footer instead of the real updated body); (b) the scrub is the
  wrong abstraction for the update path — it was designed for the
  add-comment dedup-rejection path where a near-duplicate should be
  suppressed entirely, not transformed.

- **D-003. The footer is appended to the body BEFORE `commentUpdate`,
  so the next read by `add_or_update_comment` sees it on the
  existing-body side and can strip it under D-002.**

  Concretely, the existing body fetched in
  `bin/linear.sh:562-567` already carries the prior footer (if any);
  the comparison strips it; on identity the function rewrites a fresh
  footer at the bottom of the new body (NOT appending in addition to
  any existing footer in the new body — there is none, since callers
  do not synthesize `meta: reapplied`).

  *Why:* this keeps the footer count at exactly one per comment over
  any number of re-applies. The N-th re-apply rewrites the timestamp
  to the N-th moment. Operators looking at the comment see "first
  emitted at <createdAt>, last re-applied at <footer ts>" — two
  data points telling the full story.

  Rejected alternative: append a counter `<!-- meta: reapplied count=N
  at=<ts> -->`. Tempting but out of scope — the issue's Approach A
  text specifies a timestamp footer only, no counter. The counter is
  flagged as Open Question Q-001 for a follow-up.

  Rejected alternative: keep all prior footers as a stack. Rejected
  because each re-apply would extend the body by one line; over many
  re-applies the comment becomes unreadable. Single-rotating footer
  is the minimum viable signal.

- **D-004. The footer is added on the UPDATE path only, never on the
  CREATE path.**

  The `commentCreate` branch (`bin/linear.sh:576-580`) skips the
  footer entirely. A first emission has no "re-application" to
  signal; the comment's own `createdAt` carries that information.

  *Why:* clarity. The footer's semantic is "this body was previously
  posted under this sig and re-applied at <ts>." Putting it on a
  create call would be misleading.

- **D-005. The new marker `<!-- meta: reapplied at=<iso8601-utc> -->`
  joins the closed `meta:` vocabulary registry.**

  `bin/pipeline-events.json` is the source of truth for both
  `pipeline:` and `meta:` token sets (`docs/pipeline-vocabulary.md:33-36`
  — "Source: `bin/pipeline-events.json` — edit there, not here").
  Adding `reapplied` as a `meta_kinds` entry, with `at` as its
  attribute, keeps the vocabulary discipline intact and surfaces the
  marker in `docs/pipeline-vocabulary.md` (regenerated by
  `bin/generate-vocabulary-doc.sh`).

  Lane fence verification: the body containing the footer goes
  through `add_or_update_comment` → `commentUpdate`. The lane check
  in `add_comment` (`bin/linear.sh:476-479`) is NOT reached by the
  update path — `add_or_update_comment` does not call `_check_lane`
  in its current form. The footer therefore inherits whatever lane
  the original comment was posted under (no new lane consideration).

  Rejected alternative: introduce a free-form, non-registered marker
  shape. Rejected because the entire point of the ENG-60 vocabulary
  closure was to prevent ad-hoc markers from accumulating. The
  footer is operator-facing observability infrastructure; it gets
  the same registry treatment as every other operator-facing token.

- **D-006. Test fixture lives in `bin/linear-test.sh`, not in a new
  test file.**

  Three new test cases, added at the bottom of the existing
  `add_or_update_comment` test block (`bin/linear-test.sh:493-510`):
  1. **C-001** Identical-body re-apply emits a footer. Stub
     `linear_query` to return an existing comment with body B,
     re-call `add_or_update_comment` with body B in non-dry-run, assert
     the captured commentUpdate body matches `B + footer`.
  2. **C-002** Different-body re-apply omits the footer. Stub
     existing body B, re-call with body B'≠B, assert the captured
     commentUpdate body equals B' (no footer).
  3. **C-003** Repeated identical-body re-apply rotates the footer
     (does not stack). Stub existing body `B + footer1`, re-call
     with body B, assert the captured commentUpdate body is
     `B + footer2` where footer2's timestamp differs from footer1's
     and exactly one footer line is present.

  *Why this file:* `bin/linear-test.sh` already sources `linear.sh`
  with `PIPELINE_DRY_RUN=1` and exercises `add_or_update_comment`'s
  body-arg shapes. The pre-existing harness scaffolding (lines
  18-92) gives us `pass_at`/`fail_at`, the temp `TARGET_REPO`
  scaffold, and the linear-ids stub.

  *Why a stub for `linear_query`:* the existing tests run only the
  dry-run path (`bin/linear.sh:553-556`), which short-circuits
  before any GraphQL is fetched. To exercise the
  existing-body-comparison branch we need to (a) bypass the
  dry-run guard for these specific cases, and (b) inject a
  controlled GraphQL response. Override `linear_query` at the
  top-level after sourcing — the function is global once sourced,
  so re-defining it per test gives us deterministic responses.
  Also flip `PIPELINE_DRY_RUN=0` for the duration of these three
  cases (and back to 1 afterwards to leave the rest of the file's
  invariants intact).

  Rejected alternative: a new file `bin/linear-reapply-test.sh`.
  Rejected because the test scaffolding overlap is ~80 lines that
  would be duplicated, and the suite already groups
  `add_or_update_comment` cases together.

  Rejected alternative: add the test to `bin/verdict-handler-test.sh`
  (the load-bearing protocol-violation caller). Rejected because the
  bug is in `linear.sh`, not `verdict-handler.sh`. The verdict
  handler's correctness does not depend on whether the comment was
  re-posted with a footer — that's a Linear-presentation property,
  observable only via the linear.sh code path.

- **D-007. Operator-runbook update goes into `docs/runbooks/recovery.md`,
  not into a new file. Includes a one-line decision tree.**

  Add a §4 titled "Halted issue with stale-looking halt comment
  timestamp." Required body content:
  1. **Symptom:** Linear shows `pipeline:halted` applied recently
     but the most-recent halt comment is dated to an earlier
     occurrence (and shows no "(edited)" indicator, OR shows one
     but the `createdAt` looks stale).
  2. **Authoritative signal:** the `pipeline:halted` LABEL is the
     state of record. Comment `createdAt` reflects only the first
     emission of any given halt body; subsequent identical re-applies
     update the existing comment in place.
  3. **Recency evidence:** inspect the comment body via
     `bash bin/linear.sh get-comments ENG-N | jq -r '.[-5:][] | .body'`
     and look for a `<!-- meta: reapplied at=<ts> -->` footer line.
     If present, the timestamp shown is the most recent
     re-application moment (not the original `createdAt`).
  4. **Operator decision tree** (one line each):
     - footer present AND timestamp is recent (within last hour) →
       the halt is FRESH; investigate the halt's `reason=` token
       for cause; do NOT just re-run `decide --action continue`.
     - footer present BUT timestamp is old → halt has not re-fired
       since; safe to investigate at leisure or
       `decide --action continue` if cause was external.
     - footer absent → halt has only ever been emitted once at
       `createdAt`; treat per existing §3 guidance.

  *Why this file:* `docs/runbooks/recovery.md:8` already advertises
  itself as the "Quick reference for fixing issues stuck in three
  modes." Adding the fourth mode here is the path of least surprise.
  No `docs/operator-runbook.md` exists today (verified by
  `ls docs/`: brainstorms, plans, runbooks, pipeline-vocabulary.md
  and template).

  *Plus:* update `CLAUDE.md`'s "Failure-mode quick reference" table
  row "Issue stuck in `stage:X`" to add a parenthetical: "comment
  `createdAt` reflects FIRST emission only; check the
  `<!-- meta: reapplied at=... -->` footer for the latest moment."

  *Note on stale `bin/halt.sh` references in the existing runbook:*
  `docs/runbooks/recovery.md` still references `bash bin/halt.sh
  resolve ENG-N --decision resume` in §3, but per CLAUDE.md the
  current operator command is `bash bin/pipeline.sh decide ENG-N
  --action continue`. The new §4 uses the current command shape;
  modernizing §3's references is OUT OF SCOPE for ENG-63 (flagged
  as a cleanup follow-up) — ENG-63's narrow scope is the new mode.

- **D-009. Emit a `comment-reapplied` metric event on every footer
  rewrite, so the retrospective agent can detect re-apply churn
  without operator pattern-matching.**

  Inside the identical-body branch (D-001), after the footer is
  rewritten and BEFORE `commentUpdate`, fire:
  ```bash
  bash "$SCRIPT_DIR/metrics.sh" comment-reapplied "$ident" "$sig" \
    "reapplied" 0 "comment_id=$existing_id" || true
  ```
  Failure of the metric write does not fail the comment update
  (`|| true`).

  *Why (closes the iter-1 product persona P1 — observability gap):*
  the retrospective agent (`bin/run-retrospective-local.sh`) consumes
  `events.jsonl` (`bin/metrics.sh`-managed). Without this emission, a
  pattern of "halt re-fires N times silently" remains invisible to
  the retrospective: it sees one halt comment, no churn signal. With
  the emission, the retrospective can flag issues whose
  `comment-reapplied` count for the same sig exceeds a threshold
  (e.g., ≥3 within a tick window) as "halt-loop suspect" — exactly
  the regression class ENG-63 is hardening against.

  This is purely additive (one `metrics.sh` call); no schema
  migration, no caller-facing API change. The `metrics.sh` event
  taxonomy already accepts arbitrary event names per the `stage-end`
  / `halt-resume` precedent.

  Rejected alternative — emit the metric from each caller
  (verdict-handler, classify-failure, post_completion_comment)
  rather than from `add_or_update_comment`: rejected because (a) it
  forces every existing and future caller to remember to emit the
  metric, recreating the original "easy to overlook" failure mode
  in a different shape; (b) the determination of "this was an
  identical-body re-apply" requires reading the existing comment,
  which is `add_or_update_comment`'s job — pushing the metric
  upstream would force callers to re-implement that fetch.

- **D-008. The comparison and footer rewrite happen inline in
  `add_or_update_comment`, not in a new helper.**

  Approximately 14 lines of bash inserted between
  `bin/linear.sh:567` (existing_id resolution) and `bin/linear.sh:569`
  (the existing_id branch). No new top-level function, no new
  `_resolve_*` helper.

  *Why:* the logic is small enough that extraction adds indirection
  without modularity payoff. The function is currently 54 lines
  (`bin/linear.sh:529-582`); adding 14 more keeps it under 70 lines
  — comfortable for a single-page read. Future test cases can call
  `add_or_update_comment` directly without setting up helper-call
  fixtures.

  Rejected alternative: extract a `_strip_reapplied_footer` helper.
  Rejected because the regex is one line and used twice in adjacent
  code; inline is more readable than indirection here. If a third
  caller needs the strip, hoist then.

## 3. Architecture

### 3.1 Files modified

| File | Change |
|---|---|
| `bin/linear.sh` | Insert ~14 lines into `add_or_update_comment` between existing_id resolution and the existing_id update branch (D-001, D-002, D-003, D-004, D-008). Plus one `metrics.sh comment-reapplied` call (D-009). |
| `bin/pipeline-events.json` | Add `reapplied` to the `meta_kinds` array (currently `[dedup, metric, evidence]`) with attribute `at` (D-005). |
| `bin/linear-test.sh` | Add three new test cases C-001/C-002/C-003 plus the `linear_query` stub override and PIPELINE_DRY_RUN flip (D-006). One additional case C-004 asserting `metrics.sh comment-reapplied` is invoked exactly once on the identical-body branch (D-009). |
| `docs/runbooks/recovery.md` | Add §4 "Halted issue with stale-looking halt comment timestamp" with the four-step body and decision tree (D-007). |
| `CLAUDE.md` | Update "Failure-mode quick reference" row to point at the footer (D-007). |
| `docs/pipeline-vocabulary.md` | Auto-regenerated by `bin/generate-vocabulary-doc.sh` from the updated registry (D-005). |

No changes to `bin/verdict-handler.sh`, `bin/classify-failure.sh`,
`bin/run-stage.sh`, `bin/halt.sh`, `bin/poll.sh`, `bin/scope-check.sh`,
or any other caller. The fix is fully contained in `linear.sh`'s
update path; callers continue to pass identical bodies as they do
today and observe the new visibility property as a side effect.

### 3.2 Pseudocode for the `add_or_update_comment` change

```bash
# … existing code through bin/linear.sh:567 (existing_id resolution) …

if [[ -n "$existing_id" ]]; then
  # NEW: detect identical-body update and append a re-applied footer.
  # Compare existing body vs new body, both with any prior
  # `<!-- meta: reapplied at=… -->` line stripped. Regex is LINE-ANCHORED
  # via `^...$` so quoted prose can't be silently dropped (see §6).
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
  fi

  local mu='mutation($id: String!, $body: String!) { commentUpdate(id: $id, input: { body: $body }) { success } }'
  # … unchanged from bin/linear.sh:570-573 …
fi
```

### 3.3 GraphQL impact

One additional `jq` parse over the already-fetched response (`$resp`,
`bin/linear.sh:565`) — no new GraphQL roundtrips. The existing query
(`bin/linear.sh:562`) already returns `{id, body}` for up to 50
comments; we now use the body field that was previously discarded.

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
        │    │
        │    ├─ NEW: extract existing_body from $resp by id
        │    │
        │    ├─ NEW: strip <!-- meta: reapplied at=... --> from both
        │    │       existing_body and body
        │    │
        │    ├─ NEW: if normalized bodies are byte-equal:
        │    │         body := normalized_body + "\n<!-- meta: reapplied at=<now> -->"
        │    │
        │    └─ commentUpdate(id=existing_id, body=body)
        │       (unchanged endpoint — :570-573)
        │
        └─ else:
             commentCreate(issueId=uuid, body=body)
             (unchanged — :576-580)
```

## 5. Error handling

- `jq` extraction failure (existing_body parse): if `jq` returns
  empty or errors, treat as "existing_body unknown" → skip the
  comparison, fall through to a normal `commentUpdate` with the
  caller's body. This is functionally equivalent to today's behavior
  on the comparison-failure path (the bug remains unfixed for that
  rare case but no new failure is introduced).
- `date -u` failure: this is a builtin under `coreutils`/macOS BSD
  date; both honor `+%Y-%m-%dT%H:%M:%SZ`. If for some reason `date`
  returns empty, the footer becomes `<!-- meta: reapplied at= -->`
  — still a body change, still moves `updatedAt`, just less
  informative. No additional defensive coding required.
- `commentUpdate` failure: unchanged behavior. The function does not
  retry; the caller (e.g., `bin/run-stage.sh:212-216`) handles its
  own one-shot retry.

## 6. Edge cases

- **First-ever post (no existing_id):** D-004 — no footer.
  `commentCreate` runs with the unmodified body. `createdAt` carries
  the first-emission timestamp.

- **Mixed legacy/new dedup marker shapes:** body fetched from Linear
  may carry `<!-- pipeline-sig: <sig> -->` (legacy ENG-60 predecessor),
  while caller-supplied body carries `<!-- meta: dedup key=<sig> -->`
  (current). Stripping the `reapplied` footer leaves the marker shape
  untouched in both. The two normalized bodies will differ by the
  marker shape itself → comparison says "not identical" → no footer
  → caller's body posted (an in-place migration to the new marker
  shape, which is the intended ENG-60 behavior). No regression.

- **Caller passes a body that already contains a `meta: reapplied`
  line:** unexpected (no caller does this today; defensible to die
  on it). Decision: tolerate. The strip applies symmetrically to both
  sides; the caller's footer is treated as a no-op. The body equality
  check then proceeds on the residue. If equal, we rewrite a fresh
  footer (replacing the caller's). If unequal, the caller's footer
  rides along (and gets stripped on the next re-apply).

- **Comment fetched but body field missing/null:** the `// ""`
  fallback in the §3.2 `jq` selector handles this — `existing_norm`
  becomes empty, never matches a non-empty new body, no footer
  emitted, normal `commentUpdate` path runs.

- **Body containing literal `<!-- meta: reapplied at=… -->` inside a
  fenced code block (e.g., a stage-summary that quotes a prior
  re-apply):** the strip regex is `^<!-- meta: reapplied at=[^>]* -->$`
  with explicit `^...$` anchors (D-002, §3.2). A code-block-quoted
  line indented with leading spaces, prefixed with `> ` quote markup,
  or surrounded by other characters will NOT begin and end with the
  literal marker shape and is left intact. Without the anchors, the
  un-anchored `/<!-- meta: reapplied … -->/d` form WOULD silently
  strip such a line — that was caught in iter-1 design persona
  review and the regex was tightened to the anchored form. False
  strips of legitimately-quoted content are therefore impossible
  under the current regex.

- **Re-apply at the exact same UTC second:** two re-applies separated
  by sub-second intervals would produce identical timestamps → the
  second re-apply's normalized body would match the first's
  normalized body (both have the same footer text after strip) →
  footer rewritten with the same timestamp → body byte-equal to
  the existing body → Linear short-circuits the update → bug
  re-emerges. Practical exposure: zero. The harness tick is every
  5 minutes; classify-failure / verdict-handler invocations within
  the same 5-min tick are extremely rare, and within the same SECOND
  effectively impossible (each Linear roundtrip alone takes >100ms).
  Documented edge case; no defensive code.

- **`add-or-update-comment` invoked from a test fixture with a stub
  `linear_query`:** the stub must return a JSON shape compatible
  with `bin/linear.sh:562`'s query schema — `{data: {issue: {comments:
  {nodes: [{id, body}, ...]}}}}`. Any stub that returned only
  `{id}` (no body field) would break the new `existing_body`
  extraction. None of the existing tests use such a stub today
  (verified: no existing `bin/*-test.sh` mocks `linear_query` for
  `add_or_update_comment`'s GraphQL path — only for the dry-run
  path, which short-circuits before the query); D-006 is therefore
  the only place the new schema requirement matters, and the new
  fixtures define stubs that include `body`.

## 7. Persona review

Run during this session per the brainstorming stage's persona-review
contract. All six personas were dispatched in parallel against the
iter-1 draft.

| Persona | Verdict | P0 | P1 / P2 themes addressed in iter-2 |
|---|---|---|---|
| design | PASS | 0 | Regex divergence between D-002 and §3.2 (anchored vs un-anchored) → resolved by canonicalizing both to `^...$` anchors. D-008 line-count refresh (53 → 54). |
| security | PASS | 0 | Strip-regex anchoring tightened; explicit `jq --arg` json-encoding noted (no injection risk via footer interpolation). Pre-existing lane-fence asymmetry on `add_or_update_comment` flagged for follow-up but out of scope. |
| scope | PASS | 0 | No creep blockers. Confirmed AC #1, #3, #4 covered; AC #2 (Approach B) cleanly rejected with rationale (D-001). |
| coherence | PASS | 0 | Mis-attribution of `// ""` jq fallback to D-008 (correct: D-001 territory) → fixed in §5/§6. A-007 stale assumption (`meta_kinds` exists today) → resolved with iter-2 verification. A-011 inventory drift → updated. |
| product | PASS | 0 | Web-UI visibility caveat made explicit in D-001 rationale. Operator decision tree added to D-007 §4. Metric emission promoted from Q-001 to D-009 to close the retrospective-observability gap. |
| feasibility (gating) | PASS | 0 | All 14 codebase-fact checks passed against the actual worktree. `meta_kinds` registry already present; `bin/generate-vocabulary-doc.sh` already iterates it; macOS BSD `date`/`sed` compatibility confirmed; jq selector valid against the existing `{ id body }` query payload. |

**Gate:** 6/6 PASS, 0 P0 in feasibility. Threshold (≥5/6 PASS AND
feasibility P0=0) cleanly satisfied. Iter-2 was a polish-only pass —
no decision-level changes, only sharpening the regex, removing
attribution drift, adding D-009 (metric emission) and the operator
decision tree to D-007.

## 8. Anti-bias checks

### 8.1 ADR stress test

Existing decisions this brainstorm interacts with:

- **One canonical comment per logical event (ENG-60 vocabulary
  closure).** D-001 preserves it (one comment per sig, just with a
  visible re-apply footer). Approach B was rejected partly because it
  weakened this invariant. NO stress on the ADR.
- **Closed `pipeline:` and `meta:` token registry
  (`bin/pipeline-events.json` per ENG-60).** D-005 honors the
  registry — `reapplied` is added there, not as an ad-hoc shape. NO
  stress on the ADR.
- **Lane-fence write enforcement (ENG-41).** D-005 verifies the
  footer rides through the existing `commentUpdate` call which is
  already lane-permitted for the original comment's lane. NO stress.
- **Linear comments are append-only (no delete primitive)**
  (`docs/runbooks/recovery.md:99-102`). The fix LEANS ON this
  constraint as the reason to prefer Approach A over Approach B.
  REINFORCES the ADR.

No existing decision is destabilized.

### 8.2 Simpler alternatives (per decision)

Captured inline under each decision's "Rejected alternative" blocks.
Summary:

- **D-001** rejected: Approach B (split sig by stage); skip the
  identical-update API call entirely; whitespace-only edits;
  visible (non-HTML-comment) footer like `_re-applied: <ts>_`.
- **D-002** rejected: reuse `add_comment`'s broad timestamp/SHA
  scrub for the comparison; un-anchored strip regex.
- **D-003** rejected: counter footer; stacked footers.
- **D-006** rejected: separate test file; tests in
  `verdict-handler-test.sh`.
- **D-007** rejected: new operator-runbook file (none exists today).
- **D-008** rejected: extracted `_strip_reapplied_footer` helper.
- **D-009** rejected: emit metric from each caller rather than
  centrally in `add_or_update_comment`.

### 8.3 Assumption inventory

| # | Assumption | Status | Verification |
|---|---|---|---|
| A-001 | `add_or_update_comment` is at `bin/linear.sh:529-582` and dispatches via `bin/linear.sh:642`. | verified | `Read bin/linear.sh:529-582,640-650` |
| A-002 | `_vh_protocol_violation` calls `add-or-update-comment` with sig `protocol-violation/$case_id/$issue` at `bin/verdict-handler.sh:52-60`. | verified | `Read bin/verdict-handler.sh:52-60` |
| A-003 | `classify-failure.sh` calls `add-or-update-comment` with sig `halt/$stage/$issue` at `bin/classify-failure.sh:146`. | verified | `Read bin/classify-failure.sh:125-150` |
| A-004 | `run-stage.sh::post_completion_comment` calls `add-or-update-comment` with sig `completion/$stage/$issue` at `bin/run-stage.sh:212,216`. | verified | `Read bin/run-stage.sh:145-217` |
| A-005 | The `commentUpdate` mutation is at `bin/linear.sh:570-573`. | verified | `Read bin/linear.sh:570-573` |
| A-006 | Linear's `commentUpdate` short-circuits identical-body updates such that `updatedAt` does not advance and the operator sees only `createdAt`. | assumed | Empirical observation from the [ENG-58](https://linear.app/twinning/issue/ENG-58/) incident in the issue body. Not independently re-tested. The fix is robust either way: even if `updatedAt` does move on identical updates, the footer addition still gives an operator-visible cue, which is the actual bug surface. |
| A-007 | `bin/pipeline-events.json` is the source of truth for both `pipeline:` events and `meta:` kinds; `docs/pipeline-vocabulary.md` is generated from it via `bin/generate-vocabulary-doc.sh`. `meta_kinds` already exists as a top-level array in the registry (currently `[dedup, metric, evidence]`); D-005 is a one-element append. | verified (iter-2) | Confirmed by feasibility persona at `bin/pipeline-events.json:42-46`. The earlier hedge about "may need to be added" is resolved. |
| A-008 | `bin/linear-test.sh` already exercises `add_or_update_comment`'s body-arg shapes (lines 493-510) and uses the source-and-stub pattern. | verified | `Read bin/linear-test.sh:493-510,1-92` |
| A-009 | `docs/runbooks/recovery.md` exists and covers three "stuck" recovery modes today. | verified | `ls docs/runbooks/`; `Grep "stuck" docs/runbooks/recovery.md` |
| A-010 | `_reject_legacy_marker_body` (`bin/linear.sh:403-416`) rejects bodies containing `<!-- pipeline-sig: ... -->` among other legacy shapes. | verified | `Read bin/linear.sh:400-416` |
| A-011 | The `<!-- meta: reapplied at=... -->` shape does not collide with any existing `meta:` kind. | verified | Registry-listed `meta_kinds` are `dedup`, `metric`, `evidence` (`bin/pipeline-events.json:42-46`). `reapplied` is unused. |
| A-012 | `bin/pipeline.sh` (the new event/decide CLI) does not need updating — `meta:` markers are written through `linear.sh`, not `pipeline.sh`. | verified | `Read bin/pipeline.sh` header lines 1-40 and `Grep meta:` in `bin/pipeline.sh` shows zero references. |
| A-013 | The `jq` query in `bin/linear.sh:566-567` returns the comment body in the existing payload (so re-extracting it for D-001 needs no additional GraphQL call). | verified | `Read bin/linear.sh:562` — query is `{ id body }`, both fields fetched. |
| A-014 | macOS `date -u +%Y-%m-%dT%H:%M:%SZ` produces a stable iso8601 string; no GNU coreutils dependency. | verified | macOS BSD `date` honors `+` format strings; project profile already declares macOS as the runtime. |
| A-015 | `bin/generate-vocabulary-doc.sh` exists and regenerates `docs/pipeline-vocabulary.md` from `bin/pipeline-events.json`, including iterating `meta_kinds`. | verified (iter-2) | Confirmed by feasibility persona; the script iterates `meta_kinds` and will pick up the `reapplied` addition automatically. |

Anything marked "assumed" is non-load-bearing for the fix's correctness:
A-006 is the only assumed item, and the fix degrades gracefully if the
assumption is wrong (the operator-visible footer is the actual signal,
not the `updatedAt` move).

## 9. Open questions

- **Q-001.** Should the footer also include a re-apply COUNTER, e.g.,
  `<!-- meta: reapplied count=3 at=2026-05-04T10:00:00Z -->`? Pro:
  immediate "this halt fired N times" signal at a glance. Con: scope
  creep (issue's Approach A specifies timestamp only); requires
  extracting an existing count from the prior footer, which is a few
  more lines of logic. Recommendation for follow-up: implement only
  if operators report the timestamp alone is insufficient.

- **Q-002.** Should `bin/pipeline.sh decide --action continue` emit
  a per-issue summary of how many re-applies the most recent halt
  comment carries when the operator resolves a halt? The information
  is now available in the comment body footer (and in the
  `comment-reapplied` metric stream from D-009); surfacing it to the
  operator at resolution time would close the loop fully. Out of
  scope for this brainstorm; flagged for a follow-up ENG ticket.
  (Note: `bin/halt.sh` was retired in ENG-58/ENG-60 — operators use
  `bin/pipeline.sh decide` exclusively now.)

- **Q-003.** Long-term: should the `meta:` family grow a dedicated
  `last-modified-by-harness` registry that captures the harness
  version + git SHA at re-apply time, not just a timestamp? This
  would let the retrospective agent correlate re-apply patterns
  with code changes. Out of scope; flagged for a follow-up.

## 10. Scope flags

Nothing in this brainstorm exceeds the issue's acceptance criteria.
Every code change maps directly to AC #1 (Approach A), #3 (test
fixture), or #4 (operator runbook). AC #2 (Approach B) is explicitly
rejected with rationale.

The `bin/pipeline-events.json` registry update (D-005) is an
acceptance-criteria-implicit ENG-60 requirement: any new `meta:`
marker emitted by harness code MUST be in the closed registry, per
the ENG-60 vocabulary discipline. This is not scope expansion; it's
the price of admission for the new footer.

The `CLAUDE.md` Failure-mode quick reference table touch-up (D-007
addendum) is a one-line documentation update that the operator
runbook §4 cross-references. Trivial; included for navigability.

## 11. Conflicts with existing architecture

None identified.

The dedup contract, the lane fence, the closed vocabulary, and the
single-canonical-comment-per-sig invariant are all preserved. The
fix is a strict information ADD: the same comment now carries one
extra line of operator-readable provenance under the documented
`meta:` namespace.
