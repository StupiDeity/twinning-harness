---
linear: ENG-46
title: Forbid the `${SECRET:-FALLBACK}` env-probe anti-pattern in agents and harness scripts
date: 2026-04-28
status: draft
---

# Forbid the `${SECRET:-FALLBACK}` env-probe anti-pattern

## Overview

ENG-45's UI agent self-flagged a secret-handling near-miss: it ran
`${LINEAR_API_KEY:+SET}${LINEAR_API_KEY:-UNSET}` to probe presence and printed
`SET<actual-key-value>` instead of the intended `SET`. The key did not leave
the host process — but the same pattern in any script that pipes its output
to `slack.sh`, `gh issue comment`, `tee` to a checked-in log, `set -x`-traced
output, or a `claude -p` system prompt would silently leak the value to a
durable destination.

This brainstorm proposes a forward-looking, single-PR fix: a static lint that
fails on the dangerous pattern, a one-paragraph rule in the AGENT_PROMPTS.md
preamble (read by every dispatched agent), a learned-rule entry recording the
incident, and a one-time sweep of pre-existing `:-`-form hits in the harness
itself so the lint can be turned on against a clean tree.

The fix scope deliberately stays inside what the Linear issue requests
(§ Scope Boundaries IN). It does not retrofit secret scanning across history,
rotate keys, or restructure how secrets enter agent context — those are
explicit OUT items in the issue.

## 1. Problem framing

### 1.1 The specific bug

`${VAR:-FALLBACK}` returns `$VAR`'s value when `VAR` is set non-empty, and
`FALLBACK` only when `VAR` is unset/empty. The buggy composition the ENG-45
agent reached for —

```bash
${LINEAR_API_KEY:+SET}${LINEAR_API_KEY:-UNSET}
```

— is two independent expansions concatenated. Both evaluate against the same
variable. When the variable is set, the first emits `SET` and the second emits
the **value** (because `:-UNSET` only fires when unset/empty). The result is
`SET<value>`. The author intended XOR semantics; bash gives concatenation
semantics.

### 1.2 Why this specific bug recurs

The ENG-45 occurrence did not come from any prompt or learned-rule that
teaches the pattern (verified: `grep -nE '\$\{[A-Z_]+:[\+\-]'
AGENT_PROMPTS.md learned-rules/twinning/*.md` returns no matches). The agent
synthesized it from training-data shell idioms — the
`${VAR:+SET}${VAR:-UNSET}` "presence and value" composition is a common
copy-paste in shell tutorials. So **every dispatched agent on every stage on
every issue is liable to reach for it**. Without an explicit project-side
rule, self-flagging is the only protection — which is what surfaced ENG-45,
but is not a guarantee.

### 1.3 What protects us today, what does not

What we already have (verified):

- **Secret confinement to `~/.config/twinning-harness/secrets.env`**. Loaded
  by `bin/run-local.sh:76-79` via `set -a; source "$SECRETS_FILE"; set +a`,
  also by `bin/run-retrospective-local.sh:18`. The file is `chmod 0700` on
  the directory and `0600` on the file (`bin/setup.sh:39, 282-294`). Outside
  this load path, no committed code echoes a key.
- **No prompt currently teaches the bad pattern** (§ 1.2 grep above).
- **Tool-lane fences (ENG-41).** `bin/linear.sh`'s lane fence prevents an
  agent from posting under the orchestrator's identity; lanes are
  `orchestrator | agent | classify | scope-check | human` (`AGENT_PROMPTS.md:56-87`).
  Lane fences govern *write* lanes; this issue is the same family on the
  *read* side (what the agent observes about its env, and how).

What does not protect us:

- **Prompt prose alone is insufficient.** ENG-41 documents the same lesson
  on the write side: prose-only contracts lose to agent training-data
  defaults. The fix shape that worked there — make `bin/linear.sh` enforce
  the contract structurally — has a partial analog here (the lint), and
  a remaining prose-only piece (the preamble rule) that we accept because
  the lint covers committed-code recurrence and the prose covers
  ad-hoc-in-agent-shell recurrence.
- **No CI lint exists in this repo.** There is no committed `.github/workflows/`
  step that runs `bin/dry-run.sh` against PRs, and no committed git
  pre-commit hook (`ls .github/workflows/ docs/runbooks/recovery.md`
  enumerated; no lint job today). The fix surface is therefore
  `bin/dry-run.sh` + a sibling `bin/secret-probe-lint-test.sh` — same
  pattern as the eight other `*-test.sh` files, runnable manually, in
  CI when CI exists, and via dry-run on demand. (See § Open Questions Q-1
  for the CI integration path.)

## 2. Decisions

Each decision references a load-bearing constraint from `CLAUDE.md` (the
de-facto architecture doc for this repo — `docs/VISION.md` and
`docs/architecture/SYSTEM_ARCHITECTURE.md` are placeholder template paths
that do not exist, see Assumption Inventory A-01).

### D-001 — Add a static lint script `bin/secret-probe-lint.sh` enforcing two regexes (AC literal + security-defense superset)

A new script `bin/secret-probe-lint.sh` runs `git grep -nE` against two
patterns over tracked files. The script enforces a STRICT SUPERSET of the
issue's literal regex — both `:-` and `:+` halves of the parameter
expansion are caught (justified by Iteration 2 / security finding S-P0 —
see Persona-review section):

```
\$\{[A-Z_]*(KEY|TOKEN|SECRET)[A-Z_]*:[\+\-]
\$\{(ANTHROPIC|GITHUB|LINEAR)[A-Z_]*:[\+\-]
```

The character class `[\+\-]` (matches `:+` or `:-`) is the v2 form. Exit 0
on zero hits across both regexes; exit 1 on any hit. The script prints
**three lines per hit**: (1) `path:line:matched-text`, (2) a one-line
remediation hint quoting the safe replacement, and (3) a pointer to the
preamble section (`AGENT_PROMPTS.md "Secret-handling preamble"`). Example
output:

```
bin/some-script.sh:42: echo "key=${LINEAR_API_KEY:-x}"
  hint: use ${VAR-} (single-dash, no fallback string) for presence-only checks
  see:  AGENT_PROMPTS.md "Secret-handling preamble (ENG-46)"
```

Pathspec exclusions (consolidated — these were partially scattered across
D-001 + E-6 in iteration 1; coherence-finding C-P0 fixed):

```
git grep -nE '<pat>' -- \
  ':!bin/secret-probe-lint.sh' \
  ':!bin/secret-probe-lint-test.sh' \
  ':!docs/**' \
  ':!learned-rules/**'
```

Rationale per exclusion:
- `bin/secret-probe-lint.sh` — must contain the regex string literally
- `bin/secret-probe-lint-test.sh` — fixtures contain bad-pattern strings
- `docs/**` — markdown prose; brainstorms / plans contain pattern examples
  in code blocks (this brainstorm itself does)
- `learned-rules/**` — markdown prose; the new ENG-46 entry will literally
  quote the bad pattern as a "do not write" example

A sibling `bin/secret-probe-lint-test.sh` follows the project's test pattern
(sentinel + sourceable functions per `CLAUDE.md` "How tests work") and seeds
a temp dir with both clean and dirty fixtures to assert pass/fail behavior.

**Constraint reference.** Acceptance criterion 3 ("New test runs in `bin/dry-run.sh`
and fails the pipeline if either grep finds a hit"). AC1/AC2 require zero
hits for the `:-` regexes; the v2 `:[\+\-]` regex is a strict superset, so
satisfying the lint implies satisfying AC1/AC2. And `CLAUDE.md` "Tests"
section: tests are sibling shell scripts named `*-test.sh` in `bin/`; there
is no test runner.

**Rationale.** A static lint is the only structural defense against
training-data-rooted recurrence. Prompt prose can be ignored or forgotten;
a lint that fails dispatch cannot. The `:+` half is included because the
ENG-45 surfacing bug used **both** halves of the composition
(`${KEY:+SET}${KEY:-UNSET}`) — though the leak came from the `:-` half,
a sibling pattern `${KEY:+--auth=$KEY}` (extremely common training-data
shape for "include flag if set") inlines the value via the alternate
string and would slip past a `:-`-only regex. Verified zero `:+` hits
in `bin/**` and `learned-rules/**` today (`git grep -nE '\$\{[A-Z_]+:\+'`
returns one hit in `docs/plans/...md`, which is path-excluded), so the
v2 regex adds zero false positives.

### D-002 — Wire the lint into `bin/dry-run.sh` as one `check` line

A single line is added to `bin/dry-run.sh` after the existing
`classify-failure-test` / `run-stage-test` / etc. block (around current
`bin/dry-run.sh:38-46`):

```bash
check "secret-probe-lint: no \${SECRET:-…} forms" \
  bash $HARNESS_ROOT/bin/secret-probe-lint.sh
```

**Constraint reference.** `bin/dry-run.sh` is the harness-side smoke runner
that's run by hand and (eventually) in CI. AC3 says "runs in dry-run.sh".

**Rationale.** No new orchestration surface, no new tick step, no new
breaker class. The dry-run smoke already aggregates pass/fail; a single
`check` integrates cleanly.

**Rejected alternative.** Run the lint inside `run-local.sh` on every tick.
Rejected because (a) every tick already pays a Linear-API + worktree-resolve
cost; static-content lints belong in CI / smoke, not in the per-tick
critical path; (b) running the lint at tick start would surface failures
*after* a commit landed, not at PR review time; and (c) `CLAUDE.md` "When
wiring a new script" lists `dispatch.sh::allowed_tools_for` and
`failure_outcome_for_exit` updates as the cost of a new tick step — neither
update is wanted here. (See also Q-1 for the CI add-on.)

**Rejected alternative.** Run the lint as a git pre-commit hook only.
Rejected because (a) hooks aren't checked in / installed by the harness
today; (b) a hook protects only this developer's machine, not the launchd
ticks; (c) we want CI / dry-run coverage anyway. The hook is a future
add-on, not a v1 deliverable.

### D-003 — Add a "Secret-handling preamble" section to `AGENT_PROMPTS.md`

Insert a new section between the "Stage summary comment format" preamble
section (`AGENT_PROMPTS.md:115-157`) and "## 1. Brainstorm Agent"
(`AGENT_PROMPTS.md:161`). Section body:

```
## Secret-handling preamble (ENG-46)

Never use `${VAR:-FALLBACK}` or `${VAR:+ALTERNATE}` against env vars whose
names match `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`.

- `${VAR:-FALLBACK}` returns the variable's *value* when set, not the literal
  `FALLBACK`. So `echo "${KEY:-UNSET}"` prints the actual key when set.
- `${VAR:+ALTERNATE}` returns `ALTERNATE` when VAR is set. If `ALTERNATE`
  references `$VAR` (e.g. `${KEY:+--auth=$KEY}`), the value is materialized
  via the alternate string. Both halves of the composition `${KEY:+SET}${KEY:-UNSET}`
  bite — `:-UNSET` prints the value, `:+SET` is safe alone but unsafe as a
  template into log/argv/comment context.

The canonical safe form is **single-dash, empty fallback**:

  [[ -n "${VAR-}" ]] && printf SET || printf UNSET     # presence test
  [[ -z "${VAR-}" ]]                                    # emptiness gate

Also acceptable:

  if [[ -n "${VAR-}" ]]; then echo SET; else echo UNSET; fi

The lint `bin/secret-probe-lint.sh` (run by `bin/dry-run.sh` and CI per
ENG-46 D-007) rejects any `${VAR:[+-]…}` form against the secret name set
above. Fix offending lines by switching to `${VAR-}` (single-dash) or by
restructuring the surrounding expression to avoid materializing the value.
```

**Constraint reference.** AC4 — "AGENT_PROMPTS.md contains an explicit
secret-probe rule in a place every stage reads (preamble, not per-stage)."
Also `CLAUDE.md` "AGENT_PROMPTS.md is load-bearing": "do not add column-0
``` fences inside a stage's body". This section sits in the preamble,
outside any stage's fenced block, so the per-stage fence-count contract
(`render-prompt.sh` requires exactly 2 fences per stage) is not violated.

**Rationale.** Preamble placement means every stage agent reads the rule
before the per-stage prompt that the dispatched agent runs. The
acceptance criterion is explicit about preamble, not per-stage.

### D-004 — Sweep the existing `:-` hits to compliance, picking semantically-equivalent rewrites

Two distinct rewrite groups, each enumerated explicitly. (Iteration 2:
sweep table tightened per coherence-finding C-P0 — every hit is named
once, classified once, and given a verbatim rewrite.)

**Group 1 — Test-mock fallback assignment (11 hits, "non-empty fallback" form)**

Pattern: `export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"`.
Used in tests to provide a deterministic mock value when the developer
hasn't set a real key. Semantics: assign default if VAR is unset/empty.

Verbatim rewrite (one line per file):

```
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY
```

`${VAR:=default}` assigns-default-if-unset-or-empty (POSIX 2.6.2). The
substring is `:=`, not `:-`, so the lint regex (`:[\+\-]`) does not match.
User-facing semantics identical: after the line, `$LINEAR_API_KEY` holds
either the real key or the mock.

Hit list (confirmed via `git grep -nE` in A-02):
- `bin/classify-failure-test.sh:14`
- `bin/dispatch-test.sh:16`
- `bin/halt-sprawl-adversarial-test.sh:16`
- `bin/halt-sprawl-test.sh:13`
- `bin/linear-test.sh:14`
- `bin/metrics-test.sh:19`
- `bin/poll-slot-test.sh:13`
- `bin/reconcile-test.sh:22`
- `bin/run-stage-test.sh:12`
- `bin/verdict-adversarial-test.sh:23`
- `bin/verdict-handler-test.sh:14`

(11 lines total. Iteration 1 undercounted as "9"; corrected on iteration 2.)

**Group 2 — Empty-fallback safe-presence check (4 hits, "empty fallback" form)**

Pattern: `${VAR:-}` (no fallback string between `:-` and `}`). Used inside
`[[ -z … ]]` / `[[ -n … ]]` tests to distinguish "set" from "unset/empty".

Verbatim rewrite: `${VAR:-}` → `${VAR-}` (drop the colon). For
`[[ -z … ]]` and `[[ -n … ]]` tests, single-dash and colon-dash are
identical: both return empty when VAR is unset; for VAR set to empty,
both forms also return empty (so `-z` is true in both); for VAR set
non-empty, both return the value (so `-z` is false in both). The two
forms only differ when the fallback is non-empty (e.g., `${X:-foo}` vs.
`${X-foo}`), which is irrelevant here. (Bash semantics verified — A-13.)

Hit list:
- `bin/dry-run.sh:162` — `if [[ -z "${LINEAR_API_KEY:-}" ]]; then`
- `bin/status.sh:93` — `if [[ -z "${LINEAR_API_KEY:-}" ]]; then`
- `bin/status.sh:283` — `if [[ -z "${LINEAR_API_KEY:-}" ]]; then`
- `bin/poll-slot-test.sh:80` — `[[ -n "${LINEAR_STUB_LOG:-}" ]] && …`

(`LINEAR_STUB_LOG` is a stub log path, not a secret. The lint matches
because the variable name starts with `LINEAR`. We rewrite anyway —
the rewrite is lexical, costs nothing, and avoids an in-tree allowlist
mechanism.)

**Group 3 — Lint self-reference (1 file, excluded)**

The new `bin/secret-probe-lint.sh` and its test must contain the regex
strings as text. Excluded from the lint's own scan via the pathspec list
in D-001. Not counted as a "hit".

**Total**: 11 + 4 = 15 lines rewritten across 14 distinct files. After
sweep, `git grep -nE '\$\{[A-Z_]*(KEY|TOKEN|SECRET)[A-Z_]*:[\+\-]'` and
`git grep -nE '\$\{(ANTHROPIC|GITHUB|LINEAR)[A-Z_]*:[\+\-]'` both return
zero hits (modulo the four pathspec-excluded directories). The literal
AC1/AC2 regexes (`:-` only, no `:+`) are subsets of the v2 regex; they
also return zero. AC1 and AC2 satisfied.

**Why we don't tighten the regex to `:-[^}]` to skip empty-fallback cases.**
The scope persona's iteration-1 P1 finding suggested narrowing the regex
so `${VAR:-}` (empty fallback) doesn't match — which would skip Group 2's
sweep. Rejected because (a) AC1's regex is normative — narrowing it
silently violates the contract; (b) Group 2 is 4 lines, single-character
edits, no behavior change — the sweep cost is trivial; (c) the security
persona's iteration-1 finding pushes the regex *broader* (to include
`:+`), not narrower. Holding the line at the literal AC regex (extended
to `:[\+\-]` for security defense, never tightened) is the durable
contract.

**Constraint reference.** AC1 / AC2 — "returns zero hits across the repo."
And `CLAUDE.md` "Tests" — tests use `LINEAR_API_KEY=test-mock-key` as a
mock value (the rewrite preserves this convention).

**Rationale.** Choosing semantically-equivalent rewrites (`${VAR-}` for
empty fallbacks, `${VAR:=…}` for assign-defaults) means no behavior
changes anywhere — the fix is purely lexical for the existing safe uses.
The dangerous `:-FALLBACK` form is the one we are forbidding; it does
not appear anywhere in the current tree.

**Rejected alternative.** Allowlist the test-mock-key form via a
comment marker (`# secret-probe-lint:safe`) and skip lines bearing that
comment. Rejected because (a) it adds parser complexity to the lint
without buying anything — the equivalent rewrite costs zero behavior
and zero readability; (b) every allowlist comment is a future agent's
opportunity to misuse it on a real secret; (c) the literal AC says
"zero hits", which an allowlist mechanism would technically violate
even if defensible in spirit.

### D-005 — Add the learned-rule entry to `learned-rules/twinning/brainstorm.md`

Append a new rule block to `learned-rules/twinning/brainstorm.md` — not
`ui.md`. (Iteration 2: Q-3 decided per product persona finding P-P1.)

The rule cites ENG-45 as the surfacing incident, names the bug, and lists
the safe replacement.

**Constraint reference.** AC5 — "learned-rules/twinning/<at-least-one-stage>.md
contains a one-paragraph entry naming the bug, the surfacing incident
(ENG-45), and the safe replacement."

**Rationale.** AC5 says minimum one stage. Two competing principles:

- *Surfacing stage* (UI) preserves provenance — "this rule came from a UI
  agent's mistake." This is the convention B-001 / B-002 follow.
- *Highest-read stage* (brainstorm) maximizes future-agent exposure — the
  brainstorm agent is the first dispatched on every issue, and the
  retrospective agent reads `brainstorm.md` weekly when synthesizing new
  rules. Putting the rule there means it's seen earliest in every cycle.

We pick the highest-read stage. The bug class (env-probe in shell) is
universal across stages, not specific to UI; the *surfacing* was
incidental. The provenance is recorded inside the rule body (it cites
ENG-45 explicitly), so we do not lose audit-trail fidelity by anchoring
the entry in the brainstorm file.

**Rejected alternative.** Add the same entry to all 8 stage learned-rules
files. Rejected: (a) AC5 explicitly says "at-least-one-stage" — the
brainstorm should not exceed the issue's stated boundary; (b)
8-way duplication has zero retrospective value, hurts maintainability,
and the universal-coverage need is already met by the preamble (D-003).

**Rejected alternative.** Anchor in `ui.md` (iteration-1 default). Rejected
on iteration-2 product-persona evidence: the retrospective tooling is the
primary consumer of learned-rules, and the existing rules (B-001, B-002)
already converge on `brainstorm.md` regardless of surfacing stage. The
file is the project's de-facto rules index.

**Rejected alternative.** Skip the learned-rules write entirely; rely on
the preamble. Rejected because AC5 is explicit, and the learned-rules
file is the durable audit trail (the preamble can be rewritten without
a record of the why).

### D-007 — Wire the lint into CI via `.github/workflows/secret-probe-lint.yml`

(Iteration 2: added per product persona finding P-P0. The Linear issue
says "machine-runnable on every tick and on every commit"; deferring CI
to a follow-up — as iteration 1 proposed — leaves the structural
protection un-fired on the actual recurrence vector, which is
agent-authored PRs landing through launchd ticks.)

Add a small GitHub Actions workflow that runs the lint on every PR push
and every push to `main`:

```yaml
name: secret-probe-lint
on:
  pull_request: {}
  push:
    branches: [main]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash bin/secret-probe-lint.sh
```

No secrets are referenced (the lint is static analysis). No `TARGET_REPO`
is required — the lint reads only `bin/**`, `AGENT_PROMPTS.md`, and
tracked files via `git grep`, none of which depend on `common.sh`'s
`TARGET_REPO` enforcement (the lint script itself does NOT source
`common.sh`; this is a deliberate deviation from `CLAUDE.md` "When
wiring a new script", justified because the lint is a CI tool, not a
harness operator script — see D-007 rationale below).

**Constraint reference.** Linear issue § Scope Boundaries IN: "machine-runnable
on every tick and on every commit." `bin/dry-run.sh` covers manual /
operator runs (D-002); GitHub Actions covers per-PR / per-commit runs.

**Rationale.** This is the smallest possible CI surface that satisfies
"every commit." 11 lines of YAML, no secrets, no matrix, no caching, no
custom action. The harness has zero CI workflows today, so we are not
adding to a maintenance load — we are introducing the first one, scoped
narrowly. Future workflows (e.g., a full `bin/dry-run.sh` job) can land
in their own PRs with their own scope arguments.

**Why the lint script does not source `common.sh`.** `common.sh` enforces
`TARGET_REPO` and reads `config.json` — both inappropriate in a CI lint
context that operates on the harness repo itself, with no target. The
lint is the only `bin/*.sh` script that legitimately bypasses
`common.sh`. The bypass is documented in a header comment on
`bin/secret-probe-lint.sh` and called out in the test
`bin/secret-probe-lint-test.sh`.

**Rejected alternative.** Wire the lint into `bin/run-local.sh` as a
post-sweep, pre-push step. Rejected: (a) every tick already pays
multiple Linear-API calls; static lints belong out of the tick critical
path; (b) running the lint at tick start would catch an offending line
*after* an agent commits it, not at PR review; (c) `bin/run-local.sh`
already does dirty-path partitioning (`partition_dirty_paths` in
`bin/run-local-helpers.sh`) — adding a content-of-files lint there would
muddle the responsibilities (sweep checks file *paths*; lint checks file
*contents*).

**Rejected alternative.** Pre-commit hook only. Already rejected in
D-002. Hooks aren't checked-in; CI is.

### D-006 — No retroactive sweep, no key rotation, no agent-log audit

Three things deliberately deferred or out:

- **Auditing every prior dispatched-agent log for past leaks.** Out per the
  issue's "OUT" list: "Auditing every dispatched-agent log for prior leaks.
  The forward-looking fix prevents recurrence; archaeological sweep is not
  in scope."
- **Rotating LINEAR_API_KEY because of this incident.** Out per the issue:
  "the key did not leave the host (per ENG-45 UI agent's analysis)." The
  ENG-45 evidence trail (`stage-summary-ui.md` line 17, the agent's own
  flagging) confirms confinement to the local agent process.
- **External secret scanners** (`gh secret-scanning`, trufflehog, etc.).
  Out per the issue: "Comprehensive secret scanning of every commit (use
  `gh secret-scanning` or external tools)."

**Constraint reference.** Linear issue § Scope Boundaries OUT.

**Rationale.** Each of these would more than double the PR's scope. The
forward-looking fix (D-001..D-005) closes the recurrence vector at the
cost of single-digit-line edits.

## 3. Architecture (where code goes)

```
bin/
├── secret-probe-lint.sh             (NEW — ~40 lines, pure shell + git grep,
│                                     deliberately does NOT source common.sh
│                                     so it runs in CI without TARGET_REPO)
├── secret-probe-lint-test.sh        (NEW — ~80 lines, sentinel + fixtures)
├── dry-run.sh                       (EDIT — one `check` line added; one `:-`→`-` rewrite at L162)
├── status.sh                        (EDIT — 2x `:-`→`-` rewrites at L93, L283)
├── poll-slot-test.sh                (EDIT — 2x rewrites: L13 `:-`→`:=` (test default), L80 `:-`→`-` (stub-log presence check))
├── classify-failure-test.sh         (EDIT — 1x `:-`→`:=` rewrite at L14)
├── dispatch-test.sh                 (EDIT — 1x `:-`→`:=` at L16)
├── halt-sprawl-test.sh              (EDIT — 1x `:-`→`:=` at L13)
├── halt-sprawl-adversarial-test.sh  (EDIT — 1x `:-`→`:=` at L16)
├── linear-test.sh                   (EDIT — 1x `:-`→`:=` at L14)
├── metrics-test.sh                  (EDIT — 1x `:-`→`:=` at L19)
├── reconcile-test.sh                (EDIT — 1x `:-`→`:=` at L22)
├── run-stage-test.sh                (EDIT — 1x `:-`→`:=` at L12)
├── verdict-adversarial-test.sh      (EDIT — 1x `:-`→`:=` at L23)
└── verdict-handler-test.sh          (EDIT — 1x `:-`→`:=` at L14)

AGENT_PROMPTS.md                     (EDIT — new "Secret-handling preamble" section
                                      inserted between "Stage summary comment format"
                                      and "## 1. Brainstorm Agent"; lives in the
                                      preamble, outside any stage's fenced block, so
                                      `render-prompt.sh`'s 2-fence-per-stage contract
                                      is preserved)

learned-rules/twinning/brainstorm.md (EDIT — appended one rule block, format
                                      matches B-001 / B-002 already in this file)

.github/workflows/secret-probe-lint.yml (NEW — ~11 lines, runs `bash bin/secret-probe-lint.sh`
                                         on every PR push and every push to main; first
                                         CI workflow in the harness repo)
```

Total surface:
- 2 new files in `bin/` (lint script + its test)
- 1 new file under `.github/workflows/` (the first workflow in the repo)
- 1 prompt-preamble section in `AGENT_PROMPTS.md`
- 1 learned-rule block in `learned-rules/twinning/brainstorm.md`
- 15 single-line rewrites in 13 existing files (Group 1: 11 lines, Group 2: 4 lines)

No changes to `bin/run-stage.sh`, `bin/run-local.sh`, `bin/dispatch.sh`,
`bin/scope-check.sh`, `bin/verdict-handler.sh`, `bin/classify-failure.sh`,
`bin/linear.sh`, `bin/poll.sh`, or `bin/reconcile.sh`. (AC6 — "no new
pipeline-rejection shape, no new label, no behavioral change in
run-stage.sh's scope-check or guards" — satisfied by construction.)

## 4. Data flow

The lint is static; its data flow is trivial.

```
PR opens
  └─ (future) CI runs bin/dry-run.sh
      └─ check "secret-probe-lint: …" runs bin/secret-probe-lint.sh
          └─ git grep -nE '<pattern1>' tracked files (excluding self)
          └─ git grep -nE '<pattern2>' tracked files (excluding self)
          └─ exit 0 if both empty; exit 1 otherwise
              └─ check() prints ✅/❌, increments PASS/FAIL
                  └─ summary block exits 1 if FAIL > 0

Operator runs `bash bin/dry-run.sh` manually
  └─ same path
```

There is no runtime data flow into agent context — the lint runs at
static-analysis time, before dispatch. (That is the point: stop the
dangerous pattern from ever reaching `claude -p`'s argv.)

The `compute_pipeline_content_hash()` in `bin/common.sh:71-95` covers
`bin/**/*.sh`, `config.json`, and `AGENT_PROMPTS.md`. Our edits all live
inside that set, so this PR will bump the hash. Per `bin/poll.sh:78-81`,
that means any halted issue whose `issue-state.json` records a different
prior hash will be auto-resumed on the next tick (the existing
"pipeline_content_hash or branch HEAD changed" path). This is desirable
side-effect behavior: a code change that adds a forward-looking guard
should clear unrelated halts that depend on the prior hash. No other
issue is currently halted on a state related to this lint.

## 5. Error handling

The lint has three failure surfaces:

1. **Lint hit on a real bad pattern (intended fail).** Exit 1; print
   `path:line:match`. The dry-run summary line marks ❌ and the script
   exits non-zero. CI / human reviewer fixes the offending line.
2. **Lint hit on a false positive in newly-added safe code.** Same exit
   shape. The reviewer either rewrites the line (preferred — `${VAR-}`
   single-dash form is always available) or, if there's a justified
   exception, files a follow-up to refine the regex (we do not add an
   in-tree allowlist mechanism — see D-004 rejected alternative).
3. **`git grep` failure** (e.g., not in a git repo). The lint defends
   with `git rev-parse --git-dir >/dev/null 2>&1 || die "lint requires a
   git repo"`. Calling `bin/dry-run.sh` outside a git checkout is already
   broken (see `bin/dry-run.sh:34` which globs `$HARNESS_ROOT/bin/*.sh`,
   not git-tracked); this is a defensive belt only.

The lint **does not** call `bin/linear.sh`, **does not** post comments,
**does not** apply labels, **does not** mutate state. It is read-only
filesystem analysis. (No lane-fence interaction with ENG-41.)

If the lint mis-classifies a line (false positive) and CI is offline /
not yet wired, the bad PR could still merge. Mitigation: D-002 wires the
lint into `bin/dry-run.sh`, which the harness operator runs by hand
before bumping `last-observed-release`. ENG-46 v1 does not commit a CI
workflow (Q-1).

## 6. Edge cases

**E-1. The lint script must contain the regex string.** Solved via
self-exclusion (D-001 self-reference escape). Confirmed reproducible:
`git grep -nE '<pattern>' -- ':!bin/secret-probe-lint.sh'
':!bin/secret-probe-lint-test.sh'` is the exact incantation; pathspec
`:!path` is git's exclusion form (verified —
`git help gitglossary` "magic word `exclude`").

**E-2. Variables ending in lowercase.** The regex is
`\$\{[A-Z_]*(KEY|TOKEN|SECRET)[A-Z_]*:-`, which requires uppercase. A
lowercased name (`api_key`) would not match. We do not extend the regex —
shell convention is uppercase env vars, and the bug surfaces specifically
on the env-probe class. A lowercased local would bear different concerns
(scoped to a function, less likely to inline into argv).

**E-3. Variables with mixed case or no `KEY|TOKEN|SECRET`/`ANTHROPIC|GITHUB|LINEAR`
substring.** A future provider env var (e.g., `OPENAI_API_KEY`,
`SLACK_BOT_TOKEN`, `STRIPE_SK`) is covered: `OPENAI_API_KEY` matches
pattern 1 (`*KEY*`); `SLACK_BOT_TOKEN` matches pattern 1 (`*TOKEN*`);
`STRIPE_SK` does NOT match. The issue's regex is permissive on the
`KEY|TOKEN|SECRET` axis (any uppercase substring), narrow on the
provider axis (only ANTHROPIC|GITHUB|LINEAR explicit). Adding new
provider names is a follow-up if/when those secrets enter the env;
not in this PR's scope.

**E-4. The pattern `${VAR:-}` (empty fallback, used as the safe presence
check)** matches the regex literally. Per D-004, we rewrite all such
hits to `${VAR-}` (single-dash). The literal AC1 ("zero hits") would
otherwise lose to the safe-pattern false positive. We accept the
slight idiomatic non-standardness of `${VAR-}` as the cost of strict
literal compliance; both forms are POSIX and shellcheck-clean.

**E-5. `tee`-tagged or `set -x`-traced output of any safely-rewritten
line.** Even after the rewrite, `tee` and `set -x` still print the
*expanded* value of variables in the line. This is unavoidable bash
semantics. We do not introduce a `set +x`-around-secrets discipline in
this PR — it is OUT per the issue ("Re-architecting how secrets enter
agent context … is the right shape"). The lint catches the specific
class of bug (literal pattern in source); broader shell-tracing
discipline is future work.

**E-6. Quoted heredoc content / markdown prose containing the pattern.**
This brainstorm doc, the new learned-rules entry, and any future
documentation-of-the-bug all contain literal `${KEY:-x}` strings as
worked examples. The lint must not flag prose. Resolved in D-001 by
path-excluding `docs/**` and `learned-rules/**` (both are prose, not
executable bash; lint value there is near-zero, false-positive risk is
total). The pathspec list in D-001 is the single source of truth — no
heuristic / no comment-marker / no pattern-aware logic. Plain
file-tree segregation.

**E-7. The pipeline_content_hash auto-resume.** As noted in §4, the PR
bumps the hash and resumes any halted issue with a stale hash on next
tick. This is desirable. No regression: the auto-resume path
(`bin/poll.sh:78-115`) only fires when the hash differs AND the issue
carried `pipeline:halted`; the resume just removes `pipeline:halted`
and lets the issue advance through the orchestrator's normal verdict
path. No new label, no new marker.

## 7. Rejected alternatives (consolidated)

Already detailed inline under each decision. Summary:

- **3.1 (alt to D-001)** — Rely on `gh secret-scanning` / external scanners.
  Rejected: explicit OUT in issue.
- **3.2 (alt to D-002)** — Run lint per tick instead of per-PR. Rejected:
  not the right phase, increases tick latency, no payoff.
- **3.3 (alt to D-002)** — Pre-commit hook only. Rejected: not committed by
  harness today; doesn't cover launchd ticks; CI/dry-run is the right home.
- **3.4 (alt to D-004)** — In-tree allowlist comment marker. Rejected:
  parser complexity, allowlist abuse vector, AC literal violation.
- **3.5 (alt to D-005)** — 8-way duplicate the rule across all stages.
  Rejected: AC5 says one minimum; preamble already gives universal
  coverage.
- **3.6 (alt to D-005)** — Skip learned-rules entirely. Rejected: AC5
  explicit; loses the audit trail.
- **3.7 (alt to D-006)** — Audit prior agent logs. Rejected: explicit OUT.
- **3.8 (alt to D-006)** — Rotate LINEAR_API_KEY. Rejected: explicit OUT;
  no exfiltration evidence.

## 8. ADR stress test

Does this PR put pressure on any prior accepted decision?

- **ENG-23 (env-var roots refactor — `HARNESS_ROOT` / `TARGET_REPO` /
  `HARNESS_STATE_DIR`).** No conflict. This PR does not touch root-var
  resolution.
- **ENG-14 (sweep + scope partition).** Files written by this PR all
  live in the brainstorm stage's allowlist (`docs/brainstorms/`) for
  *this* stage. The implementation stage of ENG-46 will need
  `bin/**/*.sh`, `AGENT_PROMPTS.md`, and `learned-rules/twinning/ui.md`
  in its allowlist; per `CLAUDE.md` "Sweep + scope partition", any
  out-of-allowlist write would self-leak. The plan stage should
  enumerate the allowed paths explicitly; the brainstorm flags this
  rather than handling it (plan-stage scope).
- **ENG-15 (per-issue state directory).** No conflict — no per-issue
  state added.
- **ENG-18 (verdict-marker protocol).** No conflict — no new markers,
  no new verdict shapes. The lint is silent on Linear.
- **ENG-26 (token/cost telemetry, stream-json renderer).** No conflict
  — `dispatch.sh` is unchanged. The lint is invoked from `dry-run.sh`,
  which already lives outside ENG-26's stream-json path.
- **ENG-41 (lane fences in `bin/linear.sh`).** Same family
  (read-side counterpart) but no overlap in code. The lane fence is
  about *write* lanes; this lint is about *what an agent says* in its
  shell. They cooperate without coupling.
- **ENG-42 (implement-stage PR-ownership guard reframe).** No conflict;
  ENG-42 lands in `bin/run-stage.sh`, this PR does not.
- **ENG-45.** Surfacing incident, not an ADR. Behavioral change unrelated
  (UI stage soft-precondition handling).

No accepted decision becomes harder. No proposed override.

## 9. Test strategy preview

- **Unit (`bin/secret-probe-lint-test.sh`)** — 7 cases:
  1. clean tree (a temp git repo with one safe file containing
     `${VAR-}`) → exit 0
  2. dirty tree with one bad `${LINEAR_API_KEY:-leak}` form → exit 1,
     stderr matches `path:line:match` plus the remediation hint and
     the AGENT_PROMPTS.md preamble pointer (D-001 three-line output
     contract)
  3. dirty tree with one bad `${ANTHROPIC_FOO:-x}` form (provider regex)
     → exit 1
  4. dirty tree with `${KEY:+--auth=$KEY}` (the `:+` half — security
     iteration-2 finding) → exit 1; validates `:[\+\-]` superset
  5. dirty tree with `${VAR:-}` (the empty-fallback safe form, but
     literal AC says "zero hits") → exit 1; validates the lint's
     literal contract
  6. lint-self-exclusion: place the regex string inside
     `bin/secret-probe-lint.sh` itself in the temp repo → exit 0
  7. prose-exclusion: place a bad pattern inside `docs/brainstorms/foo.md`
     and `learned-rules/twinning/foo.md` → exit 0 (pathspec excludes
     prose dirs)

- **Integration (`bin/dry-run.sh`)** — the existing dry-run pass-rate
  must remain ≥ pre-PR; the new `check` line passes against the swept
  tree; the swept-tree-as-fixture check is what validates AC1/AC2
  end-to-end.

- **CI (`.github/workflows/secret-probe-lint.yml`)** — runs the lint
  on every PR push and every push to main. No matrix, no caching, no
  secrets. First workflow in the repo; subsequent workflows can append.

- **Prompt-fence regression** — `AGENT_PROMPTS.md` keeps exactly 2
  fence delimiters per stage (the `render-prompt.sh` contract). The
  new "Secret-handling preamble" section sits *outside* any stage
  fence; verified by `bash bin/dry-run.sh` (existing
  `check "render-prompt: extracts all 9 stages"` covers this).

- **No new run-stage cases** — AC6 forbids behavioral changes in
  `run-stage.sh`; the existing test suite covers regressions.

## 10. Failure modes (preview)

| Failure mode | Severity | Test |
|---|---|---|
| Lint regex misses a real pattern (the agent's `${VAR:+SET}${VAR:-UNSET}` form) | critical (the bug we set out to prevent) | unit test case 2 (the second expansion `${VAR:-UNSET}` matches pattern 1 and fails the lint) |
| Lint false-positives on a future safe pattern | low | rewrite to `${VAR-}` is always available; no behavior change |
| AGENT_PROMPTS.md preamble breaks `render-prompt.sh` fence count | high | covered by `dry-run.sh` "extracts all 9 stages" |
| Sweep rewrite changes test-default semantics | low | unit-test files run pre-/post-sweep with identical results (same `${VAR:=test-mock-key}` semantic) |
| Lint script self-failure (recursive grep) | medium | unit test case 5 |
| pipeline_content_hash bump auto-resumes a halted issue mid-conflict | low | desirable; documented in §4 / E-7 |

## 11. Out of scope

Reproduced from issue § Scope Boundaries OUT, with our framing:

- Comprehensive secret scanning across all commits — defer to `gh
  secret-scanning` / external tooling.
- Rotating `LINEAR_API_KEY` — no exfiltration evidence; the ENG-45 agent
  self-flagged confinement to local agent process.
- Auditing prior dispatched-agent logs (`stage-summary-*.md`,
  per-stage transcripts under `$PROJECT_STATE_DIR/logs/`) for
  past leaks — forward-looking fix only.
- Re-architecting how secrets enter agent context (`bin/run-local.sh:76-79`
  `set -a; source secrets.env; set +a`). The current shape is correct;
  the file is `0700/0600` mode-restricted; the only attack surface is
  agent-emitted echoes, which this PR addresses.
- Generalizing the lint to enforce broader shell-style hygiene
  (shellcheck, set -x guards). Out of scope.
- Extending the regex to non-uppercase / non-ANTHROPIC|GITHUB|LINEAR
  provider env vars. Future, when a new provider's secret enters the
  env.

## 12. Why this also doesn't unstick or restick anything else

- ENG-26 / ENG-42 / ENG-45 — independent surfaces; no merge dependency.
  ENG-45 is the surfacing incident; its UI-stage soft-precondition
  fix is its own PR.
- The `pipeline_content_hash` bump (§4 / E-7) clears stale halts as a
  designed side effect (`bin/poll.sh:78-115`). This is the same
  mechanism that ENG-42 relies on for its post-merge unsticking.
- No coordination needed with ENG-45's `pipeline-wait` shape additions
  — `bin/dry-run.sh` accepts both edits cleanly; the issue's "Technical
  Hints" note about merge conflicts is procedural, not architectural.

---

## Assumption Inventory

Every named file, function, line range, and contract is verified against
the current tree (commit before this brainstorm: `87cc8e3`).

### Verified

- **A-01 (verified).** `docs/VISION.md` and
  `docs/architecture/SYSTEM_ARCHITECTURE.md` do **not** exist in this
  repo (`ls docs/architecture/ docs/VISION.md docs/knowledge/decisions.md
  docs/knowledge/gotchas.md` returns no matches). The brainstorm
  prompt-template assumes them; this repo's de-facto architecture doc
  is `CLAUDE.md`. Consistent with ENG-26 brainstorm § 3 preamble.
- **A-02 (verified).** Pre-PR hits to the issue's grep regexes
  (`git grep -nE` run during this brainstorm):
  ```
  bin/classify-failure-test.sh:14
  bin/dispatch-test.sh:16
  bin/dry-run.sh:162
  bin/halt-sprawl-adversarial-test.sh:16
  bin/halt-sprawl-test.sh:13
  bin/linear-test.sh:14
  bin/metrics-test.sh:19
  bin/poll-slot-test.sh:13
  bin/poll-slot-test.sh:80   (LINEAR_STUB_LOG, non-secret)
  bin/reconcile-test.sh:22
  bin/run-stage-test.sh:12
  bin/status.sh:93
  bin/status.sh:283
  bin/verdict-adversarial-test.sh:23
  bin/verdict-handler-test.sh:14
  ```
  15 hits total (the second pattern adds the `LINEAR_STUB_LOG` line on
  top of pattern 1's 14 hits). All accounted for in D-004.
- **A-03 (verified).** `AGENT_PROMPTS.md` does NOT currently contain any
  `${VAR:-…}` or `${VAR:+…}` pattern in its prose body. Verified by
  `grep -nE '\$\{[A-Z_]+:[\+\-]' AGENT_PROMPTS.md learned-rules/twinning/*.md`
  returning no matches.
- **A-04 (verified).** `bin/run-local.sh:76-79` sources `secrets.env`
  with `set -a; source ...; set +a`, exporting LINEAR_API_KEY into
  the tick process and inherited subprocesses (including `claude -p`).
  This is the upstream of the bug surface; we do not change it.
- **A-05 (verified).** `compute_pipeline_content_hash()` in
  `bin/common.sh:71-95` digests `find $HARNESS_ROOT/bin -type f -name
  '*.sh'` plus `$CONFIG` plus `$HARNESS_ROOT/AGENT_PROMPTS.md`. Edits
  to bin/**.sh and AGENT_PROMPTS.md will bump this hash.
- **A-06 (verified).** `bin/poll.sh:78-115` reads
  `prev_hash = .evidence.pipeline_content_hash` from issue-state.json
  and compares to `compute_pipeline_content_hash` output; on mismatch
  it removes `pipeline:halted` and posts a `<!-- pipeline-decision:
  resume -->` comment.
- **A-07 (verified).** `render-prompt.sh` extracts the fenced ``` block
  by stage section header and dies if the fence count is not exactly 2
  (per CLAUDE.md "AGENT_PROMPTS.md is load-bearing"). The new
  "Secret-handling preamble" section sits in the preamble, outside any
  stage's fenced block.
- **A-08 (verified).** `bin/dry-run.sh` uses a `check "label" command…`
  helper (lines 19-30) that runs the command and prints ✅/❌; failures
  increment `FAIL`; `(( FAIL > 0 )) && exit 1`. Adding one `check` line
  is the minimum-friction wire-up.
- **A-09 (verified).** `learned-rules/twinning/brainstorm.md` is the
  canonical learned-rules format reference (rules B-001, B-002 in that
  file). Format: `### Rule X-NNN: <title>` then `**Added:**`,
  `**Expires:**`, `**Last verified:**`, `**Source:**`, `**Rule:**`,
  `**Why:**`, `**Evidence:**`. We append the new entry to this file
  per D-005 (iteration 2: target file moved from `ui.md` to
  `brainstorm.md` per product-persona finding P-P1; brainstorm.md
  is the highest-read learned-rules file and the canonical rules
  index).
- **A-10 (verified).** `learned-rules/twinning/brainstorm.md` exists
  (`ls learned-rules/twinning/` lists 8 files: brainstorm.md, build.md,
  implementation.md, plan.md, qa.md, release.md, review.md, ui.md).
  Appending a new rule block does not require creating the file.
- **A-11 (verified).** `bin/linear.sh add-comment` is the append-only
  comment API per ENG-18 verdict-marker protocol
  (`AGENT_PROMPTS.md:54`). The brainstorm stage summary uses
  `add-or-update-comment` for the completion-checklist comment (per
  the dispatch wrapper) and `add-comment` for the verdict-marker comment.
- **A-12 (verified).** `bash` `${VAR:=default}` is the assign-default-if-unset-or-empty
  parameter expansion (POSIX 2.6.2, `bash(1)` Parameter Expansion). It
  modifies the variable in addition to expanding it. For non-positional
  parameters (which all our test vars are), `: "${VAR:=default}"` is the
  idiomatic way to assign without using the value. Behavior verified by
  test: `unset X; : "${X:=hi}"; printf '%s\n' "$X"` prints `hi`.
- **A-13 (verified).** `bash` `${VAR-default}` (single-dash) returns
  `default` only when VAR is unset; returns VAR's value otherwise
  (including when VAR is set to empty). For `[[ -z "..." ]]` and
  `[[ -n "..." ]]` tests with empty `default`, single-dash and
  colon-dash forms are equivalent: both return empty when VAR is unset
  or empty. Verified: `unset X; [[ -z "${X-}" ]] && echo unset` prints
  `unset`; `X=""; [[ -z "${X-}" ]] && echo empty` prints `empty`;
  same for `${X:-}`.

### Assumed (validate during implementation)

- **A-14 (assumed).** `git grep -nE '<pat>' -- ':!path'` (pathspec
  exclusion) is supported by the system git version (≥ 1.9 — released
  2014; current macOS git is well past). To validate: implementation
  agent runs `git --version` in CI and confirms ≥ 1.9. Mitigation if
  older: rewrite with `git grep | grep -v '^bin/secret-probe-lint'`.
- **A-15 (assumed).** No CI workflow currently runs `bin/dry-run.sh`
  on PR. The implementation step does not add CI; it only wires the
  lint into dry-run. CI add-on is Q-1.
- **A-16 (assumed).** No agent currently in flight is mid-stage on
  ENG-46 (no concurrent dispatch). If a tick fires during this
  brainstorm's commit, the dispatch agent uses the just-committed
  prompt — desirable, not a regression.

## Open questions

- **Q-1. RESOLVED in iteration 2 (product-persona P0).** A minimal CI
  workflow `.github/workflows/secret-probe-lint.yml` is now D-007. The
  initial deferral was wrong: the issue's "every commit" requirement is
  load-bearing — the actual recurrence vector is agent-authored PRs
  through launchd, not operator-driven dry-run runs.

- **Q-2.** Should the regex include `PASSWORD`? The issue's regex covers
  `KEY|TOKEN|SECRET` plus three explicit provider prefixes. `PASSWORD`
  is not currently used by any committed env-loading path
  (`grep -nE 'PASSWORD' bin/` returns no matches), but a future
  integration might add one. Recommendation: stay literal to AC for v1;
  follow-up if/when a `PASSWORD` env var enters the harness.

- **Q-3. RESOLVED in iteration 2 (product-persona P1).** Learned-rule
  goes into `learned-rules/twinning/brainstorm.md` (highest-read stage,
  consolidates with B-001/B-002). See D-005.

- **Q-4.** The security persona's iteration-1 finding noted that
  `${KEY:+--auth=$KEY}` (alternate string referencing the variable
  itself) is a real recurrence shape. Iteration 2 extended the lint
  regex to cover `:[\+\-]` so the OUTER `${KEY:+…}` form is caught. But
  a more elaborate dangerous shape — e.g., `printf '%s' "${KEY+x}$KEY"`
  (single-dash `+`, no value materialization in `${KEY+x}` itself, but
  followed by raw `$KEY`) — is technically not caught. Recommendation:
  do not extend the regex further in v1; the surfaced bug shape and
  its documented siblings are covered, and broader shell-hygiene
  enforcement is OUT scope (D-006). Plan stage to confirm.

- **Q-5.** The `secrets.env`-load path runs `set -a; source secrets.env;
  set +a` (`bin/run-local.sh:76-79`). If any sourced or earlier-invoked
  script leaves `set -x` enabled, the source line itself prints every
  `KEY=value` to the tick log. Today nothing turns on `set -x` in the
  harness, but a future operator debugging session might. Worth a
  one-line `set +x` before the source as belt-and-suspenders? Out of
  scope for ENG-46 (re-architecting secret loading is OUT per D-006),
  but a fast follow-up. Plan stage to confirm.

## Persona review

Durable audit trail of the six persona verdicts (design, security, scope,
coherence, product, feasibility) across the iteration loop. The Linear
stage-summary comment is the headline; this section is the record.

### Iteration 1 (initial draft)

| Persona      | Verdict | Notable findings (only those that became P0 in this iteration) |
|---|---|---|
| design       | PASS    | P1: lint failure output should include remediation hint. P1: Q-3 unresolved. P2: D-003 preamble copy structure. |
| security     | **FAIL** | P0: regex `:-` only — misses `${KEY:+...}` half (e.g. `${KEY:+--auth=$KEY}` flag-conditional shape). P1: provider list, `set -x` blast radius, threat model. |
| scope        | PASS    | P0 *finding* (verdict still PASS): D-004 over-sweeps safe code to satisfy literal AC1; consider tightening regex to `:-[^}]`. |
| coherence    | **FAIL** | P0: D-004 sweep table internally inconsistent vs. E-4. P1: D-001 pathspec exclusions split between D-001 + E-6. P2: terminology drift. |
| product      | **FAIL** | P0: lint has no operator-visible failure surface in production (Q-1's CI deferral defeats the issue's stated urgency model). P1: Q-3 underspecified. P2: ergonomics of single-dash sweep. |
| feasibility  | PASS, 0 P0 | All path:line refs verified. P1: poll-slot-test.sh listed twice in §3 architecture diagram. P2: heredoc/markdown exclusion ambiguity in E-6. |

**Iteration 1 status:** 3/6 PASS, 3 P0s. Gate fails. Iterating.

### Iteration 2 (after P0 fixes)

Iteration-2 deltas:
- D-001 regex extended from `:-` to `:[\+\-]` (security P0 fix; strict
  superset of AC1's `:-`-only regex).
- D-001 pathspec exclusions consolidated: `:!bin/secret-probe-lint.sh`,
  `:!bin/secret-probe-lint-test.sh`, `:!docs/**`, `:!learned-rules/**`
  (coherence P0 fix; E-6 simplified to point at D-001 as SoT).
- D-001 output expanded from 1 line per hit to 3 lines (path:line:match
  + remediation hint + AGENT_PROMPTS.md preamble pointer; design P1 fix).
- D-003 preamble copy expanded to address both `:-` and `:+` halves
  explicitly (security P0 reinforcement).
- D-004 sweep table restructured into Group 1 (11 hits, `:=` rewrite)
  and Group 2 (4 hits, `${VAR-}` rewrite), each enumerated once with
  verbatim rewrite; re-counted (iteration-1 had said "9" for Group 1,
  actual is 11; coherence P0 fix).
- D-005 target file moved from `learned-rules/twinning/ui.md` to
  `learned-rules/twinning/brainstorm.md` (product P1 / Q-3 resolution;
  highest-read learned-rules file, canonical rules index).
- D-007 added: `.github/workflows/secret-probe-lint.yml` runs the lint
  on every PR push and every push to `main` (product P0 fix; first CI
  workflow in the repo, scoped narrowly).
- §3 architecture diagram rewritten with explicit per-file rewrite
  counts; `poll-slot-test.sh` listed once covering both lines (feasibility
  P1 fix).
- A-09/A-10 updated to reference `brainstorm.md` instead of `ui.md`.
- Q-1 / Q-3 marked RESOLVED. Q-4 (broader regex shapes) and Q-5
  (`set -x` hygiene) added as deferred follow-ups.

| Persona      | Verdict | Notable findings (iteration 2) |
|---|---|---|
| design       | PASS (iter 1, no rerun) | P1 (remediation hint) addressed in D-001 v2; carried forward as PASS. |
| security     | PASS    | All iter-1 findings resolved. Spot-check noted `actions/checkout@v4` is pinned to major-version tag; standard practice; no `pull_request_target`; no new ReDoS risk in extended regex. |
| scope        | PASS (iter 1, no rerun) | Iter-1 P0 *finding* (narrow regex) explicitly rejected in D-004 with reasoning; verdict stands. |
| coherence    | PASS    | All iter-1 P0/P1/P2 resolved. No new contradictions introduced by iter-2 deltas. |
| product      | PASS    | All iter-1 findings resolved. D-007 satisfies "every commit"; Q-3 resolved with rationale. |
| feasibility  | PASS, 0 P0 | All iter-2 deltas reconcile with the codebase (counts, pathspec, `actions/checkout@v4`, `common.sh` bypass justification, file existence). P1 typo "(10 hits" → "(11 hits" in D-004 corrected after report. |

**Iteration 2 status:** 6/6 PASS, feasibility 0 P0. **Gate passes cleanly.**
Stopping iteration loop. Proceeding to artifact commit and stage summary.
