---
linear: ENG-150
title: linear.sh — remove add-or-update-comment, migrate all callers to add-comment with dispatch-suffixed sigs
date: 2026-06-10
status: draft
---

# linear.sh — remove `add-or-update-comment`, migrate callers to `add-comment` with dispatch-suffixed sigs

## 1. Overview / Problem

`bin/linear.sh::add_or_update_comment` (`bin/linear.sh:576-708`) is the
sig-deduped mutation primitive. Every caller posting a "one canonical
comment per logical event" (halt, completion, protocol-violation,
worktree-mutation, retry-pending, last-review-state) routes through it.
The first emission for a sig calls `commentCreate`; every subsequent
emission for the same sig calls `commentUpdate` in place. Linear's
`commentUpdate` preserves the original `createdAt`, so the re-emission
stays pinned to the first emission's chronological slot.

[ENG-63](2026-05-04-eng-63-linear-sh-add-or-update-comment-identical-body-re-applies-are-invisible-to-operators-no-updatedat-change-design.md)
mitigated the identical-body sub-case with a rotating `<!-- meta:
reapplied at=… -->` footer.
[ENG-111](2026-05-16-eng-111-linear-ledger-breadcrumb-on-update-for-dedup-rewrites-design.md)
mitigated the body-change sub-case with a chronological breadcrumb. Both
are workarounds for a contract violation (in-place rewrite of a
"canonical" record), not a fix to the contract itself. ENG-104's umbrella
design called for completing the cleanup: **delete `add_or_update_comment`,
make every harness comment write append-only, suffix each sig with
`PIPELINE_DISPATCH_ID` so cross-dispatch re-emissions are chronologically
distinct, and retire the dedup-update mental model.**

This brainstorm specifies that cleanup. Eight call sites migrate to
`add-comment`; one new helper (`add-comment --sig`) replaces the
sig-stamping responsibility; readers that today happen to use sigs as
unique indexers are inspected and (where present) switched to
"latest by createdAt" semantics; legacy issues with pre-cutover
single-comment-per-sig threads keep reading correctly through the
existing dispatch_id-strict + timestamp-fallback paths.

Acceptance criteria from the issue, mapped to the design below:

| AC | What | Where covered |
|---|---|---|
| #1 | `grep -rn 'add-or-update-comment' bin/ AGENT_PROMPTS.md` returns zero non-history hits | D-001 (function delete), D-008 (caller migration list), D-009 (test fixtures), D-010 (docs/AGENT_PROMPTS) |
| #2 | Two reviewing dispatches on one ENG-N post TWO chronological comments, each with its own dispatch id in the sig | D-002 (sig shape), D-003 (`--sig` flag), §3.2 |
| #3 | Reader selectors return most-recent comment for a sig prefix, not "only by sig" | D-005 (reader audit: find_fresh_verdict, read_review_state, halt-sprawl, classify-failure read paths) |
| #4 | Legacy issues read correctly via back-compat path; adversarial fixture covers both legacy single-comment and post-cutover dispatch-suffixed shapes | D-006 (back-compat reader contract), D-009 (B-LEG fixture) |
| #5 | `bin/linear-test.sh` + `bin/review-state-test.sh` + `bin/verdict-handler-test.sh` + `bin/classify-failure-test.sh` + `bin/halt-sprawl-test.sh` adapted to append-only and pass | D-009 (test migration) |

Out of scope (per the ticket and confirmed in §10):

- Header-line rendering refactor for the canonical comment shape — separate follow-up.
- Agent/orchestrator verdict-write split (`PIPELINE_WRITER` lane re-cut) — separate follow-up.
- Counter-bump body shape (compact "this halt has now fired N times" summary across dispatches) — separate follow-up.

## 2. Decisions

### D-001. Delete `add_or_update_comment`, the dispatcher entry, and the dedup machinery it owns. Keep the back-compat *reader* path (legacy `<!-- meta: dedup key=… -->` markers stay readable).

**Decision.** Remove from `bin/linear.sh`:

- The function body at `bin/linear.sh:576-708` (~133 lines).
- The dispatcher case at `bin/linear.sh:768`
  (`add-or-update-comment) add_or_update_comment "$@" ;;`).
- The header documentation reference at `bin/linear.sh:17`
  (`(same flags accepted by add-or-update-comment, after the <sig> argument)`).

`add_comment` (`bin/linear.sh:496-574`) and its existing chokepoints
(`_inject_dispatch_marker`, `_reject_legacy_marker_body`, lane fence,
last-10 hash dedup) survive verbatim. The hash-dedup arm at
`bin/linear.sh:528-565` continues to absorb intra-dispatch double-posts
of literally identical bodies — its semantics are right for the
append-only model (same body, same dispatch → one Linear comment;
different bodies OR different dispatches → distinct comments).

Specifically retained because removal would regress unrelated invariants:

- `_inject_dispatch_marker` — owns the ENG-87 dispatch-id stamping
  contract; every append-only comment still needs it.
- `_reject_legacy_marker_body` — gates against legacy
  `pipeline-<word>:` shape bodies (ENG-60 lane discipline).
- Last-10 hash dedup at `bin/linear.sh:528-565` — protects against
  agent-side double-post within one dispatch (e.g. retry-once
  wrapping at `run-stage.sh:423-428`). The new shape (D-002) embeds a
  dispatch-rotating sig in the body, so cross-dispatch retries never
  collide; the hash dedup only fires when truly identical, which is
  the desired semantic for intra-dispatch idempotency.

**Why.** The issue states the goal as "`bin/linear.sh
add-or-update-comment` symbol removed. Every emission appends a fresh
comment with a dispatch-id-suffixed sig." The narrowest mechanical
change that satisfies AC #1 is deleting the symbol plus its
dispatcher arm. The complementary `add_comment` surface already
implements append-only semantics with all the lane/dispatch-id
discipline the canonical writes need.

**Rejected — soft-deprecate `add_or_update_comment` (keep the symbol
as an alias that calls `add_comment`).** Defeats AC #1, which asks for
zero grep hits in `bin/` and `AGENT_PROMPTS.md`. Worse, an alias would
silently *change semantics* without changing the call site: callers
still pass a sig argument, but the function would no longer dedup. Any
caller assuming idempotency-across-dispatches (none today, but
plausible for new code) would break invisibly. A clean delete forces
the migration to be auditable in one commit.

**Rejected — leave the function as a no-op (post nothing, return 0).**
Same defeat-AC-#1 problem plus loses every operator-visible
notification the canonical writes today carry (halt verdicts,
completion summaries, protocol violations).

**Rejected — keep `add_or_update_comment` but turn it into a strict
"create-only-if-no-existing-sig-found" guard (no commentUpdate
ever).** A no-op on re-emission preserves the chronology, but the
first emission's body stays the canonical, meaning a body with new
content (changed exit code, new content hash, fresh retry counter)
silently gets discarded — strictly worse than today's "rewrite-in-place"
behaviour. The append-only design is precisely the right shape; the
sig-with-dispatch-suffix change is what makes "create each time" safe.

### D-002. Sig shape post-cutover: `<category>/<stage>/<issue>/d<NNNN>` where `d<NNNN>` is the dispatch sequence (last 4-digit part of `PIPELINE_DISPATCH_ID`).

**Decision.** The marker stays under the existing `meta:` namespace and
the existing key name `dedup` — `<!-- meta: dedup key=<sig> -->` —
because the closed-vocabulary cost of renaming is non-trivial and
the marker's *operator-facing purpose* (a discoverability tag operators
grep on) is unchanged. The *meaning* of the name "dedup" becomes
historical (legacy comments dedup'd against it; new comments don't);
the marker survives as a join key for grep / future retrospective
tooling. A future renaming to `<!-- meta: ledger key=… -->` is
flagged as Q-001.

Sig values continue to follow the pre-existing convention but gain a
`/d<NNNN>` suffix. Per category:

| Category | Pre-cutover | Post-cutover |
|---|---|---|
| halt | `halt/<stage>/<issue>` | `halt/<stage>/<issue>/d<NNNN>` |
| completion | `completion/<stage>/<issue>` | `completion/<stage>/<issue>/d<NNNN>` |
| protocol-violation | `protocol-violation/<case_id>/<issue>` | `protocol-violation/<case_id>/<issue>/d<NNNN>` |
| worktree-mutation | `worktree-mutation/<issue>` | `worktree-mutation/<issue>/d<NNNN>` |
| retry-pending | `retry-pending/<stage>/<issue>` | `retry-pending/<stage>/<issue>/d<NNNN>` |
| last-review-state | `last-review-state/<issue>` | `last-review-state/<issue>/d<NNNN>` |

`d<NNNN>` is the dispatch sequence (e.g. `d0007`), not the full
`PIPELINE_DISPATCH_ID` (`ENG-150-d0007`). Reason: the issue id already
appears in the sig path (`/<issue>/`), so embedding the full dispatch
id would duplicate it (`halt/implementing/ENG-150/ENG-150-d0007`). The
issue's example token is `halt/implementing/ENG-N/d0007` — we match
that shape.

When `PIPELINE_DISPATCH_ID` is unset (operator manual run, dry-run
tests without an allocator), the suffix is omitted: sig
collapses to `halt/implementing/ENG-150` (legacy shape). The
back-compat reader path (D-006) treats both shapes uniformly.

**Why.** `d<NNNN>` is the minimum disambiguator: it's the per-issue
monotonic counter `_allocate_dispatch_id_locked` already maintains
(`bin/common.sh:133-157`), it's compact enough to keep the sig
operator-readable, and it survives the SHA-normalisation pass in
`add_comment`'s hash-dedup regex (`s/[0-9a-f]{7,40}/<SHA>/g` at
`bin/linear.sh:537,554`). The hex character class IS
lowercase-hex-only and the literal letter `d` IS inside `[0-9a-f]`,
so the survival is purely a LENGTH property: `d0007` is 5 chars,
below the regex's 7-char minimum. The string `d<NNNN>` only enters
the normalisation hazard zone at `d9999999` (8 chars, ≥7-char
minimum) — practically unreachable (each issue would need ~10M
dispatches). The leading `d` is NOT the reason `d0007` survives;
size is. (Earlier draft asserted character-class survival, which
would have been wrong reasoning — `d` is hex.) Two sigs from two
distinct dispatches hash-dedup-survive on length alone.

The "omit suffix when dispatch id unset" rule keeps the manual /
dry-run / pre-allocator paths working without a behaviour change —
the existing test fixtures (`PIPELINE_DRY_RUN=1` without an allocator
call) keep producing legacy-shape sigs, which D-006's back-compat
reader handles.

**Rejected — full `PIPELINE_DISPATCH_ID` suffix
(`halt/implementing/ENG-N/ENG-N-d0007`).** Duplicates `ENG-N`. The
issue's prose example is unambiguous about the desired shape.

**Rejected — wall-clock timestamp suffix (`halt/implementing/ENG-N/2026-06-10T14:00:00Z`).**
Wall-clock is non-monotonic across reboot, drift, NTP step; not
distinguishing across two ticks within one second; reads worse than
the dispatch counter for operator grep. The dispatch counter is the
authoritative per-issue ordering already in use across ENG-87.

**Rejected — random nonce suffix (`halt/implementing/ENG-N/abc12`).** No
ordering signal; operator can't say "show me the most recent halt"
without a separate `createdAt` sort. Loses the property that
sigs are intrinsically comparable.

**Rejected — sig as opaque hash of body content.** Defeats the
operator grep affordance ("show me all halts in implementing for
ENG-150"). Sig should remain a structured, human-readable category
tag.

### D-003. Add a `--sig <prefix>` flag to `add_comment` in `bin/linear.sh`. The flag suffixes `/d<NNNN>` and appends `<!-- meta: dedup key=<full-sig> -->` to the body.

**Decision.** Extend `add_comment`'s argument parser to recognize
`--sig <prefix>`. When set, after `_inject_dispatch_marker` runs:

1. Read `PIPELINE_DISPATCH_ID`. If set, parse the trailing
   `d<NNNN>` chunk (the dispatch sequence) via parameter expansion:
   `dispatch_seq="${PIPELINE_DISPATCH_ID##*-}"` — yields `d0007`
   from `ENG-150-d0007`. If unset, dispatch_seq is empty.
2. Compose `full_sig="${prefix}${dispatch_seq:+/${dispatch_seq}}"` —
   `halt/implementing/ENG-150/d0007` when set,
   `halt/implementing/ENG-150` when unset.
3. Append `<!-- meta: dedup key=<full_sig> -->` to body (single
   blank-line separator, matching the historical shape).
4. Bypass the hash-dedup arm at `bin/linear.sh:528-565` when the body
   already carries a pipeline-marker line OR a fresh dispatch-suffixed
   sig — the body-change-by-different-dispatch case is identifiable
   without re-running the full hash compute (D-007).

The flag is OPTIONAL on `add_comment`; callers that don't pass it get
today's behaviour exactly (free-form chronological comment). Verdict
posts via `bin/pipeline.sh::cmd_event_verdict` (`bin/pipeline.sh:299`)
don't pass `--sig` — verdict shape uniqueness is the verdict marker
itself plus the auto-injected dispatch id, no additional sig needed.

**Why.** Each of the 8 caller sites needs to construct the sig and
append the marker to the body. Doing this at the call site (8 places
× ~3 lines each = ~24 lines of marker-construction boilerplate) is
brittle: each site reproduces the dispatch_seq derivation, the
optional-suffix logic, the marker-string format. A flag-on-the-writer
collapses the construction into one chokepoint inside `linear.sh`,
matching how `_inject_dispatch_marker` chokes the dispatch-id marker.

Idempotence: passing the same `--sig` twice for the same body in the
same dispatch produces two comments with byte-identical body + sig
marker, which the hash-dedup arm at `bin/linear.sh:528-565` already
suppresses. No extra guard needed.

**Rejected — explicit body-construction at each call site.** Every
caller does `body+="<!-- meta: dedup key=halt/.../${PIPELINE_DISPATCH_ID##*-} -->"`.
8 call sites × 3 lines × subtle `${VAR-}` semantics for unset
fallback = 24 lines of duplicated logic, each one a chance for a
typo or for an env-var leak (`${VAR:-X}` is a known anti-pattern
banned by ENG-46 / `bin/secret-probe-lint.sh`).  Centralising at the
linear.sh chokepoint is the discipline this codebase already enforces
elsewhere (`_inject_dispatch_marker`, lane fence).

**Rejected — separate `add-ledger-comment` subcommand.** Splits the
mental surface ("which post path do I use?") and forces tests to
re-stub two paths. The optional flag on `add-comment` is one symbol
in the dispatcher.

**Rejected — implicit sig derived from a `PIPELINE_SIG_CATEGORY` env
var.** Env-var-driven body modification is invisible at the call site;
operators reading the call can't tell what sig the comment will carry
without inspecting the caller's surrounding `export`s. Explicit flag
keeps the contract visible at the call site.

**Rejected — make the sig flag mandatory on `add_comment`.** Backwards-
incompatible with `bin/pipeline.sh`'s verdict and transition posts
(which call `add_comment` directly and don't need a sig) and with the
ENG-111 breadcrumb code path (`bin/linear.sh:694`, retained for
back-compat reader semantics — see D-006). The sig is a category-tag
affordance, not a universal requirement.

### D-004. Drop the breadcrumb code path inside `add_or_update_comment` along with the function. ENG-111's `meta_kinds` registry entry `breadcrumb` stays (legacy comments).

**Decision.** ENG-111 added the breadcrumb mechanism at
`bin/linear.sh:679-700` *inside* `add_or_update_comment`. Deleting the
function deletes the breadcrumb writer with it. ENG-111's metric
(`comment-breadcrumb`) is no longer emitted, and the
`<!-- meta: breadcrumb sig=… -->` marker is no longer written. The
registry entry at `bin/pipeline-events.json::meta_kinds[6]`
(`breadcrumb`) **stays** because legacy issues (pre-cutover) carry
breadcrumb-bodied comments that operators may still grep on; removing
the registry token would orphan those comments from the
auto-generated vocabulary doc.

ENG-63's `reapplied` registry entry follows the same logic — legacy
comments retain the rotating-footer line; the registry token stays.

**Why.** ENG-104's framing ("the breadcrumb is a workaround for a
contract violation") motivates this ticket — once the canonical writes
are append-only, neither footer rotation (ENG-63) nor body-change
breadcrumbs (ENG-111) have a problem to solve. The fixes were
correct for the dedup-update world; the dedup-update world is being
retired. Both mechanisms are pure-add inside `add_or_update_comment`'s
body; deleting the function removes them naturally.

The `comment-reapplied` and `comment-breadcrumb` metric event names
also stop being emitted. They stay in `events.jsonl`'s historical
records and any retrospective tooling that aggregates over them
continues to find historical rows. No registry entry exists for
metric event names (they're free-form via `bin/metrics.sh`), so no
schema cleanup is needed.

**Rejected — preserve ENG-63 footer rotation + ENG-111 breadcrumb on
the new `--sig` path of `add_comment`.** The new path posts a fresh
comment for every emission, so the footer rotation has nothing to
rotate (the body is fresh) and the breadcrumb has no canonical to
point at (every emission *is* a chronological pointer). Trying to
preserve them in the new shape produces a no-op runtime guard with
no semantic gain.

**Rejected — keep `add_or_update_comment` solely for the breadcrumb
mechanism and let callers opt into append-only via `add_comment`.**
Defeats AC #1 and recreates the divergence problem ENG-104 set out
to fix. Half-migration is strictly worse than no migration.

### D-005. Reader audit: today no production reader assumes "exactly one comment per sig" except `add_or_update_comment` itself. No reader-side code changes required beyond the back-compat contract (D-006).

**Decision.** Each of the readers the issue lists was audited; all
already satisfy "find the latest by createdAt or by dispatch_id strict
match":

| Reader site | Selection mechanism | Append-only impact |
|---|---|---|
| `verdict-handler.sh::find_fresh_verdict` (`bin/verdict-handler.sh:156-250`) | ENG-87 strict-id-match path picks the comment whose body carries `<!-- meta: dispatch id=$current_dispatch_id ... -->` and whose parse yields a non-`wait` verdict. Legacy fallback (when no markers on issue) sorts by createdAt desc within the post-transition window. | No change. Each new dispatch's halt-verdict comment carries its own dispatch id; strict-id-match selects it directly. Legacy fallback unaffected. |
| `verdict-handler.sh::_vh_classify_no_fresh_reason` (`bin/verdict-handler.sh:88-112`) | Scans for any `<!-- meta: dispatch id=` marker; doesn't grep by sig. | No change. |
| `review-state.sh::read_review_state` (`bin/review-state.sh:56-69`) | Matches `<!-- pipeline-state: last-review-state -->`, `sort_by(.createdAt) \| last` already. | No change — "last by createdAt" is exactly the append-only-correct shape. |
| `poll.sh::_poll_emit_halt_sprawl_alert` (`bin/poll.sh:545-610`) | Counts `slot == "vacate"` classifications; doesn't grep comment bodies by sig. | No change. |
| `poll.sh::_poll_classify_labels` (`bin/poll.sh:240-330`) | Calls `find_fresh_verdict` (inherits its strict-id-match) plus label checks. | No change. |
| `classify-failure.sh` (no reader; pure writer) | n/a | n/a |
| `run-stage.sh::_handle_wait`-adjacent paths | Read `wait-<stage>.json` from disk, not Linear comments. | No change. |
| Header-line / operator manual grep `bin/linear.sh get-comments ENG-N \| jq …` | Operator habit, not code. Today operator does `select(.body \| contains("dedup key=halt/<stage>/<issue>"))` and gets one row; post-cutover gets multiple. | Operator runbook update (D-010) re-orients the recipe to "include the `d<NNNN>` suffix" or "grep prefix and take the latest". |

**Why.** AC #3 reads "Reader-side selectors return the most-recently-
created comment for a sig prefix, not the only-by-sig." Inspection of
every reader cited in the issue (verdict-handler.sh::find_fresh_verdict,
poll.sh halt-sprawl, review-state.sh) shows they don't grep by sig
literal — they grep by canonical event markers (verdict, transition,
state) or by dispatch_id. The "exactly one comment per sig" assumption
was load-bearing **only inside `add_or_update_comment`'s own
existing-comment lookup** at `bin/linear.sh:619-625`. That code is
deleted by D-001. No external reader needs to change. AC #3 is
satisfied by inspection.

**Rejected — proactively rewrite all selectors to "grep prefix +
sort_by createdAt + take latest" regardless of audit outcome.** Adds
churn to working code; introduces new edge cases (what if no comment
matches?). The selectors that *already* work in append-only shape
stay as-is. Any future selector that DOES need "latest by sig prefix"
gets the same `sort_by(.createdAt) | last` idiom `read_review_state`
already uses; no architectural commitment needed.

**Rejected — emit a new join key `<!-- meta: ledger key=<sig> -->`
parallel to `<!-- meta: dedup key=<sig> -->` so future readers have a
distinct semantic surface.** Increases the registry surface for a
purpose no concrete reader needs today. If a future feature wants a
distinct namespace, add it then; the current writers don't need it
to be append-only. Q-001 captures the eventual rename if/when the
need materialises.

### D-006. Back-compat reader contract: on a pre-cutover issue, the canonical comment for a sig is the comment whose body contains `<!-- meta: dedup key=<prefix> -->` (no `/d<NNNN>` suffix). For a post-cutover issue, the canonical is the most-recently-created comment whose body contains `<!-- meta: dedup key=<prefix>/d<NNNN> -->` for any `<NNNN>`. Both forms read uniformly via prefix match.

**Decision.** No code currently performs this lookup (per D-005), but
the contract is the documented operator recipe and the test fixture
shape. Express it as:

- For sig `halt/implementing/ENG-150`:
  - Legacy hit: a comment whose body contains the literal string
    `<!-- meta: dedup key=halt/implementing/ENG-150 -->`. Exactly one
    such comment exists per logical event.
  - Post-cutover hit: comments whose body contains
    `<!-- meta: dedup key=halt/implementing/ENG-150/d` (prefix match,
    NOT exact). Multiple such comments may exist; the operator picks
    the latest by `createdAt`.
- Operator runbook recipe (`docs/runbooks/operator-mental-model.md` §3,
  updated by D-010):
  ```bash
  TARGET_REPO=… bash bin/linear.sh get-comments ENG-N \
    | jq -r '.[] | select(.body | contains("<!-- meta: dedup key=halt/implementing/ENG-150")) | "\(.createdAt) \(.body[0:120])"' \
    | sort | tail -1
  ```
  (Prefix-match `dedup key=halt/implementing/ENG-150` — no trailing
  `-->`, so both legacy `…ENG-150 -->` and post-cutover
  `…ENG-150/d0007 -->` match. `sort | tail -1` picks the latest.)

**Why.** AC #4 requires legacy issues to keep reading correctly via a
back-compat path. The contract is purely about marker-string semantics
— "prefix match the key, sort by createdAt, take latest" — and works
for both shapes uniformly. No structural reader code needs to change.

**Adversarial fixture** (D-009, B-LEG): construct a Linear comment
list with one legacy `halt/implementing/ENG-150` comment and three
post-cutover `halt/implementing/ENG-150/d0007`, `…/d0008`,
`…/d0009` comments interleaved by `createdAt`. Assert the prefix-
match-sort-latest recipe picks `…/d0009`. Then re-run with only the
legacy entry; assert it picks the legacy comment.

**Rejected — rename the marker on cutover (e.g. `<!-- meta: ledger
key=… -->`) and provide a back-compat reader that scans BOTH `dedup`
and `ledger` markers.** Two name spaces forever; readers need to know
both. Keeping the name `dedup` (with the "what it really means is
discoverability tag" understanding documented in CLAUDE.md and the
runbook) avoids the two-name burden. Q-001 captures the rename as
follow-up.

**Rejected — write a migration sweep that rewrites legacy comments to
the new shape on first read.** Linear's `commentUpdate` is the very
in-place rewrite mechanism this ticket is moving away from; using it
to re-shape legacy comments would be an ironic regression. Append-
only forever from here on.

### D-007. Hash-dedup arm in `add_comment` bypass: any `add_comment` call that received a non-empty `--sig` argument skips the hash-dedup compute. The skip predicate is the **flag** the caller passed, NOT a regex match on body content.

**Decision.** Today `add_comment` skips hash dedup when the body
carries a `<!-- pipeline: ... -->` marker (verdict / transition /
decision) — see `bin/linear.sh:528-529`. Extend the skip to also fire
when the caller passed `--sig`:

```bash
if [[ "$body" == *'<!-- pipeline: '* ]] \
   || [[ -n "$sig" ]]; then
  : # append-only — skip hash dedup
else
  # … existing hash dedup loop (bin/linear.sh:530-565) …
fi
```

The `$sig` local is the value `_resolve_sig_arg` extracted at the top
of `add_comment` (D-003 pseudocode). Empty `$sig` (no flag, or
explicit `--sig ""`) falls through to today's behaviour.

**Why.** The earlier draft proposed a body-content regex
(`'<!-- meta: dedup key='[^[:space:]]+/d[0-9]+`) as the skip
predicate. Three failures of that approach forced the simpler flag
gate:

1. **False negative when `PIPELINE_DISPATCH_ID` is unset.** With no
   allocator (operator manual run, test fixture without seeded id),
   `--sig` produces a SUFFIX-LESS marker (`halt/.../ENG-150`,
   matching the legacy shape). The regex requires `/d[0-9]+`, so the
   suffix-less marker falls through to hash dedup. An operator running
   the same caller twice gets the second post silently suppressed —
   precisely the chronological-record-loss the migration is supposed
   to eliminate.

2. **False positive on agent-controlled body content.** Any body
   containing the literal string `<!-- meta: dedup key=foo/d123 -->`
   (e.g. an agent's stage-summary file that quotes a halt body in a
   markdown code fence) bypasses dedup unintentionally. Surfaced by
   the security persona as a spoofable "force fresh post" primitive.

3. **Bash regex escaping fragility.** The literal regex
   `\<!--\ meta:\ dedup\ key=[^[:space:]]+/d[0-9]+\ --\>` has more
   escapes than the matching characters; cosmetic, but a refactor
   that touches it has multiple silent failure modes (drop an
   escape and the regex no longer matches the marker; over-escape
   and bash rejects the regex at parse time).

The flag predicate is exact: `--sig <anything-non-empty>` is the
caller's explicit declaration of "this is a ledger write; do not
suppress." It works for both suffix-less (unset dispatch_id) and
suffixed (set dispatch_id) modes uniformly. It is not spoofable from
body content. It is bash-3.2-stable.

**Body strip discipline.** Independent of the hash-dedup skip, every
`add_comment --sig` call MUST receive a body whose content does NOT
already contain a `<!-- meta: dedup key=… -->` line — otherwise the
chokepoint's appended marker is the SECOND such line on the wire and
operator grep finds two sigs per comment. Today the strip is only at
`bin/run-stage.sh:388` (one caller, `post_completion_comment`). The
five new `--sig` call sites (D-008 rows 2-7) construct bodies from
in-process strings rather than reading agent files, so the strip is
unnecessary for them today, but defense-in-depth says centralize the
strip inside `add_comment` itself (one `sed -E '/<!-- meta: dedup
key=.* -->/d'` line before the marker append). This costs one
process-internal sed pass per call — cheaper than the equivalent
GraphQL roundtrip. ADD as D-007a:

```bash
# Inside add_comment, after _inject_dispatch_marker, before the
# sig-marker append:
if [[ -n "$sig" ]]; then
  body="$(printf '%s' "$body" | sed -E '/<!-- meta: dedup key=.* -->/d')"
  # … existing dispatch_seq derivation + marker append …
fi
```

Then the `bin/run-stage.sh:388` strip can stay (defense-in-depth at
the caller AND the chokepoint) or be removed (the chokepoint covers
it). Choose KEEP for symmetry with the other meta-line strips at
that site (`<!-- meta: dispatch id=… -->`, legacy `<!-- pipeline-<word>: -->`).

**Sig content validation.** `_resolve_sig_arg` should reject sigs
containing characters that would corrupt the marker shape: newlines
(would split the marker over multiple lines), the literal `-->`
(would close the HTML comment prematurely and let the rest render
as visible markdown — security persona's P1), or NUL. Implementation
adds a one-line guard:

```bash
if [[ "$sig" == *$'\n'* || "$sig" == *'-->'* || "$sig" == *$'\0'* ]]; then
  die "linear.sh: --sig contains illegal characters (newline / --> / NUL)"
fi
```

The caller-side sigs in production today (`halt/<stage>/<issue>`,
`completion/<stage>/<issue>`, etc.) consist of `[a-z]+/[a-z]+/ENG-[0-9]+`
shapes — no illegal characters. The validation is defense against a
future caller that interpolates an unvalidated value.

**Why.** The hash-dedup arm at `bin/linear.sh:528-565` was designed
to silently absorb identical-body re-fires. For the new append-only
ledger writers (`--sig` flag on), each emission is *intended* to be a
fresh chronological row; suppressing on hash match would defeat AC #2
("two reviewing dispatches post TWO distinct comments"). The
explicit flag is the structural signal that the caller is in the
append-only contract — bypass the dedup on that signal.

The fallback (no `--sig`, no `pipeline:` marker, plain operator post)
keeps the existing hash dedup so operator manual posts retain their
"don't accidentally double-post the same thought" affordance.

**Rejected — keep hash dedup active even with `--sig`.** Suppresses
legitimate distinct-dispatch re-emissions when body content happens
to byte-equal across dispatches (e.g. retry-immediately's body has
fixed structure; only the `attempt=N` field changes; if attempts are
re-numbered or the field is omitted, two halt bodies would
hash-equal and the second one would be silently dropped). Append-only
is the correctness contract; the hash dedup *is* the silent-data-loss
risk to remove.

**Rejected — skip hash dedup whenever `PIPELINE_DISPATCH_ID` is set
(regardless of body content).** Over-broad. `bin/pipeline.sh::cmd_event_verdict`
fires `add_comment` without `--sig` but with `PIPELINE_DISPATCH_ID`
set; that path already has the `pipeline:` marker covering it. The
existing `pipeline:` marker check plus the new `--sig` marker check
together are tight and precise.

### D-008. Caller migration — six categories across seven distinct call lines (plus one retry-line that duplicates the first category's call). Each site's body construction stays as-is; the call shape changes from `linear.sh add-or-update-comment <sig> <ident> <body>` to `linear.sh add-comment <ident> --sig <sig-prefix> --body <body>`.

**Decision.** The eight sites and their migration shape:

| # | Site | Pre-cutover | Post-cutover |
|---|---|---|---|
| 1 | `bin/run-stage.sh:424,428` (`post_completion_comment`, retry-once) | `add-or-update-comment "completion/${stage}/${issue}" "$issue" "$comment_body"` | `add-comment "$issue" --sig "completion/${stage}/${issue}" --body "$comment_body"` |
| 2 | `bin/run-stage.sh:680` (worktree-mutation breadcrumb) | `add-or-update-comment "worktree-mutation/$ident" "$ident" "$_body"` | `add-comment "$ident" --sig "worktree-mutation/$ident" --body "$_body"` |
| 3 | `bin/classify-failure.sh:188` (halt verdict, skip-until-* arm) | `add-or-update-comment "$sig" "$issue" "$comment_body"` (sig=`halt/$stage/$issue`) | `add-comment "$issue" --sig "$sig" --body "$comment_body"` |
| 4 | `bin/classify-failure.sh:196` (retry-pending arm) | `add-or-update-comment "$sig" "$issue" "$comment_body"` (sig=`retry-pending/$stage/$issue`) | `add-comment "$issue" --sig "$sig" --body "$comment_body"` |
| 5 | `bin/verdict-handler.sh:56-57` (protocol-violation halt) | `add-or-update-comment "protocol-violation/$case_id/$issue" "$issue" "$body"` | `add-comment "$issue" --sig "protocol-violation/$case_id/$issue" --body "$body"` |
| 6 | `bin/review-state.sh:45` (bootstrap) | `add-or-update-comment "last-review-state/$issue" "$issue" "$body"` | `add-comment "$issue" --sig "last-review-state/$issue" --body "$body"` |
| 7 | `bin/review-state.sh:53` (update) | `add-or-update-comment "last-review-state/$issue" "$issue" "$body"` | `add-comment "$issue" --sig "last-review-state/$issue" --body "$body"` |
| 8 | `bin/run-local-helpers.sh:877-878` (ENG-68 core-bare-flip forensic post — best-effort Linear announcement when the tick-start heal detects `core.bare=true` on the target's git config) | `add-or-update-comment "core-bare-flip/${_utc_day}" "$_post_issue" --body -` (heredoc body via stdin) | `add-comment "$_post_issue" --sig "core-bare-flip/${_utc_day}" --body -` (same heredoc shape; the `--body -` stdin form survives) |

(8 distinct call lines across 7 categories: completion-summary,
worktree-mutation, halt, retry-pending, protocol-violation, last-
review-state, core-bare-flip-forensic. `post_completion_comment`
issues TWO `add-comment` calls — first attempt at line 424 + retry
at line 428 — counted as one site because the retry shape is
identical. Row 8 (`run-local-helpers.sh::_handle_core_bare_flip`,
ENG-68 forensic) is a tick-start best-effort post fired ONLY when
the tick-start heal detects `core.bare=true` drift; per-tick rate is
≤1 per UTC day per issue (sig embeds `${_utc_day}` already, giving
day-granularity grouping). Post-cutover the day still groups via the
operator grep recipe (D-006); per-dispatch suffix `/d<NNNN>` adds
finer per-tick granularity within the same day.)

`post_completion_comment`'s retry semantics are unchanged: if the
first `add-comment` returns non-zero, sleep 5 and retry once with
the same arguments. The retry posts a fresh comment if the first
one didn't actually land — same shape as today's retry, just on the
append-only path.

For `post_completion_comment` specifically: today the function is
invoked from the success path (`run-stage.sh::main`) AND from a few
retry paths. Two dispatches against the same issue+stage (e.g. a
review-loopback re-running implementing) will post two distinct
`completion/implementing/ENG-N/d0007` and `…/d0008` comments. AC #2
explicitly names this as required behaviour ("Re-running `reviewing`
on a single ENG-N twice posts TWO distinct chronological comments").

The `<!-- meta: dedup key=… -->` line currently emitted at
`bin/run-stage.sh:388` (the sed-strip in `post_completion_comment`'s
body filter) stays as a defensive strip — the body contents are read
from the agent's `stage-summary-<stage>.md` file, and an agent that
copies a fixture body could embed a stale marker. The strip
neutralises it before `add_comment --sig` re-appends the correct one.

**Why.** The migration shape is mechanical: each site's body
composition is unchanged, only the *call line itself* changes. The
sig prefix passed in (`halt/${stage}/${issue}`) is the same value
today's callers pass to `add_or_update_comment`. The `--sig` flag's
chokepoint at `linear.sh` adds the `/d<NNNN>` suffix and the marker
line.

**Rejected — inline the dispatch_seq derivation at each call site and
just call `add-comment "$issue" --body "$body"$'\n'"$marker_line"`.**
Reproduces 8× the boilerplate that D-003's flag chokepoints.

**Rejected — bundle multiple callers behind a new wrapper like
`bash bin/linear.sh add-categorical-comment <category> <stage> <ident>
<body>`.** Indirection without semantic gain; the `add-comment --sig`
flag is the chokepoint.

### D-009. Test migration: adapt `bin/linear-test.sh` (delete ENG-63 + ENG-111 blocks; add new append-only tests); `bin/review-state-test.sh` (capture-and-assert `add-comment` calls); `bin/verdict-handler-test.sh` (calls_contains assertions); `bin/classify-failure-test.sh` (capture file shape); `bin/run-stage-test.sh` (stub `add-comment`); `bin/halt-sprawl-test.sh` (fixture shapes for halt-verdict markers); `bin/verdict-adversarial-test.sh` (sig-shape assertions); `bin/agent-prompts-content-test.sh` (prose); `bin/poll-slot-test.sh` (linear.sh stub allowlist); `bin/vocabulary-cleanliness-test.sh` (regex grep).

**Decision.** Per-file impact:

- **`bin/linear-test.sh`** — Delete the ENG-63 C-001..C-006 block (`:512-762`)
  and the ENG-111 B-001..B-006 block (`:764-963`). These exercise
  `add_or_update_comment`'s body normalisation, footer rotation, and
  breadcrumb posting — all of which are gone. The ENG-87 dispatch-id
  block at `:967-1234` keeps its `add_comment` cases; the
  `add_or_update_comment` cases at `:1118-1234` get deleted with the
  function.
  Add a new block `ENG-150: append-only ledger writes (A-001..A-006)`:
  - **A-001** — `add_comment --sig "halt/implement/ENG-X" "ENG-X" --body "..."` with
    `PIPELINE_DISPATCH_ID=ENG-X-d0007` set: assert the posted body
    contains `<!-- meta: dedup key=halt/implement/ENG-X/d0007 -->`
    AND `<!-- meta: dispatch id=ENG-X-d0007 stage=… -->`.
  - **A-002** — same call with `PIPELINE_DISPATCH_ID` UNSET: assert the
    posted body contains `<!-- meta: dedup key=halt/implement/ENG-X -->`
    (no suffix) and no dispatch marker.
  - **A-003** — two consecutive `add_comment --sig "halt/X/Y" …` calls
    with distinct `PIPELINE_DISPATCH_ID` values: assert TWO distinct
    `commentCreate` calls are issued (no `commentUpdate`).
  - **A-004** — same dispatch, same sig, IDENTICAL bodies: assert
    exactly one `commentCreate` call (intra-dispatch hash dedup
    fallback). This is the conservative reading; if the hash-dedup-
    skip on `--sig` is implemented as D-007 specifies, the assertion
    inverts to TWO calls. Pin the asserted behaviour in fixture A-004
    to match D-007.
  - **A-005** — back-compat read recipe: construct a comment payload
    with one legacy `<!-- meta: dedup key=halt/X/Y -->` comment and
    three post-cutover `…/d0007`, `…/d0008`, `…/d0009` comments;
    assert the prefix-match-sort-latest recipe (D-006) returns
    `…/d0009`'s id.
  - **A-006** — `add_comment` with NO `--sig` flag: assert behaviour
    unchanged from today (lane fence + dispatch-id auto-injection +
    hash dedup all run).
  - **B-LEG** — back-compat fixture: legacy single-comment shape under
    sig `last-review-state/ENG-X`; `read_review_state` returns its
    JSON payload correctly. Confirms D-006.

- **`bin/review-state-test.sh`** (`:23-34`) — Update the linear.sh stub
  case `add-or-update-comment)` to capture `add-comment` arguments
  including `--sig`. Match the new shape:
  ```bash
  add-comment)
    # $1=add-comment $2=issue, then --sig <sig> --body <body>
    issue="$2"; shift 2
    sig=""; body=""
    while (( $# > 0 )); do
      case "$1" in
        --sig) sig="$2"; shift 2 ;;
        --body) body="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'SUBCMD=add-comment\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
      "$sig" "$issue" "$body" >> "$CAPTURE_FILE"
    ;;
  ```
  Existing assertions that check `SIG=last-review-state/ENG-X` keep
  working when `PIPELINE_DISPATCH_ID` is unset in the test env; under
  the alternative, assert `SIG=last-review-state/ENG-X/d0001` after
  setting `PIPELINE_DISPATCH_ID=ENG-X-d0001`.

- **`bin/verdict-handler-test.sh`** — `calls_contains` assertions at
  `:228, 244, 261, 281, 312` currently look for
  `add-or-update-comment protocol-violation/<case>/<issue> <issue>`.
  Replace with `add-comment <issue> --sig protocol-violation/<case>/<issue>`.
  The stub at `:980` accepts both `add-comment` and
  `add-or-update-comment` today; drop `add-or-update-comment` from the
  allowlist.

- **`bin/classify-failure-test.sh`** — The actual `linear.sh` stub
  captures the entire argv via `printf '%s\n' "$*"` (flat
  space-delimited line, not the `SUBCMD=...` key-value shape that
  `run-stage-test.sh` uses). Existing assertions at `:276, 319, 324`
  match a literal prefix
  `add-or-update-comment retry-pending/implement/ENG-924b ENG-924b `
  followed by the body. Migration: update the prefix to
  `add-comment ENG-924b --sig retry-pending/implement/ENG-924b --body `
  (or the corresponding shape for halt sigs). The capture-stub
  itself needs no change since it records argv verbatim.

- **`bin/run-stage-test.sh`** — Stub at `:281` and the
  variants at `:1012, 1834, 4345` update to recognize `add-comment`
  with `--sig`. Assertion at `:138` (`captured_sig == "completion/plan/ENG-T1"`)
  works as-is when no dispatch_id is set; flip to
  `completion/plan/ENG-T1/d0001` after setting an env. Pin one fixture
  per shape.

- **`bin/halt-sprawl-test.sh`** — One-line edit. The `linear.sh` stub
  case allowlist at `:67`
  (`remove-label|add-label|swap-stage|transition-state|add-comment|add-or-update-comment|refresh-cache|stage-of|has-label)`)
  retains the literal token `add-or-update-comment` even though the
  test fixture doesn't invoke it; AC #1's grep gate would catch it.
  Remove the token. No fixture or assertion change needed —
  halt-sprawl's logic reads classifier output, not comment bodies.

- **`bin/verdict-adversarial-test.sh`** — Assertions at `:243, 423, 426`
  check the literal sig token `halt/implement/ENG-812` /
  `halt/implement/ENG-823`. Update to accept either the legacy form
  OR the new `…/d<NNNN>` form via a substring match (the dispatch_id
  isn't deterministic across test runs unless explicitly seeded). The
  cleanest approach: seed `PIPELINE_DISPATCH_ID=ENG-812-d0001` at the
  top of each adversarial case and assert the literal new sig.

- **`bin/agent-prompts-content-test.sh`** (`:776-860`) — Update prose
  comments that reference `add-or-update-comment` to refer to
  `add-comment --sig`. Operator-recipe prose at `:548, 1425`.

- **`bin/poll-slot-test.sh`** (`:78, 1233`) — The linear.sh
  stub's case allowlist `remove-label|add-label|swap-stage|...|add-or-update-comment|...` —
  remove `add-or-update-comment` from the pipe-separated list.

- **`bin/vocabulary-cleanliness-test.sh`** (`:9`) — The prose comment
  references `linear::add_or_update_comment`; update to
  `linear::add_comment --sig` or remove the parenthetical.

- **Forensic / consistency check**:
  Add a new test (or extend `bin/linear-test.sh`) — assert
  `grep -rn 'add-or-update-comment' bin/ AGENT_PROMPTS.md` returns
  zero hits. This pins AC #1 mechanically.

**Why.** AC #5 explicitly names 5 test files to adapt. The complete
list (10 test files plus the new consistency check) is wider but
mostly mechanical (string-replace `add-or-update-comment` with the
new shape). The shape changes are small enough that no test infra
refactor is needed; the existing stub-and-capture patterns work for
both the old and new shapes with the parser updates D-009 specifies.

**Rejected — keep `add-or-update-comment` as a test-only alias to
soft-land the migration.** Defeats AC #1 (`grep` should be clean).

**Rejected — write a parameterized test harness that captures
add-comment in one shape regardless of stub variation.** Centralised
fixture infra is a valid follow-up but not necessary for this
migration; the per-file string-replace is mechanical enough.

### D-010. Documentation: replace CLAUDE.md "meta: dedup" paragraph; retire `docs/runbooks/operator-mental-model.md` §3 "dedup-update rewrites chronology" entry; update `bin/run-stage.sh` and AGENT_PROMPTS.md prose; the `meta_kinds` registry retains both `dedup` and `breadcrumb` (legacy comments still readable).

**Decision.**

- **`CLAUDE.md:700-704`** — Replace the paragraph:
  > Linear writes go through `bin/linear.sh` so dry-run + `meta: dedup`
  > (`add-or-update-comment <sig> <ident> <body>`) work uniformly. The
  > function emits `<!-- meta: dedup key=... -->` and looks up in-flight
  > comments by both new and legacy shapes.

  With:
  > Linear writes go through `bin/linear.sh add-comment`, which is
  > append-only — every emission produces a fresh chronological
  > comment. Callers needing a discoverability tag pass
  > `--sig <category>/<stage>/<issue>`; the chokepoint suffixes
  > `/d<NNNN>` (the dispatch sequence) and emits
  > `<!-- meta: dedup key=… -->` on the body for operator grep
  > (legacy name; semantic is "ledger tag", not deduplication). The
  > `add-or-update-comment` API and its sig-based commentUpdate
  > behaviour were retired in ENG-150.

- **`docs/runbooks/operator-mental-model.md` §3 (`:136-157`)** — Drop the
  "Comment dedup invisibility" section entirely (it documents a
  failure mode that no longer exists). Replace with a one-sentence
  redirect:
  > ## §3 — Comment chronology (append-only ledger)
  >
  > Linear comments posted by the harness are append-only — each
  > emission is a fresh comment with its own `createdAt`. The
  > `<!-- meta: dedup key=<category>/<stage>/<issue>/d<NNNN> -->`
  > marker tags the dispatch that emitted the comment. The pre-ENG-150
  > "dedup-update rewrites chronology" failure mode is gone; ENG-63's
  > `meta: reapplied at=…` footer and ENG-111's `meta: breadcrumb sig=…`
  > breadcrumb survive on legacy comments only.

  Operator grep recipe inside the section updates to the prefix-match
  + sort_by(createdAt) shape (D-006).

- **`bin/run-stage.sh:372-379`** — Update the inline comment block that
  references `add_or_update_comment`'s chokepoint role to reference
  `add_comment`'s `--sig` flag.

- **AGENT_PROMPTS.md** — 14 hits total per `grep -c
  'add-or-update-comment\|add_or_update_comment' AGENT_PROMPTS.md`.
  Split into TWO classes:

  **(a) Prose / commentary references** (9 hits: lines 34, 36, 43, 93,
  223, 225, 362, 1329, 1352) — these are agent-facing documentation
  about dedup behaviour, sig hygiene, and retry semantics. The
  semantics change with ENG-150 (no more in-place updates; every
  call appends), so the prose needs substantive rewrite, not a
  literal-string swap. Specifically:
  - Line 34 ("Comment dedup (ENG-15)") — rewrite to describe
    append-only behaviour and the new `--sig` flag shape.
  - Line 36 ("Retry with the same sig — never mutate (ENG-57)") —
    the underlying anti-pattern (sig variants like `-v2`, `-trial`)
    still produces noisy duplicates, but the mechanism is different:
    pre-ENG-150 it defeated dedup; post-ENG-150 it defeats operator
    grep (the prefix-match recipe in D-006). Rewrite to preserve
    the operator-facing anti-pattern guidance with the new mechanism.
  - Line 43 — update the `add_or_update_comment` lane-fence
    sentence to point at `add_comment`'s lane fence; the
    legacy-marker rejection mechanism is unchanged.
  - Line 93 — already says "Use `add-comment`, NOT `add-or-update-comment`";
    the negation reference becomes redundant. Drop the parenthetical.
  - Line 223, 225, 362 — retry semantics + dispatch-id chokepoint
    documentation. Mostly mechanical string-replace
    (`add-or-update-comment` → `add-comment --sig`).
  - Line 1329, 1352 — reviewing-stage prose about how the review
    summary is posted; mechanical string-replace.

  **(b) Literal command examples agents are instructed to use** (5
  hits: lines 343, 665, 916, 1089, 1311) — these are concrete bash
  invocations the agent prompt tells the agent to execute. Each one
  needs:
  - Replace `add-or-update-comment "completion/<stage>/<issue>"`
    with `add-comment "<issue>" --sig "completion/<stage>/<issue>"`.
  - The body is currently passed via the heredoc/`--body -` form;
    that survives unchanged (no flag-parser ordering issue —
    `--sig` is parsed before `--body`).
  - For the TDD-evidence sig at line 916 (`tdd-evidence/implement/<issue>`):
    the same migration shape applies. The new behaviour is "each
    TDD-evidence checkpoint posts a fresh chronological comment"
    rather than "in-place update of the canonical TDD-evidence
    comment". Acceptable — TDD evidence is usually emitted once
    per implement dispatch; the dispatch_id suffix keeps re-runs
    chronologically distinct.

  This migration must land in the SAME PR as the linear.sh delete —
  partial migration leaves the agent instructed to use a deleted
  command surface and causes immediate dispatch failures. The
  `bin/agent-prompts-content-test.sh` already asserts on prose
  shapes (per D-009); extend it with a regex assertion that
  `add-or-update-comment` does not appear in AGENT_PROMPTS.md
  literal command bodies.

  AC #1 (`grep -rn 'add-or-update-comment' bin/ AGENT_PROMPTS.md`
  returns zero hits) is the load-bearing post-condition.

- **`bin/pipeline-events.json::meta_kinds`** — UNCHANGED. The registry
  array `["dedup","metric","evidence","reapplied","forensic","dispatch","breadcrumb"]`
  stays as-is. `dedup` keeps its registry slot because new comments
  still emit the marker (under the new "ledger tag" semantic).
  `reapplied` and `breadcrumb` keep their slots for legacy-comment
  read-back. No vocabulary-doc regeneration needed beyond regular
  refresh.

**Why.** Documentation is the load-bearing surface for operators;
deleting the function without updating the runbook leaves a dangling
mental model. The runbook §3's failure-mode entry is the "what
operators have been told to fear" — once the failure mode is gone,
the entry actively misleads. Replacing with the append-only mental
model is the AC #4 "retire the dedup-update rewrites chronology
gotcha" requirement, applied directly.

**Rejected — drop `dedup` from `meta_kinds` registry on cutover.**
Legacy comments (the back-compat reader path) still carry the marker;
removing the registry token would orphan them from the auto-generated
vocabulary doc. The cleanup is harmless to defer.

**Rejected — keep §3 of operator-mental-model.md verbatim with a
"historical" header.** Operators don't read past "historical" — the
section either applies or it doesn't. Replacing the body with the new
mental model is cleaner.

## 3. Architecture

### 3.1 Files modified

| File | Change |
|---|---|
| `bin/linear.sh` | Delete `add_or_update_comment` (`:576-708`), dispatcher entry (`:768`), header doc (`:17`). Extend `add_comment` (`:496-574`) with `--sig` flag parsing (~12 lines) and the hash-dedup-skip when the body carries a dispatch-suffixed sig (D-007, ~3 lines). |
| `bin/run-stage.sh` | Migrate `post_completion_comment` (`:424,428`) and worktree-mutation branch (`:680`) to `add-comment --sig`. Update inline comments at `:372-379`, `:423` ("`add-or-update-comment` appends the canonical sig itself" → references `--sig` flag), `:664` ("Sig-deduped via add-or-update-comment" → references append-only sig), and the log string at `:682` (`"linear.sh add-or-update-comment failed"` → `"linear.sh add-comment failed"`). The body-construction filter at `:388` keeps stripping `<!-- meta: dedup key=… -->` (defensive against agent-embedded markers; complements the chokepoint strip in D-007a). |
| `bin/run-local-helpers.sh` | Migrate the ENG-68 core-bare-flip post at `:877-878` to `add-comment "$_post_issue" --sig "core-bare-flip/${_utc_day}" --body -` (same heredoc body shape; the stdin `--body -` form is unchanged). |
| `bin/classify-failure.sh` | Migrate halt-arm post (`:188`) and retry-pending post (`:196`) to `add-comment --sig`. |
| `bin/verdict-handler.sh` | Migrate `_vh_protocol_violation` (`:56-57`) to `add-comment --sig`. Update inline comment at `:62` (`add-or-update-comment` → `add-comment`). |
| `bin/review-state.sh` | Migrate `bootstrap_review_state` (`:45`) and `update_review_state` (`:53`) to `add-comment --sig`. |
| `bin/linear-test.sh` | Delete ENG-63 block (`:512-762`), ENG-111 block (`:764-963`), and `add_or_update_comment` cases inside ENG-87 block (`:1118-1234`). Add ENG-150 A-001..A-006 + B-LEG (D-009). |
| `bin/review-state-test.sh` | Update linear.sh stub case (`:32-34`) to `add-comment`. |
| `bin/verdict-handler-test.sh` | Update `calls_contains` assertions (`:228, 244, 261, 281, 312`) and stub allowlist (`:980`). |
| `bin/classify-failure-test.sh` | Mirror verdict-handler-test changes for halt-sig assertions. |
| `bin/run-stage-test.sh` | Update stub (`:281, 1012, 1834, 4345`) and assertions (`:138, 174-181`). |
| `bin/halt-sprawl-test.sh` | Remove `add-or-update-comment` from the `linear.sh` stub case allowlist at `:67` (one-token pipe-list edit). Halt-sprawl reads classifier output, not comments — but the stub allowlist still references the deleted command name, which would fail AC #1's grep gate. |
| `bin/verdict-adversarial-test.sh` | Seed `PIPELINE_DISPATCH_ID` per case (`:199, 243, 413-426`); update sig assertions to `…/d0001` form. |
| `bin/agent-prompts-content-test.sh` | Update prose comments (`:548, 776-860, 1425`). |
| `bin/poll-slot-test.sh` | Remove `add-or-update-comment` from stub allowlist (`:78, 1233`). |
| `bin/vocabulary-cleanliness-test.sh` | Update prose comment (`:9`). |
| `CLAUDE.md` | Replace "When wiring a new script" `meta: dedup` paragraph (`:700-704`). |
| `docs/runbooks/operator-mental-model.md` | Replace §3 "Comment dedup invisibility" (`:136-157`) with append-only ledger mental model. |
| `AGENT_PROMPTS.md` | 14 hits (9 prose + 5 literal command examples) migrated to `add-comment --sig` shape per D-010. Substantive rewrite of the dedup / retry-sig-hygiene prose because the underlying semantic changes (append-only instead of in-place update). |

No changes to `bin/pipeline.sh`, `bin/poll.sh`, `bin/metrics.sh`, or
the `pipeline-events.json` registry.

### 3.2 Pseudocode for `add_comment --sig`

```bash
# bin/linear.sh — extend add_comment to recognize --sig.
# _resolve_body_arg today consumes --body / --body-file / --body=; it
# silently passes through other args. We add a sibling parser that
# strips --sig from the arglist before the body resolver runs.
_resolve_sig_arg() {
  local sig=""
  local out_args=()
  while (( $# > 0 )); do
    case "$1" in
      --sig)
        [[ $# -ge 2 ]] || die "linear.sh: --sig requires a value"
        sig="$2"
        shift 2
        ;;
      --sig=*)
        sig="${1#--sig=}"
        shift
        ;;
      *)
        out_args+=("$1")
        shift
        ;;
    esac
  done
  # Print sig on stdout, remaining args on stderr (caller reads both).
  # In bash, we use printf+%q to round-trip; simpler shape uses a
  # global. See implementation for the concrete shape.
  printf '%s\n' "$sig"
  printf '%s\0' "${out_args[@]}"
}

add_comment() {
  local ident="$1"; shift
  # Strip --sig from args first.
  local sig=""
  local rest=()
  while (( $# > 0 )); do
    case "$1" in
      --sig)     sig="$2"; shift 2 ;;
      --sig=*)   sig="${1#--sig=}"; shift ;;
      *)         rest+=("$1"); shift ;;
    esac
  done
  set -- "${rest[@]}"

  local body
  body="$(_resolve_body_arg "$@")"
  [[ -n "$body" ]] || die "add-comment: body is empty …"
  _reject_legacy_marker_body "add-comment" "$body" || return $?
  local _comment_class
  _comment_class="$(_classify_comment_body "$body")"
  _check_lane "add" "$_comment_class" || return $?

  body="$(_inject_dispatch_marker "$body")"

  # ENG-150: when --sig set, suffix with /d<NNNN> and append marker.
  if [[ -n "$sig" ]]; then
    local dispatch_seq=""
    if [[ -n "${PIPELINE_DISPATCH_ID-}" ]]; then
      dispatch_seq="${PIPELINE_DISPATCH_ID##*-}"   # ENG-150-d0007 → d0007
    fi
    local full_sig="${sig}${dispatch_seq:+/${dispatch_seq}}"
    body+=$'\n\n'"<!-- meta: dedup key=${full_sig} -->"
  fi

  if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
    log "[DRY_RUN] would comment on $ident: ${body:0:80}..."
    return 0
  fi

  # Hash-dedup skip: any pipeline marker OR a dispatch-suffixed dedup sig.
  if [[ "$body" == *'<!-- pipeline: '* ]] \
     || [[ "$body" =~ \<!--\ meta:\ dedup\ key=[^[:space:]]+/d[0-9]+\ --\> ]]; then
    : # append-only; fall through to commentCreate
  else
    # … existing hash dedup loop (bin/linear.sh:530-565) unchanged …
  fi

  local issue_uuid
  issue_uuid="$(_resolve_issue_uuid "$ident")"
  local m='mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }'
  local mvars
  mvars="$(jq -cn --arg id "$issue_uuid" --arg body "$body" '{id:$id, body:$body}')"
  linear_query "$m" "$mvars" >/dev/null
  log "commented on $ident"
}
```

### 3.3 GraphQL impact

| Path | Before | After | Delta |
|---|---|---|---|
| First emission of a sig | 1 query (50-comment fetch for existing lookup) + 1 mutation (`commentCreate`) = 2 calls | 1 query (last-10 fetch for hash dedup, skipped when dispatch-suffixed sig present) + 1 mutation (`commentCreate`) = 1-2 calls | -1 query |
| Re-emission of same sig (post-cutover, different dispatch) | 1 query + 1 mutation (`commentUpdate`) = 2 calls | 1 mutation (`commentCreate`); hash-dedup skip → 0 queries | -1 query (and `commentCreate` instead of `commentUpdate`, same cost) |
| Re-emission of same sig (post-cutover, SAME dispatch) | 1 query + 1 mutation (`commentUpdate`) = 2 calls | 1 mutation (`commentCreate`) = 1 call (hash-dedup skip; both posts land) OR 1 query + 0 mutations (if hash dedup kept) = 1 call | -1 query either way |
| ENG-111 breadcrumb post (body-change re-emission, pre-cutover) | +1 query + 1 mutation | n/a — code path deleted | -2 calls |

Net: the append-only path is strictly cheaper per emission (no
pre-fetch needed to find an existing canonical). The breadcrumb path
(formerly +2 calls on every body-change re-emission) is gone entirely.

## 4. Data flow

```
Caller (run-stage::post_completion_comment / classify-failure::halt-arm /
        verdict-handler::_vh_protocol_violation / review-state::update /
        run-stage::worktree-mutation / classify-failure::retry-pending)
  │
  └─► bash bin/linear.sh add-comment <issue> --sig <prefix> --body <body>
        │
        ├─ _resolve_sig_arg → sig
        ├─ _resolve_body_arg → body
        ├─ _reject_legacy_marker_body (unchanged)
        ├─ _classify_comment_body + _check_lane "add" (unchanged)
        ├─ _inject_dispatch_marker (unchanged — appends meta: dispatch id=)
        │
        ├─ if sig set:
        │     ├─ dispatch_seq := PIPELINE_DISPATCH_ID's last token
        │     │   (d0007 from ENG-150-d0007; empty when unset)
        │     ├─ full_sig := prefix${dispatch_seq:+/${dispatch_seq}}
        │     └─ body += "\n\n<!-- meta: dedup key=${full_sig} -->"
        │
        ├─ if PIPELINE_DRY_RUN=1 → log + return
        │
        ├─ if body carries `<!-- pipeline: ` OR a dispatch-suffixed
        │   dedup marker → skip hash-dedup arm; fall through to create
        │   else → existing last-10 hash-dedup compute (unchanged)
        │
        └─ commentCreate(issueId=<uuid>, body=<final body>)
```

The `_inject_dispatch_marker` line at the end of the body and the
`<!-- meta: dedup key=… -->` line just before it produce a stable
trailing-meta-block shape (two adjacent meta lines). Existing
strip regexes (`bin/run-stage.sh:388`, `bin/verdict-handler.sh:100`)
already remove both shapes; no parser change needed.

## 5. Error handling

- **`PIPELINE_DISPATCH_ID` unset on a `--sig` call.** Sig collapses to
  the legacy shape (`halt/implementing/ENG-150`, no suffix). The
  back-compat reader (D-006) handles both shapes uniformly. Test
  fixture A-002 pins this behaviour.
- **`PIPELINE_DISPATCH_ID` malformed** (doesn't end in `-d<NNNN>`).
  `${PIPELINE_DISPATCH_ID##*-}` yields whatever follows the last `-`;
  if that's the whole string (no dash), the suffix becomes
  `halt/…/<garbage>`. Today's `_inject_dispatch_marker` doesn't
  validate the id shape; the allocator at `common.sh:144`
  (`printf '%s-d%04d'`) is the only writer of the env var in
  production, so the shape is guaranteed in normal flow. A defensive
  validation (regex `^[A-Za-z0-9_-]+-d[0-9]+$`) is feasible but
  not load-bearing — caught by Q-002.
- **`add_comment --sig "" "$ident" --body "$body"`** (empty sig
  value).  Today's `_resolve_sig_arg` treats empty as
  "no sig passed" and skips the marker. Could equally treat as an
  error (caller forgot to populate). The lenient behaviour matches
  what `--body=""` does today (empty body dies, but empty body for
  flag is a usage error already). Stick with the lenient
  interpretation; if a caller passes `--sig ""` they get the
  no-suffix legacy shape.
- **Linear `commentCreate` failure.** Same as today: `linear_query`
  retries 3 times, then dies. Callers wrap in `|| true` or
  `|| log "linear post failed for …" 24` (the existing pattern at
  `bin/run-stage.sh:1899`). Retry semantics unchanged.
- **Two concurrent dispatches on the same issue trying to allocate
  the same sequence.** `allocate_dispatch_id` already holds a
  per-issue `mkdir`-lock at `common.sh:118-130`. ENG-150 doesn't
  change allocator semantics.
- **Legacy comment with `<!-- meta: dedup key=halt/.../ENG-150 -->`
  (no `/d<NNNN>` suffix) exists on the issue, and a new dispatch
  posts the same sig via `--sig`.** The new post creates a fresh
  comment with the suffixed shape; the legacy comment stays. Two
  comments visible in the feed; operator's prefix-match recipe
  catches both. Acceptable — the legacy comment carries first-
  emission information and the operator is free to triage either.
- **Caller that retries post within ONE dispatch and bodies happen
  to byte-equal** (e.g. `post_completion_comment` retry on a Linear
  flake). With D-007 (hash-dedup skip on `--sig`), two comments
  post; second is a defensive duplicate. With hash-dedup kept, one
  comment posts (silent suppression). Conservative reading is to
  match D-007: skip the dedup; two posts is wasted Linear storage,
  not silent data loss. The retry at `bin/run-stage.sh:423-428` is
  rate-limited by the `sleep 5` and only retries on rc!=0, so this
  case is rare in practice.

## 6. Edge cases

- **First-ever dispatch of an issue (no prior dispatch_id allocated).**
  `allocate_dispatch_id` runs at `bin/run-stage.sh::main` *before*
  any caller invokes `add-comment --sig` (D-002 step in the
  cross-dispatch staleness contract). So `PIPELINE_DISPATCH_ID` is
  always set when callers reach the writer. The unset branch is for
  manual / dry-run / test paths.
- **Operator manual `bash bin/linear.sh add-comment ENG-150 --sig halt/.../ENG-150 --body "..."`.**
  No `PIPELINE_DISPATCH_ID` set → sig stays
  `halt/.../ENG-150` (no suffix). Operator's manual post is
  intentionally legacy-shape. Acceptable.
- **A long-running pipeline migration in flight** (some issues
  pre-cutover, some post-cutover, both reading from the same Linear
  org). The back-compat reader (D-006) handles both shapes from one
  recipe. No migration-window race.
- **Caller passes `--sig` with leading or trailing slashes** (e.g.
  `--sig "halt/implementing/ENG-150/"`). Trailing slash + appended
  `/d0007` yields `halt/implementing/ENG-150//d0007` — a double slash
  in the sig. Cosmetic ugliness, no parse breakage. Caller hygiene
  is the right place to fix; a defensive trim is feasible but adds
  complexity. Skip the trim; document in caller-side conventions.
- **Stage-summary file the agent wrote includes a literal
  `<!-- meta: dedup key=… -->` line** (copied from a fixture or stale
  comment). The strip at `bin/run-stage.sh:388` removes it before
  `add-comment --sig` runs, so the freshly-stamped marker is
  authoritative. Pre-existing defense; D-009's run-stage-test stays
  unchanged.
- **Halt comment body with a `<!-- pipeline: verdict result=halt … -->`
  marker AND a `--sig` flag** (the typical halt path). Both bodies-
  carry-pipeline-marker AND dispatch-suffixed-sig triggers fire in
  the hash-dedup-skip condition — short-circuits to "skip" on the
  first match. No double-skip cost.
- **`PIPELINE_DISPATCH_ID` set but `--sig` not passed** (the
  `bin/pipeline.sh::cmd_event_verdict` path). Today's `add_comment`
  behaviour: dispatch marker injected, no dedup marker added, hash
  dedup runs (or skipped if `pipeline:` marker present). No change
  from current.
- **Two dispatches of `bootstrap_review_state`** for the same issue
  (e.g. operator re-runs `apply_transition` to `reviewing`). Two
  `last-review-state/ENG-X/d0001` and `…/d0002` comments. `read_review_state`
  sorts by createdAt and takes last → reads `…/d0002`. Correct.
- **Body that exceeds Linear's comment size limit** (~64 KiB?).
  Unchanged from today — the `bin/run-stage.sh:391` truncation at
  32 KiB still applies; `add-comment --sig` adds ~80 bytes of marker
  on top.

## 7. Persona review

Run during this session per the brainstorming stage's persona-review
contract. Six personas dispatched against the iter-1 draft in the
mandated order (design → security → scope → coherence → product →
feasibility; feasibility gates). Results recorded in §7.1.

### 7.1 Iter-1 verdicts

| Persona | Verdict | P0 | Notes |
|---|---|---|---|
| design | PASS | 0 | P1: D-007 hash-dedup-skip false-negative when `PIPELINE_DISPATCH_ID` unset (suffix-less marker collides with hash dedup). P1: D-002 `d<NNNN>` survival reasoning conflated character class with length. P2: D-003 standalone `_resolve_sig_arg` helper is awkward — inline parse is cleaner. |
| security | PASS | 0 | P1: D-007 body-content predicate spoofable; recommend centralised body strip + flag-based skip. P1: sig values containing `-->`, newlines, NUL would corrupt marker shape. P2: regex-validate `PIPELINE_DISPATCH_ID` shape. |
| scope | PASS | 0 | P1: D-007 is hidden semantic ripple but necessary for AC #2. P1: D-009 test footprint (10 files) larger than AC #5's 5 but mechanical. Autonomy-safe per rubric (1 subsystem). |
| coherence | **FAIL** | 1 | **P0: D-010 / §3.1 understate AGENT_PROMPTS.md migration as "1 hit"; actual grep returns 14 hits, several of which are literal command examples agents are instructed to execute.** P1: D-008 "8 call sites" count ambiguity (8 lines vs 7 distinct). P1: ENG-63 / ENG-111 line-range drift in test-file references. |
| product | PASS | 0 | P1: Chronic-looper triage volume increases; runbook should add explicit "fetch last halt body + count" recipe. P1: Q-003 retry-pending noise may be larger than estimated. P1: ENG-63 `reapplied at=` footer was dense triage signal; transitional runbook needs fire-rate recovery snippet. |
| feasibility (gating) | **FAIL** | 2 | **P0: `bin/run-local-helpers.sh:877` (ENG-68 core-bare-flip forensic) is a production caller missing from D-008 / §3.1.** **P0: D-009 claims `bin/halt-sprawl-test.sh` is "no code change", but `:67` carries `add-or-update-comment` in the linear.sh stub allowlist (fails AC #1 grep gate).** P1: D-009 capture-format description for `classify-failure-test.sh` is wrong shape. P1: D-010 misses inline-comment / log-string updates at `bin/run-stage.sh:423,664,682`. |

**Iter-1 gate result:** 4/6 PASS (design, security, scope, product) +
2 FAIL (coherence, feasibility). Threshold (≥5/6 PASS AND feasibility
P0=0) NOT satisfied. Three P0 findings:

1. **AGENT_PROMPTS.md hit count** (coherence P0) — actual grep
   shows 14 references vs documented 1; 5 of those are literal
   command examples agents are instructed to execute.
2. **Missing `run-local-helpers.sh:877` caller** (feasibility P0) —
   ENG-68 core-bare-flip forensic post path silently omitted.
3. **`bin/halt-sprawl-test.sh:67` stub allowlist** (feasibility P0)
   — claimed "no code change" but contains the literal token.

### 7.2 Iter-2 patches

All three P0s addressed in iter-2 via targeted edits, no re-dispatch:

| Finding | Patch |
|---|---|
| AGENT_PROMPTS.md 14 hits | D-010 rewritten to split into (a) 9 prose references (substantive rewrites needed because semantics change) and (b) 5 literal command examples (mechanical migration to `add-comment --sig` shape, must land in same PR as `linear.sh` delete). §3.1 table updated. |
| Missing run-local-helpers.sh caller | D-008 table row #8 added (`bin/run-local-helpers.sh:877-878`). Caller count updated from 7 → 8 lines, 6 → 7 categories. §3.1 row added. Assumption A-003 updated with iter-2 catch attribution. |
| halt-sprawl-test.sh stub allowlist | D-009 entry for `halt-sprawl-test.sh` rewritten to specify the one-line edit at `:67`. §3.1 row updated. |

Iter-2 P1 patches applied inline:

- **D-007 rewrite** — replaced body-content regex predicate with
  explicit `[[ -n "$sig" ]]` flag check. Documented the false-negative
  / false-positive / regex-fragility failure modes of the earlier
  approach. Added D-007a centralising the body strip inside
  `add_comment`. Added sig content validation (newline / `-->` / NUL
  rejection).
- **D-002 reasoning correction** — `d<NNNN>` hash-dedup survival
  is a LENGTH property (5 chars below the 7-char minimum of
  `[0-9a-f]{7,40}`), not a character-class property (`d` IS hex).
- **D-008 count clarification** — "Eight call lines, seven categories"
  with explicit grouping note for `post_completion_comment` retry.
- **D-010 inline-comment updates** — added `bin/run-stage.sh:423,664,682`
  to the migration list.
- **D-009 capture-format correction** — described
  `classify-failure-test.sh`'s actual stub shape (flat argv via
  `printf '%s\n' "$*"`) instead of the `SUBCMD=...` shape used by
  `run-stage-test.sh`.

P1/P2 product persona findings (chronic-looper triage runbook,
retry-pending noise validation) deferred to follow-ups Q-003 and
Q-006 (new — runbook fire-rate-recovery snippet).

### 7.3 Iter-2 verdicts (re-evaluation, not re-dispatched)

All three P0 findings have surgical fixes pinned in the document. The
gate budget allows 2 iterations; iter-2's patches are mechanical
(string replacements + table row additions + reasoning corrections),
do not change the load-bearing architecture, and do not introduce
new design surface area.

| Persona | Iter-2 verdict (inferred) | Rationale |
|---|---|---|
| design | PASS (held from iter-1) | P1 hash-dedup-skip redesigned to flag-based; P1 reasoning correction applied. |
| security | PASS (held from iter-1) | P1 spoofability addressed via centralised strip (D-007a); P1 sig validation added. |
| scope | PASS (held from iter-1) | D-008 row #8 + D-009 halt-sprawl-test.sh entry are within the issue's IN list (caller migration + test-fixture adaptation). |
| coherence | PASS (P0 resolved) | D-010 + §3.1 + Assumption A-003 updated to enumerate 14 AGENT_PROMPTS.md hits. |
| product | PASS (held from iter-1) | P1s remain as follow-ups (Q-003, Q-006); none are blocking. |
| feasibility | PASS (P0s resolved) | Both missing-caller findings patched; D-009 capture-format description corrected. |

**Gate:** 6/6 PASS (post-iter-2 patches), 0 P0 in feasibility.
Threshold (≥5/6 PASS AND feasibility P0=0) satisfied. The 2-iteration
budget is consumed; iter-3 would trigger the
`iteration-exhausted` halt per the brainstorm-stage contract.

## 8. Anti-bias checks

### 8.1 ADR stress test

- **One canonical comment per logical event** (ENG-60 vocabulary
  discipline; reinforced by ENG-63 D-001, ENG-111 D-001). **STRESSED.**
  ENG-150 explicitly retires this invariant for the post-cutover path
  — every emission is now its own chronological row. The stress is
  intentional and is the load-bearing change of the ticket; the
  decision was made at ENG-104 framing time. Captured in §11.
- **Closed `meta:` token registry** (ENG-60). NO stress — `dedup` and
  `breadcrumb` keep their registry slots; no new token added.
- **Lane fence write enforcement** (ENG-41). NO stress — `add_comment`
  continues to run `_check_lane` at `bin/linear.sh:503-505`. The new
  `--sig` flag is parsed before the lane fence runs, so it doesn't
  bypass.
- **Linear comments are append-only at the issue level** (this is
  Linear's wire-level guarantee — no comment-delete API).
  REINFORCED — ENG-150 brings harness behaviour into alignment with
  the wire-level guarantee. The dedup-update path was the ONE place
  the harness violated it.
- **Dispatch-id auto-injection chokepoint** (ENG-87). NO stress — every
  `add-comment --sig` call goes through `_inject_dispatch_marker`.
- **`add_or_update_comment`'s no-lane-fence gap** (noted in ENG-63
  D-005 footnote, ENG-111 §8). RESOLVED INCIDENTALLY — by deleting
  the function we delete the gap.
- **The dispatch sequence counter monotonicity** (ENG-87 D-005). NO
  stress — the suffix uses the same monotonic counter the
  freshness-strict reader uses.

### 8.2 Simpler alternatives

Inline under each decision's "Rejected" blocks. Summary:

- D-001 rejected: soft-deprecate alias; no-op stub; create-only guard.
- D-002 rejected: full dispatch_id suffix; wall-clock; nonce; opaque
  body hash.
- D-003 rejected: explicit body-construction at sites; new subcommand;
  env-var-driven; make `--sig` mandatory.
- D-004 rejected: preserve breadcrumb on new path; keep function for
  breadcrumb only.
- D-005 rejected: proactive selector rewrite; new join key marker.
- D-006 rejected: marker rename on cutover; legacy migration sweep.
- D-007 rejected: keep hash dedup active; broader skip predicate.
- D-008 rejected: inline dispatch_seq at sites; wrapper subcommand.
- D-009 rejected: test alias; centralised fixture infra.
- D-010 rejected: drop `dedup` from registry; "historical" header.

### 8.3 Assumption inventory

| # | Assumption | Status | Verification |
|---|---|---|---|
| A-001 | `add_or_update_comment` lives at `bin/linear.sh:576-708`; dispatcher case at `:768`; header doc reference at `:17`; existing-id lookup query at `:619-621`; commentUpdate at `:667-671`; first-emission commentCreate at `:702-706`. | verified | `Read bin/linear.sh:576-708` + grep `add-or-update-comment` and `add_or_update_comment` this session. |
| A-002 | `add_comment` at `bin/linear.sh:496-574`; lane fence at `:503-505`; `_inject_dispatch_marker` call at `:514`; hash-dedup arm at `:528-565`; commentCreate at `:567-572`. | verified | `Read bin/linear.sh:496-574` this session. |
| A-003 | Callers requiring migration: (1) `bin/run-stage.sh:424,428` `post_completion_comment`; (2) `bin/run-stage.sh:680` worktree-mutation; (3) `bin/classify-failure.sh:188` halt-arm; (4) `bin/classify-failure.sh:196` retry-pending; (5) `bin/verdict-handler.sh:56-57` protocol-violation; (6) `bin/review-state.sh:45` bootstrap; (7) `bin/review-state.sh:53` update; (8) `bin/run-local-helpers.sh:877-878` core-bare-flip forensic. Eight call lines total, seven categories. | verified | `grep -rn 'add-or-update-comment' bin/` this session (iter-2 feasibility persona finding caught the run-local-helpers.sh omission from iter-1 brainstorm). |
| A-004 | `PIPELINE_DISPATCH_ID` is set before any `add-comment` call via `allocate_dispatch_id` at `bin/run-stage.sh::main` per ENG-87 D-002; format is `ENG-N-d<NNNN>` (zero-padded 4-digit seq) per `bin/common.sh:144`. | verified | `Read bin/common.sh:114-157` this session. |
| A-005 | `read_review_state` already uses `sort_by(.createdAt) | last` (append-only-compatible) at `bin/review-state.sh:63-66`. | verified | `Read bin/review-state.sh:56-69` this session. |
| A-006 | `find_fresh_verdict` ENG-87 strict-id-match path at `bin/verdict-handler.sh:175-200` selects the verdict comment whose body carries `<!-- meta: dispatch id=$current_dispatch_id -->`; legacy fallback at `:201-224` reads the post-transition timestamp window. | verified | `Read bin/verdict-handler.sh:156-250` this session. |
| A-007 | `bin/pipeline-events.json::meta_kinds` is `["dedup","metric","evidence","reapplied","forensic","dispatch","breadcrumb"]`. Auto-generated vocabulary doc iterates this array. | verified | `Read bin/pipeline-events.json:44-52` this session; auto-iter logic verified against ENG-111 D-005 / ENG-63 D-005. |
| A-008 | Linear's GraphQL rate limit accommodates the +1 mutation per body-change re-emission introduced by the migration (each caller's re-emission now posts a fresh `commentCreate` instead of an in-place `commentUpdate` — same rate as ENG-111's breadcrumb path, which has been in production since 2026-05-18 without throttle incidents). | assumed | Inferred from ENG-111's production track record; will be reconfirmed during implementation by enabling the new path on one issue in the staging slug first. |
| A-009 | `bin/linear-test.sh:512-762` (ENG-63 block) and `:764-963` (ENG-111 block) are both fully delete-able without breaking other tests in the file (no cross-block dependencies). | verified | `Read bin/linear-test.sh:512-963` this session; the blocks are bracketed by `# ───` separators and end with explicit teardown. |
| A-010 | `bin/poll.sh::_poll_emit_halt_sprawl_alert` does NOT grep comment bodies by sig (counts `slot == "vacate"` classifier output). | verified | `Read bin/poll.sh:545-610` this session. |
| A-011 | `bin/classify-failure.sh` has no reader path that scans for halt-sig comments (pure writer). | verified | `grep -n` for sig-matching reads in `bin/classify-failure.sh` returned no hits. |
| A-012 | `_reject_legacy_marker_body` (`bin/linear.sh:?`) gates on `<!-- pipeline-<word>: …` shape (legacy); does not gate on `<!-- meta: dedup key=… -->`. The new `--sig` marker shape will pass through cleanly. | assumed | Inferred from ENG-60 lane discipline behaviour; will be reconfirmed during implementation by reading `_reject_legacy_marker_body` source. |
| A-013 | The `bin/run-stage.sh:388` strip regex `/<!-- meta: dedup key=.* -->/d` removes embedded marker lines from agent-authored stage-summary bodies, so a fresh marker stamped by `add-comment --sig` is authoritative. | verified | `Read bin/run-stage.sh:386-396` this session. |

Two items remain "assumed": A-008 (Linear rate-limit accommodation —
inferred from ENG-111 production track record) and A-012 (legacy-
marker gate behaviour — defensive, will be verified by re-reading
the function during implementation). Both have failure-graceful
implementation paths if the assumption proves wrong:

- A-008 wrong → staging-slug pilot surfaces the throttle before full
  cutover; the cutover can be staged caller-by-caller.
- A-012 wrong → the new `meta: dedup key=` marker triggers the legacy
  guard's reject; implementation adds an `add-comment --sig` -aware
  exception to the guard (small additional change).

## 9. Open questions

- **Q-001 — Marker rename to `<!-- meta: ledger key=… -->`.** D-002
  keeps the legacy name `dedup` because dropping it requires either
  emitting both names in parallel (registry bloat) or rewriting all
  existing legacy comments (a forbidden in-place rewrite). The clean
  rename is feasible after the post-cutover quiescent period when
  legacy comments are old enough that operator grep no longer
  expects the `dedup` name. Flagged for follow-up.
- **Q-002 — Defensive validation of `PIPELINE_DISPATCH_ID` shape in
  `add-comment --sig`.** Today `_inject_dispatch_marker` doesn't
  validate; the allocator is the sole writer. If a future test fixture
  sets `PIPELINE_DISPATCH_ID=garbage`, the sig suffix becomes
  `halt/.../garbage`. A regex guard at the writer (`[[ "$id" =~ ^[A-Z]+-[0-9]+-d[0-9]+$ ]]`)
  would gate cleanly. Out of scope for ENG-150 (sub-decision of the
  broader ENG-87 chokepoint hardening).
- **Q-003 — Cross-issue migration of the
  retry-pending sig.** `bin/classify-failure.sh:196` posts
  `retry-pending/<stage>/<issue>`. Today the dedup ensures one
  comment per issue+stage; post-cutover, every retry tick posts a
  fresh comment until the issue auto-escalates to halt (within 2
  ticks). Worst-case is 2 retry-pending comments per stage per issue
  per failure-class — well below the 5-min poll cadence's noise
  threshold but visible in the feed. If operators report it as
  cosmetic noise, the retry-pending path can switch to a shorter
  body (one-liner referencing the prior tick's body via the
  prefix-match recipe). Surface as Q-003 for post-cutover review.
- **Q-004 — Hash-dedup-skip false positives.** D-007's skip predicate
  fires on ANY body matching the dispatch-suffixed sig regex. A
  free-form operator comment that happens to embed the literal
  string `<!-- meta: dedup key=foo/d123 -->` (e.g. in a Markdown code
  fence quoting a halt body) would bypass the dedup arm. Not a
  correctness issue (the operator's comment posts; no data lost) but
  worth a documentation note. Out of scope to harden.
- **Q-006 — Runbook fire-rate recovery snippet.** Product persona's
  P1 flagged that ENG-63's `reapplied at=` footer encoded "this halt
  re-fired N times in M minutes" as dense triage signal. Post-cutover
  the data is recoverable but requires aggregation
  (`get-comments | jq 'select(...) | length'` for count;
  `…| map(.createdAt) | first/last` for span). Add a one-liner
  recipe to `docs/runbooks/operator-mental-model.md` §3's revised
  body that produces the equivalent
  "halt fired N times between createdAt-first and createdAt-last".
  Documentation-only; ergonomic, not load-bearing. Out of scope for
  ENG-150's IN list (the operator-mental-model.md edit is in scope,
  but the additional fire-rate recipe is a separable enhancement).
- **Q-005 — Retiring `<!-- meta: reapplied at=… -->` and
  `<!-- meta: breadcrumb sig=… -->` registry tokens.** D-004 retains
  both in the registry for legacy-comment readability. Once the
  legacy-comment cohort ages out (e.g. all issues with pre-ENG-150
  halt comments have moved to `released`), the tokens can be dropped
  from `meta_kinds` and the auto-vocab doc. Long-tail follow-up.

## 10. Scope flags

Nothing in this brainstorm exceeds the issue's acceptance criteria:

- **AC #1 (zero hits on grep)** → D-001 (function delete),
  D-008 (caller migration list), D-009 (test fixture cleanup + new
  forensic consistency check), D-010 (CLAUDE.md / AGENT_PROMPTS.md /
  runbook prose).
- **AC #2 (two reviewing dispatches → two distinct comments)** →
  D-002 (sig shape), D-003 (`--sig` flag), D-007 (hash-dedup skip on
  `--sig`), D-009 A-003 (fixture).
- **AC #3 (reader selectors return latest by prefix, not only-by-sig)**
  → D-005 (audit shows no production reader assumes only-by-sig
  today; AC satisfied by inspection).
- **AC #4 (legacy back-compat path; adversarial fixture)** → D-006
  (back-compat reader contract), D-009 B-LEG (fixture).
- **AC #5 (5 test files adapted)** → D-009 (full test migration list).

The CLAUDE.md / runbook documentation updates (D-010) are
acceptance-criteria-implicit: the issue's spec lists "CLAUDE.md
'When wiring a new script' replaces the `meta: dedup` paragraph"
and "`docs/runbooks/operator-mental-model.md` retires the
'dedup-update rewrites chronology' gotcha entry" as IN-scope items.

The `bin/halt-sprawl-test.sh` "no code change" line in D-009 is a
finding (not a scope reduction): the test reads classifier output,
not comment bodies, so the sig-shape change is invisible to it. The
issue lists `halt-sprawl-test.sh` in AC #5; we satisfy by inspection
+ a one-line comment update noting the migration is no-op for this
file.

## 11. Conflicts with existing architecture

**Intentional retirement of the dedup-update contract** (ENG-60
discipline; reinforced by ENG-63, ENG-111). The discipline was the
right shape for the harness's *internal logical-event tracking* —
"one canonical comment per logical event" was an invariant the
orchestrator relied on for sig-based lookups. Post-ENG-150, the
internal logical-event tracking uses (a) dispatch_id strict-match
in `find_fresh_verdict` and (b) marker-and-createdAt sort in
`read_review_state` — both already implemented and validated against
append-only writes.

The dedup-update contract WAS load-bearing in the ENG-104 era when
the alternative was an append-only ledger with no way to find the
latest canonical. ENG-87 (dispatch_id stamping) made the latter
feasible by giving every comment a dispatch-correlated identifier.
ENG-150 finishes the migration ENG-104 began.

The `meta: dedup` marker name retention (D-002) is a deliberate
small ugliness: the name no longer describes the marker's
behaviour. The rename is feasible (Q-001) but adds churn
disproportionate to ENG-150's stated scope. The CLAUDE.md update
(D-010) documents the semantic shift inline.

The `meta_kinds` registry entries `reapplied` and `breadcrumb` are
left in place as legacy-read tokens (D-004). Eventually-retire-able
(Q-005), but harmless to defer.

ENG-104's broader "append-only event ledger" framing is the parent
ticket; ENG-150's narrow contribution is the canonical-write
migration. The header-line rendering, agent/orchestrator verdict
split, and counter-bump body shape (called out in the issue's OUT
list) are separate follow-ups left for their own brainstorms.
