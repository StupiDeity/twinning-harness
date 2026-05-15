---
linear: ENG-101
title: Prompt-side defensive-code restraint clause for implement + review agents
date: 2026-05-15
status: draft
---

# ENG-101 — Prompt-side defensive-code restraint clause for implement + review agents

## 1. Overview

The Claude Code system prompt carries the rule:

> "Don't add error handling, fallbacks, or validation for scenarios that
> can't happen. Trust internal code and framework guarantees. Only
> validate at system boundaries."

`AGENT_PROMPTS.md` does not cite or operationalise this rule today —
verified by a single-file grep at the start of this dispatch:

```
$ grep -niE 'defensive|nil-guard|try/except' AGENT_PROMPTS.md
$ # (zero matches; the only 'invariant' hit at line 1528 is unrelated
$ # state-invariant prose)
```

The dispatched implement agent (`claude -p` rendered from §3) therefore
drifts toward defensive coding (`try/except`, nil-guards, validation of
internal invariants) on every dispatch, which (a) bloats diffs,
(b) triggers reviewer pushback, (c) burns review-loop iterations, and
(d) keeps Opus 4.7 on the floor for the implement stage because Sonnet's
training pull toward defensiveness is the strongest argument for the
costlier model. ENG-101 ships the cheapest fix shape — prompt-only —
and explicitly defers the regex / Haiku-judge detective alternatives
until evidence demands them.

Scope per the Linear issue:

| Edit site | Adds |
|---|---|
| `AGENT_PROMPTS.md` §3 (Implementation Agent), inside the "Self-review before exit" block | A `**Defensive-code restraint**` self-review bullet — states the rule, gives 2–3 cross-language AVOID examples, 2–3 boundary OK examples, a boundary-path heuristic, and a "cite the boundary justification" requirement. |
| `AGENT_PROMPTS.md` §5 (Review Agent), inside the "Anti-bias pass" block | A `**Defensive-code restraint**` review check — scan added/changed code for try-blocks, nil-guards, internal-invariant validation; flag `[major]` unless the file path is a boundary OR the diff/commit explains the justification. |
| `bin/agent-prompts-content-test.sh` | Per-stage positive-marker pins so a future "cleanup" pass cannot silently strip the clauses, mirroring the ENG-97 D-8 pattern. |

**Load-bearing tradeoff.** Prompt-only enforcement is the lowest-cost
shape AND the weakest: a system-prompt rule that is not cited in the
stage prompt has demonstrably not been respected, but adding the cite
guarantees only *behavioral pull*, not *blocking enforcement*. The next
tier — a Haiku LLM-judge detective sibling to `bin/scope-check.sh` —
adds blocking enforcement at ~$0.01/dispatch and is filed as the
explicit escalation path. Picking the cheap shape first matches the
Linear issue's "Ship the cheapest shape first; escalate only on
observed misses" framing.

## 2. Goal

After ENG-101 lands:

- AC#1: `AGENT_PROMPTS.md` §3 contains a Defensive-code restraint
  clause inside the "Self-review before exit" block, with the rule
  statement + 2–3 AVOID examples + 2–3 boundary OK examples +
  boundary-path heuristic + commit-message citation requirement.
- AC#2: `AGENT_PROMPTS.md` §5 contains a Defensive-code restraint
  check inside the "Anti-bias pass" block, with the `[major]` severity
  + boundary-OR-commit-justification gate.
- AC#3: `bin/agent-prompts-content-test.sh` passes — §3 fence count
  stays exactly 2, §5 fence count stays exactly 2, no new column-0
  fences introduced, and per-stage positive-marker pins prevent silent
  removal.
- AC#4: `bin/render-prompt-test.sh` and `bin/render-prompt-rc0-test.sh`
  pass — §0/§3/§5 extract cleanly, the end-to-end `bash bin/render-prompt.sh
  <stage> ENG-X` rc-gate stays 0 for every dispatch-time stage.
- AC#5: Pre-commit hook passes (full `bin/*-test.sh` suite).

## 3. Architectural principle (which one this extends)

The harness has **no formal ADR registry** — verified: `ls docs/`
returns `architecture.md assumptions.md brainstorms/ configuration.md
cost.md demos install.md operations.md pipeline-vocabulary.md
pipeline-vocabulary.template.md plans runbooks security.md` with no
`VISION.md` and no `docs/knowledge/decisions.md`. Per CLAUDE.md the
governing constraints are CLAUDE.md, `docs/architecture.md`, and
`learned-rules/<slug>/project-profile.md`.

ENG-101 extends two implicit-but-established principles:

1. **System-prompt rules SHOULD be reinforced at the stage-prompt
   level when the system rule has observable drift.** The same shape
   is already in `AGENT_PROMPTS.md` for other system rules — secret
   handling (§0 `Secret-handling (ENG-46)`), tool allowlist & probing
   (§0 `Tool allowlist & probing (ENG-53 #11 / ENG-57)`), env-var
   prefix (§0 ENG-74). Each cites the same underlying system-prompt
   pattern that already exists at the runtime level; the stage-prompt
   citation is what made the rule actually fire across dispatches.
   ENG-101 follows that pattern for the defensive-code rule.

2. **§0 SSOT consolidation for cross-stage rules (ENG-87 review-iter-7
   M4) WHEN the rule is identical across stages.** The defensive-code
   rule is NOT identical — see D-3. Per-stage placement is correct
   here.

No existing ADR is overturned. No new ADR is proposed; per the
harness's "no formal ADR registry" status, the appropriate vehicle is
the brainstorm doc itself + the positive-marker pins in the
content-test (which is how ENG-46, ENG-53, ENG-57, ENG-74, ENG-87 all
shipped their cross-stage rules).

## 4. Decisions

Each decision has the form **D-N: \<verdict\>** + Why + rejected
alternatives. All decisions cite a concrete `path:line` in
`AGENT_PROMPTS.md` or `bin/agent-prompts-content-test.sh` or the
Linear issue.

### D-1: §3 Self-review — add a `**Defensive-code restraint**` bullet at the end of the existing list, before the "Iterate until zero P0" closing.

**Verdict.** Insert the following at `AGENT_PROMPTS.md:693-694` (after
the `**Gate commands:**` bullet, before the `- Iterate until zero P0`
closing). The bullet is a peer of the other four self-review bullets,
sharing their indentation and bold-header shape:

```
  - **Defensive-code restraint:** scan your own diff for added code
    that validates internal invariants or guards against scenarios
    that cannot occur given the rest of the change. The system prompt's
    rule applies: "Don't add error handling, fallbacks, or validation
    for scenarios that can't happen. Trust internal code and framework
    guarantees. Only validate at system boundaries."
      AVOID — internal-invariant defensiveness:
        - `try/except: pass` (or `catch (...) {}`) around code you
          control end-to-end on the call path.
        - `if x is None: return None` / `unless x.nil?` /
          `if (!x) return` on values your own code just produced.
        - `assert x is not None` followed by a fallback when the
          producer already guarantees non-nil.
      LEGITIMATE — boundary validation:
        - Parsing CLI args / env vars (user input crossing the
          process boundary).
        - Validating the shape of an HTTP request body or external API
          response.
        - Decoding bytes from a file or socket the caller does not own.
      Boundary heuristic — path-based:
        - Boundary: `controllers/`, `handlers/`, `routes/`, `api/`,
          `cli/`, `main.*` and the entrypoint binaries the profile's
          File layout names. Defensive validation here is correct.
        - Internal: `lib/`, `internal/`, `services/`, `domain/`, and
          the implementation-detail directories the profile names.
          Defensive validation here is a self-review failure.
      If you add defensive code at an internal site, cite the
      boundary justification in the commit message body (one line:
      `Defensive: <why this is a real-world reachable failure mode>`)
      OR remove the code before exit. A bullet in the self-review
      that says "added try/except for safety" without a concrete
      reachable-failure citation is a P0.
```

The closing `- Iterate until zero P0` bullet (current line 694-695)
remains unchanged and continues to apply to this new bullet.

**Why.**
- The Linear issue's `What ships` clause 1 prescribes this section
  ("§3 — add an explicit clause to the 'Self-review before exit' block")
  and enumerates exactly the four sub-parts: rule statement, 2–3 AVOID
  examples, 2–3 OK examples, boundary heuristic, commit-message
  citation requirement.
- Placement at the END of the bullet list (after Gate commands, before
  the closing iterate bullet) matches the existing block's shape: each
  prior bullet is a discrete self-review check; the closing bullet is
  the "drive to zero" instruction that applies to all checks. The new
  bullet is another discrete check, so it goes between.
- The boundary heuristic explicitly references "the profile's File
  layout" because target stacks vary — the harness target has no
  `controllers/` or `handlers/` directory (its file layout is `bin/`,
  `learned-rules/`, `launchd/`, `docs/`). The profile-aware phrasing
  preserves correctness for non-web stacks; the heuristic-by-path is
  the WEB-stack illustration that lets the agent apply the rule when
  the path conventions are conventional.
- "Cite or remove" framing prevents the rule from becoming a magic
  veto: legitimate defensive code at internal sites (e.g. parsing
  ambiguous file content the producer cannot statically guarantee)
  still has a path — explain it in the commit body.

**Rejected alternative — write the rule as a new top-level section under
§3, between Self-review and TDD evidence comment.** The Linear issue
explicitly says "add an explicit clause to the 'Self-review before exit'
block" — placement inside the block is the AC. A separate top-level
section would technically deliver the rule but creates two competing
"self-review-shaped" lists, and a future agent reading the prompt might
treat the standalone section as orthogonal-to-self-review (so neither
fires). Rejected.

**Rejected alternative — hoist the rule to §0 (Common rules) as a
shared paragraph, deleted from §3.** §0 hoisting is the ENG-87
review-iter-7 M4 pattern (stage-summary overwrite mandate, secret
handling, tool allowlist & probing) and works when the rule is
IDENTICAL across stages. The defensive-code rule is NOT identical —
§3's directive is "don't write defensive code", §5's directive is
"flag defensive code in others' diffs". Same underlying principle,
different agent action. Hoisting forces a single phrasing that serves
neither role naturally. Per-stage placement is correct. (D-3 contrasts
this with §0 examples that ARE identical across stages.)

**Rejected alternative — also add the bullet to §4 (UI Agent).** UI is
also a code-writing agent and the rule logically applies. But the
Linear issue's AC#1 names only §3. Adding §4 is scope creep that
should be filed as a follow-up ticket. See §9 OQ-1.

### D-2: §5 Anti-bias pass — add a `**Defensive-code restraint**` check between **Simplicity check** and **Scope enforcement**.

**Verdict.** Insert the following at `AGENT_PROMPTS.md:969-970`
(after the closing line of **Simplicity check**, before the
**Scope enforcement (HARD REJECT, with safety valve):** header). The
paragraph follows the same `**Header:**` + body shape as Premise
challenge, Workaround detection, Simplicity check, and Scope
enforcement:

```
**Defensive-code restraint:** scan added / changed code for try-blocks,
nil-guards, and internal-invariant validation. For each occurrence,
require ONE of:
  (a) the file path is a boundary (`controllers/`, `handlers/`,
      `routes/`, `api/`, `cli/`, `main.*`, or an entrypoint binary the
      profile's File layout names), OR
  (b) the commit message body OR the diff's surrounding context cites
      the concrete reachable-failure mode the defensive code addresses.
Otherwise flag the occurrence as `[major] <path>:<line> — defensive
code at internal site; either move the check to the boundary, justify
the failure mode in commit, or remove`. The system prompt rule the
implementer should have followed is: "Don't add error handling,
fallbacks, or validation for scenarios that can't happen. Trust internal
code and framework guarantees. Only validate at system boundaries."
Apply the same boundary heuristic the implement agent uses (path-based;
defer to the profile's File layout for non-web stacks). Idiomatic
language error handling (Go `if err != nil { return err }`, Rust `?`,
Ruby `raise`) is NOT in scope — those propagate, they do not swallow.
```

**Why.**
- The Linear issue's `What ships` clause 2 prescribes this section
  ("§5 — add a check item in the Anti-bias pass") and prescribes the
  `[major]` severity and the boundary-OR-justification gate
  literally.
- Placement between Simplicity check and Scope enforcement is
  semantically right: Simplicity check asks "could this PR be 30 %
  smaller?" and the Defensive-code check is one concrete way it could
  be smaller (drop the unneeded guards). Workaround detection is a
  different shape (workarounds vs real fixes); Scope enforcement is
  structural (file in-or-out). Adjacent to Simplicity is the natural
  grouping.
- The explicit carve-out for idiomatic propagation (Go `if err != nil
  { return err }`, Rust `?`, Ruby `raise`) prevents the reviewer from
  flagging EVERY error-propagation statement in a Go diff. Those are
  not defensive — they are the language's standard control flow. The
  carve-out is the smallest precise hedge that keeps the rule useful
  in Go/Rust-shaped diffs (the harness's project-profile machinery
  already supports both stacks via `learned-rules/<slug>/project-profile.md::## Stack`).
- `[major]` severity matches the Linear issue's literal AC. The review
  agent's decision-path (path B at lines 1018-1034) maps `major` to
  changes-requested loopback to `implementing` — exactly the
  intervention the Linear issue's "burns review-loop iterations"
  motivation calls for.

**Rejected alternative — emit `[critical]` for defensive-code
violations.** `[critical]` triggers must-fix-before-merge gating;
defensive code is a quality issue, not a correctness or security
issue. Treating it as critical would block PRs on stylistic grounds
and erode the critical-severity signal. The Linear issue specifically
says `[major]`. Rejected.

**Rejected alternative — place the check inside Workaround detection
as a sub-bullet.** Workarounds are "code that avoids the real
problem"; defensive code is "code that guards against a
non-occurring problem." Different categories; bundling them confuses
both. Rejected.

**Rejected alternative — hoist the check to §0 (Common rules) so
every stage runs it on its own diff.** Same reasoning as D-1's
rejected §0 alternative: §5's directive is to flag OTHERS' code,
§3's is to not write your own. Different rules, different agents.
The two rules also fire on different inputs (§3 reviews self-commits;
§5 reviews `gh pr diff <N>`), so the same prompt phrasing cannot serve
both. Rejected.

### D-3: `bin/agent-prompts-content-test.sh` — add positive-marker pins for §3 + §5, following the ENG-97 D-8 pattern.

**Verdict.** Add four assertions, three on §3 and one on §5:

1. §3 carries the `**Defensive-code restraint:**` bold-header marker
   (mirrors the ENG-87 M4 / ENG-77 pin pattern at lines 1082-1103 for
   the overwrite mandate — positive-marker substring grep).
2. §3 carries the AVOID example token `try/except: pass` (one example
   from the three the Linear issue requires; the others are similar
   substrings and grep-as-a-set would over-couple, so we lock the most
   distinctive token).
3. §3 carries the boundary-path token `controllers/` AND the internal-
   site token `internal/` (two tokens, AND-gated; locks the heuristic
   shape and pins both halves so a future edit cannot silently drop
   the internal-site half).
4. §5 carries the `**Defensive-code restraint:**` bold-header marker
   AND the `[major]` severity token co-occurring in the same body
   block (single grep on §5's body for the literal sequence; pins
   the severity choice from D-2 against a silent severity-downgrade).

Test names follow the existing `ENG-NNN: <description>` shape used
throughout `bin/agent-prompts-content-test.sh`. The four assertions
go after the existing ENG-82 §6 block (lines 1113-1138) so they are
co-located with similarly-shaped per-stage positive-marker pins. No
existing assertion is removed.

**Why.**
- AC#3 of the Linear issue: "`bin/agent-prompts-content-test.sh`
  passes — section fence counts remain exactly 2 (no new column-0 ```
  lines inside fenced blocks)." The fence-count assertions already
  exist at lines 264-270 (§2) and need no change. The positive-marker
  pins are the SECONDARY safeguard against silent removal — without
  them, a future "cleanup" pass that strips the new bullets would
  pass every existing assertion because none currently key on
  defensive-code content.
- The pin pattern matches ENG-97 D-8's three-part shape: invert any
  prior negative assertion + add a global negative-grep + add a
  positive marker. ENG-101 has no prior negative to invert and no
  new forbidden-token to scan, so only the positive markers apply.
- Locking distinctive substrings (the bold header + one example
  token + the boundary heuristic anchor) rather than the full
  paragraph body keeps the assertions robust to cosmetic rephrasing
  while still catching silent removal. ENG-97 A-21 explicitly chose
  marker-pinning over body-pinning for the same reason.

**Rejected alternative — pin the entire bullet body verbatim.**
Brittle: any cosmetic rephrasing (e.g. swapping `try/except: pass`
for `catch (...) {}` as the lead AVOID example) would break the
test without a real regression. Pin the marker(s) instead. Rejected
(same as ENG-97 D-8's body-pin rejection).

**Rejected alternative — only pin the `**Defensive-code restraint:**`
header in §3 and §5; no example-token pins.** Permissive: a future
edit could keep the header and gut the body to a one-line "be careful
with defensive code" while passing the test. The Linear issue's AC#1
explicitly requires the examples + heuristic; the test should pin
that those AC parts are still present. Rejected.

**Rejected alternative — fold the §3 pins under a single positive-grep
combining all three tokens (header + AVOID + heuristic).** A single
AND-gated grep is more brittle: if any one token is renamed, the test
fails without a diagnostic naming WHICH token broke. Separate
assertions (one per check) give per-token diagnostics, mirroring the
ENG-97 D-8 approach of "one assertion per token". Rejected.

### D-4: §0 hoisting — explicitly not done; rule lives per-section.

**Verdict.** Do NOT add the defensive-code rule to §0 (Common rules,
lines 212-228). Keep it per-section (§3 + §5).

**Why.**
- §0 SSOT is for rules IDENTICAL across stages. ENG-87 review-iter-7
  M4 hoisted the stage-summary overwrite mandate to §0 precisely
  because the same boilerplate had to fire in §§1-7 verbatim. The
  defensive-code rule is NOT verbatim: §3 says "don't write defensive
  code"; §5 says "flag defensive code". The agent's *action* is
  different.
- §0 hoisting also implies the rule fires in §§1-9 — but §1
  (Brainstorm), §2 (Plan), §8 (Release), §9 (Retrospective) do not
  write or review *code* in the relevant sense. A §0-shaped rule
  would either (a) need stage-conditional carve-outs (defeating the
  consolidation point) or (b) over-fire on stages where the rule is
  meaningless.
- The Linear issue's `What ships` clause 1 and 2 explicitly say §3
  and §5. Adopting §0 hoisting would diverge from AC#1+AC#2 without
  a clear win.

**Rejected alternative — hoist to §0 with stage-conditional carve-outs
(e.g. "if you are writing code, X; if you are reviewing code, Y").**
The dual-directive shape would be longer than the two per-section
clauses combined, and §0's existing rules are stage-agnostic by
design. The carve-out path defeats the purpose of §0. Rejected.

## 5. Architecture (where code goes)

Two files change:

1. **`AGENT_PROMPTS.md`** — two edit sites (D-1 and D-2). Both are
   inside-fence additions (column-4+ indented bullets, NOT new
   column-0 ``` fences). The §3 column-0 fence count stays at 2
   (608, 747); the §5 column-0 fence count stays at 2 (892, 1106).
   Verified contract at `bin/render-prompt.sh:111-112` —
   `extract_block` dies if either section's column-0 fence count is
   not exactly 2.

2. **`bin/agent-prompts-content-test.sh`** — four added assertions
   (D-3). The file is self-contained per the harness language idioms
   (per the profile's `## Language idioms` section, "Each
   `bin/foo.sh` ends with the sentinel ..."); no `source` chain is
   touched. Assertions go after line 1138 (the ENG-82 §6 block close)
   so they are co-located with similarly-shaped per-stage pins.

No other file changes. Specifically out of scope:
- `learned-rules/implementation.md` and `learned-rules/review.md` —
  per the Linear issue's "Out of scope" clause; those are
  retrospective-owned. (Confirmed: those files do not exist today
  for the harness slug — `ls learned-rules/harness/` returns only
  `build.md` and `project-profile.md`. For the harness-self target
  this brainstorm therefore does not produce a stale reference.)
- `bin/scope-check.sh` and any new detective script — Option A
  (regex) was rejected outright in the Linear issue; Option B
  (Haiku LLM-judge) is deferred to a follow-up ticket.
- `AGENT_PROMPTS.md` §4 (UI Agent), §6 (QA Agent) — see §9 OQ-1
  for the rationale to defer.
- `bin/render-prompt.sh`, `bin/dispatch.sh` — unchanged.
- The per-stage model-tiering work (Sonnet-default for implement
  with Opus escalation on rebase/loopback) — separate ticket per
  the Linear issue's "Why now" framing.

## 6. Data flow

The dispatched agent receives, in this order (verified at
`bin/render-prompt.sh:184-210` and via `bin/render-prompt-test.sh`):

1. §0 (Common rules) fenced block, prepended to every stage by
   `bin/render-prompt.sh::main` (verified at the existing test's
   case 6.1-6.5 and the rendered_stage_body helper at
   `bin/agent-prompts-content-test.sh:36-40`).
2. The stage's own fenced block (e.g. §3 Implementation) with
   `{token}` substitution applied by `resolve_block_tokens`.
3. (For non-retrospective stages only — verified at
   `bin/render-prompt.sh:187-190`) The full
   `learned-rules/<slug>/project-profile.md` appended verbatim under
   a `## Project profile (addendum)` heading.

ENG-101 changes step 2's content for §3 and §5. The agent still reads
the profile in step 3 to ground its stack assumptions. The
boundary-path heuristic in D-1 / D-2 explicitly defers to the
profile's File layout, so the rule applies correctly across web
(controllers/handlers), CLI (cli/main.*), library (lib/internal/),
and harness-shaped (bin/) stacks.

The four new test assertions in D-3 fire against `AGENT_PROMPTS.md`
content directly (via `section_body` for §3-scoped, §5-scoped, or
`rendered_stage_body` if any future iter wants the §0-prepended
shape). Per D-4 the rule does NOT live in §0, so `section_body` is
sufficient and `rendered_stage_body` is unnecessary for the new
assertions.

## 7. Error handling

The new clauses are markdown-only edits inside existing fenced blocks.
The two failure modes worth naming:

1. **Fence-count regression.** A future edit that adds a column-0 ```
   fence inside §3 or §5 trips `bin/render-prompt.sh:111-112`'s die
   AND `bin/agent-prompts-content-test.sh:264-270`'s §2-scoped pin
   (the latter is §2-only today; ENG-101 does not add equivalent
   §3/§5 pins because the global render-rc0 test at
   `bin/render-prompt-rc0-test.sh:113` covers every dispatch-time
   stage's end-to-end render). If a §3 or §5 column-0 fence
   regresses, brainstorming + reviewing renders die loudly at
   dispatch time — same backstop ENG-87 review-iter-7 C6 added.

2. **Positive-marker assertion failure.** A future "cleanup" pass that
   strips the §3 bullet trips D-3 assertion #1 (`**Defensive-code
   restraint:**` header missing). The pre-commit hook
   (`.githooks/pre-commit`) runs the full `bin/*-test.sh` suite per
   CLAUDE.md `## Tests / Pre-commit hook`, so the regression catches
   at commit time. Same shape as the ENG-77/ENG-71 overwrite-mandate
   pin at lines 1082-1103.

The clauses themselves do not introduce new runtime code paths or
new failure modes for the agent's runtime behavior. If the agent
mis-applies the rule (e.g., flags a legitimate boundary check as
defensive), the consequence is a single rejected PR — the implement
agent re-dispatches per the review-loopback path (§5 decision-path B
at lines 1018-1034) and the prompt's boundary-OR-commit-justification
clause gives a clear remediation: add the citation, push, re-review.

## 8. Edge cases

| Case | Handling |
|---|---|
| `bin/`-only stacks (the harness target itself) — no `controllers/`, `handlers/`, `lib/`, `internal/` directories exist | The boundary heuristic's "defer to the profile's File layout for non-web stacks" carve-out explicitly handles this. The harness profile's `## File layout` names `bin/`, `bin/setup-prompts/`, `learned-rules/`, `launchd/`, `docs/brainstorms/`, `docs/plans/`, `AGENT_PROMPTS.md` — none of which fit the path heuristic literally. The agent then falls back to the rule statement itself ("validate internal invariants vs system boundaries") applied to whatever the profile names as code-bearing. This is the same fallback shape ENG-97 D-7 used for the retrospective stage's path-list. |
| Go diff with idiomatic `if err != nil { return err }` propagation | D-2's explicit carve-out: "Idiomatic language error handling (Go `if err != nil { return err }`, Rust `?`, Ruby `raise`) is NOT in scope — those propagate, they do not swallow." A reviewer's grep for `try` or `catch` substrings will not trip on Go's error-return pattern; the carve-out is also explicit so the agent does not over-interpret. |
| Rust `?` operator that propagates `Result::Err` upward | Same carve-out. The `?` operator is idiomatic propagation. The defensive shape would be `match foo() { Ok(x) => x, Err(_) => return None }` where the `Err(_)` arm swallows the error without justification — that IS in scope. |
| Python `try: ... except SomeSpecificError: log(...)` where the except logs and re-raises | Re-raise is propagation, not swallowing. The pattern is not defensive. A reviewer flag here would be a false positive; the carve-out language ("they propagate, they do not swallow") covers it. If a reviewer still flags it, the implementer cites in the commit body and the next review iteration accepts. |
| Test code (`*-test.sh`, `tests/`, `*_test.go`, etc.) carrying `assert x is not None` patterns | Test assertions are not defensive code — they ARE the validation, by design. The boundary heuristic in D-1 names code-path directories, not test directories. The agent's self-review should treat test assertions as out-of-scope; if uncertain, cite in the commit body. The Linear issue does not call out test code; OQ-3 flags this for plan-stage refinement. |
| Implementer adds defensive code with a commit-body citation ("Defensive: foo() panics under concurrent map mutation") that the reviewer disagrees with | The review-loopback path (B in §5 decision-path) returns the PR with the `[major]` flag; the implementer can either remove the code or amend the citation with stronger evidence. The rule is a forcing function, not a magic veto — judgment still applies. |
| A future profile lists `controllers/` AND `handlers/` AND a custom non-web directory like `bin/` (mixed stacks) | The heuristic's "path-based … defer to the profile's File layout for non-web stacks" applies stacked: the literal `controllers/` directory triggers the web heuristic; the harness-shaped `bin/` directory triggers the profile-defer fallback. Both can coexist. |
| Defensive code at a boundary site (e.g. `controllers/foo.py` calls `parse_request_body()`) that catches a `ValueError` from the parser | Boundary check; LEGITIMATE per D-1's example list. No flag fires. |
| The implementer cites the boundary justification but the diff also adds adjacent defensive code with NO citation | The §3 self-review's "per-occurrence" framing handles this: every defensive block needs its own boundary-or-citation. The reviewer's flag fires on the uncited block, not on the cited one. |
| §3's new bullet introduces a chevron / hyphen / colon character that breaks the YAML-like rendering in the agent's view | The new bullet uses only ASCII characters that are already heavily used in the surrounding §3 prose (`-`, `:`, `*`, backticks). `bin/render-prompt-rc0-test.sh:113` exercises the full render for implementing/reviewing stages and would catch a rendering crash. |
| Linear issue's "out of scope" includes `learned-rules/implementation.md` — but adding a §3 stage prompt clause sometimes leads operators to also seed a learned-rules entry by hand | The Linear issue explicitly notes "Edits to `learned-rules/implementation.md` or `learned-rules/review.md` (retrospective-owned)" are OUT of scope. No manual seeding from this brainstorm; the retrospective agent will (if the rule needs reinforcement) propose a learned-rule entry on a future retrospective cycle. |

## 9. Open questions

| OQ | Question | Default if not resolved during planning |
|---|---|---|
| OQ-1 | Should the §3 bullet also be added to §4 (UI Agent) and any future code-writing stage? UI also writes code; the rule logically applies. AC#1 of the Linear issue names §3 only. | Defer — file a follow-up ticket ("ENG-101 follow-on: extend defensive-code restraint to §4 UI Agent"). The shape will mirror §3's bullet. ENG-101 ships §3 + §5 only. |
| OQ-2 | Should the §5 check be a sub-bullet of **Simplicity check** or a peer paragraph? D-2 chose peer paragraph for parallel structure with Premise / Workaround / Scope. A sub-bullet under Simplicity is shorter and arguably more discoverable (the cognitive group is the same). | Peer paragraph per D-2. Plan stage may reconsider if the prompt-token cost is meaningful. |
| OQ-3 | Should the rule explicitly carve out test code (`*-test.sh`, `tests/`, `*_test.go`, `*.spec.ts`)? Test assertions look like defensive code by shape but are not — they ARE the validation. The path heuristic does not list test directories. | Add a one-line carve-out at plan stage: "Test code (paths under `tests/`, `__tests__/`, `*_test.*`, `*.spec.*`) is exempt from the rule — assertions in tests ARE the validation, not defensive guards." Defer the exact wording to the plan's editing pass; the brainstorm flags this as a known refinement. |
| OQ-4 | Should D-3's test assertions follow the ENG-87 M4 `assert_overwrite_mandate` helper-function shape (one function applied per stage in a for-loop) instead of four open-coded asserts? Helper-function pattern matches `bin/agent-prompts-content-test.sh:1082-1103`. | For ENG-101 the helper-function path adds boilerplate for only two stages (§3, §5). Keep the asserts open-coded; the helper pattern is the right call when ≥3 stages share a rule. The plan can revisit if §4 is added per OQ-1. |
| OQ-5 | Should the `[major]` severity in §5 escalate to `[critical]` after N observed misses? `[major]` causes review-loopback; `[critical]` would block merge entirely. The Linear issue explicitly says `[major]` — no escalation today. | `[major]` permanently per the Linear issue AC. Severity escalation is a separate ticket. |
| OQ-6 | Should the rule mention specific language idioms beyond `try/except: pass`? D-1's three AVOID examples are TS `try {} catch` swallowing, Python `if x is None: return None`, Ruby `unless x.nil?`. The Linear issue suggests "JS `try {} catch`" and "Ruby `unless x.nil?`" — three examples is sufficient for cross-language coverage. | Three examples per D-1; covers TS/Python/Ruby and the patterns generalize to Java/Go/Rust by transparent analogy. |
| OQ-7 | Should `bin/render-prompt-test.sh` get a new case asserting the §3 and §5 renders carry the new substring? It already covers fence-count and token-resolution. Adding a content-presence pin would partially duplicate D-3's `agent-prompts-content-test.sh` assertions. | Skip — D-3's `agent-prompts-content-test.sh` pin is the canonical content-presence check. `render-prompt-test.sh`'s scope is resolver behavior, not content. Adding a content pin there crosses scopes. |
| OQ-8 | Should the boundary heuristic list also include `bin/` as a boundary path? The harness target's `bin/` directory contains both entrypoint-shaped scripts (`run-local.sh`, `setup.sh`) and library-shaped scripts (`common.sh`, `linear.sh`). | Don't hardcode `bin/`. The heuristic's "defer to the profile's File layout" clause handles this — for the harness-self target the rule applies to whatever the profile names. Listing `bin/` literally would force the harness target into web-stack semantics. |

## 10. Out of scope

- **Per-stack regex detective (Option A from the Linear issue)** — rejected
  outright in the issue: "Worst-of-both-worlds: requires per-target config
  + per-stack patterns, can't distinguish idiomatic Go/Rust error handling
  from defensive code, can't detect boundary-vs-internal context."
- **Haiku LLM-judge detective (Option B)** — explicit escalation path; file
  the follow-up Feature ticket *"Haiku LLM-judge defensive-code detective,
  sibling to scope-check.sh"* if post-ship monitoring shows the review
  agent missing defensive-code violations.
- **Per-stage model-tiering work** (Sonnet 4.6 default for implement
  with Opus 4.7 escalation on rebase/loopback) — separate ticket; the
  Linear issue explicitly names this as the downstream beneficiary
  of ENG-101 but not as in-scope.
- **`learned-rules/implementation.md` and `learned-rules/review.md` edits** —
  retrospective-owned per CLAUDE.md `## AGENT_PROMPTS.md is load-bearing`.
  The retrospective agent may propose entries on a future cycle if the
  rule needs reinforcement.
- **§4 (UI Agent), §6 (QA Agent) clauses** — see OQ-1. Defer to follow-on
  tickets if needed.
- **Adding `defensive` / `defensive-violation` to `bin/pipeline-events.json`** —
  the rule fires as a `[major]` review finding, not as a verdict marker; the
  existing review-loopback path covers it. No vocabulary change.

## 11. Assumption inventory

| # | Assumption | Status | Evidence (`path:line` or method) |
|---|---|---|---|
| A-1 | `AGENT_PROMPTS.md` §3 starts at line 606 with `## 3. Implementation Agent (Backend)` and its column-0 fences are at lines 608 and 747 (exactly 2) | **verified** | Read `AGENT_PROMPTS.md`: H2 `## 3. Implementation Agent (Backend)` at line 606; column-0 ` ``` ` fences at lines 608, 747 (via `grep -n '^```' AGENT_PROMPTS.md` output: `608:\`\`\``, `747:\`\`\``). |
| A-2 | The "Self-review before exit" block in §3 starts at line 686 and ends at line 695 with the "- Iterate until zero P0" closing | **verified** | Read `AGENT_PROMPTS.md:686-695`: `Self-review before exit (MANDATORY — drive P0 findings to zero):` at 686; bullets at 687-693 (`Premise-match`, `Contract match`, `Test-map match`, `Gate commands`); closing `- Iterate until zero P0…` at 694-695. |
| A-3 | The closing `- Iterate until zero P0` bullet in §3 applies to all preceding bullets and is the correct insertion-before-this-line anchor for D-1 | **verified** | Read `AGENT_PROMPTS.md:694-695`: "Iterate until zero P0. If you cannot, STOP, comment `<!-- meta: metric name=impl_escalate -->` with what is failing, and exit without advancing." The clause is the universal escalation, not bullet-specific. |
| A-4 | `AGENT_PROMPTS.md` §5 starts at line 890 with `## 5. Review Agent` and its column-0 fences are at lines 892 and 1106 (exactly 2) | **verified** | Read `AGENT_PROMPTS.md`: H2 `## 5. Review Agent` at line 890; column-0 ` ``` ` fences at lines 892, 1106 (via `grep -n '^```' AGENT_PROMPTS.md`: `892:\`\`\``, `1106:\`\`\``). |
| A-5 | The "Anti-bias pass" block in §5 starts at line 948 and runs through line 996, with paragraphs in the order: Premise challenge (950-959), Workaround detection (961-964), Simplicity check (966-968), Scope enforcement (970-979), Review-comment quality rubric (981-995) | **verified** | Read `AGENT_PROMPTS.md:948-996` directly; all paragraph headings and line ranges quoted above match. |
| A-6 | The "between Simplicity check and Scope enforcement" insertion point (D-2) is line 969-970 (after the closing line of Simplicity check at 968, before the Scope enforcement header at 970) | **verified** | Read `AGENT_PROMPTS.md:968-970`: line 968 closes Simplicity check ("...indirection count unjustified by the plan?"); line 969 is blank; line 970 starts `**Scope enforcement (HARD REJECT, with safety valve):**`. Insertion at line 969 keeps the blank-line spacing pattern of the surrounding paragraphs. |
| A-7 | `bin/render-prompt.sh::extract_block` dies on any section whose column-0 fence count is not exactly 2 | **verified** | Read `bin/render-prompt.sh:107-126` (the extract_block function): line 111-112 `if [[ "$fence_count" != "2" ]]; then die "AGENT_PROMPTS.md schema error: section '$section' has $fence_count column-0 fences (expected 2)..."`. (Located by grep; line numbers approximate within the function but the die-on-mismatch contract is verified literal.) |
| A-8 | `bin/agent-prompts-content-test.sh` has 1269 lines and uses the `section_body`+`ok`/`nope` pattern throughout | **verified** | `wc -l bin/agent-prompts-content-test.sh` returned `1269`; Read of lines 1-50 confirmed the `section_body` helper (lines 20-28) and the `ok`/`nope` pattern (lines 13-14). |
| A-9 | The ENG-82 §6 block in the test file is at lines 1113-1138 and is the right adjacency for the new D-3 assertions | **verified** | Read `bin/agent-prompts-content-test.sh:1113-1138`: comment `# ─── ENG-82: §6 back-fill detection clause + Decision-path D ────────` at 1113; three positive-marker pins for §6 (back-fill clause / detection command / canonical status line) at 1119-1137; `unset s6` at 1138. Pattern matches the per-stage positive-marker shape D-3 prescribes. |
| A-10 | The ENG-77/ENG-71 overwrite mandate is asserted per-stage via the `assert_overwrite_mandate` helper at lines 1082-1103 | **verified** | Read `bin/agent-prompts-content-test.sh:1082-1103`: `assert_overwrite_mandate()` function at 1082; three internal grep asserts (overwrite phrase / read-then-skip carve-out / ENG-71/77 citation); applied per-stage at lines 1105-1111 for stages 1-7. This is the "helper-function pattern" OQ-4 references. |
| A-11 | `bin/render-prompt-test.sh` is 386 lines and tests `append_project_profile` + `resolve_block_tokens` against a sandbox; it does NOT pin any content in §3 or §5 | **verified** | `wc -l bin/render-prompt-test.sh` returned `386`; Read of the full file confirmed the case-6.1 through ENG-87 R8 assertions are all about resolver behavior + addendum behavior; no `grep` against §3 or §5 content. OQ-7 defers content-pinning to D-3. |
| A-12 | `bin/render-prompt-rc0-test.sh` is 119 lines and exec()s `bash bin/render-prompt.sh <stage> ENG-X` for every dispatch-time stage (brainstorming/planning/implementing/ui/reviewing/qa/building) | **verified** | `wc -l bin/render-prompt-rc0-test.sh` returned `119`; Read of the full file confirmed: lines 91-108 `run_render()` invokes `bash "$sandbox/bin/render-prompt.sh" "$stage" ENG-87R6X`; line 113 `for stage in brainstorming planning implementing ui reviewing qa building; do run_render "$stage"; done`. This is the rc-gate AC#4 of the Linear issue maps to. |
| A-13 | `AGENT_PROMPTS.md` carries zero existing references to "defensive", "nil-guard", "try/except" (so D-1/D-2 introduce these tokens for the first time in this file) | **verified** | `grep -niE 'defensive|nil-guard|try/except|invariant' AGENT_PROMPTS.md` returned only two hits: a partial match at line 43 (omitted due to length, contextually unrelated per the surrounding §"Pipeline comment dedup convention" / §"Verdict-marker protocol" sections — these talk about marker invariants, not code invariants) and line 1528 ("invariant that prevents `stage:released` drift on un-merged issues" — also unrelated). No `defensive` / `nil-guard` / `try/except` substring exists today. |
| A-14 | The §0 (Common rules) section at `AGENT_PROMPTS.md:212-228` carries the SSOT pattern (Secret-handling, Tool allowlist & probing, env-var prefix, dispatch-id contract, stage-summary overwrite mandate) — and is the natural reference for "rules already hoisted to §0" in D-4 | **verified** | `grep -n "^## " AGENT_PROMPTS.md` confirmed `## 0. Common rules` at line 212 (and the next H2 `## 1. Brainstorm Agent` at line 232). Read of the test file's lines 51-66 confirms which phrases are pinned in §0 (Secret-handling ENG-46, Tool allowlist & probing ENG-53 #11, retry with the same sig, Do NOT prepend env-var assignments). The defensive-code rule is NOT among these and per D-4 will not join them. |
| A-15 | The harness target's `learned-rules/harness/` directory exists and contains `build.md` + `project-profile.md` but NOT `implementation.md` / `review.md` / `brainstorm.md` (so the Linear issue's "out of scope" carve-out for learned-rules edits applies cleanly — no existing file to drift against) | **verified** | `ls learned-rules/harness/` returned `build.md  project-profile.md`. The brainstorm prompt earlier flagged that `learned-rules/harness/brainstorm.md` does not exist and instructed skipping that read-step; verified directly. |
| A-16 | The brainstorm filename convention `eng-N` (case-insensitive) in the basename satisfies `partition_dirty_paths::D-004` so the doc is in-scope on the post-stage sweep | **verified** | CLAUDE.md §"Sweep + scope partition (ENG-14)" + the prompt preamble's literal text: "The `eng-101` token in the basename is load-bearing: `partition_dirty_paths::D-004` requires `eng-N` (case-insensitive) in the basename to bucket as in-scope." Filename used: `2026-05-15-eng-101-prompt-side-defensive-code-restraint-clause-for-implement-review-agents-design.md` — contains `eng-101` at the right position. |
| A-17 | The pre-commit hook (`.githooks/pre-commit`) runs the full `bin/*-test.sh` suite and `bin/agent-prompts-content-test.sh` + `bin/render-prompt-test.sh` + `bin/render-prompt-rc0-test.sh` are all in that suite | **verified** | CLAUDE.md `## Tests / Pre-commit hook`: "The repo ships a pre-commit hook at `.githooks/pre-commit` that runs the entire `bin/*-test.sh` suite (~30 s) and blocks the commit on any failure." All three test files are named `bin/*-test.sh`. AC#5 of the Linear issue is exactly this. |
| A-18 | The Linear issue's AC#3 ("section fence counts remain exactly 2 (no new column-0 ``` lines inside fenced blocks)") is enforced for §2 by `bin/agent-prompts-content-test.sh:264-270`; equivalent §3/§5 fence-count assertions do NOT exist today but the global rc0 test at `bin/render-prompt-rc0-test.sh:113` covers them end-to-end | **verified** | Read `bin/agent-prompts-content-test.sh:264-270`: `fence_count_s2="$(printf '%s\n' "$s2" | grep -c '^\`\`\`' || true)"`; the ` == "2" ` check is §2-specific. No `fence_count_s3` / `fence_count_s5` equivalent exists per `grep -n fence_count_s bin/agent-prompts-content-test.sh` (only `fence_count_s2`). The rc0 test compensates: `bin/render-prompt-rc0-test.sh:113` exec()s `bash bin/render-prompt.sh implementing ENG-X` AND `... reviewing ENG-X`, both of which would die on a column-0 fence-count regression in their respective sections per A-7. |
| A-19 | The Linear issue's AVOID example list ("`try/except: pass`, `if x is None: return None` on internal inputs, `unless x.nil?` for internally-produced values, JS `try {} catch` swallowing internal errors") is verbatim from the issue body and is the source for D-1's three AVOID examples | **verified** | Linear issue body, "What ships" clause 1, second sub-bullet: "2–3 cross-language examples of defensive patterns to AVOID adding (e.g. `try/except: pass`, `if x is None: return None` on internal inputs, `unless x.nil?` for internally-produced values, JS `try {} catch` swallowing internal errors)." D-1 selects three of these for the bullet body. |
| A-20 | The Linear issue's boundary-OK example list ("CLI arg parsing, HTTP handler input, external API responses") is verbatim from the issue and is the source for D-1's three LEGITIMATE examples | **verified** | Linear issue body, "What ships" clause 1, third sub-bullet: "2–3 examples of legitimate boundary cases that ARE correct (CLI arg parsing, HTTP handler input, external API responses)." D-1 expands these to three (CLI args / env vars, HTTP request body / external API response, decoding bytes from file/socket). |
| A-21 | The Linear issue's boundary-path heuristic ("`controllers/`, `handlers/`, `routes/`, `api/`, `cli/`, `main.*` → boundary; `lib/`, `internal/`, `services/`, `domain/` → internal") is verbatim from the issue and is the source for D-1/D-2's heuristic phrasing | **verified** | Linear issue body, "What ships" clause 1, fourth sub-bullet: "Boundary-path heuristic: `controllers/`, `handlers/`, `routes/`, `api/`, `cli/`, `main.*` → boundary; `lib/`, `internal/`, `services/`, `domain/` → internal." D-1 and D-2 quote this list literally with the profile-defer carve-out for non-web stacks. |
| A-22 | The Linear issue prescribes `[major]` severity for §5 review flags (not `[critical]`) | **verified** | Linear issue body, "What ships" clause 2, second sub-bullet: "Flag as `[major]` defensive-code violations otherwise." D-2's severity choice matches. |
| A-23 | The harness project profile's File layout names `bin/`, `bin/setup-prompts/`, `learned-rules/<slug>/`, `launchd/`, `docs/brainstorms/`, `docs/plans/`, `AGENT_PROMPTS.md` (so the "defer to profile File layout for non-web stacks" carve-out has a concrete fallback on the harness-self target) | **verified** | This dispatch's project-profile addendum, "## File layout" section, names exactly those paths. (Source-of-truth file path: `learned-rules/harness/project-profile.md` — read via the addendum-embedding mechanism documented in CLAUDE.md `## Per-target dispatch.tools extras and profile-derived tools (ENG-51, ENG-94)`.) |
| A-24 | The harness project profile's `## Don'ts` section does NOT carry any pre-existing defensive-code-related "don't" (so D-1/D-2 do not collide with an existing profile rule) | **verified** | This dispatch's project-profile addendum, "## Don'ts" section, contains rules about `mcp__plugin_linear_linear__save_issue`, column-0 fences, `STAGE_TO_SECTION`, exit-code taxonomy, `REPO_ROOT`/`PIPELINE_ROOT`, `$HARNESS_STATE_DIR` vs `$PROJECT_STATE_DIR`, `partition_dirty_paths`, and `~/.claude/projects/.../memory/`. None mention defensive coding, error handling, validation, or invariants. |
| A-25 | The Linear issue's "Escalation path" prescribes a follow-up *Feature* ticket if post-ship monitoring shows misses, and the follow-up's shape is "Haiku LLM-judge defensive-code detective, sibling to scope-check.sh, ~$0.01/dispatch, stack-agnostic" | **verified** | Linear issue body, "Escalation path" section verbatim. ENG-101 §10 mirrors this. |
| A-26 | The implementing-stage tool allowlist (per the harness profile) does NOT include any code-execution Bash patterns that would let the implement agent run arbitrary linters to detect defensive code; the rule is enforced purely via Read/Write/Edit + agent self-inspection | **verified** | This dispatch's project-profile addendum, "## Tool allowlist" / implementing section, lists `Bash(bash .githooks/pre-commit:*)`, `Bash(bash bin/secret-probe-lint.sh:*)`, and `Bash(bash bin/*-test.sh:*)` patterns enumerated literally. No `Bash(grep:*)` / `Bash(ast-grep:*)` / `Bash(rg:*)` pattern; the agent's defensive-code self-review runs via `Read`+`Grep` (implicit core tools per the profile's "Stage-agnostic core tools (Read, Write, Edit, Grep, Glob, ...) are implicit and not declared here" comment in the addendum). |
| A-27 | The §5 (Review Agent) decision-path B at `AGENT_PROMPTS.md:1018-1034` maps `[major]` findings to a `pipeline.sh event ENG-N verdict fail --target implementing` loopback (which is the intervention ENG-101's `[major]` severity is intended to trigger) | **verified** | Read `AGENT_PROMPTS.md:1018-1034`: path B's `gh pr review {pr_number} --comment` clause; the Linear consolidated review summary; `bash bin/pipeline.sh event {issue_id} verdict fail --target implementing` at 1032. The path is "any `critical` or `major` findings"; defensive-code violations at `[major]` map cleanly. |
| A-28 | The Claude Code system prompt rule the Linear issue cites ("Don't add error handling, fallbacks, or validation for scenarios that can't happen. Trust internal code and framework guarantees. Only validate at system boundaries.") is reachable to the dispatched agent because the same rule is in this dispatch's own system prompt | **verified** | This dispatch's CLAUDE.md (loaded via the claudeMd preamble at the top of the prompt) does NOT carry this rule, but the underlying system prompt (the prompt boilerplate above the user message — visible in this dispatch's preamble: "Don't add error handling, fallbacks, or validation for scenarios that can't happen. Trust internal code and framework guarantees. Only validate at system boundaries (user input, external APIs). Don't use feature flags or backwards-compatibility shims when you can just change the code.") DOES. The rule is therefore in every dispatched `claude -p` call's system prompt — adding the citation in §3/§5 is reinforcement, not duplication. |
| A-29 | The `bin/render-prompt.sh` validator does NOT specifically scan §3 or §5 content beyond the column-0 fence-count check + the `{token}` resolver coverage; any added prose in §3/§5 that respects the fence-count contract + uses no new `{token}` substring will render successfully | **verified** | Read of `bin/render-prompt-test.sh` (full file) + `bin/render-prompt-rc0-test.sh` (full file): the only content-shape checks are fence-count (via `bin/render-prompt.sh::extract_block`) and `{token}` coverage (via `PROMPT_RESOLVERS` registry). D-1 and D-2 introduce no new `{token}` substrings; the ` ``` ` substring in D-1 / D-2 is inside an example AVOID/OK block (column-4+ indented), not a column-0 fence. The rc0 test at line 113 exercises every dispatch-time stage and would catch any rendering failure. |
| A-30 | The Linear issue is filed as **Improvement** type (so the branch is `feat/eng-101-…`), NOT as **Bug** (which would be `fix/eng-101-…`) — verified by branch name | **verified** | Branch name (from git status): `feat/eng-101-prompt-side-defensive-code-restraint-clause-for-implement-review-agents`. The `feat/` prefix matches Improvement/Feature label per CLAUDE.md `## Linear conventions the harness depends on`. |

## 12. ADR stress test

The harness has no formal ADR registry (verified by A-N showing
`docs/knowledge/` does not exist). The implicit principles ENG-101
extends and the pressure each receives:

| Implicit principle | Source | Pressure from ENG-101 |
|---|---|---|
| §0 SSOT consolidation for cross-stage rules | ENG-87 review-iter-7 M4 at `bin/agent-prompts-content-test.sh:1072-1111` | D-4 explicitly declines to hoist; per-stage placement is the right call BECAUSE the rule is different across §3 and §5. No principle violated; the asymmetry is intentional. |
| Profile-as-source-of-truth | ENG-49, ENG-52, ENG-93–97 (see `docs/brainstorms/2026-05-13-eng-97-...-design.md:78-98`) | The boundary heuristic explicitly defers to the profile's File layout for non-web stacks — the rule respects the profile-as-truth principle rather than hardcoding stack conventions. ENG-101 extends, does not strain. |
| System-prompt rules SHOULD be reinforced at the stage-prompt level when observable drift exists | Recurring pattern: secret-handling (ENG-46), tool allowlist & probing (ENG-53 #11), env-var prefix (ENG-74), stage-summary overwrite mandate (ENG-77/ENG-71/ENG-87 M4) | ENG-101 is another instance of this pattern. No deviation. |
| Cheapest defensible shape first | The Linear issue's "Why prompt-only (Option C)" framing; CLAUDE.md `## Failure-mode quick reference`'s general "soft fail / escalation only on signal" approach | ENG-101 chooses Option C (prompt-only) explicitly and files Option B as escalation. Matches. |
| Tests pin distinctive markers, not full bodies | ENG-97 D-8 at `docs/brainstorms/2026-05-13-eng-97-...-design.md:370-414`; also ENG-77 / ENG-71 / ENG-82 at `bin/agent-prompts-content-test.sh:1113-1138` | D-3 follows this pattern. No deviation. |

No existing principle is overturned. The only minor pressure point is
the §0 SSOT principle (which prefers consolidation when rules are
identical) — D-4 documents why this rule is intentionally NOT
consolidated. The asymmetry between "write-side" (§3) and
"review-side" (§5) directives is the reason; future cross-stage rules
with this asymmetry (e.g. write-side commit-message conventions vs
review-side commit-log audits) should similarly NOT consolidate.

## 13. Simpler-alternative inventory

| Decision | Simpler alternative rejected | Why |
|---|---|---|
| D-1 (§3 bullet placement) | Add as new top-level §3 section between Self-review and TDD evidence comment | Linear issue's AC explicitly says "inside the Self-review block"; a standalone section would diverge from AC and risk being treated as orthogonal-to-self-review |
| D-1 (§3 bullet placement) | Hoist to §0 as shared rule | §0 SSOT is for identical-across-stages rules; defensive-code is write-side at §3, review-side at §5 — asymmetric |
| D-1 (§3 bullet placement) | Also add to §4 UI Agent | Linear AC names §3 only; defer to follow-on per OQ-1 |
| D-2 (§5 placement between Simplicity check and Scope enforcement) | Sub-bullet under Simplicity check | Less discoverable; the rule is its own check, not a sub-aspect of "could this PR be 30 % smaller" |
| D-2 (§5 placement) | Inside Workaround detection | Different category — workarounds avoid problems, defensive code guards non-occurring problems |
| D-2 (§5 severity) | `[critical]` instead of `[major]` | Erodes the critical signal; AC says `[major]` |
| D-2 (carve-out for idiomatic propagation) | No carve-out | Over-fires on every Go `if err != nil` and Rust `?`; rule becomes unusable in Go/Rust diffs |
| D-3 (positive-marker pins) | Pin the entire bullet body verbatim | Brittle to cosmetic rephrasing (ENG-97 D-8 precedent) |
| D-3 (per-token assertions) | Single AND-gated grep across all tokens | Loses per-token diagnostic on failure |
| D-3 (no helper function) | `assert_defensive_restraint` helper applied per stage | Helper pattern overhead exceeds benefit for two stages; revisit if OQ-1 adds §4 |
| D-4 (do not hoist to §0) | Hoist with stage-conditional carve-outs | Defeats §0's stage-agnostic purpose; longer than two per-section clauses combined |
| Overall (prompt-only / Option C) | Per-stack regex detective (Option A) | Rejected outright in the Linear issue: per-target config, can't distinguish idiom from defense, can't detect boundary context |
| Overall (prompt-only / Option C) | Haiku LLM-judge detective (Option B) | Deferred; file as escalation only if post-ship monitoring shows misses |

## 14. Summary

Two markdown insertions in `AGENT_PROMPTS.md` (§3 Self-review bullet
and §5 Anti-bias pass paragraph) plus four positive-marker pins in
`bin/agent-prompts-content-test.sh` operationalise a system-prompt
rule that today drives observable drift in the implement and review
stages. The rule lives per-section (§3 write-side, §5 review-side)
rather than hoisting to §0 because the two directives are
asymmetric. The boundary heuristic defers to the profile's File
layout so non-web stacks (including the harness self-target) remain
correct. Sibling escalation paths — regex detective (rejected) and
Haiku LLM-judge detective (deferred) — are documented as future
work conditioned on observed misses. The change is fenced inside
existing column-0 fence boundaries, introduces no new `{token}`
substrings, and is covered end-to-end by the pre-commit hook's
existing `bin/*-test.sh` suite plus the four added positive-marker
pins.

## Persona review

Per the brainstorm-stage Completion checklist, six personas run in
order: design → security → scope → coherence → product → feasibility.
Each persona's verdict + findings are recorded below; iteration 1
(below) is the only pass run.

### Persona 1: design — PASS

Findings:
- D-1's bullet placement (peer of `Premise-match`, `Contract match`,
  `Test-map match`, `Gate commands`; before the closing `Iterate until
  zero P0`) matches the existing block's structural pattern — each
  prior bullet is a discrete self-review check, the closing bullet is
  the universal escalation. No structural surprise.
- D-2's paragraph placement (peer of `Premise challenge`, `Workaround
  detection`, `Simplicity check`, `Scope enforcement`, `Review-comment
  quality rubric`) follows the same `**Header:**` + body shape; the
  insertion at line 969 preserves the blank-line-between-paragraphs
  spacing of the surrounding §5 body.
- D-3 follows the ENG-82 / ENG-77 / ENG-97 D-8 positive-marker pin
  pattern (`bin/agent-prompts-content-test.sh:1113-1138` and
  `:1082-1103`). Four open-coded asserts; helper-function path
  rejected for the two-stage case per OQ-4.
- D-4's decline-to-hoist call is consistent with §0 SSOT's
  identical-across-stages requirement; the asymmetry between §3 and
  §5 directives is the disqualifier, and the rationale is documented
  inline.
- Brainstorm-doc-specific gotcha: D-1 / D-2 wrap their example bullet
  bodies in column-0 ``` fences (in THIS brainstorm doc). The plan
  and implement agents reading this brainstorm need to understand
  the wrapping ``` is a markdown code-fence in the brainstorm, NOT
  literal content to add to `AGENT_PROMPTS.md`. The body INSIDE the
  fence (with its indentation) is what lands in `AGENT_PROMPTS.md`.
  ENG-97's brainstorm uses the same convention (see
  `docs/brainstorms/2026-05-13-eng-97-...-design.md:118-133`). Plan
  stage may wish to add a one-line note when transcribing.

No P0/P1 findings.

### Persona 2: security — PASS

Findings:
- No secrets touched. No env-var fallback patterns (`${VAR:-X}` /
  `${VAR:+Y}`) introduced. The new prose is markdown-only.
- No new Bash invocations or tool-allowlist patterns. The
  implementing-stage and reviewing-stage tool allowlists (per the
  profile addendum) are unchanged.
- D-3's test assertions will use `grep -qF` (literal substring) per
  the ENG-97 D-8 convention; no regex-injection or
  pattern-interpretation risk.
- The boundary-path heuristic names path strings (`controllers/`,
  `handlers/`, etc.) as prose patterns the agent uses to classify
  diff files — these are not paths the agent will write to or
  exec from. No directory-traversal vector.
- The rule itself is an *additive constraint* on agent behavior:
  it asks the agent to write *less* defensive code, not more. A
  mis-application that flags legitimate boundary checks degrades
  to a single rejected PR + commit-message citation, not to a
  bypass of any security boundary.

No P0/P1 findings.

### Persona 3: scope — PASS

Findings:
- Two files changed (`AGENT_PROMPTS.md`, `bin/agent-prompts-content-test.sh`),
  exactly matching Linear AC#1, AC#2, AC#3. AC#4 and AC#5 are
  test-suite invariants covered without file changes.
- §4 (UI Agent), §6 (QA Agent), §0 hoisting, learned-rules edits,
  regex detective (Option A), Haiku judge (Option B), per-stage
  model-tiering — all explicitly OUT of scope and named in §10.
- OQ-3's test-code carve-out is flagged as a plan-stage refinement
  rather than added as a decision. This is consistent with the
  brainstorm-vs-plan responsibility split: brainstorms flag
  refinements, plans decide them.
- D-2's idiomatic-propagation carve-out (Go `if err != nil`, Rust
  `?`, Ruby `raise`) is NOT in the Linear AC literally, but is a
  necessary clarification of AC#2's "scan added/changed code for
  try-blocks, nil-guards, internal-invariant validation". Without
  it, the §5 reviewer would flag every Go error-return line as
  defensive — making the rule unusable in Go diffs. Treated as
  "responsible interpretation of AC#2" rather than scope creep;
  the alternative would be a follow-up bug ticket within hours of
  ship.
- The boundary heuristic's profile-defer carve-out (for non-web
  stacks) is similarly a necessary clarification — without it,
  the harness self-target's `bin/`-only file layout has no
  matching heuristic at all.

No P0/P1 findings.

### Persona 4: coherence — PASS

Findings:
- §0 SSOT principle (ENG-87 review-iter-7 M4) is invoked explicitly
  in D-4 with the asymmetric-directive disqualifier. The brainstorm
  does NOT add to §0; it stays per-section. Coherent with the
  existing pattern.
- Profile-as-source-of-truth principle (ENG-49 → ENG-97) is invoked
  in the boundary heuristic's profile-defer carve-out. Coherent with
  the umbrella ENG-92 / ENG-94 / ENG-95 / ENG-96 / ENG-97 thread.
- D-3's positive-marker pin pattern mirrors ENG-82 §6 block at
  `bin/agent-prompts-content-test.sh:1113-1138` and ENG-77's
  `assert_overwrite_mandate` at lines 1082-1103. Coherent.
- The rule's *intent* (stage-prompt reinforcement of a system-prompt
  rule with observable drift) matches the existing pattern of
  ENG-46 (secret-handling), ENG-53 #11 (tool allowlist probing),
  ENG-57 (sig retry), ENG-74 (env-var prefix). All five are
  reinforcements at the stage level of rules that already exist at
  the runtime/system level; ENG-101 is the sixth.
- The Linear issue's escalation path (Haiku judge sibling to
  `bin/scope-check.sh`) is coherent with the harness's existing
  detective pattern (see `bin/scope-check.sh::is_benign` at
  ENG-96, which is profile-driven).
- No tension with sibling tickets: ENG-92 umbrella (de-Tauri / profile-as-truth)
  is orthogonal; ENG-87 dispatch-staleness umbrella is orthogonal;
  ENG-86 entry-conditions is orthogonal; ENG-81 K-2 dispatch is
  orthogonal.

No P0/P1 findings.

### Persona 5: product — PASS

Findings:
- Implement-agent outcome: smaller diffs (no try/except wrappers on
  internal call paths) → fewer review-loop iterations → shorter
  end-to-end issue cycle time. The Linear issue's "burns review-loop
  iterations" framing is the user-visible value.
- Review-agent outcome: concrete check to apply ("scan added code
  for try-blocks, nil-guards, internal-invariant validation; flag
  unless boundary-path or commit-justified") replaces fuzzy "this PR
  is too defensive" gut feeling. More deterministic review behavior
  per dispatch.
- Operator-visible outcome: enables the per-stage model-tiering
  follow-up (Sonnet for implement) by removing the strongest argument
  for keeping implement on Opus 4.7. Dispatch cost reduction is the
  downstream economic win the Linear issue's "Why now" cites.
- Prompt-token cost: ~20 lines in §3 + ~15 lines in §5 = ~35 lines
  of markdown per dispatch. On a baseline ~1870-line `AGENT_PROMPTS.md`
  that ships ~14k tokens per non-retrospective dispatch (back-of-envelope),
  the additive ~1-2% cost is negligible relative to the value.
- Risk: rule mis-fires on legitimate boundary checks → single PR
  rejection cycle. Mitigated by (a) D-1's boundary-OR-citation gate,
  (b) D-2's idiomatic-propagation carve-out, (c) the review-loopback
  path that lets the implementer cite-and-retry without operator
  involvement.
- No regressions named for any operator persona. The change is
  observably value-additive.

No P0/P1 findings.

### Persona 6: feasibility — PASS (zero P0)

Codebase-fact verification pass (the gating check). Every cited
`path:line` was verified against the current code during this
dispatch:

- **`AGENT_PROMPTS.md` H2 headings + column-0 fence locations** —
  verified via `grep -n '^## ' AGENT_PROMPTS.md` and `grep -n '^\`\`\`'
  AGENT_PROMPTS.md`. §3 H2 at line 606, fences at 608, 747. §5 H2 at
  line 890, fences at 892, 1106. Both sections have exactly 2 column-0
  fences (A-1, A-4).
- **`AGENT_PROMPTS.md:686-695` Self-review block** — Read directly;
  bullets at 687 (Premise-match), 690 (Contract match), 691-692
  (Test-map match), 693 (Gate commands), 694-695 (closing Iterate);
  D-1's insertion at line 693-694 is verified to be between Gate
  commands and the closing bullet (A-2, A-3).
- **`AGENT_PROMPTS.md:948-996` Anti-bias pass block** — Read directly;
  paragraph headings at 950 (Premise challenge), 961 (Workaround
  detection), 966 (Simplicity check), 970 (Scope enforcement), 981
  (Review-comment quality rubric); D-2's insertion at line 969 sits
  in the blank line between Simplicity check and Scope enforcement
  (A-5, A-6).
- **`bin/render-prompt.sh::extract_block` die-on-non-2-fences** —
  Grep'd directly; line 111-112:
  `if [[ "$fence_count" != "2" ]]; then die "AGENT_PROMPTS.md schema
  error: section '$section' has $fence_count column-0 fences
  (expected 2). Check for stray \`\`\` lines or a missing closing
  fence."` — exact contract verified (A-7).
- **`bin/agent-prompts-content-test.sh` structure** — Read lines 1-300
  and lines 1020-1269 directly; confirmed `section_body`/`ok`/`nope`
  helpers (lines 12-28), the ENG-82 §6 block at lines 1113-1138 (A-9),
  and the ENG-77/ENG-87 `assert_overwrite_mandate` helper at lines
  1082-1103 (A-10). 1269 total lines (A-8).
- **`bin/render-prompt-test.sh` content-scope** — Read full file
  (386 lines); verified the file tests resolver behavior + addendum
  behavior; no §3-content or §5-content pins exist today; OQ-7 defers
  content-pinning to D-3 (A-11).
- **`bin/render-prompt-rc0-test.sh` stage coverage** — Read full file
  (119 lines); line 113 iterates `brainstorming planning implementing
  ui reviewing qa building`. Every dispatch-time stage exercises the
  end-to-end render; a §3 or §5 fence-count regression dies at
  `implementing` / `reviewing` rc-check (A-12).
- **Defensive / nil-guard / try/except substrings in `AGENT_PROMPTS.md`** —
  Grep'd: zero relevant hits (one unrelated hit at line 1528 about
  state invariants). D-1/D-2 introduce these tokens for the first
  time in the file (A-13).
- **§0 SSOT contents (Secret-handling, Tool allowlist, env-var prefix)** —
  Read via `bin/agent-prompts-content-test.sh:51-66` which pins each
  phrase; verified those phrases live in §0's fenced block at
  lines 213-228 (A-14).
- **`learned-rules/harness/` directory contents** — `ls` returned
  `build.md  project-profile.md`; no `implementation.md`, no
  `review.md`, no `brainstorm.md`. The Linear issue's "out of scope"
  for learned-rules carries cleanly (A-15).
- **Brainstorm filename satisfies `partition_dirty_paths::D-004`** —
  Filename `2026-05-15-eng-101-prompt-side-defensive-code-restraint-clause-for-implement-review-agents-design.md`
  contains the `eng-101` token (case-insensitive) at the correct
  basename position (A-16).
- **Pre-commit hook test coverage** — CLAUDE.md `## Tests / Pre-commit
  hook` confirms the entire `bin/*-test.sh` suite runs on every commit;
  all three relevant test files (`agent-prompts-content-test.sh`,
  `render-prompt-test.sh`, `render-prompt-rc0-test.sh`) are in that
  suite (A-17).
- **`bin/agent-prompts-content-test.sh:264-270` §2 fence-count pin —
  §3/§5 equivalents do NOT exist** — `grep -n fence_count_s` returned
  only `fence_count_s2`. The end-to-end rc0 test compensates per A-12;
  D-3 does NOT propose adding §3/§5 fence-count pins because the rc0
  test catches the same regression class (A-18).
- **Linear AC tokens (AVOID examples, OK examples, boundary-path
  heuristic, `[major]` severity)** — Quoted verbatim from the
  Linear issue body in A-19, A-20, A-21, A-22.
- **Review-stage decision-path B (loopback on `[major]`)** — Read
  `AGENT_PROMPTS.md:1018-1034`; verified `[major]` findings invoke
  `bash bin/pipeline.sh event {issue_id} verdict fail --target
  implementing` at line 1032 (A-27).
- **System-prompt rule is reachable to the dispatched agent** —
  Verified against this dispatch's own system prompt preamble; the
  exact phrase ("Don't add error handling, fallbacks, or validation
  for scenarios that can't happen...") is in the current system
  prompt (A-28).
- **No new `{token}` substrings introduced by D-1/D-2** — The
  example bullet content uses only the existing prompt's vocabulary
  (the bullet body refers to `the profile's File layout` as prose,
  not as a `{token}`). The `PROMPT_RESOLVERS` registry is not
  touched (A-29).
- **Branch prefix matches Improvement label** — Branch name from
  git status begins `feat/eng-101-...`; CLAUDE.md `## Linear
  conventions the harness depends on` confirms `feat/` =
  Feature/Improvement, `fix/` = Bug (A-30).

Mentally-rehearsed plan-stage edit verification: D-1's bullet inserted
between lines 693 and 694, indented `  -` (2-space + dash), keeps the
§3 fenced block at exactly 2 column-0 fences (608 + 747 unchanged).
D-2's paragraph inserted at line 969, starts at column-0
(`**Defensive-code restraint:**`), follows the surrounding paragraph
shape, keeps §5's fenced block at exactly 2 column-0 fences (892 +
1106 unchanged). The `bin/render-prompt-rc0-test.sh` end-to-end check
for implementing + reviewing stages exits 0.

Zero P0 findings. Brainstorm proceeds to planning.
