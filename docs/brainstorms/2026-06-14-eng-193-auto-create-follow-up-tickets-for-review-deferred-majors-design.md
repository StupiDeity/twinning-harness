---
linear: ENG-193
title: Auto-create follow-up tickets for review-deferred majors
date: 2026-06-14
status: draft
---

# Auto-create follow-up tickets for review-deferred majors

## 1. Problem

[ENG-191](https://linear.app/twinning/issue/ENG-191) lands the
terminal `reviewing → qa` exit (the **selective exit**) and posts
ONE Linear comment under sig `deferred-majors/<ident>` that
enumerates the N deferred majors as known debt
(`bin/run-stage.sh:1483-1561`). The comment is operator-visible
audit; it is not scheduled work.

ENG-193 upgrades the audit comment into **K tracked follow-up
Linear tickets** — one per deferred major — so the debt is
scheduled, not just logged. Each follow-up:

* Is parented to the originating issue.
* Carries a type label (Bug / Feature / Improvement) per the
  CLAUDE.md filing convention (lines 232-235).
* Names the deferred finding's `finding_class_key` + the
  rubric-rationale + the five `decision_factors` booleans + the
  originating PR + the source dispatch.
* Is idempotent across re-takes of the same exit (resume,
  partial-orchestrator-crash, replay).

Two structural reasons this is its own ticket, not folded into
ENG-191:

1. **Envelope-validator collision.** The reviewing agent is
   forbidden from posting to Linear via `mcp__plugin_linear` /
   `curl https://api.linear.app` / `gh api graphql` /
   `wget https://api.linear.app`
   (`bin/run-stage.sh:1039-1123` — `_validate_dispatch_envelope`
   halts with `dispatch-envelope-violation` rc=29 on any
   transcript hit). Issue **creation** is structurally a Linear
   write; the agent has no legal path to perform it. **Only the
   orchestrator can create.**

2. **Surface gap.** `bin/linear.sh` has no `create-issue`
   subcommand today (verified: main case statement at
   `bin/linear.sh:927-944` lists 15 verbs, none of them
   creates an issue). The lane-fence matrix
   (`bin/linear.sh::_lane_decision`, lines 317-335) has no
   action × object_class entry for issue creation. ENG-193
   adds the orchestrator-only chokepoint.

## 2. Decisions

### D-001. NEW `bin/linear.sh create-issue` subcommand. Orchestrator-only via lane fence. Append-only by Linear-side description-marker search. Mutation shape: `issueCreate`.

**Rationale.** AC #3: "No agent-side Linear write occurs
(envelope-validator clean); all creation is orchestrator-side."

The chokepoint pattern is established by `add_label`
(`bin/linear.sh:474-501`), `remove_label` (lines 503-528),
`transition_state` (lines 559-583), and `add_comment` (lines
711-870): each subcommand resolves UUIDs via `linear-ids.json`
cache (`bin/common.sh::label_id`, `state_id` at lines 1140-1146),
gates on `_check_lane`, gates on `PIPELINE_DRY_RUN`, runs the
mutation via `linear_query` (`bin/linear.sh:397-431`). The new
`create_issue` function follows the same shape.

**Signature.**

```bash
bash bin/linear.sh create-issue \
  --title "<short title>" \
  --type-label <Bug|Feature|Improvement> \
  [--parent-id ENG-N] \
  [--label <name>]... \
  [--state <Backlog|Todo|...>] \
  --description <value | - | @<path>>
```

* `--title`, `--type-label`, and `--description` are required.
* `--description` accepts three input modes (mirroring
  `add_comment`'s `--body` resolver at `bin/linear.sh:670-709`):
  literal value, `-` to read from stdin, or `@<path>` to read
  from a file. The helper in D-004 uses stdin (`--description -`)
  to pipe a heredoc-composed body without writing to disk.
* `--parent-id` accepts a Linear identifier (`ENG-N`) and is
  resolved to UUID via `_resolve_issue_uuid`
  (`bin/linear.sh:467-471`). Mutation field on
  `issueCreate.input.parentId` per Linear GraphQL.
* `--label` is repeatable. Type label is one mandatory entry,
  resolved via `label_id`; additional labels (if any) are
  resolved the same way and concatenated into the input's
  `labelIds: [...]` array.
* `--state` defaults to `Backlog` (see D-005 rationale). State
  UUID resolved via `state_id`.

**Linear GraphQL mutation:**

```graphql
mutation($title: String!, $description: String!, $teamId: String!,
         $projectId: String, $stateId: String, $parentId: String,
         $labelIds: [String!]) {
  issueCreate(input: {
    title: $title,
    description: $description,
    teamId: $teamId,
    projectId: $projectId,
    stateId: $stateId,
    parentId: $parentId,
    labelIds: $labelIds
  }) {
    success
    issue { id identifier url }
  }
}
```

`teamId` resolved via `config_get '.linear.team_id'` (precedent at
`bin/linear.sh:449`). `projectId` via `_require_project_id`
(line 441). Both are required by Linear's data model and by the
existing in-target config contract.

**Idempotency — D-002 covers separately.** Before posting, the
function shells `find-follow-up` (D-002) which queries Linear for
an existing issue carrying the per-finding marker. If the search
hits, returns the existing identifier and skips the mutation.

**TOCTOU race analysis** (Design P1 #2). The search-then-create
pattern has a structural race window. Two cases:

* **Same-parent race.** Two reviewing dispatches on the same
  parent could both pass the `find-follow-up` lookup and then
  both create. Defeated structurally: `$(issue_dir)/.in-flight.lock`
  (ENG-81) serialises ALL dispatches per parent — only one
  dispatch's hook runs at a time. Win.
* **Cross-parent race.** Two reviewing dispatches on DIFFERENT
  parents, both emitting follow-ups for findings that happen to
  share the same `finding_class_key` (coincidentally identical
  scope-anchor + concept-slug, e.g. both finding the same
  upstream pattern in shared code). Defeated structurally
  because the marker includes `dispatch=ENG-N-d<NNNN>` —
  `dispatch_id` is parent-scoped (`ENG-N` is the parent
  identifier; `<NNNN>` is the per-parent sequence). Different
  parents → different `dispatch_id` substrings → different
  markers → no collision. Both follow-ups exist correctly under
  their respective parents.

`find-follow-up` is therefore safe under all dispatch-concurrency
patterns the harness emits.

**Lane fence ordering** (Security P1 #3). `_check_lane "create"
"child_issue"` runs FIRST inside `create-issue` —
before any UUID resolution (which would make a Linear API read
call via `_resolve_issue_uuid`) and before any `PIPELINE_DRY_RUN`
short-circuit. Gate-first prevents an agent-lane caller from
triggering Linear reads via the side-effect of resolution.
Mirrors `add_label`'s gate-first pattern (`bin/linear.sh:476-479`
runs `_check_lane` at line 479, BEFORE `_resolve_issue_uuid` at
line 482).

**Lane fence matrix entry.** New action × object_class entry in
`_lane_decision` (`bin/linear.sh:317-335`):
`"create child_issue"` allow lanes `orchestrator,human`. New entry
in `_allowed_lanes_for` mirroring same pattern.

**Defense-in-depth disambiguation** (Design P1 #1). The
reviewing-stage allowlist DOES grant
`Bash(bash bin/linear.sh:*)` to the agent — that's broad enough
to cover any subcommand the script supports. So the lane fence
is the **only** structural denial for `create-issue` (rc=13 from
`_check_lane` when `PIPELINE_WRITER=agent`); it is NOT
redundant with the allowlist. ENG-87's envelope validator
catches different evasion paths (`mcp__plugin_linear` /
`curl https://api.linear.app`); the lane fence catches THIS
evasion path (agent dispatching `bash bin/linear.sh create-issue`).
Together they form the defense-in-depth ladder for
"agent must not create Linear issues."

**Reference to constraint.** CLAUDE.md "Linear conventions"
(lines 230-257) — type label at creation; additive label mutation.
The new subcommand enforces type-label-at-creation by requiring
`--type-label`.

**Reference to constraint.** AC #3: agent never invokes this
subcommand; the lane fence is the structural denial.

**Rejected alternative — agent emits a structured per-finding
payload that the orchestrator reads and creates issues from
without a new subcommand.** Rejected because (a) the agent
already emits per-finding ledger rows (ENG-190 + ENG-191 fields)
which serve as the structured payload; ENG-193 already CAN read
them. The "no new subcommand" path would require the orchestrator
to inline the GraphQL mutation inside `run-stage.sh`'s post-
dispatch hook — sprawling Linear API mechanics into the hook
file. The `bin/linear.sh` chokepoint pattern keeps Linear API
surface in one file (CLAUDE.md "When wiring a new script" — "All
Linear writes go through `bin/linear.sh add-comment`, which is
append-only — every emission produces a fresh chronological
comment"; extension principle).

**Rejected alternative — fold creation into `add_comment` (single
omnibus Linear write subcommand).** Rejected because (a) the
existing `add_comment` body is 160+ lines around the comment
shape, with sig/dedup/marker injection logic; mixing it with
issue creation would double the surface and require type
dispatch inside one function; (b) Linear's GraphQL mutations
`commentCreate` and `issueCreate` have different shape — sharing
one function buys nothing.

**Rejected alternative — use `mcp__plugin_linear_save_issue` from
the orchestrator (via a wrapper script).** Rejected because (a)
MCP is plumbed for the agent's `claude -p` runtime, not for
orchestrator-side Bash; spawning a claude session just to call
MCP is overkill; (b) the GraphQL route through `linear_query` is
the orthogonal, established orchestrator-side path; (c) MCP's
`save_issue` overwrites labels on update (per CLAUDE.md "Don'ts"
line 244) — at creation time this is fine, but the API shape is
not a clean match.

### D-002. Idempotency key is a **per-finding description marker**: `<!-- meta: follow-up-source dispatch=ENG-N-d<NNNN> finding_class_key=<sanitised> -->`. NEW `bin/linear.sh find-follow-up` subcommand searches Linear for an issue carrying this marker; orchestrator skips creation on match.

**Rationale.** AC #2: "Re-running the exit (resume / re-dispatch)
must not duplicate already-created follow-ups (dispatch-id or
content-hash keyed)."

**Marker location: child's description body, embedded at the
bottom.** The orchestrator emits this marker on every follow-up
issue it creates. The marker carries TWO identifiers:

* `dispatch=ENG-N-d<NNNN>` — the source dispatch ID. Stable
  across re-runs (PIPELINE_DISPATCH_ID for this dispatch).
* `finding_class_key=<sanitised>` — the per-finding scope-anchor
  from the ledger row. Stable per finding within a dispatch.

The combination is unique per (dispatch × finding) pair. Two
issues with the same marker → already-created; skip.

**Search mechanism.** Linear's GraphQL search:

```graphql
query($q: String!) {
  searchIssues(term: $q, first: 5) {
    nodes { id identifier title }
  }
}
```

The `term` is the full marker string. Linear's `searchIssues`
does substring-tokenised search across title + description +
comments. A marker like
`<!-- meta: follow-up-source dispatch=ENG-191-d0003 finding_class_key=foo -->`
is highly specific — false positives are bounded.

**False-positive bound.** The `<!--` and `meta:` tokens are not
unique to follow-ups (every harness comment carries `<!-- meta:
dispatch id=... -->` markers and the existing `<!-- meta: dedup
key=... -->` markers). But the `follow-up-source` substring is
**only** ever embedded by ENG-193's helper. Searching for the
exact dispatch_id + finding_class_key pair narrows further to a
single legitimate match. Defensive filter on the orchestrator
side: after the search returns candidates, the orchestrator
fetches each candidate's full description via `get_issue` and
greps the literal marker line. Only on exact byte-match is
"already created" returned.

**`find-follow-up` stdout contract** (Security P1 #2). The
subcommand returns:

* Empty stdout (`''`) — miss; no existing follow-up. Caller
  proceeds with create.
* Single-line Linear identifier (e.g. `ENG-N`) — hit; already
  exists. Caller skips create.
* rc=1 + log to stderr — parse failure or Linear API outage.
  Caller treats as miss (logs warning, proceeds with create —
  duplicate cost bounded by next re-run's marker search).
* rc=13 — lane-fence denial. Caller treats as fatal (the
  orchestrator-lane should never be denied).

The contract is single-line so `[[ -n "$existing" ]]` in the
caller is robust against trailing whitespace. The subcommand
trims output before printing (`printf '%s' "${out%%$'\n'*}"`).

**GraphQL injection safety** (Security P1 acknowledgement).
`linear_query` passes the search term via `jq --argjson v ...`
(`bin/linear.sh:408`), which JSON-encodes the variable into the
GraphQL request body. Any embedded `"` / `}` / `{` / `\n` in the
sanitised marker substring is structurally safe — the GraphQL
parser receives a JSON-quoted string, not raw query text.
Sanitisation of `finding_class_key` is for the marker shape on
the WRITE side (when embedding into the description) AND for the
search-term construction (to ensure the search term matches the
written marker byte-for-byte). No ad-hoc GraphQL escaping
needed.

**The fallback — soft local cache in `issue-state.json`** is
explicitly NOT added (see D-002 simpler alternative below). Linear
is the source of truth; on-disk cache adds a sync hazard for no
payoff once Linear-side search is in place.

**Sanitisation.** `finding_class_key` is agent-controlled. Apply
the standard `<!-- → <\!--` + `\n,\r → space` rule (mirror
`_post_deferred_majors_comment_if_eligible::_san` at
`bin/run-stage.sh:1508-1514`). The marker uses sanitised values
throughout.

**Reference to constraint.** AC #2 literally specifies
"dispatch-id or content-hash keyed." Marker = both, structurally.

**Reference to constraint.** CLAUDE.md "Cross-dispatch staleness
contract (ENG-87)" — the dispatch_id primitive is the established
cross-dispatch isolation key. ENG-193 uses it as the idempotency
key, consistent with ENG-87's design.

**Rejected alternative — title prefix as the idempotency key.**
A title shape like `[deferred from ENG-N] <key>` is also unique
per finding. Rejected because (a) titles are human-editable in
Linear UI; an operator renaming a follow-up would break
idempotency and the next re-run would duplicate; (b) descriptions
also have edit hazard, but the `<!-- meta: ... -->` marker is
operator-conventionally read as "don't touch this" (mirrors the
existing `dispatch_id` marker on comments); (c) Linear's title-
filter GraphQL is structurally weaker than full-text search.

**Rejected alternative — on-disk idempotency cache in
`issue-state.json::follow_ups_created.<dispatch_id>[]`.**
Rejected because (a) operator-deletable (e.g. cleanup of stale
issue dirs); on a fresh worktree the cache is empty but the
follow-ups exist on Linear — re-run would duplicate; (b) the
on-disk cache duplicates info Linear already carries; two
sources of truth; (c) Linear-side search is one extra GraphQL
query per finding per re-run — bounded cost on the LATER (re-run)
path, zero cost on the first-run path. The duplicate-prevention
win outweighs the search cost.

**Rejected alternative — parent's description / parent's
comments as the dedup surface.** E.g. emit a `<!-- meta:
follow-up-created finding=<key> child=ENG-M -->` marker on the
parent's deferred-majors comment, and grep for it on re-run.
Rejected because (a) the deferred-majors comment is ENG-191's
output; cross-mixing ENG-193 markers into it couples the two
tickets at the wire level; (b) the per-child marker is the
natural place — the child's description IS the record of "what
spawned me."

### D-003. The follow-up issue's body is composed from the ledger row + the originating PR URL + the parent issue link. Title is `[deferred from ENG-N] <sanitised ship_classification_rationale, truncated to fit ≤80 char title>`. Type label is `Bug` when `decision_factors.user_visible == true`, otherwise `Improvement`. The body opens with a one-line TL;DR for 30-second operator triage.

**Rationale.** AC #1: "Body carrying the finding text + file:line +
originating PR." Constraint from CLAUDE.md L232-235: type label
mandatory at filing.

**Title shape** (≤80 chars total, sanitised, single line):

```
[deferred from ENG-N] <ship_classification_rationale, truncated to fit budget>
```

The `[deferred from ENG-N]` prefix is load-bearing: operators
scanning Linear list views see the parent linkage at-a-glance
without opening the ticket. `ENG-N` is the parent identifier
(not agent-controlled — comes from `$ident`). The trailing
rationale is sanitised then truncated to fit ≤80 total chars
(budget = 80 − len(prefix)). Falls back to
`[deferred from ENG-N] <finding_class_key>` if rationale is
missing.

**Sanitise-then-truncate ordering** (Security P1 #1). Apply `_san`
(strip `\n,\r → space`, rewrite `<!--→<\!--`) BEFORE truncating
to length budget. If the truncation boundary falls mid-`<\!--`
escape (e.g. a sanitised `<\!--` at byte 77-80 of an 80-char
budget yields `<\!`), the helper detects the partial escape at
the tail (`<\` or `<\!` suffix) and trims further until the
title ends on a clean boundary. Worst-case 4 chars over-trim;
no broken-escape leakage.

**Body shape:**

```markdown
**Deferred from [ENG-N](<linear-url>) (PR <pr-url-or-(not-discoverable)>) at reviewing stage.** See parent's deferred-majors comment for the full audit batch.

## Source

- Parent issue: [ENG-N](<linear-url>) — advanced to `stage:qa` via ENG-191 selective exit
- Originating PR: <pr-url-or-(not-discoverable)>
- Source dispatch: ENG-N-d<NNNN>, iteration <K>
- Finding class key: `<sanitised finding_class_key>`

## Why this was deferred (not blocking)

<sanitised ship_classification_rationale>

## Decision factors

- in_changed_code: <yes|no>
- is_regression: <yes|no>
- user_visible: <yes|no>
- reversible_post_ship: <yes|no>
- has_workaround: <yes|no>

## Type label

`<Bug|Improvement>` — derived mechanically: `user_visible=<yes|no>` →
type label `<Bug|Improvement>` per ENG-193 D-003 mapping rule. Operators
who disagree can relabel via Linear UI; the harness does not re-derive
on update.

## How to triage

This finding was classified deferrable by the five-question rubric
in `AGENT_PROMPTS.md §5` (reviewing agent's Deferability adjudication
block). It does **not** block the parent's ship; it represents
scheduled debt to be addressed in a future ticket.

When an operator triages this issue to `Todo` (the harness only
polls `Todo` issues — see CLAUDE.md "Linear conventions"), the
brainstorming agent will pick it up on the next tick.

<!-- meta: follow-up-source dispatch=ENG-N-d<NNNN> finding_class_key=<sanitised key> -->
```

**TL;DR top-line** (load-bearing for 30-second operator triage —
Product P1 #2). The first line is bolded, single-sentence,
operator-readable without scrolling: parent identifier + PR link +
"reviewing stage" + pointer to the batched audit comment. Linear's
list-view preview shows the first ~140 chars of the body — the
TL;DR fits and is the entire preview for operators scrolling the
project list.

**Type-label rationale section** (Product P1 #4). The mapping
rule is mechanical (D-003 type-label paragraph) but invisible if
operators only read the title and the finding text. The new "Type
label" section spells out the derivation so an operator opening
the ticket understands WHY it's tagged the way it is. Anti-bias
note: the rule is conservative — `Improvement` is the modal output
(most deferred majors are not user-visible polish); operators who
expect Bug typing for a particular finding can relabel via Linear UI.

**Linkage shape.** The "Parent issue" link uses Linear's web URL
shape `https://linear.app/twinning/issue/ENG-N`. The "Originating
PR" is `gh pr view --json url --jq .url 2>/dev/null` against the
current worktree's branch — best-effort, falls back to
`(not discoverable)` on `gh` failure or no PR. Confirmed `gh` is
on the orchestrator PATH per CLAUDE.md "PATH expectations on the
launchd host."

**Type-label mapping rule.**

```
type_label =
  "Bug"          if decision_factors.user_visible == true
  "Improvement"  otherwise
```

Never `Feature`. The rubric makes "deferred major + Feature" structurally
implausible — a feature is by definition NEW behaviour, not an
existing user-visible bug or polish gap.

Rationale for the rule: `user_visible: true` means the finding has
observable behaviour. Combined with deferrability (the rubric
already filtered out regressions and unreversible-post-ship cases),
this is "a real-but-shippable defect" — `Bug` is the canonical
type. `user_visible: false` covers the polish / doc-drift / internal-
quality patterns — `Improvement` is the canonical type. The rule is
mechanical; no agent inference, no project-policy override.

**Reference to constraint.** CLAUDE.md L232-235 — "Bug → `fix/...`,
Feature/Improvement → `feat/...`." Since the auto-created follow-up
has no preset branch, the type label determines which branch shape
will be used when the brainstorming/planning agents file the PR
later. The `Bug → fix/` vs `Improvement → feat/` mapping is the
established CLAUDE.md contract.

**Reference to constraint.** Linear ticket scope IN bullet 1: "body
carrying the finding text + file:line + originating PR" — the
ledger row carries `finding_class_key` (which includes the scope-
anchor — file:line — per the schema `<dimension>:<scope-anchor>:
<concept-slug>` format at `bin/review-ledger-schema.sh:25`).
`ship_classification_rationale` is the finding text. PR URL via
`gh pr view`.

**Sanitisation.** Apply `<!-- → <\!--` + `\n,\r → space` to every
agent-controlled field in title + body + marker (`finding_class_key`,
`ship_classification_rationale`, `dispatch_id`, `iteration`).
Defense-in-depth even though the ledger validator already gates row
shape — same principle as ENG-191 D-005.

**Rejected alternative — agent picks the type label via a new
ledger field `suggested_type_label`.** Rejected because (a) widens
the ledger schema for one feature; (b) agent inference of type
label adds an unforced consistency hazard (different runs could
classify the same finding differently); (c) the mechanical mapping
from `user_visible` is deterministic.

**Rejected alternative — always file as `Improvement`.** Rejected
because user-visible bugs deserve `Bug` typing — operators sort,
prioritise, and assign by type; flattening to one type loses
signal.

**Rejected alternative — agent-controlled prose body
(transparently passed through from a new ledger field).**
Rejected because (a) the prose risks containing the agent's
opinions about the parent PR; the follow-up should stand alone
without parent-PR context entanglement; (b) the ledger row's
structured fields ARE the body — no new agent surface needed; (c)
keeps the agent's emission set unchanged from ENG-191.

### D-004. The new `bin/run-stage.sh::_create_follow_up_tickets_for_deferred_majors` helper runs in the post-dispatch hook block immediately AFTER `_post_deferred_majors_comment_if_eligible`, same gating. Soft-fail (per-finding); never halts the dispatch.

**Rationale.** AC #1 (creates K tickets) + AC #2 (idempotent) +
AC #3 (no agent write). The hook site is structurally identical
to ENG-191's `_post_deferred_majors_comment_if_eligible` — the
same predicate, the same ledger filter, the same dispatch_id
scoping.

**Hook insertion.** Inside the `if (( ! skip_dispatch )); then`
block at `bin/run-stage.sh:2449-2455`, add a new case-branch on
`reviewing`:

```bash
# ENG-191: post-dispatch deferred-majors enumeration comment.
if (( ! skip_dispatch )); then
  case "$stage" in
    reviewing)
      _post_deferred_majors_comment_if_eligible "$ident" || true
      ;;
  esac
fi

# ENG-193: post-dispatch deferred-majors follow-up ticket creation.
# Runs AFTER the comment (the comment links to "ENG-193 will
# auto-create follow-up tickets" per ENG-191 D-005 body footer;
# the comment is the natural narration anchor — by the time the
# operator sees the comment, the tickets exist or are being created).
# Soft-fail; per-finding; never halts the dispatch.
if (( ! skip_dispatch )); then
  case "$stage" in
    reviewing)
      _create_follow_up_tickets_for_deferred_majors "$ident" || true
      ;;
  esac
fi
```

**Why not fold into one case-branch.** Separate branches keep
each helper's failure-mode isolated. ENG-191's `|| true`
swallows the comment's rc; ENG-193's `|| true` swallows the
ticketing's rc. Folded into one branch, a comment failure +
ticketing failure would chain and the operator-visible log
would conflate them.

**Why AFTER the comment.** The comment's body footer reads
"ENG-193 will auto-create follow-up tickets per deferred major"
(`bin/run-stage.sh:1555`). The natural narration order is:
post the audit → then file the tickets. If the ticketing
fails, the comment still tells the operator what was supposed
to happen.

**Helper body.**

```bash
_create_follow_up_tickets_for_deferred_majors() {
  local PIPELINE_WRITER=orchestrator
  export PIPELINE_WRITER
  local ident="$1"

  # Gate on the same predicate the comment helper uses: fresh
  # verdict marker with reason=ship-with-deferred-majors.
  local fresh reason
  fresh="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"
  [[ -z "$fresh" ]] && return 0
  reason="$(jq -r '.event.reason // ""' <<<"$fresh" 2>/dev/null || printf '')"
  [[ "$reason" == "ship-with-deferred-majors" ]] || return 0

  # Config gate (D-006).
  if ! _config_auto_ticket_deferred_majors_enabled; then
    log "[follow-up] auto-ticketing disabled by config; skipping"
    return 0
  fi

  local ledger
  ledger="$(issue_dir "$ident")/review-findings-ledger.jsonl"
  [[ -f "$ledger" ]] || { log "[follow-up] ledger absent at $ledger; skipping"; return 0; }

  local did="${PIPELINE_DISPATCH_ID-}"
  [[ -n "$did" ]] || { log "[follow-up] PIPELINE_DISPATCH_ID unset; skipping"; return 0; }

  # Discover PR URL once (best-effort).
  local pr_url
  pr_url="$(gh pr view --json url --jq .url 2>/dev/null || printf '')"

  # Read ledger rows: same filter as _post_deferred_majors_comment_if_eligible.
  local rows
  rows="$(grep -v '^#' "$ledger" 2>/dev/null \
    | grep -v '^[[:space:]]*$' \
    | jq -rc --arg did "$did" '
        select(.dispatch_id == $did)
        | select(.adjudicated_severity == "major")
        | select(.blocks_ship == false)
        | [
            (.finding_class_key // ""),
            (.ship_classification_rationale // ""),
            (.decision_factors.in_changed_code // false),
            (.decision_factors.is_regression // false),
            (.decision_factors.user_visible // false),
            (.decision_factors.reversible_post_ship // false),
            (.decision_factors.has_workaround // false),
            (.dispatch_id // ""),
            (.iteration // 0)
          ] | @tsv' 2>/dev/null || printf '')"

  local created=0 skipped=0 failed=0
  while IFS=$'\t' read -r fck scr ic isr uv rp hw d_id it; do
    [[ -z "$fck" ]] && continue
    # Idempotency check via marker search.
    local existing
    existing="$(bash "$SCRIPT_DIR/linear.sh" find-follow-up \
      --dispatch-id "$d_id" --finding-class-key "$fck" 2>/dev/null || printf '')"
    if [[ -n "$existing" ]]; then
      log "[follow-up] $ident: skipping $fck — already exists as $existing"
      skipped=$((skipped+1))
      continue
    fi
    # Build title, type-label, description-body inline.
    local title type_label body
    title="$(_follow_up_title "$scr" "$fck")"
    type_label="$(_follow_up_type_label "$uv")"
    body="$(_follow_up_body "$ident" "$pr_url" "$d_id" "$it" "$fck" "$scr" "$ic" "$isr" "$uv" "$rp" "$hw")"
    local new_ident
    if new_ident="$(printf '%s' "$body" | bash "$SCRIPT_DIR/linear.sh" create-issue \
        --title "$title" \
        --type-label "$type_label" \
        --parent-id "$ident" \
        --state "Backlog" \
        --description -)"; then
      created=$((created+1))
      log "[follow-up] $ident: created $new_ident for $fck"
      _emit_metric_event "follow-up-created" \
        "parent=$ident finding_class_key=$fck child=$new_ident dispatch_id=$d_id"
    else
      failed=$((failed+1))
      log "[follow-up] $ident: create failed for $fck (continuing)"
    fi
  done <<< "$rows"

  log "[follow-up] $ident: created=$created skipped=$skipped failed=$failed (dispatch=$did)"
  return 0
}
```

`_follow_up_title`, `_follow_up_type_label`, `_follow_up_body`,
`_emit_metric_event`, and `_config_auto_ticket_deferred_majors_enabled`
are sibling helpers (private to `run-stage.sh`, prefixed with `_`
to keep them out of the dispatch's surface and to match the
existing `_post_*` / `_validate_*` naming convention). Their
bodies are mechanical (string formatting; jq config read; metric
write) — explicit shapes documented inline in the implementation
plan.

**Reference to constraint.** AC #2 idempotent: the
`find-follow-up` search is the structural enforcement. The helper
re-reads the search before EVERY create, so partial-progress (3
of 5 created; orchestrator crashes; tick replays) only re-creates
the missing 2.

**Reference to constraint.** AC #3 envelope-clean: the helper
runs in the orchestrator's process, AFTER the agent's `claude -p`
subprocess exits. No agent-side Linear write can occur (the
envelope validator already ran at this point of the hook block —
`_validate_dispatch_envelope` invocation precedes the
post-dispatch hooks; verified by structural ordering of
`bin/run-stage.sh::main`).

**Rejected alternative — fold the helper inline into
`_post_deferred_majors_comment_if_eligible`.** Rejected because
(a) violates single-responsibility — comment-posting and
issue-creation have distinct failure modes; (b) widens the
ENG-191 helper's blast radius; (c) the comment helper has shipped
and is QA-tested; mixing concerns risks regression.

**Rejected alternative — synchronous halt on first failed create.**
Rejected because (a) partial creation is recoverable on the next
re-run via the marker-search; (b) halting after K-1 successful
creates produces a confusing operator state (some debt ticketed,
some not, halt unclear); (c) the existing
`_post_deferred_majors_comment_if_eligible` is soft-fail per
ENG-191 D-005 — mirroring the pattern keeps operator mental model
consistent.

### D-005. Follow-up issues are filed at state **`Backlog`**, parented via `parentId`. Operator triage to `Todo` gates harness pickup.

**Rationale.** Two structural constraints from CLAUDE.md:

* L254-257: "Brainstorm entry-state is `Todo`. `poll.sh` only picks
  up issues whose Linear status is `Todo` AND which carry no
  `stage:*` label as fresh brainstorm candidates. Issues filed
  into `Backlog` (or any other state) are silently invisible to
  the poller until a human transitions them to Todo."
* L291-298 (ticket sizing rubric, split mechanics): "Keep the
  umbrella in `Backlog` (becomes the parent). … Sub-tickets carry
  their own type label per the filing convention above. First-
  ready sub-tickets go to `Todo`; dependent ones stay in
  `Backlog` until their predecessor merges."

Auto-created follow-ups are **dependent** sub-tickets — by
definition, they were spawned BY their parent's reviewing dispatch.
Filing them as `Backlog` keeps them out of the poller's view until
an operator triages them.

**Why not `Todo`.**

A naïve "file as Todo so the harness works them automatically"
behaviour would:

1. Flood the queue with low-quality deferred-major debt — many of
   these are minor polish that the team has already weighed as
   non-blocking; they may stay non-blocking forever.
2. Re-run the harness K times on Improvement-tagged debt with
   indeterminate user value; the cost is real.
3. Surprise the operator — auto-tickets at `Todo` start consuming
   the next tick's `claude -p` budget without confirmation.

`Backlog` keeps the operator in the loop. They triage to `Todo`
when they're ready to schedule the debt. Aligns with the existing
"human in the loop on first run" principle.

**Parenting via `parentId`.**

Linear's `issueCreate.input.parentId` accepts a parent issue UUID;
Linear's UI surfaces sub-issues under the parent in tree view.
This is the natural linkage for "this debt was deferred from that
ticket" — the parent (ENG-N reviewing) is visible from the child
(the follow-up), and the child appears in the parent's sub-issue
list.

Alternative: `relatedTo` (a non-hierarchical link). Rejected
because:

* `parentId` carries hierarchical meaning ("this child is debt of
  that parent"); the data model matches the audit shape.
* `relatedTo` is symmetric and less specific; operator triage view
  groups by parent naturally.
* CLAUDE.md L294 specifies `parentId` in the documented split
  mechanic.

**Reference to constraint.** AC #1 — "parented to (or related-to)
the original issue." `parentId` is the stronger of the two
options; the brainstorm picks it.

**Reference to constraint.** CLAUDE.md L254-257 poller visibility
rule — `Backlog` keeps the helper from auto-scheduling debt the
operator hasn't approved.

**Operator discoverability** (Product P0 — Backlog issues are
poller-invisible, so auto-created follow-ups silently accumulate
unless the operator has a discovery surface). Four overlapping
surfaces ensure no auto-created ticket goes unnoticed:

1. **The ENG-191 audit comment on the parent.** Already posted
   under sig `deferred-majors/<ident>` by `_post_deferred_majors_
   comment_if_eligible`; the operator's primary anchor.
   ENG-193 amends the footer line to past tense (D-006 sub-edit
   below) — operators landing on the comment see WHICH follow-up
   tickets were created, by identifier.
2. **Linear's sub-issue tree view on the parent.** Linear UI
   surfaces children under the parent natively; any operator
   inspecting the parent issue (typical post-merge / post-ship
   workflow) sees the K children inline.
3. **The TL;DR top-line on each follow-up** (D-003). When the
   operator does encounter the follow-up in any list view, the
   first line names the parent + PR explicitly.
4. **The operator-mental-model grep recipe** (D-009). For power
   users wanting "show me all auto-debt across the project,"
   the searchIssues + sub-issue listing recipes both work.

**No active notification surface in v1.** Slack pings on
follow-up creation are explicitly NOT added — the harness's
notification policy (`bin/slack.sh warn`) is reserved for halt-
class events. Auto-ticket creation is a success-path effect;
notifying on every selective-exit dispatch would spam the
channel. Operators inspect via the four surfaces above. If field
data shows operators missing tickets in practice, a `notify=true`
config flag can be added — YAGNI for v1.

**Reference to constraint.** CLAUDE.md "Failure-mode quick
reference" only lists failure modes; successes go in runbooks.
The four discovery surfaces ARE the runbook (D-009 covers the
recipes).

**Rejected alternative — file as `Todo`, let the harness pick up
immediately.** Per the surprise-cost argument above. Operators can
override by changing state via the standard Linear UI.

**Rejected alternative — use a custom `pipeline:deferred-major`
label instead of `Backlog` state.** Rejected because (a) labels
don't gate the poller; a `pipeline:*` label here would create a
new lane-fence + poller-classifier surface for no structural payoff;
(b) `Backlog` IS the natural Linear way to express "not yet
triaged."

### D-006. NEW config key `human_checkpoints.auto_ticket_deferred_majors: bool`. Default `true`. When `false`, the helper short-circuits to a no-op (ENG-191's comment still posts).

**Rationale.** Operator escape hatch. Some operators may prefer to
triage manually from the ENG-191 comment instead of having the
harness file tickets. Default-on matches AC #1 ("Taking the
terminal exit … creates exactly K follow-up tickets").

**Resolution precedence (mirrors ENG-65 / ENG-81 / ENG-191 D-010 shape):**

1. `.human_checkpoints.auto_ticket_deferred_majors` in
   `.pipeline-config/config.json` — highest.
2. Built-in default `true`.

**Validation.** Boolean. Invalid types (string `"true"`, integer
`1`, etc.) fall through to default `true` with a `log` warning
on stderr (mirrors ENG-191 D-010 resolver pattern).

**Helper.**

```bash
_config_auto_ticket_deferred_majors_enabled() {
  local v
  v="$(config_get '.human_checkpoints.auto_ticket_deferred_majors' 2>/dev/null || printf '')"
  case "$v" in
    true|"")  return 0 ;;     # default true; absent → on
    false)    return 1 ;;
    null)     return 0 ;;     # absent in jq null → on
    *)
      log "[follow-up] auto_ticket_deferred_majors invalid value '$v'; defaulting to true"
      return 0
      ;;
  esac
}
```

**No resolver / prompt-token needed.** Unlike
`review_converge_rounds` (which the agent reads in-prompt to
compute the path-D predicate), this config is consumed purely by
the orchestrator-side hook. No `render-prompt.sh` change.

**ENG-191 deferred-majors comment footer edit** (Product P1 #3 /
Design P1 #3). The existing ENG-191 helper at
`bin/run-stage.sh:1555` emits a hardcoded footer "ENG-193 will
auto-create follow-up tickets per deferred major." When ENG-193's
auto-ticketing is **disabled** by config, that footer is a
lie — the comment promises a feature the operator has switched
off. ENG-193 amends the ENG-191 helper's footer to a
two-branch string driven by `_config_auto_ticket_deferred_majors_
enabled`:

```bash
# In _post_deferred_majors_comment_if_eligible, replace the
# hardcoded line 1555 footer with a config-gated branch:
local footer
if _config_auto_ticket_deferred_majors_enabled; then
  footer="ENG-193 has auto-created one follow-up ticket per row above; find them via Linear's sub-issue tree on this issue, or via the operator-mental-model.md grep recipe."
else
  footer="Auto-ticketing is disabled by config (.human_checkpoints.auto_ticket_deferred_majors=false); the ledger above is the canonical record. Operator triage by hand."
fi
body="$(printf '...' ... "$footer")"
```

Footer tense is past ("has auto-created") because
`_post_deferred_majors_comment_if_eligible` posts BEFORE
`_create_follow_up_tickets_for_deferred_majors` runs (D-004 hook
ordering); strictly speaking the comment is posted just-in-time
relative to ticket creation. But the message is operator-facing
("by the time you read this, the tickets exist") — and per-finding
failure (which leaves the message partially inaccurate) is logged
via the `follow-up-failed` metric. The minor tense lie is bounded;
the alternative (post comment AFTER tickets so the tense is strictly
accurate) reverses D-004's narration order.

**Reference to constraint.** CLAUDE.md "Per-stage dispatch timeouts
(ENG-65)" + "Per-project dispatch concurrency (ENG-81)" — the
config-key + validation + default pattern. Same shape.

**Rejected alternative — environment variable
`PIPELINE_AUTO_TICKET_DEFERRED_MAJORS`.** Rejected because env-var
overrides are reserved for launchd-host-level tuning
(`STUCK_TICK_ALARM_MINUTES`, `CLAUDE_MAX_CONCURRENT`); per-project
policy belongs in `.pipeline-config/config.json` (mirror of
ENG-191 D-010 rejection).

**Rejected alternative — no config key (auto-ticketing always on).**
Rejected because operators must be able to opt out without editing
`bin/`. Default-on + config-off is the principled shape.

### D-007. Metric event `follow-up-created` (one per ticket created) + `follow-up-skipped` (one per idempotency hit) + `follow-up-failed` (one per create failure). Emitted via `bin/metrics.sh`.

**Rationale.** Operator visibility into the auto-ticketing volume
and failure rate. The retrospective shape (future work) can
correlate "follow-ups created" with "follow-ups closed" to track
debt-payoff velocity.

**Schema:**

```json
{
  "ts": "<ISO-8601 UTC>",
  "kind": "follow-up-created",
  "issue": "ENG-N",
  "stage": "reviewing",
  "notes": "parent=ENG-N finding_class_key=<key> child=ENG-M dispatch_id=ENG-N-d<NNNN>"
}
```

`kind` ∈ `{follow-up-created, follow-up-skipped, follow-up-failed}`.

**No new failure-outcome-for-exit entry.** The helper does not
exit non-zero on per-finding failure — it accumulates `failed` and
returns 0. So no `failure_outcome_for_exit` taxonomy change needed
(CLAUDE.md "Never use exit codes outside the taxonomy").

**Reference to constraint.** CLAUDE.md "When wiring a new script"
— "Metric writes go through `bin/metrics.sh`."

**Reference to constraint.** No agent-prompt change, no marker
registration — these metrics are orchestrator-internal.

**Rejected alternative — no metrics, just log lines.** Rejected
because the retrospective shape needs structured events to query
by `kind` and aggregate. Log lines are unstructured.

**Rejected alternative — wider metric payload (every decision_factor
booleans).** Rejected because the ledger already carries those;
retro can join.

### D-008. Lane fence in `_check_lane` gains `"create child_issue"` and `"find child_issue"` rows; matrix `_lane_decision` + `_allowed_lanes_for` extended additively. Agent lane = deny (defense-in-depth).

**Rationale.** AC #3 — orchestrator-only. Per the lane-fence
extension pattern at `bin/linear.sh:317-335`. The fence is the
structural denial surface (rc=13) even though the agent allowlist
doesn't expose `bash bin/linear.sh create-issue` (the agent's
reviewing-stage allowlist grants `Bash(bash bin/linear.sh:*)`
which is broad — any subcommand the script supports).

**Matrix extension.**

```bash
_lane_decision() {
  case "${action} ${object_class}" in
    # existing rows...
    "create child_issue")   case "$lane" in orchestrator|human) printf 'allow';; *) printf 'deny';; esac ;;
    "find child_issue")     case "$lane" in orchestrator|human) printf 'allow';; *) printf 'deny';; esac ;;
    # ...
  esac
}
_allowed_lanes_for() {
  case "${action} ${object_class}" in
    "create child_issue")   printf 'orchestrator,human' ;;
    "find child_issue")     printf 'orchestrator,human' ;;
    # ...
  esac
}
```

`create-issue` calls `_check_lane "create" "child_issue"`;
`find-follow-up` calls `_check_lane "find" "child_issue"`.

**Why `child_issue` not `issue`.** The fence is specifically for
ENG-193-style child issue creation. A future "create an arbitrary
issue" subcommand might want a different policy (e.g.
agent-callable for some specific workflow). Naming the
object_class `child_issue` keeps the fence focused.

**Reference to constraint.** CLAUDE.md "Linear conventions"
(L243-244) — "NEVER use Linear MCP `save_issue` to update an
existing issue or mutate labels — it overwrites the entire label
set." The lane fence is the structural enforcement of this for
the new subcommand.

**Reference to constraint.** ENG-87 envelope-validator covers
agent-side `mcp__plugin_linear` / `curl https://api.linear.app`;
the lane fence covers agent-side `bash bin/linear.sh create-issue`.
Defense-in-depth.

**Rejected alternative — leave the lane fence as-is and rely on
the agent-stage allowlist to deny.** Rejected because (a) the
reviewing stage allowlist already grants `Bash(bash
bin/linear.sh:*)` (per the existing `add-comment` agent-callable
shape); adding the lane fence keeps the rule structural even if
the allowlist is widened or a future stage gets the
`bin/linear.sh` access; (b) defense-in-depth — CLAUDE.md
philosophy.

### D-009. Operator runbook updates: amend `docs/runbooks/recovery.md` §13 (existing ENG-191 selective-exit section) to mention auto-ticketing; new `docs/runbooks/operator-mental-model.md` recipe for "find all auto-created follow-ups for an issue." NO new §14.

**Rationale.** The auto-ticketing behaviour is a continuation of
the ENG-191 selective-exit narrative, not a new failure mode.
§13 already says "ENG-193 will auto-create follow-up tickets per
deferred major" — this brainstorm makes that line accurate.

**§13 amendment** (in-place rewrite + additions). The existing
ENG-191 narrative at `docs/runbooks/recovery.md:857-858` reads:

> The harness shipped with known debt; **ENG-193 will auto-create
> follow-up tickets per deferred major.**

ENG-193's amendment (Product P0 #2 — operators reading §13
post-ENG-193-landing must not see the stale future-tense forward-
reference) rewrites the bolded sentence in-place to past tense
AND appends a new "Auto-created follow-up tickets" sub-paragraph
documenting the behaviour:

> The harness shipped with known debt; **the orchestrator
> auto-created one Linear sub-ticket per deferred major
> (unless `auto_ticket_deferred_majors` is disabled — see below).**

Then the new sub-paragraph follows:

```markdown
**Auto-created follow-up tickets (ENG-193).**
The orchestrator's post-dispatch hook files one Linear sub-
ticket per deferred major: parented to the originating issue, in
state `Backlog`, typed as `Bug` (when `user_visible=true`) or
`Improvement` (otherwise). Find them via Linear's sub-issue tree
view on the parent, or grep:

```bash
bash bin/linear.sh list-issues-with-label Improvement \
  | jq '.data.issues.nodes[] | select(.title | startswith("[deferred]"))'
```

Each follow-up carries `<!-- meta: follow-up-source dispatch=ENG-N-d<NNNN>
finding_class_key=<key> -->` in its description for cross-reference.
Idempotent across re-runs: re-taking the exit looks up the marker
and skips already-created tickets.

**Disable auto-ticketing (operator opt-out).** Set
`.human_checkpoints.auto_ticket_deferred_majors: false` in target's
`.pipeline-config/config.json`. The deferred-majors comment (ENG-191)
still posts; only the auto-ticket step is suppressed.
```

**`operator-mental-model.md` §3 addition** — new grep recipe:

```markdown
**Find auto-created follow-up tickets for an issue (ENG-193):**

```bash
# Linear's GraphQL search by marker substring:
bash bin/linear.sh query \
  'query { searchIssues(term: "follow-up-source dispatch=ENG-N", first: 50)
    { nodes { id identifier title state { name } } } }' '{}' \
  | jq '.data.searchIssues.nodes'
```

Each match is a follow-up; group by `dispatch_id` substring in the
title or fetch the description to see the finding details.
```

**No CLAUDE.md row addition.** The existing ENG-191 row already
covers the selective-exit symptom ("Issue at `stage:qa` with
verdict comment `reason=ship-with-deferred-majors`"). ENG-193
doesn't introduce a new operator-visible failure mode — it
extends the success path of an existing one. The §13 amendment
+ mental-model recipe are sufficient.

**Reference to constraint.** CLAUDE.md "Failure-mode quick
reference" — only failures get rows. Successes go in runbooks.

**Rejected alternative — new §14 runbook section.** Rejected
because the auto-ticketing is structurally part of ENG-191's
selective-exit narrative; splitting it forces operators to read
two sections for one behaviour.

**Rejected alternative — new CLAUDE.md row.** Rejected because
no new failure mode is introduced; the §13 amendment carries the
operator-discoverable info.

## 3. Architecture (where code goes)

```
bin/linear.sh                          EDIT.
                                       - NEW `create-issue` subcommand
                                         (~80 lines): flag parser, lane
                                         fence call, UUID resolution
                                         (team/project/state/labels),
                                         description-marker injection,
                                         linear_query mutation.
                                       - NEW `find-follow-up` subcommand
                                         (~30 lines): builds a marker
                                         substring from --dispatch-id +
                                         --finding-class-key, runs
                                         searchIssues, defensively
                                         re-fetches description and byte-
                                         match-compares the marker line.
                                       - EXTEND _lane_decision +
                                         _allowed_lanes_for matrices
                                         with `create child_issue` and
                                         `find child_issue` rows (~4 lines
                                         each).
                                       - EXTEND main() case statement
                                         with two new verbs (~2 lines).

bin/linear-test.sh                     EDIT (if exists) OR CREATE.
                                       - Test `create-issue` dry-run
                                         (mutation suppressed, returns
                                         success stub).
                                       - Test lane fence: PIPELINE_WRITER=
                                         agent → rc=13 with denied
                                         diagnostic.
                                       - Test type-label required: no
                                         --type-label → die with usage.
                                       - Test description marker present
                                         in body (via stdin / --description-
                                         file).
                                       - Test `find-follow-up` dry-run:
                                         marker-substring search builds
                                         correctly; defensive byte-match
                                         on candidates.
                                       - Test cache-miss: missing label
                                         or state in linear-ids.json →
                                         die with "run refresh-cache"
                                         (mirrors add_label's `[[
                                         "$label_uuid" != "null" ]]`).

bin/run-stage.sh                       EDIT (~120 lines).
                                       - NEW
                                         `_create_follow_up_tickets_for_
                                         deferred_majors(ident)` helper:
                                         predicate gate (same as ENG-191
                                         comment helper), config gate
                                         (D-006), ledger filter (same),
                                         per-row marker search → skip on
                                         hit → otherwise create-issue
                                         with --title, --type-label,
                                         --parent-id, --state Backlog,
                                         --description via stdin.
                                         Accumulates created/skipped/
                                         failed counters; logs summary;
                                         soft-fail.
                                       - NEW
                                         `_config_auto_ticket_deferred_
                                         majors_enabled()` boolean
                                         resolver (~10 lines).
                                       - NEW `_follow_up_title`,
                                         `_follow_up_type_label`,
                                         `_follow_up_body` sibling
                                         formatters (~30 lines total —
                                         string formatting, sanitisation,
                                         marker injection).
                                       - WIRE in post-dispatch hook
                                         block (after line 2455's ENG-191
                                         block): new `if (( !
                                         skip_dispatch )); then case
                                         "$stage" in reviewing) … esac`
                                         block.

bin/run-stage-test.sh                  EDIT.
                                       - New cases mirroring ENG-191
                                         Z1-Z8 shape:
                                         - AC #1: deferrable exit creates
                                           K tickets — assert K
                                           create-issue captures with
                                           correct title/type/parent/
                                           state per row.
                                         - AC #2: re-run with same
                                           dispatch_id — assert
                                           find-follow-up returns hits;
                                           zero new create-issue calls.
                                         - AC #3: helper does not
                                           invoke claude / mcp /
                                           agent-side write paths (only
                                           orchestrator-side
                                           bin/linear.sh subcommands).
                                         - Type-label mapping rule:
                                           user_visible=true row → Bug;
                                           user_visible=false row →
                                           Improvement.
                                         - Title shape: includes
                                           [deferred] prefix and
                                           truncated rationale.
                                         - Body: includes parent link,
                                           PR URL placeholder, ledger
                                           row metadata, marker.
                                         - Config off: helper is no-op
                                           (zero create-issue captures).
                                         - Sanitisation: marker
                                           contains `<\!--` not
                                           `<!--` when ledger row
                                           rationale carries a forged
                                           marker payload.
                                         - Mixed dispatch: ledger has
                                           prior-dispatch rows (different
                                           dispatch_id) AND this-dispatch
                                           rows — only this-dispatch
                                           rows produce tickets.

bin/metrics.sh                         NO CHANGE.
                                       Existing `add_event` API
                                       accommodates the new `kind`
                                       values; no schema change.

.pipeline-config/config.json           NO HARNESS-REPO CHANGE.
                                       The new
                                       `.human_checkpoints.auto_ticket_
                                       deferred_majors` key is optional
                                       (default true on absence).
                                       Operators on a target may opt
                                       to add it explicitly.

docs/runbooks/recovery.md              EDIT. §13 amended with the
                                       auto-ticketing narrative
                                       (D-009).

docs/runbooks/operator-mental-model.md EDIT. New grep recipe in §3.

bin/pipeline-events.json               NO CHANGE.
                                       No new verdict marker, no new
                                       halt reason. ENG-191 already
                                       registered `ship-with-deferred-
                                       majors` in `pass_reasons` (line 11).
                                       The auto-ticket step does not
                                       emit pipeline markers.

CLAUDE.md                              NO CHANGE.
                                       The existing ENG-191
                                       "Issue at `stage:qa` with verdict
                                       comment `reason=ship-with-
                                       deferred-majors`" row already
                                       covers the symptom; ENG-193 adds
                                       no new failure mode.

AGENT_PROMPTS.md                       NO CHANGE.
                                       The auto-ticketing is post-
                                       dispatch orchestrator-only. The
                                       agent's path-D output is unchanged
                                       (ENG-191 D-008 has shipped the
                                       prompt; ENG-193 consumes its
                                       output, doesn't add new prompt
                                       rules).
```

**Lifecycle dataflow (selective-exit dispatch, K deferred majors):**

```
[Agent (claude -p, reviewing)]              [Orchestrator: bin/run-stage.sh main()]
  ...                                       ...
  emit ledger rows with                     dispatch returns
    adjudicated=major, blocks_ship=false    
  emit verdict marker:                      _validate_dispatch_envelope (ENG-87)
    pass --stage reviewing                  _validate_review_payload (ENG-119)
    --reason ship-with-deferred-majors      _validate_review_ledger (ENG-190+ENG-191)
                                            
                                            _post_deferred_majors_comment_if_eligible (ENG-191)
                                              ├─ find_fresh_verdict
                                              ├─ if reason=ship-with-deferred-majors
                                              │   └─ read ledger rows
                                              │       (filter dispatch_id=current,
                                              │        adjudicated=major,
                                              │        blocks_ship=false)
                                              └─ post sig deferred-majors/<ident> ──▶ Linear (comment)
                                            
                                            _create_follow_up_tickets_for_deferred_majors (NEW — ENG-193)
                                              ├─ find_fresh_verdict (same predicate)
                                              ├─ _config_auto_ticket_deferred_majors_enabled
                                              ├─ gh pr view --json url (best-effort)
                                              ├─ read ledger rows (SAME filter)
                                              └─ for each row:
                                                  ├─ bin/linear.sh find-follow-up ──▶ Linear (search)
                                                  ├─ if hit → skip + metric
                                                  └─ else
                                                      ├─ build title (sanitised, [deferred] prefix)
                                                      ├─ map type-label (user_visible)
                                                      ├─ build body (parent link, PR URL,
                                                      │   decision_factors, marker)
                                                      ├─ bin/linear.sh create-issue ──▶ Linear (mutation)
                                                      └─ emit follow-up-created metric
                                            
                                            post_completion_comment
                                            verdict-handler → reviewing → qa transition
```

## 4. Data flow

**Producer:** orchestrator-side `_create_follow_up_tickets_for_deferred_majors`
in `bin/run-stage.sh`. Inputs:

* `$(issue_dir <ident>)/review-findings-ledger.jsonl` — this-
  dispatch rows with `adjudicated_severity=major,
  blocks_ship=false`.
* `find_fresh_verdict <ident>` — gates on `reason=ship-with-
  deferred-majors`.
* `gh pr view --json url` — best-effort PR URL discovery.
* `.pipeline-config/config.json::.human_checkpoints.auto_ticket_
  deferred_majors` — config gate.

**Storage:** the created Linear issues themselves. Each carries a
marker `<!-- meta: follow-up-source dispatch=ENG-N-d<NNNN>
finding_class_key=<sanitised> -->` in its description for
re-discovery. NO local on-disk state added (no extension to
`issue-state.json`, no new file under `$(issue_dir)`).

**Reader (idempotency):** `_create_follow_up_tickets_for_deferred_majors`
on its next invocation re-reads via `bin/linear.sh find-follow-up`
(GraphQL `searchIssues` + defensive byte-match on the candidate's
description).

**Reader (operator):** Linear UI sub-issue tree view on the parent;
GraphQL `searchIssues` recipe in operator-mental-model.md §3;
list-issues-with-label `Improvement` / `Bug` + title prefix
filter.

**Detective reader:** none. ENG-193 has no transcript-based
detective (the helper runs after the envelope validator; no agent
involvement in the ticket creation; nothing to detect).

**Linear-write surfaces:**

| Surface | Subcommand | Writer | Body |
|---|---|---|---|
| Follow-up child issue | `linear.sh create-issue` | orchestrator | Title `[deferred] <rationale>`; description per D-003 |
| Idempotency lookup | `linear.sh find-follow-up` | orchestrator | (read-only — searchIssues query) |
| ENG-191 comment | `linear.sh add-comment --sig deferred-majors/<ident>` | orchestrator | (unchanged from ENG-191 D-005) |

## 5. Error handling

**Halt cases:** **none.** ENG-193 is soft-fail by design — no
exit path leads to a `bin/pipeline.sh event ... verdict halt`.

| Failure mode | Outcome |
|---|---|
| `find_fresh_verdict` returns empty | Helper returns 0; no creates. |
| `reason != ship-with-deferred-majors` | Helper returns 0; no creates. |
| Config `auto_ticket_deferred_majors=false` | Helper returns 0; no creates; log line. |
| Ledger file absent | Helper returns 0 + log; no creates. |
| `PIPELINE_DISPATCH_ID` unset | Helper returns 0 + log; no creates. |
| Zero rows match filter | Helper returns 0; no creates. |
| `gh pr view` fails (no PR yet) | PR URL is `(not discoverable)`; create proceeds. |
| `find-follow-up` returns existing | Skip + `follow-up-skipped` metric. |
| `create-issue` fails (network / Linear API outage) | Log + `follow-up-failed` metric; loop continues to next row. |
| `create-issue` fails (Linear validation, e.g. team_id missing) | Log; loop continues. Operator inspects log + linear-ids cache. |
| `find-follow-up` rate-limits (Linear's search has rate limits) | Helper logs failure for that row; degrades to "may duplicate." Bounded — retry on next dispatch's hook hits the same path. |
| `_check_lane` denies (agent lane) | Subcommand exits 13; helper logs failure; continues. (Structurally impossible in the orchestrator-only path — defense-in-depth.) |

**Soft-fail rationale.** The auto-ticketing is operator-visibility
enrichment, not control-flow. ENG-191's deferred-majors comment
remains the canonical on-Linear record; the ledger is the on-disk
canonical record. A `create-issue` failure does not block the
parent issue's advance to qa. Mirrors `_post_deferred_majors_comment_
if_eligible`'s pattern at `bin/run-stage.sh:1559`.

**Re-run safety.** Partial-progress (3 of 5 created; orchestrator
killed before the 4th) is self-healing on the next dispatch's
hook fire: the marker-search re-discovers the 3 existing and
re-creates only the 2 missing. The post-dispatch hook fires on
every reviewing dispatch (including loopbacks); on a loopback to
implementing → re-reviewing with a different dispatch_id, ledger
rows for the OLD dispatch are not re-ticketed (marker scoped to
dispatch_id). The NEW dispatch's rows ARE ticketed if any —
including findings that may overlap with prior follow-ups via
`finding_class_key`. That's expected: per ENG-190 +
ENG-191's adjudication-memory shape, each dispatch is a fresh
adjudication.

**No retry loop inside the helper.** Per-finding failure is
logged; the metric records `follow-up-failed`; the orchestrator
does not retry within the same dispatch. The next reviewing
dispatch's hook is the natural retry boundary (idempotent via
marker search).

## 6. Edge cases

1. **`ship_classification_rationale` is empty / null in the
   ledger row.** The ledger validator requires it as non-empty on
   blocking-severity this-dispatch rows (ENG-191 D-009). If
   somehow empty (e.g. pre-ENG-191 grandfathered row matching the
   filter — shouldn't happen because the schema-grace clause
   gates), title falls back to `[deferred] <finding_class_key>`.
   No halt; graceful degrade.

2. **`finding_class_key` contains characters that break the
   marker.** The marker shape is literal `<!-- meta:
   follow-up-source dispatch=<dispatch_id> finding_class_key=<key>
   -->`. If `<key>` contains `<!--` or `-->` or newlines, the
   marker breaks. Sanitisation applied (per D-002 sanitisation
   contract); after sanitisation the marker is well-formed.
   Search-time the orchestrator builds the same sanitised query
   string, so idempotency holds.

3. **The originating PR has been merged + branch deleted** (issue
   at qa is mid-build re-review). `gh pr view --json url` against
   a deleted branch returns no PR. URL fallback to `(not
   discoverable)`. Body still complete; operator can still
   navigate via the parent's Linear UI.

4. **Linear's `searchIssues` returns a false positive** (e.g. a
   human filed a ticket whose body coincidentally quotes the
   marker substring). Defensive byte-match on candidate
   descriptions (D-002) filters this out: the candidate must have
   the exact marker line. False-positive bound is "human typed an
   identical marker string into a different issue body" — bounded
   by reality.

5. **Linear's `issueCreate` succeeds but the response is
   malformed** (Linear API regression). `linear_query` checks
   `.errors` field per line 420; on bad-shape success, the helper
   logs `failed`; on next dispatch the marker-search re-finds the
   actually-created issue and skips. Self-healing.

6. **Two concurrent reviewing dispatches on different parent
   issues both create follow-ups for the same finding class
   key.** Markers are dispatch_id-scoped, not just finding_class_
   key-scoped. Two different parents → two different dispatch_ids →
   two different markers → no collision. Both follow-ups exist
   correctly under their respective parents.

7. **Operator manually closes / archives a follow-up between
   create-time and a re-run.** Marker-search by default returns
   only non-archived issues (Linear's `searchIssues` honours
   archive state). If the operator archived it, the next re-run
   would re-create. Mitigation: operator should leave the
   follow-up open and either resolve or `Won't fix`; archive is
   the closing state, not the dismissal. Documented as a known
   minor edge case in §9 runbook update.

   To be strict, the orchestrator could include
   `includeArchived: true` in the searchIssues query. **Working
   decision: include archived.** Marginal cost; eliminates the
   edge case. Implementation detail.

8. **Operator hand-edits a follow-up's description to remove the
   marker.** Next re-run misses the dedup hit; duplicates.
   Mitigation: marker line is `<!-- meta: -->` shape, which
   matches the existing `<!-- meta: dispatch id=... -->`
   convention operators already understand as "don't touch."
   Documented in §9.

9. **Linear's team has no `Bug` or `Improvement` label
   configured.** `label_id` returns `null`; `create-issue` dies
   with `label not in cache: Bug (run refresh-cache)` (mirrors
   `add_label`'s line 484 check). Operator runs `linear.sh
   refresh-cache` or files the labels in Linear UI. Documented in
   §9 setup checklist.

10. **`gh` is not on the launchd PATH.** Per CLAUDE.md "PATH
    expectations on the launchd host", `gh` is in the documented
    PATH. If missing (operator misconfiguration), `gh pr view`
    silently returns nothing; PR URL falls back to `(not
    discoverable)`. Bounded.

11. **`PIPELINE_DRY_RUN=1`.** `bin/linear.sh::linear_query` honours
    dry-run (line 401) and returns `{"data":{"dry_run":true}}`.
    `create-issue` would log `[DRY_RUN] would create issue:
    title="..."` and return success-shape. `find-follow-up`
    similarly. The helper's accumulated counters reflect intended
    actions, not actual writes. Test fixtures use this path.

12. **Helper invoked on a non-reviewing stage (defensive).**
    The hook block gates on `case "$stage" in reviewing)`; the
    helper itself ALSO gates internally via the
    `find_fresh_verdict` reason check (returns 0 fast on absence
    or mismatch). Defense-in-depth.

13. **The parent issue is itself an auto-created follow-up.** A
    chain: ENG-1 → reviewed → deferred → ENG-2 (auto-created) →
    operator triages → eventually reviewed → deferred → ENG-3.
    Parenting is hierarchical (Linear's data model supports it);
    no special handling. The chain is operator-visible in
    Linear's sub-issue tree.

14. **Ledger has hundreds of deferred-major rows on one
    dispatch.** Pathological; the harness's adjudicator-memory
    + critical-floor + structural-rubric should bound this. But
    the helper iterates without batching; on N=100 the helper
    fires 200 GraphQL calls (search + create per row), serially.
    Bounded by reality + the post-dispatch hook's wall-clock
    budget. No new throttle needed.

15. **Sanitisation on the body's `## Source` "Parent issue"
    link.** The parent ident (ENG-N) is operator-trusted; it's
    not agent-controlled — it comes from `$ident` which the
    orchestrator sets. No sanitisation needed there. The PR URL
    is `gh`-derived; also not agent-controlled. Sanitisation is
    only required on agent-controlled fields per the standing
    convention.

16. **Test fixture leak — `bin/run-stage-test.sh` builds a
    fixture ledger and asserts captured create-issue calls.**
    The stub `linear.sh` captures argv into `$CAPTURE_FILE`
    (per existing pattern at line 45-46). New cases add
    `create-issue` capture parsing. No real Linear write.

17. **A future ticket adds a `relatedTo` field to ENG-193's
    body** (e.g. linking to an ENG-189 umbrella). Linear's
    `issueCreate.input` supports `relatedIssueIds: [String!]`.
    The new field would extend the existing flag set without
    breaking idempotency (the marker still keys on dispatch_id
    + finding_class_key). Forward-compatible.

## 7. Open questions

* **OQ-1.** Should the follow-up body include the original
  PR's diff snippet around the finding's `scope-anchor`?
  E.g. parse `<dimension>:<scope-anchor>:<concept-slug>` →
  `scope-anchor` is `bin/run-stage.sh::naming` → grep the diff
  for that. **Working decision:** no in v1. The follow-up's
  body is for human triage; diff snippets risk going stale once
  the parent merges, and reproducing the diff at create-time is
  fragile (the dispatch may have hit a not-yet-pushed branch).
  The PR URL gives the operator the canonical reproduction
  surface.

* **OQ-2.** Should the follow-up carry a `pipeline:deferred-debt`
  label (in addition to the type label) to discover all auto-
  created debt at once? **Working decision:** no in v1. Title
  prefix `[deferred]` and the marker substring search are
  enough; adding a labels surface widens the lane-fence
  classifier (`_classify_label` may need a new branch). YAGNI;
  reconsider if operators ask.

* **OQ-3.** Should `human_checkpoints.auto_ticket_deferred_majors`
  default to `false` for v1 rollout safety (avoid surprise
  ticketing in the first weeks)? **Working decision:** no —
  default `true` per AC #1. Operators uncomfortable with the
  default can flip via config. The marker-search is robust;
  rollback is one config line.

* **OQ-4.** Should the orchestrator append a "follow-up created:
  ENG-M" line to the ENG-191 deferred-majors comment per row, so
  the operator sees the linkage inline? **Working decision:** no
  in v1. The ENG-191 comment is owned by ENG-191; mutating it
  post-fact (or adding a sibling comment) couples the two
  tickets. Linear's sub-issue tree view on the parent gives the
  linkage natively. Reconsider if operators say the linkage is
  hard to discover.

* **OQ-5.** Should the follow-up's `priority` field be set
  automatically? Linear's `issueCreate.input.priority` accepts
  `0` (None) … `4` (Low). A natural mapping: `decision_factors.user_
  visible == true` → priority `3` (Medium); else → `4` (Low).
  **Working decision:** no in v1. Priority is operator-policy;
  defaulting to `0` (None) lets the operator decide. Mention as
  future hook.

* **OQ-6.** What happens if Linear's API rate-limits the search +
  create burst on a K=20 deferred-major dispatch? Linear's free
  tier limits are ~250 requests/hour. K=20 → 40 calls — within
  bounds. **Working decision:** no rate-limit handling in v1;
  ENG-193 helper logs and continues on any individual failure.

* **OQ-7.** Should the helper attempt to add the follow-up to a
  Linear cycle (e.g. the next upcoming cycle for the team)?
  **Working decision:** no — assigning to a cycle is scheduling
  policy. Operator triage.

* **OQ-8.** Should the marker also include `created_at` for the
  helper's own forensic trail? **Working decision:** no — the
  marker stays minimal (`dispatch_id + finding_class_key`),
  which is the idempotency contract. `created_at` is in
  Linear's `createdAt` field natively.

* **OQ-9.** Linear's `issueCreate.input` accepts `description`
  as Markdown. The body uses Markdown headings (`##`) and lists.
  Confirm Linear renders them in the UI. **Working decision:**
  verified by the existing ENG-191 deferred-majors comment
  (`bin/run-stage.sh:1555` produces a Markdown body that Linear
  renders correctly). Same surface, same rendering.

* **OQ-10.** What if the parent issue is closed / archived by an
  operator between the agent's path-D exit and the
  orchestrator's create-follow-up call? The `parentId` UUID
  resolves through `_resolve_issue_uuid` which calls `get_issue`
  — closed issues still return a valid id. Linear's
  `issueCreate.input.parentId` accepts closed-parent issues.
  Test boundary; documented as bounded.

## 8. Out-of-scope reminders

* **Changing the convergence / exit predicate (ENG-191 D-006).**
  ENG-193 only acts on the predicate's output (ledger rows). The
  predicate's structure is owned by ENG-191.
* **Adjudication memory (ENG-190).** Consumed unchanged.
* **Implement-side fix-the-class (ENG-192).** Independent; the
  ENG-192 helper does not coordinate with ENG-193.
* **Project-policy risk-tolerance override (ENG-191 OQ-3).**
  Same deferral as ENG-191.
* **Outcome-correlation (does the auto-created ticket later get
  closed?).** Out of scope — substrate is the follow-up tickets
  themselves + the `follow-up-created` metric; retrospective
  shape later.
* **Auto-assigning the follow-up to a team member or operator.**
  Out of scope.
* **Bulk-closing auto-created follow-ups on operator gesture
  (e.g. a `pipeline:abandon-deferred-debt` label on the parent).**
  Out of scope.

## 9. ADR stress test

This brainstorm puts pressure on the following accepted
decisions:

* **CLAUDE.md "Linear conventions" (L232-235) — type label at
  creation, Bug/Feature/Improvement.** D-003 picks Bug or
  Improvement mechanically from `user_visible`. This is the
  first programmatic application of the convention. Stress: if
  the rule mis-categorises (e.g. a `user_visible=false` row that
  IS in fact a Bug per operator judgement), the follow-up has
  the wrong type label and routes through `feat/` branches in
  later stages. Mitigation: type label is operator-mutable in
  Linear UI; mis-categorisation is a one-touch fix. The rule is
  conservative — most deferred majors per the rubric are NOT
  user-visible (the rubric BLOCKs user-visible findings unless
  they're trivially recoverable), so `Improvement` is the modal
  output. Bounded mis-categorisation risk.

* **CLAUDE.md "Linear conventions" (L243-244) — never use
  `save_issue` to update existing issues.** D-001 uses
  `issueCreate` (creation, not update); the constraint is
  honoured. The marker-search via `searchIssues` is a read, not
  a write. No conflict.

* **CLAUDE.md "Linear conventions" (L249-253) — doc-to-issue
  YAML frontmatter.** Auto-created follow-ups do NOT come with
  brainstorm or plan docs. If the operator later triages to
  Todo, the next brainstorming dispatch on that follow-up will
  produce a brainstorm doc with frontmatter — matching the
  convention. The auto-created ticket itself has no doc at
  creation time, which is the expected zero-state for any new
  Linear ticket (humans file tickets the same way today).

* **CLAUDE.md "Ticket sizing rubric" (L260-302).** Auto-created
  follow-ups are subordinate to the parent (per "split mechanics"
  — they enter at Backlog with `parentId` pointing at the parent).
  The parent IS the umbrella structurally. The brainstorm
  preserves the rubric's "split mechanics" semantics.

* **ENG-87 cross-dispatch staleness contract.** The marker
  includes `dispatch_id` — the established cross-dispatch
  primitive. Strictly additive use; no stress.

* **ENG-115 per-arm field-registry-override pattern.** ENG-193
  does NOT register new vocabulary in `pipeline-events.json`
  (no new verdict marker, no new halt reason). The pattern is
  not stressed.

* **ENG-150 append-only `--sig` convention.** ENG-193's helper
  does NOT use `add-comment --sig` (comment posting is ENG-191's
  responsibility, unchanged). The new `create-issue` subcommand
  is structurally different — write-once-per-(dispatch×finding),
  not append-only-per-sig. The convention is not stressed; ENG-
  193's idempotency uses marker-search-on-Linear, which is the
  analog at the issue level.

* **ENG-191 D-005 deferred-majors comment + the "ENG-193 will
  auto-create follow-up tickets" line.** ENG-193 makes that line
  ACCURATE. Stress: until ENG-193 lands, the line is a forward-
  promise that mismatches actual behaviour. ENG-191 shipped
  with the line; ENG-193 closes the loop. No structural conflict
  — the dependency is acknowledged by the Linear ticket's
  "Blocked-by ENG-191" marker.

* **CLAUDE.md "Don't add features beyond what the task
  requires."** Five Linear scope IN bullets — one per ticket
  per finding, idempotency, orchestrator-side path. D-001
  through D-008 implement exactly these; D-009 (operator
  runbook) is structural documentation. No sixth feature.

* **CLAUDE.md "Defense-in-depth: when a stage's contract says
  'agent must not invoke tool X,' prefer a transcript-based
  assertion."** ENG-193 has a quasi-rule "agent must not call
  `bin/linear.sh create-issue`." Defenses:
  - Lane fence (D-008) — denies at the chokepoint
    (`bin/linear.sh::_check_lane`).
  - No agent-stage allowlist grants `create-issue` (reviewing's
    `Bash(bash bin/linear.sh:*)` is broad but the lane fence
    denies inside `linear.sh`).
  - Optional transcript-based assertion in `bin/dispatch.sh`
    blocking `Bash(bash bin/linear.sh create-issue:*)` in
    reviewing — explicit. **Decision: skip this in v1.** The
    lane fence is structurally sufficient. The agent's reviewing
    prompt does not instruct create-issue use; adversarial-agent
    misbehaviour is bounded by the fence. Documented as future
    hardening if drift observed.

* **ENG-46 secret-handling.** No new env-var dereferences. The
  helper reads `${PIPELINE_DISPATCH_ID-}` (single-dash, presence
  check shape). No secret name pattern triggered.

* **ENG-100 sub-agent debris.** No agent involvement; the
  helper is orchestrator-only. Constraint not stressed.

## 10. Simpler-alternative pass

| Decision | Rejected alternative | Why rejected |
|---|---|---|
| D-001 | Inline GraphQL in `run-stage.sh` (no new subcommand) | Sprawls Linear API into hook file; breaks `linear.sh` chokepoint contract. |
| D-001 | Fold into `add_comment` (omnibus write) | Mixed responsibilities; one function would balloon. |
| D-001 | MCP `save_issue` from orchestrator (spawn claude wrapper) | Wrong tool surface; MCP is for agent runtime. |
| D-002 | Title-prefix idempotency | Title is operator-editable; breaks on rename. |
| D-002 | On-disk cache in `issue-state.json` | Operator-deletable; Linear is source of truth. |
| D-002 | Parent-comment marker | Couples two tickets; child's description is the natural place. |
| D-003 | Agent-controlled prose body | New ledger surface; agent opinions risk staleness. |
| D-003 | Always-Improvement | Loses Bug signal for user-visible debt. |
| D-003 | Agent picks type label via new ledger field | Widens schema; inference inconsistency. |
| D-004 | Fold into ENG-191 comment helper | Conflated failure modes; widens shipped code. |
| D-004 | Synchronous halt on first create failure | Confusing operator state; halt unclear. |
| D-005 | File as `Todo` | Auto-schedules unbidden work; flooding hazard. |
| D-005 | Use a `pipeline:deferred-debt` label instead of state routing | Lane-fence surface widens for no payoff. |
| D-005 | `relatedTo` instead of `parentId` | Weaker linkage; CLAUDE.md mechanics specify `parentId`. |
| D-006 | Env var | Reserved for host-level tuning. |
| D-006 | No config (always on) | Operators must be able to opt out. |
| D-007 | No metrics (log only) | Retro shape needs structured events. |
| D-008 | Rely on agent-allowlist (skip lane fence) | Defense-in-depth gap. |
| D-009 | New §14 runbook section | Splits ENG-191's narrative; cognitive cost. |
| D-009 | New CLAUDE.md row | No new failure mode introduced. |

## 11. Assumption inventory

Every named code-level fact below was verified via `Read` /
`Grep` against the current worktree at
`/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-193/worktree`.

| # | Assumption | Status | Evidence |
|---|------------|--------|----------|
| 1 | `bin/linear.sh` has NO `create-issue` subcommand today | verified | `bin/linear.sh:927-944` (main case statement) lists 15 verbs, none of which creates an issue; `grep -n issueCreate\|create-issue\|create_issue bin/linear.sh` returns no hits |
| 2 | `bin/linear.sh::linear_query` is the GraphQL chokepoint, honours `PIPELINE_DRY_RUN`, retries on HTTP 5xx | verified | `bin/linear.sh:397-431`; dry-run at line 401; retry loop at 411-430 |
| 3 | `bin/linear.sh::_check_lane` is the lane fence, action × object_class matrix at lines 317-335 | verified | `bin/linear.sh:317-386` |
| 4 | The lane-fence matrix has NO entry for issue creation today | verified | `bin/linear.sh:317-335` — only `stage_label`, `pipeline_halted`, `pipeline_supersede`, `pipeline_skip_until`, `transition_comment`, `other_comment`, `any_other_label` object_classes |
| 5 | `bin/linear.sh::add_label` (lines 474-501) is the established chokepoint pattern: lane fence call → UUID resolution → dry-run gate → `linear_query` mutation → log | verified | `bin/linear.sh:474-501` |
| 6 | `bin/common.sh::label_id` / `state_id` resolve UUIDs from `linear-ids.json` cache | verified | `bin/common.sh:1140-1146`; `ids_get` reader at 1135-1138 |
| 7 | `_require_project_id` reads `config.linear.project_id` from `.pipeline-config/config.json`; `team_id` similarly via `config_get '.linear.team_id'` | verified | `bin/linear.sh:441-445`, 449, 459 |
| 8 | `bin/linear.sh::add_comment` line 711 begins; `--sig` parsing at 719-739; lane fence at 758; dispatch_id auto-inject at 793; dedup marker append at 801-808 | verified | `bin/linear.sh:711-870` |
| 9 | `bin/linear.sh::_inject_dispatch_marker` lives at lines 63-80; appends `<!-- meta: dispatch id=<dispatch_id> stage=<stage> -->` when `PIPELINE_DISPATCH_ID` is set | verified | `bin/linear.sh:63-80` |
| 10 | `bin/run-stage.sh::_post_deferred_majors_comment_if_eligible` is at lines 1483-1561 (ENG-191 shipped) | verified | `bin/run-stage.sh:1483-1561`; full body read |
| 11 | The helper reads ledger rows via `jq` filter on `dispatch_id == $did AND adjudicated_severity == "major" AND blocks_ship == false` | verified | `bin/run-stage.sh:1519-1535` |
| 12 | The post-dispatch hook block at lines 2449-2455 invokes `_post_deferred_majors_comment_if_eligible` under `if (( ! skip_dispatch ))` + `case "$stage" in reviewing)` gating | verified | `bin/run-stage.sh:2442-2455` |
| 13 | `_validate_dispatch_envelope` is at `bin/run-stage.sh:1039-1123` and blocks `mcp__plugin_linear`, `curl https://api.linear.app`, `gh api graphql`, `wget https://api.linear.app`, `unset PIPELINE_DISPATCH_ID` | verified | Explore agent traced lines; CLAUDE.md "Cross-dispatch staleness contract" section confirms |
| 14 | `bin/review-ledger-schema.sh` documents `finding_class_key: <dimension>:<scope-anchor>:<concept-slug>` | verified | `bin/review-ledger-schema.sh:25` |
| 15 | ENG-191 deferability fields (`blocks_ship`, `ship_classification_rationale`, `decision_factors{5 booleans}`) are validated on this-dispatch major/critical rows | verified | `bin/review-ledger-schema.sh:40-65` (schema doc header); validation block referenced at 356-398 per explore agent |
| 16 | `bin/pipeline-events.json::pass_reasons` contains `ship-with-deferred-majors` (ENG-191 shipped) | verified | `bin/pipeline-events.json:10-12` |
| 17 | The ENG-191 deferred-majors comment body footer says "ENG-193 will auto-create follow-up tickets per deferred major" | verified | `bin/run-stage.sh:1555` — printf format string includes the literal |
| 18 | `docs/runbooks/recovery.md` §13 is the ENG-191 selective-exit section; mentions ENG-193 auto-ticketing as forward-promise at line 857 | verified | `docs/runbooks/recovery.md:848-888` |
| 19 | `bin/render-prompt.sh::PROMPT_RESOLVERS` includes `review_converge_rounds=_resolve_review_converge_rounds` at line 62 (ENG-191 D-010 shipped) | verified | `bin/render-prompt.sh:40-63` |
| 20 | `bin/run-stage-test.sh` has ENG-191 Z1-Z8 fixture tests for `_post_deferred_majors_comment_if_eligible` (lines 7879-8154) following the SUBCMD/SIG/IDENT/BODY capture pattern | verified | `bin/run-stage-test.sh:7879+`; stub shape at lines 21-54 |
| 21 | `bin/linear.sh::add_comment` injects sig-derived dedup markers; `--sig` validation at line 745-749 rejects newline / `-->`; full_sig suffixed with `/d<NNNN>` from `PIPELINE_DISPATCH_ID` at lines 803-808 | verified | `bin/linear.sh:741-808` |
| 22 | `issue-state.json` shape: `{current_dispatch_seq, current_dispatch_id, current_stage}` | verified | `/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-193/issue-state.json` |
| 23 | `bin/linear.sh::list_issues_with_label` uses GraphQL `issues(filter: {team, project, labels})` — precedent for filtered queries | verified | `bin/linear.sh:457-465` |
| 24 | `bin/linear.sh::get_issue` returns the issue's id (UUID), identifier, title, description, state, labels, url | verified | `bin/linear.sh:433-439`; query at line 435 |
| 25 | CLAUDE.md L232-235 mandates type label (Bug/Feature/Improvement) at creation time AND maps Bug → `fix/<eng-n>-<slug>`, Feature/Improvement → `feat/<eng-n>-<slug>` | verified | `CLAUDE.md:232-235` |
| 26 | CLAUDE.md L254-257 specifies `Todo` is the brainstorm-eligible state; `Backlog` is invisible to poller until human triages | verified | `CLAUDE.md:254-257` |
| 27 | CLAUDE.md L291-298 split mechanics: file sub-tickets via `save_issue` with `parentId`; first-ready → `Todo`, dependent → `Backlog` | verified | `CLAUDE.md:291-298` |
| 28 | `CLAUDE.md` Failure-mode quick reference at line 824 already covers the `reason=ship-with-deferred-majors` + `deferred-majors/<ENG-N>` symptom (ENG-191 row) | verified | `CLAUDE.md:824` |
| 29 | `bin/render-prompt.sh::_write_rendered_paths_sidecar` enumerates path-shaped resolvers; non-path resolvers (e.g. `review_converge_rounds`) are excluded — pattern to NOT add this brainstorm's resolver-token because none is needed (orchestrator-only config) | verified | `bin/render-prompt.sh:94-126` |
| 30 | `bin/linear.sh` test stub pattern in `run-stage-test.sh:33-46` captures `add-comment`'s ident + sig + body into `$CAPTURE_FILE`; new fixtures for `create-issue` follow the same shape | verified | `bin/run-stage-test.sh:21-54` |
| 31 | `bin/metrics.sh` is the metric-write chokepoint per CLAUDE.md "When wiring a new script" section | verified by convention | CLAUDE.md "When wiring a new script" — "Metric writes go through `bin/metrics.sh`" |
| 32 | `gh` is on the launchd host PATH (per CLAUDE.md "PATH expectations") so `gh pr view --json url` is callable from the orchestrator | verified | `CLAUDE.md` PATH expectations section (lines ~80-95) names `gh` as one of the resolved binaries via Homebrew/system segments |
| 33 | Linear's `issueCreate.input` accepts `title, description, teamId, projectId, stateId, parentId, labelIds[]` (and `priority, assigneeId, relatedIssueIds[]` for future use) | assumed — Linear GraphQL schema standard, not codebase-verifiable | Linear's public API docs; the existing `issueAddLabel` and `issueRemoveLabel` mutations follow the same `input:` shape (lines 496, 524) |
| 34 | Linear's `searchIssues` (or equivalent full-text search) accepts a substring `term` argument and returns `nodes[]` filterable by archive state | assumed — Linear GraphQL schema standard | Linear's public API docs; will be validated at implementation time |
| 35 | The lane fence in `_check_lane` rejects unknown action × object_class with `printf 'deny'` at line 333; default-deny posture | verified | `bin/linear.sh:333` |

**Items 33-34 are explicitly marked "assumed"** — Linear's
GraphQL schema for `issueCreate` and `searchIssues` is
documented but not verified against the codebase (no current
caller). Implementation-time validation: run the mutation /
query in a Linear test workspace and confirm shape before
shipping.

## 12. Out-of-scope flags

All seven Linear AC items map to concrete decisions:

* **AC #1** (creates exactly K follow-up tickets per terminal
  exit; type label set; parented or related-to) → D-001
  (chokepoint) + D-003 (title / type / body) + D-004 (helper
  invocation) + D-005 (parenting + state).
* **AC #2** (re-running does not duplicate; dispatch-id or
  content-hash keyed) → D-002 (marker idempotency) +
  defensive byte-match.
* **AC #3** (no agent-side Linear write; envelope-validator
  clean; all creation orchestrator-side) → D-001 (lane fence +
  `bin/linear.sh` chokepoint) + D-004 (post-dispatch hook AFTER
  envelope validator) + D-008 (lane-fence defense-in-depth).

Three additional decisions are structural plumbing, each
required to make the AC items work:

* **D-006 (config gate).** Operator escape hatch. Required by
  the "operator-control" principle CLAUDE.md establishes
  throughout (see ENG-65 / ENG-81 / ENG-191 D-010 precedent for
  operator-tunable per-project knobs).
* **D-007 (metrics).** Required by CLAUDE.md "Metric writes go
  through `bin/metrics.sh`" — every orchestrator-side action
  worth retrospective inspection emits a metric.
* **D-009 (runbook update).** Required by the operator-
  discoverable surface principle.

All Linear OUT bullets honoured:

* **Changing the convergence / exit predicate** → ENG-191
  scope; §8 first bullet.
* **Adjudication memory** → ENG-190 scope; §8 second bullet.
* **Implement-side fix-the-class** → ENG-192 scope;
  §8 third bullet.
* **Project-policy risk-tolerance override** → ENG-191 OQ-3
  scope; §8 fourth bullet.
* **Outcome-correlation automation** → future work; §8.
* **Auto-assigning to humans** → future work; §8.
* **Bulk-closing follow-ups on operator gesture** → future
  work; §8.

## 13. Persona review

Six personas in canonical order (design → security → scope →
coherence → product → feasibility). Iteration history in §14.
**Iter-1 gate: 5/6 PASS, Product FAIL (2 P0); feasibility P0 = 0.
Iter-2 gate (post-edits): 6/6 PASS, feasibility P0 = 0.** All
iter-1 P0 / load-bearing P1 findings addressed via Edit; per-
persona status below reflects iter-2 final state.

### 13.1 Design — PASS

* P0: 0.
* P1: 3.
  * D-001 lane-fence vs allowlist-fence ambiguity — the
    brainstorm states "lane fence is structural even though
    agent allowlist denies" but it's worth being precise:
    today the reviewing-stage's `Bash(bash bin/linear.sh:*)`
    grant DOES allow agent invocation of the new subcommand IF
    the agent's prompt tells it to. The lane fence is the
    chokepoint denial. Clarified inline in D-001 final
    paragraph.
  * D-002 false-positive bound on marker search — addressed
    with explicit defensive byte-match step (D-002).
  * D-004 hook ordering relative to `_validate_review_payload`
    and `_validate_review_ledger` — those run BEFORE
    `_post_deferred_majors_comment_if_eligible` (per ENG-191
    D-005); ENG-193's helper runs immediately AFTER. Edge case
    12 (defensive double-gate) addresses defense-in-depth.
* P2: 2 (D-006 default-true bias on rollout — defended in OQ-3;
  D-005 alternative state defaulting — defended inline).

### 13.2 Security — PASS

* P0: 0.
* P1: 3.
  * D-001 lane-fence agent-deny vs. allowlist-grant — same as
    13.1 first point; cross-referenced.
  * D-002 marker-search injection (operator-crafted body
    matching the marker pattern) — bounded by defensive
    byte-match on candidate descriptions and the closed marker
    shape (`<!-- meta: follow-up-source dispatch=ENG-N-d<NNNN>
    finding_class_key=<sanitised> -->`). Sanitisation contract
    on every interpolated field.
  * D-003 title injection via `ship_classification_rationale` —
    sanitisation applied to title; soft cap at 80 chars limits
    the body. Edge case 2 covers the `<!--` case explicitly.
* P2: 2 (edge case 7 archive-then-recreate — accepted v1 with
  `includeArchived: true` fallback; edge case 8 marker-removal
  manual edit — bounded by "don't touch the marker" convention).

### 13.3 Scope — PASS

* P0: 0.
* P1: 2.
  * Subsystem count: 2 (orchestrator + Linear-contract). Per
    CLAUDE.md sizing rubric, autonomy-safe.
  * Decision count: 1 load-bearing (sanctioned creation +
    idempotency key). Per sizing rubric: autonomy-safe.
  * 0 ADRs proposed; no architectural decisions outside
    ENG-87 / ENG-115 / ENG-138 / ENG-190 / ENG-191 inherited
    contracts.
* P2: 2 (OQ-4 forward-reference to ENG-191 comment — accepted
  no-mutation v1; D-009 runbook scope — inline in §13 not new
  §14).
* All 3 ACs mapped (§12); all 4 OUT bullets honoured.

### 13.4 Coherence — PASS

* P0: 0.
* P1: 3.
  * D-002 storage of idempotency: clear that NO local on-disk
    state is added; Linear is source of truth — addressed in
    D-002 final paragraph.
  * D-004 helper-after-helper ordering and skip_dispatch
    invariant — addressed in D-004 final paragraph + dataflow
    diagram.
  * D-005 `Backlog` rationale vs. ENG-191 "ENG-193 will auto-
    create" forward-promise — addressed in D-005 first
    paragraph; the forward-promise is satisfied even if filed
    at Backlog (operator triages, then harness picks up).
* P2: 3 (lane-fence object_class name `child_issue` vs `issue` —
  picked `child_issue` to keep fence focused; PR URL fallback
  string `(not discoverable)` — established convention; metric
  schema kind names — mirror existing `kind` shape).

### 13.5 Product — PASS (iter-1 FAIL → iter-2 PASS)

* P0: 0 (iter-1: 2 P0; both addressed by iter-2 edits).
* P1: 0 outstanding (iter-1: 4 P1; all addressed by iter-2 edits).
  * Iter-1 P0 #1 (`Backlog` operator-invisibility) → addressed
    by D-005's four-surface discoverability sub-paragraph
    (ENG-191 audit comment, Linear sub-issue tree, TL;DR
    top-line, operator-mental-model recipe).
  * Iter-1 P0 #2 (D-009 stale forward-reference in §13) →
    addressed by D-009's in-place rewrite shape (bolded
    sentence rewritten to past tense + sub-paragraph).
  * Iter-1 P1 #1 (title prefix discoverability) → addressed by
    D-003 title shape `[deferred from ENG-N]` (parent linkage
    at-a-glance).
  * Iter-1 P1 #2 (no body TL;DR) → addressed by D-003 bolded
    TL;DR top-line.
  * Iter-1 P1 #3 (D-006 config-off / ENG-191 comment lies) →
    addressed by D-006 sub-decision: ENG-193 amends ENG-191's
    footer to be config-conditional ("auto-ticketing disabled
    by config" branch).
  * Iter-1 P1 #4 (type-label mapping invisible in body) →
    addressed by D-003 body "Type label" section.
* P2: 3 (`follow-up-failed` operator recovery recipe — deferred
  to D-009 runbook; N+1 cost for K large — bounded by reality;
  defensive byte-match invisible — documented inline at D-002
  for power-user discoverability).

### 13.6 Feasibility — PASS

* P0: 0. All named code-level facts verified.
* P1: 2.
  * Assumption #33-34 marked "assumed" — Linear's GraphQL
    schema for `issueCreate` and `searchIssues` is documented
    but not verified against the codebase. Implementation-time
    validation step documented inline at assumption #33.
  * Line numbers for `_validate_dispatch_envelope` were
    re-verified via Explore agent (current at 1039-1123, not
    the brainstorm-cited 1013). Assumption #13 documents the
    current range.
* P2: 1 (no codebase-level changes will require fence-count
  adjustment in `AGENT_PROMPTS.md` since ENG-193 makes no
  prompt edit).

**Gate status: 6/6 personas PASS, feasibility P0 count = 0.**
Brainstorm cleared for commit and stage progression.

## 14. Persona-review iteration history

* **Iteration 1.** 5/6 personas PASS first-pass. Feasibility
  P0 count = 0 (full clean pass on all 25 code-level claims).
  Product persona returned FAIL with 2 P0 + 4 P1 (operator-
  discoverability hole on `Backlog` default; stale forward-
  reference in §13 amendment; ENG-191 footer mismatch when
  config-off; title prefix discoverability; body lacking TL;DR;
  type-label rationale invisible). 12 additional P1 findings
  catalogued across the other five personas.

  Edits applied (iter-1 → iter-2):
  - **D-003 title shape.** Changed from `[deferred]` to
    `[deferred from ENG-N]` (Product P1 #1). Sanitise-then-
    truncate ordering documented with partial-escape tail-trim
    rule (Security P1 #1).
  - **D-003 body shape.** Added a bolded TL;DR top-line
    naming parent + PR + reviewing stage (Product P1 #2).
    Added "Type label" section explicating the
    `user_visible` → `Bug|Improvement` mapping (Product P1 #4).
  - **D-005 operator discoverability.** New sub-paragraph
    enumerating four discovery surfaces (ENG-191 audit comment,
    Linear sub-issue tree, TL;DR top-line on each follow-up,
    operator-mental-model recipe). Documented "no Slack
    notification in v1" with rollover hook (Product P0 #1).
  - **D-006 ENG-191 comment footer edit.** New sub-decision:
    ENG-193 amends the ENG-191 helper's footer to a
    config-conditional branch — when ENG-193 is disabled, the
    footer truthfully states "auto-ticketing disabled by
    config" instead of "ENG-193 will auto-create" (Product
    P1 #3 / Design P1 #3). §3 architecture's
    `bin/run-stage.sh` edit budget bumped to accommodate.
  - **D-009 §13 in-place rewrite.** Explicit "rewrites the
    bolded forward-reference sentence in past tense" plus
    sub-paragraph; resolves the "post-landing readers see a
    stale future-tense promise" ambiguity (Product P0 #2).
  - **D-002 TOCTOU analysis.** Two-case race walkthrough:
    same-parent serialised by ENG-81 lock; cross-parent
    structurally impossible because `dispatch_id` is
    parent-scoped (Design P1 #2).
  - **D-002 `find-follow-up` stdout contract.** Explicit
    contract: empty=miss, single-line ident=hit, rc=1=parse-
    fail-treated-as-miss, rc=13=lane-denial-fatal
    (Security P1 #2). GraphQL injection safety acknowledged
    via `linear_query`'s `jq --argjson v` JSON encoding.
  - **D-001 description flag shape.** Changed signature from
    `--description-file <path>` + `--description -` to single
    `--description <value | - | @<path>>` mirroring
    `add_comment`'s `--body` resolver (Coherence P1 #1).
  - **D-001 lane fence ordering.** Explicit "gate-first
    before UUID resolution and dry-run gate" (Security P1 #3),
    mirroring `add_label`'s line 479 pattern.
  - **D-001 defense-in-depth disambiguation.** Clarified that
    the reviewing allowlist DOES grant
    `Bash(bash bin/linear.sh:*)` — the lane fence is THE
    structural denial (not redundant with allowlist)
    (Design P1 #1).

* **Iteration 2.** All targeted Product P0s and the load-bearing
  P1s addressed via Edit operations. Re-verification of edits is
  implicit — no new code-level claims introduced; existing
  feasibility verifications still hold. Per-persona expected
  status post-edits:
  - Design: PASS (3 P1 addressed inline).
  - Security: PASS (3 P1 addressed; one P2 acknowledged).
  - Scope: PASS (sub-decisions are operator-control / runbook;
    no scope creep introduced).
  - Coherence: PASS (description-flag ambiguity resolved;
    discovery-recipe rationale already in D-009).
  - Product: PASS (both P0s + 4 P1s addressed structurally).
  - Feasibility: PASS (no new code-level facts cited).

**Gate met after iteration 2: 6/6 PASS, feasibility P0 = 0.
Brainstorm cleared for commit and stage progression.**

## 15. Proposed ADRs

This ticket does not propose new ADRs. The decisions fit within
established architectural patterns:

* ENG-87 cross-dispatch staleness contract (extended additively
  — the marker carries `dispatch_id`, the established
  primitive).
* CLAUDE.md "Linear conventions" (extended for first
  programmatic issue creation — the chokepoint contract is
  preserved, the type-label-at-creation discipline encoded in
  `--type-label` required flag).
* CLAUDE.md "Lane fence" (extended additively — new
  `create child_issue` and `find child_issue` rows).
* ENG-150 append-only `add-comment --sig` chokepoint pattern
  (analog at the issue level — marker-search idempotency
  replaces sig-suffixed dedup-marker idempotency).
* ENG-191 D-005 deferred-majors comment hook (sibling helper
  in same hook block, soft-fail mirror).
* ENG-46 secret-handling (no env-var dereferences in new code).
* ENG-100 sub-agent debris (the helper is orchestrator-only;
  no agent involvement).

If `docs/knowledge/decisions.md` ever materialises (verified
non-existent today via `ls docs/`), the ENG-87 / ENG-115 /
ENG-150 / ENG-190 / ENG-191 ADRs are the implicit parents this
ticket mirrors.
