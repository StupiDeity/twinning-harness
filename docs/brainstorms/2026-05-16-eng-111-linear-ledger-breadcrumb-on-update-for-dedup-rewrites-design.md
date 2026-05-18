---
linear: ENG-111
title: Linear ledger — breadcrumb-on-update for dedup rewrites
date: 2026-05-16
status: draft
---

# Linear ledger — breadcrumb-on-update for dedup rewrites

## 1. Overview / Problem

`bin/linear.sh::add_or_update_comment` (`bin/linear.sh:576-671`) is the
sig-deduped writer: every caller that posts a "canonical comment per
logical event" (halt, completion, protocol-violation, scope-approval)
routes through it, and the first emission for a sig calls `commentCreate`
while every subsequent emission for the same sig calls `commentUpdate`
in place. `commentUpdate` preserves the original Linear `createdAt`; the
re-emission is invisible to humans scanning the comment thread
top-down (Linear's web UI groups by `createdAt`, not `updatedAt`).

[ENG-63](2026-05-04-eng-63-linear-sh-add-or-update-comment-identical-body-re-applies-are-invisible-to-operators-no-updatedat-change-design.md)
addressed the **identical-body** sub-case by appending a rotating
`<!-- meta: reapplied at=<iso8601-utc> -->` footer line; that gives an
operator inspecting the canonical comment a recency signal but does NOT
move the comment in the chronological feed. Operators still report the
"the thread is lying" failure mode for **body-change** re-emissions
(e.g., a halt body where `pipeline_content_hash`, `branch_head_sha`, or
`retry_count` change between re-fires): the canonical comment quietly
rewrites in place, the feed shows no fresh comment, and the operator
treats the stale `createdAt` as the truth.

ENG-111 closes the body-change path. The fix: on a genuinely-different
`commentUpdate`, also post a fresh **chronological breadcrumb** — a
sig-less, hash-deduped pointer comment whose `createdAt` is NOW and
whose body refers back to the canonical (updated) comment. Identical-body
re-applies stay silent at the breadcrumb level (ENG-63's footer remains
the canonical signal for that mode).

Acceptance criteria from the issue, mapped to the design below:

| AC | What | Where covered |
|---|---|---|
| #1 | Body-change re-run posts a breadcrumb at the top of the feed | D-001, D-002, §3.2 |
| #2 | Identical-body re-runs are silent (no breadcrumb) | D-001, §3.2 (gate on `is_identical_reapply`) |
| #3 | Tests cover all three paths | D-006 (B-001/B-002/B-003) |

Out of scope (per the ticket): migration of pre-cutover legacy dedup
comments. New emissions only.

## 2. Decisions

### D-001. Inside `add_or_update_comment`, after `commentUpdate` succeeds, post a sig-less breadcrumb comment via `add_comment` when the new body differs from the existing body (post-normalisation).

**Decision.** The function already normalises both bodies (strip
`<!-- meta: reapplied at=… -->` and `<!-- meta: dispatch id=… -->` lines,
trim trailing newline) and byte-compares — see `bin/linear.sh:631-652`.
That comparison drives the existing ENG-63 footer rotation; we extend
it to also drive the breadcrumb. A new local `is_identical_reapply`
flag (0/1) records which branch fired:

- **First emission** (no `existing_id`) → `commentCreate`; no breadcrumb (D-004).
- **`existing_id` set AND normalised bodies are byte-equal** → ENG-63 footer
  rotation runs; `commentUpdate`; **no breadcrumb** (AC #2). The footer is
  the documented signal for identical re-apply; a breadcrumb on every
  identical re-fire would flood the feed (a 5-min tick that keeps
  halting would post a fresh breadcrumb every 5 min, defeating the
  one-canonical-per-event invariant in spirit).
- **`existing_id` set AND normalised bodies DIFFER** → `commentUpdate`
  runs as today; **then** the function calls
  `add_comment "$ident" --body "<breadcrumb-body>"` (D-002). The
  breadcrumb gets a fresh `createdAt`, appears in the operator's
  chronological scan, and points back to the canonical sig.

**Why.** The narrowest fix that closes AC #1 without touching caller
surfaces, sig naming, or the dedup contract. Re-using
`add_or_update_comment`'s already-fetched response (`$resp`,
`bin/linear.sh:619`) avoids a new GraphQL roundtrip for body
extraction; the breadcrumb post is one extra `commentCreate` round-trip
on the body-change path only — exactly the case where operator
visibility is currently lost. Identical-body re-applies pay no
additional cost.

**Rejected — drop ENG-63's footer entirely and replace with a breadcrumb
for both identical AND body-change.** AC #2 explicitly says identical-body
re-runs are silent at the breadcrumb level. ENG-63's footer is the
already-shipped signal for identical re-apply (with documented operator
runbook in `docs/runbooks/recovery.md:240-260`). Removing it would lose
that observability gain and contradict AC #2. The two mechanisms are
complementary — footer for identical, breadcrumb for body-change.

**Rejected — embed the breadcrumb info INSIDE the canonical comment
(prepend a "last updated at" header).** Defeats the ticket's premise.
The bug is that humans scan top-down and miss in-place updates; a header
inside the canonical comment does NOT move that comment in the feed.
`createdAt` stays old, the comment stays where it was — the operator
still skims past it.

**Rejected — always post a breadcrumb (every body-update, identical or
not).** Identical-body re-applies are the high-noise case (a 5-min
polling cycle that keeps tripping the same halt produces many identical
re-applies). A breadcrumb per identical re-fire would flood the feed,
defeat the dedup contract's intent, and recreate the noise-vs-signal
tradeoff that ENG-63's footer rotation was designed to balance. The
identical case already has its solution; ENG-111 closes the gap that
solution doesn't address.

**Rejected — replace `commentUpdate` with `commentDelete` +
`commentCreate` on body-change.** Linear's API does not expose comment
deletion (`docs/runbooks/recovery.md:99-101` — append-only at the issue
level). Even if it did, deleting the canonical breaks every prior
operator link to it and discards the original `createdAt` of the
first emission. The canonical's `createdAt` is informative — it tells
operators "this halt class first fired N hours ago, has re-fired since"
— and we explicitly want to preserve it. The fix is purely additive.

### D-002. Breadcrumb body shape: short prose pointer + closed-vocabulary `<!-- meta: breadcrumb sig=<sig> -->` marker.

**Decision.** The breadcrumb body has exactly three substantive parts,
in this order:

1. One line of human-facing prose, written to be self-documenting on
   first encounter and direction-neutral (Linear web UI sorts by
   `createdAt` either newest-first or oldest-first depending on the
   operator's preference):
   `Re-emitted (body changed) under sig \`<sig>\`. Canonical comment was updated in place; this pointer marks the moment.`
2. (Optional) A second line carrying a Linear permalink to the
   canonical comment, IF we can fetch the `Comment.url` field from the
   existing GraphQL query (D-003). When the URL is unavailable, the
   line is omitted — the sig is sufficient because the operator can run
   `bash bin/linear.sh get-comments ENG-N` and grep for the sig.
3. A trailing closed-vocabulary marker
   `<!-- meta: breadcrumb sig=<sig> comment_id=<existing_id> -->`.
   The `comment_id` attribute embeds the canonical Linear comment id
   so that two breadcrumbs posted in two different dispatches against
   the SAME sig (which always rotate the canonical to the SAME
   comment_id, since update is in-place) still carry distinct body
   content via the auto-injected `<!-- meta: dispatch id=ENG-N-d… -->`
   marker on the end. **Why two ids?** The `sig` is the join key
   back to the canonical's logical event; the `comment_id` is a
   designed anti-dedup affordance that makes the breadcrumb's
   chronological-distinctness an explicit property rather than a
   happy-accident dependency on `add_comment`'s hash-dedup regex
   character class (D-001 §5 elaborates the regex-survival; design
   persona's P1.2 finding pushed this from implicit to explicit).

The auto-injected ENG-87 dispatch marker (`<!-- meta: dispatch id=… stage=… -->`)
appends after the body via `_inject_dispatch_marker`, which `add_comment`
runs as a chokepoint at `bin/linear.sh:514`. The breadcrumb therefore
carries TWO `meta:` markers — `breadcrumb` for discoverability and
`dispatch` for attribution — both inside the closed registry.

**Why.** A short pointer body is the lowest-noise shape that still
surfaces the re-emission chronologically. The `meta: breadcrumb` marker
makes the comment programmatically distinguishable from operator chatter
(future retrospective / status tooling can filter on it). The sig in the
marker provides a join key back to the canonical, regardless of whether
the optional URL line is present.

**Rejected — embed the full updated canonical body inside the breadcrumb.**
Triples the comment volume on every body-change re-fire and defeats the
"one canonical per logical event" invariant by spawning a second copy of
the content. The breadcrumb is a POINTER, not a duplicate.

**Rejected — emit a structured `<!-- pipeline: breadcrumb … -->` event
marker instead of a `meta:` marker.** `pipeline:` is reserved for
state-driving events (verdict / transition / decision per
`docs/pipeline-vocabulary.md`); the breadcrumb is bookkeeping, not
state. `meta:` is the documented namespace for that — same family as
`dedup`, `reapplied`, `dispatch`. Consistent with ENG-60 vocabulary
discipline.

### D-003. Extend the existing 50-comment query at `bin/linear.sh:616` to also return `url`, and fall back gracefully if Linear's `Comment.url` is unavailable.

**Decision.** Today the query is `{ id body }` per comment node. Change
to `{ id body url }`. When constructing the breadcrumb body, extract
`url` for the existing comment id from the same `$resp` payload (one
extra `jq` selector pass; no new roundtrip). If the URL string is
non-empty, include it in the breadcrumb body as line 2 (D-002); if
empty, omit the line — the sig in the trailing marker is the
fallback pointer.

**Why.** The ticket asks for "a pointer URL to the canonical (updated)
one." Adding `url` to the existing query is a one-token GraphQL diff
with zero new roundtrips. The fallback path keeps the breadcrumb
useful even if a Linear schema change ever drops `url` (or our
permissions get revoked) — the sig + chronological position is the
load-bearing signal; the URL is a convenience.

**Rejected — construct the URL string ourselves from
`issue.url + #comment-<id>`.** Linear's permalink format for comments is
not documented in this codebase (no usage found in `bin/`, only design
docs that quote sample formats), and the actual shape may use a
short-id prefix rather than the full UUID. Constructing a wrong URL is
worse than omitting it (a broken pointer wastes operator time). Using
the API's own `url` field is the only way to guarantee the link
resolves. Assumption A-009 marks the field's existence as
assumed-to-be-verified during implementation; if absent, the fallback
path is the design's behaviour.

**Rejected — do a second `comment(id: $id)` GraphQL roundtrip to fetch
the URL.** Adds one round-trip per body-change re-apply. The
breadcrumb-post path is already adding one (`commentCreate` for the
breadcrumb); a second URL-fetch query would double that. The single-query
extension is strictly cheaper.

### D-004. Breadcrumb is emitted ONLY on the update path, and ONLY when bodies genuinely differ. First-emission `commentCreate` skips it.

**Decision.** The branch at `bin/linear.sh:664-670` (the `else` arm —
no `existing_id`, so `commentCreate` runs to make the canonical) does
not emit a breadcrumb. First emission is itself a fresh chronological
comment; there is no prior "canonical" to point at.

**Why.** Clarity and AC fidelity. AC #1 specifies "a re-run that
produces a different body for an existing sig" — the existing-sig
clause is load-bearing. AC #3 names "first-emit (no breadcrumb)" as a
required test case.

### D-005. Add `breadcrumb` to the closed `meta_kinds` array in `bin/pipeline-events.json`.

**Decision.** `bin/pipeline-events.json:44-51` currently holds
`["dedup","metric","evidence","reapplied","forensic","dispatch"]`.
Append `breadcrumb`. `bin/generate-vocabulary-doc.sh:14` already
iterates `meta_kinds`, so `docs/pipeline-vocabulary.md` regenerates
with the new entry automatically.

**Why.** ENG-60 closed-vocabulary discipline: any new `meta:` marker
emitted by harness code MUST be in the registry. ENG-63 set this
precedent (D-005 in that brainstorm added `reapplied`); ENG-111 follows
the same pattern. Keeping `breadcrumb` out of the registry would let it
drift into ad-hoc shape territory and lose discoverability via the
auto-generated vocabulary doc.

**Lane fence verification.** The breadcrumb body is classified as
`other_comment` by `_classify_comment_body` (first line is prose, not
a transition marker). `_lane_decision "add" "other_comment"` allows
ALL lanes (`bin/linear.sh:115`). No lane denial possible for the
breadcrumb regardless of which lane (`orchestrator|agent|classify|
scope-check|human`) the caller is in.

**Rejected — free-form `<!-- breadcrumb: … -->` marker outside the
`meta:` namespace.** Drifts from the closed registry. The whole point
of ENG-60 was to prevent this exact failure mode.

### D-006. Tests live in `bin/linear-test.sh`, mirroring ENG-63's C-001..C-006 scaffolding.

**Decision.** Add a new test block `ENG-111: breadcrumb-on-body-change`
immediately after the ENG-63 test block at `bin/linear-test.sh:512-762`.
Re-use the same `linear_query` stub override + `_resolve_issue_uuid`
stub + `_eng63_capture_file` machinery; the stub already handles
`commentUpdate` and `commentCreate` paths. Six test cases:

1. **B-001** — first-emit (no `existing_id`): stub returns no
   matching existing comment; assert exactly ONE entry in the capture
   file (the new canonical body); assert capture does NOT contain
   `<!-- meta: breadcrumb sig=`.
2. **B-002** — body-change update: stub returns an existing comment
   with body B; caller passes body B' (where B'≠B post-normalisation);
   assert exactly TWO entries in the capture file (the updated
   canonical body B' AND the breadcrumb body); assert the second entry
   contains `<!-- meta: breadcrumb sig=test/sig/ENG-111T -->` and
   references the sig in its prose.
3. **B-003** — identical-body update: stub returns existing body B;
   caller passes body B (post-normalisation byte-equal); assert exactly
   ONE entry in the capture file (the canonical with rotated reapplied
   footer per ENG-63); assert capture does NOT contain
   `<!-- meta: breadcrumb sig=`.
4. **B-004** — breadcrumb body carries the sig AND the canonical URL:
   stub `linear_query` returns `url` for the existing comment;
   assert capture contains the URL substring in the breadcrumb entry.
5. **B-005** — URL fallback: stub returns existing comment with empty
   `url`; assert breadcrumb still posts (B-002 pattern) but the URL
   line is omitted; assert the trailing `<!-- meta: breadcrumb sig=… -->`
   marker is still present.
6. **B-006** — breadcrumb post failure is non-fatal: stub `linear_query`
   to return success for the `commentUpdate` but fail (rc != 0 / GraphQL
   error) for the subsequent `commentCreate`; assert the canonical
   update is still observable in the capture file AND
   `add_or_update_comment` itself returns 0 (canonical update is
   load-bearing; breadcrumb is best-effort).

**Why this file.** `bin/linear-test.sh:512-762` already exercises
`add_or_update_comment` under `PIPELINE_DRY_RUN=0` with a `linear_query`
stub that distinguishes `commentUpdate` from `commentCreate`. ENG-111's
test fixtures slot in directly with the same setup/teardown. The
stub's "everything else" branch already returns the canned existing
body for the 50-comment query; adding `url` to the canned response is
a one-arg change.

**Rejected — new file `bin/linear-breadcrumb-test.sh`.** ~80 lines of
setup duplication and an additional pre-commit suite entry, for no
modularity gain. The `add_or_update_comment` test surface is already
co-located in `linear-test.sh`.

### D-007. Operator-runbook update extends `docs/runbooks/recovery.md` §4 with a one-line breadcrumb pointer.

**Decision.** `docs/runbooks/recovery.md:228-267` (§4 "Halted issue
with stale-looking halt comment timestamp") is the recovery mode ENG-63
established. ENG-111 adds a paragraph to that section's "Recency
evidence" subsection:

> If `bash bin/linear.sh get-comments ENG-N | jq -r '.[] | select(.body | contains("meta: breadcrumb"))'`
> returns one or more breadcrumb comments referencing the canonical sig,
> those breadcrumbs carry a fresh `createdAt` for each body-change
> re-emission. The most recent breadcrumb's `createdAt` is the most
> recent body-change moment; the canonical comment (matched by sig in
> the breadcrumb marker) carries the current content.

Plus a one-line addition to the CLAUDE.md "Failure-mode quick reference"
row "Issue stuck in `stage:X`": "comment `createdAt` reflects FIRST
emission only — check the `<!-- meta: reapplied at=… -->` footer for
the latest re-apply moment (ENG-63), or grep for
`<!-- meta: breadcrumb sig=… -->` comments for body-change history
(ENG-111)."

**Why this file.** §4 already documents the stale-timestamp recovery
mode and lists ENG-63's footer as one signal. The breadcrumb is a
complementary signal for a different sub-mode (body-change rather than
identical-body); extending §4 keeps the operator's mental model in one
place. The minor CLAUDE.md touch-up matches ENG-63 D-007's precedent.

**Rejected — new §5 in recovery.md for the body-change mode.** The two
modes share the same underlying confusion ("the comment thread is
lying about when the halt re-fired"). Splitting them would force the
operator to identify which sub-mode they're in before they have the
evidence in hand — backwards.

### D-008. Inline implementation in `add_or_update_comment`, not a new helper.

**Decision.** Approximately 18 lines of bash inserted between
`bin/linear.sh:663` (the existing `log "updated-in-place …"` line) and
the `else` arm at `:664`. No new top-level function.

**Why.** Symmetric with ENG-63 D-008 (the rotating-footer logic was
also inlined). The breadcrumb construction is small and tightly
coupled to the variables already in scope (`$sig`, `$existing_id`,
`$resp`, `$is_identical_reapply`, `$ident`). Extracting it would
require either passing all four args explicitly or fishing them out
of globals; neither is cleaner than inline. If a third re-emission
mode lands in the future, hoist then.

**Rejected — extract `_post_breadcrumb_comment <sig> <ident> <comment_id> <canonical_url>`.**
The function would be called from exactly one place. Indirection
without modularity payoff.

**Dissenting view (design persona iter-1 P1).** The inline block is
~18 lines spanning four concerns (URL extraction from `$resp`,
breadcrumb-body construction, recursive `add_comment` call, metric
emission); a named helper would localise these and improve
grep-ability. Trade-off accepted as-is for symmetry with ENG-63's
inline footer-rotation precedent and because each concern is tightly
coupled to in-scope locals (`$sig`, `$existing_id`, `$resp`, `$ident`).
If a third re-emission mode lands in the future, this becomes a
natural extraction point — flagged as Q-005 for follow-up.

### D-009. Emit a `comment-breadcrumb` metric event on every breadcrumb post.

**Decision.** Inside the body-change branch (D-001), after the breadcrumb
`add_comment` call succeeds, fire:

```bash
bash "$SCRIPT_DIR/metrics.sh" comment-breadcrumb "$ident" "" \
  "posted" 0 || true
```

The `metrics.sh` signature is `<event> <issue_id> <stage> <outcome>
<duration_ms> [notes…]` (`bin/metrics.sh:19-22`). Pass empty stage
(the sig embeds it sometimes — `halt/<stage>/<issue>` — but not always;
matches ENG-63 D-009's `""` placeholder choice). `|| true` makes
metric write non-fatal — the comment post is the load-bearing call.

**Why.** Mirrors ENG-63 D-009 (`comment-reapplied`) for symmetry in the
retrospective signal. The retrospective agent
(`bin/run-retrospective-local.sh`) consumes `events.jsonl`; an issue
whose `comment-breadcrumb` count for a given sig climbs above a
threshold within a short window is a candidate "halt-loop with changing
body" signal (e.g., flapping `pipeline_content_hash` on retry-immediately
churn). Without this emission, body-change re-emissions remain
quantitatively invisible to retrospective tooling — the same gap ENG-63
closed for identical re-apply.

**Rejected — derive the metric from `comment-reapplied` plus a body-diff
flag.** Encodes two distinct events into one row's notes field; weakens
the registry's discoverability. Separate event name is simpler.

## 3. Architecture

### 3.1 Files modified

| File | Change |
|---|---|
| `bin/linear.sh` | (a) Extend the 50-comment query at `:616` to return `url`. (b) Set `is_identical_reapply` (0/1) in the existing-id branch (`:623-658`). (c) Insert ~18 lines after `:663` (`log "updated-in-place …"`) to extract `canonical_url` and post the breadcrumb via `add_comment` when `is_identical_reapply == 0`. (d) Emit `comment-breadcrumb` metric (D-009). |
| `bin/pipeline-events.json` | Append `breadcrumb` to `meta_kinds` (D-005). |
| `bin/linear-test.sh` | Add B-001..B-006 plus the canned-response extension for `url` (D-006). |
| `docs/runbooks/recovery.md` | Extend §4 "Recency evidence" with the breadcrumb pointer paragraph (D-007). |
| `CLAUDE.md` | One-line addition to the "Issue stuck in `stage:X`" row noting the breadcrumb signal (D-007). |
| `docs/pipeline-vocabulary.md` | Auto-regenerated from the updated registry (D-005). |

No changes to `bin/verdict-handler.sh`, `bin/classify-failure.sh`,
`bin/run-stage.sh`, `bin/poll.sh`, or any other caller. The fix is
contained in `linear.sh`; callers continue to invoke
`add-or-update-comment <sig> <ident> <body>` exactly as they do today.

### 3.2 Pseudocode for the `add_or_update_comment` change

```bash
# bin/linear.sh:616 — extend query to also return url.
local q='query($id: String!) { issue(id: $id) { comments(first: 50, orderBy: updatedAt) { nodes { id body url } } } }'

# bin/linear.sh:623 — existing-id branch
if [[ -n "$existing_id" ]]; then
  # … existing ENG-63 normalisation + footer rotation (:631-658) …
  # (:631-652 strip + compare; :653-658 rotate footer + metric)

  local is_identical_reapply=0
  if [[ "$existing_norm" == "$new_norm" && -n "$existing_norm" ]]; then
    is_identical_reapply=1
    now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    body="${new_norm}"$'\n'"<!-- meta: reapplied at=${now_iso} -->"
    bash "$SCRIPT_DIR/metrics.sh" comment-reapplied "$ident" "" \
      "reapplied" 0 || true
  fi

  # … existing commentUpdate (:659-663) …
  linear_query "$mu" "$mvars" >/dev/null
  log "updated-in-place $sig on $ident (comment=$existing_id)"

  # NEW (ENG-111): post a chronological breadcrumb when the body
  # genuinely changed. Identical re-applies (ENG-63 path) stay
  # silent at the breadcrumb level (AC #2).
  if (( is_identical_reapply == 0 )); then
    local canonical_url breadcrumb_body
    canonical_url="$(jq -r --arg id "$existing_id" \
      '[.data.issue.comments.nodes[]? | select(.id == $id) | .url] | first // ""' \
      <<<"$resp")"
    local prose=$'Re-emitted (body changed) under sig `'"$sig"$'`. Canonical comment was updated in place; this pointer marks the moment.'
    local trailer=$'<!-- meta: breadcrumb sig='"$sig"$' comment_id='"$existing_id"$' -->'
    if [[ -n "$canonical_url" ]]; then
      breadcrumb_body="${prose}"$'\n'"${canonical_url}"$'\n\n'"${trailer}"
    else
      breadcrumb_body="${prose}"$'\n\n'"${trailer}"
    fi
    # add_comment runs the lane fence + dispatch-id auto-injection
    # + last-10 hash dedup. Non-fatal on failure — the canonical
    # update is the load-bearing call.
    if add_comment "$ident" --body "$breadcrumb_body"; then
      bash "$SCRIPT_DIR/metrics.sh" comment-breadcrumb "$ident" "" \
        "posted" 0 || true
    else
      log "add-or-update-comment: breadcrumb post failed for $sig on $ident (non-fatal)"
    fi
  fi
else
  # … existing commentCreate first-emission branch (:664-670) …
fi
```

### 3.3 GraphQL impact

| Path | Before | After | Delta |
|---|---|---|---|
| First emission (`existing_id` empty) | 1 query (50-comment fetch) + 1 mutation (`commentCreate`) = 2 calls | unchanged | 0 |
| Identical-body re-emission | 1 query + 1 mutation (`commentUpdate`) = 2 calls | unchanged | 0 |
| Body-change re-emission | 1 query + 1 mutation (`commentUpdate`) = 2 calls | 1 query + 2 mutations (`commentUpdate` + breadcrumb `commentCreate`) + 1 query (add_comment's last-10 hash dedup fetch) = 4 calls | +1 query, +1 mutation |

The +2 calls per body-change re-emission are bounded: body-change
re-emissions are inherently rarer than identical re-applies (each one
represents a meaningful state change — new exit code, new content hash,
new retry counter), and a 5-minute polling cycle that flapped on every
tick would emit at most ~288 breadcrumbs/day per affected issue.
`add_comment`'s last-10 hash dedup absorbs the cross-dispatch-identical
case (D-009 footer's body normalised after timestamp/SHA stripping).

## 4. Data flow

```
Caller (verdict-handler / classify-failure / run-stage)
  │
  └─► bash bin/linear.sh add-or-update-comment <sig> <issue> <body>
        │
        ├─ legacy-marker reject (unchanged — :588)
        ├─ _inject_dispatch_marker (unchanged — :595)
        ├─ append dedup marker (unchanged — :601-605)
        ├─ if PIPELINE_DRY_RUN=1 → log + return (unchanged — :607-610)
        ├─ resolve issue uuid (unchanged — :612-613)
        ├─ fetch last 50 comments {id, body, url} (CHANGED — :616 adds url)
        │
        ├─ if existing_id is non-empty:
        │    ├─ normalise existing vs new (unchanged — :631-652)
        │    ├─ if normalised equal:
        │    │     ├─ rotate reapplied footer (unchanged — :653-657)
        │    │     ├─ emit comment-reapplied metric (unchanged)
        │    │     └─ is_identical_reapply := 1
        │    ├─ commentUpdate (unchanged — :659-663)
        │    │
        │    └─ NEW (ENG-111): if is_identical_reapply == 0:
        │          ├─ extract canonical_url from $resp by id
        │          ├─ construct breadcrumb body (prose + url + meta marker)
        │          ├─ add_comment <issue> --body <breadcrumb_body>
        │          │  (recursive call — inherits lane fence,
        │          │   dispatch-id injection, last-10 hash dedup)
        │          └─ on success: emit comment-breadcrumb metric
        │
        └─ else:
             commentCreate (unchanged — :664-670)
             [no breadcrumb on first emission]
```

The recursive `add_comment` call is safe: `add_comment` does NOT call
`add_or_update_comment` back, so there is no cycle. `add_comment`'s
own dispatch-id auto-injection is idempotent
(`_inject_dispatch_marker` skips when the current dispatch marker is
already present, per `bin/linear.sh:71-74`); the breadcrumb body
arrives at `add_comment` with no dispatch marker yet (we don't
prepend one in the breadcrumb construction), so the injection
appends cleanly.

## 5. Error handling

- **`jq` extraction failure (canonical_url parse).** If the `jq`
  selector returns empty (Comment.url field absent from the schema or
  null in the payload), `canonical_url` is empty; the breadcrumb body
  takes the URL-less form (D-002 line 2 omitted). The sig in the
  trailing marker is the fallback pointer. Operator can resolve via
  `bash bin/linear.sh get-comments ENG-N`.
- **`add_comment` breadcrumb post failure** (Linear API error, lane
  fence — won't happen since `add other_comment` is allow-all but
  defensive — or hash-dedup suppresses the post). `|| true` semantics
  via the `if … else log "breadcrumb post failed (non-fatal)" fi`
  pattern. Canonical update has already succeeded; the operator still
  sees the in-place update with its new content. Recovery: next
  body-change re-emission will attempt another breadcrumb.
- **`metrics.sh comment-breadcrumb` failure.** `|| true` suppresses;
  comment update + breadcrumb succeed regardless. Retrospective signal
  is best-effort.
- **`commentUpdate` itself fails before the breadcrumb branch.**
  `linear_query` either succeeds (rc=0, body written) or `die`s after
  3 attempts (rc≠0 propagates via `set -euo pipefail`). The
  breadcrumb branch only runs after `linear_query "$mu"` returns 0; on
  failure the function aborts before the branch executes. Correct
  outcome — the breadcrumb shouldn't point at a comment whose update
  failed.
- **`add_comment`'s recursive last-10 hash dedup suppresses the
  breadcrumb.** Hash dedup normalises timestamps + SHA-like hex
  (`bin/linear.sh:535-537` and `:552-554`). The breadcrumb's
  chronological-distinctness has TWO independent guards against
  silent dedup suppression: (a) the trailing
  `<!-- meta: breadcrumb sig=<sig> comment_id=<existing_id> -->` marker
  embeds the canonical comment id, which is stable per-sig but distinct
  per-event-class — though this alone wouldn't help cross-dispatch
  re-fires of the SAME canonical; (b) the auto-injected
  `<!-- meta: dispatch id=ENG-N-d<NNNN> -->` marker on the body's end,
  whose token contains uppercase `ENG` and so does NOT match the
  lowercase-only `[0-9a-f]{7,40}` hex character class. Two breadcrumbs
  from different dispatches therefore differ on the dispatch-id line
  AND survive both normalisation passes. Two breadcrumbs from the SAME
  dispatch for the SAME sig (extremely unlikely — would require two
  body-change re-fires in one agent cycle) WOULD hash-dedup and be
  silently suppressed. That's an acceptable degenerate case (the
  operator sees one breadcrumb for one dispatch, which is informative).

## 6. Edge cases

- **First emission (`existing_id` empty).** D-004 — `commentCreate`
  fires; no breadcrumb. `createdAt` carries the first-emission moment.
- **Identical body re-apply.** D-001 + AC #2 — ENG-63 footer
  rotation runs; `commentUpdate` succeeds; `is_identical_reapply=1`
  so the breadcrumb branch skips. No breadcrumb. Operator-visible
  signal is the rotated footer at the bottom of the canonical body.
- **Body-change re-apply where the only change is a fresh ENG-87
  dispatch_id marker** (the prior canonical was stamped with
  dispatch_id A, the new body carries dispatch_id B, content
  otherwise identical). The normalisation strip removes both
  `dispatch id=` lines before comparison (`bin/linear.sh:645`), so
  the two bodies normalise to byte-equal → `is_identical_reapply=1`
  → no breadcrumb. Correct — a dispatch-id rotation is not a content
  change worth surfacing chronologically.
- **Body-change re-apply where the canonical comment has a stale
  ENG-63 reapplied footer (prior dispatch's footer).** The strip
  removes both `reapplied at=` lines before comparison, so the
  comparison sees content-only. If content actually changed,
  `is_identical_reapply=0` → breadcrumb posts. Correct.
- **Sig contains characters that need shell-escaping in the breadcrumb
  body** (`/`, `:`, ` `, etc., as in `halt/implement/ENG-111`). The
  body string is constructed via bash string-substitution and passed
  to `add_comment "$ident" --body "$breadcrumb_body"` — `--body` takes
  the value verbatim (`bin/linear.sh:463-469`). The sig rides into the
  body as quoted-literal characters. No shell expansion or
  word-splitting on the sig because of double-quoting.
- **Sig contains characters that break the `<!-- meta: breadcrumb sig=<sig> -->`
  marker shape** — specifically, if `<sig>` itself contains `-->`. Today
  the sigs in use (`halt/<stage>/<issue>`, `completion/<stage>/<issue>`,
  `protocol-violation/<case_id>/<issue>`, `scope-approval/<stage>/<issue>`)
  consist of `[a-z]+(/[a-z]+|/ENG-[0-9]+)+` shapes — no `>` characters.
  Defensive: if a future sig embeds `-->`, downstream parsers reading
  the marker would mis-split. `_classify_comment_body`
  (`bin/linear.sh:84-96`) never sees the marker because it's body
  content, not a label, and the classifier only inspects the FIRST
  non-blank line of the body. The risk is downstream
  parsers reading the marker via regex — those should anchor on the
  fixed `<!-- meta: breadcrumb sig=` prefix and read until end-of-line,
  not until `-->`. Out of scope to fix preemptively; flagged as Q-002.
- **Operator manually re-runs the same dispatch twice (same `PIPELINE_DISPATCH_ID`).**
  Both invocations attempt to post identical breadcrumb bodies (same
  sig, same dispatch_id, same canonical content). `add_comment`'s
  hash dedup catches the second one; one breadcrumb in the feed.
  Correct behaviour.
- **The breadcrumb body's chronological position in Linear's web UI.**
  Linear's web feed orders comments by `createdAt` (newest first or
  oldest first depending on user preference). The breadcrumb's
  `createdAt` is set by Linear at `commentCreate` time → fresh
  timestamp. Regardless of which sort direction the operator
  prefers, a top-down scan (newest at top, descending) puts the
  breadcrumb at or near the top. Verified: AC #1 satisfied for the
  default Linear web UI behaviour.
- **A re-emission that drops a line from the body (body shrinks rather
  than grows).** Normalisation strips footer/dispatch lines but
  preserves content. If the content lines genuinely differ, even by
  one line, `existing_norm != new_norm` → breadcrumb. Correct.

## 7. Persona review

Run during this session per the brainstorming stage's persona-review
contract. Six personas dispatched against the iter-1 draft in the
mandated order (design → security → scope → coherence → product →
feasibility, feasibility gating).

| Persona | Verdict | P0 | P1/P2 themes addressed in iter-2 |
|---|---|---|---|
| design | PASS | 0 | P1 inline-vs-helper trade-off → captured as dissenting view in D-008 + Q-005. P1 happy-accident hash-dedup → upgraded to designed property (D-002 now embeds `comment_id` in the trailing marker; §5 expanded to call out the two independent dedup-survival guards). P2 directional arrow / Q-002 / D-009 stage placeholder noted; arrow addressed (see product), Q-002/D-009 deferred. |
| security | PASS | 0 | No findings P0/P1. P2 confirmations recorded: `jq --arg` injection-safe; lane fence preserves; closed-vocabulary discipline preserved; secret-handling unimplicated. Implementation reminder noted in §3.2 (`jq -r --arg id`, not string interpolation). |
| scope | PASS | 0 | P1 D-009 metric scope-adjacent → kept with explicit author flag in §10 mirroring ENG-63 D-009 precedent (operator who pushed for that precedent flagged it; ENG-111 follows). P2 sizing rubric verified: 1 subsystem (Linear contract), 1 load-bearing decision (D-001). |
| coherence | PASS | 0 | P2 line-range cosmetics fixed (`:631-652` vs `:631-658` annotation in §3.2; A-001 `:664-670` normalisation). P2 `_classify_label` typo → corrected to `_classify_comment_body` in §6, with the function's behaviour cited (`bin/linear.sh:84-96`). |
| product | PASS | 0 | P1 directional `↑` arrow → replaced with direction-neutral prose ("Canonical comment was updated in place; this pointer marks the moment"), which also addresses the first-encounter cognitive-load finding (the prose is now self-documenting). P2 diff preview / status aggregation / grep-vs-jq runbook deferred. |
| feasibility (gating) | PASS | 0 | All 12 cited code-level facts verified against the current worktree. Hash-dedup ENG-N-d<NNNN>-vs-`[0-9a-f]{7,40}` survival explicitly verified (uppercase `ENG` breaks the lowercase-only hex class). Pseudocode bash 3.2-compatible. jq selector valid. No cycle on recursive `add_comment`. A-009 (`Comment.url`) remains the single 'assumed' item; design's graceful-degradation path keeps AC #1 satisfied independent of A-009 (B-005 fixture pins this). |

**Gate:** 6/6 PASS, 0 P0 in feasibility. Threshold (≥5/6 PASS AND
feasibility P0=0) cleanly satisfied at iter-1; iter-2 patches applied
the P1 product + design findings and P2 coherence cleanups inline
without re-dispatching personas.

## 8. Anti-bias checks

### 8.1 ADR stress test

- **One canonical comment per logical event** (ENG-60 vocabulary
  closure, reinforced by ENG-63 D-001). The breadcrumb is NOT a second
  canonical — it carries no `meta: dedup key=<sig>` marker, so future
  `add_or_update_comment` calls under the same sig will NOT match it as
  an existing comment to update. The canonical-per-sig invariant is
  preserved. NO stress.
- **Closed `meta:` token registry** (ENG-60). D-005 honours the
  registry — `breadcrumb` joins it. NO stress.
- **Lane fence write enforcement** (ENG-41). The breadcrumb body is
  classified as `other_comment`; `add other_comment` is allow-all.
  No lane-denial path. NO stress.
- **Linear comments are append-only**
  (`docs/runbooks/recovery.md:99-101`). The fix LEANS ON this property
  — the breadcrumb is purely additive, never updates or deletes the
  canonical. REINFORCES.
- **Dispatch-id auto-injection chokepoint** (ENG-87). The breadcrumb
  is posted via `add_comment`, which is the chokepoint;
  auto-injection happens uniformly. No new bypass surface. NO stress.
- **`add_or_update_comment`'s "no lane fence" gap** (noted in ENG-63
  D-005 footnote). The breadcrumb sub-call goes through `add_comment`,
  which DOES enforce the lane fence (`bin/linear.sh:503-505`). So the
  breadcrumb actually gets MORE lane enforcement than the canonical
  it shadows — a small unevenness but functionally correct (the
  fence's allow-all decision for `other_comment` means the unevenness
  has no operational impact). Flagged for Q-003 as a follow-up
  cleanup outside ENG-111's scope.

### 8.2 Simpler alternatives

Inline under each decision's "Rejected" blocks. Summary:

- D-001 rejected: drop ENG-63 footer entirely; embed pointer inside
  canonical; always post breadcrumb; commentDelete+commentCreate.
- D-002 rejected: embed full canonical body; `pipeline:` event marker.
- D-003 rejected: construct URL ourselves; second roundtrip.
- D-006 rejected: separate test file.
- D-007 rejected: new §5 in recovery.md.
- D-008 rejected: extracted helper function.
- D-009 rejected: encode in existing `comment-reapplied` notes.

### 8.3 Assumption inventory

| # | Assumption | Status | Verification |
|---|---|---|---|
| A-001 | `add_or_update_comment` lives at `bin/linear.sh:576-671`; existing-id query at `:616-621`; commentUpdate at `:659-663`; commentCreate first-emission branch at `:664-670`; ENG-63 footer rotation at `:631-658`. | verified | `Read bin/linear.sh:576-671` this session. |
| A-002 | Callers that route through `add_or_update_comment` and may emit body-change re-emissions: `bin/verdict-handler.sh::_vh_protocol_violation`, `bin/classify-failure.sh:146` (halt sig), `bin/run-stage.sh:212,216` (completion sig), plus scope-approval. | verified | Cited in ENG-63 brainstorm §1 table (verified-pinned in that session). |
| A-003 | `bin/pipeline-events.json::meta_kinds` is the closed-vocabulary registry; currently `["dedup","metric","evidence","reapplied","forensic","dispatch"]`. | verified | `Read bin/pipeline-events.json:44-51` this session. |
| A-004 | `bin/generate-vocabulary-doc.sh` iterates `meta_kinds` so registry updates auto-propagate to `docs/pipeline-vocabulary.md`. | verified | Cited and verified in ENG-63 D-005 (A-007 in that brainstorm). |
| A-005 | `bin/metrics.sh` signature is `<event> <issue_id> <stage> <outcome> <duration_ms> [notes…]`; accepts arbitrary event names (closure of `[[ -n "$event" && -n "$outcome" ]]` validation). | verified | `Read bin/metrics.sh:19-22` this session. |
| A-006 | `_inject_dispatch_marker` at `bin/linear.sh:60-77` is the dispatch-id chokepoint; idempotent on re-apply; runs at the top of both `add_comment` (`:514`) and `add_or_update_comment` (`:595`). | verified | `Read bin/linear.sh:60-77,514,595` this session. |
| A-007 | `add_comment` enforces the lane fence at `:503-505` and runs its own last-10 hash dedup at `:528-565`. | verified | `Read bin/linear.sh:496-574` this session. |
| A-008 | The lane decision `add other_comment` is allow-all across `orchestrator|agent|classify|scope-check|human` (`bin/linear.sh:115` — `printf 'allow'`). | verified | `Read bin/linear.sh:102-120` this session. |
| A-009 | Linear's GraphQL `Comment` type exposes a `url` field returning a permalink to the comment. | assumed | Not verified against this codebase (no usage found via grep). Will be verified during implementation by extending the query and inspecting the response on a real Linear issue. If the field is absent or null, the design's URL-fallback path (D-002, D-003, §5) keeps the breadcrumb useful without it; AC #1 is still satisfied because the breadcrumb's chronological position is the load-bearing property. |
| A-010 | `bin/linear-test.sh:512-762` (ENG-63 test block) uses a `linear_query` stub override + `_resolve_issue_uuid` stub + `PIPELINE_DRY_RUN=0` flip; the stub distinguishes `commentUpdate` vs `commentCreate` mutations and routes a canned `{id, body}` payload for the comments-fetch query. | verified | `Read bin/linear-test.sh:512-762` this session. |
| A-011 | The ENG-87 strict-id-match design clears the per-issue `dispatch_id` on every dispatch start, so breadcrumbs emitted in dispatch A and dispatch B carry different `<!-- meta: dispatch id=ENG-N-d… stage=… -->` lines, making them distinct under `add_comment`'s hash-dedup normalisation. | verified | `Read bin/linear.sh:60-77` (ENG-87 chokepoint); cross-referenced CLAUDE.md "Cross-dispatch staleness contract (ENG-87)". |
| A-012 | `docs/runbooks/recovery.md` §4 exists and documents the stale-halt-timestamp recovery mode with the ENG-63 footer signal at `:240-260`. | verified | `Read docs/runbooks/recovery.md:228-267` (grep result this session). |
| A-013 | macOS BSD `date -u +%Y-%m-%dT%H:%M:%SZ` is available on the launchd host (no GNU coreutils requirement for ISO-8601 UTC formatting). | verified | Inherited from ENG-63 A-013 (already running in production for the rotating footer). |

A-009 is the only assumed item. The design degrades gracefully if A-009
is wrong: the breadcrumb body omits the URL line, the sig in the
trailing marker becomes the sole pointer, and the operator still sees
a fresh chronological comment naming the canonical sig. AC #1 is
satisfied independent of A-009.

## 9. Open questions

- **Q-001.** Should the breadcrumb include a one-line body diff
  preview (e.g., the first few lines of the new content) so the
  operator gets immediate context without clicking through? Pro:
  faster triage on a top-down feed scan. Con: scope creep (the ticket
  asks for a pointer, not a preview); risks duplicating
  meaningful content from the canonical. Recommendation: implement
  only if operators report the pointer alone is insufficient.
- **Q-002.** Harden the `<!-- meta: breadcrumb sig=<sig> -->` marker
  parser shape against future sigs that might contain `-->`. Today's
  sigs don't, but a future caller might. Defensive shape:
  `<!-- meta: breadcrumb key="<sig>" -->` with a quoted key whose
  parser reads until end-of-line. Out of scope for ENG-111; flagged
  for follow-up.
- **Q-003.** Add the missing lane-fence call to `add_or_update_comment`
  itself (the canonical's update path), mirroring the `add other_comment`
  / `add transition_comment` check that `add_comment` performs. ENG-63
  D-005 noted this gap; ENG-111 doesn't widen it, but doesn't close
  it either. Out of scope; flagged for follow-up.
- **Q-004.** Should `bin/pipeline.sh status` aggregate breadcrumb
  counts per issue (mirroring whatever it does today for
  `comment-reapplied`) so an operator can see "this issue has 7
  body-change re-emissions across 3 dispatches" at a glance? The
  data is in `events.jsonl` post-D-009. Surfacing is an ergonomic
  enhancement, not load-bearing for ENG-111. Flagged for follow-up.
- **Q-005.** Extract `_post_breadcrumb_for_canonical` if a third
  re-emission mode lands in the future (design persona's dissenting
  view in D-008). Today's two modes (footer rotation, breadcrumb) are
  inlined for symmetry with the ENG-63 precedent; a third mode would
  push the function over its single-page readability bound and is the
  natural extraction trigger. Out of scope for ENG-111.

## 10. Scope flags

Nothing in this brainstorm exceeds the issue's acceptance criteria:

- **AC #1 (breadcrumb on body-change update)** → D-001, D-002, D-003, §3.2.
- **AC #2 (identical re-runs silent)** → D-001 (`is_identical_reapply` gate), §3.2.
- **AC #3 (tests cover all three paths)** → D-006 (B-001/B-002/B-003 cover
  first-emit/body-change/identical respectively).

The `bin/pipeline-events.json::meta_kinds` append (D-005) is an
acceptance-criteria-implicit ENG-60 requirement — any new `meta:`
marker emitted by harness code MUST be in the closed registry.
Identical precedent set by ENG-63 D-005 for `reapplied`.

The `comment-breadcrumb` metric emission (D-009) is one line of
additive observability that closes the retrospective-blindness gap
ENG-63 D-009 closed for `comment-reapplied`. Operator-facing
observability is the bug class ENG-111 targets, so I'm including it;
if a reviewer judges this as scope creep, remove the `metrics.sh`
line and demote to Q-005. Matches the ENG-63 D-009 author's same
self-flag.

The `CLAUDE.md` Failure-mode quick reference touch-up (D-007 addendum)
is a one-line documentation update that the operator runbook §4
cross-references. Trivial; included for navigability — matches the
pattern of ENG-63 D-007.

## 11. Conflicts with existing architecture

None identified.

The dedup contract (one canonical comment per sig), the lane fence,
the closed `meta:` vocabulary, the append-only Linear-comment
property, and the dispatch-id chokepoint discipline are all
preserved. The fix is a strict information ADD: every body-change
re-emission produces one additional chronological breadcrumb pointing
at the canonical, under the documented `meta:` namespace, with a
matching `comment-breadcrumb` metric event.

ENG-104's broader "append-only event ledger with explicit per-dispatch"
framing is the parent ticket; ENG-111's narrow contribution is the
chronological-breadcrumb mechanism. The broader ledger design (the
parent's full surface) is not in ENG-111's scope and is not touched by
this brainstorm.
