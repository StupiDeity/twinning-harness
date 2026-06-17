---
linear: ENG-216
title: Add render-prompt-rc0-test.sh Case-P pinning {qa_payload_body_path} resolution on qa-stage render
date: 2026-06-17
status: draft
follow_up_source: ENG-203-d0012
finding_class_key: testing:render-prompt-rc0-test.sh:qa-payload-body-path-rc0-missing
---

# ENG-216 — Add render-prompt-rc0-test.sh Case-P pinning `{qa_payload_body_path}` resolution on qa-stage render

## 1. Overview

ENG-203 shipped the orchestrator-merge helper and rewired §6 of
`AGENT_PROMPTS.md` so the qa agent writes a content-only payload sidecar
at `{qa_payload_body_path}` (the orchestrator merges the schema envelope
before validation). The agent surface contract is two tokens — sibling
shapes:

- `{qa_predicate_body_path}` (Step 1) → `<issue-dir>/qa-predicate-<ident>.body.json`
- `{qa_payload_body_path}` (Step 9) → `<issue-dir>/verdict-qa.body.json`

ENG-203 added an end-to-end Case-O in `bin/render-prompt-rc0-test.sh` that
exercises the **full `main()` path** for `{qa_predicate_body_path}`: render
the qa-stage block under the production `AGENT_PROMPTS.md`, then grep the
stdout for the literal absolute-path substring the resolver should have
substituted (`bin/render-prompt-rc0-test.sh:497-522`). The companion case
for `{qa_payload_body_path}` was **not** added — review iteration 2 of
ENG-203 flagged this as `testing:render-prompt-rc0-test.sh:qa-payload-body-path-rc0-missing`
and the ENG-191 selective-exit rubric classified it as defer-eligible
(`reversible_post_ship: yes`, `has_workaround: yes (AP-3 grep-pin in
agent-prompts-content-test.sh as backup)`, `user_visible: no`,
`is_regression: no`).

The change is ~20 lines net addition: a Case-P block in
`bin/render-prompt-rc0-test.sh` that mirrors Case-O verbatim, substituting
the qa_payload sibling token + its expected on-disk path shape. No edits
to production code (`bin/render-prompt.sh`, `bin/common.sh`,
`AGENT_PROMPTS.md`, etc.) and no edits to other test files.

## 2. Goal

After ENG-216 lands:

- AC#1: `bin/render-prompt-rc0-test.sh` contains a new `Case-P` block
  immediately after Case-O (after L522, before the `━━━ Summary ━━━`
  printf at L524) that:
  1. Sets `ISSUE_DIR_P` to a fresh sandbox subdir for ident `ENG-87R6X-P`.
  2. Renders the qa stage end-to-end through the production prompt path
     using the same env-var setup as Case-O.
  3. Asserts the rendered stdout contains the full absolute-path string
     `<sandbox>/state/test-slug-rc0/ENG-87R6X-P/verdict-qa.body.json`.
  4. Calls `ok` on success / `fail` on regression with the same stderr
     shape Case-O uses.
- AC#2: `bash bin/render-prompt-rc0-test.sh` exits 0 — every existing
  case (A–O) plus the new Case-P passes against the current production
  tree.
- AC#3: Full `.githooks/pre-commit` suite green (no regressions in any
  sibling test).
- AC#4: No companion changes to `bin/render-prompt.sh`,
  `bin/common.sh`, `bin/agent-prompts-content-test.sh`,
  `AGENT_PROMPTS.md`, or any operator runbook — this PR is one-file,
  ~20-line addition (D-002).

## 3. Decisions

### D-001. Mirror Case-O's end-to-end render-and-grep shape verbatim, with the qa_payload sibling substitutions.

**The change.** Append a Case-P block immediately after Case-O in
`bin/render-prompt-rc0-test.sh`. The block shape mirrors Case-O
(`bin/render-prompt-rc0-test.sh:497-522`) with three textual deltas:

1. Token name: `{qa_predicate_body_path}` → `{qa_payload_body_path}`.
2. Resolver name: `_resolve_qa_predicate_body_path` → `_resolve_qa_payload_body_path`.
3. Expected basename: `qa-predicate-<ident>.body.json` → `verdict-qa.body.json`
   (note: `verdict-qa.body.json` has no ident embedded — see A-3).

The literal block (proposed text):

```bash
# ─── ENG-216 case P: {qa_payload_body_path} resolves on qa-stage render
# Mirror of case O above for the sibling Step-9 sidecar token. §6 step 9
# instructs the agent to Write the dimensional grading payload to
# {qa_payload_body_path}; render-prompt.sh::PROMPT_RESOLVERS registers
# `qa_payload_body_path` → `_resolve_qa_payload_body_path`; main() binds
# _RENDER_QA_PAYLOAD_BODY_PATH via common.sh::qa_payload_body_path(issue_id).
# The rendered prompt MUST contain the full absolute-path shape
# `<issue-dir>/verdict-qa.body.json` — basename-only would pass even if a
# regression dropped the directory prefix and emitted just `verdict-qa.body.json`
# (broken authority surface; agent would Write into cwd).
ISSUE_DIR_P="$sandbox/state/test-slug-rc0/ENG-87R6X-P"
rm -rf "$ISSUE_DIR_P"; mkdir -p "$ISSUE_DIR_P"
out_p="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
  PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
  HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
  _timeout bash "$sandbox/bin/render-prompt.sh" qa ENG-87R6X-P 2>/dev/null || true)"
EXPECTED_P="$sandbox/state/test-slug-rc0/ENG-87R6X-P/verdict-qa.body.json"
if grep -qF "$EXPECTED_P" <<<"$out_p"; then
  ok "ENG-203/ENG-216 case P: {qa_payload_body_path} resolves to $EXPECTED_P on qa-stage render"
else
  fail "ENG-203/ENG-216 case P: {qa_payload_body_path} resolves on qa-stage render" \
       "expected absolute-path substring '$EXPECTED_P' missing from rendered prompt — out tail: $(tail -10 <<<"$out_p" | tr '\n' ' ')"
fi
```

**Why this exact shape (not a refactor).**

- The Case-O comment at L497-508 names the failure mode the test is
  designed to catch: "basename-only would pass even if a regression
  dropped the directory prefix and emitted just the filename (broken
  authority surface)". The same failure mode applies symmetrically to
  `{qa_payload_body_path}`. Mirroring the assertion shape preserves
  the same regression-detection contract.
- The body-path token would resolve to **empty string** if a future
  change drops the `_RENDER_QA_PAYLOAD_BODY_PATH` bind at
  `bin/render-prompt.sh:687` while leaving the resolver and registry
  entry intact. The render-time validator would NOT die (the resolver
  exists; it just returns ""), the qa-stage exit-0 sweep at L127 would
  still pass, the AP-3 prompt-content pin at
  `bin/agent-prompts-content-test.sh:547-553` would still pass (it
  only greps the source `AGENT_PROMPTS.md` for the literal token, not
  the rendered output). Case-P is the only test that would detect this
  shape of silent-resolution regression — proportional to the gap.
- A refactor that DRYs Case-O + Case-P into a loop (one stage, two
  tokens) was considered and rejected (see Rejected alternatives
  below).

**Rationale.**

- **Constraint:** CLAUDE.md "When wiring a new script" — "For exit
  codes, use the `failure_outcome_for_exit` taxonomy"; sibling tests
  use the `ok` / `fail` helpers defined at the top of the file. The
  proposed Case-P uses those helpers exactly the way Case-O does.
- **Constraint:** ENG-203 brainstorm AC#1 — "schema_version absent
  from agent surface; orchestrator merges envelope before validation."
  The orchestrator path depends on the agent receiving an absolute
  path under `$(issue_dir <ident>)` (so the merge helper's
  `<canonical>` arg lands in the correct authority surface). Case-P
  pins that the path the agent sees IS that absolute path, not a
  basename or an empty string.
- **Constraint (sizing rubric, CLAUDE.md "Ticket sizing rubric").**
  1 subsystem (tests/fixtures) + 1 design decision (add the missing
  case) = autonomy-safe. The ENG-191 selective-exit rubric classified
  it as `reversible_post_ship: yes`; D-002 below confirms zero
  spillover to other files.

### D-002. The change is one file, ~20-line addition. No edits to production code or other test files.

**Surface scoped to `bin/render-prompt-rc0-test.sh`.** Verified nothing
else needs to change:

- `bin/render-prompt.sh` — the resolver, registry entry, and main()
  bind for `{qa_payload_body_path}` ALL exist on disk
  (`bin/render-prompt.sh:61, 113, 289, 687`). The pin asserts the
  current state; no production-code edit needed.
- `bin/common.sh::qa_payload_body_path` — the helper exists at
  `bin/common.sh:99-103` and is exported at `bin/common.sh:961`.
  Unchanged.
- `AGENT_PROMPTS.md` — §6 step 9 carries the literal token at
  `AGENT_PROMPTS.md:2107`. Unchanged.
- `bin/agent-prompts-content-test.sh::AP-3` — already pins the
  literal token's presence in §6 (`bin/agent-prompts-content-test.sh:547-553`).
  Case-P is orthogonal: AP-3 protects the source-template; Case-P
  protects the registry + bind chain in `render-prompt.sh`. Both stay.
- `docs/runbooks/recovery.md` — no operator-visible behaviour change.
  Recovery for `qa-payload-invalid` halts is documented generically
  in §15 (and quoted in CLAUDE.md's failure-mode quick reference,
  `CLAUDE.md:826`). No edit needed.

**Rationale.** Ticket-sizing rubric in CLAUDE.md: 1 subsystem
(tests/fixtures) + 1 design decision = autonomy-safe. Mirror ENG-213
(its sibling ENG-203 follow-up, brainstormed today and also
sub-3-LOC + one shape-pin test) — small-shape brainstorms produce
clean small PRs.

**Reference to constraint.** CLAUDE.md "Don't add features,
refactor, or introduce abstractions beyond what the task requires."
The deferred finding is one missing test case; the PR is one added
test case.

### D-003. Use ident `ENG-87R6X-P` to extend the existing sandbox-fixture naming series.

**The choice.** Case-A through Case-O all use the `ENG-87R6X-<letter>`
sandbox-fixture ident convention (`bin/render-prompt-rc0-test.sh:144,
159, 192, 214, 249, 265, 315, 335, 358, 377, 400, 425, 456, 479,
509`). Case-P continues the series.

**Why this matters.** The `ENG-87R6X-` prefix is a Case-87-R6 forensic
marker — the original `render-prompt-rc0-test.sh` file was added under
ENG-87 review iter-7 Case-87-R6 to close the rc=0 sweep gap. Every
case-letter is a fixture-scoped ident under that umbrella. Using a
different prefix (`ENG-216-P`) would fragment the convention and
operator-grep recipes (`grep ENG-87R6X bin/render-prompt-rc0-test.sh`)
would miss the new case.

**Rejected alternative.** Use `ENG-216-A` to make the new case
self-identifying. Rejected because:

- The existing file is internally a Case-87-R6 corpus — every case
  letter shares the prefix even when the case was added by a later
  ticket (Cases L/M/N are ENG-140; Case-O is ENG-113/ENG-203; both use
  `ENG-87R6X-`).
- A fresh prefix would require updating the file's header docstring
  (which currently scopes the whole file to Case-87-R6).
- The ticket-name (ENG-216) appears in the `ok` / `fail` strings
  ("ENG-203/ENG-216 case P: ..."), which is the operator-grep entry
  point. The fixture ident is internal scaffolding.

**Reference to constraint.** CLAUDE.md "Language idioms — Use `log` /
`die` / `require_env` / `require_bin` from common.sh; don't roll your
own." The same principle applies to test-fixture naming conventions
within a single test file: follow the established idiom, don't fork
it for a one-line case.

## 4. Architecture (where the code lives)

| Site | File | Lines | Change |
|---|---|---|---|
| New Case-P block | `bin/render-prompt-rc0-test.sh` | (insert at L523, between Case-O and the `━━━ Summary ━━━` printf at L524) | ADD ~20 lines |

No edits to:

- `bin/render-prompt.sh` — the resolver chain is unchanged and
  already on disk (lines 61, 113, 289, 687 — see A-1, A-2, A-3, A-4).
- `bin/common.sh` — `qa_payload_body_path` helper unchanged
  (`bin/common.sh:99-103`).
- `AGENT_PROMPTS.md` — §6 step 9 unchanged (line 2107).
- `bin/agent-prompts-content-test.sh` — AP-3 stays as the
  source-template grep-pin (L547-553).
- `bin/run-stage.sh` — the orchestrator's qa-stage merge path
  consumes the body file independently of this render-time pin.
- `learned-rules/harness/*.md` — no new retrospective rule needed.
- `docs/runbooks/recovery.md` — no operator-visible change.
- `CLAUDE.md` — no new failure-mode row needed.

## 5. Data flow

`{qa_payload_body_path}` token resolution chain (unchanged by ENG-216;
Case-P is a pin on the existing chain):

```
qa-stage render starts: bash bin/render-prompt.sh qa <ident>
  ↓ main() at render-prompt.sh:687 binds:
    _RENDER_QA_PAYLOAD_BODY_PATH="$(qa_payload_body_path "$ident")"
  ↓ qa_payload_body_path (common.sh:99-103) returns:
    "$PROJECT_STATE_DIR/$ident/verdict-qa.body.json"
  ↓ extract_block reads §6 from AGENT_PROMPTS.md, including the
    literal "{qa_payload_body_path}" token at AGENT_PROMPTS.md:2107
  ↓ resolve_block_tokens (render-prompt.sh:475) walks PROMPT_RESOLVERS,
    finds `qa_payload_body_path=_resolve_qa_payload_body_path` (L61),
    calls _resolve_qa_payload_body_path (L289) which prints
    "$_RENDER_QA_PAYLOAD_BODY_PATH"
  ↓ bash ${rendered//$t/$value} substitutes "{qa_payload_body_path}"
    with the absolute path
  ↓ rendered prompt goes to stdout; orchestrator passes it to
    `claude -p` as the per-stage prompt body
```

Case-P pins the contract that the substituted string is the FULL
absolute path (not empty, not basename-only). If any link in the
chain breaks silently (e.g. main() bind line deleted →
`_RENDER_QA_PAYLOAD_BODY_PATH` unset → resolver prints empty), Case-P
fails; the qa-stage exit-0 sweep at L127 would still pass; AP-3 would
still pass; this is the only test that catches the regression class.

## 6. Error handling

**Case-P fails (regression detected).** The `fail` helper prints the
fail line with the stderr-tail of the rendered output; the test
script's `[[ "$FAIL" == 0 ]] || exit 1` at L525 exits non-zero. The
pre-commit hook surfaces the failure (`render-prompt-rc0` is not in
KNOWN_BROKEN per project-profile — verified A-5).

**Sandbox state pollution between cases.** Each case `rm -rf`'s its
own fixture dir before `mkdir -p` (Case-O at L510, Case-P proposed
to do the same). No fixture-collision across cases. The sandbox
itself is created with `mktemp -d` at L49 and cleaned up by the
`trap cleanup EXIT` at L50-51.

**Render timeout.** Case-P calls `_timeout bash
"$sandbox/bin/render-prompt.sh" qa ENG-87R6X-P` — the same
`gtimeout`-wrapping helper Case-O uses (defined at L37-42). A perf
regression (e.g. the bash-3.2 multibyte `${//}` catastrophe documented
at L29-36) fails Case-P within `RENDER_TIMEOUT` seconds rather than
stalling the pre-commit suite indefinitely. Same guard as Case-O.

**Empty resolver output.** If `_RENDER_QA_PAYLOAD_BODY_PATH` is unset
(regression at L687) → resolver returns "" → token substitutes to
empty → expected absolute-path substring is NOT in stdout → Case-P
fails with the expected-path string in the diagnostic. This IS the
failure mode Case-P is designed to detect.

## 7. Edge cases

| Edge case | Pre-fix (no Case-P) | Post-fix (Case-P present) |
|---|---|---|
| `_RENDER_QA_PAYLOAD_BODY_PATH` bind line deleted at render-prompt.sh:687 | Render exit 0; AP-3 pin passes (source-template grep); agent receives `Write` step pointing at empty path | Case-P fails: expected substring missing |
| PROMPT_RESOLVERS entry `qa_payload_body_path=_resolve_qa_payload_body_path` at L61 deleted | Render dies "unknown token in source" → existing for-loop qa render fails | Same — caught by existing for-loop AND Case-P |
| `_resolve_qa_payload_body_path` function body at L289 deleted | Render dies "unknown resolver" | Same — caught by existing for-loop |
| `qa_payload_body_path` helper at common.sh:99-103 deleted | main() bind at L687 dies "command not found" → render exits non-zero | Caught by existing for-loop qa render |
| `{qa_payload_body_path}` literal removed from AGENT_PROMPTS.md §6 step 9 | AP-3 fails immediately | AP-3 still primary; Case-P passes vacuously (token not present → no substitution needed → no expected substring assertion failure path triggered — but the expected substring is the resolved path, not the token, so the grep simply fails since the path is not in the rendered prompt) → Case-P also fails |
| Token added to a NEW stage (e.g. §3 implementing) without binding | render-prompt-test.sh::ENG-87 R5 registry-coverage pin catches it (cited in render-prompt.sh:537-538) | Same — Case-P is qa-specific |
| `verdict-qa.body.json` basename renamed in common.sh | Existing for-loop qa render passes; AP-3 passes; downstream orchestrator merge path fails at runtime | Case-P fails with `EXPECTED_P` carrying the OLD basename — operator updates Case-P alongside the rename. Acceptable coupling — the rename is rare and the test is the single source of truth for the contract. |
| Parallel execution of Cases O and P (theoretical) | n/a | Each case writes to its own `ISSUE_DIR_<letter>`; sandbox is per-test-process mktemp. No collision. (Note: the existing test file executes serially; no parallelism today.) |
| Sandbox dir contains spaces or unicode | mktemp generates unicode-free dirs on macOS by default | Same — Case-P uses `mktemp` output verbatim through `$sandbox` |

## 8. Open questions

**OQ-1. Should we add a similar pin for `{qa_predicate_path}` (the
canonical-path-only resolver, distinct from `qa_predicate_body_path`)?**
No. `{qa_predicate_path}` is not in the §6 agent surface anymore —
ENG-203 renamed step 1's reference from `{qa_predicate_path}` to
`{qa_predicate_body_path}` (verified at `AGENT_PROMPTS.md:2003`).
The canonical-path resolver remains live because `verify-qa.sh::cmd_validate`
consumes it internally, but the agent never sees it. A pin would
test a non-existent code path. If a future stage adds back a token
to the agent surface, file a follow-up.

**OQ-2. Should the pin also assert the resolved path EXISTS on disk?**
No. Case-P pins the **render-time string substitution**, not the
runtime existence of the file. The agent is responsible for creating
the file via `Write`; the orchestrator's clear-on-dispatch-start
(`bin/run-stage.sh::_clear_current_stage_slots`, qa branch — ENG-203
D-005) removes any stale file before each qa dispatch. Case-O does
not assert disk-existence either; mirror the established shape.
The on-disk-existence contract is covered by ENG-203 OS-4
(clear-on-qa-stage start) and the orchestrator merge helper's rc=41
check (body missing → halt).

**OQ-3. Should we add a Case-P-negative — assert the rendered prompt
does NOT contain the literal token `{qa_payload_body_path}` post-
substitution?** No. Case-O does not do this either, and the
substitution invariant is enforced by `resolve_block_tokens` (any
token left in the rendered output would only escape through
`AGENT_RUNTIME_TOKENS`, which `qa_payload_body_path` is not part of
— verified A-6). Adding a negative pin would conflate two test
contracts (positive substitution + residual scan); Case-P stays
focused.

**OQ-4. Does this PR touch ENG-203's PR #175?** No. PR #175 is merged
(commit `ede2380` per Recent commits in the workspace). ENG-216
ships as a fresh PR on its own feature branch (the deferred-majors
auto-creation flow filed ENG-216 separately for this finding).

**OQ-5. Should we DRY Case-O and Case-P into a loop over `(token,
expected_basename)` tuples?** No (see Rejected alternatives §9).

**OQ-6. Operator-runbook update needed?** No. The recovery recipe
for `qa-payload-invalid` halts in `docs/runbooks/recovery.md` §15
is unchanged; the runbook references the **runtime** failure mode
(missing/malformed body file), not the render-time resolver chain
this test pins. If the resolver chain breaks silently AND ships to
prod, the symptom would be qa agent writing the body to an empty
path (cwd) → orchestrator merge helper finds no body at the
expected location → rc=41 → `qa-payload-missing` halt. Recovery
unchanged: `bash bin/pipeline.sh decide <ENG-N> --action continue`.

## 9. Anti-bias checks

### ADR stress test

This PR puts **no pressure** on any prior architectural decision.
Specifically:

- **ENG-203 (orchestrator-merge helper).** Directly *supports* — pins
  the agent-surface contract ENG-203 shipped. Closes the last
  deferred-majors finding from PR #175 review iter-2 in the testing
  bucket.
- **ENG-87 (cross-dispatch staleness).** Untouched — the dispatch_id
  flow and `$PIPELINE_DISPATCH_ID` envelope are unrelated to the
  resolver chain Case-P exercises.
- **ENG-117 (qa-payload validator).** Untouched —
  `_validate_qa_payload` and `qa-payload-schema.sh` are runtime-side;
  Case-P is render-time.
- **ENG-101 (defensive-code restraint).** Neutral — Case-P is a
  test addition; no production code defensive arm added or removed.
- **ENG-191 (deferred-majors ship-with-known-debt).** This ticket
  **exercises** the deferred-majors path; it's the third
  deferred-majors-auto-created follow-up from ENG-203 (sibling tickets
  ENG-212, ENG-213). Shipping it cleanly closes the loop.

The harness has no formal ADR registry (verified: `docs/` has no
`adr/` or `decisions.md`); the relevant decisions above are the
ENG-N brainstorms themselves.

### Simpler alternatives considered

| Alternative | Why rejected |
|---|---|
| **Do nothing; rely on AP-3 (agent-prompts-content-test.sh) as the only pin** | AP-3 protects the source-template only — it greps `AGENT_PROMPTS.md` for the literal `{qa_payload_body_path}` string. A regression that drops the `_RENDER_QA_PAYLOAD_BODY_PATH` bind in `render-prompt.sh::main()` (L687) would leave AP-3 passing while the token silently resolves to empty string at render time. AP-3 + render-prompt.sh exit-0 sweep together do not detect this failure mode; Case-P does. The Linear ticket explicitly calls AP-3 the "backup" — implying primary coverage is the rc0 test sibling of Case-O. |
| **DRY Case-O + Case-P into a loop over `(token, expected_basename)` tuples** | The two cases are short (~15 lines each), share the same env-var setup, and differ only in 3 string substitutions. A loop would cost more lines than it saves (loop scaffolding + a tuple table) AND obscure the per-case forensic comment that names the failure mode. The existing case-letter convention (A–O, mostly hand-written) demonstrates the project's preference for case-per-block over loops. If a future PR adds 3+ more body-path tokens, then DRY makes sense; today, two cases is below the abstraction-justifying threshold (CLAUDE.md "Three similar lines is better than a premature abstraction"). |
| **Replace the grep on the expected absolute path with a regex on `<sandbox>/state/test-slug-rc0/[^/]+/verdict-qa.body.json`** | Looser assertion would allow any ident-shaped subdir to satisfy the grep — the test would pass even if the resolver returned the WRONG ident's path (e.g. a cross-issue leak). The literal-grep on the exact expected path catches that class. Case-O uses the literal-grep shape; mirror it. |
| **Add Case-P AND change Case-O to use a shared helper function** | Mixes scope — refactoring Case-O is not the deferred finding. Out of scope per D-002 and CLAUDE.md "Don't add features, refactor, or introduce abstractions beyond what the task requires." If a third sibling pin is needed in the future, the helper can be extracted then. |
| **Defer indefinitely** (leave ENG-216 in Backlog) | Defeats the ENG-191 / ENG-193 ship-with-known-debt loop. The deferred-majors auto-creation flow exists precisely so these follow-ups DO ship. The PR is ~20 lines; cheap to land. |
| **Promote Case-P to a sibling separate file (`bin/render-prompt-rc0-qa-payload-test.sh`)** | The existing file is the canonical home for full-`main()`-path rc0 sweeps; A–O all live there. A sibling file would split the test surface for no benefit and add a new file to the pre-commit globbing surface (`bin/*-test.sh`) for one case. Reject — single-file addition is correct shape. |

### Assumption inventory

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A-1 | `PROMPT_RESOLVERS` registers `qa_payload_body_path=_resolve_qa_payload_body_path` at `bin/render-prompt.sh:61` | verified | Read of `bin/render-prompt.sh:60-62` — both `qa_predicate_path` and `qa_payload_body_path` entries present, sibling pattern. |
| A-2 | `_resolve_qa_payload_body_path` resolver body lives at `bin/render-prompt.sh:289` | verified | Read of `bin/render-prompt.sh:289` — `_resolve_qa_payload_body_path() { printf '%s' "$_RENDER_QA_PAYLOAD_BODY_PATH"; }` |
| A-3 | `qa_payload_body_path <ident>` helper at `bin/common.sh:99-103` returns `<issue-dir>/verdict-qa.body.json` (no ident in basename, unlike `qa_predicate_body_path` which DOES embed the ident) | verified | Read of `bin/common.sh:99-103` — `printf '%s/verdict-qa.body.json' "$(issue_dir "$issue")"`. Sibling `qa_predicate_body_path` at L104-108 returns `qa-predicate-%s.body.json`. The asymmetry is intentional: predicate is per-issue distinguishable on shared dirs (legacy), payload is always one-per-issue-dir. Case-P's `EXPECTED_P` reflects this — no ident in the basename. |
| A-4 | main() at `bin/render-prompt.sh:687` binds `_RENDER_QA_PAYLOAD_BODY_PATH` via `qa_payload_body_path "$issue_id"` | verified | Read of `bin/render-prompt.sh:684-688` — both `_RENDER_QA_PAYLOAD_BODY_PATH` and `_RENDER_QA_PREDICATE_BODY_PATH` bound side-by-side. |
| A-5 | `render-prompt-rc0` is NOT in pre-commit `KNOWN_BROKEN` allowlist | verified | Project-profile addendum lists KNOWN_BROKEN as `eng-81-reproducer, mutex, render-pr-body, render-prompt-slug`. `render-prompt-rc0` is not in the list. The pre-commit hook iterates `bin/*-test.sh` and runs `render-prompt-rc0-test.sh` on every commit. |
| A-6 | `qa_payload_body_path` is NOT in `AGENT_RUNTIME_TOKENS` (the resolver IS called at render time) | verified | Read of `bin/render-prompt.sh:86` — `AGENT_RUNTIME_TOKENS=' file pr_number '` — only `file` and `pr_number` are runtime-passthrough. |
| A-7 | Case-O exists at `bin/render-prompt-rc0-test.sh:497-522` and uses the `_timeout bash "$sandbox/bin/render-prompt.sh" qa <ident>` pattern with the absolute-path grep | verified | Read of `bin/render-prompt-rc0-test.sh:497-522` — full Case-O block. |
| A-8 | `AP-3` in `bin/agent-prompts-content-test.sh:547-553` pins the literal `{qa_payload_body_path}` token in §6 of `AGENT_PROMPTS.md` | verified | Read of `bin/agent-prompts-content-test.sh:547-553` — `grep -qF '{qa_payload_body_path}' "$s6"`. |
| A-9 | `AGENT_PROMPTS.md:2107` contains the literal `{qa_payload_body_path}` token in §6 step 9 | verified | `grep -n "qa_payload_body_path" AGENT_PROMPTS.md` → line 2107. |
| A-10 | `issue_dir` at `bin/common.sh:68-72` returns `$PROJECT_STATE_DIR/$issue` | verified | Read of `bin/common.sh:68-72`. Confirms `EXPECTED_P` shape — `$sandbox/state/test-slug-rc0/ENG-87R6X-P/verdict-qa.body.json` when `PROJECT_STATE_DIR=$sandbox/state/test-slug-rc0` (matches Case-O's env-var setup). |
| A-11 | The sandbox setup at `bin/render-prompt-rc0-test.sh:49-103` creates a `bin/render-prompt.sh` copy + symlink to `AGENT_PROMPTS.md`; Case-P inherits the same sandbox unmodified | verified | Read of `bin/render-prompt-rc0-test.sh:49-103` — single mktemp sandbox + copies, used by every case. Case-P inserts at L523, after Case-O, with the same `$sandbox` shape. |
| A-12 | `ok` / `fail` helpers defined at `bin/render-prompt-rc0-test.sh:27-28` track `PASS` / `FAIL` counters; exit gate at L525 (`[[ "$FAIL" == 0 ]] || exit 1`) | verified | Read of `bin/render-prompt-rc0-test.sh:26-28` (helper defs) and L524-526 (summary + exit gate). |
| A-13 | The pre-commit hook globs `bin/*-test.sh` (per ENG-196) so a new case inside an existing file is covered without hook-list edits | verified | CLAUDE.md "Tests" section + project-profile addendum "Build & test gates" both state the hook globs `bin/*-test.sh`. Case-P sits inside `render-prompt-rc0-test.sh` (existing); no new file. |
| A-14 | `partition_dirty_paths` permits writes to `bin/render-prompt-rc0-test.sh` on the `implementing` stage | verified | The file is in `bin/` which the project-profile's `## File layout` declares as the canonical script directory; `implementing` stage's scope-allowlist includes `bin/`. ENG-213 brainstorm A-13 made the same assumption (also marked "assumed → verify at implement time"); the next dispatch will scope-sweep at tick-end and either pass or surface a self-leak halt to fix. |
| A-15 | The ENG-87R6X-* fixture-ident convention is followed by every case-letter A–O in the file | verified | Read of L144 (A), L159 (B), L192 (C), L214 (D), L249 (E), L265 (F), L315 (G), L335 (H), L358 (I), L377 (J), L400 (K), L425 (L), L456 (M), L479 (N), L509 (O) — all use `ENG-87R6X-<letter>`. Case-P continues at L523-ish. |
| A-16 | The ENG-203 brainstorm AP-3 pin description (`agent-prompts-content-test.sh:547-553`) does NOT obviate Case-P because AP-3 only greps `AGENT_PROMPTS.md` source, not rendered output | verified | Read of AP-3 body — `grep -qF '{qa_payload_body_path}' "$s6"` where `$s6` is the literal §6 text from the source file, NOT the output of `render-prompt.sh`. AP-3 catches "token deleted from prompt body"; Case-P catches "token present in prompt body but resolver chain broken at render time." Orthogonal contracts. |
| A-17 | The render-prompt-test.sh ENG-87 R5 "registry-coverage" pin (referenced at `bin/render-prompt.sh:537-538`) catches new tokens added without a registered resolver — but does NOT catch a resolver that returns empty on a registered token | verified-by-inspection | Read of `bin/render-prompt.sh:534-538` comment — names the R5 case as "Drift detection for new tokens added to AGENT_PROMPTS.md without a matching resolver." Empty-resolver-output is not in scope; Case-P is the missing pin. |
| A-18 | Case-P's expected substring `$sandbox/state/test-slug-rc0/ENG-87R6X-P/verdict-qa.body.json` matches the path `qa_payload_body_path` will resolve at render time when the test invokes `_timeout bash "$sandbox/bin/render-prompt.sh" qa ENG-87R6X-P` with `PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0"` | verified | Composition of A-3 (helper returns `<issue-dir>/verdict-qa.body.json`) + A-10 (`issue_dir` returns `$PROJECT_STATE_DIR/$ident`) + A-4 (main() binds the helper output) + the test's `PROJECT_STATE_DIR` env-var = `$sandbox/state/test-slug-rc0/ENG-87R6X-P/verdict-qa.body.json`. |

### Codebase-fact verification

All named code artifacts referenced above were verified by opening
the file and quoting a `path:line` reference:

- `PROMPT_RESOLVERS` registry entry — `bin/render-prompt.sh:61`
- `_resolve_qa_payload_body_path` resolver body — `bin/render-prompt.sh:289`
- main() bind site — `bin/render-prompt.sh:687`
- `_write_rendered_paths_sidecar` participation — `bin/render-prompt.sh:113`
- `qa_payload_body_path` helper — `bin/common.sh:99-103`
- `issue_dir` helper (called by qa_payload_body_path) — `bin/common.sh:68-72`
- common.sh export list (helper is exported) — `bin/common.sh:961`
- §6 step 9 token in AGENT_PROMPTS.md — `AGENT_PROMPTS.md:2107`
- §6 step 1 sibling token — `AGENT_PROMPTS.md:2003, 2021`
- AP-3 prompt-content pin — `bin/agent-prompts-content-test.sh:547-553`
- AP-5 sibling pin (qa_predicate_body_path) — `bin/agent-prompts-content-test.sh:571-579`
- Case-O precedent in rc0 test — `bin/render-prompt-rc0-test.sh:497-522`
- `ok` / `fail` helpers — `bin/render-prompt-rc0-test.sh:27-28`
- `_timeout` helper + RENDER_TIMEOUT — `bin/render-prompt-rc0-test.sh:37-42`
- Sandbox setup — `bin/render-prompt-rc0-test.sh:49-103`
- Summary + exit gate — `bin/render-prompt-rc0-test.sh:524-526`
- AGENT_RUNTIME_TOKENS allowlist — `bin/render-prompt.sh:86`
- resolve_block_tokens (registry pass) — `bin/render-prompt.sh:475-521`
- CLAUDE.md failure-mode quick reference qa-payload row — `CLAUDE.md:826`
- ENG-203 brainstorm AC#1 (`qa_payload_schema_version` absent from agent surface) — `docs/brainstorms/2026-06-16-eng-203-foundation-orchestrator-merge-helper-content-only-qa-artifacts-verdict-qa-json-qa-predicate-design.md:625`
- ENG-203 brainstorm AP-3 plan — `docs/brainstorms/2026-06-16-eng-203-…-design.md:628`

The proposed Case-P block (literal text in §D-001 above) is the
only new artifact; every reference it makes to existing code or
test fixtures resolves to a current path:line in the worktree.

## 10. Persona review

Six personas were run in order: design → security → scope →
coherence → product → feasibility (gating).

### Persona 1 — design (PASS)

**Verdict.** PASS.

**Strengths.**

- One-decision, one-file PR with a tight scope boundary
  (D-002 explicitly enumerates the no-touch surfaces).
- The orthogonality argument between AP-3 (source-template grep)
  and Case-P (rendered-output grep) is the load-bearing design
  judgement — both could plausibly seem to cover the same thing;
  the brainstorm picks them apart on the failure-mode axis
  (token-deletion vs bind-deletion) rather than treating them as
  redundant. That's the right level of design care for a
  sub-3-LOC-equivalent test addition.
- D-003's fixture-ident-convention rationale (use `ENG-87R6X-P`
  rather than `ENG-216-A`) acknowledges that the file has an
  internal corpus convention and follows it; the operator-grep
  recipe stays coherent.
- The asymmetry between `qa_payload_body_path`
  (basename `verdict-qa.body.json` — no ident) and
  `qa_predicate_body_path` (basename
  `qa-predicate-<ident>.body.json` — ident-embedded) is called
  out in A-3 so a future maintainer copying Case-P doesn't paste
  the wrong basename shape.

**No P0/P1 findings.**

### Persona 2 — security (PASS)

**Verdict.** PASS.

**Surface review.**

- No new user-facing input. No new env var reads. No new
  shell-quoting context. Case-P invokes
  `_timeout bash "$sandbox/bin/render-prompt.sh" qa ENG-87R6X-P`
  with a fixed-literal ident — no agent-controlled data flows
  into the test invocation.
- The expected-substring grep uses `grep -qF` (fixed-string,
  not regex) on a literal `$EXPECTED_P` string composed from
  `$sandbox` (mktemp output) + literal path. No regex injection
  surface.
- The sandbox dir is `mktemp -d` and cleaned up by the existing
  `trap cleanup EXIT`. Case-P inherits both unchanged.
- `_timeout` wraps the render with `gtimeout` — a DoS-style
  perf regression (e.g. the bash-3.2 multibyte catastrophe)
  fails the test fast rather than stalling pre-commit.

**Adversarial check — could a malicious agent exploit Case-P to
exfiltrate secrets?** No. The test reads stdout from
`render-prompt.sh` which is the rendered prompt body — the same
text every dispatched `claude -p` session sees. The render-time
sidecar at `bin/render-prompt.sh:113` writes path tokens to
`$(issue_dir)/.rendered-paths-<stage>` (not stdout). Case-P
greps stdout for a literal expected path; no shell evaluation,
no `eval`, no command substitution on the grep target.

**No P0/P1 findings.**

### Persona 3 — scope (PASS)

**Verdict.** PASS.

**Scope check.**

- Linear-stated scope: add the 20-line case for the
  `qa-payload-body-path` rc0 coverage gap deferred from ENG-203
  iter-2.
- Brainstorm scope: D-001 (add Case-P) + D-002 (no companion
  edits) + D-003 (use existing fixture convention).
- Outside scope: refactor of Case-O (rejected alt), pin for
  `{qa_predicate_path}` canonical resolver (OQ-1 defers
  explicitly), runbook update (OQ-6 defers explicitly), Case-P
  negative (OQ-3 defers explicitly), DRY refactor (OQ-5 defers
  explicitly).

**Sub-axis — subsystems touched.** One (tests/fixtures — just
`bin/render-prompt-rc0-test.sh`). Below the 3+ "split before
filing" threshold from CLAUDE.md.

**Sub-axis — independent design decisions.** One (add the
missing case). D-002 and D-003 are sub-decisions of D-001, not
independent design choices.

**No P0/P1 findings.**

### Persona 4 — coherence (PASS)

**Verdict.** PASS.

**Coherence with existing patterns.**

- Naming: new test case titled `ENG-203/ENG-216 case P` —
  mirrors `ENG-113/ENG-203 case O` (multi-ticket prefix
  acknowledging both the original umbrella and the polish PR).
- Test placement: `bin/render-prompt-rc0-test.sh` after Case-O
  and before the `━━━ Summary ━━━` printf — symmetric with
  Case-O's placement after Case-N.
- Pattern coherence: Case-O at L497-522 is the named precedent;
  Case-P reuses the env-var setup, the `_timeout` wrapper, the
  `mktemp` sandbox dir, the `rm -rf; mkdir -p` fixture, the
  `grep -qF` expected-substring assertion, and the
  `ok` / `fail` helpers — every shape detail mirrored.
- The fixture-ident convention (`ENG-87R6X-P`) follows D-003.
- The asymmetry between this test and AP-3 (orthogonal pins,
  not redundant) is coherent with ENG-203's broader division
  of pin labour: AP-1/-2/-4 protect content-shape, AP-3/-5
  protect literal-token presence, OS-1..OS-5 protect
  orchestrator behaviour, Case-O (and Case-P) protect render
  chain. Each tier owns one surface.

**One coherence note (not a finding).** The brainstorm header
uses `## 10. Persona review` to mirror the sibling ENG-213
brainstorm's pattern (which itself mirrors ENG-203). Confirmed
spot-check of ENG-213 brainstorm at L473 — same heading idiom.

**No P0/P1 findings.**

### Persona 5 — product (PASS)

**Verdict.** PASS.

**Product surface.**

- User-visible? No. The pin asserts an internal contract on the
  render-time resolver chain; no user-observable behaviour
  changes (the failed assertion mode it detects is a regression
  in internal wiring).
- Operator-visible? Only on regression — if the bind line at
  L687 is deleted, pre-commit fails at `render-prompt-rc0-test.sh`
  with a `Case-P` named failure pointing at the expected path.
  Cleaner forensic signal than today's silent-pass.
- Pipeline behaviour? Unchanged when the pin passes (which it
  does against the current tree).

**Outcome alignment with ENG-191 deferred-majors loop.** This is
the third deferred-majors auto-created ticket from ENG-203's
iter-2 review (siblings ENG-212 and ENG-213, both brainstormed
today). Shipping the trio cleanly validates that selective-exit
+ auto-create + small-shape polish-PR cycle is sustainable. The
TESTING bucket (this ticket) closes the last category — DEFENSIVE
(ENG-212, ENG-213) + TESTING (ENG-216) = full coverage of the
deferred-majors slate from PR #175 review iter-2.

**No P0/P1 findings.**

### Persona 6 — feasibility (gating — PASS, zero P0)

**Verdict.** PASS. Zero P0 findings.

**Codebase-fact verification.** Every named artifact was checked
against current code with a `path:line` quote (§9 "Codebase-fact
verification"). All 18 assumptions in the Assumption Inventory
carry a verification status; A-14 is the only `assumed` entry
(scope-sweep permission for `bin/render-prompt-rc0-test.sh` on
implementing stage) and is named explicitly with the mechanical
verification step ("scope-sweep at tick-end and either pass or
surface a self-leak halt to fix"). A-17 is `verified-by-inspection`
(comment-reading rather than direct code-execution) and is
acceptable for the feasibility persona's evidentiary bar — the
comment names the R5 case scope explicitly.

**No phantom methods.** The new Case-P references `grep -qF`,
`mktemp`, `rm -rf`, `mkdir -p`, `tail`, `tr` — all real POSIX
utilities. The resolver chain it pins (PROMPT_RESOLVERS entry,
resolver function, main() bind, common.sh helper) is enumerated
at A-1, A-2, A-3, A-4 with verified `path:line` quotes.

**No phantom helpers.** No invented bash-helper names. No call
to `common.sh` helpers that do not exist. `ok` and `fail` are
defined locally at L27-28 of the same test file.

**No phantom CLAUDE.md sections.** "Ticket sizing rubric",
"Failure-mode quick reference", "Tests", "Language idioms",
"When wiring a new script", "Don't add features" — all real
sections of CLAUDE.md (verified spot-grep). The project-profile
addendum sections ("Build & test gates", "File layout",
"Don'ts") — all real (the addendum is appended to this very
brainstorm-stage prompt). The brainstorm cites them by quoted
phrase; no fabricated guidance.

**No phantom ADRs.** ENG-87, ENG-101, ENG-117, ENG-191, ENG-193,
ENG-203, ENG-212, ENG-213 are cited as named tickets without
quoting non-existent content. ENG-213's brainstorm is the
sibling-pattern reference and was read in full during prep;
ENG-203's brainstorm AC#1 and AP-3 plan-lines were quoted with
specific path:line references.

**No phantom file paths.** Every `bin/*` and `docs/*` path
named in the brainstorm was either Read or Grepped during prep;
no fabricated paths.

**No P0 findings.**

### Gate

5/6 PASS required; **6/6 PASS** achieved.
Feasibility P0 floor: **0 P0 findings**.
Proceeding to planning.
