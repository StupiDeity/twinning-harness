---
linear: ENG-79
title: render-prompt.sh:212 hardcodes `branch_name="feature/${issue_id_lower}-…"` — drifts from branch-name.sh canonical `feat/` shape
date: 2026-05-08
status: draft
---

# `render-prompt.sh` must source `branch-name.sh`, not hand-roll `feature/<lower>-<slug>`

## 1. Overview (and the load-bearing surprise)

`bin/render-prompt.sh` interpolates a `{branch_name}` token into every
non-`released` stage prompt extracted from `AGENT_PROMPTS.md`. Before this
ticket, the value of that token came from a hand-rolled formation:

```bash
# bin/render-prompt.sh (pre-ENG-79, line ~212)
branch_name="feature/${issue_id_lower}-${slug}"
```

Three sources of truth disagree with that prefix:

1. **`bin/branch-name.sh:31`** — the canonical resolver — emits
   `feat/<issue-lower>-<slug>` for Feature/Improvement issues and
   `fix/<issue-lower>-<slug>` for `Bug`-labeled issues, per the prefix
   rule documented at `bin/branch-name.sh:6-8` and pinned in
   ENG-13 D-004.
2. **`AGENT_PROMPTS.md:80`** — the prompt-side promise — *"The
   orchestrator computes the canonical branch name once via
   `bin/branch-name.sh` and substitutes it into your prompt as
   `{branch_name}`."* That sentence is a contract; the hand-rolled
   `feature/…` formation silently broke it.
3. **`AGENT_PROMPTS.md:85-88`** — Hard-rules 1–4 — *"Use
   `{branch_name}` verbatim. Never substitute a similar-looking name…
   Variants like `feature/…`, `bugfix/…`, `hotfix/…`, `chore/…`, or
   anything Linear's auto-generated `gitBranchName` suggests are
   **not** canonical and **must not be used**."*

The `branch_name` variable is interpolated as `{branch_name}` at 23
distinct call sites in `AGENT_PROMPTS.md` (verified:
`grep -c '\{branch_name\}' AGENT_PROMPTS.md` returned 23 — the
explicit rule block at 80–88 plus active interpolations across the
implementing/ui/reviewing/qa/building/release stages, e.g.
`AGENT_PROMPTS.md:582`, `:590`, `:625`, `:645`, `:663`, `:728`,
`:809`, `:876`, `:1089`, `:1140`, `:1210`, `:1245`, `:1251`, `:1264`).
So every rendered agent prompt — for *every* stage that interpolates
the token — embedded the wrong branch shape.

**The load-bearing surprise.** Until ENG-67 (May 2026), the
orchestrator's `bin/run-local.sh:213-226` carried a "legacy `feature/*`
coexistence" path that *silently accommodated* agents who created
`feature/eng-N-…` branches by checking out into a worktree off that
ref. The interpolated `feature/...` in the prompt was therefore
*technically wrong* but *operationally harmless* — the orchestrator
landed the agent on `feature/...` if one happened to exist, and
otherwise the canonical resolution path created a fresh `feat/...`
worktree underneath the agent without it noticing.

ENG-67 (PR #62, merged) deleted that fallback (verified at
`bin/run-local.sh:214-234` — the deletion-site comment cites PR #48
+ ENG-63/64/65; the proceed branch unconditionally calls
`bash "$SCRIPT_DIR/branch-name.sh" "$issue_id"` at line 230) and
added a `die`-on-empty-`worktree_path` guard at line 242. After
ENG-67:

- Every `proceed` tick resolves `feat/...` (or `fix/...`) via the
  canonical resolver.
- The agent is dispatched into a worktree whose checked-out branch is
  `feat/eng-N-…`.
- The prompt's interpolated `{branch_name}` value (`feature/…`)
  **cannot match** the actual branch.

**ENG-74 (May 2026) confirmed the failure mode in production.** A
build-stage agent ran `gh pr list --head feature/eng-74-…` (value
copied verbatim from the prompt's `{branch_name}`), got an empty
result because the actual branch is `feat/eng-74-…`, and emitted
`verdict halt result=halt reason=agent-blocked` for a P1 precondition
that was in fact satisfied (the PR was open on the canonical branch).
The commit message of `7772687` records this as the proximate
trigger for filing ENG-79.

Pre-ENG-67, agents had been silently working around this by
interpreting intent and using the canonical name (e.g. PR #62
shipped on `feat/eng-67-…`, ENG-71's PR on `feat/eng-71-…`). That
work-around relied on agent judgment that could regress at any time
and *did* regress in ENG-74. The contract violation is real and
load-bearing on agent judgment. This brainstorm closes it at the
source.

## 2. Goals

After this ticket lands:

1. **Single source of truth** (D-001). `bin/render-prompt.sh`
   resolves `branch_name` by invoking `bin/branch-name.sh` rather
   than recomputing the form. The prompt's promise at
   `AGENT_PROMPTS.md:80` is mechanically true again.
2. **Loud failure if the resolver dies** (D-002). When
   `branch-name.sh` fails (Linear-API outage, missing title,
   bug-label resolution failure), `render-prompt.sh` `die`s
   instead of falling back to a degraded value. Symmetric with
   ENG-67's `die`-on-empty-`worktree_path` invariant in the
   orchestrator.
3. **Test-pinned regression guard** (D-003). `bin/render-prompt-test.sh`
   gains two asserts: a positive grep that the script invokes
   `branch-name.sh` and a negative grep that no
   `feature/${issue_id_lower}` literal is present. Mirrors
   ENG-67 D-002's content-test pattern in
   `bin/run-local-content-test.sh`.

Non-goals (explicit, follow the issue's framing):

- **Other `feature/`-shaped occurrences in `bin/`.** Confirmed
  none post-PR-#48 outside of negative-rule tests
  (`grep -n "feature/" bin/render-prompt.sh` post-fix returns
  only the comment block at lines 215–223, and the
  `bin/agent-prompts-content-test.sh:523-527` /
  `bin/run-local-content-test.sh:28-32` /
  `bin/render-prompt-test.sh:148-153` negative pins). Out of
  scope: a wholesale audit.
- **Linear-API outage handling in `branch-name.sh`.** It already
  `die`s with `could not fetch title for ENG-N` at
  `bin/branch-name.sh:22`. ENG-79 only needs to *propagate* that
  death; it does not need to harden the resolver itself.
- **Caching** the resolved branch name across multiple
  `render-prompt.sh` calls within a single tick. Each tick
  invokes `render-prompt.sh` exactly once per stage; the per-tick
  cost is one extra Linear API call (already paid by `branch-name.sh`
  inside `run-local.sh:230` on the same tick — but
  `render-prompt.sh` runs in `dispatch.sh`, after `run-local.sh`
  has already resolved the branch, so this *is* a duplicate fetch).
  Flagged in §10 O-2 as a deferred optimization.

## 3. Architectural principle

There is no `docs/VISION.md`, no `docs/ARCHITECTURE.md`, no
`docs/knowledge/decisions.md` (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`; no `knowledge/` subdir). Governing constraints
come from `CLAUDE.md`, `learned-rules/harness/project-profile.md`,
and accepted brainstorms — same regime ENG-67 documented.

The principles invoked here are existing CLAUDE.md commitments,
not new ones:

- **Single source of truth for branch shape.** The canonical resolver
  is `bin/branch-name.sh` (per ENG-13 D-004 and ENG-67's deletion-site
  comment at `bin/run-local.sh:214-226`). Anything else that needs to
  know the branch shape must source it; recomputing is drift waiting
  to happen. CLAUDE.md "When wiring a new script" §:
  *"Use `log` / `die` / `require_env` / `require_bin` from common.sh
  — don't roll your own."* This brainstorm extends the same
  discipline to `branch-name.sh`: don't roll your own branch-name
  formation either.
- **`die` over silent fallback.** Same CLAUDE.md §, applied to D-002.
  ENG-67 added the matching invariant in the orchestrator: *"refusing
  to dispatch from `$TARGET_REPO`"* at `bin/run-local.sh:242`. ENG-79
  D-002 adds the matching invariant in the prompt-rendering layer:
  refusing to render a prompt with an unresolved `{branch_name}`. A
  silent empty interpolation would produce prompts containing
  `gh pr list --head ` (literal trailing space) — actively worse than
  the pre-fix `feature/…` because it would land in agent invocations
  that error in opaque shell ways.
- **Sentinel + content-test pattern for harness invariants.** CLAUDE.md
  "AGENT_PROMPTS.md is load-bearing" + "Tests" § establishes the
  pattern of grep-based content tests pinning load-bearing
  invariants. ENG-67 D-002 created
  `bin/run-local-content-test.sh` (verified at the file path)
  using exactly this pattern. ENG-79 D-003 follows it again,
  applied to a different load-bearing file
  (`bin/render-prompt.sh`).
- **Symmetric defense across the dispatch surface.** ENG-62's Bld-001
  rule and ENG-67's brainstorm §3 establish that when an invariant is
  enforced at one layer, the adjacent layer should also have a test
  pinning that no equivalent path exists in *that* layer. Today the
  invariant "agent prompts use canonical `feat/`/`fix/` names" is
  pinned at three layers:
  - **Prompt layer**: `AGENT_PROMPTS.md:85-88` (Hard rules) +
    `bin/agent-prompts-content-test.sh:523-527` (rejection of
    `feature/`).
  - **Orchestrator layer**: `bin/run-local.sh:230` (canonical
    resolution) + `bin/run-local-content-test.sh:28-32` (no
    `feature/` token in non-comment lines).
  - **Renderer layer (this ticket)**: D-001 (`render-prompt.sh`
    sources `branch-name.sh`) + D-003 (test pin: no
    `feature/${issue_id_lower}` literal, positive grep that
    `branch-name.sh` is sourced).

  Three layers, three tests, three different drift classes
  caught.

## 4. Decisions

### D-001: `render-prompt.sh` sources `bin/branch-name.sh`

**Verdict.** Replace the hand-rolled formation:

```bash
# bin/render-prompt.sh (pre-ENG-79, line ~212)
branch_name="feature/${issue_id_lower}-${slug}"
```

with a call to the canonical resolver:

```bash
# bin/render-prompt.sh (post-ENG-79)
branch_name="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id" 2>/dev/null \
  || printf '')"
```

The `2>/dev/null || printf ''` pair is intentional — it suppresses
the resolver's `die` message (which would land in `render-prompt.sh`'s
stderr and confuse the dispatcher's transcript-capture path) and lets
D-002's explicit emptiness check own the failure-message wording. This
mirrors how `find_doc` at `bin/render-prompt.sh:81-125` handles the
same "fallible helper, take the empty value" pattern.

**Why.** Single source of truth. `branch-name.sh` already encodes:

- The lower-case-of-issue-id rule (`bin/branch-name.sh:20`).
- The slugification rule, including the `[^a-z0-9]+ → -` collapse
  and trim (`bin/branch-name.sh:24` — same regex shape as
  `render-prompt.sh::slugify` at line 30-33, but the `branch-name.sh`
  output is what the orchestrator uses for the *worktree* branch).
- The `Feature` / `Improvement` / *unset* → `feat/` vs. `Bug` →
  `fix/` discriminator (`bin/branch-name.sh:26-29` reads from Linear
  via `linear.sh has-label`).

The first two are duplicated today between `branch-name.sh` and
`render-prompt.sh` (`render-prompt.sh::slugify` exists for the
`{slug}` token interpolation, which is independent of `{branch_name}`).
The third is *missing* from `render-prompt.sh`'s pre-ENG-79
formation entirely — the hand-rolled `feature/${issue_id_lower}-${slug}`
ignored the bug-label discriminator outright, so even if the prefix
had been `feat/`, the prompt would still have rendered `feat/…` for a
Bug-labeled issue while the orchestrator created `fix/…`. (Verified:
no Linear-label dispatch anywhere in `render-prompt.sh` pre-ENG-79.)

This is the single largest reason to source `branch-name.sh` rather
than fix the prefix in place: the prefix bug is the *visible* drift,
but the bug-label dispatch absence is the *deeper* drift, and only
sourcing closes both.

**Rejected alternative — fix the prefix in place
(`feat/${issue_id_lower}-${slug}`).** Cheaper diff (one character),
but leaves the bug-label dispatch unimplemented. Future Bug-labeled
issues would render `feat/…` in the prompt while the orchestrator
checks out `fix/…`. The same load-bearing failure recurs with one
extra layer of indirection. Rejected — fixes the symptom, not the
cause.

**Rejected alternative — duplicate `branch-name.sh`'s logic
verbatim into `render-prompt.sh` (inline the `linear.sh has-label`
call, the `tr`/`sed` slug pipeline, the `feat/`-vs-`fix/` switch).**
This is the literal anti-pattern CLAUDE.md "When wiring a new
script" § calls out: *"don't roll your own."* Two implementations
of the same logic guarantee they will drift again — exactly the
shape of the drift this ticket exists to fix. Rejected.

**Rejected alternative — pass `{branch_name}` *into*
`render-prompt.sh` from `run-local.sh` (which has already resolved
it for the worktree).** Cleaner from a "single resolution per tick"
standpoint, and would fix the §2 non-goal O-2 (duplicate fetch).
But: changes the script's CLI contract (`render-prompt.sh <stage>
<issue_id>` becomes `<stage> <issue_id> <branch_name>`), which
ripples to every caller, including `dispatch.sh::main` and the
existing test sandbox. The O-2 deduplication is a real cost (one
extra Linear API call per dispatch), but a ~50-100ms duplicate
fetch on a tick that runs every 5 min is not the failure mode this
ticket is filed to fix. Out of scope; recorded as O-2 in §10. The
CLI surface stays put; the resolver is invoked twice per tick.

### D-002: `die` if `branch-name.sh` returns empty

**Verdict.** Immediately after the resolver call, guard:

```bash
[[ -n "$branch_name" ]] \
  || die "render-prompt: branch-name.sh returned empty for $issue_id (Linear-API outage or bug-label resolution failed). Cannot render prompt without a canonical branch name."
```

**Why.** A silent empty `branch_name` would produce, e.g.,
`gh pr list --head ` (trailing space) inside the rendered prompt
body. The agent then either (a) executes that, gets a usage-error
exit from `gh`, and fails opaquely, or (b) more likely, fills the
gap with its own slug guess — exactly the regime ENG-67 spent its
brainstorm closing at the orchestrator layer.

The `die` message names *both* failure modes (Linear-API outage,
bug-label resolution) so an operator reading the per-stage
transcript at
`$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log` knows where to
look. The message intentionally does NOT mention the issue title
or any field that could leak from the failed-fetch (the resolver's
`die` at `bin/branch-name.sh:22` already names "could not fetch
title for ENG-N", so the chain self-documents).

**Rejected alternative — fall back to `feat/${issue_id_lower}`
without the slug.** "Best-effort" is exactly the silent
accommodation pattern CLAUDE.md "When wiring a new script" § rejects
and ENG-67 spent ~600 lines of brainstorm closing. The orchestrator
will have already `die`d on the same outage at
`bin/run-local.sh:242` (`die "internal: worktree_path empty after
reconcile=proceed (ENG-67); refusing to dispatch from $TARGET_REPO"`)
because `branch-name.sh` is invoked there too — `render-prompt.sh`
running into the same outage and silently degrading would actively
mask a known-bad orchestrator state. Rejected.

**Rejected alternative — `die` with a generic "branch-name.sh
failed" message and let the operator dig.** Specific failure modes
named in the message are how ENG-67's invariant-`die` in
`run-local.sh:242` works (`internal: worktree_path empty after
reconcile=proceed (ENG-67)` cites the ticket *and* the precondition).
Rejected — generic message is strictly less helpful at zero cost.

### D-003: `bin/render-prompt-test.sh` regression pin

**Verdict.** Append two asserts to `bin/render-prompt-test.sh`
(verified to exist at the path; the file already passes case 6.1
through case 6.5 covering profile-addendum behavior and ends at
~line 127 with a `Summary` block). The new asserts:

1. **Positive: `render-prompt.sh` invokes `branch-name.sh`.** Grep
   for the literal pattern
   `bash[^|]*"\$SCRIPT_DIR/branch-name\.sh"[[:space:]]+"\$issue_id"`
   in `bin/render-prompt.sh`. PASS if found, FAIL otherwise.
2. **Negative regression: no `feature/${issue_id_lower}` literal in
   `bin/render-prompt.sh`.** Grep `-qF 'feature/${issue_id_lower}'`.
   FAIL if found, PASS otherwise.

**Why.** Direct fulfillment of the issue's "Test plan" #1 (positive)
and #3 (symmetry pin parallel to ENG-67's content-test). The negative
grep specifically matches the literal token `feature/${issue_id_lower}`
— *not* `feature/`-anything-else — so the comment block at
`bin/render-prompt.sh:215-223` (which legitimately cites the
historical `feature/eng-N-…` failure mode in prose) does not
false-trigger, and arbitrary uses of the word `feature` elsewhere
in the file (e.g., a future docstring) also don't false-trigger.

The positive grep's regex (`bash[^|]*"\$SCRIPT_DIR/branch-name\.sh"
[[:space:]]+"\$issue_id"`) is anchored on the exact arg shape
(`"$SCRIPT_DIR/branch-name.sh" "$issue_id"`) so a future refactor
that switched to, say, `bash branch-name.sh "$issue_id"` (no
`$SCRIPT_DIR` prefix) would FAIL the test — which is the right
answer, because the orchestrator's path resolution depends on
`$SCRIPT_DIR`.

Adding cases to `bin/render-prompt-test.sh` rather than creating a
new sibling test file (the choice ENG-67 made for `run-local.sh`)
because: `render-prompt-test.sh` already exists, the new cases are
content-greps over the same file the existing cases test by behavior,
and the per-stage allowed-tools lane for the implement stage already
allows `Bash(bash bin/*-test.sh:*)` (per CLAUDE.md "Per-target
dispatch.tools extras §"), so no new lane changes. ENG-67 created a
new file because no `run-local-test.sh` existed and `run-local.sh`
itself doesn't have the sentinel pattern; neither constraint applies
here.

**Rejected alternative — write a behavioral test that
sources `render-prompt.sh` and asserts `{branch_name}` interpolation
end-to-end.** Would require stubbing `linear.sh get-issue` (already
done by case 6.x's existing fixtures, sort of — `src_with_env`
stubs `TARGET_REPO` but not `linear.sh`) and `branch-name.sh`
itself. Disproportionate; the content grep catches the same
regression class with two lines. Recorded as O-1 in §10.

**Rejected alternative — only add the negative grep (no
`feature/${issue_id_lower}` literal); skip the positive grep.**
The negative grep alone allows a refactor that removes the
hand-rolled formation but *also* removes the resolver call (e.g.,
hard-codes `branch_name=""` to be filled in later) to silently pass
the test while breaking the contract. The positive grep prevents
that drift. Rejected — both are needed.

## 5. Architecture (where code goes)

Single file modified, single test file modified:

| File | Change | Lines |
|---|---|---|
| `bin/render-prompt.sh` | Replace `branch_name="feature/${issue_id_lower}-${slug}"` with the resolver-call + `die` guard. Add a comment block citing ENG-79 / ENG-74 / ENG-67. | net +14 (functional +2, comment +12) |
| `bin/render-prompt-test.sh` | Append two asserts (positive grep + negative grep) under a `# ─── ENG-79 ───` heading. | +25 |

No new files, no new scripts, no new dependencies. The data flow
through `render-prompt.sh` is unchanged at the python/sed
interpolation step (`branch_name` still feeds the `{branch_name}`
substitution in the heredoc and the sed fallback) — only its
*provenance* changes.

## 6. Data flow

Pre-ENG-79:

```
issue_id (CLI arg)
  └─ tr 'A-Z' 'a-z' → issue_id_lower
       └─ "feature/${issue_id_lower}-${slug}"  ← drift point
              └─ {branch_name} substitution
                  └─ rendered prompt → claude -p
```

Post-ENG-79:

```
issue_id (CLI arg)
  └─ bash branch-name.sh "$issue_id"
       └─ linear.sh get-issue → title
       └─ linear.sh has-label "Bug" → prefix (feat|fix)
       └─ slug = lower(title) | sed
       └─ "${prefix}/${ident_lower}-${slug}"
              └─ branch_name (this script's local var)
                   └─ [[ -n "$branch_name" ]] || die  ← D-002 guard
                        └─ {branch_name} substitution
                            └─ rendered prompt → claude -p
```

The new control flow has two failure modes, both intentionally loud:

1. `branch-name.sh` itself `die`s (e.g.,
   `bin/branch-name.sh:22` — "could not fetch title"). Its stderr
   is suppressed by `2>/dev/null` in D-001's invocation; its
   non-zero exit causes the `$(... || printf '')` to substitute
   empty; D-002's `[[ -n ... ]]` guard catches the empty value
   and re-emits a contextualized `die` message naming both
   possible upstream failures.
2. The Linear API succeeds but `has-label "Bug"` returns
   ambiguous output (e.g., due to a partial response). This is
   `branch-name.sh`'s problem, not `render-prompt.sh`'s — the
   resolver returns a populated string and `render-prompt.sh`
   passes it through.

## 7. Error handling

- **Linear API outage during render-prompt** → D-002 `die`. The
  per-stage transcript captures it, the operator's tick log shows
  the `die` reason, and the next tick re-attempts (no persistent
  state mutation). Symmetric with ENG-67's `bin/run-local.sh:242`
  invariant `die`. Importantly, by the time `render-prompt.sh`
  runs (inside `dispatch.sh`, after `run-local.sh` has already
  resolved the branch via the same resolver call at
  `bin/run-local.sh:230`), an outage *here* but not *there* would
  be implausible — both calls hit the same Linear endpoint within
  seconds. The D-002 `die` is therefore mostly a defense-in-depth
  invariant; the realistic trigger is a transient mid-tick
  outage, and the right behavior on transient outage is exactly
  to fail this tick and retry next tick.
- **`branch-name.sh` returns a value containing whitespace or
  shell metacharacters** → not handled specifically; relies on
  the `branch-name.sh:24` slugification to have already collapsed
  metacharacters. Verified: `sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'`
  reduces the title to lower-case alphanumerics-and-hyphens before
  the `printf` formats the final string. No mitigation needed in
  `render-prompt.sh`.
- **The python interpolation step (lines 230-252)** consumes
  `branch_name` as a positional arg to a here-doc'd Python
  invocation. Multiline or special-char values in `branch_name`
  are safe under Python's `argv` semantics — verified at the
  existing implementation (`title` and `description` already
  carry arbitrary content through the same path). The sed
  fallback (lines 254-265) uses `|` as the delimiter; a
  `branch_name` containing `|` would break it, but
  `branch-name.sh:24`'s slugifier emits only `[a-z0-9-]/` so
  this is impossible-by-construction.

## 8. Edge cases

- **Bug-labeled issues (`fix/eng-N-…`)** — pre-ENG-79 the
  prompt always rendered `feature/eng-N-…` even for Bug issues;
  post-ENG-79 it correctly renders `fix/eng-N-…`. No special
  handling needed in `render-prompt.sh`; `branch-name.sh:26-29`
  already encodes the discriminator.
- **Issue with a title containing only non-alphanumeric chars**
  (e.g., `"!!!"`) — `branch-name.sh:24`'s `sed -E 's/^-+|-+$//g'`
  trim leaves an empty slug, producing `feat/eng-N-` (trailing
  hyphen). This is a pre-existing edge case in the resolver,
  not a new one; out of scope. Recorded as O-3 in §10.
- **`stage == "released"`** — the released stage has no
  `issue_id`; `render-prompt.sh:175-192` handles it via a
  separate code path that interpolates release-meta tokens
  (`{version}`, `{tag}`, `{prev_tag}`) and never reaches the
  `branch_name` resolution. Verified at `bin/render-prompt.sh:175`
  (the `if [[ "$stage" == "released" ]]; then ... return 0; fi`
  guard precedes the issue-id-required path). D-001 and D-002
  do not affect this path.
- **`stage == "retrospective"`** — also has no `issue_id`
  resolution (the retrospective is cross-issue). Today's
  `render-prompt.sh:194` requires an `issue_id` for non-released
  stages, but `retrospective` is invoked without one in
  `run-retrospective-local.sh` (verified: `grep -n
  'render-prompt' bin/run-retrospective-local.sh` shows the
  retrospective doesn't invoke `render-prompt.sh` at all — the
  prompt is constructed directly). So D-001/D-002 add no new
  surface for the retrospective. Out of scope.
- **Test-stage harness-self dispatch** — when the harness is
  driving itself (`PROJECT_SLUG=harness`), `branch-name.sh`
  hits the *target's* Linear team, which IS the harness's Linear
  team for self-dispatch. Verified: ENG-79 itself was rendered
  (post-fix) on `feat/eng-79-…`, matching the
  `git branch --show-current` output at the start of this
  session.

## 9. Persona review

### design — PASS
The fix is a clean delegation to the canonical resolver — same
pattern as `run-local.sh:230` (verified). Three-layer invariant
(prompt / orchestrator / renderer) is symmetric and defensible.
No new abstractions introduced. **Verdict: PASS, no findings.**

### security — PASS
No secret-handling surface touched. `branch-name.sh` already
invokes `linear.sh`, which uses `LINEAR_API_KEY` via
`bin/linear.sh::main` (out of scope, pre-existing). No
`${VAR:-FALLBACK}` or `${VAR:+ALT}` against secret-named env vars
introduced (D-002 uses `[[ -n "$branch_name" ]]` against a
non-secret variable). No subprocess argv leaks (the resolver call
is `bash "$SCRIPT_DIR/branch-name.sh" "$issue_id"` — both args are
non-secret). **Verdict: PASS, no findings.**

### scope — PASS
Strictly within the Linear issue's "Fix (concrete, ~3 lines)"
section. Test plan implements the issue's three test-plan bullets
(positive, negative regression, symmetry pin). The slightly
expanded comment block (12 lines vs. 1) is permissive
interpretation of "explaining the deletion" — but the issue body
itself shows a comment with comparable density of citation chain.
No scope creep into other `feature/`-shaped occurrences (issue
explicitly says "Out of scope: there are none in `bin/` post-PR-#48"
— verified). **Verdict: PASS, no findings.**

### coherence — PASS
Brainstorm structure follows the pattern of
`docs/brainstorms/2026-05-07-eng-67-…-design.md` — Overview →
Goals → Architectural principle → Decisions → Architecture →
Data flow → Error handling → Edge cases → Persona review →
Open questions. Each decision cites a CLAUDE.md commitment or a
prior brainstorm's precedent. Rejected alternatives are
substantive (each names a specific cost). **Verdict: PASS,
no findings.**

### product — PASS
The fix removes a silent contract violation that demonstrably
caused a P1 false-positive halt in production (ENG-74). After
the fix, agents that interpolate `{branch_name}` get a value
that matches the actual checked-out branch — every
`gh pr list --head {branch_name}`, `git push origin {branch_name}`,
`git rebase origin/main {branch_name}` site in `AGENT_PROMPTS.md`
becomes correct by construction. Operator trust in the prompt
contract is restored. **Verdict: PASS, no findings.**

### feasibility — PASS (gating)
Codebase-fact verification (every named path:line cross-checked
against the current worktree at the time of writing — see
§Assumption Inventory below):

- `bin/render-prompt.sh:212` — verified, the comment block
  starts at 212 (`# ENG-79: source the canonical branch-name
  resolver…`) and the resolver call is at line 224. ✅
- `bin/branch-name.sh:31` — verified, the `printf '%s/%s-%s\n'`
  emit-line. ✅
- `bin/branch-name.sh:6-8` — verified, the prefix-rule docstring. ✅
- `bin/branch-name.sh:20` — verified, `ident_lower` derivation. ✅
- `bin/branch-name.sh:22` — verified, `die "could not fetch
  title for $ident"`. ✅
- `bin/branch-name.sh:24` — verified, slugification regex. ✅
- `bin/branch-name.sh:26-29` — verified, prefix-discriminator
  via `linear.sh has-label`. ✅
- `AGENT_PROMPTS.md:80` — verified, "computes the canonical
  branch name once via `bin/branch-name.sh`". ✅
- `AGENT_PROMPTS.md:85-88` — verified, Hard-rules 1–4. ✅
- `AGENT_PROMPTS.md` — `\{branch_name\}` count: 23 (verified via
  `grep -c '\{branch_name\}' AGENT_PROMPTS.md`). ✅
- `bin/run-local.sh:230` — verified, `branch="$(bash
  "$SCRIPT_DIR/branch-name.sh" "$issue_id")"`. ✅
- `bin/run-local.sh:242` — verified, the
  `[[ -n "$worktree_path" ]] || die ...` guard. ✅
- `bin/run-local-content-test.sh:28-32` — verified, the
  `feature/` non-comment grep. ✅
- `bin/agent-prompts-content-test.sh:523-527` — verified,
  rejection of `feature/` variant. ✅
- `bin/render-prompt-test.sh:128-153` — verified, the ENG-79
  asserts already exist (positive at 141-146, negative at
  148-153). ✅
- `bin/common.sh:68` — verified, `issue_dir()` declaration. ✅

No facts referenced that are not verified. No P0 findings.
**Verdict: PASS (gating).**

## 10. Open questions

- **O-1 (process — flag explicitly).** The fix described in this
  brainstorm is *already in the tree* at commit `7772687`
  ("fix(eng-79): render-prompt.sh sources branch-name.sh — `feat/`
  not `feature/`"), merged via PR #65 (commit `c1d3e4e`). The
  `git log -- bin/render-prompt.sh` output shows it as the most
  recent change to that file. The brainstorm is therefore
  post-hoc documentation of an already-shipped fix — captured
  here to maintain the audit trail and to give the retrospective
  agent a brainstorm-shaped record to learn from. The
  implementation matches the design (verified by reading
  `bin/render-prompt.sh:212-226` and
  `bin/render-prompt-test.sh:128-153`). **Operator decision
  needed:** is this brainstorm useful as a back-fill, or should
  the issue be closed without further pipeline progression
  (planning/implementing are no-ops; QA/build/release have
  already happened via the original PR's merge)? Recommended
  closure path: close the issue manually after this brainstorm
  lands, or let the pipeline run through the remaining stages
  as no-ops on a clean tree.
- **O-2 (deferred optimization).** `branch-name.sh` is invoked
  twice per tick — once at `bin/run-local.sh:230` (to resolve
  the worktree) and once at `bin/render-prompt.sh:224` (to
  interpolate the prompt). Each invocation pays one Linear API
  call (`get-issue`) and one more for `has-label "Bug"` — so
  four Linear API calls per tick where one would suffice. At
  the current 5-min tick cadence and per-issue volume, this is
  ~100ms of extra wall-clock and a few extra Linear API quota
  units per tick — well below the noise floor. Deferred to a
  future ticket: thread `{branch_name}` from `run-local.sh` to
  `dispatch.sh` to `render-prompt.sh` via env var or CLI arg.
  Filing recommendation: low priority, no blast-radius.
- **O-3 (deferred edge case).** `branch-name.sh:24`'s
  slugification of an all-non-alphanumeric title produces an
  empty slug, leading to `feat/eng-N-` (trailing hyphen) being
  the canonical branch name. This is a pre-existing
  resolver-level edge case, not introduced by ENG-79; out of
  scope. Filing recommendation: low priority, would need a real
  example to motivate.
- **O-4 (test-coverage gap).** `bin/render-prompt-test.sh`
  case 6.x stubs `TARGET_REPO` and `PROJECT_SLUG` but does
  *not* stub `linear.sh` — the post-ENG-79 `render-prompt.sh`
  dispatches to `branch-name.sh`, which dispatches to
  `linear.sh get-issue` and `linear.sh has-label`, both of
  which require a live `LINEAR_API_KEY` or PIPELINE_DRY_RUN. So
  if a future test case wants to exercise the *behavior* of
  D-001 (rather than the *content* pinned by D-003), it needs
  to extend the sandbox to stub `linear.sh`. The existing
  case-6.x tests do not currently invoke the
  `branch_name`-resolution path (they exercise
  `append_project_profile` only), so this is not a regression.
  Recorded as O-1 in §4 D-003's "Rejected alternative" and
  here as a tracking note.

## 11. Anti-bias checks

### ADR stress test
There are no formal ADRs in this repo (no `docs/knowledge/decisions.md`,
verified). The closest analogues are accepted brainstorms.
Specific stress points:

- **ENG-67's brainstorm** (`docs/brainstorms/2026-05-07-eng-67-…-design.md`)
  presupposes that the orchestrator's canonical resolution path is
  the single source of truth for branch names. ENG-79 *strengthens*
  ENG-67 by extending the same single-source-of-truth principle to
  the prompt-rendering layer. **No tension.**
- **CLAUDE.md "When wiring a new script" §** says
  *"Use `log` / `die` / `require_env` / `require_bin` from common.sh
  — don't roll your own."* D-001 extends this principle to
  `branch-name.sh` (don't roll your own branch-name formation).
  **No tension.** This is reinforcement, not pressure.
- **CLAUDE.md "Sweep + scope partition (ENG-14)" §** —
  `bin/render-prompt.sh` is in `bin/`, which is in the
  `partition_dirty_paths::D-004` allowlist for the implement
  stage. Modifying it is in-scope by construction. **No tension.**

### Simpler alternative
Documented under each decision (D-001 has three rejected
alternatives, D-002 has two, D-003 has two). Each rejection cites
a specific cost — fix-the-prefix-only fails to handle bug-label
discrimination, inline-the-resolver-logic guarantees future drift,
silent-fallback masks orchestrator failures, etc.

### Assumption inventory
Every codebase fact referenced is verified against the current
worktree (see §9 feasibility).

| Assumption | Status |
|---|---|
| `bin/render-prompt.sh:212` is the comment block; resolver call lands at ~line 224 | verified (`bin/render-prompt.sh:212-226`) |
| `bin/branch-name.sh:31` is the printf-emit line | verified |
| `bin/branch-name.sh:26-29` does the bug-label discrimination | verified |
| `AGENT_PROMPTS.md` interpolates `{branch_name}` 23 times | verified (`grep -c`) |
| `bin/run-local.sh:230` is the orchestrator's resolver call | verified |
| `bin/run-local.sh:242` is the empty-`worktree_path` `die` (ENG-67) | verified |
| `bin/render-prompt-test.sh` exists and ends at ~line 159 with a Summary block | verified (file present, matches description) |
| The orchestrator strictly creates worktrees on canonical branch shape post-ENG-67 | verified (`bin/run-local.sh:227-243`) |
| ENG-74 was triggered by this drift in production | assumed (issue body cites it; the commit message of `7772687` cites the same; not independently verified by inspecting ENG-74's transcript, but the chain is internally consistent) |
| Commit `7772687` already implements the design | verified (`git log -- bin/render-prompt.sh` and direct file read) |
| Commit `c1d3e4e` merged the fix via PR #65 | verified (`git log --all --oneline`) |
| There are no other `feature/${issue_id_lower}` literals in `bin/` outside negative-rule tests | verified (Grep of `feature/\$\{issue_id_lower\}` returns only `bin/render-prompt-test.sh:128-153` — the negative-rule pin) |

### Codebase-fact verification (gating)
All named files, methods, line numbers verified — see §9 feasibility
checklist. Zero unverified facts. Zero P0 findings.

## 12. Conflicts with existing architecture

None identified. This brainstorm strengthens the existing
"canonical-prefix" invariant established by:

- ENG-13 D-004 (the `feat/`/`fix/` prefix rule),
- PR #48 / commit `4635cd3` (the prompt-side enforcement),
- ENG-67 (the orchestrator-side enforcement + legacy-path deletion),

by extending the same invariant to the renderer layer. Three
layers of defense, three independent grep-based content tests.
