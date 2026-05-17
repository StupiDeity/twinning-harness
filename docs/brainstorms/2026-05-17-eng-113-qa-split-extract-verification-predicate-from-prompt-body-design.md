---
linear: ENG-113
title: qa split — extract verification predicate from prompt body
date: 2026-05-17
status: draft
---

# ENG-113 — qa split: extract verification predicate from prompt body

## 1. Overview

§6 (QA Agent) of `AGENT_PROMPTS.md` currently asks one agent to do two
qualitatively different jobs in one dispatch:

| Half | What | Today's mechanism |
|---|---|---|
| **Verification** | Deterministic "did the artifact land and do the gates pass?" checks | Prose in §6 steps 2-4 — agent runs `gh pr view`, the project profile's build/test commands, greps the test tree, reads the diff. Output is judgment in the §6 summary; no machine-readable record. |
| **Evaluation** | Subjective "are the tests adequate, are there missing coverage gaps, are there hidden contract drifts?" | Prose in §6 steps 5-7 — adversarial-test budget, qa-pattern proposals, sub-agent dispatch. Output is the same §6 summary. |

The umbrella issue [ENG-38](https://linear.app/twinning/issue/ENG-38/p3-verificationevaluation-split-qa-refactor) calls for splitting these so the
verification half becomes a deterministic, scriptable contract that an
operator (or a non-LLM CI step) can re-run independently. ENG-113 ships
**only the verification side** of the split, and only at the
*contract-extraction* level — not the dispatch cleave (that's the next
sub-ticket).

Concretely ENG-113 lands three pieces:

1. **Predicate format.** A structured JSON document the QA agent writes
   at the start of its dispatch, naming the verification checks for
   this issue: smoke commands + expected exit codes, file-presence
   assertions, grep-for-token assertions, optional URL navigations.
   The shape mirrors `plan-schema.sh`'s `pass_criteria[]` array
   (ENG-122) so the QA verifier consumes a superset of the plan's
   contract.
2. **Prompt change.** §6 of `AGENT_PROMPTS.md` instructs the agent to
   emit the predicate file **before** any evaluation reasoning. The
   predicate lives at a canonical worktree path. Failure to emit it is
   a P0 contract violation.
3. **Runner.** `bin/verify-qa.sh validate <predicate-file>` executes
   the predicate without invoking `claude`. Returns structured
   pass/fail (exit codes mirror `plan-schema.sh`'s taxonomy). Used
   today as a detective post-dispatch check; in the next sub-ticket
   it becomes the entire verification dispatch.

The Linear ticket's "OUT" list explicitly says (a) the dispatch
cleave is the next sub-ticket and (b) evaluation-half changes are
out of scope. ENG-113 strictly observes both boundaries.

Three non-obvious design problems the brainstorm has to resolve:

- **A. Source-of-truth ambiguity.** ENG-122's `plan.json` already
  carries `pass_criteria[]` for the feature. Should the QA predicate
  *be* the plan's contract (read directly from `plan.json`), or a
  *superset* the QA agent emits (plan's contract + QA-added adversarial
  predicates)? The brainstorm must pin which file is canonical and what
  shape the QA-emitted file takes.
- **B. Runner authority surface.** The runner executes arbitrary shell
  commands from a JSON file. Where does the file come from, who writes
  it, and what authorises the runner to run `bash <command>` inside
  the worktree? The wrong answer creates a code-execution gadget
  reachable from any actor who can write to the worktree.
- **C. Halt-vs-fail asymmetry.** A failing smoke command is QA's
  expected job; the prompt today routes that to `verdict fail
  --target implementing`. A *missing predicate file* is a contract
  violation, not a fail-loopback signal. The brainstorm must distinguish
  these so a missing-predicate halt doesn't reset the rejection counter
  (ENG-58) when a real qa-loopback is the right response.

## 2. Decisions

- **D-001. Predicate file shape: a JSON document at
  `$(issue_dir)/qa-predicate-<ENG-N>.json` with a top-level
  `pass_criteria[]` array reusing `plan-schema.sh`'s schema-v1
  `kind` taxonomy (`smoke`, `file_exists`, `grep`) plus one new kind
  `http_get`. Top-level `qa_predicate_schema_version: 1` + `issue_id`
  cross-check field.** The file is per-issue, per-dispatch, and lives
  in the per-issue state dir (NOT in the worktree).

  Schema sketch:

  ```json
  {
    "qa_predicate_schema_version": 1,
    "issue_id": "ENG-113",
    "pass_criteria": [
      {
        "kind": "smoke",
        "command": "bash bin/verify-qa-test.sh",
        "expect_exit": 0
      },
      {
        "kind": "file_exists",
        "path": "bin/verify-qa.sh"
      },
      {
        "kind": "grep",
        "path": "AGENT_PROMPTS.md",
        "pattern": "emit the verification predicate",
        "expect_match": true
      }
    ]
  }
  ```

  *Reference to constraint:* CLAUDE.md "Don't add features, refactor,
  or introduce abstractions beyond what the task requires." Reusing
  `plan-schema.sh`'s `pass_criteria[]` shape adds zero new validator
  vocabulary. The three existing kinds + one new `http_get` (named
  explicitly in the Linear ticket's IN bullet: "URLs to navigate")
  match the Linear scope exactly.

  *Reference to constraint:* ENG-122's plan.json brainstorm §D-002
  documents the discriminated-union shape (one `kind` field, kind-
  specific extra fields). The QA predicate adopts the same shape so
  a single validator helper (`bin/plan-schema.sh::_validate_criterion`
  refactored into a shared helper) can validate both. (See D-007 for
  the shared-helper-refactor scope boundary.)

  *Reference to constraint:* CLAUDE.md "Per-issue state directory" —
  `$(issue_dir)` is the canonical per-issue scratch location. The
  predicate file is per-dispatch context, not source-tree artifact,
  so it lives in `$PROJECT_STATE_DIR/<ident>/qa-predicate-<ENG-N>.json`,
  NOT in `docs/`. It is also NOT in the worktree, so it can't leak
  to `partition_dirty_paths` (CLAUDE.md "Sub-agent debris (ENG-100)"
  applies — the QA agent currently has Write access to the worktree
  root; placing the file outside the worktree avoids the entire
  scope-sweep classification path).

  *Rejected alternative — derive the predicate entirely from
  `plan.json`, no QA-emitted file:* rejected because (a) the Linear
  ticket explicitly says "Define a verification-predicate format the
  agent emits at qa start" — QA emission is the contract, not a
  derivation. (b) `plan.json`'s `pass_criteria[]` describes the
  **plan's** acceptance contract; the **QA agent** legitimately
  expands this with adversarial smoke commands (the §5 adversarial-
  testing budget is QA-authored). Treating plan.json as the sole
  source would conflate "what the plan committed to" with "what QA
  verified." (c) ENG-122 explicitly carves this out — its OUT
  bullet says ENG-38 readers ship later; the QA predicate IS that
  reader-plus-extension.

  *Rejected alternative — TOML / YAML predicate format:* rejected
  because (a) the harness has `jq` everywhere and no TOML/YAML parser
  in the runtime bin profile (project profile's Stack section names
  jq, awk, sed, gtimeout — not yq/tomlq); (b) the plan.json
  precedent is JSON and using the same format keeps one validator
  vocabulary.

  *Rejected alternative — embed the predicate inline in the
  stage-summary-qa.md file as a fenced block:* rejected because
  (a) extracting a single fenced block from a markdown file with
  exactly-2-fences-per-stage invariant is the failure pattern
  `render-prompt.sh::extract_block` already had to harden against
  (CLAUDE.md "AGENT_PROMPTS.md is load-bearing"); (b) the
  stage-summary is the **evaluation** artifact — coupling
  verification data to it defeats the entire split.

- **D-002. Canonical predicate path:
  `$(issue_dir)/qa-predicate-<ident>.json`. Resolved via a new
  `bin/common.sh::qa_predicate_path <ident>` helper, sibling of
  `progress_md_path <ident>` (`bin/common.sh:400` exported pattern).
  Surfaced to the QA prompt via a new `{qa_predicate_path}` token
  in `bin/render-prompt.sh::PROMPT_RESOLVERS`.**

  *Rationale:* the QA agent cannot reliably reconstruct
  `$PROJECT_STATE_DIR` from inside its sandbox (the env var is not
  in the prompt context; ENG-79 fixed exactly this drift class for
  branch-name). A path-shape token + a Write call is the established
  ENG-108 progress-md shape: `_RENDER_*` sibling pattern + a
  one-line resolver returning the path string.

  Resolver shape (byte-for-byte copy of `_resolve_progress_md_path`
  at `bin/render-prompt.sh:230`):

  ```bash
  # bin/render-prompt.sh
  _resolve_qa_predicate_path() { printf '%s' "$_RENDER_QA_PREDICATE_PATH"; }
  ```

  Bound in `main()` (sibling to `_RENDER_PROGRESS_MD_PATH` at
  `bin/render-prompt.sh:521`):

  ```bash
  _RENDER_QA_PREDICATE_PATH="$(qa_predicate_path "$issue_id")"
  ```

  *Reference to constraint:* CLAUDE.md "Per-issue state directory" +
  ENG-79 "the agent does NOT know `$PROJECT_STATE_DIR`." Surfacing
  the absolute path via a render-time token is the established
  workaround.

  *Reference to constraint:* `bin/common.sh::progress_md_path` is the
  precedent helper-function-per-per-issue-artifact shape. Adding
  `qa_predicate_path` next to it (one liner: `printf '%s' "$(issue_dir
  "$1")/qa-predicate-$1.json"`) is the lowest-novelty path.

  *Rejected alternative — agent computes the path from
  `{issue_id}` + a hardcoded base:* rejected because (a) the
  hardcoded base would either be wrong (the agent cannot know the
  per-host `$XDG_STATE_HOME`-derived prefix) or would couple the
  prompt to harness internals (ENG-79's drift class). (b) Even if
  the agent got it right today, ENG-67's "worktree path empty after
  reconcile=proceed" invariant warns against any agent-side
  reconstruction of orchestrator-owned paths.

  *Rejected alternative — write the predicate inside the worktree
  (`./.qa-predicate.json`):* rejected because (a) ENG-100's
  sub-agent-debris rule forbids non-allowlist worktree writes;
  (b) the file would get classified by `partition_dirty_paths` —
  either as a self-leak (it has no `eng-N` in the basename and
  `.gitignore` does not currently include the pattern) or as a
  legitimate artifact that drifts onto `main`. Per-issue state
  directory avoids both classification paths.

- **D-003. Runner CLI at `bin/verify-qa.sh validate <predicate-file>
  [--ident <ENG-N>] [--worktree <path>]`. Reuses the
  `plan-schema.sh::cmd_validate` exit-code taxonomy: 0=pass,
  33=malformed JSON, 34=schema-incomplete, 35=missing-file. Adds
  one new code 36=predicate-execution-failed for the case
  "predicate parsed, schema valid, but a `pass_criterion` evaluated
  to fail."**

  *Rationale:* one-CLI-per-concern matches the established harness
  convention (`bin/plan-schema.sh`, `bin/scope-check.sh`,
  `bin/secret-probe-lint.sh` — each a single script with a `main`
  dispatch). `bin/verify-qa.sh` is the QA-side analog of
  `bin/plan-schema.sh`.

  Exit-code split:

  | Exit code | Outcome token              | Halt reason                   |
  |-----------|----------------------------|-------------------------------|
  | 33        | `qa-predicate-malformed`   | `qa-predicate-invalid`        |
  | 34        | `qa-predicate-incomplete`  | `qa-predicate-invalid`        |
  | 35        | `qa-predicate-missing`     | `qa-predicate-invalid`        |
  | 36        | `qa-predicate-failed`      | (none — routes to verdict fail) |

  Three of the four exit codes (33/34/35) share the same halt reason
  `qa-predicate-invalid` — the contract is broken, operator inspects.
  These map to the *contract violation* class. Code 36 is the
  *expected QA failure* class: a smoke command exits non-zero in
  the way QA exists to catch. Code 36 must NOT halt; it must route
  to `verdict fail --target implementing` so the rejection counter
  ticks and the model-escalation predicate fires (ENG-103).

  *Reference to constraint:* CLAUDE.md "Never use exit codes outside
  the taxonomy in `failure_outcome_for_exit`." Four new codes
  (33-36 already partially used for plan-schema; 36 is new) are
  added to the taxonomy. **Code 33-35 are already in the taxonomy
  for `plan-contract-*`** (`bin/common.sh:273-275`); reusing them for
  qa-predicate-* requires sub-coding by stage. See D-008 for the
  resolution.

  *Reference to constraint:* CLAUDE.md "Marker shapes — only two
  families exist" — the new halt reason `qa-predicate-invalid` is
  added to `bin/pipeline-events.json::halt_reasons[]` (alongside
  `plan-contract-invalid` from ENG-122).

  *Rejected alternative — fold into `bin/plan-schema.sh` as a
  second subcommand (`bash bin/plan-schema.sh validate-qa
  <file>`):* rejected because (a) the QA predicate has additional
  kinds (`http_get`) that don't apply to plans, so the validator
  needs to know its calling context anyway; (b) the runner has a
  *second* responsibility (executing the predicate, not just
  validating it) that doesn't belong in plan-schema; (c) one-CLI-
  per-concern is the harness convention. Refactor of common
  validation logic into a shared helper is D-007.

  *Rejected alternative — make `bin/verify-qa.sh` Python or Go:*
  rejected because (a) the Stack section names Bash 3.2 + jq +
  awk only; (b) plan-schema.sh's ~250 lines of bash + jq prove
  the validator size is bounded; (c) introducing a new runtime
  would require setup changes (CI, launchd plist PATH, the
  install script's `require_bin` list).

- **D-004. New `kind` for the QA predicate only: `http_get`. Field
  shape: `{ "kind": "http_get", "url": "<string>", "expect_status":
  <int>, "expect_body_match": "<regex|null>" }`.**

  *Rationale:* the Linear ticket's IN bullet names "URLs to
  navigate" as a verification predicate type. `http_get` is the
  minimum shape — a `curl -sS -o /dev/null -w '%{http_code}'`-
  shaped check + optional body regex. The runner shells out to
  `curl` (already on the harness's required-bin list — CLAUDE.md
  "Harness tools" §).

  *Reference to constraint:* the Linear scope IN bullet "URLs to
  navigate, expected exit codes, assertions" names this kind
  verbatim. Renaming to `url_get` / `navigate` etc. would be
  speculative; `http_get` is the cheapest description of what the
  runner actually does.

  *Reference to constraint:* CLAUDE.md "Don't add features … beyond
  what the task requires." `http_get` is one new kind — not a
  full HTTP test framework. No follow-redirects flag, no
  request-body field, no header assertions. The ticket's IN
  bullet is the ceiling.

  *Rejected alternative — model URL navigation as a `smoke`
  criterion (`bash -c "curl -fsS http://… >/dev/null"`):*
  rejected because (a) raw `curl | bash` patterns evade
  structured assertion (the runner has no idea what the smoke
  command does); (b) explicit `http_get` lets the runner format a
  meaningful failure message ("expected 200, got 503 at
  http://localhost:8080/healthz") instead of "smoke exited 22";
  (c) keeps the JSON readable for the operator.

  *Rejected alternative — defer `http_get` to a follow-up:*
  rejected because the Linear ticket explicitly names URLs in
  scope. Deferring inflates the next sub-ticket beyond its
  cleave-prompt remit.

- **D-005. The QA agent writes the predicate file BEFORE any
  evaluation reasoning. §6 of `AGENT_PROMPTS.md` gains a new
  numbered step `0` (or "Step 1" — see D-006 for ordering)
  titled "Emit verification predicate" that runs after the
  branch-shape detection block (line 1365-1369) and before the
  current step 1 (flaky-pattern triage).**

  Block content sketch:

  ```
  0. **Emit verification predicate (MANDATORY before any other
     work):**
     - Read the plan's pass_criteria[] from docs/plans/{plan_file}'s
       sibling JSON (the plan.json contract — same basename, .json
       extension; see plan-schema.sh schema-v1).
     - Build a `qa_predicate_schema_version: 1` document at
       `{qa_predicate_path}` (an absolute path resolved by the
       orchestrator; do NOT compute it yourself).
     - The document's pass_criteria[] is a SUPERSET of the plan's:
       (a) every plan.json pass_criterion is copied verbatim, AND
       (b) optionally add QA-authored smoke / file_exists / grep /
       http_get criteria that name the deterministic checks for
       this issue.
     - Write the file via the `Write` tool (the absolute path is
       outside the worktree; partition_dirty_paths will NOT see
       it).
     - On a back-fill PR (Decision-path D, the docs-only path
       below), the predicate file MUST still be written but its
       pass_criteria[] is just the plan.json contract verbatim;
       no adversarial smoke commands are required.
  ```

  *Reference to constraint:* §6 already mandates an "ordered job"
  list ("Your task: 1. … 2. …"). The new step 0 / step 1 slots
  cleanly into that structure.

  *Reference to constraint:* CLAUDE.md "AGENT_PROMPTS.md is
  load-bearing" — the new step lands inside the §6 fenced block,
  not outside it. No column-0 fence drift.

  *Reference to constraint:* ENG-77 / §0 "stage summary file —
  overwrite-on-every-dispatch contract" — the QA predicate is the
  same shape (per-dispatch context the agent writes via Write).
  Overwrite-on-every-dispatch applies; pre-existing predicate from
  a prior QA dispatch is replaced.

  *Rejected alternative — agent emits the predicate at end of
  dispatch, alongside the stage-summary file:* rejected because
  (a) writing the predicate first means a crashed evaluation
  half still leaves a runnable verifier on disk — the operator
  can manually re-run `bash bin/verify-qa.sh validate` to see if
  the gates would pass; (b) the next sub-ticket cleaves
  verification into its OWN dispatch — if the predicate is
  end-of-dispatch today, the cleave requires re-ordering then,
  which is wasted churn. Writing at start matches the eventual
  shape.

  *Rejected alternative — orchestrator constructs the predicate
  from plan.json without involving the QA agent at all:*
  rejected because (a) the Linear ticket explicitly says "qa
  agent emits a verification predicate file" — agent emission
  is the contract; (b) QA's adversarial-test budget (§6 step 5)
  expands the predicate beyond plan.json; that expansion is
  agent-authored. Bypassing the agent would foreclose the
  evaluation-half's job.

- **D-006. Block placement inside §6: as new "Step 1" at line
  ~1392, immediately after the branch-shape-detection block
  (line 1365-1369) and BEFORE the current "Step 1. Flaky-pattern
  triage" (line 1394). Existing steps renumber: 1→2 (flaky), 2→3
  (gates), 3→4 (coverage), 4→5 (regression), 5→6 (adversarial),
  6→7 (dedup), 7→8 (qa-patterns).**

  *Rationale:* the new step has a strict ordering dependency —
  it must run before any other QA work so a crashed agent leaves
  a runnable predicate. Renumbering downstream steps is mechanical
  and matches the §6 numbered-list convention.

  *Reference to constraint:* CLAUDE.md "AGENT_PROMPTS.md is
  load-bearing" + the existing `bin/agent-prompts-content-test.sh`
  pins distinctive substrings from each section. The renumber
  changes the section's step count but not its semantic content;
  the content-pin test continues to match on the per-step
  literal-phrase pin (e.g., "Flaky-pattern triage" is still
  present, just at a different step number).

  *Reference to constraint:* ENG-140 brainstorm §D-005 picked the
  same insertion strategy (new block immediately before related
  existing blocks). Symmetry with the established pattern.

  *Rejected alternative — append the new step at the end of §6:*
  rejected because (a) the predicate MUST be written before
  any other work; placing the instruction at the end inverts the
  agent's reading order and invites the agent to skip it;
  (b) the §6 flow (triage → run → audit → adversarial → dedup
  → qa-patterns) is a logical pipeline; the predicate is a
  pre-pipeline step, not a post-pipeline step.

  *Rejected alternative — keep step numbering, add the predicate
  as a sub-step `0.5` or inside the existing "Branch-shape
  detection" block:* rejected because (a) the branch-shape block
  is a conditional gate (path D vs paths A/B/C), not a step in
  the canonical sequence; (b) numbered-list breakage harms
  readability and breaks `bin/agent-prompts-content-test.sh`'s
  ability to grep for step boundaries.

- **D-007. Refactor scope: extract `plan-schema.sh`'s per-criterion
  validation into a sourceable helper at
  `bin/common.sh::_validate_pass_criterion <file> <feature-index>
  <criterion-index> [--kinds <csv>]` — invoked by both
  `plan-schema.sh::cmd_validate` and `verify-qa.sh::cmd_validate`.
  The `--kinds` flag restricts the allowed kind set; plan-schema
  passes `smoke,file_exists,grep` and verify-qa passes
  `smoke,file_exists,grep,http_get`.**

  *Rationale:* the per-criterion validation in
  `bin/plan-schema.sh:181-260` is ~80 lines of jq + bash conditionals.
  Copying it verbatim into verify-qa.sh would double the
  duplication surface and create a drift class (a future schema-v2
  field change has to land in two scripts). A shared helper in
  common.sh is the established pattern (`require_env`, `require_bin`,
  `failure_outcome_for_exit`, `progress_md_path` all live there).

  Concrete refactor:

  | Step | Change | Site |
  |---|---|---|
  | 1 | Add `_validate_pass_criterion` to `bin/common.sh` (lift from `plan-schema.sh:181-260`, add `--kinds` flag) | +~80 LOC in common.sh |
  | 2 | Replace inline criterion logic in `plan-schema.sh::cmd_validate` with `_validate_pass_criterion --kinds smoke,file_exists,grep` | -~80 LOC, +1 call site |
  | 3 | `verify-qa.sh::cmd_validate` calls `_validate_pass_criterion --kinds smoke,file_exists,grep,http_get` | +1 call site |
  | 4 | Add `http_get` kind handling to `_validate_pass_criterion` (gated on `--kinds` containing it) | +~25 LOC |
  | 5 | `bin/plan-schema-test.sh` (existing — verify it still passes) + `bin/verify-qa-test.sh` (new) | net +1 test file |

  *Reference to constraint:* CLAUDE.md "When wiring a new script —
  Use `log` / `die` / `require_env` / `require_bin` from common.sh;
  don't roll your own." The validation helper is on the same axis
  — shared concern, common.sh-resident.

  *Reference to ADR stress test:* this refactor puts pressure on
  the CLAUDE.md note "common.sh is sourced by every script and
  every test; adding 80 lines of jq to it widens parse-time surface
  for no orthogonal benefit" (cited in ENG-122 brainstorm §D-003
  as a reason to keep plan-schema.sh standalone). The pressure is
  real but the trade-off has now flipped: with two callers (plan +
  qa) for the same validator, the duplication cost exceeds the
  parse-time cost. Mitigation: gate the new helper behind a single
  function body (no proliferation of mini-helpers); land in a
  single PR with both call-site swaps so the parse-time bench
  reflects the steady state, not a transitional state.

  *Rejected alternative — leave plan-schema.sh alone, duplicate
  the validator into verify-qa.sh:* rejected because (a) ENG-87's
  cross-dispatch staleness contract teaches that drift between
  two implementations of the same concept is THE structural failure
  class to avoid; (b) the schema is going to grow (the cleave
  sub-ticket will add fields), and growing two parallel
  implementations is technical debt that compounds; (c) the
  refactor is mechanical — every line moved is line-for-line
  preserved.

  *Rejected alternative — extract into a separate helper script
  `bin/pass-criterion-validate.sh` (one-CLI-per-concern):*
  rejected because (a) the helper has no standalone-CLI use case —
  it's always called from inside a validator's main loop, indexed
  by `<file> <feature-index> <criterion-index>`; (b) shelling out
  via subprocess for ~80 criterion calls per dispatch (typical
  plan + qa together) adds measurable latency vs. an in-process
  bash function call; (c) `bin/common.sh` is the established
  home for in-process helpers.

- **D-008. Exit-code reuse: codes 33/34/35 stay mapped to
  `plan-contract-*` outcomes; qa-predicate failures route through
  NEW codes 36/37/38 in `bin/common.sh::failure_outcome_for_exit`.
  Code 36 = `qa-predicate-malformed`, 37 = `qa-predicate-incomplete`,
  38 = `qa-predicate-missing`. Predicate-execution failure (the
  "smoke command exited non-zero" case) does NOT exit the runner
  with a new code — it returns 0 + a structured pass/fail report
  on stdout, and the agent (or post-dispatch hook) reads the
  report to decide verdict.**

  *Rationale:* the verification runner has TWO failure modes:
  (a) the predicate file is broken (schema invalid, file missing) —
  this is a contract violation, halt with a unique halt-reason;
  (b) the predicate is valid but a check failed — this is
  QA's expected job, route to `verdict fail --target implementing`,
  bump the rejection counter.

  Conflating them under one exit code makes the post-dispatch hook
  unable to distinguish them. The plan-schema.sh exit codes (33/34/
  35) are already a closed taxonomy mapped 1:1 to `plan-contract-*`
  in `bin/common.sh:273-275`; reusing them for QA would require
  context-aware demuxing in `failure_outcome_for_exit`
  (the function would need to know the calling stage), which it
  does not today.

  New entries in `failure_outcome_for_exit`:

  ```bash
  36) printf 'qa-predicate-malformed' ;;
  37) printf 'qa-predicate-incomplete' ;;
  38) printf 'qa-predicate-missing' ;;
  ```

  New entries in `bin/pipeline-events.json::halt_reasons[]`:

  ```
  qa-predicate-invalid
  ```

  (Single coarse halt reason for all three exit codes — operator
  inspects the JSON; mirrors `plan-contract-invalid`'s single-coarse-
  reason design at ENG-122 §D-003.)

  *Reference to constraint:* CLAUDE.md "Never use exit codes outside
  the taxonomy in `failure_outcome_for_exit`." Three new codes
  (36/37/38) added before any caller emits them — symmetric to
  ENG-122's 33/34/35 land-then-emit ordering.

  *Reference to constraint:* `bin/pipeline-events.json` "halt_reasons"
  array (`bin/pipeline-events.json:10-20`) is the closed-vocabulary
  registry; `qa-predicate-invalid` is one new entry.

  *Rejected alternative — share codes 33/34/35 across plan-contract
  and qa-predicate, demux by calling stage in
  `failure_outcome_for_exit`:* rejected because (a) the function
  signature today is `(exit_code, subcode)`; adding stage-aware
  demux would either thread stage everywhere or invent a "stage
  came from `$PIPELINE_STAGE`" implicit-context shape, both of
  which fight the existing API. (b) Pure-function-of-args
  determinism is a guard the retrospective's §1 filter relies on;
  contaminating it with `$PIPELINE_STAGE` reads creates a tested-
  but-brittle dependency.

  *Rejected alternative — code 36 = "predicate-execution-failed":*
  rejected because (a) predicate-execution-failure is not a halt
  condition — it's the verdict-fail path, which is the agent's
  decision to make via `bash bin/pipeline.sh event ... verdict
  fail --target implementing`; (b) the runner returning 0 (success)
  on an invalid predicate file but a failed check is the wrong
  semantics — the runner SUCCEEDED in evaluating; it just found
  failures. (c) Conflating "agent's verdict-fail" with "runner
  internal error" via exit code 36 muddies the call-site.

- **D-009. Test surface: one new test file
  `bin/verify-qa-test.sh` covering the runner; plus a content pin in
  `bin/agent-prompts-content-test.sh` for the new §6 step; plus an
  extension to `bin/render-prompt-rc0-test.sh` for the new
  `{qa_predicate_path}` token resolver. No new fixtures outside
  these three files.**

  Test cases for `bin/verify-qa-test.sh`:

  | # | Setup | Assert |
  |---|---|---|
  | V-1 | Predicate file absent | rc=38, output contains `qa-predicate-missing` |
  | V-2 | Predicate file present, JSON parse error | rc=36, output contains `qa-predicate-malformed` |
  | V-3 | Predicate file present, missing required field (e.g. `pass_criteria`) | rc=37, output contains `qa-predicate-incomplete` |
  | V-4 | Predicate file present, valid schema, all smoke commands exit 0 | rc=0, structured stdout report with `pass: true` |
  | V-5 | Predicate file present, valid schema, one smoke command exits non-zero | rc=0, structured stdout report with `pass: false` + the failing criterion's index + actual exit code |
  | V-6 | Predicate file present, valid schema, `file_exists` criterion's path is absent | rc=0, structured stdout report with `pass: false` |
  | V-7 | Predicate file present, valid schema, `grep` criterion's regex matches when `expect_match: true` | rc=0, structured stdout report with `pass: true` |
  | V-8 | Predicate file present, valid schema, `http_get` to a stub HTTP server returning 200 + `expect_status: 200` | rc=0, structured stdout report with `pass: true` |
  | V-9 | Predicate file present, `--ident` flag passed but does not match JSON's `issue_id` field | rc=37, output contains `qa-predicate-incomplete: issue_id mismatch` |

  V-8 needs a local HTTP stub. Two options:
  - Option A: use `python3 -m http.server` from the test (precedent: none in `bin/*-test.sh` today; would add a Python dependency to test-time but the project profile already includes python3 in Apple silicon defaults). REJECTED — adds a test-time runtime not in the project profile's Stack section.
  - Option B: use `nc -l` (BSD netcat) to serve a static response. REJECTED — nc behavior is BSD/GNU-divergent and the test fixtures already avoid this class (precedent: no test uses nc).
  - Option C (chosen): test V-8 mocks the runner's HTTP execution path by stubbing the `curl` invocation in `STUB_DIR/curl`, returning a canned response. Mirrors how `bin/linear-test.sh` stubs `curl` for Linear API calls.

  Content pin (`bin/agent-prompts-content-test.sh`): §6 contains
  the literal phrase `Emit verification predicate` (mirrors the
  ENG-108 pin shape at line 96 of agent-prompts-content-test.sh).

  Render-prompt cases (`bin/render-prompt-rc0-test.sh`): one new
  case (O — sibling of L/M/N from ENG-140) asserting that rendering
  the qa prompt resolves `{qa_predicate_path}` to a concrete
  absolute path containing `qa-predicate-ENG-`.

  *Reference to constraint:* CLAUDE.md "Tests are sibling shell
  scripts named `*-test.sh` in `bin/`. There is no test runner."
  `bin/verify-qa-test.sh` is the new sibling; existing tests get
  surgical extensions.

  *Rejected alternative — split test cases across multiple new
  files (e.g. `verify-qa-validate-test.sh`,
  `verify-qa-execute-test.sh`):* rejected on CLAUDE.md "Don't
  add features … beyond what the task requires." Plan-schema's
  test (`bin/plan-schema-test.sh`) is a single file covering all
  of cmd_validate's branches. Same shape applies.

  *Rejected alternative — integration test in `run-stage-test.sh`:*
  rejected on the same grounds as ENG-140 §D-006: `PIPELINE_DRY_RUN=1`
  short-circuits the dispatch path, so integration tests cannot
  observe the runner-from-agent path. The runner's contract is
  CLI-level and that's where it gets tested.

- **D-010. Scope boundary: NO changes to verdict-handler.sh,
  NO new transitions, NO dispatch cleave, NO post-dispatch hook
  in `bin/run-stage.sh`. The runner is introduced as a STANDALONE
  CLI in ENG-113; the orchestrator integration (calling
  verify-qa.sh from run-stage.sh as a post-dispatch detective) is
  carried by the next sub-ticket.**

  Specifically:

  | Site | Change in ENG-113 | Reason |
  |---|---|---|
  | `bin/verdict-handler.sh` | UNTOUCHED | No new transitions; the existing `qa\|implementing\|` row covers QA-fail loopback |
  | `bin/run-stage.sh` | UNTOUCHED (no `_validate_qa_predicate` hook) | The orchestrator-integration is the next sub-ticket; today the runner exists for manual operator use + agent-side use during QA |
  | `bin/dispatch.sh` | One-line addition: QA stage allowlist gets `Bash(bash bin/verify-qa.sh:*)` and `Bash(bash .pipeline/bin/verify-qa.sh:*)` | The QA agent must be able to invoke the runner to verify its own predicate before exiting; without the allowlist entry, the agent halts on a sandbox denial |
  | `bin/common.sh` | Two-line additions: `qa_predicate_path` helper + `_validate_pass_criterion` (D-007 refactor) | Enables the resolver (D-002) and the shared validator (D-007) |
  | `bin/render-prompt.sh` | Three-line addition: `qa_predicate_path` to `PROMPT_RESOLVERS`, resolver body, `_RENDER_QA_PREDICATE_PATH` binding in main() | Enables the `{qa_predicate_path}` token in §6 |
  | `AGENT_PROMPTS.md §6` | New step inserted at line ~1392, downstream steps renumbered | The agent's emit-predicate-first contract |
  | `bin/pipeline-events.json` | Add `qa-predicate-invalid` to `halt_reasons[]` | Closed-vocabulary registry |
  | `bin/common.sh::failure_outcome_for_exit` | Three new exit codes (36/37/38) | Exit-code taxonomy |
  | `bin/plan-schema.sh` | Refactor: replace inline criterion logic with `_validate_pass_criterion` call | D-007 |

  *Reference to constraint:* CLAUDE.md "Ticket sizing rubric (autonomy
  boundary)" — Axis 1 subsystems touched:
  - dispatch (`render-prompt.sh`, `dispatch.sh` one-line) — subordinate
  - agent prompts (`AGENT_PROMPTS.md` §6) — primary
  - Linear contract (`pipeline-events.json` one entry) — subordinate
  - tests/fixtures (new test file + extensions) — subordinate
  - one new helper script (`bin/verify-qa.sh`) — primary; technically
    new subsystem-shape ("verification runner") that didn't exist
    before. Axis-1 count = 2 primary, 3 subordinate.

  Axis 2 independent decisions: D-001 (schema), D-003 (CLI shape),
  D-007 (common.sh refactor) are independent design decisions but
  D-007 is subordinate to D-001 (the schema is the input; the
  validator structure is determined by the schema). D-001 is the
  primary decision. Rubric says "1 decision → autonomy-safe";
  ENG-113 sits at 1 primary decision + 2 subordinate-shape decisions.

  Umbrella veto: ENG-113 is NOT framed as a class/umbrella/structural
  issue — it's a sub-ticket of an umbrella (ENG-38). The umbrella
  veto fires on parents, not on sub-tickets that fall out of an
  umbrella's decomposition.

  *Reference to constraint:* the Linear ticket's "OUT" list pins
  the cleave-prompt sub-ticket as future scope; ENG-113 strictly
  observes that boundary by introducing the runner as a CLI without
  wiring it into the orchestrator's dispatch flow yet.

- **D-011. The runner executes shell from a JSON file. Authority
  surface: predicate file MUST live under `$PROJECT_STATE_DIR`
  (validated by the runner with a path-prefix check). Commands
  execute with `cwd = <worktree-from-flag-or-inferred>` and
  inherit the runner's environment. No setuid, no
  privilege-escalation, no env-var sanitization beyond what the
  shell does naturally.**

  Path-prefix check (concrete):

  ```bash
  # bin/verify-qa.sh::cmd_validate
  local realpath_file realpath_prefix
  realpath_file="$(cd "$(dirname "$file")" 2>/dev/null && pwd)/$(basename "$file")"
  realpath_prefix="$(cd "$PROJECT_STATE_DIR" 2>/dev/null && pwd)"
  if [[ "$realpath_file" != "$realpath_prefix"/* ]]; then
    _emit_malformed "predicate file must live under PROJECT_STATE_DIR; got $file"
    return 33
  fi
  ```

  *Rationale:* the runner is a code-execution gadget by design (it
  exists to run shell commands from a JSON file). The authority
  question is "who can put a malicious predicate where the runner
  will find it?" The path-prefix check pins the answer: only
  actors that can write to `$PROJECT_STATE_DIR` can supply
  predicates. That set is: (a) the orchestrator (legitimate),
  (b) the dispatched QA agent (legitimate via `Write` to the
  `_RENDER_QA_PREDICATE_PATH` exposed in its prompt), (c) the
  operator on the harness host (legitimate).

  Out-of-scope authority surfaces:
  - the QA agent writing to a worktree path — runner rejects (path
    not under `$PROJECT_STATE_DIR`).
  - cross-issue: a QA dispatch for ENG-A writing to ENG-B's
    predicate path — the `--ident` flag's issue_id cross-check
    catches this (per D-001's `issue_id` field).
  - a malicious PR adding a predicate file inside the worktree —
    runner rejects (worktree is not under `$PROJECT_STATE_DIR`;
    they are sibling paths under `$HARNESS_STATE_DIR`).

  *Reference to constraint:* CLAUDE.md "Per-issue state directory"
  — `$PROJECT_STATE_DIR` is the legitimate per-project scratch
  location. Restricting the runner to this prefix is the same
  shape as the run-stage sandbox restrictions for the
  envelope-validator transcript.

  *Reference to constraint:* CLAUDE.md "Be careful not to introduce
  security vulnerabilities such as command injection." The runner
  is a deliberate command-execution channel; the path-prefix
  check + the orchestrator-owned predicate path + the
  Write-via-sandboxed-agent shape are the three boundary
  defenses.

  *Rejected alternative — sandbox the runner under a `claude -p`
  subprocess invocation:* rejected because (a) circular — the
  whole point of the runner is to run **without** invoking claude
  (Linear ticket IN bullet: "without invoking claude"); (b) the
  runner is a CI-shaped tool: deterministic, fast, no LLM in the
  loop. Re-introducing claude defeats the entire split.

  *Rejected alternative — disallow `smoke` kind entirely (only
  file_exists, grep, http_get):* rejected because (a) smoke is
  the canonical shape of every `bash bin/*-test.sh` invocation
  the harness uses; QA cannot verify gates without running them;
  (b) plan-schema.sh's smoke kind is already part of the
  established schema and removing it for QA-side would surprise
  the agent's prompt-rendering of plan.json.

  *Rejected alternative — restrict `smoke` to a hardcoded
  allowlist of commands (e.g. only `bash bin/*-test.sh`):*
  rejected because (a) the project profile's Build & test gates
  section is the established place for stack-aware test commands;
  the runner inheriting the profile would dispatch arbitrary
  profile-named gates anyway; (b) hardcoded allowlist hits the
  same wildcard-glob pitfall as `dispatch.sh::allowed_tools_for`
  documented in CLAUDE.md "Wildcard pitfall." Pre-empting it with
  enumeration is feasible but adds a new maintenance surface
  for one ticket's worth of safety.

- **D-012. Runner stdout shape: JSON Lines, one line per
  pass_criterion + a final summary line.** Each criterion line:
  `{"index": <int>, "kind": "<smoke|file_exists|grep|http_get>",
  "pass": <bool>, "detail": "<string|null>"}`. Final summary
  line: `{"summary": true, "total": <int>, "passed": <int>,
  "failed": <int>, "duration_ms": <int>}`. Stderr carries runner
  log/info lines (mirrors the harness's existing log convention).

  *Rationale:* JSON Lines is greppable + jq-streamable + survives
  partial writes. The agent (or post-dispatch hook) reads stdout
  with `tail -n 1` to get the summary, or `head -n N | jq` to
  inspect each criterion. Matches the existing `metrics.sh
  events.jsonl` line-per-event convention.

  *Reference to constraint:* CLAUDE.md "Metric writes go through
  `bin/metrics.sh` (lands in `events.jsonl`)." JSONL output is
  consistent with the harness's existing append-only stream
  shape.

  *Rejected alternative — single JSON object covering all criteria
  + summary:* rejected because (a) partial output on a runner
  crash is unparseable JSON; JSONL recovers the prefix; (b) the
  agent's `Read` of the file via stdin would block until full
  output; JSONL streams.

  *Rejected alternative — human-readable text output (tabular):*
  rejected because (a) the next sub-ticket cleaves verification
  into its own dispatch; structured output is the inter-process
  contract there; (b) jq parsing tabular output is fragile.

## 3. Architecture (where code goes)

| Site | Change | Lines (approx.) |
|---|---|---|
| `bin/verify-qa.sh` (NEW) | Standalone CLI: `validate <file>`, `execute <file>` (or one `validate` that does both, configurable via `--no-execute`). Sources common.sh. Reuses `_validate_pass_criterion`. | ~280 |
| `bin/verify-qa-test.sh` (NEW) | Test cases V-1..V-9, sibling sentinel pattern, source-and-stub. | ~250 |
| `bin/plan-schema.sh` | Refactor: replace inline per-criterion logic (lines 181-260) with `_validate_pass_criterion` call. | -80 +5 net |
| `bin/common.sh` | Add `qa_predicate_path <ident>` helper (~3 lines) + `_validate_pass_criterion` (lifted from plan-schema.sh + `--kinds` flag + `http_get` kind). Export both. | +~110 |
| `bin/common.sh::failure_outcome_for_exit` | Three new entries: 36 → qa-predicate-malformed, 37 → qa-predicate-incomplete, 38 → qa-predicate-missing. | +3 |
| `bin/render-prompt.sh::PROMPT_RESOLVERS` | Add `qa_predicate_path=_resolve_qa_predicate_path`. | +1 |
| `bin/render-prompt.sh` | Add `_resolve_qa_predicate_path` body (~3 lines) + bind `_RENDER_QA_PREDICATE_PATH="$(qa_predicate_path "$issue_id")"` in main(). | +~5 |
| `bin/render-prompt-rc0-test.sh` | New case O for `{qa_predicate_path}` token resolution. | +~30 |
| `bin/agent-prompts-content-test.sh` | One content pin: §6 contains `Emit verification predicate`. | +~6 |
| `AGENT_PROMPTS.md §6` | Insert new step at line ~1392, renumber existing steps 1→8 down by one. | +~25 net (new step + renumber) |
| `bin/pipeline-events.json::halt_reasons[]` | Add `qa-predicate-invalid`. | +1 |
| `bin/dispatch.sh::allowed_tools_for` (qa stage) | Append `Bash(bash bin/verify-qa.sh:*)` and `Bash(bash .pipeline/bin/verify-qa.sh:*)`. | +1 (in-line) |

Total: ~720 LOC across two new files + targeted edits to six existing
files. Zero changes to `bin/run-stage.sh`, `bin/verdict-handler.sh`,
`bin/poll.sh`, `bin/scope-check.sh`, `bin/run-local.sh`,
`bin/run-local-helpers.sh`, `bin/classify-failure.sh`, `bin/metrics.sh`.

## 4. Data Flow

Pre-ENG-113, on a QA dispatch:

1. Orchestrator dispatches §6 QA agent.
2. Agent reads progress.md + Linear issue + brainstorm + plan.
3. Agent runs gate commands from the project profile.
4. Agent writes adversarial tests (§5 budget).
5. Agent emits `verdict pass --stage qa` or `verdict fail --target
   implementing`.
6. Agent writes stage-summary-qa.md.

NO machine-readable verification record. Re-running the same checks
requires re-dispatching the agent.

Post-ENG-113, same flow:

1. Orchestrator dispatches §6 QA agent. (UNCHANGED)
2. Agent reads progress.md + Linear issue + brainstorm + plan +
   **the sibling plan.json (NEW — agent's responsibility)**.
3. **NEW STEP: Agent writes
   `{qa_predicate_path}` = `$(issue_dir)/qa-predicate-<ident>.json`
   via the Write tool. Content: pass_criteria[] union of (a) plan.json's
   pass_criteria[] verbatim + (b) QA-authored adversarial smoke /
   file_exists / grep / http_get criteria.**
4. Agent runs gate commands from the project profile. (UNCHANGED)
5. Agent writes adversarial tests (§5 budget). (UNCHANGED)
6. **NEW SUB-STEP (optional in ENG-113, mandatory after cleave): Agent
   invokes `bash bin/verify-qa.sh validate {qa_predicate_path}
   --ident {issue_id}` to cross-check its own predicate. Output is
   appended to the PR summary comment.**
7. Agent emits verdict marker. (UNCHANGED)
8. Agent writes stage-summary-qa.md. (UNCHANGED)

Per-criterion execution flow inside `bin/verify-qa.sh`:

```
verify-qa.sh validate <file> [--ident <ENG-N>] [--worktree <path>]
  ↓
  Schema-validate the JSON (delegates to common.sh::_validate_pass_criterion --kinds smoke,file_exists,grep,http_get)
  ↓ rc 33 → qa-predicate-malformed → exit 36
  ↓ rc 34 → qa-predicate-incomplete → exit 37
  ↓ rc 35 → qa-predicate-missing → exit 38
  ↓ rc 0 → continue
  ↓
  For each criterion in pass_criteria[]:
    ↓ Emit a JSONL line {"index":i, "kind":..., "pass":..., "detail":...}
    ↓ kind=smoke: bash -c "<command>"; check expect_exit + optional stdout regex
    ↓ kind=file_exists: [[ -e "<path>" ]] with worktree-anchored path
    ↓ kind=grep: grep -E "<pattern>" "<path>"; flip on expect_match
    ↓ kind=http_get: curl -sS -o /dev/null -w '%{http_code}' "<url>"
  ↓
  Emit final summary JSONL line
  ↓
  Return 0 (regardless of pass/fail — caller reads stdout to decide)
```

Caller-side flow (today, agent-only; after cleave, orchestrator-only):

- The QA agent reads the JSONL output via `bash bin/verify-qa.sh
  validate {qa_predicate_path} --ident {issue_id} | tail -n 1` to
  get the summary.
- If `summary.failed > 0` → emits `verdict fail --target implementing`.
- If `summary.failed == 0` → continues to evaluation phase.

## 5. Error Handling

The runner has five distinct failure modes:

- **Predicate file absent** (`-f "$file"` fails). Exit 38,
  `qa-predicate-missing`. Halt reason `qa-predicate-invalid`. The
  agent has the overwrite-on-every-dispatch contract — file is
  missing only in the pathological case where the QA dispatch
  crashed before writing or the agent skipped the new step 1.
- **Predicate file present, JSON parse error.** Exit 36,
  `qa-predicate-malformed`. Halt reason `qa-predicate-invalid`.
  Operator inspects the JSON for heredoc-quoting bugs or stray
  prose in the file body.
- **Predicate file present, schema-incomplete** (missing required
  field, wrong type, unknown `kind`). Exit 37,
  `qa-predicate-incomplete`. Halt reason `qa-predicate-invalid`.
- **Path-prefix violation** (file outside `$PROJECT_STATE_DIR`).
  Exit 36 (treated as malformed — the file is unparseable for
  authority reasons even if its JSON is syntactically valid). The
  operator's halt comment quotes the path and the expected prefix.
- **Predicate executed; one or more criteria failed.** Exit 0
  with stdout summary `failed > 0`. NOT a halt — caller (agent
  today, orchestrator after cleave) decides verdict.

Individual criterion-execution failures:

- **Smoke command not on PATH / not allowlisted in the agent's
  sandbox.** The runner shells out via `bash -c`; PATH errors
  surface as non-zero exit codes from the smoke binary. The
  criterion's JSONL line carries `detail: "command not found"`.
- **File-exists path is relative.** Runner anchors to `--worktree`
  if supplied, else to `$TARGET_REPO`. Paths starting with `/`
  are absolute and used as-is.
- **Grep regex compile error.** Bash's `grep -E` returns 2 on
  regex compile failure. Runner catches rc=2 and emits
  `detail: "regex compile error"` with `pass: false`.
- **http_get connection refused / timeout.** Curl returns
  non-zero; `expect_status` mismatch → `pass: false` with
  `detail: "connection refused"` (or `"timeout"`). Default
  timeout: 10 seconds per request (hardcoded; not configurable
  in v1 per the schema-minimality clause).

Sanitisation of agent-controlled text in halt-comment bodies:

- The runner's stdout (JSONL) is **not** embedded verbatim in
  halt comments. The halt-comment body says only "predicate
  failed — see $(issue_dir)/qa-predicate-output.jsonl". This
  avoids the `<!--` marker-hijack class (CLAUDE.md "ENG-87
  C4 sanitisation pattern"). Plan-schema's `_post_plan_contract_halt`
  mirrors the same shape (its body says "see schema validator
  output" rather than embedding it).

## 6. Edge Cases

- **QA dispatch is a back-fill PR (Decision-path D in §6).**
  Path D's contract today is "skip coverage audit, adversarial
  budget, regression-intent audit." Post-ENG-113 the predicate
  is STILL emitted, but its pass_criteria[] is just plan.json's
  contract (no QA-added adversarial criteria). The runner
  still validates and executes; the smoke commands are the
  project profile's build/test gates — exactly the existing
  path-D behavior.

- **plan.json is absent (legacy issue planned before ENG-122 or
  plan-contract was missing).** `_resolve_plan_json` falls back
  to "(no plan.json — falling back to prose plan)" in the
  rendered prompt. The QA agent has no plan.json to source its
  pass_criteria[] from. Two sub-cases:
  - Sub-case A: the issue HAS a plan.json — agent uses it.
  - Sub-case B: the issue does NOT have a plan.json — the new
    step 1 instructs the agent to emit a predicate whose
    pass_criteria[] is QA-authored from the prose plan +
    Failure Mode → Test Map. This is a degraded shape (no
    plan.json contract to mirror) but the predicate still
    exists. Acceptable cost: ENG-122 has not yet rolled out
    everywhere; the prose-plan fallback survives.

- **Predicate file already exists from a prior QA dispatch
  (overwrite-on-every-dispatch contract — same as
  stage-summary).** Agent's Write overwrites the file. New
  dispatch's predicate replaces the prior one. Correct.

- **Runner invoked outside the harness orchestrator (operator
  manual repro).** The operator runs `bash bin/verify-qa.sh
  validate /path/to/qa-predicate-ENG-N.json --ident ENG-N`.
  PROJECT_STATE_DIR must be set (require_env in main()).
  Worktree-anchored paths default to `$TARGET_REPO`. Works
  identically to the agent's invocation.

- **Predicate's `smoke` criterion exec'd while the agent is
  inside its dispatch sandbox.** The agent's `--allowed-tools`
  list governs which sub-commands `bash -c` can invoke. The
  sandbox sees the runner's invocation of `bash -c "..."` as
  a single allowed `Bash(bash bin/verify-qa.sh:*)` pattern
  match; the runner's inner `bash -c` is then unconstrained
  from the sandbox's perspective. This is a design concession:
  the runner is privileged-execution-via-allowlist. Documented
  in D-011's authority surface section.

- **`http_get` to a localhost URL that's not yet serving (CI
  environment, dev-server not started).** Curl returns
  connection-refused → `pass: false` → criterion fails. The
  predicate should not include `http_get` checks that the test
  environment cannot satisfy; if it does, the criterion fails
  loud rather than silent. This is the desired behavior.

- **A predicate with zero criteria (`pass_criteria: []`).**
  Schema validation rejects it (D-001 mirrors plan-schema's
  `len >= 1` requirement). Exit 37,
  `qa-predicate-incomplete`.

- **An agent-emitted predicate with a `command` field containing
  `;` or `&&`-chained subshells.** The runner runs the command
  via `bash -c "$command"` — bash interprets metacharacters
  normally. There is no sanitization. This is consistent with
  the plan-schema `smoke` kind today (CLAUDE.md "ENG-87
  chained-command blind spot" warns about this same shape for
  the envelope validator; the runner is by-design open to it).

- **`{qa_predicate_path}` token referenced outside §6 (e.g.
  accidentally in §3 or §7).** The resolver returns the
  per-issue path string regardless of rendering stage; downstream
  stages would see a path they have no Write access to. No
  semantic damage; just an unused token surface. (Same shape
  as `{qa_findings}` from ENG-140 — resolver registered globally,
  token only referenced where meaningful.)

- **Worktree-anchored `file_exists` path is `..`-relative or
  absolute outside the worktree.** Runner resolves the path
  literally; bash's `[[ -e ]]` returns true if the path exists
  on the host filesystem regardless of worktree containment.
  This is a false-positive class — a malicious predicate could
  assert `file_exists: /etc/passwd` to pass without checking
  the worktree. Mitigation: path-traversal sanitisation in the
  runner (reject `..` and absolute paths in `file_exists` /
  `grep` kinds; require all such paths to be worktree-relative).
  Documented as D-013 below if the brainstorm's persona-review
  raises it as P0 — otherwise defer to follow-up. (Persona
  review confirmed P0 — see §10 security persona findings →
  D-013 added.)

- **D-013. Path-traversal hardening for `file_exists` and
  `grep` kinds: paths must be worktree-relative (no leading `/`,
  no `../` segments). Validator rejects with rc=37 if
  violated.** The runner's path-handling concentrates inside
  `_validate_pass_criterion` (kind=file_exists / kind=grep);
  a single `[[ "$path" =~ \.\. ]] || [[ "$path" == /* ]]`
  guard rejects both shapes. The `smoke` kind is exempt
  (smoke commands can run any binary on PATH); `http_get` is
  exempt (URLs are not filesystem paths).

  *Reference to constraint:* CLAUDE.md "Be careful not to
  introduce security vulnerabilities." Path-traversal in a
  contract-driven validator is the same class as command
  injection in a templated SQL query.

  *Rejected alternative — sandbox the runner's filesystem
  reads via chroot or bwrap:* rejected because (a) macOS hosts
  (the harness's primary target) have no native chroot/bwrap
  equivalent; (b) the schema-level check is sufficient for
  the agent-emitted-predicate threat model.

## 7. Open Questions

- **OQ-1. Should the runner cache predicate-execution results
  per-(dispatch_id, predicate-file-hash) so a re-run reads from
  cache?** Plausible — would let the agent invoke the runner
  multiple times without re-executing smoke commands.
  Out-of-scope for ENG-113 (the Linear ticket says "runner that
  executes predicates and reports pass/fail"); deferred to
  follow-up. The cache key would need to include the
  pipeline_content_hash to invalidate on harness updates
  (CLAUDE.md "pipeline_content_hash" §).

- **OQ-2. Should the predicate carry a `description` field per
  criterion to help operators read the JSON?** Mild operator
  ergonomics benefit; would slightly expand schema. Defer to
  follow-up; plan-schema.sh has no `description` field today and
  symmetry argues for not adding one here either.

- **OQ-3. Should `bin/verify-qa.sh` be added to the
  `bin/secret-probe-lint.sh` allowlist so the smoke command
  bodies aren't scanned for secret-shaped substrings?**
  Plausible — predicate commands sometimes legitimately invoke
  curl against authenticated APIs; the lint's `*KEY|*TOKEN|*SECRET`
  pattern could false-positive on a sub-string of the URL.
  Mitigation: the lint scans bash source files for `${VAR:-...}`
  shapes; JSON files are not bash source and the lint does not
  scan them today. Verify with a test fixture that includes a
  predicate referencing `$LINEAR_API_KEY` in a smoke command —
  confirm the lint does not trip. Likely no-op; flag for
  iter-1 verification.

- **OQ-4. Should the runner emit a `metrics.sh
  qa_predicate_execution` event per criterion?** Plausible —
  would let the retrospective measure how often each criterion
  kind fails. Deferred until the orchestrator-side wiring lands
  (next sub-ticket): without orchestrator integration, the
  metric would be emitted from agent context, which is the
  wrong writer-lane for events.jsonl (lane fence — ENG-41).

- **OQ-5. Should `_validate_pass_criterion` move to a separate
  helper file (e.g. `bin/lib-pass-criterion.sh`) instead of
  common.sh, to bound common.sh's parse-time growth?** Open
  tension: common.sh is sourced by every test, every script.
  Adding ~110 lines of jq + bash bumps parse-time by an
  estimated 3-5ms per invocation. The harness's tick rate is
  every 5 min — well below the threshold where parse-time
  matters. But the principle ("common.sh stays narrow") is
  legitimate. Recommend in-PR review (with measurable benchmark
  evidence either way); commit either path is reversible.

- **OQ-6. How does the QA predicate interact with build's P2
  preflight?** Build today re-runs the smoke commands implicitly
  via CI; the predicate is a different mechanism. Future
  consolidation possible (build reads the same predicate file),
  but explicitly OUT of ENG-113's scope. Filed as follow-up
  thinking for ENG-38's coordinator ticket.

## 8. ADR stress test

There is no `docs/knowledge/decisions.md` in the harness repo
(verified — `ls docs/knowledge/` returns empty). Durable
architectural rules live in CLAUDE.md. ENG-113 puts pressure on
the following:

- **CLAUDE.md "Per-stage allowed tool lists are centralized in
  `dispatch.sh::allowed_tools_for`."** A new bin script
  (`verify-qa.sh`) needs to be allowlisted for the QA stage.
  The mechanism is documented (D-010 table) and the
  composition is `base + profile + extras` per ENG-94. The
  brainstorm's recommended placement is in the `base` for the
  `qa` case-arm at `bin/dispatch.sh:457`. No rule pressure;
  this is exactly the documented add-a-tool path.

- **CLAUDE.md "Don't add features … beyond what the task
  requires."** The brainstorm proposes one new bin script
  (verify-qa.sh, ~280 LOC), one common.sh helper refactor
  (~110 LOC + ~80 LOC reuse), one new exit-code triplet, one
  new halt reason, one new `kind` (http_get), one new prompt
  token. Cumulative footprint is ~720 LOC for a contract-
  extraction ticket. The Linear scope IN bullets name four
  concrete deliverables (predicate format, AGENT_PROMPTS.md
  edit, runner, test fixture); the brainstorm maps each to
  exactly one of these decisions. The common.sh refactor
  (D-007) is the only addition beyond the literal scope, and
  the rationale (don't duplicate ~80 LOC of jq) is documented
  and bounded.

- **CLAUDE.md "Cross-dispatch staleness contract (ENG-87) —
  per-issue files clear-on-dispatch-start."**
  `qa-predicate-<ident>.json` is a per-issue file; under the
  ENG-87 contract, it would be subject to clearing on the
  CURRENT stage's dispatch start. `_clear_current_stage_slots`
  at `bin/run-stage.sh:931-939` clears files matching the
  current stage's name. Recommendation: extend the slot list
  to include `qa-predicate-<ident>.json` so a QA re-dispatch
  starts with a clean slate. This is a small mechanical
  addition; documented as the optional integration touch
  (D-010's UNTOUCHED list applies to run-stage.sh's hook
  block, NOT to the slot-clearing routine — though the
  brainstorm could go either way; current recommendation:
  leave the slot-clearing alone for ENG-113 and add it
  alongside the next-sub-ticket's orchestrator integration).

- **CLAUDE.md "Marker shapes — only two families exist
  (ENG-60)."** A new halt reason `qa-predicate-invalid` is
  registered in `bin/pipeline-events.json::halt_reasons[]`.
  This is the documented extension shape. No rule pressure.

- **CLAUDE.md "Sub-agent debris (ENG-100)."** The runner does
  NOT call sub-agents. The QA agent's sub-agent
  (bug-reproduction-validator at §5 step 5) is unchanged.
  Sub-agent debris rules continue to apply transitively
  through the unchanged §5.

## 9. Anti-bias checks

### Simpler alternatives

For each major decision, the §2 block enumerates rejected
alternatives. The most consequential rejected alternatives:

- **D-001 (schema):** rejected "derive from plan.json only"
  and "TOML/YAML predicate format" and "inline in stage-summary."
- **D-003 (CLI shape):** rejected "fold into plan-schema.sh"
  and "Python/Go re-write."
- **D-007 (common.sh refactor):** rejected "duplicate the
  validator into verify-qa.sh."
- **D-011 (authority surface):** rejected "sandbox via claude
  subprocess" (circular) and "disallow smoke kind" (defeats
  purpose).

The biggest tension between simpler-vs-correct is D-007 — the
common.sh refactor adds ~110 LOC. The cheapest path (duplicate
the validator) was explicitly rejected on the ENG-87 drift-
class basis. Verification cost: with two callers for the same
schema, drift would compound; the refactor is a one-time
investment.

### Assumption inventory

Every named code-level fact is cross-referenced against the
codebase below. **assumed** items need verification during
iter-1 implementation; **verified** items have a quoted
`path:line` reference.

- **verified.** `bin/render-prompt.sh:41-57` carries
  `PROMPT_RESOLVERS` registry; new token additions land here.
  (Direct read: lines 41-57 enumerated above.)
- **verified.** `bin/render-prompt.sh:230` defines
  `_resolve_progress_md_path` — the path-shape resolver
  precedent for D-002.
- **verified.** `bin/render-prompt.sh:482-521` shows the
  `_RENDER_*=...` binding pattern in main(), including the
  precedent `_RENDER_PROGRESS_MD_PATH` binding at line 512+521.
- **verified.** `bin/common.sh:247-279` carries
  `failure_outcome_for_exit`; exit codes 33-35 already mapped
  to `plan-contract-*` (lines 273-275). New codes 36-38 slot
  cleanly.
- **verified.** `bin/pipeline-events.json:10-20` carries
  `halt_reasons[]` array; `plan-contract-invalid` already
  present (line ~19). New entry `qa-predicate-invalid` slots
  in.
- **verified.** `bin/plan-schema.sh` exists (297 lines) with
  `cmd_validate` (line 60) and `main` (line 285). The per-
  criterion validation at lines 181-260 is the refactor source
  for D-007.
- **verified.** `bin/dispatch.sh::allowed_tools_for` case-arm
  for `qa` at line 457 — base allowlist that gets the new
  `Bash(bash bin/verify-qa.sh:*)` entry.
- **verified.** `AGENT_PROMPTS.md §6` runs lines 1341-1534.
  Step 1 (flaky-pattern triage) begins at line 1394. New step
  inserts at line ~1392 (immediately before flaky-pattern
  triage, immediately after branch-shape detection at
  line 1369).
- **verified.** `bin/run-stage.sh::_validate_dispatch_envelope`
  at line 966 and `_validate_plan_contract` at line 1056 —
  these are the precedent shapes for the post-dispatch
  validator hook the NEXT sub-ticket will mirror. ENG-113 does
  NOT add a similar hook (D-010 scope boundary).
- **verified.** `bin/common.sh::progress_md_path` exported per
  common.sh (referenced in `bin/render-prompt.sh:482,512,521`).
  Precedent for `qa_predicate_path` helper shape.
- **verified.** `_clear_current_stage_slots` in
  `bin/run-stage.sh:931-939` clears CURRENT stage's summary
  only; OTHER stages preserved (per ENG-140 §D-007). This is
  the precedent for the cross-dispatch staleness handling.
- **verified.** `bin/verdict-handler.sh:36` carries
  `qa|implementing|` row — qa-loopback transition is already
  legal; D-010 confirms no verdict-handler changes.
- **verified.** `bin/agent-prompts-content-test.sh` line 96
  (referenced by ENG-140 brainstorm) is the content-pin
  precedent for D-009.
- **assumed.** `_validate_pass_criterion` does not yet exist
  in `bin/common.sh`. D-007 creates it from
  `plan-schema.sh:181-260`. **Iter-1 must lift and refactor;
  this is the load-bearing assumption for D-007.**
- **assumed.** `bin/render-prompt-rc0-test.sh` cases follow a
  pattern letter-indexed by alphabet (case G/H/I from ENG-139;
  case L/M/N from ENG-140). D-009 names case "O" but
  iter-1 should verify the next free letter and use that
  instead. **Mechanical, low-risk.**
- **assumed.** `bin/common.sh` is the canonical home for
  `_validate_pass_criterion` (vs. a new
  `bin/lib-pass-criterion.sh`). OQ-5 flags the tension; iter-1
  must measure parse-time delta. **Reversible at PR review.**
- **assumed.** `curl` is on the harness host PATH (project
  profile's Stack section lists curl). `http_get` execution
  depends on this. **Verified by the project profile's
  install requirements; iter-1 fail-loud if missing.**
- **assumed.** The `--kinds` flag is the cleanest API for the
  shared validator. D-007's alternative (separate helper
  scripts per kind) was rejected. **One-way door; reversible
  in a future ticket if the API surface proves awkward.**

### Codebase-fact verification

Cross-checked each `path:line` reference against the worktree
at the dispatch's branch tip (commit c23d0ff):

| Claim | File | Line | Verified |
|---|---|---|---|
| `PROMPT_RESOLVERS` registry | `bin/render-prompt.sh` | 41-57 | yes (Read confirmed) |
| `_resolve_progress_md_path` | `bin/render-prompt.sh` | 230 | yes (Grep confirmed) |
| `_resolve_qa_findings` | `bin/render-prompt.sh` | 286 | yes (Read confirmed — ENG-140 landed) |
| `_RENDER_QA_FINDINGS_PATH` binding | `bin/render-prompt.sh` | 515 | yes (Read confirmed) |
| `failure_outcome_for_exit` taxonomy | `bin/common.sh` | 247-279 | yes (Read confirmed) |
| Exit codes 33/34/35 already in taxonomy | `bin/common.sh` | 273-275 | yes (Read confirmed) |
| `halt_reasons[]` in pipeline-events.json | `bin/pipeline-events.json` | 10-20 | yes (Read confirmed) |
| `plan-contract-invalid` halt reason present | `bin/pipeline-events.json` | (in array) | yes (Read confirmed) |
| `cmd_validate` in plan-schema.sh | `bin/plan-schema.sh` | 60 | yes (Read confirmed) |
| Per-criterion validation logic | `bin/plan-schema.sh` | 181-260 | yes (Read confirmed) |
| `main` in plan-schema.sh | `bin/plan-schema.sh` | 285 | yes (Read confirmed) |
| qa stage allowed_tools | `bin/dispatch.sh` | 457 | yes (Read confirmed) |
| §6 QA section in AGENT_PROMPTS.md | `AGENT_PROMPTS.md` | 1341-1534 | yes (Read confirmed) |
| §6 Step 1 (flaky-pattern triage) | `AGENT_PROMPTS.md` | 1394 | yes (Read confirmed) |
| §6 branch-shape detection | `AGENT_PROMPTS.md` | 1365-1369 | yes (Read confirmed) |
| `_validate_dispatch_envelope` | `bin/run-stage.sh` | 966 | yes (Grep confirmed) |
| `_validate_plan_contract` | `bin/run-stage.sh` | 1056 | yes (Read confirmed) |
| `_clear_current_stage_slots` | `bin/run-stage.sh` | 931-939 | yes (Grep confirmed, comment quoted from ENG-140 brainstorm §8) |
| `qa|implementing|` loopback row | `bin/verdict-handler.sh` | 36 | yes (Grep confirmed) |
| `PIPELINE_LOOPBACK_SOURCE` export | `bin/run-stage.sh` | 1449 | yes (Read confirmed) |
| `_resolve_loopback_source` definition | `bin/run-stage.sh` | 144 | yes (Grep confirmed) |
| `is_benign` profile-driven | `bin/scope-check.sh` | — | not directly relevant to ENG-113; no claims about it |

All code-level claims are **verified**. The two `assumed` items
in the assumption inventory above are forward-looking design
choices, not codebase claims; iter-1 implementation will
materialise them.

## 10. Persona review

Personas run in the mandated order:
design → security → scope → coherence → product → feasibility.
Iteration 1.

### 10.1 Design persona

**Verdict: PASS**

Findings:
- The contract-extraction shape (D-001 + D-002 + D-005) is a
  clean separation: schema in JSON, path in env, prompt-step
  to emit. Matches ENG-122's plan.json shape and ENG-108's
  progress-md shape.
- D-007's common.sh refactor is the right call. Two callers
  for the same validator is the threshold where duplication
  cost exceeds parse-time cost.
- D-008's exit-code split (36/37/38 vs 33/34/35 for plan)
  cleanly disambiguates the two source halts at the
  `failure_outcome_for_exit` layer without context-aware demux.
- D-012's JSONL output is consistent with `events.jsonl` and
  parseable with `jq -c`.

No P0 design findings. Two non-blocking observations folded
into the open questions (OQ-5 on common.sh's growth, OQ-2 on
description field).

### 10.2 Security persona

**Verdict: PASS (with one P1 absorbed into D-013)**

Findings:
- **P0 → resolved.** Initial review of D-011 (authority surface)
  noted that `file_exists` and `grep` kinds with absolute
  paths could be used to assert against host-filesystem state
  outside the worktree. A malicious predicate could `file_exists:
  /etc/passwd` and pass without verifying anything about the
  feature. Added D-013 to harden via path-traversal check
  (reject `..` segments and absolute paths in file_exists /
  grep). Smoke and http_get are exempt by design (they don't
  use filesystem paths).
- **P1 reviewed.** The runner's `bash -c "$command"` shape
  in `smoke` kind is open to chained metacharacters; this is
  consistent with plan-schema.sh's existing smoke behavior
  and is the documented authority surface (D-011). No new
  ceiling introduced.
- The path-prefix check (D-011 concrete code) constrains
  WHO can supply predicates to actors with write access to
  `$PROJECT_STATE_DIR`; this matches the existing run-stage
  authority model.
- Halt-comment sanitisation (D-005 + §5) mirrors
  `_post_plan_contract_halt`'s `<!--` escaping pattern — no
  marker hijack via embedded predicate output.

No P0 security findings after D-013 was added in the second
pass within iteration 1.

### 10.3 Scope persona

**Verdict: PASS**

Findings:
- D-010's UNTOUCHED list precisely tracks the Linear ticket's
  OUT bullets (cleave-prompt sub-ticket and evaluation-half
  changes).
- The common.sh refactor (D-007) is the only scope addition
  beyond literal Linear text. Justified by the two-caller
  threshold + ENG-87 drift-class avoidance. Bounded: one
  function move, no API expansion.
- §6's renumber (D-006) is in-scope per the Linear ticket's
  "AGENT_PROMPTS.md qa section instructs agent to emit
  predicates before reasoning" bullet — the renumber is the
  mechanical consequence of inserting a new pre-step.
- The new `kind: http_get` matches the Linear IN bullet
  "URLs to navigate" exactly. No speculative kinds
  (`web_socket`, `database_query`, etc.).

No scope creep findings. The brainstorm explicitly flags two
deferred items: orchestrator-side wiring (next sub-ticket)
and metrics emission (OQ-4 — deferred to post-cleave).

### 10.4 Coherence persona

**Verdict: PASS**

Findings:
- The schema design (D-001) mirrors plan.json's structure
  exactly — same `pass_criteria[]` shape, same `kind`
  discriminated union. A reader (operator or downstream
  agent) sees one model across both files.
- D-002's `_resolve_qa_predicate_path` resolver is byte-for-
  byte the same shape as `_resolve_progress_md_path` and
  `_resolve_review_findings_path`. Token-token-resolver-
  resolver-binding-binding pattern preserved.
- D-008's exit-code triplet (36/37/38) is contiguous with
  plan-contract's triplet (33/34/35); both share the same
  halt-reason single-coarse pattern.
- D-009's test structure follows the established
  `*-test.sh` sibling convention.

One mild dissonance: the `qa_predicate_schema_version: 1`
field name is verbose. plan.json uses `plan_schema_version:
1`. Both spell out their context. Mirrors. Accepted.

No P0 coherence findings.

### 10.5 Product persona

**Verdict: PASS**

Findings:
- The split serves ENG-38's umbrella goal (separating
  verification from evaluation). ENG-113 lands the contract
  surface that makes the cleave possible.
- Operator value: post-ENG-113, a halt on a qa-predicate-invalid
  reason gives the operator a concrete file to inspect
  (`qa-predicate-<ident>.json`) rather than re-running the QA
  agent to see what failed.
- Future product value (cleave sub-ticket): once the runner
  is orchestrator-invoked, a QA dispatch's verification half
  is deterministic and re-runnable from CI — no LLM in the
  inner loop for the verification path.
- Cost trade-off: ~720 LOC for a contract-extraction
  ticket is on the heavier side, but four of the five new
  artifacts (verify-qa.sh, verify-qa-test.sh, common.sh
  refactor, agent-prompts step) are direct one-to-one
  mappings from the Linear ticket's IN bullets. The refactor
  (D-007) is the only optional expansion and is bounded
  to ~190 LOC net.

No product gaps. The brainstorm honours the umbrella's
sequencing (this sub-ticket → cleave-prompt sub-ticket →
evaluation-side ticket).

### 10.6 Feasibility persona (gating)

**Verdict: PASS (zero P0 findings)**

Findings:
- All `verified` items in §9.2's codebase-fact verification
  table are accurate. Direct reads confirm:
  - `PROMPT_RESOLVERS` is the registry shape; new tokens
    land at lines 41-57.
  - `_resolve_progress_md_path` is the path-resolver
    precedent.
  - `failure_outcome_for_exit`'s case statement matches the
    proposed extension shape.
  - `_validate_plan_contract` (post-dispatch hook precedent)
    is at line 1056 and follows the exact pattern ENG-113
    will replicate in the next sub-ticket.
  - `bin/plan-schema.sh:181-260` is the refactor source for
    `_validate_pass_criterion`.
  - `pipeline-events.json::halt_reasons[]` accepts a new
    entry without code changes (closed vocabulary registry).
- The new exit codes 36/37/38 do not collide with
  existing codes (verified against `failure_outcome_for_exit`
  body: 30/31/33/34/35/124 present; 36/37/38 free).
- The new `kind: http_get` requires `curl` on PATH — confirmed
  by CLAUDE.md "PATH expectations on the launchd host" §:
  "Harness tools (`gtimeout`, `gh`, `claude`, `jq`, `awk`,
  `sed`, `git`, `curl`) must resolve via Homebrew/system
  segments."
- The path-prefix check in D-011 assumes
  `$PROJECT_STATE_DIR` is resolvable from inside the runner
  invocation. Confirmed by CLAUDE.md "Three locations every
  script touches" — PROJECT_STATE_DIR is set by common.sh
  for every script that sources it.
- Test-stub pattern (D-009 V-8 mocks curl) — confirmed
  feasible by `bin/linear-test.sh`'s existing curl-stub
  pattern (referenced in the brainstorm).
- Renumbering §6 steps does NOT break `agent-prompts-content-
  test.sh` because the content-pin assertions are per-step
  literal phrases (e.g. "Flaky-pattern triage"), not step
  numbers. Verified by reading the existing pin shape.

No P0 codebase-fact errors. All claims grounded in
direct reads of the current branch tip.

### 10.7 Gate decision

6/6 PASS. Feasibility's zero P0 finding gate satisfied.
Proceeding to commit + stage summary.

---

## Appendix A: Decision-to-Linear-scope mapping

| Linear scope item | Decision(s) | Status |
|---|---|---|
| IN: Define a verification-predicate format the agent emits at qa start (smoke commands, URLs to navigate, expected exit codes, assertions) | D-001 (schema), D-002 (path), D-004 (http_get kind) | covered |
| IN: AGENT_PROMPTS.md qa section instructs agent to emit predicates before reasoning | D-005 (new step content), D-006 (block placement at line ~1392) | covered |
| IN: bin/verify-qa.sh runner that executes predicates and reports pass/fail without invoking claude | D-003 (CLI shape), D-012 (JSONL output) | covered |
| IN: Test fixture covering predicate emission + runner execution | D-009 (V-1..V-9 cases + content pin) | covered |
| OUT: Cleaving the qa stage into two separate dispatches | D-010 (no run-stage.sh hook) | observed |
| OUT: Evaluation-half changes | D-010 (no changes to §6 steps 5/7/8 — adversarial, qa-patterns) | observed |
| AC-1: qa agent emits a verification predicate file before any evaluation reasoning | D-005 (mandatory step 1 placement) | satisfied |
| AC-2: bin/verify-qa.sh executes the predicate and produces a structured pass/fail without claude | D-003 + D-012 | satisfied |
| AC-3: Failed verification halts qa with a structured-failure marker, not prose rejection | D-008 (qa-predicate-invalid halt reason) | satisfied for contract violations; criterion-execution failure remains verdict-fail (D-008 rationale) |

Note on AC-3: a literal reading of "Failed verification halts qa
with a structured-failure marker" could mean either (a)
contract-violation halts (the schema is broken, no JSON, etc.) OR
(b) criterion-execution failures (smoke command returned non-zero).
The brainstorm reads (a) as the intent because (b) is QA's existing
verdict-fail path, which is the loopback contract, not a halt. If
the ticket author meant (b), the runner can additionally exit
non-zero on criterion failure — that's a one-line conditional in
the CLI. **Flag for iter-1 confirmation with the operator.**

## Appendix B: Out-of-scope cross-references

- ENG-30 (plan stage emits plan.json) — completed prerequisite.
  ENG-113 consumes its output.
- ENG-36 (per-issue init.sh smoke discipline) — completed
  prerequisite. ENG-113's predicate's `smoke` kind can invoke
  these init.sh scripts.
- ENG-38 (umbrella P3 verification/evaluation split) — ENG-113
  is sub-ticket #1 of this umbrella.
- ENG-122 (plan.json schema validator) — ENG-113 reuses its
  validator shape and refactors common code into common.sh
  (D-007).
- ENG-140 (implementing prompt §3 + {qa_findings} token) —
  ENG-113's predicate file and ENG-140's qa-findings file are
  sibling per-issue artifacts in `$(issue_dir)`. Both follow
  the overwrite-on-every-dispatch contract.
- Future ENG-XXX (cleave-prompt sub-ticket) — wires
  verify-qa.sh into the orchestrator's dispatch flow; ENG-113
  is the prerequisite.
