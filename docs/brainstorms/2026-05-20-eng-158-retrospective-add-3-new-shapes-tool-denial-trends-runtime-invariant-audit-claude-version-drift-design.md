---
linear: ENG-158
title: Retrospective — add 3 new shapes (tool-denial-trends, runtime-invariant-audit, claude-version-drift)
date: 2026-05-20
status: draft
---

# Retrospective — add three new shapes

## 1. Problem

`bin/run-retrospective-local.sh` is the weekly meta-reviewer. Its §1
("Stage failure analysis") has already been extracted as a shape under
the ENG-129 pattern (`bin/retro-shape-stage-failure-summary.sh`,
`bin/retro-prompts/stage-failure-summary.md`,
`bin/retro-shape-stage-failure-summary-test.sh`); the rest of §1-§12
still lives inline.

Today's §1 input is filtered to `events.jsonl` rows with
`outcome ∈ {failed, paused, scope-violation, …}` — i.e. STAGE HALTS only
(per `bin/retro-prompts/stage-failure-summary.md:36-42`). Three classes
of drift never enter the learning loop because they aren't halts:

1. **Tool denials the agent recovered around.** Claude's stream-json
   `type:result` event carries a `permission_denials` array
   (visible in `bin/dispatch-test.sh:554` fixture). Today
   `bin/dispatch.sh:62`'s SEC-002 explicitly DROPS this field from
   `usage-<stage>.json` (six-field allowlist). When an agent hits a
   denial, retries with a different shape, and proceeds — `events.jsonl`
   sees no row. Aggregate over a week: drift between prompt expectations
   and `--allowed-tools` reality is invisible.

2. **Runtime contract drift in the harness itself.** Three independent
   surfaces declare what an agent can read/write/invoke: (a)
   `AGENT_PROMPTS.md` per-stage bodies emit `{token}` references and
   `Bash(<x>:*)` examples; (b) `bin/dispatch.sh:515-545`
   `allowed_tools_for` declares the bash patterns per stage; (c)
   `bin/dispatch.sh:743` `--add-dir "$issue_state_dir"` and
   `bin/render-prompt.sh:41-58` `PROMPT_RESOLVERS` declare the
   filesystem paths the agent can write. These three surfaces drift
   independently — a prompt edit that adds `{some_new_path}` will silently
   `die` at render time (caught), but a prompt that instructs `bash X`
   when `X` is not in `allowed_tools_for` will produce a runtime sandbox
   denial (mostly silent — see class 1).

3. **`claude` CLI version drift.** The harness pins NO claude version
   today. A homebrew upgrade between Mondays can shift agent behavior
   (different model defaults, different sandbox semantics, different
   tool-availability) without any visible signal in the metrics stream.

The Linear ticket proposes adding three sibling shapes to the
ENG-129 pattern — one per drift class:

- **Shape A — `tool-denial-trends`**: consume
  `events.jsonl::sandbox_denial` (produced by a separate Phase-A
  sandbox-detective ticket) and bucket by `claude_version` × `stage`.
- **Shape B — `runtime-invariant-audit`**: bash-side cross-check across
  `AGENT_PROMPTS.md` / `allowed_tools_for` / `PROMPT_RESOLVERS` /
  `--add-dir` paths. No new events needed.
- **Shape C — `claude-version-drift`**: compare `claude --version`
  against a checked-in expected value (produced by a separate
  pin-claude-version ticket).

Each shape mirrors `stage-failure-summary` shape-for-shape: prompt body
at `bin/retro-prompts/<name>.md`, driver at
`bin/retro-shape-<name>.sh`, sibling test at
`bin/retro-shape-<name>-test.sh`, artifact at
`$PROJECT_STATE_DIR/retrospective-${date}/<name>.md` consumed by §9 via
a `{<name>_path}` token (handled through the
`AGENT_RUNTIME_TOKENS` allowlist in `bin/render-prompt.sh:78`).

The PoC pattern was ENG-129; this ticket adds three INSTANTIATIONS of
that pattern. Per the sizing rubric, three instantiations = three
independent design decisions (one per shape). The ticket-body sizing
note explicitly anticipates a split. §10's "Scope size & split
recommendation" addresses the split question head-on.

## 2. Decisions

### D-001. Three shapes, three drivers, three prompt bodies — one per drift class.

Each shape is a verbatim sibling of `stage-failure-summary`:

| File family                                  | Shape A (tool-denial-trends) | Shape B (runtime-invariant-audit) | Shape C (claude-version-drift) |
|---                                           |---                           |---                                |---                             |
| Prompt body                                  | `bin/retro-prompts/tool-denial-trends.md` | `bin/retro-prompts/runtime-invariant-audit.md` | `bin/retro-prompts/claude-version-drift.md` |
| Driver                                       | `bin/retro-shape-tool-denial-trends.sh` | `bin/retro-shape-runtime-invariant-audit.sh` | `bin/retro-shape-claude-version-drift.sh` |
| Sibling test                                 | `bin/retro-shape-tool-denial-trends-test.sh` | `bin/retro-shape-runtime-invariant-audit-test.sh` | `bin/retro-shape-claude-version-drift-test.sh` |
| Artifact (under `$PROJECT_STATE_DIR/retrospective-${today}/`) | `tool-denial-trends.md` | `runtime-invariant-audit.md` | `claude-version-drift.md` |
| §9 prompt token (allowlisted in `AGENT_RUNTIME_TOKENS`) | `{tool_denial_trends_path}` | `{runtime_invariant_audit_path}` | `{claude_version_drift_path}` |

*Reference to constraint:* CLAUDE.md "Retrospective shapes (ENG-129)" §
codifies the file naming and orchestration pattern. The three new shapes
fit that pattern verbatim.

*Rejected alternative — one mega-shape `metrics-drift-audit` that
covers all three drift classes:* rejected because (a) the three input
surfaces are disjoint (one consumes `events.jsonl`, one reads source
files in the harness repo, one shells out to `claude --version`) so
there is no cross-class reasoning to consolidate, (b) failure isolation
is the architectural property the shape pattern was built for; folding
back into one shape regresses ENG-129's main benefit, (c) the Linear
ticket explicitly names three.

*Rejected alternative — extend the existing `stage-failure-summary`
shape with three additional sections:* rejected for the same isolation
reason — `stage-failure-summary`'s current prompt body is a single
focused task with one schema; adding three orthogonal analyses to it
would re-create the §9 monolith problem at the shape layer.

### D-002. Shape A (`tool-denial-trends`) reads `events.jsonl` rows with `event == "sandbox_denial"`, NOT `outcome == "sandbox-denial"`.

`bin/metrics.sh:67` shows the event schema:
`{ts, event, issue_id, stage, outcome, duration_ms, notes, ...}`.
The schema has BOTH an `event` field (the row type) and an `outcome`
field (the verdict for that row type). Today's `stage-failure-summary`
shape filters on `outcome` (per
`bin/retro-prompts/stage-failure-summary.md:36-42`); that's correct for
halt-class data which lives in `stage-end` rows.

The sandbox-detective Phase A dependency (see §3 Dependencies) is
expected to emit a NEW event type — `event=="sandbox_denial"` — one
row per `permission_denials[]` entry parsed from the dispatch's
stream-json `type:result`. Each row carries `stage`, `issue_id`,
`notes` (denial pattern), and a NEW `model` field (already present in
the metrics schema since ENG-103 / `bin/metrics.sh:73`). The shape filters
by event type, not outcome.

The dependency contract: Shape A specifies the JQ selector it expects
to apply. If the Phase-A ticket lands with a different shape (e.g. it
buries denial info inside an existing event's `notes` field), the
shape's prompt body's `## Insufficient-sample carve-out` clause emits
"no rows" and the §9 prompt sees an empty artifact. Failure is bounded
(per D-007).

*Reference to constraint:* `bin/retro-prompts/stage-failure-summary.md:36-42`
proves the prompt-side filter shape. CLAUDE.md "When wiring a new script"
§ says "metric writes go through `bin/metrics.sh`" — Shape A is
read-side only; no writes.

*Rejected alternative — Shape A re-parses the raw `.cmd-capture-*.ndjson.tmp`
files post-hoc rather than depending on Phase A:* rejected because
(a) those files are `RETURN`-trap-deleted (`bin/dispatch.sh:79`), so they
don't survive into retrospective time; (b) re-implementing the parser
inside the shape would couple Shape A to the stream-json format,
violating "Phase A owns the parse" boundary; (c) the dependency makes
Shape A a SIMPLER consumer.

### D-003. Shape A buckets by `claude_version × stage`, NOT by `model × stage`.

The ticket body says "buckets by `claude_version` × `stage`". The
`model` field in `events.jsonl` is the Anthropic model ID (e.g.
`claude-opus-4-7`), not the CLI version (e.g. `1.2.345`). These are
distinct: the CLI version is what `claude --version` prints; the model
is what the dispatch resolved per ENG-103.

For Shape A to bucket by `claude_version`, the sandbox-detective ticket
MUST emit `claude_version` as a field on each `sandbox_denial` row.
This is a constraint on Phase A that the brainstorm flags explicitly.
If Phase A omits `claude_version`, Shape A's prompt body MUST treat
that as `claude_version="unknown"` and emit a single bucket — the §9
artifact remains useful at coarser granularity.

The model-only fallback (bucket by `model × stage`) is a P2 carve-out
documented in the shape's prompt body (per §6 Edge case 4).

*Reference to constraint:* the ticket body's explicit phrasing — "buckets
by `claude_version` × `stage`". Ticket intent takes precedence over
"the existing event schema's nearest field".

*Rejected alternative — bucket by `model` to avoid the Phase-A
constraint:* rejected because (a) `model` is a poor proxy for CLI
behavior — a CLI bug in a `claude --version 1.2.345` upgrade that
breaks sandbox parsing would not show up as a model shift; (b) Shape C
already exists to catch CLI drift, so Shape A's CLI-aware bucketing
gives a join key between A and C in retrospective analysis.

### D-004. Shape B (`runtime-invariant-audit`) does bash-side gathering + claude-side reasoning, NOT a pure bash diff.

Shape B cross-checks three surfaces (`AGENT_PROMPTS.md` token usage,
`bin/dispatch.sh::allowed_tools_for` patterns, `--add-dir` paths,
`PROMPT_RESOLVERS` registry). A purely mechanical bash diff is possible
— extract tokens with `grep -oE '\{[a-z_]+\}'`, extract allow-listed
patterns with `awk` against the `allowed_tools_for` case statement,
diff the sets, exit non-zero on mismatch.

The shape chooses the same orchestration as `stage-failure-summary`:
**driver gathers + renders prompt; dispatch claude as the reasoner.**
The driver does NO diffing — it produces the inputs in three text
blocks (the AGENT_PROMPTS.md tokens used, the `allowed_tools_for` per
stage, the `PROMPT_RESOLVERS` registry) and interpolates them into the
prompt body. The prompt body asks the agent to identify drift AND
characterise each drift (is the unused token an unfinished migration,
or a typo; is the unused `--allowed-tools` pattern legacy or
forward-looking).

Rationale: each surface drift has CONTEXT that a pure diff cannot
provide. A token referenced in a prompt body but absent from
`PROMPT_RESOLVERS` could be (a) a typo, (b) an intentional
literal-string mention (e.g. inside a `<!-- meta: dedup -->` example),
or (c) an unfinished migration where the resolver will land in a sibling
ticket. The agent can read the surrounding text and characterise; bash
cannot.

*Reference to constraint:* CLAUDE.md "Defense-in-depth: when a stage's
contract says... prefer a transcript-based assertion" — the *retrospective*
context inverts this: we're past the dispatch, looking for class-of-bug
patterns rather than enforcing a per-dispatch invariant. Cf. ENG-125 RCA
("the retrospective is the structural counter-weight that was missing").
Reasoning depth > mechanical diff here.

*Rejected alternative — pure bash diff in the driver; no claude
invocation:* rejected because (a) loses the contextual characterisation,
(b) the operator skim would mix true positives with false positives
indistinguishably, (c) the unified shape envelope (driver → dispatch →
artifact → §9 consumer) is the architectural property; ad-hoc pure-bash
drivers would fragment the pattern. CALLED OUT as the simpler alternative
for OQ-2 — if the agent's characterisation is shown to add noise rather
than signal post-ship, fall back to pure bash.

*Rejected alternative — write a real bash unit test that asserts no
drift between the three surfaces (instead of a retrospective shape):*
rejected because (a) the cross-check is heuristic (some token uses are
intentional non-resolver literals), and unit tests want determinism; (b)
the unit test would block PRs on every benign drift; the retrospective
shape surfaces drift for human review on a slower cadence which is the
right ergonomic.

### D-005. Shape C (`claude-version-drift`) reads a checked-in `.pipeline-config/expected-claude-version` (or equivalent) produced by the pin-claude-version dependency ticket.

The exact filename and location of the expected-version source is
NOT decided here — it's owned by the pin-claude-version ticket. Shape C
takes a path as an argument from the parent
`run-retrospective-local.sh` and checks ONLY two things:

1. The file exists and is readable.
2. The file's content matches `claude --version`'s output.

If the file doesn't exist (the dependency hasn't shipped), the shape's
prompt body emits "expected-version file not found at <path>; skipping
drift check (pin-claude-version dependency not yet wired)" and exits 0.
This is symmetrical with Shape A's empty-rows carve-out.

The shape's artifact records:
- The observed `claude --version` value.
- The expected value (or `<unknown>` if the file is absent).
- Drift status: `match` | `drift` | `dependency-not-wired`.
- If drift: include the previous value (cached from prior retrospective)
  and the new value, so §9 can summarise the upgrade.

*Reference to constraint:* the Linear ticket body — "compares `claude
--version` against the checked-in expected value (see 'pin claude CLI
version' ticket)". Phase A symmetry (D-002): the dependency contract is
that the consuming shape degrades gracefully if the producer hasn't
shipped.

*Rejected alternative — Shape C pins the version itself by reading
`.pipeline-config/...` and PR-amending it on drift:* rejected because
(a) auto-amending the pin defeats the point — the whole purpose is to
SURFACE drift for human review; (b) the pin-claude-version ticket
explicitly owns the pin file's authorship/update workflow; Shape C
should observe, not write.

### D-006. The three new shapes are invoked sequentially from `run-retrospective-local.sh::main`, before the §9 dispatch and after the existing `stage-failure-summary` invocation. Failure semantics differ per shape.

Sequence (extends today's `bin/run-retrospective-local.sh:79-101`
block):

```
run-retrospective-local.sh::main()
  …
  1. retro-shape-stage-failure-summary.sh  (existing, ENG-129)
  2. retro-shape-tool-denial-trends.sh     (NEW — Shape A)
  3. retro-shape-runtime-invariant-audit.sh (NEW — Shape B)
  4. retro-shape-claude-version-drift.sh   (NEW — Shape C)
  …
  5. extract §9 fenced block from AGENT_PROMPTS.md
  6. sed-substitute four {…_path} tokens into the rendered prompt
  7. dispatch.sh retrospective <rendered> <log>
```

Failure semantics — DIFFERENT from `stage-failure-summary` (which halts
the retrospective per ENG-129 D-006):

| Shape                    | Failure mode                                  | Parent reaction |
|---                       |---                                            |---              |
| stage-failure-summary    | Driver returns non-zero                       | **Halt** (existing) |
| tool-denial-trends       | Driver returns non-zero / artifact missing    | **Soft-degrade**: artifact set to literal "Shape A failed: <reason>"; §9 still runs |
| runtime-invariant-audit  | Driver returns non-zero / artifact missing    | **Soft-degrade**: same as above |
| claude-version-drift     | Driver returns non-zero / artifact missing    | **Soft-degrade**: same as above |

Why the asymmetry: `stage-failure-summary` is BYTE-IDENTICAL the
content of §1 today; absent it, the retrospective PR's §1 section is
empty, which is a regression vs the monolith. The three new shapes
ADD coverage that didn't exist before — partial coverage > no coverage.
A Shape-A driver crash should NOT block the retrospective; the
operator inspects the soft-degrade marker next Monday.

*Reference to constraint:* CLAUDE.md "Don't ship half-finished
implementations" — the soft-degrade path is COMPLETE, not half-finished:
the parent retrospective gets a deterministic artifact (either real
content or a documented failure marker), and the §9 prompt body handles
both cases.

*Rejected alternative — all four shapes halt-on-failure like
stage-failure-summary:* rejected because (a) breaks the "ADD coverage"
property, (b) makes the retrospective fragile to dependencies (a
sandbox-detective bug could halt every Monday's retrospective forever),
(c) the operator-visible Slack alert pattern is "retrospective
failed" — too coarse for "one new shape misbehaved". Soft-degrade with
a Slack `info` per-shape is the right granularity.

*Rejected alternative — all four shapes soft-degrade including
stage-failure-summary (consistency):* rejected because §1 is verbatim
the monolith's §1 — a soft-degrade there would silently regress today's
retrospective content. Preserve existing halt semantics for the
already-shipped shape.

### D-007. Tokens are registered in `bin/render-prompt.sh:78`'s `AGENT_RUNTIME_TOKENS` allowlist, NOT `PROMPT_RESOLVERS`.

`bin/render-prompt.sh:41-58` `PROMPT_RESOLVERS` is the per-issue dispatch
resolver registry. Retrospective `{…_path}` tokens are NOT per-issue;
they're per-retrospective-run, and they're substituted by
`run-retrospective-local.sh` directly via `sed -i.bak` (per
`bin/run-retrospective-local.sh:113-116`).

`bin/render-prompt.sh:78` shows `AGENT_RUNTIME_TOKENS`:

```
AGENT_RUNTIME_TOKENS=' file pr_number stage_failure_summary_path '
```

This is the allowlist of `{token}` names that the residual-unknown-token
validator in `render-prompt.sh` IGNORES (because they're filled in at
runtime by some external mechanism). The existing entry
`stage_failure_summary_path` was added for ENG-129. ENG-158 extends the
list to:

```
AGENT_RUNTIME_TOKENS=' file pr_number stage_failure_summary_path tool_denial_trends_path runtime_invariant_audit_path claude_version_drift_path '
```

The string is space-padded on both ends so `[[ "$AGENT_RUNTIME_TOKENS"
== *" $name "* ]]` substring tests are unambiguous (per the existing
comment at `bin/render-prompt.sh:74-77`). Adding tokens to this list is
the FULL extent of `render-prompt.sh` changes — no new resolver
functions, no `PROMPT_RESOLVERS` entries.

*Reference to constraint:* CLAUDE.md "AGENT_PROMPTS.md is load-bearing"
+ `bin/render-prompt.sh:67-78` comment ("AGENT_RUNTIME_TOKENS — names
the registry does NOT resolve at render time because the agent fills
them in at runtime"). The four `{…_path}` tokens are runtime tokens,
not render-time tokens.

*Rejected alternative — add `{tool_denial_trends_path}` etc. to
`PROMPT_RESOLVERS` with per-issue resolver functions returning a hard
error like "this token is retrospective-only":* rejected because the
issue dispatches don't reach §9; the resolver functions would be dead
code. Cleaner to use the runtime-token allowlist that exists exactly
for this case.

### D-008. Shape B and Shape C drivers route through `dispatch.sh retrospective` even though Shape C's analysis is two-string-comparisons.

ENG-129 D-004 established the principle: "shape's claude invocation is
structurally a dispatch — route it through `dispatch.sh`." This
preserves ENG-26 cost capture, ENG-65 timeout, ENG-81 mutex
acquisition, the ENG-48 isolation flags. Re-implementing any of this
in a shape driver duplicates code.

Shape B's analysis is partly mechanical, partly judgmental (D-004) —
clear win for claude.

Shape C's analysis is two-string-comparisons. Routing through
`dispatch.sh retrospective` for two-line literal compare looks wasteful
but is the consistent pattern. The shape's prompt body is short
(~30 lines) and the dispatch is read-only; cost will be cents per week.
The alternative — Shape C calls `claude --version` from bash, computes
the diff, and writes the artifact directly — would establish a SECOND
shape-orchestration pattern (claude-dispatch shapes vs bash-only shapes)
that future shapes would have to choose between. ENG-129 D-004's
rationale stands.

*Reference to constraint:* CLAUDE.md "Don't add features… beyond what
the task requires" — the inverse: don't add a SECOND pattern when the
existing one fits. Pattern consistency outweighs the per-week token
saving.

*Rejected alternative — bash-only driver for Shape C (skip
`dispatch.sh`):* rejected for pattern-consistency reasons above.
Logged as OQ-3 for post-ship review: if the operator observes that
Shape C's token spend is non-trivial, revisit. Reversible decision.

### D-009. Tests are sibling `bin/retro-shape-<name>-test.sh` files, one per shape; each test mirrors `bin/retro-shape-stage-failure-summary-test.sh`'s fixture inventory but adapted to the shape's inputs.

The fixture-inventory template (from
`bin/retro-shape-stage-failure-summary-test.sh:71-454`) covers:

- argv parsing (missing required flag → die)
- happy-path dry-run (placeholder artifact written)
- token resolution (no `{token}` leftovers in rendered prompt)
- dry-run skips dispatch
- happy-path non-dry-run (stub dispatch writes artifact)
- artifact-missing (stub dispatch returns 0 but writes no file → die)
- dispatch non-zero exit → die with rc in message
- prompt-body carries the empty-inputs carve-out text
- unresolved-token-in-rendered-prompt → die
- parent dir missing → die
- same-day rerun overwrites artifact

Each new shape's test sibling reuses this inventory, swapping in the
shape's specific inputs (Shape A: events.jsonl rows; Shape B: harness
source files; Shape C: `claude --version` output + expected file).

Per-shape extra fixtures:
- Shape A: events.jsonl with NO `sandbox_denial` rows → prompt's
  empty-rows carve-out emits "(no rows in period)".
- Shape B: harness source files unchanged from a known-good fixture →
  shape's prompt body's "no drift" output schema is exercised.
- Shape C: expected-claude-version file absent → "dependency not wired"
  carve-out exercised; expected file with content matching `claude
  --version` → "match" carve-out; expected file with different content
  → "drift" carve-out.

Each test file adds itself to `.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]`
per CLAUDE.md "Per-target dispatch.tools extras and profile-derived tools (ENG-51, ENG-94)"
regeneration snippet — same chore as ENG-129's test addition.

*Reference to constraint:* CLAUDE.md "Tests are sibling shell scripts
named `*-test.sh` in `bin/`" + the existing
`bin/retro-shape-stage-failure-summary-test.sh:11-15` source-and-stub
pattern.

*Rejected alternative — one mega-test file
`bin/retro-shapes-test.sh` covering all three:* rejected because (a)
breaks the sibling-test convention (every `bin/foo.sh` has
`bin/foo-test.sh`), (b) makes selective re-runs harder, (c) pre-commit
hook iterates `bin/*-test.sh`; one file is one row in the OK summary.

### D-010. Scope fence: three shapes, no coordinator, no detective.

This brainstorm ships:
- Three new prompt bodies under `bin/retro-prompts/`.
- Three new drivers under `bin/`.
- Three new sibling tests under `bin/`.
- Minimal edits to `bin/run-retrospective-local.sh` (invoke three new shapes; pass four paths to the §9 rendered prompt).
- Minimal edits to `bin/render-prompt.sh` (extend `AGENT_RUNTIME_TOKENS`).
- Minimal edits to `AGENT_PROMPTS.md` §9 (add three "Read these artifacts" entries; no fence-count change).
- One short CLAUDE.md amendment under "Retrospective shapes (ENG-129)".
- `.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]` regeneration for the three new tests.

This brainstorm does NOT ship:
- The sandbox-detective Phase A ticket (separate; Shape A consumes its
  output). See §3 Dependencies.
- The pin-claude-version ticket (separate; Shape C consumes its output).
  See §3 Dependencies.
- A shape coordinator / generic shape-runner (ENG-129 OQ-3 deferred).
- Any other shape (calibration ENG-39, component audit ENG-40, etc.).
- Promotion of any of the three classes from observation to halt-loud
  (explicit "OUT" in the ticket body — "not the retrospective's job;
  per-dispatch detectives do that").
- Replacement of the §9 narrative with shape-only output (explicit "OUT").

*Reference to constraint:* the Linear ticket's "OUT" section, verbatim.
CLAUDE.md "Ticket sizing rubric (autonomy boundary)" — this ticket is
explicitly umbrella-shaped per the ticket's own sizing note. See §10
for the split recommendation.

## 3. Architecture

### Files added

1. **`bin/retro-prompts/tool-denial-trends.md`** — Shape A prompt body.
   Tokens: `{events_jsonl_path}`, `{period_start_iso}`,
   `{period_end_iso}`, `{artifact_path}`, `{previous_period_path}`.
   Body instructs the agent to filter `events.jsonl` by
   `.event == "sandbox_denial"` within the period, group by
   `claude_version × stage`, name the top 5 denial patterns per bucket,
   compare to the previous period if available. Carve-out: if jq filter
   matches zero rows, write "No sandbox_denial events in period
   (sandbox-detective Phase A may not be wired)." and exit.

2. **`bin/retro-shape-tool-denial-trends.sh`** — Shape A driver. Mirrors
   `bin/retro-shape-stage-failure-summary.sh` structure verbatim:
   parses `--artifact-path`, `--period-start-iso`, `--period-end-iso`,
   `--previous-period-path` (optional, defaults to `(none)`); renders
   prompt via `sed` substitution; validates no unresolved tokens;
   dispatches `bash $SCRIPT_DIR/dispatch.sh retrospective <rendered>
   <log>`; validates the artifact file exists post-dispatch.
   PIPELINE_DRY_RUN=1 writes a placeholder artifact + skips dispatch.

3. **`bin/retro-shape-tool-denial-trends-test.sh`** — Shape A sibling
   test. Fixture inventory per D-009.

4. **`bin/retro-prompts/runtime-invariant-audit.md`** — Shape B prompt
   body. Tokens: `{agent_prompts_path}` (absolute path to
   `$HARNESS_ROOT/AGENT_PROMPTS.md`), `{allowed_tools_dump_path}`
   (file the driver writes with the contents of
   `allowed_tools_for <stage>` for each stage), `{resolvers_dump_path}`
   (file the driver writes with the contents of `PROMPT_RESOLVERS` and
   `AGENT_RUNTIME_TOKENS`), `{add_dir_dump_path}` (file the driver
   writes with the names of paths passed via `--add-dir` per stage),
   `{artifact_path}`, `{previous_period_path}`. Body instructs the
   agent to: (a) extract `{token}` references from `AGENT_PROMPTS.md`
   bodies and verify each appears in `PROMPT_RESOLVERS` or
   `AGENT_RUNTIME_TOKENS`; (b) extract `Bash(<x>:*)` strings from
   `AGENT_PROMPTS.md` prose and verify each appears in some stage's
   `allowed_tools_for` output; (c) extract path references in prompt
   bodies and verify any per-issue paths are covered by `--add-dir`;
   (d) characterise each drift (typo / legacy / unfinished migration /
   intentional literal); (e) write a markdown artifact with two
   sections: "Drift findings" (sorted by severity) and "No-drift
   confirmations" (one-liner). Carve-out: zero drift → write "No
   runtime-invariant drift detected this period." and exit.

5. **`bin/retro-shape-runtime-invariant-audit.sh`** — Shape B driver.
   Same structure as Shape A. Additional steps before `sed`-rendering:
   - `mkdir -p` a tmp dir; produce four intermediate text files
     (`allowed_tools_dump.txt`, `resolvers_dump.txt`,
     `add_dir_dump.txt`, `tokens_in_use_dump.txt`).
   - The dumps are produced via `bash -c` invocations against
     `bin/dispatch.sh`'s `allowed_tools_for` (source-and-call pattern,
     not subshell-and-parse — `dispatch.sh`'s test sentinel allows
     sourcing) and `grep -oE '\{[a-z_]+\}' AGENT_PROMPTS.md`.
   - These intermediate files live in
     `$PROJECT_STATE_DIR/retrospective-${date}/_runtime-invariant-audit-inputs/`
     and are deleted on shape exit via a `RETURN` trap.
   The driver does NO drift analysis — it produces inputs; the agent reasons.

6. **`bin/retro-shape-runtime-invariant-audit-test.sh`** — Shape B
   sibling test.

7. **`bin/retro-prompts/claude-version-drift.md`** — Shape C prompt
   body. Tokens: `{observed_version}` (driver pre-computes via `claude
   --version`), `{expected_version}` (driver reads the pin file; literal
   `<missing>` when absent), `{expected_version_path}` (path the
   pin-claude-version ticket owns), `{previous_observed_version}` (from
   the prior retrospective's Shape C artifact, or `(none)`),
   `{artifact_path}`. Body instructs the agent to: (a) compare observed
   to expected; (b) if equal → "match"; (c) if expected is `<missing>` →
   "dependency-not-wired" (single-line artifact); (d) if differ → "drift"
   + name observed/expected/previous_observed + one-paragraph
   speculation on what changed in claude CLI between those versions
   (release-notes URL if the agent can synthesise from common-knowledge).

8. **`bin/retro-shape-claude-version-drift.sh`** — Shape C driver. Same
   structure as Shape A. Extra: before rendering, invokes `claude
   --version` (captures output; falls back to "unknown" if exit != 0)
   and `cat $EXPECTED_PIN_FILE` (captures output; falls back to
   "<missing>" if file absent).

9. **`bin/retro-shape-claude-version-drift-test.sh`** — Shape C sibling
   test. Extra fixture: stub `claude` binary in `STUB_DIR` that emits a
   known version string.

### Files modified

10. **`bin/run-retrospective-local.sh`** — extend the existing
    `# ENG-129: pre-compute stage-failure-summary as a shape artifact`
    block (`bin/run-retrospective-local.sh:79-101`) with three additional
    shape invocations after the first. Each new invocation soft-degrades
    on failure per D-006:

    ```bash
    # ENG-158: Shape A (tool-denial-trends).
    local tool_denial_trends_path="${shape_artifact_dir}/tool-denial-trends.md"
    local shape_a_rc=0
    bash "$SCRIPT_DIR/retro-shape-tool-denial-trends.sh" \
      --artifact-path     "$tool_denial_trends_path" \
      --period-start-iso  "$period_start_iso" \
      --period-end-iso    "$period_end_iso" \
      || shape_a_rc=$?
    if (( shape_a_rc != 0 )); then
      printf 'Shape A (tool-denial-trends) failed (rc=%d). See log: %s\n' \
        "$shape_a_rc" "$log_file" > "$tool_denial_trends_path"
      bash "$SCRIPT_DIR/slack.sh" info "Retrospective Shape A failed; continuing."
    fi
    # …mirror for Shape B and Shape C…
    ```

    The §9 prompt-rendering sed pipeline gets three additional `-e
    "s|{token}|...|g"` arguments alongside the existing
    `{stage_failure_summary_path}`.

11. **`bin/render-prompt.sh`** — one-line edit at line 78:

    ```diff
    -AGENT_RUNTIME_TOKENS=' file pr_number stage_failure_summary_path '
    +AGENT_RUNTIME_TOKENS=' file pr_number stage_failure_summary_path tool_denial_trends_path runtime_invariant_audit_path claude_version_drift_path '
    ```

12. **`AGENT_PROMPTS.md`** §9 — three additional bullets in the
    "Read these files" list (between today's items 6 and 7, or as items
    1a/1b/1c near the existing pre-computed artifact reference). Each
    new bullet: "Read the pre-computed `<name>` artifact at
    `{<name>_path}` and incorporate its findings into <which section>."
    Fence count stays at 2 (per `bin/render-prompt.sh:91-109`).

    Specific placements:
    - Shape A → Systemic findings (top 3); flag when denial patterns
      cluster on a specific claude_version × stage.
    - Shape B → Bias findings; runtime-invariant drift fits the
      cross-agent contradictions / confirmation-bias-audit family.
    - Shape C → top of Systemic findings; a CLI upgrade between
      retrospectives is the single highest-priority "what changed".

13. **`CLAUDE.md`** — extend "Retrospective shapes (ENG-129)" §:

    > ENG-158 adds three sibling shapes (`tool-denial-trends`,
    > `runtime-invariant-audit`, `claude-version-drift`) following the
    > ENG-129 pattern. Each consumes a different input surface
    > (events.jsonl sandbox_denial rows, harness source files, the
    > checked-in claude version pin respectively). Failure semantics
    > differ from `stage-failure-summary`: the three new shapes
    > soft-degrade — a driver failure writes a marker artifact and
    > posts a Slack info, the §9 dispatch still runs. (Compare:
    > `stage-failure-summary` halts the parent because its content is
    > load-bearing.)

14. **`.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]`**
    — regeneration adds three new `Bash(bash bin/retro-shape-<name>-test.sh:*)`
    entries per the snippet in CLAUDE.md "Per-target dispatch.tools extras
    and profile-derived tools".

### Files NOT modified (intentional)

- **`bin/dispatch.sh`** — no new stage; the three shapes reuse the
  `retrospective` allowed-tools arm at line 543. No `--allowed-tools`
  edit.
- **`bin/render-prompt.sh::PROMPT_RESOLVERS`** — D-007 puts the new
  tokens in `AGENT_RUNTIME_TOKENS`, not `PROMPT_RESOLVERS`.
- **`bin/metrics.sh`** — no new metric event. Shape A is a READ-side
  consumer of `sandbox_denial` rows; the producer is the
  sandbox-detective Phase A dependency.
- **`bin/pipeline-events.json`** — no new vocabulary. Shapes don't emit
  verdict markers per ENG-129's precedent.
- **`bin/scope-check.sh` / `bin/run-local-helpers.sh::partition_dirty_paths`**
  — retrospective doesn't go through `run-local.sh::tick`; no scope-sweep
  interaction (per ENG-129's "Files NOT modified" rationale).
- **`docs/architecture.md`** — the two-binary topology is unchanged;
  the retrospective binary's internal shape count grows but the external
  contract (Mondays at 09:00, PR with proposals) does not.
- **`launchd/com.twinning.retrospective.plist.template`** — same binary,
  same trigger. The internal split is transparent to launchd.

## 4. Data flow

### Flow 1: weekly retrospective with four shapes (the new common path)

```
launchd (com.twinning.retrospective, Mon 09:00)
  → run-retrospective-local.sh::main()
    → fresh-checkout guard, fetch + checkout working branch
    → _compute_retro_period           (existing, ENG-129)
    → mkdir -p $PROJECT_STATE_DIR/retrospective-${today}/
    → bash retro-shape-stage-failure-summary.sh …  (existing; HALT on fail)
    → bash retro-shape-tool-denial-trends.sh …     (NEW; soft-degrade)
    → bash retro-shape-runtime-invariant-audit.sh … (NEW; soft-degrade)
    → bash retro-shape-claude-version-drift.sh …   (NEW; soft-degrade)
    → extract §9 fenced block from AGENT_PROMPTS.md
    → sed-substitute {stage_failure_summary_path}, {tool_denial_trends_path},
      {runtime_invariant_audit_path}, {claude_version_drift_path}
    → bash dispatch.sh retrospective <rendered-§9> <log>
      → parent agent: Reads four artifact files; splices into PR body
    → git add -A / commit / push / gh pr create
```

### Flow 2: shape-only invocation (manual / debugging)

```
operator runs:
  TARGET_REPO=/path bash bin/retro-shape-tool-denial-trends.sh \
    --artifact-path /tmp/out.md \
    --period-start-iso 2026-05-13T00:00:00Z \
    --period-end-iso   2026-05-20T00:00:00Z
  → renders prompt, dispatches claude, writes /tmp/out.md
```

Each shape is independently invocable — the ENG-129 architectural
property is preserved.

### Flow 3: dry-run path

```
PIPELINE_DRY_RUN=1 bash retro-shape-<name>.sh …
  → log "[DRY_RUN] would dispatch …"
  → write placeholder content to --artifact-path
  → return 0
```

Mirrors `bin/retro-shape-stage-failure-summary.sh:90-95`. The parent
in dry-run flows through all four shapes; each writes a placeholder;
§9 dispatch is also dry-run-gated.

### Flow 4: dependency-not-wired path (Shape A or C)

```
bash retro-shape-tool-denial-trends.sh …
  → driver renders + dispatches normally
  → agent jq-filters events.jsonl for sandbox_denial rows → zero matches
  → agent writes "No sandbox_denial events in period
                  (sandbox-detective Phase A may not be wired)."
  → driver validates artifact exists; returns 0
```

The shape does NOT crash on missing dependency — it produces a
deterministic artifact. The §9 agent reads "no rows" and treats it as
no-finding for that pass.

### Flow 5: Shape B inputs production

```
bash retro-shape-runtime-invariant-audit.sh …
  → driver:
    → mkdir -p _inputs/
    → bash -c 'source bin/dispatch.sh && for s in brainstorming planning …; do
                 printf "## stage=%s\n%s\n" "$s" "$(allowed_tools_for "$s")"
               done' > _inputs/allowed_tools_dump.txt
    → grep -oE '\{[a-z_]+\}' AGENT_PROMPTS.md | sort -u
        > _inputs/tokens_in_use_dump.txt
    → awk '/^PROMPT_RESOLVERS=/,/^.$/' bin/render-prompt.sh
        > _inputs/resolvers_dump.txt
    → printf 'add_dir paths per dispatch (ENG-155):\n%s\n' \
            "$(grep -nE '\-\-add-dir' bin/dispatch.sh)" \
        > _inputs/add_dir_dump.txt
  → driver renders prompt with the four file paths as tokens
  → bash dispatch.sh retrospective <rendered> <log>
    → agent Reads four input files; characterises drift
    → agent Writes artifact to {artifact_path}
  → driver validates artifact exists; RETURN-trap removes _inputs/
```

## 5. Error handling

### Shape driver fails (rc != 0)

Per D-006:
- Shape A / B / C → soft-degrade. Parent writes a marker artifact
  "Shape <name> failed (rc=<n>). See log: <path>" so §9 still has
  a deterministic file to Read.
- Slack `info` (NOT `error`) — the retrospective is not halted; the
  operator sees the marker in next Monday's PR and decides next steps.

### Artifact missing after dispatch returns 0

Each shape driver validates `[[ -f "$artifact_path" ]]` after dispatch
returns (per `bin/retro-shape-stage-failure-summary.sh:108-109`'s
existing pattern). If absent, driver dies; parent treats as the "Shape
driver failed" path above.

### `events.jsonl` missing or empty (Shape A)

Today's `bin/retro-prompts/stage-failure-summary.md:18-26` shows the
"Insufficient-sample carve-out" prose pattern. Shape A's prompt body
ships the same carve-out: jq filter matches zero rows → single-line
artifact "No sandbox_denial events in period." → exit 0. Driver writes
no extra failure.

### Tokens missing or unknown in rendered prompt (every shape)

Each driver's `_validate_no_unresolved_tokens` mirrors
`bin/retro-shape-stage-failure-summary.sh:55-74`. Any leftover `{token}`
in the rendered prompt → `die "shape: unresolved tokens: …"`. Same
pattern as ENG-129.

### Shape B input dump files are themselves stale or wrong

Shape B's `RETURN`-trap cleanup of `_inputs/` runs on any exit path.
If the driver crashes mid-dump, the trap fires, no orphan files. If
the driver succeeds but the dispatch crashes (`dispatch.sh` exits
non-zero), the `RETURN` trap fires on driver exit, removes the inputs.

### `claude --version` shells out and returns non-zero (Shape C)

Driver captures: `observed="$(claude --version 2>/dev/null || true)";
observed="${observed:-<unable-to-resolve>}"`. The shape's prompt body
handles `<unable-to-resolve>` as an explicit error class ("driver
could not capture claude --version output").

### Expected-version file absent (Shape C)

Driver: `expected="$(cat "$EXPECTED_PIN_FILE" 2>/dev/null || true)";
expected="${expected:-<missing>}"`. Prompt body's
"dependency-not-wired" carve-out (D-005) handles `<missing>` → single-line
artifact + exit 0. No driver crash, no parent halt.

### Per-shape concurrency

Each shape's dispatch consumes one ENG-81 semaphore slot, releases,
the next shape acquires. Worst case at K=2 with two concurrent pipeline
dispatches: shapes queue. Sequential, total worst-case latency ~30 min
per shape × 4 shapes = ~2h Monday morning. Operator-acceptable for a
weekly cadence. ENG-129's D-006 §6 edge case 14 already documents this.

### Artifact-path collision across shapes

Each shape writes to a distinct filename (`tool-denial-trends.md`,
`runtime-invariant-audit.md`, `claude-version-drift.md`) under the
shared `$PROJECT_STATE_DIR/retrospective-${today}/`. No collisions.

### `--allowed-tools` insufficient for Shape B's dispatch

Shape B's prompt instructs the agent to Read the four input dump
files; the `retrospective` allowed-tools arm
(`bin/dispatch.sh:543`) already grants `Read`, `Grep`, `Glob`,
`Bash(jq:*)`, `Bash(awk:*)`. The driver pre-stages the inputs, so the
agent does not need `Bash(grep:*)` against the raw harness files.

### A new claude version breaks one of the shapes' dispatch

If `claude --version 2.0.0` (hypothetical) changes stream-json fields
such that `dispatch.sh::_render_and_capture_stream` cannot capture
cost, the SHAPE'S dispatch fails cost capture (`bin/dispatch.sh:111-125`
returns 0 with a soft-fail log line) but the artifact still gets
written. Shape behavior is preserved; cost telemetry degrades — handled
by the existing ENG-26 logic, not new.

## 6. Edge cases

1. **First-ever retrospective run with the three new shapes (no prior
   retrospective artifact dirs).** Each shape's
   `--previous-period-path` defaults to `(none)` per the existing
   `bin/retro-shape-stage-failure-summary.sh:11-30` argv parsing.
   Prompts handle `(none)` (no trend comparison; only current period
   findings).

2. **A new claude version that adds a NEW `permission_denials` shape
   (richer payload).** Shape A's input is the
   `events.jsonl::sandbox_denial` row schema — the row producer
   (sandbox-detective Phase A) normalizes the upstream schema change.
   Shape A is unaffected; the Phase A ticket owns adaptation.

3. **The three new tests trip the
   `bin/agent-prompts-content-test.sh::PROMPT_RESOLVERS` consistency
   check.** That test asserts every `{token}` in `AGENT_PROMPTS.md` is
   in `PROMPT_RESOLVERS` or `AGENT_RUNTIME_TOKENS`
   (`bin/agent-prompts-content-test.sh:1556-1607`). Per D-007 the three
   new tokens go in `AGENT_RUNTIME_TOKENS`; test continues to pass.

4. **Shape A's bucket key (`claude_version × stage`) is `(unknown,
   unknown)` for every row.** The sandbox-detective Phase A ticket
   ships without populating `claude_version`. Shape A's prompt body's
   single-bucket fallback (D-003) emits one bucket; §9 sees a
   coarse-granularity finding. Still useful.

5. **Shape B detects "drift" that is actually intentional.** Example: a
   prompt body shows `Bash(bash bin/foo.sh:*)` in prose as a
   counter-example ("DO NOT use…"); the audit flags it as a missing
   allowed-tools entry. Mitigated by D-004 — the agent reads context
   and characterises. Worst-case: a P3 "review-noise" finding. Operator
   can refine the prompt body in a follow-up.

6. **Shape C "drift" finding is a Homebrew auto-upgrade between
   retrospectives, harmless behaviorally.** Drift is REPORTED, not
   GATED. The operator inspects the §9 PR, decides whether to update
   the pin file (owned by the pin-claude-version ticket) or revert
   the claude install. No dispatch is blocked.

7. **All four shapes' dispatches in one Monday tick exceed the K=2
   semaphore + concurrent pipeline dispatches → 60-min+ retrospective
   start.** Acceptable per ENG-129 §6 edge case 14. Worst-case bumped
   from "one shape" to "four shapes" but still bounded; if observed
   problematic, operator can raise `max_concurrent_features` for the
   Monday-morning window. Out of scope.

8. **Operator manually invokes Shape C with `--expected-version-path`
   pointing at a directory.** Shape C's `cat "$EXPECTED_PIN_FILE"`
   would emit `cat: …: Is a directory` on stderr; the driver's
   `2>/dev/null || true` swallows it; `expected="<missing>"`; shape
   emits "dependency-not-wired". Bounded failure.

9. **A test-stub `claude` binary in `STUB_DIR` shadows the real one
   during Shape C tests.** Standard source-and-stub pattern; covered
   by `bin/retro-shape-claude-version-drift-test.sh`'s fixture. Same
   shape as the existing `dispatch.sh` stub in `bin/retro-shape-stage-failure-summary-test.sh`.

10. **Shape B's `RETURN`-trap fires before the dispatch reads the
    input files (race).** The trap fires on DRIVER exit; dispatch is a
    synchronous bash call inside `main()` (per
    `bin/retro-shape-stage-failure-summary.sh:101-106`). The dispatch
    completes BEFORE the driver returns; trap fires after the agent's
    read. No race.

11. **Shape A wins the race for the semaphore against a high-priority
    pipeline dispatch.** ENG-81 semaphore is FIFO-ish but not
    priority-aware. The pipeline dispatch may queue behind Shape A's
    dispatch. Acceptable — same as ENG-129; the retrospective is
    Monday morning.

12. **The pin-claude-version ticket ships but the expected-version file
    lives at a path Shape C doesn't know about.** Shape C reads the
    path from a `--expected-version-path` flag (passed from
    `bin/run-retrospective-local.sh`). The path is the integration
    contract between Shape C and the pin-claude-version ticket. The
    parent retrospective resolves the path from a
    `bin/common.sh`-exposed env var or a `.pipeline-config/...` key
    (decision deferred to the pin-claude-version ticket; Shape C just
    takes the flag).

13. **One of the three shapes' prompt bodies grows to >300 lines and
    bumps against the per-dispatch token budget.** Same risk every
    shape carries; mitigated by ENG-65's per-stage gtimeout
    (retrospective default 30 min). No new mitigation needed.

14. **Concurrent invocation of `bin/retro-shape-claude-version-drift.sh`
    races with a Homebrew install of a new `claude` version.** The
    driver captures `claude --version` once at start; the captured
    string is what gets diffed. The race window is a single
    millisecond-scale subprocess call; if it loses the race, Shape C
    reports drift on the next retrospective run.

15. **Shape A's bucket count explodes (many distinct claude_versions
    seen in the period).** Limit: 10 buckets max in the artifact
    (prompt body declares this); excess goes into an "(other)" bucket.
    Matches the §1 stage-failure summary's "top 5" pattern.

## 7. Open questions

1. **OQ-1. Should the three shapes share a thin helper for argv
   parsing / `_validate_no_unresolved_tokens` / artifact-exists check?**
   They will all carry the same 30-40 lines of boilerplate (per
   `bin/retro-shape-stage-failure-summary.sh:16-74`). A shared library
   `bin/retro-shape-helpers.sh` would deduplicate. Current proposal:
   per-shape duplication (matches ENG-129). Revisit when a fourth
   shape lands — three duplications is the "rule of three" inflection
   point but two would be premature; a single shared helper extracted
   from THIS ticket's three new shapes might be the right call.
   Defer to coordinator ticket. Not blocking.

2. **OQ-2. Should Shape B's analysis be a bash diff (no claude)?** D-004
   chose claude for context-aware characterisation. If the agent's
   characterisation post-ship turns out to add more noise than signal,
   a follow-up could move Shape B to bash-only. The downside of
   bash-only: no characterisation, so every drift surfaces as raw text.
   Vote: claude for now; revisit if signal-to-noise is bad. Not blocking.

3. **OQ-3. Should Shape C skip `dispatch.sh` and write its artifact
   directly from the driver?** D-008 chose dispatch-consistency. Same
   revisit clause as OQ-2.

4. **OQ-4. Should the §9 prompt body's "Read these files" list grow
   to enumerate every shape artifact (current proposal) or should §9
   establish a single shape-artifacts directory and say "Read every
   `*.md` in this directory"?** The latter scales better but couples
   §9 to a directory convention. Current proposal is explicit
   enumeration. Defer the directory convention to the coordinator
   ticket. Not blocking.

5. **OQ-5. Should the soft-degrade marker (Shape A/B/C failure)
   include the full driver-side stderr capture, or just the rc?**
   Current proposal: rc + log path. Full stderr in the artifact has
   PII/credential risk if any tool leaks env-vars. Log path is safer
   (operator opens the log when needed). Not blocking.

6. **OQ-6. The three new shapes will produce three new
   per-retrospective artifacts. Should the directory get a TTL prune
   (delete `retrospective-*` dirs older than 90 days)?** Disk pressure
   is small (<5 MB per run); ENG-129 §6 edge case 15 already deferred
   the TTL question. Not blocking.

7. **OQ-7. The pin-claude-version dependency hasn't been filed yet
   (per §3). Should ENG-158 file it as a sub-ticket / blocker before
   Shape C starts?** D-005's graceful-degradation property means Shape
   C can ship BEFORE the pin file exists; it will emit
   "dependency-not-wired" until the pin ships. The operator can file
   the pin ticket independently. Recommend filing as a separate ticket
   with a `blocked-by-ENG-158` relation. Not blocking implementation.

8. **OQ-8. Same as OQ-7 for sandbox-detective Phase A.** D-002's
   graceful-degradation: Shape A ships independently; emits "no rows"
   until Phase A wires emission. Recommend filing the Phase A ticket
   first, since without it Shape A has zero signal. Not blocking
   implementation; blocking USEFULNESS.

## 8. ADR stress test

Existing decisions this ticket touches:

- **ENG-26 (six-field usage-<stage>.json schema):** The shapes'
  dispatches inherit `bin/dispatch.sh::_render_and_capture_stream`.
  `PIPELINE_ISSUE_ID` stays unset for retrospective dispatches
  (`bin/dispatch.sh:573-574` comment), so no `usage-<stage>.json` is
  written. Same property as ENG-129. **Pressure on ENG-26: zero.**

- **ENG-48 / ENG-65 (gtimeout watchdog + per-stage timeout):** Each
  shape's dispatch inherits `retrospective`'s 30-min default. Four
  shapes × 30 min worst case = 2h; well under launchd cadence. If
  Shape A's `events.jsonl` scan grows slow, the per-stage timeout config
  override (`dispatch_timeout_minutes_per_stage`) is the existing knob.
  **Pressure on ENG-48/ENG-65: low.** Future: a per-shape timeout
  override might earn its keep, but not in this PoC.

- **ENG-81 (per-project dispatch concurrency, K=2):** Each shape
  consumes one semaphore slot, releases. Sequential within the
  retrospective binary; no parallelism. Total Monday-morning load
  bumps from 2 dispatches to 5 (1 stage-failure-summary + 3 new shapes
  + 1 §9 parent). **Pressure on ENG-81: low.** Worst case a Monday
  morning with concurrent pipeline dispatches delays retrospective
  start by tens of minutes; acceptable per ENG-129 §6 edge case 14.

- **ENG-87 (cross-dispatch staleness, dispatch_id hand-off):**
  Retrospective shapes do not have an issue_id; `PIPELINE_DISPATCH_ID`
  stays unset; no marker injection. Same property as ENG-129.
  **Pressure on ENG-87: zero.**

- **ENG-94 (per-target dispatch.tools extras):** Each shape's sibling
  test must be added to `dispatch.tools.{implementing,qa}[]` via the
  regeneration snippet. Three additional entries; CLAUDE.md "Per-target
  dispatch.tools extras and profile-derived tools" snippet already
  covers this. **Pressure on ENG-94: zero — uses the existing knob.**

- **ENG-100 (sub-agent debris):** All three shape artifacts live in
  `$PROJECT_STATE_DIR/retrospective-${today}/`, OUTSIDE any worktree.
  `partition_dirty_paths` does not run on retrospective branches per
  ENG-129's §3 "Files NOT modified" rationale. Shape B's `_inputs/`
  tmp dir lives under the same `$PROJECT_STATE_DIR/retrospective-…/`
  and is `RETURN`-trap removed. **Pressure on ENG-100: zero.**

- **ENG-103 (per-stage model tiering):** Retrospective is intentionally
  out of scope per ENG-103. Shapes inherit subscription default. If a
  cheaper-tier (Haiku) becomes attractive for Shape C's two-string
  compare, the config knob to surface it doesn't exist yet — flagged
  as OQ-3's future-work. **Pressure on ENG-103: zero today.**

- **ENG-129 (retrospective shape pattern):** This ticket adds three
  INSTANTIATIONS of the ENG-129 pattern. The pattern's three contracts
  (prompt body location, driver location, sibling test location)
  scale to N shapes without modification. ADR stress: D-006's
  soft-degrade contract DIVERGES from ENG-129's halt contract.
  Documented in CLAUDE.md edit (D-010 item 13). The divergence is
  per-shape, not per-pattern — the pattern stays consistent; what
  changes is the parent's reaction to driver failure. **Pressure on
  ENG-129: small.** Specifically:
  - The "shape failures HALT the parent" line in ENG-129 D-006 is
    no longer universally true. CLAUDE.md edit updates the surrounding
    paragraph.
  - `run-retrospective-local.sh:96-101` (`if (( shape_rc != 0 )) then
    slack error + exit 20`) gets a per-shape policy; the existing
    `stage-failure-summary` keeps halt semantics, three new shapes
    soft-degrade.

- **ENG-155 (`--add-dir` to widen claude's sandbox):** Shape B's
  prompt body asks the agent to reason about `--add-dir` paths.
  Shape B itself does NOT need `--add-dir` — the agent reads the
  pre-staged dump files in `$PROJECT_STATE_DIR/retrospective-…/_inputs/`
  which are NOT under `$issue_state_dir` (retrospective dispatches
  have no `issue_state_dir`). The four input file paths in
  `--add-dir`'s expanded scope is the AGENT'S INPUT but not the AGENT'S
  CONSTRAINT. **Pressure on ENG-155: zero.**

- **CLAUDE.md "AGENT_PROMPTS.md is load-bearing" + fence-count
  invariant:** The §9 edit adds three "Read these files" bullets;
  fence count stays at 2. `bin/render-prompt.sh::extract_block` schema
  check (`bin/render-prompt.sh:91-109`) continues to pass.
  **Pressure on AGENT_PROMPTS.md schema: zero.**

No existing ADR is overturned. The shape-pattern's failure-semantics
contract gets a per-shape extension (D-006); CLAUDE.md edit captures it.
No new ADR proposed.

## 9. Assumption inventory

Format: `[verified|assumed]` ITEM — `path:line` reference (or "needs
to be created" / "owned by dependency ticket" for new/external items).

### Verified — code paths quoted from the current tree

- `[verified]` `bin/retro-shape-stage-failure-summary.sh:1-115` —
  ENG-129's existing driver. Each new shape's driver mirrors its
  argv parsing, render+validate, dispatch invocation, artifact check,
  and DRY_RUN branch, structurally identically.
- `[verified]` `bin/retro-shape-stage-failure-summary.sh:11-30` —
  argv parsing (`--artifact-path`, `--period-start-iso`,
  `--period-end-iso`, `--previous-period-path`). New shapes mirror.
- `[verified]` `bin/retro-shape-stage-failure-summary.sh:55-74` —
  `_validate_no_unresolved_tokens` shape. New shapes mirror token by
  token.
- `[verified]` `bin/retro-shape-stage-failure-summary.sh:90-94` —
  PIPELINE_DRY_RUN=1 placeholder write + skip dispatch. New shapes
  mirror.
- `[verified]` `bin/retro-shape-stage-failure-summary.sh:101-106` —
  `bash "$SCRIPT_DIR/dispatch.sh" retrospective "$rendered" "$log"` is
  the shape→dispatch boundary; D-008 reuses this.
- `[verified]` `bin/retro-shape-stage-failure-summary-test.sh:1-579` —
  the test fixture inventory. D-009 enumerates which fixtures each new
  shape's test replicates.
- `[verified]` `bin/retro-prompts/stage-failure-summary.md:1-71` —
  prompt body shape: front-matter tokens, "Insufficient-sample
  carve-out", "Task" block, "Output schema" block, "Mandatory exit
  instructions". Each new shape's prompt body mirrors this layout.
- `[verified]` `bin/retro-prompts/stage-failure-summary.md:18-26` —
  insufficient-sample carve-out prose; D-002 and D-005 mirror.
- `[verified]` `bin/run-retrospective-local.sh:79-101` — the
  ENG-129 shape invocation block. D-006 extends it with three more
  shape invocations.
- `[verified]` `bin/run-retrospective-local.sh:113-116` — the §9
  prompt `sed` interpolation of `{stage_failure_summary_path}`. The
  three new tokens get appended `-e "s|{token}|val|g"` arguments to
  this sed pipeline.
- `[verified]` `bin/render-prompt.sh:41-58` — `PROMPT_RESOLVERS`
  registry; D-007 says NOT to add the new tokens here.
- `[verified]` `bin/render-prompt.sh:66-78` — `AGENT_RUNTIME_TOKENS`
  comment + declaration. D-007's one-line edit extends line 78.
- `[verified]` `bin/render-prompt.sh:91-109` — `extract_block`
  fence-count invariant. §9 edit preserves count at 2.
- `[verified]` `bin/dispatch.sh:515-545` — `allowed_tools_for` per-stage
  case statement; line 543 has `retrospective)` with `Read, Write,
  Edit, Grep, Glob, TaskCreate, Agent, Bash(git log:*), Bash(git
  diff:*), Bash(git show:*), Bash(git rev-list:*), Bash(git
  describe:*), Bash(jq:*), Bash(awk:*), Bash(bash
  .pipeline/bin/linear.sh:*), …`. Adequate for all three new shapes.
- `[verified]` `bin/dispatch.sh:62` — SEC-002 explicitly excludes
  `permission_denials` from `usage-<stage>.json`. This is the gap
  that the sandbox-detective Phase A dependency must close.
- `[verified]` `bin/dispatch.sh:554` (in `bin/dispatch-test.sh` fixture)
  — the stream-json `type:result` shape: `"permission_denials":[]`
  field present. Confirms Phase A has a parse target.
- `[verified]` `bin/dispatch.sh:743` — `cmd+=(--add-dir "$issue_state_dir")`
  ENG-155 widening. Shape B's audit reads this line.
- `[verified]` `bin/metrics.sh:43,67` — events.jsonl path + schema
  shape `{ts, event, issue_id, stage, outcome, duration_ms, notes,
  tokens_in?, tokens_out?, cache_read?, cache_create?, cost_usd?, model?}`.
  Shape A filters by `.event == "sandbox_denial"` per D-002.
- `[verified]` `bin/metrics.sh:73` — `model` field already present
  in the schema (added in ENG-103). Shape A and Shape C both reference
  it; no schema change needed for `model`.
- `[verified]` `AGENT_PROMPTS.md:2025` — `## 9. Retrospective Agent
  (Scheduled)` header.
- `[verified]` `AGENT_PROMPTS.md:2044-2057` — "Read these files (in
  order)" numbered list. New shape artifacts get inserted bullets near
  item 1.
- `[verified]` `AGENT_PROMPTS.md:2066-2070` — "Some sections below are
  pre-computed by retrospective shapes" preamble that ENG-129
  introduced; extends without re-write.
- `[verified]` `AGENT_PROMPTS.md:2075-2082` — §9 §1 paragraph; Shape
  A's findings go into "Systemic findings (top 3)" alongside §1's
  output.
- `[verified]` `bin/agent-prompts-content-test.sh:1556-1607` —
  PROMPT_RESOLVERS + AGENT_RUNTIME_TOKENS consistency check. D-007's
  edit to `AGENT_RUNTIME_TOKENS` keeps the test green.
- `[verified]` `docs/architecture.md:14-19` — Two-binary topology;
  unchanged.
- `[verified]` CLAUDE.md "Retrospective shapes (ENG-129)" § (lines
  78-95 of project-instructions) — the pattern documentation. D-010
  item 13 amends.
- `[verified]` CLAUDE.md "Per-target dispatch.tools extras and
  profile-derived tools (ENG-51, ENG-94)" § — regeneration snippet
  for adding new tests to `dispatch.tools.{implementing,qa}[]`.
  D-010 item 14 reuses verbatim.
- `[verified]` `learned-rules/harness/brainstorm.md` does NOT exist
  (no slug-specific brainstorm learned rules yet). Prompt's "follow
  ALL rules listed" reduces to no-op for this slug.
- `[verified]` `docs/knowledge/decisions.md` does NOT exist
  (consistent with ENG-129 §9 Assumption Inventory).
- `[verified]` `docs/knowledge/gotchas.md` does NOT exist.

### Assumed — needs verification / owned by external dependency

- `[assumed]` `bin/retro-prompts/tool-denial-trends.md` does NOT yet
  exist. **To create in implementation.**
- `[assumed]` `bin/retro-shape-tool-denial-trends.sh` does NOT yet
  exist. **To create in implementation.**
- `[assumed]` `bin/retro-shape-tool-denial-trends-test.sh` does NOT
  yet exist. **To create in implementation.**
- `[assumed]` `bin/retro-prompts/runtime-invariant-audit.md` does NOT
  yet exist. **To create in implementation.**
- `[assumed]` `bin/retro-shape-runtime-invariant-audit.sh` does NOT
  yet exist. **To create in implementation.**
- `[assumed]` `bin/retro-shape-runtime-invariant-audit-test.sh` does
  NOT yet exist. **To create in implementation.**
- `[assumed]` `bin/retro-prompts/claude-version-drift.md` does NOT
  yet exist. **To create in implementation.**
- `[assumed]` `bin/retro-shape-claude-version-drift.sh` does NOT yet
  exist. **To create in implementation.**
- `[assumed]` `bin/retro-shape-claude-version-drift-test.sh` does NOT
  yet exist. **To create in implementation.**
- `[assumed — dependency]` `events.jsonl::sandbox_denial` rows do NOT
  exist today. **Owned by the sandbox-detective Phase A ticket.**
  Shape A's prompt body's "no rows" carve-out (D-002 + §6 edge case 4)
  is the graceful-degradation path until Phase A wires emission.
  **No file in this tree must be modified for the dependency to
  produce rows — Phase A owns the producer.**
- `[assumed — dependency]` `events.jsonl::sandbox_denial` rows will
  carry a `claude_version` field. **Owned by sandbox-detective Phase A.**
  D-003 documents the fallback if not.
- `[assumed — dependency]` A checked-in `expected-claude-version` file
  (path TBD by the pin-claude-version ticket) does NOT exist today.
  **Owned by the pin-claude-version ticket.** Shape C's
  "dependency-not-wired" carve-out (D-005) is the graceful-degradation
  path until the pin ticket ships.
- `[assumed]` Shape B's bash-side dumping of `allowed_tools_for`'s
  output via `source bin/dispatch.sh; for s in …; do allowed_tools_for
  "$s"; done` is safe — i.e., sourcing `bin/dispatch.sh` does NOT fire
  its `main` (sentinel guard at end of file is the pattern). **To
  verify in implementation:** check `bin/dispatch.sh` ends with the
  test sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main
  "$@"; fi`. If not, Shape B's driver must take a different approach
  (e.g., bash subprocess invoking a one-off script that prints each
  stage's tools).
- `[assumed]` The `bin/agent-prompts-content-test.sh:1556-1607`
  PROMPT_RESOLVERS + AGENT_RUNTIME_TOKENS consistency check will
  accept the four-token-wide `AGENT_RUNTIME_TOKENS` string per D-007.
  **To verify in implementation:** run the test pre-commit.
- `[assumed]` `claude --version` on the dispatch host emits a
  single-line version string that's stable across invocations
  (no embedded date or wall-clock-dependent token). **To verify in
  implementation:** invoke `claude --version` manually and confirm.
  If output contains a timestamp, Shape C's diff must normalize.
- `[assumed]` The four input dumps Shape B's driver writes
  (`allowed_tools_dump.txt`, `tokens_in_use_dump.txt`,
  `resolvers_dump.txt`, `add_dir_dump.txt`) are small enough to fit
  in the dispatch's context window (each ~1–5 kB). **To verify in
  implementation:** measure the line counts of each dump.
- `[assumed]` The §9 prompt extension does NOT trip
  `bin/agent-prompts-content-test.sh`'s other invariants (line count
  limits, header positions, etc.). **To verify in implementation:**
  run the test pre-commit.
- `[assumed]` Soft-degrade is acceptable to the operator as the
  failure semantic. Confirmed by the ticket body's "OUT" section
  ("Promoting any shape from observation to halt-loud — not the
  retrospective's job"). Reading the ticket's literal "OUT" as
  affirmation of "do NOT halt on retrospective shape failures";
  reasonable interpretation but operator-confirmation worth in OQ-5.

## 10. Scope size & split recommendation

Per CLAUDE.md "Ticket sizing rubric (autonomy boundary)":

**Axis 1 — Subsystems touched.** All three shapes touch the same
subsystem (retrospective: `bin/retro-prompts/`,
`bin/retro-shape-*.sh`, `bin/retro-shape-*-test.sh`,
`bin/run-retrospective-local.sh`,
`AGENT_PROMPTS.md` §9, `bin/render-prompt.sh::AGENT_RUNTIME_TOKENS`).
**1 subsystem.** Autonomy-safe per axis 1 alone.

**Axis 2 — Independent design decisions.** Three independent design
decisions:

1. Shape A's events.jsonl filter + bucket dimension (D-002, D-003) +
   its sandbox-detective Phase A dependency.
2. Shape B's bash-side gathering + claude-side reasoning (D-004) +
   the input-dump file layout.
3. Shape C's two-string diff + its pin-claude-version dependency
   (D-005).

The orchestration (D-006), token registration (D-007), and dispatch
routing (D-008) are SHARED — one decision applied uniformly. So 3
INDEPENDENT + 3 SHARED. **3 independent design decisions; the rubric
says "split before filing" at 2+.**

**Umbrella veto.** The ticket body says "Filing as one tracking
ticket per user direction; treat as umbrella if split." This
voluntarily flags umbrella intent.

**Recommendation: SPLIT before planning** into three sub-tickets:

| Sub-ticket            | Scope                                | Blocker                                 |
|---                    |---                                   |---                                      |
| ENG-158a (Shape A)    | tool-denial-trends shape (D-002/3)   | sandbox-detective Phase A ticket (file separately) |
| ENG-158b (Shape B)    | runtime-invariant-audit shape (D-004) | none — independent                     |
| ENG-158c (Shape C)    | claude-version-drift shape (D-005)   | pin-claude-version ticket (file separately) |

ENG-158 remains as the umbrella tracking ticket; the three new
sub-tickets become first-class. The shared decisions (D-001, D-006,
D-007, D-008, D-010) are common context to all three — copy into each
sub-ticket's brainstorm scope, since each sub-ticket's planning stage
gets its own brainstorm.

Splitting also CHEAPENS the dependency story: ENG-158b (Shape B) has
no blocker and can ship first. ENG-158a / ENG-158c block on the
respective dependency tickets — those tickets can be filed in
parallel, and Shape A / C can land as soon as their producer lands,
independently.

Alternative: keep as a single ticket. Acceptable if the operator
explicitly directs (the ticket body suggests they're aware of the
sizing). The risk: one shape's blocker (e.g., sandbox-detective Phase A
slips) stalls the entire ticket. The split insulates the other shapes
from that.

## 11. Proposed ADRs

`docs/knowledge/decisions.md` does not exist in this tree (per §9
Verified). No new ADR is required; this brainstorm extends an
existing pattern (ENG-129 — ADR-001 proposed in that brainstorm) and
the per-shape soft-degrade extension (D-006) is captured in CLAUDE.md
(D-010 item 13). No new proposed ADR.

## 12. Persona review

Personas in mandated order: design → security → scope → coherence →
product → feasibility (feasibility is the gating persona).

### Iteration 1

#### design — PASS

D-001 through D-010 compose. D-001 (shape count + naming) is the
top-level decision; D-002/D-003 (Shape A specifics), D-004 (Shape B
specifics), D-005 (Shape C specifics) are per-shape decisions; D-006
(orchestration + failure semantics) is the integration decision;
D-007 (token registration) and D-008 (dispatch consistency) are
layered uniformity decisions; D-009 (tests) and D-010 (scope fence)
are completion decisions.

The three new shapes faithfully replicate the ENG-129 pattern
across three orthogonal drift classes. No new abstractions invented;
no new mechanism cross-cuts the three shapes. The pattern's
properties (per-shape independence, per-shape testability,
per-shape artifact) hold across the three new instantiations.

D-006's per-shape failure semantics is the substantive design
extension. The ENG-129 D-006 "shape failures HALT the parent" line
was implicitly universal; this ticket's D-006 makes it per-shape.
Documented in CLAUDE.md (D-010 item 13). The divergence is intentional
and justified.

No P0 / P1. Two P2 design notes:
- P2-design-1: Shape B's "driver gathers + agent reasons" pattern
  is heavier than Shape A's "agent does it all from inputs". The
  asymmetry is intentional (D-004 inputs need pre-staging) but a
  later refactor might unify on one of the two shapes. OQ-1
  (shared helpers).
- P2-design-2: The three shapes share argv-parsing boilerplate (per
  `bin/retro-shape-stage-failure-summary.sh:11-30` template). If a
  fourth shape lands, factor out a `bin/retro-shape-helpers.sh`.
  Already captured in OQ-1.

#### security — PASS

No new auth surface. The three new dispatches inherit
`bin/dispatch.sh::retrospective`'s allowed-tools (line 543), which
already carries the ENG-48 isolation flags
(`--setting-sources project,local`, `--disable-slash-commands`,
`--disallowed-tools <list>`).

Each shape's Write target is constrained to
`$PROJECT_STATE_DIR/retrospective-${today}/<shape>.md` by the prompt
body's instruction. The `--allowed-tools` Write capability is broader
but the prompt-side restriction is the operative constraint (same
pattern as `stage-failure-summary` and every other dispatched agent
stage).

Shape A reads `events.jsonl` — operator-trust-boundaried (harness
written). Shape B reads harness source files — operator-trust
likewise. Shape C reads `$EXPECTED_PIN_FILE` (operator-checked-in)
and shells out to `claude --version` (claude binary
trust-boundaried; same as every other dispatch).

Token interpolation via `sed -e "s|{token}|val|g"` — token values
are deterministic strings (paths under `$PROJECT_STATE_DIR`, ISO
timestamps, file contents from harness-controlled files). Same
guarantees as ENG-129 D-007 (sed-meta safety).

Shape C's `claude --version` shell-out: the driver captures stdout
into a bash variable; not eval'd; not concatenated into shell strings
without quoting. Standard hygiene.

Shape B's `source bin/dispatch.sh` to invoke `allowed_tools_for`: relies
on the sentinel-guard at end of `bin/dispatch.sh`. If a future edit
removes the sentinel, `source` would fire `main` — but
`bin/agent-prompts-content-test.sh` and the existing test suite would
catch the change. Sentinel-removal is detected as a structural
regression by the existing tests.

No PII surface. The retrospective binary already handles cross-issue
metric aggregation; the three new shapes don't broaden that.

`PIPELINE_DISPATCH_ID` stays unset for retrospective dispatches per
ENG-129's `PIPELINE_ISSUE_ID` carve-out (`bin/dispatch.sh:573-574`
comment). Same property; no ENG-87 contract violation.

No P0 / P1 / P2 findings.

#### scope — PASS

Linear AC walkthrough:

- AC #1 ("Three new shapes ship following the ENG-129 prompt + driver +
  sibling test pattern; each produces a markdown artifact and is Read
  into §9"): D-001 names the three; D-009 names the test inventory;
  D-006 names the §9-side artifact splicing; D-007 registers the four
  runtime tokens; D-010 explicit scope fence.
- AC #2 ("Each shape's sibling test passes; pre-commit hook suite stays
  green"): D-009 reuses the ENG-129 fixture template, including the
  `bin/agent-prompts-content-test.sh` AGENT_RUNTIME_TOKENS consistency
  check; D-007's one-line edit is the only edit to a shared registry.
- AC #3 ("A live retrospective run consumes all three artifacts and
  surfaces at least one finding per shape if drift exists in the past
  7 days"): D-006's orchestration makes all three artifacts available
  to §9; the §9 prompt-body edit explicitly instructs the agent to
  Read each.

Out-of-scope discipline:
- No new shape coordinator (D-010 explicit).
- No promotion of any shape from observation to halt-loud (D-010
  explicit; matches ticket "OUT").
- No replacement of the §9 narrative with shape-only output (D-010
  explicit; matches ticket "OUT").
- No new metric event (D-002 / Shape A consumes
  sandbox-detective Phase A; doesn't emit).

§10's split recommendation is in-scope as a sizing observation per
the ticket body's own sizing note ("treat as umbrella if split"). The
brainstorm doesn't unilaterally split; it surfaces the recommendation
for the planning stage to act on.

One P2 scope note: §10's recommendation that the planning stage SPLIT
into ENG-158a/b/c sub-tickets is a meta-decision about ticket
mechanics, not architecture. It's a recommendation, not a commit; the
operator/planning stage may choose to keep as one ticket. Clearly
flagged. P2.

No P0 / P1 findings.

#### coherence — PASS

Internal cross-checks:

- D-002's filter (`.event == "sandbox_denial"`) is consistent with
  `bin/metrics.sh:67`'s row shape verified in §9.
- D-003's bucket key (`claude_version × stage`) is consistent with
  D-002's dependency on sandbox-detective Phase A emitting
  `claude_version`. D-005's claude-version-drift shape provides a
  semantic join key for §9's analysis (when both shapes name
  `claude_version <X>`, §9 can correlate).
- D-006's per-shape failure policy is consistent with D-010's "ADD
  coverage" framing: a soft-degrade keeps the §9 dispatch running
  with reduced data; a halt would lose §9 entirely. Symmetric to the
  shape-pattern's "isolation" property in ENG-129.
- D-007's `AGENT_RUNTIME_TOKENS` extension is consistent with
  `bin/render-prompt.sh:78`'s existing one-line declaration; one
  text edit; no resolver functions.
- D-008's dispatch-routing consistency is the same principle as
  ENG-129 D-004 (don't fragment the orchestration pattern across
  shape sizes).
- D-009's test inventory mirrors `bin/retro-shape-stage-failure-summary-test.sh`
  fixture by fixture; the per-shape adaptation list is enumerated.

§9 paragraph-edit consequence: three "Read these files" bullets get
added between today's items 6 and 7 (or as 1a/1b/1c near the existing
pre-computed-artifact reference). Fence count stays at 2; line count
grows by ~15 lines; `bin/agent-prompts-content-test.sh` continues to
pass.

One P2 coherence note: the §9 placement of where each artifact's
findings get spliced (Shape A → Systemic findings, Shape B → Bias
findings, Shape C → top of Systemic findings) is prescriptive in the
brainstorm but isn't enforced — the agent could choose differently.
Same risk as ENG-129's "agent could ignore the artifact". Mitigation:
the §9 prompt body's wording explicitly says "incorporate verbatim".
P2.

No P0 / P1 findings.

#### product — PASS

The PoC's user (operator) gets:

- **Observability of three new drift classes** that today's
  retrospective cannot see: tool denials, runtime-invariant drift,
  claude version drift.
- **Per-class actionability**: each shape's artifact is in its own
  file; if Shape A finds nothing, the operator skims past it; if
  Shape C finds drift, the operator inspects the version pin.
- **Forward-compatibility with the coordinator ticket**: three new
  shapes is the inflection point at which a shared helper / coordinator
  becomes attractive (rule of three). Each new shape's structure is
  the template the coordinator will refactor.
- **Soft-degrade ergonomics**: a dependency that hasn't shipped
  (Phase A, pin) doesn't break the weekly retrospective. The shape
  emits an explicit "dependency not wired" marker — operator notices,
  files / prioritises the dependency ticket.

PoC explicitly does NOT introduce:
- Operator-facing config knobs (no per-shape enable/disable, no
  per-shape model tier).
- New Linear markers or labels.
- New Slack shapes beyond `info` (info, not error, on per-shape
  failure).
- Changes to the weekly schedule.

No P0 / P1 / P2 findings.

#### feasibility — PASS

Gating persona; codebase-fact errors here are always P0.

Every code reference in the brainstorm has been verified against the
current tree per the Assumption Inventory §9 — verified items have
`path:line` quotes; assumed items are either (a) new files to be
created in implementation, or (b) dependencies external to this ticket,
or (c) behavioral claims to verify at implementation time.

Symbol cross-check (D-002 — events.jsonl filter):
- `events.jsonl` schema verified at `bin/metrics.sh:43,67`. The schema
  has `.event` (string) — confirmed.
- `bin/dispatch.sh:62` confirms `permission_denials` is intentionally
  EXCLUDED from `usage-<stage>.json` today, and
  `bin/dispatch-test.sh:554` fixture confirms the field exists in
  stream-json `type:result`. The producer (sandbox-detective Phase A)
  has a real parse target.

Symbol cross-check (D-004 — Shape B inputs):
- `bin/dispatch.sh:515-545` `allowed_tools_for` verified; the case
  arm pattern is consistent enough to enumerate by `for s in
  brainstorming planning implementing ui reviewing qa building released
  retrospective; do allowed_tools_for "$s"; done`.
- `bin/render-prompt.sh:41-58` `PROMPT_RESOLVERS` registry verified;
  Shape B can extract `awk` slice between `^PROMPT_RESOLVERS=` and the
  closing `'`.
- `bin/render-prompt.sh:78` `AGENT_RUNTIME_TOKENS` verified.
- `bin/dispatch.sh:743` `cmd+=(--add-dir "$issue_state_dir")` verified.

Symbol cross-check (D-005 — pin file):
- `claude --version` is a valid CLI invocation (stable CLI per the
  `claude` binary already in use on the dispatch host).
- Pin file path is owned by the pin-claude-version ticket per the
  ticket body. Shape C takes the path as a flag — flexible.

Symbol cross-check (D-007 — token registration):
- `bin/render-prompt.sh:78` shows the EXACT string format
  `AGENT_RUNTIME_TOKENS=' file pr_number stage_failure_summary_path '`;
  D-007's one-line edit adds three space-separated names, preserving
  the leading + trailing space invariant called out in
  `bin/render-prompt.sh:74-77`.
- `bin/agent-prompts-content-test.sh:1556-1607` cross-checks every
  `{token}` in `AGENT_PROMPTS.md` against the PROMPT_RESOLVERS ∪
  AGENT_RUNTIME_TOKENS union; the extended `AGENT_RUNTIME_TOKENS`
  captures the four §9 path tokens.

Symbol cross-check (D-008 — dispatch reuse):
- `bin/retro-shape-stage-failure-summary.sh:101-106` shows the exact
  call shape `bash "$SCRIPT_DIR/dispatch.sh" retrospective "$rendered"
  "$log"`. Mirrored verbatim.

Symbol cross-check (D-009 — test fixtures):
- `bin/retro-shape-stage-failure-summary-test.sh:36-50` fixture stub
  + `bin/retro-shape-stage-failure-summary-test.sh:67-69`
  source-and-stub pattern — the new tests mirror this byte-for-byte
  with name substitution.

NEW symbols to be created in implementation (per D-001/D-009 — three
prompt bodies + three drivers + three tests; total 9 new files);
each named in §9 Assumption Inventory under "Assumed — needs
verification / owned by external dependency".

No P0 / P1 / P2 findings.

### Iteration 1 verdict

All six personas: PASS. Feasibility persona: zero P0 findings.

**Gate status: 6/6 PASS · gate P0: 0 · proceeding to planning**

No iteration 2 required.

## 13. Summary

This brainstorm proposes adding three sibling retrospective shapes to
the ENG-129 pattern:

- **Shape A — `tool-denial-trends`** consumes
  `events.jsonl::sandbox_denial` rows (produced by the
  sandbox-detective Phase A dependency) and buckets by `claude_version
  × stage`.
- **Shape B — `runtime-invariant-audit`** cross-checks
  `AGENT_PROMPTS.md` token usage against `bin/dispatch.sh::allowed_tools_for`,
  `bin/render-prompt.sh::PROMPT_RESOLVERS`, and `--add-dir` paths.
- **Shape C — `claude-version-drift`** compares `claude --version`
  against a checked-in expected value (produced by the
  pin-claude-version dependency ticket).

Each shape mirrors `stage-failure-summary` shape-for-shape: prompt
body + driver + sibling test + artifact under
`$PROJECT_STATE_DIR/retrospective-${date}/<name>.md`. The four
artifacts (existing + three new) are spliced into §9 via the
`AGENT_RUNTIME_TOKENS` allowlist (`bin/render-prompt.sh:78`).

Failure semantics diverge from `stage-failure-summary` — the three
new shapes SOFT-DEGRADE on driver failure (parent writes a marker
artifact, §9 still runs). The existing `stage-failure-summary`
keeps HALT semantics.

§10 recommends splitting into three sub-tickets (ENG-158a/b/c) per
the sizing rubric (3 independent design decisions). Shape A blocks
on sandbox-detective Phase A; Shape C blocks on pin-claude-version;
Shape B has no blocker. Splitting insulates the three shapes from
each other's dependency slip.

Pre-existing ADRs (ENG-26, ENG-48/65, ENG-81, ENG-87, ENG-94, ENG-100,
ENG-103, ENG-129, ENG-155) are unchanged. CLAUDE.md "Retrospective
shapes (ENG-129)" § gets a one-paragraph extension documenting the
per-shape failure-semantic policy.
