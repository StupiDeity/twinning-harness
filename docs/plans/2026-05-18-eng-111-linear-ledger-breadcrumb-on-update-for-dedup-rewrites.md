---
linear: ENG-111
date: 2026-05-18
topic: Linear ledger — breadcrumb-on-update for dedup rewrites
---

# ENG-111 — Plan: breadcrumb-on-update for dedup rewrites

## 1. Goal

When `bin/linear.sh::add_or_update_comment` runs `commentUpdate` with a
genuinely-different body (post the ENG-63 normalisation strip), also post a
sig-less chronological breadcrumb pointer via the existing `add_comment`
chokepoint. Identical-body re-applies stay silent at the breadcrumb level
(ENG-63's rotating footer remains the canonical signal for that mode).

Brainstorm: [docs/brainstorms/2026-05-16-eng-111-linear-ledger-breadcrumb-on-update-for-dedup-rewrites-design.md](../brainstorms/2026-05-16-eng-111-linear-ledger-breadcrumb-on-update-for-dedup-rewrites-design.md).

## 2. Assumption Inventory

Branch rebased onto `origin/main` (`81a2206`) at plan time. All line
numbers below are anchors valid at this base; the implementer re-verifies
each anchor before each Edit.

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A1 | `add_or_update_comment` body at `bin/linear.sh:576-671`; existing-id query at `:616`; existing-id branch at `:623-663`; ENG-63 footer rotation at `:653-658`; commentUpdate at `:659-663`; first-emission `commentCreate` at `:664-670`. | **verified** | Read `bin/linear.sh:576-671` post-rebase. |
| A2 | The query at `:616` returns `{ id body }` per node; extending to `{ id body url }` is a one-token GraphQL diff with zero new roundtrips. | **verified** | `bin/linear.sh:616` matches the literal in brainstorm §3.2. |
| A3 | `add_comment` (`bin/linear.sh:496-574`) is the chokepoint: runs `_check_lane` + `_inject_dispatch_marker` + last-10 hash dedup + `commentCreate`. Returns non-zero on lane denial or `linear_query` failure; idempotent on hash-dedup hit (logs + returns 0). | **verified** | Read `bin/linear.sh:496-574`. |
| A4 | `add_comment` last-10 hash dedup normalises ISO timestamps + `[0-9a-f]{7,40}` hex (`bin/linear.sh:535-537,552-554`). The auto-injected `<!-- meta: dispatch id=ENG-N-d<NNNN> -->` line carries uppercase `ENG-N-d<NNNN>` which does NOT match the lowercase hex class. Two breadcrumbs from different dispatches survive dedup. | **verified** | Read `bin/linear.sh:535-554` + `_inject_dispatch_marker` at `:60-77`. |
| A5 | `bin/pipeline-events.json::meta_kinds` is `["dedup","metric","evidence","reapplied","forensic","dispatch"]`. | **verified** | Read `bin/pipeline-events.json:44-51`. |
| A6 | `bin/generate-vocabulary-doc.sh` iterates `meta_kinds` so registry updates auto-propagate to `docs/pipeline-vocabulary.md`. | **verified** | Inherited from ENG-63 D-005; cross-verified via grep. |
| A7 | `bin/linear-test.sh:512-762` (ENG-63 test block) uses a `linear_query` stub + `_resolve_issue_uuid` stub + `_eng63_capture_file` + `PIPELINE_DRY_RUN=0`. The stub already routes `commentUpdate`/`commentCreate` mutation bodies into the capture file and serves a canned `{id, body}` payload for the comments-fetch query. | **verified** | Read `bin/linear-test.sh:510-762`. |
| A8 | `bin/metrics.sh` signature is `<event> <issue_id> <stage> <outcome> <duration_ms> [notes…]`. Accepts arbitrary event names. | **verified** | Inherited from ENG-63 D-009. |
| A9 | `docs/runbooks/recovery.md §4` documents the stale-halt-timestamp recovery mode with the ENG-63 footer signal; "Recency evidence" subsection at `:243-253`. | **verified** | Read `docs/runbooks/recovery.md:229-267`. |
| A10 | CLAUDE.md "Issue stuck in `stage:X`" row at `:772` carries the ENG-63 footer reference; ENG-111 appends to that row. | **verified** | Grep + read CLAUDE.md:772. |
| A11 | Linear's GraphQL `Comment` type exposes a `url` field. | **assumed (verify on first real run)** | No usage in repo. Brainstorm §3.2 D-003 + §5 explicitly designs the URL-fallback path so AC#1 is satisfied if A-11 is wrong; B-005 fixture pins the fallback. |

## 3. File Structure

| File | Change | Status |
|---|---|---|
| `bin/linear.sh` | Modify — (a) extend query at `:616` to include `url`; (b) introduce `is_identical_reapply` flag in existing-id branch; (c) on body-change path, extract `canonical_url` from `$resp`, construct breadcrumb body, post via `add_comment`, emit `comment-breadcrumb` metric. | modified |
| `bin/pipeline-events.json` | Modify — append `breadcrumb` to `meta_kinds`. | modified |
| `bin/linear-test.sh` | Modify — add ENG-111 test block B-001..B-006 immediately after the ENG-63 block; extend the canned `linear_query` stub to also serve `url` per node. | modified |
| `docs/pipeline-vocabulary.md` | Auto-regenerated via `bash bin/generate-vocabulary-doc.sh`. | regenerated |
| `docs/runbooks/recovery.md` | Modify — extend §4 "Recency evidence" with one breadcrumb paragraph. | modified |
| `CLAUDE.md` | Modify — append the breadcrumb signal to the "Issue stuck in `stage:X`" row. | modified |
| `docs/brainstorms/2026-05-16-eng-111-...-design.md` | New (already on disk; staged from prior dispatch). | new |
| `docs/plans/2026-05-18-eng-111-...-design.md` | New (this file). | new |
| `docs/plans/2026-05-18-eng-111-...-design.json` | New — plan-schema-v1 contract sibling. | new |

**Out of scope:** every other file in the repo. Callers of
`add_or_update_comment` are NOT touched (`verdict-handler.sh`,
`classify-failure.sh`, `run-stage.sh`, etc.). The fix is contained in
`linear.sh`; the function's public signature is unchanged.

## 4. API Contract

No new public API. `add_or_update_comment <sig> <ident> <body>` continues
to accept the same arguments; callers do not change. The breadcrumb is a
strictly-additive Linear-side comment produced by the function as a side
effect of the body-change update path.

## 5. Backend Tasks

### Task 1 — `bin/pipeline-events.json`: register `breadcrumb` meta kind

Edit `bin/pipeline-events.json`. Append `"breadcrumb"` to the
`meta_kinds` array (after `"dispatch"`). Comma placement: today's last
entry is `"dispatch"` with no trailing comma; add a comma to that line
and place `"breadcrumb"` on the next line.

Pass criterion: `jq -r '.meta_kinds[]' bin/pipeline-events.json` yields
seven lines, last is `breadcrumb`; JSON parses (`jq . bin/pipeline-events.json > /dev/null`).

### Task 2 — `bin/linear.sh`: extend comments-fetch query with `url`

Edit `bin/linear.sh:616`. Replace the literal
`comments(first: 50, orderBy: updatedAt) { nodes { id body } }` with
`comments(first: 50, orderBy: updatedAt) { nodes { id body url } }`.
No other change in this task. The new field is read by Task 3.

Pass criterion: grep for `nodes { id body url }` in `bin/linear.sh`
matches exactly once.

### Task 3 — `bin/linear.sh`: emit breadcrumb on body-change `commentUpdate`

Edit the existing-id branch at `bin/linear.sh:623-663`. Concrete shape:

1. After the existing footer-rotation block at `:653-658`, set a
   local flag `local is_identical_reapply=0` initialised at the top
   of the existing-id branch (declare immediately after the `if [[ -n
   "$existing_id" ]]; then` opening, before the
   `local existing_body strip_re ...` declaration). Inside the
   byte-equal arm (`if [[ "$existing_norm" == "$new_norm" && -n
   "$existing_norm" ]]; then`), set `is_identical_reapply=1`
   alongside the existing footer write + metric emission.
2. After the existing `linear_query "$mu" "$mvars" >/dev/null` +
   `log "updated-in-place …"` lines (`:662-663`), and BEFORE the
   closing `fi` of the existing-id branch, insert the breadcrumb
   block, gated on `(( is_identical_reapply == 0 ))`. The block:

   ```bash
   if (( is_identical_reapply == 0 )); then
     # ENG-111: body-change re-emission posts a chronological breadcrumb
     # so a top-down scan of the Linear feed sees the re-fire (the
     # canonical's createdAt is the FIRST emission's timestamp and stays
     # fixed across commentUpdate calls).
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
     if add_comment "$ident" --body "$breadcrumb_body"; then
       bash "$SCRIPT_DIR/metrics.sh" comment-breadcrumb "$ident" "" \
         "posted" 0 || true
     else
       log "add-or-update-comment: breadcrumb post failed for $sig on $ident (non-fatal)"
     fi
   fi
   ```

Pass criteria:

- grep for `meta: breadcrumb sig=` in `bin/linear.sh` matches once.
- grep for `comment-breadcrumb` in `bin/linear.sh` matches once.
- grep for `is_identical_reapply` in `bin/linear.sh` matches three times
  (declaration, assignment, gate).

### Task 4 — `bin/linear-test.sh`: B-001..B-006 fixtures

Insert a new test block titled `--- ENG-111: breadcrumb-on-body-change ---`
between the ENG-63 cleanup block (ending at `:762` with the `unset` for
`_eng63_ad002_*`) and the `--- ENG-87: dispatch_id auto-injection ---`
header at `:764`.

The block:

1. Re-establishes stubs by saving + overriding `linear_query` and
   `_resolve_issue_uuid` (same pattern as ENG-63). Sets
   `PIPELINE_DRY_RUN=0`. Captures `commentUpdate` + `commentCreate`
   mutation bodies into a fresh `_eng111_capture_file`.
2. Adds an optional `_eng111_canned_existing_url` variable; the stub's
   comments-fetch response embeds `{id, body, url}` with that URL
   value (empty when unset, matching the A-11 fallback path).
3. Adds a `_eng111_canned_no_match` toggle (default 0) that makes the
   comments-fetch response carry an unrelated comment whose body
   does NOT contain the sig, exercising the first-emission
   `commentCreate` path.
4. Six test cases:
   - **B-001** — first-emit, no existing match: capture has exactly
     ONE entry; does NOT contain `meta: breadcrumb sig=`.
   - **B-002** — body-change update, canonical URL present: capture
     has exactly TWO entries; second entry contains
     `<!-- meta: breadcrumb sig=test/sig/ENG-111T comment_id=cmt-mock-001 -->`
     AND the canned URL substring AND the prose phrase
     `Re-emitted (body changed) under sig` referencing the sig.
   - **B-003** — identical-body update: capture has exactly ONE
     entry; does NOT contain `meta: breadcrumb sig=`; the entry
     ends in a `<!-- meta: reapplied at=… -->` footer (ENG-63
     contract preserved).
   - **B-004** — body-change update, `url` empty: capture has TWO
     entries; second entry contains the trailing breadcrumb marker
     but does NOT contain `https://`.
   - **B-005** — body-change update, breadcrumb `add_comment` post
     fails (stub flips `_eng111_force_create_failure=1` to make the
     SECOND `commentCreate` invocation return non-zero): the canonical
     `commentUpdate` body still appears in the capture file AND
     `add_or_update_comment` itself exits 0.
   - **B-006** — `comment-breadcrumb` metric emitted exactly once
     per body-change update (delta-based assert against
     `events.jsonl`).
5. Restores `linear_query` + `_resolve_issue_uuid` + `PIPELINE_DRY_RUN`
   to the pre-block values, mirroring ENG-63's cleanup pattern at
   `:752-762`.

Pass criterion: `bash bin/linear-test.sh` exits 0 with six new
`pass_at "ENG-111 B-…"` lines.

### Task 5 — `docs/pipeline-vocabulary.md`: regenerate

Run `bash bin/generate-vocabulary-doc.sh` to regenerate the file from
the updated registry. The diff is one new bullet listing `breadcrumb`
under the meta-kinds vocabulary.

Pass criterion: grep for `breadcrumb` in `docs/pipeline-vocabulary.md`
matches at least once (today it does not exist).

### Task 6 — `docs/runbooks/recovery.md`: extend §4 "Recency evidence"

Edit `docs/runbooks/recovery.md` §4. After the existing paragraph at
`:253` (ending with "...the most recent re-application moment (NOT the
original `createdAt`)."), insert a new paragraph:

> If `bash bin/linear.sh get-comments ENG-N | jq -r '.[] | select(.body | contains("meta: breadcrumb"))'`
> returns one or more breadcrumb comments referencing the canonical
> sig, those breadcrumbs carry a fresh `createdAt` for each body-change
> re-emission. The most recent breadcrumb's `createdAt` is the most
> recent body-change moment; the canonical comment (matched by sig in
> the breadcrumb marker) carries the current content.

Pass criterion: grep for `meta: breadcrumb` in
`docs/runbooks/recovery.md` matches once.

### Task 7 — `CLAUDE.md`: extend the "Issue stuck in `stage:X`" row

Edit `CLAUDE.md:772`. Append to that row, before its trailing `|`, a
sentence pointing operators at the breadcrumb signal (ENG-111). Mirror
the ENG-63 reference precedent already present:

`... — check the rotating footer (ENG-63) for the latest re-apply, or grep for the breadcrumb signal (ENG-111) for body-change history.`

Pass criterion: grep for `ENG-111` in CLAUDE.md matches at least once
inside the failure-mode table block.

## 6. Failure Mode → Test Map

| Failure mode | Pinned by |
|---|---|
| First-emission accidentally emits a breadcrumb | B-001 |
| Body-change update silently emits no breadcrumb | B-002 |
| Identical re-apply spuriously emits a breadcrumb | B-003 |
| URL fallback path drops the breadcrumb entirely | B-004 |
| Breadcrumb post failure swallows the canonical update | B-005 |
| Metric event skipped or doubled per body-change | B-006 |
| Registry drift (`breadcrumb` not in `meta_kinds`) | grep pass-criterion on Task 1 + Task 5 |
| Operator unaware of breadcrumb signal | grep pass-criteria on Task 6 + Task 7 |

## 7. Out of Scope (explicit)

- Migration of pre-cutover legacy dedup comments. New emissions only.
- Adding a lane-fence check inside `add_or_update_comment` itself
  (brainstorm Q-003).
- Aggregating breadcrumb counts in `bin/pipeline.sh status`
  (brainstorm Q-004).
- Extracting `_post_breadcrumb_for_canonical` helper (brainstorm
  Q-005). Inlined for symmetry with ENG-63 D-008.

## 8. Verification

Pre-commit (`bash .githooks/pre-commit`) runs the full `bin/*-test.sh`
suite; ENG-111 expects all current passes to keep passing AND
`bin/linear-test.sh` to gain six new passes (B-001..B-006). Manual
spot-check on first dispatch post-merge: verify a breadcrumb appears
for the next halt-body-change re-emission via
`bash bin/linear.sh get-comments <issue> | jq -r '.[] | select(.body | contains("meta: breadcrumb"))'`.
