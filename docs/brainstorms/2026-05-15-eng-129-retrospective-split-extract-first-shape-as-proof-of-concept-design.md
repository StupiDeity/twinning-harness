---
linear: ENG-129
title: Retrospective split — extract first shape as proof-of-concept
date: 2026-05-15
status: draft
---

# Retrospective split — extract first shape as proof-of-concept

## 1. Problem

`bin/run-retrospective-local.sh` is one monolithic dispatch: it extracts
the §9 fenced block from `AGENT_PROMPTS.md`, hands the whole prompt to
`dispatch.sh retrospective`, and lets a single `claude -p` agent do
twelve different things end-to-end (stage failure analysis, gotcha
recurrence, convention drift, gotcha promotion, human-override analysis,
expiry verification, confirmation-bias audit, recency-bias check,
survivorship-bias check, knowledge-budget enforcement, pipeline-health
score, prompt/workflow amendment) before committing files and opening a
PR.

The retrospective body is now ~200 lines of prompt at
`AGENT_PROMPTS.md:1722-1929`. Each behavior has its own input set, its
own output artifact, and its own failure mode. Today they share one
context window and one verdict path. Concrete problems:

- A single failure (e.g. a confused gotcha-promotion pass that names a
  non-existent file path) blocks the whole retrospective PR. The other
  eleven behaviors don't get credit for being correct.
- The 12-behavior superset cannot be tested incrementally. No unit-test
  surface exists; the only feedback is the weekly PR.
- New behaviors named in sibling tickets — calibration (ENG-39),
  component audit (ENG-40) — pile up against an already-overloaded
  context window.
- Each behavior would naturally use different reasoning depth (e.g. §1
  failure-class summary is a pure events.jsonl scan, while §6 expiry
  verification needs to grep the codebase). The monolith forces a single
  tier.

ENG-33 is the umbrella decision to split the retrospective into named
"shapes" — independently invocable sub-behaviors with their own prompt,
their own artifact, and their own test surface. This ticket is the
proof-of-concept: extract ONE behavior, prove the architectural pattern,
and leave the rest of the monolith untouched.

The Linear ticket explicitly suggests two candidates: learned-rules
pruning (§6 expiry verification) or the §1 failure-class summary.

## 2. Decisions

### D-001. Pick §1 Stage failure analysis as the first shape.

The §1 behavior in `AGENT_PROMPTS.md:1766-1773` reads
`$PROJECT_STATE_DIR/metrics/events.jsonl`, classifies stage failures
by outcome token, compares against the previous period, and names the
top recurring reasons per stage with ≥3 rejections. The output is a
plain text summary that the parent retrospective splices into its
PR body.

Why §1 is the smallest viable shape:

- **Pure read of one file** (`events.jsonl`). No codebase grep, no
  Linear API call, no git log walk. Inputs are bounded, deterministic,
  and already on disk. Allowed-tools shrink to `Read,Write,Bash(jq:*)`.
- **Output is a single markdown artifact**, not a multi-file edit. No
  rule-file mutations to coordinate, no learned-rules churn to weigh
  against the existing 60-day shelf-life policy.
- **No side effects on the target repo.** The shape's output lives in
  `$PROJECT_STATE_DIR`; the parent retrospective is the only writer of
  rule files. This isolates the proof-of-concept's blast radius — if
  the shape misbehaves, no checked-in artifact is wrong.
- **Reuses today's events.jsonl schema verbatim** (per
  `bin/metrics.sh:67`'s `{ts, event, issue_id, stage, outcome, ...}`).
  No new metric event, no vocabulary registry change.

*Reference to constraint:* CLAUDE.md "Don't add features, refactor, or
introduce abstractions beyond what the task requires" — the smallest
viable shape exercises the new architecture without dragging
rule-mutation or codebase-grep complexity into the proof.

*Rejected alternative — §6 expiry verification (learned-rules
pruning):* the Linear ticket lists §6 as a candidate, but §6 needs to
(a) grep every `expires:` line in every `learned-rules/<slug>/*.md`,
(b) grep the codebase to verify the pattern still exists, (c) propose
an edit to the rule file. The shape script would write to
`learned-rules/`, which the parent retrospective also writes. That
overlap creates a coordination problem (who owns the file edit) that
distracts from the proof-of-concept goal. §6 is the right candidate
for an EARLY shape post-proof, not the first.

*Rejected alternative — §11 Pipeline-health score:* simplest input
schema of all (count `stage:released` vs total `stage:*` entries) but
it's also the LEAST representative — the output is two integers and a
ratio, not a markdown artifact. The architectural pattern doesn't get
exercised meaningfully if the artifact is two lines of text.

*Rejected alternative — §10 Knowledge-budget enforcement:* requires
reading config.json AND every knowledge file AND applying eviction
priority. Three input sources, multiple write targets. Bigger than §1.

### D-002. New directory `bin/retro-prompts/` for shape prompt bodies, parallel to `bin/setup-prompts/`.

`bin/setup-prompts/discovery.md` (`bin/setup.sh:303`) is the existing
precedent for "single-shot agent body lives in its own plain-markdown
file, not inside `AGENT_PROMPTS.md`". The discovery prompt is rendered
via token interpolation in `bin/setup.sh::_render_discovery_prompt`
(`bin/setup.sh:308`) and dispatched via direct `claude -p` invocation,
not through the per-stage allowed-tools registry.

Retrospective shapes mirror this pattern: each shape gets its own
plain-markdown file at `bin/retro-prompts/<shape-name>.md`. The first
file is `bin/retro-prompts/stage-failure-summary.md`.

*Reference to constraint:* `docs/architecture.md:7-14`
("Two binaries, peer roles") — the retrospective is a peer to the
orchestrator, not a stage in it. Its prompt body has historically lived
in `AGENT_PROMPTS.md` §9 by convention, but the file's structural
invariant (per `bin/render-prompt.sh:13-22` `STAGE_TO_SECTION` table and
`bin/dispatch.sh:393-405` per-stage case) is keyed on dispatch stages
1-8. §9 is an outlier kept there for "live near the others" reasons.
Moving shape bodies to `bin/retro-prompts/` makes the AGENT_PROMPTS.md
schema cleaner (sections 1-8 are dispatch stages, period) AND aligns
with the setup-prompts precedent.

*Rejected alternative — add a new H2 section to AGENT_PROMPTS.md (`## 10.
Stage Failure Summary Shape`):* rejected because (a) the `STAGE_TO_SECTION`
table (`bin/render-prompt.sh:13-22`) is keyed on dispatch stages, and
adding §10 would either pollute the schema or sit unreachable, (b) the
fence-extraction logic in `bin/render-prompt.sh::extract_block`
(`bin/render-prompt.sh:91-109`) is a layer of indirection the shape
script doesn't need — shapes don't have per-issue tokens to interpolate,
(c) co-locating shape bodies with dispatch-stage bodies would muddy the
"two binaries, peer roles" distinction documented in
`docs/architecture.md`.

*Rejected alternative — embed the prompt body inline as a heredoc in
`bin/retro-shape-stage-failure-summary.sh`:* rejected because it
violates the discovery.md precedent and makes prompt edits a code
change. Markdown-in-bash is hard to read; prose review is much easier
when the prompt is its own file.

### D-003. New executable `bin/retro-shape-<name>.sh` per shape.

Shape scripts are sibling executables in `bin/`. The first is
`bin/retro-shape-stage-failure-summary.sh`. The naming convention is
`retro-shape-<kebab-case-name>.sh`. Each shape script:

1. Sources `bin/common.sh` (per CLAUDE.md "When wiring a new script").
2. Reads its prompt body from
   `$HARNESS_ROOT/bin/retro-prompts/<shape-name>.md`.
3. Token-interpolates `{events_jsonl_path}`, `{period_start}`,
   `{period_end}`, `{artifact_path}` into the prompt body (parallel to
   `bin/setup.sh::_render_discovery_prompt`).
4. Dispatches `claude -p` via `bash $SCRIPT_DIR/dispatch.sh retrospective
   <rendered-prompt> <log-file>` (reusing the retrospective allowed-tools
   set at `bin/dispatch.sh:403`).
5. Validates that the artifact file was created at the expected path; if
   not, `die` with a clear message.
6. Supports `PIPELINE_DRY_RUN=1` (skip claude invocation, log
   would-do, write an empty placeholder artifact for downstream chain
   to see).
7. Ends with the test sentinel
   `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`
   per CLAUDE.md "How tests work" §1.

*Reference to constraint:* CLAUDE.md "Tests are sibling shell scripts
named `*-test.sh` in `bin/`" + "When a new bash file is meant to be both
executable and unit-testable, replicate the sentinel pattern". The
shape script is both — invoked by `run-retrospective-local.sh` at
runtime AND source-able by tests.

*Rejected alternative — one mega-script `bin/retro-shapes.sh` with a
shape name as the first arg:* rejected because (a) the
`bin/retro-shape-<name>.sh` shape scales better as shapes accumulate
(ENG-33 ships, ENG-39 calibration, ENG-40 component audit, etc. — five
files in `bin/` is fine; a 2000-line dispatcher is not), (b) per-shape
test sibling `bin/retro-shape-<name>-test.sh` is the obvious pairing,
(c) per-shape sibling files match the existing `bin/setup-helpers.sh /
bin/setup.sh` precedent rather than introducing a new
single-file-with-subcommands pattern.

*Rejected alternative — make shapes proper "stages" in `dispatch.sh`
(e.g. add `retro-stage-failure-summary` to
`allowed_tools_for`'s case statement):* rejected because (a) shapes are
NOT pipeline stages; they don't appear in the `stage:*` Linear label
namespace, don't have a verdict, don't loopback, (b) the `STAGE_TO_SECTION`
table is for dispatch-stages keyed by Linear status; shapes are
internal to the retrospective binary, (c) reusing `retrospective`'s
existing allowed-tools captures the right surface (Read, Write,
Bash(jq:*)) without inventing a new case arm. If a later shape needs a
narrower allowed-tools set, that's the time to add a stage; not now.

### D-004. Reuse `dispatch.sh retrospective` for the shape's claude invocation; do NOT introduce a new dispatch stage.

The shape's allowed-tools needs are a strict subset of the retrospective
stage's allowed-tools at `bin/dispatch.sh:403`: Read, Write, Edit, Grep,
Glob, TaskCreate, Agent, Bash(jq:*), Bash(awk:*), and the
`bin/linear.sh` / `bin/pipeline.sh` / `bin/guards.sh` / `bin/metrics.sh`
helpers. The shape uses Read + Write + Bash(jq:*); reusing the broader
set is harmless because the prompt body restricts the agent to the
narrower task.

This means `bin/retro-shape-<name>.sh` invokes
`bash $SCRIPT_DIR/dispatch.sh retrospective <rendered-prompt>
<log-file>` — same call shape as today's
`bin/run-retrospective-local.sh:72`. The shape's prompt body and the
retrospective's prompt body share an envelope; their MESSAGES differ.

*Rationale:* this preserves the ENG-48 isolation flags
(`--setting-sources project,local`, `--disable-slash-commands`,
`--disallowed-tools`), the gtimeout watchdog (ENG-65), the
counting-semaphore acquisition (ENG-81), and the
stream-json renderer's cost telemetry (ENG-26) — all in `dispatch.sh`'s
critical path. Re-implementing any of this in the shape script would be
duplication-bait.

*Reference to constraint:* CLAUDE.md "Tool allowlist & probing
(ENG-53 #11 / ENG-57)" and "Per-stage dispatch timeouts (ENG-65)" both
describe `dispatch.sh` as the chokepoint; the shape script respects
that.

*Rejected alternative — `bin/retro-shape-<name>.sh` invokes `claude -p`
directly with its own `--allowed-tools` string (like setup-discovery
does at `bin/setup.sh:323-340`):* rejected because that path would
duplicate ENG-26 cost capture (already in `dispatch.sh::main`), ENG-65
timeout handling, ENG-81 mutex acquisition, and ENG-87 dispatch_id
plumbing. The setup-discovery exemption was made because discovery
needs a different allowed-tools profile than any pipeline stage and
runs once at setup — neither holds for retrospective shapes. The
retrospective shape is structurally a dispatch (claude -p, prompt-in,
log-out) — route it through `dispatch.sh`.

*Rejected alternative — add a new `retro-shape` case to
`dispatch.sh::allowed_tools_for`:* rejected per D-003's rationale; the
existing `retrospective` case is a superset of what the shape needs.

### D-005. Artifact lives in `$PROJECT_STATE_DIR/retrospective-${date}/<shape-name>.md`.

The shape produces a markdown artifact. The artifact path is
deterministic, per-run, per-shape. Concretely:

`$PROJECT_STATE_DIR/retrospective-${today}/stage-failure-summary.md`

`${today}` is the UTC date the parent
`bin/run-retrospective-local.sh:34` already computes
(`today="$(date -u +%Y-%m-%d)"`). The shape script accepts the date
as an env var or arg from the parent.

Why `$PROJECT_STATE_DIR` and not inside the worktree:

- The parent retrospective checks out main inside `$TARGET_REPO`. Anything
  the shape writes under `$TARGET_REPO` shows up in `git status` and
  has to be carefully gitignored or removed. `$PROJECT_STATE_DIR` has
  no git relationship; it's the harness's state surface.
- The shape's output is operator-visible (for debugging) and
  retrospective-readable (for splicing into the PR body), but it is
  NOT a checked-in artifact. State, not source.
- Mirrors the existing convention: cost telemetry
  (`usage-<stage>.json`) lives in `$PROJECT_STATE_DIR/<issue>/`, logs
  live in `$PROJECT_STATE_DIR/logs/`, the metric stream lives in
  `$PROJECT_STATE_DIR/metrics/`. The retrospective's per-run scratch
  fits the same surface.

*Reference to constraint:* CLAUDE.md "Per-project state must reference
`$PROJECT_STATE_DIR`, never `$HARNESS_STATE_DIR/<issue>` directly".
The per-run retrospective subdirectory respects this.

*Rejected alternative — write the artifact inside the worktree
(`$TARGET_REPO/.retro/<shape-name>.md`) and gitignore it:* rejected
because (a) gitignored worktree files are partition-vulnerable per
ENG-100 (sub-agent debris); the post-stage sweep cannot
`rm`/`checkout --` them on every stage and they leak into the next
dispatch's `Read` surface, (b) checking in `.gitignore` for the
shape's scratch directory is target-repo-side configuration that
shouldn't belong to the harness's behavior model.

*Rejected alternative — write to a `mktemp` directory and pass the
path forward via env var:* rejected because (a) mktemp paths are not
debuggable (the operator can't grep
`$PROJECT_STATE_DIR/retrospective-2026-05-15/` for "what did the shape
think the failures were?") if the retrospective fails mid-flight, (b)
mktemp paths get cleaned up; the operator-visible artifact has value
between runs for verification.

*Rejected alternative — commit the artifact to a branch under
`docs/retrospective-runs/`:* rejected as scope creep. The retrospective
already commits proposals to learned-rules; adding a per-run
scratch-artifact commit doubles the commit volume on the PR for no
operator benefit (the artifact's content is summarized in the PR body
anyway).

### D-006. `run-retrospective-local.sh` invokes the shape script BEFORE dispatching the parent retrospective; the parent prompt is amended to READ the artifact instead of recomputing §1.

The orchestration flow becomes:

```
run-retrospective-local.sh::main()
  1. fresh-checkout guard (unchanged)
  2. checkout/reset working branch (unchanged)
  3. NEW: bash retro-shape-stage-failure-summary.sh
       → produces $PROJECT_STATE_DIR/retrospective-${today}/stage-failure-summary.md
  4. extract §9 fenced block from AGENT_PROMPTS.md (unchanged path)
  5. NEW: token-interpolate {stage_failure_summary_path} → step 3's artifact
  6. dispatch.sh retrospective (unchanged)
  7. commit-or-no-op + PR (unchanged)
```

The parent retrospective's §1 body in `AGENT_PROMPTS.md` changes from
"Parse events.jsonl events: which stages..." (do the analysis) to "Read
the stage-failure-summary artifact at
`{stage_failure_summary_path}` (pre-computed by the
`stage-failure-summary` shape) and incorporate its findings verbatim
into your Systemic findings §". The §1 inline analysis logic moves
into `bin/retro-prompts/stage-failure-summary.md` verbatim. The OUTPUT
the parent emits in the final PR is unchanged.

This is the cleanest cut consistent with the Linear ticket's AC #2
("Existing retrospective output is unchanged — the shape produces the
same artifact"). The mechanism changes; the content stays.

*Reference to constraint:* CLAUDE.md "Don't ship half-finished
implementations" — if the parent retrospective continues to recompute
§1 inline AND the shape also computes §1, that's a half-finished
delegation. The shape either replaces the inline behavior or it
doesn't.

*Rejected alternative — shape runs IN PARALLEL with the parent
retrospective's §1 inline analysis; outputs are diffed post-hoc to
verify equivalence:* rejected because (a) two dispatches of the same
work on the same data is wasted spend, (b) "verify equivalence" is a
non-deterministic Comparison of prose outputs — hard to assert. The
delegation cut is the right test of the architecture.

*Rejected alternative — token-interpolate the artifact CONTENT (not the
path) into the parent prompt:* rejected because (a) the artifact is
markdown; embedding it inside a markdown prompt block risks fence
collisions in `AGENT_PROMPTS.md`'s extract_block, (b) prompt-token
substitution is character-bounded; embedding a multi-page artifact
inflates the prompt for no reason — the agent can Read the file in <
one tool call, (c) the path-based reference matches the
`{learned_rules_dir}` precedent (`bin/render-prompt.sh:226`).

*Rejected alternative — keep §1 inline in the parent prompt AND ALSO
introduce the shape as a parallel option to be enabled later via a
config flag:* rejected as half-finished. The proof-of-concept goal is
"prove the pattern by delegating ONE behavior". A behavior that
remains inline isn't delegated.

### D-007. Token interpolation for the shape prompt happens in `bin/retro-shape-stage-failure-summary.sh`, NOT in `render-prompt.sh`.

`render-prompt.sh` is for stage prompts addressing a per-issue context
(issue_id, branch_name, dispatch_id, etc.). Retrospective shapes have
no issue context — they have a period (start/end), an artifact path,
and a metrics-stream path. Different rendering surface.

Token surface for the first shape:

| Token                       | Meaning                                                                 |
|---                          |---                                                                      |
| `{events_jsonl_path}`       | Absolute path to `$PROJECT_STATE_DIR/metrics/events.jsonl`              |
| `{period_start_iso}`        | ISO 8601 UTC timestamp marking start of the analysis period            |
| `{period_end_iso}`          | ISO 8601 UTC timestamp marking end of the analysis period              |
| `{artifact_path}`           | Absolute path where the shape MUST write its output markdown           |
| `{previous_period_path}`    | Optional — previous run's `stage-failure-summary.md` for trend comparison; empty string if first-ever run |

The shape script uses `sed` substitution against the prompt template
(same shape as `bin/setup.sh::_render_discovery_prompt`,
`bin/setup-helpers.sh` for the discovery template). Token names are
snake-case curly-bracketed identifiers, matching the
`bin/setup-prompts/discovery.md` precedent (`{target_repo_path}`,
`{slug}`, `{date}`, `{learned_rules_dir}`).

*Reference to constraint:* `bin/render-prompt.sh:41-54`
`PROMPT_RESOLVERS` registry — every token must be resolvable. Adding
shape-specific tokens (`{events_jsonl_path}`, `{period_start_iso}`,
...) to that registry is wrong because they're not resolvable in a
per-issue dispatch context. Keep the rendering surfaces separated.

*Rejected alternative — extend `render-prompt.sh` with a `retrospective`
mode that registers shape-only tokens:* rejected because (a)
`render-prompt.sh` has well-documented per-issue semantics; broadening
it would muddy the existing contract, (b) `bin/setup.sh` proves the
"local token interpolation helper next to the caller" pattern works.

### D-008. Period of analysis matches the existing retrospective's default — since the last retrospective PR merged, or last 30 days if none.

Today the parent retrospective body computes period from
`git log --merges --format='%H %s' | grep 'weekly retrospective' | head
-1` (per `AGENT_PROMPTS.md:1757-1758`). The shape script needs the same
period.

The shape script computes the period (via the same git-log shape) and
passes it as `{period_start_iso}` / `{period_end_iso}` to the
shape prompt. This is the inflection point: today the §1 instructions
imply "since the last retrospective"; the shape makes the period
explicit by injecting timestamps. The shape's behavior is more
deterministic; the parent retrospective's other behaviors (§2-§12) can
follow the same pattern in future shapes.

*Rationale:* the existing implicit "period" semantics rely on the agent
correctly executing the git log + grep shape inside the prompt. By
moving the period computation to bash and passing timestamps in
explicitly, the shape's reasoning surface shrinks. This is a
mechanical-vs-judgment separation along the same line as ENG-86
(orchestrator runs gh-pr-check in bash; agent runs gh-pr-merge with
prose).

*Reference to constraint:* CLAUDE.md "Defense-in-depth: when a stage's
contract says ... prefer a transcript-based assertion ... over a
post-dispatch state check." Same direction: prefer deterministic
bash-side computation over prompt-instructed agent computation when
the computation is mechanical (date math).

*Rejected alternative — leave period computation inside the shape
prompt (do the grep inside the agent):* rejected because (a) the
agent would have to invoke `git log` inside the dispatch (which is
allowed by retrospective's allowed-tools but adds an unnecessary
mechanical step), (b) the start/end-of-period semantics are about to
become a SHARED concern across many shapes (gotcha recurrence, human
override, etc. all need period); centralizing in the shape script (or
later in a coordinator) prevents drift.

### D-009. Tests in NEW `bin/retro-shape-stage-failure-summary-test.sh`.

Sibling test to the shape script, following the
`bin/dispatch-test.sh` / `bin/run-stage-test.sh` source-and-stub pattern
(CLAUDE.md "Tests are sibling shell scripts" §). The test:

1. Sources the shape script via the sentinel pattern.
2. Stubs `bin/dispatch.sh` under `STUB_DIR` so the test asserts the
   shape invokes dispatch with the right args and intercepts the
   would-be `claude -p` call.
3. PIPELINE_DRY_RUN=1: asserts the would-do log line includes the
   resolved prompt path and the resolved artifact path; asserts no
   claude invocation; asserts the placeholder artifact is created.
4. Token interpolation: asserts that `{events_jsonl_path}`,
   `{artifact_path}`, `{period_start_iso}`, `{period_end_iso}`, and
   `{previous_period_path}` are all resolved in the rendered prompt
   (no leftover braces).
5. Artifact production: in dry-run, asserts the artifact path exists
   with placeholder content; in non-dry-run (stub claude that simply
   creates the artifact file), asserts the post-shape check passes.
6. Missing-artifact failure: stub claude that does NOT create the
   artifact file → asserts the shape `die`s with a clear message.

Fixtures cover all three AC bullet points:
- "shape invocation" → fixture #1, #2 (token resolution + dispatch
  call shape)
- "artifact production" → fixture #5 (artifact-exists assertion)
- "dry-run support" → fixture #3 (PIPELINE_DRY_RUN=1 path)

*Reference to constraint:* CLAUDE.md "Each `bin/foo.sh` ends with the
sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`.
That lets a test `source` the file to get its functions without firing
`main`." The shape script follows this contract.

*Rejected alternative — integration test that actually invokes
`claude -p`:* rejected per existing test-suite convention; all
`bin/*-test.sh` use `PIPELINE_DRY_RUN=1` + stub claude. A real-claude
test would burn subscription credit on every CI run for no incremental
verification value.

### D-010. Scope fence: §1 only; §2-§12 stay inline.

The Linear ticket's "OUT" section is explicit: "Coordinator pattern +
migrating all behaviors (next sub-ticket)" and "New behavior categories
(calibration, component audit — separate tickets via ENG-39, ENG-40)".

This proof-of-concept ships:
- `bin/retro-prompts/stage-failure-summary.md` (new)
- `bin/retro-shape-stage-failure-summary.sh` (new)
- `bin/retro-shape-stage-failure-summary-test.sh` (new)
- Minimal edits to `bin/run-retrospective-local.sh` (invoke shape +
  inject artifact path into rendered prompt)
- Minimal edits to `AGENT_PROMPTS.md` §9 §1 paragraph (replace
  inline analysis with "Read the artifact at
  `{stage_failure_summary_path}`")
- One CLAUDE.md paragraph documenting the shape directory layout

This proof-of-concept does NOT ship:
- A "coordinator" abstraction that knows about all shapes
- A generic shape-runner that dispatches by name
- Any other shape (gotcha-recurrence, convention-drift, expiry,
  bias-audit, knowledge-budget, health-score, prompt-amendment)
- Per-shape allowed-tools profiles in `dispatch.sh`
- Per-shape verdict markers
- Calibration (ENG-39) or component-audit (ENG-40) shapes

*Reference to constraint:* CLAUDE.md "Ticket sizing rubric" — this
ticket is 1 subsystem (retrospective) + 1 design decision (the
shape-extraction pattern). Adding the coordinator pattern, OR a
second shape, OR new behaviors would push the ticket toward the "2+
subsystems / 2+ independent decisions → split" threshold. Resist
scope creep.

*Rejected alternative — also extract §6 expiry verification "since
we're here":* rejected per the rubric. Two shapes is two independent
designs; the second shape's coordination story (how does
run-retrospective-local.sh invoke an ordered sequence of shapes?) is
the coordinator ticket's domain.

## 3. Architecture

### Files added

1. **`bin/retro-prompts/stage-failure-summary.md`** — plain markdown
   prompt body. Contains:
   - The shape's preamble (read the events.jsonl, classify by outcome
     token, compare period to previous, name top reasons per stage).
   - Tokens: `{events_jsonl_path}`, `{period_start_iso}`,
     `{period_end_iso}`, `{artifact_path}`, `{previous_period_path}`.
   - Output instruction: "Write your markdown summary to
     `{artifact_path}` and exit. Do NOT modify other files. Do NOT
     post Linear comments. Do NOT commit."
   - Schema for the output artifact (what headers, what cells).

2. **`bin/retro-shape-stage-failure-summary.sh`** — orchestration
   wrapper.
   - `set -euo pipefail`; sources `bin/common.sh`.
   - `main()`: resolves period (since last retrospective PR or 30d
     default), computes `events_jsonl_path` and `artifact_path`,
     renders the prompt via `_render_prompt()`, invokes
     `bash $SCRIPT_DIR/dispatch.sh retrospective <rendered> <log>`,
     validates the artifact was written.
   - `_render_prompt()`: `sed -e "s|{events_jsonl_path}|...|g" -e
     "s|{period_start_iso}|...|g" ...` against the template. Use `|`
     as sed delimiter because paths contain `/` (parallel to
     `bin/setup-helpers.sh` discovery rendering).
   - PIPELINE_DRY_RUN=1: log the would-do line, write a placeholder
     artifact (so downstream chain validation sees an artifact), skip
     dispatch.sh.
   - Test sentinel at EOF.

3. **`bin/retro-shape-stage-failure-summary-test.sh`** — sibling test
   per D-009. Fixtures listed there.

4. **`bin/retro-prompts/.gitkeep`** — empty file so the directory ships
   in git. (Plain directories without files don't get tracked.)
   Alternative: add a `README.md` to the directory explaining the
   shape-prompt convention. Defer to D-013 / OQ-3.

### Files modified

5. **`bin/run-retrospective-local.sh`** — invoke the shape BEFORE the
   §9 dispatch. Concretely, between lines 58 (after the working-branch
   checkout) and line 60 (before the prompt extraction):

   ```bash
   # ENG-129: pre-compute stage-failure-summary as a shape artifact.
   # The parent retrospective Reads the artifact and incorporates §1
   # verbatim. Shape failures HALT the retrospective for operator
   # review — partial retrospectives are worse than re-running next
   # week.
   local shape_artifact_dir="$PROJECT_STATE_DIR/retrospective-${today}"
   local stage_failure_summary_path="${shape_artifact_dir}/stage-failure-summary.md"
   mkdir -p "$shape_artifact_dir"
   if ! bash "$SCRIPT_DIR/retro-shape-stage-failure-summary.sh" \
        --artifact-path "$stage_failure_summary_path" \
        --period-start-iso "$_period_start" \
        --period-end-iso   "$_period_end"; then
     bash "$SCRIPT_DIR/slack.sh" error "Weekly retrospective shape stage-failure-summary failed (log: $log_file)"
     exit 20
   fi
   ```

   Then in the existing prompt-rendering block (line 61 onwards),
   pipe the extracted §9 fenced block through one additional
   `sed` substitution to interpolate `{stage_failure_summary_path}`
   with the absolute path.

   Period computation: extract `$_period_start` and `$_period_end`
   via the same `git log --merges` shape AGENT_PROMPTS.md §9 currently
   names in prose (D-008). New helper `_compute_retro_period()` in
   the same file; emits two ISO timestamps on stdout, one per line.

6. **`AGENT_PROMPTS.md`** §9, §1 paragraph
   (`AGENT_PROMPTS.md:1766-1773`) — replace the existing
   stage-failure-analysis instructions with:

   > **1. Stage failure analysis (pre-computed):**
   > Read the stage-failure-summary artifact at
   > `{stage_failure_summary_path}` (pre-computed by the
   > `stage-failure-summary` shape this retrospective run). The
   > artifact contains the period's outcome breakdown, period-to-period
   > comparison, and top-2 recurring reasons per stage with ≥ 3
   > rejections. Incorporate its findings verbatim into your "Systemic
   > findings (top 3)" §. Do NOT recompute the analysis.

   §9 prelude (between line 1722 and line 1740) gets one new sentence
   noting "Some sections are pre-computed by retrospective shapes;
   read the artifact at the named path rather than recomputing." The
   existing fence count stays at two (per `bin/render-prompt.sh:91-109`).

7. **`CLAUDE.md`** — one new paragraph under "Retrospective" topic,
   pointing at `bin/retro-prompts/` and naming the shape pattern. ~10
   lines, mirrors the depth of existing "Per-target dispatch.tools
   extras" or "Per-stage dispatch timeouts" paragraphs.

### Files NOT modified (intentional)

- **`bin/render-prompt.sh`** — shape prompt rendering happens in the
  shape script per D-007, not in render-prompt's per-issue registry.
- **`bin/dispatch.sh`** — D-004 reuses the `retrospective` case in
  `allowed_tools_for`; no new case arm, no new env var.
- **`bin/run-stage.sh`** — shapes are NOT pipeline stages (D-003); no
  changes to per-stage code.
- **`bin/pipeline-events.json`** — no new vocabulary. Shapes don't
  emit verdict markers; their success/failure is internal to the
  retrospective binary.
- **`bin/metrics.sh`** — no new metric type. The shape's read of
  `events.jsonl` is consumption, not emission. (Future: a shape-emit
  metric for retrospective observability might be useful, but it's
  scope creep here.)
- **`launchd/com.twinning.retrospective.plist.template`** — same
  binary, same trigger. The internal split is transparent to launchd.
- **`bin/scope-check.sh` / `bin/run-local-helpers.sh::partition_dirty_paths`** —
  shapes run only inside `bin/run-retrospective-local.sh`, which
  doesn't go through the scope-sweep machinery (it's not a per-issue
  dispatch). The shape's artifact in `$PROJECT_STATE_DIR` is not in
  `$TARGET_REPO`, so partition_dirty_paths never sees it.
- **`learned-rules/<slug>/project-profile.md`** — shapes are
  stack-agnostic; the profile doesn't gate the retrospective's tools.
- **`docs/architecture.md`** — the two-binary topology is unchanged.
  The retrospective binary's INTERNAL structure changes; the public
  contract (Mondays at 09:00, output is a PR) does not. A future doc
  update is reasonable once the coordinator ships and 2+ shapes exist,
  but a one-shape proof doesn't warrant rewriting the architecture
  doc.

## 4. Data flow

### Flow 1: weekly retrospective with shape pre-computation (the new common path)

```
launchd (com.twinning.retrospective, Mon 09:00)
  → run-retrospective-local.sh::main()
    → fresh-checkout guard, fetch + checkout working branch
    → _compute_retro_period
        → git log --merges --format='%H %ct %s' \
            | grep 'weekly retrospective' | head -1
        → emit "$start_iso\n$end_iso\n"
    → mkdir -p $PROJECT_STATE_DIR/retrospective-${today}/
    → bash retro-shape-stage-failure-summary.sh \
           --artifact-path "$shape_artifact" \
           --period-start-iso "$start" \
           --period-end-iso "$end"
        → _render_prompt: sed-substitutes tokens into a temp file
        → bash dispatch.sh retrospective <rendered> <log>
          → claude -p (with retrospective's allowed-tools)
            → agent Reads events.jsonl (via {events_jsonl_path})
            → agent jq-filters by ts ∈ [start, end] and outcome
            → agent Writes markdown summary to {artifact_path}
          → stream-json renderer captures usage telemetry
        → shape validates: [[ -f "$artifact" ]] || die
        → return 0
    → extract §9 fenced block from AGENT_PROMPTS.md (existing awk)
    → sed-substitute {stage_failure_summary_path} → $shape_artifact
    → bash dispatch.sh retrospective <rendered-§9> <log>
      → parent agent: Reads $shape_artifact, splices into PR body §1
      → parent agent: runs §2-§12 inline (as today)
      → parent agent: writes proposed rule edits, knowledge file edits
    → git add -A / commit / push / gh pr create
```

The parent retrospective's PR body §1 is BYTE-IDENTICAL to today's
shape (per the shape prompt body being a verbatim move of the §1
instructions). The mechanism — shape produces, parent reads —
differs.

### Flow 2: shape-only invocation (manual / debugging)

```
operator runs:
  TARGET_REPO=/path bash bin/retro-shape-stage-failure-summary.sh \
    --artifact-path /tmp/retro.md \
    --period-start-iso 2026-05-08T00:00:00Z \
    --period-end-iso   2026-05-15T00:00:00Z
  → renders prompt, dispatches claude, writes /tmp/retro.md
```

This is the test/debug path. The shape script is independently
invocable; that's the architectural property the PoC proves.

### Flow 3: dry-run path

```
PIPELINE_DRY_RUN=1 bash retro-shape-stage-failure-summary.sh \
  --artifact-path /tmp/retro.md \
  --period-start-iso ... \
  --period-end-iso ...
  → log "[DRY_RUN] would render prompt with tokens {...}"
  → log "[DRY_RUN] would invoke dispatch.sh retrospective ..."
  → write placeholder content to /tmp/retro.md
    (so the parent retrospective's post-shape Read sees a file)
  → return 0
```

The parent `run-retrospective-local.sh` in dry-run still flows
through the shape invocation; the shape's placeholder artifact
satisfies the post-shape file-exists check.

## 5. Error handling

### Shape claude invocation fails (rc != 0)

`bin/retro-shape-stage-failure-summary.sh::main()` checks dispatch.sh's
exit code. Non-zero → log the rc + log file path → return non-zero. The
parent `run-retrospective-local.sh` checks the shape's exit code (line
~70 in the proposed edit). Failure → Slack error + exit 20 (matches the
existing "dispatch failed → exit 20" path at
`bin/run-retrospective-local.sh:75`).

**Why halt the parent on shape failure (not soft-degrade):** a
half-retrospective PR (with empty §1) is harder to reason about than no
retrospective PR. The launchd schedule re-fires next Monday; one missed
week is not a crisis. Operator sees the Slack error and inspects the
shape's log.

### Artifact file not written by claude (shape claude returned 0 but file is absent)

This is the "agent claimed success but didn't write the file" failure
mode. Shape script validates `[[ -f "$artifact_path" ]]` after
dispatch.sh returns; if absent, `die "shape: artifact not written at
$artifact_path"`. Exits non-zero; parent halts as above.

### events.jsonl missing or empty

The shape's prompt instructs the agent to handle this case verbatim:
"If `{events_jsonl_path}` does not exist or is empty, write a
single-line summary to `{artifact_path}`: 'No events in period:
events.jsonl absent or empty.' Then exit." Mirrors the existing
"insufficient-sample: N=<n>, need ≥5" pattern at
`AGENT_PROMPTS.md:1761`.

### Period computation fails (no prior retrospective merge)

`_compute_retro_period` falls back to "30 days ago → now" per the
existing convention (AGENT_PROMPTS.md:1758-1759). Test fixture asserts
this.

### Shape script and parent retrospective disagree on period

Shape is invoked WITH the parent's computed period (`$_period_start`,
`$_period_end` flow into both). Same source. No disagreement window.

### Artifact path collision across runs

The artifact path includes `${today}` (UTC date). Same-day re-run
overwrites the artifact; this is intentional — the retrospective is
weekly, and same-day re-runs are operator-driven (e.g., debugging a
shape change). The overwrite is the desired behavior.

### Tokens missing in rendered prompt (`{foo}` left unsubstituted)

Shape script renders via `sed -e "s|{token}|...|g"` for each declared
token. After rendering, `grep -n '{[a-z_]\+}' rendered.md` should
return zero lines. If non-zero, `die "shape: unresolved tokens: ..."`.
This is the same render-time validator shape that
`bin/render-prompt.sh:248-...` uses for per-issue token validation.

### Parent retrospective splices stale shape artifact from a prior run

Mitigated by D-005's per-run `${today}` subdirectory + the shape's
write of a fresh artifact at each run. Stale artifacts from PRIOR
weeks remain in `$PROJECT_STATE_DIR/retrospective-2026-05-08/...` but
the parent prompt only references the current `${today}`. Manual
operator could mis-reference an old path; the path is bash-rendered,
not agent-rendered, so the failure mode is bounded.

### Shape's dispatch counts against the claude-semaphore (ENG-81 K=2)

`bin/dispatch.sh::acquire_claude_mutex` is the semaphore acquisition.
The shape's dispatch consumes one slot for the shape's duration. The
parent retrospective then consumes one slot for the parent's duration.
Sequential, not concurrent. Worst case: one tick where K=2 is in use
by other pipeline dispatches will queue the retrospective's shape and
parent calls (acceptable; the retrospective is weekly and not
latency-sensitive).

### `dispatch.sh retrospective` requires `--allowed-tools` to include `Write` of the artifact path

The retrospective allowed-tools at `bin/dispatch.sh:403` includes
`Write` already. No allowlist edit needed. The artifact path's
directory (`$PROJECT_STATE_DIR/retrospective-${today}/`) is `mkdir -p`'d
by the shape script before dispatch, so the agent's `Write` lands
into an existing directory (the agent itself doesn't have to mkdir).

## 6. Edge cases

1. **First-ever retrospective run (no prior merge in `git log`).**
   `_compute_retro_period` returns 30-days-ago → now. Shape runs
   normally; events.jsonl may have N<5 events, shape prompt produces
   "insufficient-sample" string. Acceptable.

2. **events.jsonl is huge (many MB across long-lived deployments).**
   The agent reads via `Read` tool with default behavior. Worst case:
   the shape exceeds dispatch budget. Mitigation: gtimeout fires per
   ENG-65 (retrospective default 30 min); shape returns rc=124;
   parent halts. Long-term mitigation: the period filter narrows
   read scope (jq pre-filter by ts). Out of scope for PoC.

3. **events.jsonl contains records with `outcome` strings unknown to
   the prompt's enumerated list.** Today's §1 prompt names a closed
   outcome set; unknown outcomes get bucketed into "other". The
   shape's prompt carries the same closed set. New outcomes appearing
   in `events.jsonl` (e.g., a future ENG-N adds a metric outcome) get
   bucketed; retrospective continues. The shape's enumeration MUST be
   kept in sync with `bin/common.sh::failure_outcome_for_exit` —
   today's parent §1 has the same dependency. Drift hazard is identical
   to pre-PoC.

4. **Parent retrospective ignores the artifact and recomputes §1
   anyway.** The §9 prompt edit (D-006) explicitly says "Do NOT
   recompute". If the agent recomputes anyway, the PR body still
   contains §1 content — just possibly different from the shape's
   artifact. AC #2 ("output unchanged") would be violated. Detection:
   diff the shape's artifact against the PR body's §1; alert on drift.
   Not in PoC scope but worth a follow-up. Operator-side detection in
   the meantime.

5. **The shape script is invoked with TARGET_REPO unset.**
   `bin/common.sh:11-12` already dies on missing TARGET_REPO. The shape
   inherits this; no extra guard needed.

6. **PIPELINE_DRY_RUN=1 retrospective run on a host where claude isn't
   installed.** Dry-run skips claude per D-009; the placeholder
   artifact is created. Parent in dry-run also skips claude (existing
   `bin/dispatch.sh:511-525`). The retrospective end-to-end dry-run
   stays clean.

7. **Same-day retrospective re-run.** `${today}` is the same date; the
   artifact directory and file overwrite. Idempotent. Matches today's
   parent retrospective behavior at `bin/run-retrospective-local.sh:52-58`
   (branch is reused on same-day re-run).

8. **Operator manually invokes the shape with a non-existent
   `--artifact-path` directory.** Shape script `mkdir -p` the parent
   directory itself before dispatch, OR validates that the parent
   exists and dies clearly. Pick the validate path: `mkdir -p` would
   create unexpected directories on typos; explicit validation is
   safer.

9. **The shape script's prompt template grows new tokens (e.g.,
   `{outcome_taxonomy_path}`) before the shape script is updated.**
   The render-time `grep '{[a-z_]\+}'` validator catches the
   unresolved token; shape dies. Symmetric to
   `bin/render-prompt.sh::resolve_block_tokens` behavior.

10. **A second shape ships in a follow-up (ENG-39 calibration), and
    the operator runs both manually back-to-back.** Each shape script
    is independent; each acquires the claude-semaphore in turn. No
    cross-shape state coupling. The coordinator ticket (ENG-XX) is
    where the SEQUENTIAL invocation order gets formalized.

11. **`bin/dispatch.sh::retrospective` allowed-tools changes (e.g., a
    future ticket adds `Bash(gh:*)`).** The shape inherits the broader
    set; its prompt body still constrains the agent to the narrower
    task. No drift risk for the PoC; relevant only if a shape's prompt
    is silent on a newly-added capability.

12. **`AGENT_PROMPTS.md` fence count check (per
    `bin/render-prompt.sh:91-109`).** The §9 edit replaces the §1
    paragraph in place. Fence count (currently 2 in §9) is preserved.
    Test `bin/agent-prompts-content-test.sh` will run on the change;
    we'll re-run before commit.

13. **The shape's `_render_prompt` uses `sed` with `|` delimiter, but
    a token value contains a literal `|`.** Paths under
    `$PROJECT_STATE_DIR/retrospective-2026-05-15/...` don't contain
    `|`. ISO timestamps don't contain `|`. No collision in the
    rendered substrate. If a future token's value MIGHT contain `|`,
    switch to a delimiter byte that doesn't appear in the value (e.g.
    `\x1f`, the ASCII Unit Separator — same trick as
    `bin/setup-helpers.sh`).

14. **Concurrent retrospective + pipeline tick.** Claude-semaphore
    K=2 caps total claude invocations. If pipeline is at K=2 when the
    retrospective fires, the shape queues for a slot. Acceptable.
    `acquire_claude_mutex` blocks until a slot is free; retrospective
    is not latency-sensitive.

15. **The artifact directory `$PROJECT_STATE_DIR/retrospective-${today}/`
    is NOT cleaned up between weeks.** Each run creates a NEW dated
    directory; old directories accumulate. Disk usage: <1 MB per run
    (markdown summary). Cleanup is operator's call; not in PoC scope.
    A future ticket could add a TTL prune.

## 7. Open Questions

1. **OQ-1. Should the shape's output schema include a machine-readable
   header (YAML frontmatter) declaring `shape: stage-failure-summary`,
   `period_start: ...`, `period_end: ...`, `events_seen: N`?** This
   would let the coordinator (future) inspect shape artifacts without
   parsing the markdown body. Current PoC: emit a header section in
   the markdown body (prose), not formal YAML. Defer formal schema to
   the coordinator ticket where it earns its keep. Not blocking.

2. **OQ-2. Should `bin/retro-prompts/` contain a `README.md`
   explaining the shape-prompt convention (token names, placement of
   the "Write to {artifact_path}" instruction, fence-or-no-fence
   policy)?** The discovery prompt precedent (`bin/setup-prompts/discovery.md`)
   doesn't have a sibling README; the convention is implicit. Mirror
   that for the PoC; add a README if/when a second shape lands and
   patterns diverge. Not blocking.

3. **OQ-3. Should the `mkdir -p $PROJECT_STATE_DIR/retrospective-${today}/`
   happen in `bin/run-retrospective-local.sh` (caller-side) or in
   `bin/retro-shape-stage-failure-summary.sh` (callee-side)?**
   Current proposal: caller-side, so the shape script can be invoked
   standalone with a pre-existing artifact path. Callee-side would
   couple the shape to the harness's per-run subdir convention. Vote:
   caller-side. Not blocking.

4. **OQ-4. The shape's prompt body is moved verbatim from
   `AGENT_PROMPTS.md` §9 §1. Should we also normalize the wording (it
   currently has a few hedges like "most often?", "for each stage with
   ≥3 rejections, name the top 2 recurring reasons") to be cleaner
   imperative form?** Scope creep risk: the PoC's AC #2 says output is
   unchanged. Verbatim move preserves that; rewording risks behavioral
   drift. Vote: verbatim. Defer rewording to a follow-up that
   explicitly asserts no behavior change. Not blocking.

5. **OQ-5. Should the parent retrospective verify the shape artifact's
   FRESHNESS (e.g., `mtime > 1 hour ago`) before splicing?** This would
   guard against a stale prior-week artifact accidentally being
   referenced. Current design avoids the issue via the `${today}`
   subdir + same-day overwrite; freshness check is belt-and-suspenders.
   Vote: skip for PoC; revisit if a stale-artifact bug shows up in
   practice. Not blocking.

6. **OQ-6. Should we add a per-shape entry to `bin/pipeline-events.json`
   for telemetry (e.g., `shape-end` event with outcome `pass|fail`)?**
   Today retrospective overall emits no metric event; shapes
   inherit that. Adding shape-end events is observability work
   that's worth doing eventually but explicitly out of scope per
   D-010. Not blocking.

## 8. ADR stress test

This brainstorm interacts with several existing decisions:

- **ENG-26 (six-field usage-<stage>.json schema with cost telemetry):**
  the shape's dispatch flows through `dispatch.sh retrospective`, which
  reaches the `_render_and_capture_stream` cost capture (gated by
  `PIPELINE_ISSUE_ID` per `bin/dispatch.sh:439`). Retrospective dispatches
  today leave `PIPELINE_ISSUE_ID` unset (per `bin/dispatch.sh:12-13`'s
  comment "Other callers (release, retrospective, mutex-test,
  dry-run-self-check) leave PIPELINE_ISSUE_ID unset"). The shape
  preserves this — no `usage-<shape>.json` is written. **Pressure on
  ENG-26: zero.** Future enhancement: a `usage-shape-<name>.json` shape
  for telemetry could be wired in a follow-up, but it would require
  expanding the gate condition.

- **ENG-48 / ENG-65 (gtimeout watchdog + per-stage timeout
  resolution):** the shape inherits the `retrospective` stage's timeout
  default (30 min per `bin/dispatch.sh:471`). Long retrospective
  events.jsonl scans could approach this budget. Adding a per-stage
  `retrospective`-tier of 60 minutes (mirroring brainstorming/planning's
  60-min cap) is a config-only adjustment if observed. **Pressure on
  ENG-48/ENG-65: zero today; potential future use of the configured
  override path.**

- **ENG-81 (per-project dispatch concurrency, K=2 default):** the
  shape's dispatch consumes one semaphore slot, then releases. The
  parent retrospective consumes a slot, then releases. Sequential. No
  parallelism within the retrospective binary. **Pressure on ENG-81:
  zero.** Future: a coordinator could parallelize independent shapes
  (e.g., stage-failure-summary || gotcha-recurrence), but that's
  ENG-XX's scope.

- **ENG-87 (cross-dispatch staleness, dispatch_id hand-off):** the
  shape's dispatch is internal to the retrospective binary; there's
  no Linear-side state to stamp. `PIPELINE_DISPATCH_ID` remains unset
  for retrospective dispatches (consistent with `PIPELINE_ISSUE_ID`
  unset above). `bin/dispatch.sh:563-565` exports the env var with `${VAR-}`
  empty fallback when unset, so no marker injection happens. **Pressure
  on ENG-87: zero.**

- **ENG-100 (sub-agent debris):** the shape writes EXACTLY one file
  (its artifact) to `$PROJECT_STATE_DIR` (outside any worktree). No
  per-stage allowlist applies because retrospective doesn't go through
  `bin/run-local.sh::partition_dirty_paths`. **Pressure on ENG-100:
  zero — the shape's write surface is the harness state dir, not a
  per-issue worktree.**

- **ENG-103 (per-stage model tiering):** retrospective is intentionally
  out of scope per ENG-103 D-005 ("`released` and `retrospective`
  remain unchanged"). The shape inherits this — subscription default
  applies. If a future ticket wants Haiku-tier for cheap shapes (e.g.,
  the stage-failure-summary scan is pattern-match work, not judgment),
  it would add `dispatch.model.retrospective` config support; that's a
  ENG-103 follow-up, not in this PoC. **Pressure on ENG-103: zero.**

- **`docs/architecture.md` "Two binaries, peer roles":** the
  retrospective binary's INTERNAL structure changes; the EXTERNAL
  contract (Mondays at 09:00, reads metrics, writes a PR) is
  unchanged. The peer-binary distinction holds. **Pressure on the
  two-binary topology: zero.**

- **CLAUDE.md "AGENT_PROMPTS.md is load-bearing" + fence-count
  invariant:** the §9 edit replaces a prose paragraph in place; fence
  count stays at 2. `bin/render-prompt.sh::extract_block`'s schema
  check (`bin/render-prompt.sh:91-109`) continues to pass. **Pressure
  on the AGENT_PROMPTS.md schema: zero.**

No existing ADR is overturned by this PoC. No new ADR is required
beyond ADR-001 below.

## 9. Assumption inventory

Format: `[verified|assumed]` ITEM — `path:line` reference (or
"needs to be created" for assumed/new items).

### Verified — code paths quoted from the current tree

- `[verified]` `bin/run-retrospective-local.sh:62-66` — the awk
  extraction of the §9 fenced block. The shape pre-invocation slots
  in before this block.
- `[verified]` `bin/run-retrospective-local.sh:72` —
  `bash "$SCRIPT_DIR/dispatch.sh" retrospective "$prompt_file"
  "$log_file"` is the existing dispatch shape; the new shape invocation
  reuses it.
- `[verified]` `bin/run-retrospective-local.sh:43-44` —
  fresh-checkout guard (`die` on dirty worktree); the shape runs after
  this guard so no interaction.
- `[verified]` `bin/run-retrospective-local.sh:34` —
  `today="$(date -u +%Y-%m-%d)"`; the shape's artifact directory uses
  the same date variable.
- `[verified]` `AGENT_PROMPTS.md:1722` — `## 9. Retrospective Agent
  (Scheduled)` header; section start.
- `[verified]` `AGENT_PROMPTS.md:1766-1773` — the §1 stage-failure
  analysis paragraph. The shape's prompt body is a verbatim move of
  the listed bullets.
- `[verified]` `AGENT_PROMPTS.md:1742` — events.jsonl path token
  (`~/.twinning-pipeline/metrics/events.jsonl`). The shape uses
  `$PROJECT_STATE_DIR/metrics/events.jsonl` per
  `bin/metrics.sh:43`'s canonical path — the AGENT_PROMPTS.md path is
  stale wording but the agent resolves either via Read. Worth a
  follow-up cleanup; out of scope for PoC.
- `[verified]` `bin/dispatch.sh:403` — retrospective allowed-tools
  base. Includes `Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git
  log:*),Bash(git diff:*),Bash(git show:*),Bash(git rev-list:*),Bash(git
  describe:*),Bash(jq:*),Bash(awk:*),...`. Adequate for the shape's
  needs (Read, Write, Bash(jq:*)).
- `[verified]` `bin/dispatch.sh:375-422` — `allowed_tools_for` is
  the per-stage case statement; the `retrospective` arm exists.
- `[verified]` `bin/dispatch.sh:511-525` — DRY_RUN branch. The
  shape's parent in dry-run flows through dispatch.sh's DRY_RUN; no
  claude invocation. The shape's own DRY_RUN branch is a new helper
  (placeholder write + skip dispatch).
- `[verified]` `bin/dispatch.sh:469-488` — per-stage timeout
  resolution. Retrospective stage defaults to 30 minutes (the
  fall-through arm). Acceptable for the shape's events.jsonl scan.
- `[verified]` `bin/dispatch.sh:439` — `PIPELINE_ISSUE_ID` gating
  for usage capture; retrospective leaves it unset, so no
  `usage-<stage>.json` write. Shape inherits this property.
- `[verified]` `bin/metrics.sh:43,67` —
  `$PROJECT_STATE_DIR/metrics/events.jsonl` is the canonical path;
  row shape is `{ts, event, issue_id, stage, outcome, duration_ms,
  notes, ...}`. The shape's prompt parses by `outcome` and `stage`.
- `[verified]` `bin/setup-prompts/discovery.md` is the precedent for
  plain-markdown prompt bodies separate from `AGENT_PROMPTS.md`. The
  shape's prompt body mirrors this shape.
- `[verified]` `bin/setup.sh:303-308` — discovery prompt rendering
  via mktemp + `_render_discovery_prompt`. The shape's
  `_render_prompt` mirrors this pattern.
- `[verified]` `bin/setup.sh:323-340` — direct `claude -p`
  invocation with stage-independent allowed-tools. The shape script
  does NOT mirror this; it routes through `dispatch.sh` per D-004 to
  preserve cost capture, mutex, gtimeout. Pattern divergence
  intentional.
- `[verified]` `bin/common.sh:57-62` — `PROJECT_STATE_DIR` resolution.
  The shape's artifact path uses this var.
- `[verified]` `bin/common.sh:30-37` — `log`, `die` helpers. The
  shape script uses both per CLAUDE.md "Use `log` / `die` /
  `require_env` / `require_bin` from common.sh".
- `[verified]` `bin/render-prompt.sh:13-22` — `STAGE_TO_SECTION`
  table. Shape names ARE NOT added here; the shape's prompt rendering
  bypasses render-prompt.sh per D-007.
- `[verified]` `bin/render-prompt.sh:91-109` — `extract_block`'s
  fence-count invariant. The §9 edit preserves the fence count at 2.
- `[verified]` CLAUDE.md "AGENT_PROMPTS.md is load-bearing" § — the
  fence-count discipline is in scope. PoC edits §9 in place and
  preserves the count.
- `[verified]` CLAUDE.md "Tests are sibling shell scripts named
  `*-test.sh` in `bin/`. There is no test runner" — the new shape's
  test sibling slots into this pattern; pre-commit hook enumerates it
  via `bin/*-test.sh`.
- `[verified]` CLAUDE.md "Pre-commit hook" § — the hook runs the full
  test suite; new test joins automatically.
- `[verified]` `docs/architecture.md:7-14` — "Two binaries, peer
  roles" Orchestrator vs Retrospective. The retrospective binary's
  internal split does not change the external contract.
- `[verified]` `docs/knowledge/decisions.md` does NOT exist in this
  tree (per `ls docs/` showing `architecture.md, assumptions.md,
  brainstorms, configuration.md, cost.md, demos, install.md,
  operations.md, pipeline-vocabulary.md, pipeline-vocabulary.template.md,
  plans, runbooks, security.md` — no `knowledge/` directory). Per the
  brainstorm prompt's "skip if not present" clause; proposed ADRs live
  in §10 inline.

### Assumed — needs verification or new code

- `[assumed]` `bin/retro-prompts/` directory does NOT yet exist. To
  be created in implementation. Confirmed by `ls bin/setup-prompts/`
  showing only `discovery.md`; no `bin/retro-prompts/` shown.
- `[assumed]` `bin/retro-shape-stage-failure-summary.sh` does NOT
  yet exist. To be created.
- `[assumed]` `bin/retro-shape-stage-failure-summary-test.sh` does
  NOT yet exist. To be created.
- `[assumed]` The §9 retrospective prompt body's §1 paragraph
  (`AGENT_PROMPTS.md:1766-1773`) is the ONLY block of code that
  computes the stage-failure summary today. **Verified by inspection:**
  ripgrep for "Stage failure analysis" returns one location
  (AGENT_PROMPTS.md §9). The shape's prompt body is the verbatim move
  target.
- `[assumed]` `bin/run-retrospective-local.sh::main()` will accept a
  pre-dispatch shape invocation between lines 58 and 60 without
  breaking the existing fresh-checkout / branch-checkout invariants.
  **To verify in implementation:** check that adding the
  `bash retro-shape-stage-failure-summary.sh` call between line 58 and
  line 60 doesn't introduce side effects in `$TARGET_REPO` (it
  shouldn't — the shape writes to `$PROJECT_STATE_DIR`).
- `[assumed]` The shape's claude dispatch, with `Write` permitted to
  any path under the retrospective allowed-tools, will write to
  `$PROJECT_STATE_DIR/retrospective-${today}/stage-failure-summary.md`
  as the prompt instructs. **Worst case if the agent writes elsewhere:**
  shape's `[[ -f "$artifact_path" ]]` check fails, shape dies, parent
  halts. Bounded failure.
- `[assumed]` Adding a new file in `bin/retro-prompts/` does NOT
  collide with `bin/run-local-helpers.sh::partition_dirty_paths` scope
  rules — the retrospective binary doesn't go through
  `bin/run-local.sh::tick`, so partition_dirty_paths never runs against
  retrospective state. **To verify in implementation:** confirm no
  scope-sweep is invoked on the retrospective branch checkout.
- `[assumed]` `_compute_retro_period`'s `git log --merges
  --format='%H %ct %s' | grep 'weekly retrospective' | head -1` returns
  a parseable timestamp on a fresh tree (no prior retrospective
  merges). **To verify in implementation:** test the fallback path
  (no merges → 30-day default).
- `[assumed]` The shape's prompt rendering via `sed -e
  "s|{token}|val|g"` is safe against values containing sed-meta chars.
  ISO timestamps and `$PROJECT_STATE_DIR` paths are sed-meta-clean.
  If a future token value might contain `|`, the script switches to
  ASCII unit-separator delimiter (`\x1f`). **To verify in
  implementation:** include a fixture asserting no leftover `{token}`
  patterns remain in the rendered prompt.
- `[assumed]` Adding the new test sibling to the existing
  `bin/*-test.sh` enumeration in the pre-commit hook + the per-target
  `.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]`
  list (`CLAUDE.md "Per-target dispatch.tools extras and profile-derived
  tools (ENG-51, ENG-94)"`) will require regeneration of the operator's
  `config.json` extras list. **To verify in implementation:** run the
  regeneration snippet in CLAUDE.md after adding the new test file.
- `[assumed]` `bin/agent-prompts-content-test.sh` will accept the §9
  paragraph edit. **To verify in implementation:** run the test pre-commit.

## 10. Proposed ADRs

`docs/knowledge/decisions.md` does not exist in this repo (per the
brainstorm prompt's "skip if not present" clause). The single proposed
ADR is filed inline.

### ADR-001 (proposed): Retrospective shape-extraction pattern — independent prompt + invocation per behavior

**Status:** proposed
**Date:** 2026-05-15
**Context:** The weekly retrospective is a 12-behavior monolith
(`bin/run-retrospective-local.sh` + `AGENT_PROMPTS.md` §9). Each
behavior has independent inputs, outputs, and failure modes, but they
share one dispatch and one verdict path. Adding new behaviors
(calibration ENG-39, component audit ENG-40) compounds context window
pressure and failure-mode entanglement.

**Decision:** Extract retrospective sub-behaviors as "shapes". Each
shape gets:

- A plain-markdown prompt body at `bin/retro-prompts/<shape-name>.md`.
- An executable orchestrator at `bin/retro-shape-<shape-name>.sh`
  that renders tokens, dispatches `claude -p` via
  `bash bin/dispatch.sh retrospective`, validates the artifact.
- A sibling test at `bin/retro-shape-<shape-name>-test.sh`.
- An artifact at
  `$PROJECT_STATE_DIR/retrospective-${date}/<shape-name>.md` consumed
  by the parent retrospective via path-token injection into the §9
  prompt.

The first shape — `stage-failure-summary` — proves the pattern. The
rest of §1-§12 stays inline in §9 until ENG-XX (coordinator + bulk
migration) ships.

**Consequences:**

- Each shape has its own test surface (vs the current zero-test
  retrospective).
- Each shape's claude invocation is independent — failure of one
  doesn't block the others. (Pending coordinator: today's split keeps
  failure-blocking semantics because the parent halts on shape
  failure. The coordinator will replace that with per-shape
  best-effort.)
- New retrospective behaviors land as new shape files, not as
  AGENT_PROMPTS.md §9 paragraph additions. Lower context pressure on
  the parent prompt.
- Coordinator + remaining-shape migration is a follow-up ticket. The
  monolith persists in the meantime; only §1 is shape-shaped.
- Shape artifacts live in `$PROJECT_STATE_DIR/retrospective-${date}/`,
  giving operators a per-run inspection surface that doesn't exist
  today.

**Alternatives rejected:** (1) Coordinator-first migration — too large
for one ticket per the sizing rubric. (2) AGENT_PROMPTS.md §10
shape-prompt addition — pollutes the dispatch-stage schema. (3)
Inline-shapes-only (no separate file) — defeats the "independently
testable" goal.

## 11. Persona review

Personas applied in the mandated order:
design → security → scope → coherence → product → feasibility
(feasibility is the gating persona).

### Iteration 1

#### design — PASS

D-001 through D-010 compose cleanly. D-001 (which behavior to extract)
is the smallest-viable-shape decision; D-002 (where prompts live) and
D-003 (where shape scripts live) are layout decisions; D-004 (dispatch
reuse) and D-005 (artifact location) are integration decisions; D-006
(orchestration cut) and D-007 (rendering surface separation) and D-008
(period semantics) are flow decisions; D-009 (tests) and D-010 (scope
fence) are completion decisions.

The shape-extraction pattern parallels two existing precedents:
`bin/setup-prompts/discovery.md` (plain-markdown prompt next to a
caller) and per-stage allowed-tools (centralized in
`dispatch.sh::allowed_tools_for`). No new abstractions introduced; the
PoC is a faithful execution of an existing pattern applied to a new
surface (retrospective sub-behaviors).

D-006's "shape runs first, parent reads artifact verbatim" is the
mechanically-cleanest delegation cut. Either the parent recomputes
(no delegation) or the parent reads (true delegation). The
intermediate "shape produces, parent decides whether to use" is the
worst option (operator has no way to know what was actually used);
correctly avoided.

No P0 / P1. One P2: D-005's per-run dated subdirectory accumulates
without TTL. Disk usage is small (<1 MB / run); not a P0/P1 today;
named in §6 edge case 15 as a future TTL prune.

#### security — PASS

No new auth surface. The shape's claude dispatch flows through
`dispatch.sh` which already carries the ENG-48 isolation flags
(`--setting-sources project,local`, `--disable-slash-commands`,
`--disallowed-tools`). The shape's Write target is constrained to
`$PROJECT_STATE_DIR/retrospective-${today}/<shape-name>.md` by the
prompt instruction; the allowed-tools `Write` permission is broader but
the prompt-side restriction is the operative constraint (consistent
with how every other dispatched agent stage works today — allowed-tools
declares the surface, the prompt declares the policy).

The `--artifact-path`, `--period-start-iso`, `--period-end-iso` CLI
args to the shape script are operator-controlled (the only callers are
`bin/run-retrospective-local.sh` and manual operator invocation). No
external untrusted input. Token interpolation via sed with `|`
delimiter is safe for ISO timestamps and `$PROJECT_STATE_DIR` paths;
edge case 13 covers the future-proofing.

The shape's read of `events.jsonl` is operator-trust-boundaried (the
metric stream is harness-written). No PII surface.

`PIPELINE_DISPATCH_ID` remains unset on retrospective dispatches per
ENG-87's intentional retrospective carve-out (the binary is
cross-issue). The shape inherits this — no ENG-87 contract violation.

No P0 / P1 / P2 findings.

#### scope — PASS

The brainstorm addresses each Linear AC bullet:

- AC #1 ("One previously-inline retrospective behavior runs via the new
  shape-script architecture"): D-001 picks §1 stage-failure analysis;
  D-002/D-003 define the architecture; D-006 cuts the orchestration so
  the shape produces and the parent reads.
- AC #2 ("Existing retrospective output is unchanged — the shape
  produces the same artifact"): D-006 preserves output by moving §1's
  text VERBATIM into the shape prompt + amending §9 to read the
  artifact. OQ-4 explicitly defers wording cleanup to avoid drift.
- AC #3 ("Tests cover the shape's invocation and artifact production"):
  D-009 names fixture coverage for shape invocation (token resolution +
  dispatch call shape), artifact production (file-exists assertion),
  and dry-run support.

Nothing implemented beyond AC scope:

- D-010 fences scope to ONE shape; coordinator + migration deferred to
  ENG-XX (the next sub-ticket of ENG-33).
- New behaviors (calibration ENG-39, component audit ENG-40)
  explicitly out of scope per "OUT" section of the Linear issue.
- §2-§12 of the retrospective stay inline per D-010.
- No prompt rewording per OQ-4.
- No coordinator abstraction. No generic shape runner. No
  per-shape verdict markers.

No P0 / P1 / P2 findings.

#### coherence — PASS (with one P2 note)

Internal consistency check:

- D-001 picks §1; D-006 cuts §1 out of the inline prompt and into the
  shape. Symmetric.
- D-002 puts shape prompts in `bin/retro-prompts/`; D-007 separates
  rendering surface from `render-prompt.sh`. Both flow from
  "shapes are not dispatch stages".
- D-004 reuses `dispatch.sh retrospective`; D-008 reuses
  retrospective's existing period semantics. Reusing existing
  primitives over introducing new ones.
- D-009's test fixtures cover the AC-named surfaces (invocation,
  artifact, dry-run). One fixture per AC bullet plus error path
  fixtures.
- D-010's scope fence matches Linear "OUT" list. Symmetric.

§9 sentence-edit consequence: the parent's §1 paragraph shrinks; the
total prompt body shrinks by ~7 lines; AGENT_PROMPTS.md fence count
stays at 2. Verified by inspection of `AGENT_PROMPTS.md:1766-1773` (the
target paragraph).

One P2 coherence note: the §9 wording asks the agent to "Read the
stage-failure-summary artifact at `{stage_failure_summary_path}`" but
the existing AGENT_PROMPTS.md §9 prelude says "Read these files (in
order)" with a numbered list (`AGENT_PROMPTS.md:1741-1754`). The shape
artifact should appear in that read list as an explicit entry (e.g.,
"7a. The pre-computed stage-failure-summary artifact at
`{stage_failure_summary_path}` — read before §1") to keep the
"Read these files" enumeration accurate. The brainstorm proposes
amending §9's read list as part of the §9 edit. Worth calling out as
part of the implementation. P2.

No P0 / P1 findings.

#### product — PASS

The PoC's user (the operator) gets:

- Observability: per-run shape artifacts in
  `$PROJECT_STATE_DIR/retrospective-${date}/` give the operator a
  durable surface to inspect what the retrospective saw (today this
  surface is only the PR body, post-hoc).
- Verifiability: shape failure surfaces as Slack error + exit 20,
  same shape as today's retrospective failure path. No new operator
  workflow to learn.
- Reversibility: if the shape misbehaves, the operator can revert one
  commit (the shape script + the §9 paragraph edit) and the
  retrospective reverts to today's monolith.
- Forward-compatibility: the shape's structure (prompt body file +
  shape script + sibling test) is the template for ENG-39 / ENG-40 /
  the coordinator follow-up. The operator's mental model of "how a
  shape works" is portable across the next several tickets.

The PoC explicitly does NOT introduce:

- Operator-facing config knobs (no per-shape enable/disable, no
  per-shape model tier).
- New Linear markers or labels.
- New Slack notification shapes.
- Changes to the weekly schedule.

This is appropriate for a proof-of-concept; configuration surface
should grow with the coordinator that actually warrants it.

No P0 / P1 / P2 findings.

#### feasibility — PASS

This is the gating persona; codebase-fact errors here would be P0.

Every code reference in the brainstorm has been verified against the
current tree (per Assumption Inventory §9 — Verified items have
`path:line` quotes; Assumed items are either (a) new files to be
created in implementation, or (b) behavioral claims that must be
verified at implementation time).

Specific verification of named symbols:

- `bin/run-retrospective-local.sh::main()` — verified to be the
  entrypoint at `bin/run-retrospective-local.sh:32`.
- The fenced-block extraction awk — verified at
  `bin/run-retrospective-local.sh:62-66`.
- `bin/dispatch.sh::allowed_tools_for`'s `retrospective` arm —
  verified at `bin/dispatch.sh:403`.
- `bin/dispatch.sh::_render_and_capture_stream`'s
  `PIPELINE_ISSUE_ID` gate — verified at `bin/dispatch.sh:439`.
- `bin/dispatch.sh` DRY_RUN log line — verified at
  `bin/dispatch.sh:511-525`.
- `bin/metrics.sh`'s events.jsonl write — verified at
  `bin/metrics.sh:43,67`.
- `bin/setup-prompts/discovery.md` precedent — verified by `ls
  bin/setup-prompts/` showing `discovery.md`.
- `bin/setup.sh::_render_discovery_prompt` — verified by
  `grep -n setup-prompts/discovery.md bin/setup.sh` showing the
  invocation at `bin/setup.sh:303-308`.
- `bin/common.sh::PROJECT_STATE_DIR` resolution — verified at
  `bin/common.sh:57-62`.
- `bin/render-prompt.sh::STAGE_TO_SECTION` table — verified at
  `bin/render-prompt.sh:13-22`.
- `bin/render-prompt.sh::extract_block` fence-count check — verified
  at `bin/render-prompt.sh:91-109`.
- `AGENT_PROMPTS.md` §9 §1 paragraph — verified at
  `AGENT_PROMPTS.md:1766-1773` (`"1. **Stage failure analysis:**"` line
  shape).

NEW symbols (to be created in implementation per D-002/D-003/D-009):

- `bin/retro-prompts/stage-failure-summary.md` (assumed — new file)
- `bin/retro-shape-stage-failure-summary.sh::main` (assumed — new file)
- `bin/retro-shape-stage-failure-summary.sh::_render_prompt`
  (assumed — new helper, parallels setup.sh:_render_discovery_prompt)
- `bin/retro-shape-stage-failure-summary-test.sh` (assumed — new file)
- `bin/run-retrospective-local.sh::_compute_retro_period`
  (assumed — new helper)

The "new symbol" items are appropriately marked as `[assumed]` in §9
and the exact files that must be modified/created are named.

No P0 / P1 / P2 findings.

### Iteration 1 verdict

All six personas: PASS. Feasibility persona returned zero P0
findings.

**Gate status: 6/6 PASS · feasibility P0: 0 · proceeding to planning**

No iteration 2 required.

## 12. Summary

This brainstorm proposes extracting the §1 Stage failure analysis
behavior from the monolithic weekly retrospective into a standalone
"shape" — proof-of-concept for the architecture pattern that ENG-33 (+
follow-up coordinator + ENG-39 / ENG-40 shapes) will build on.

The shape consists of:

1. A plain-markdown prompt body at
   `bin/retro-prompts/stage-failure-summary.md` (verbatim move of §1's
   instructions).
2. A wrapper executable `bin/retro-shape-stage-failure-summary.sh`
   that renders tokens (`{events_jsonl_path}`, `{period_start_iso}`,
   `{period_end_iso}`, `{artifact_path}`, `{previous_period_path}`)
   and dispatches `claude -p` via `bash bin/dispatch.sh retrospective`.
3. A sibling test
   `bin/retro-shape-stage-failure-summary-test.sh` covering
   invocation, artifact production, and dry-run.
4. A minimal edit to `bin/run-retrospective-local.sh` invoking the
   shape before the parent dispatch and injecting the artifact path
   into the parent's rendered §9 prompt.
5. A minimal edit to `AGENT_PROMPTS.md` §9 §1 paragraph replacing the
   inline analysis with "Read the artifact at
   `{stage_failure_summary_path}`".

The PoC's output is BYTE-IDENTICAL to today's retrospective PR body
§1 (verbatim move of the prompt content). The mechanism changes; the
content stays.

§2-§12 of the retrospective remain inline. The coordinator pattern +
migration of remaining behaviors is the next sub-ticket of ENG-33.
Calibration (ENG-39) and component audit (ENG-40) are separate tickets.

Pre-existing ADRs (ENG-26, ENG-48/ENG-65, ENG-81, ENG-87, ENG-100,
ENG-103) are unchanged; no ADR is overturned. One new proposed ADR
(ADR-001) names the shape-extraction pattern.
