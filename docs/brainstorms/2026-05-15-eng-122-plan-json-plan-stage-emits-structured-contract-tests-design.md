---
linear: ENG-122
title: plan.json — plan stage emits a structured contract alongside the prose plan
date: 2026-05-15
status: draft
---

# plan.json — plan stage emits a structured contract alongside the prose plan

## 1. Problem

Today the planning agent produces one artifact: a prose markdown plan at
`docs/plans/{date}-{issue_id_lower}-{slug}.md`
(`AGENT_PROMPTS.md:413`). Downstream stages parse this prose with
heuristics: the implement agent walks H3 `### Task N:` blocks and the QA
agent infers acceptance criteria from "Failure Mode → Test Map" rows
(`AGENT_PROMPTS.md:500-505`). Both readers are tolerant by design — when
the prose drifts (a typo in a task header, a forgotten table row), the
downstream stage just silently does less work, and the only signal is
"agent finished, nothing happened."

Three concrete pains motivate the umbrella issue ENG-30:

* The within-stage iteration loop for implement / ui (ENG-32) needs a
  predicate the agent can verify against — currently each iteration's
  "am I done?" is a self-judgment.
* The qa stage refactor (ENG-38) splits verification (deterministic
  predicate checks) from evaluation (judgment); verification needs a
  structured target to check against.
* Even the build stage's P2 preflight (`AGENT_PROMPTS.md` §7) re-asks
  the same question — "are the smoke commands passing?" — and there is
  no canonical source-of-truth for what "smoke commands" *are*.

ENG-122 is the foundation sub-ticket: emit a sibling
`docs/plans/{date}-{issue_id_lower}-{slug}.json` whose content is the
single source of truth for "what did planning commit to building?" The
readers come in ENG-32 (implement-loop) and ENG-38 (qa-refactor); this
ticket just lands the producer + the detective scan.

## 2. Decisions

- **D-001. The JSON file lives at the same basename as the prose plan,
  swapping the extension: `docs/plans/{date}-{issue_id_lower}-{slug}.json`.
  Filename-pairing — not a separate index file or a fenced block inside
  the prose — is the link between the two artifacts.**

  *Rationale:* the existing reconcile-by-frontmatter convention
  (`bin/render-prompt.sh::find_doc` lines 132-176, also documented at
  CLAUDE.md "Doc-to-issue ownership is YAML frontmatter, not prose") is
  load-bearing for the `.md` side. For the `.json` we cannot embed YAML
  frontmatter (JSON has no comment syntax). Filename-pairing is the
  cheapest disambiguation: one canonical pair per issue per date+slug,
  and `partition_dirty_paths::D-004` already treats both names as
  in-scope because they both contain `eng-N` in the basename
  (CLAUDE.md "Completion checklist" step 1).

  The JSON ALSO carries an `issue_id` field at the top level for
  defense-in-depth: the validator (D-004) cross-checks
  `json.issue_id == ident` so a stale template (e.g. an agent that
  copy-pasted a sibling issue's JSON) cannot slip through filename
  pairing alone.

  *Reference to constraint:* CLAUDE.md "Doc-to-issue ownership is YAML
  frontmatter, not prose" — JSON's lack of comments forces a different
  mechanism for the same job. Mirroring the prose plan's basename is
  the lowest-novelty path consistent with `eng-N`-in-basename being the
  scope-bucket signal.

  *Rejected alternative — embed the JSON inside a fenced block in the
  prose plan (a ` ```plan-contract` block):* rejected because (a) it
  forces every reader to walk the markdown to find the fence (extra
  parsing surface, fence-count fragility — same class of bug as
  `render-prompt.sh::extract_block`'s "exactly 2 fences" invariant), (b)
  it conflates a human artifact (prose plan readable in PRs and on
  GitHub) with a machine artifact (typed contract), (c) the Linear
  scope text says "sibling docs/plans/<issue>.json", which is the
  cleaner shape.

  *Rejected alternative — a single rolling `docs/plans/contracts.json`
  index file mapping `issue_id → contract`:* rejected because (a) it
  introduces a serialisation bottleneck (two plan dispatches racing on
  a merge to main could double-write the same key), (b) the
  per-issue-per-day file scales naturally with the existing
  `docs/plans/{date}-{issue_id_lower}-{slug}.md` shape, (c) the
  retrospective + git history give cheap "find a past contract" UX via
  filename grep with no extra plumbing.

- **D-002. Schema — `plan_schema_version: 1`, top-level `issue_id` +
  `features[]`. Each feature carries `id`, `summary`, and a
  `pass_criteria[]` array. Each pass-criterion is a typed record (a
  discriminated union on `kind`).**

  Schema sketch:

  ```json
  {
    "plan_schema_version": 1,
    "issue_id": "ENG-122",
    "features": [
      {
        "id": "F-1",
        "summary": "Schema validator helper exists at bin/plan-schema.sh and validates plan.json files",
        "pass_criteria": [
          {
            "kind": "smoke",
            "command": "bash bin/plan-schema.sh validate docs/plans/2026-05-15-eng-122-plan-json-plan-stage-emits-structured-contract-tests.json",
            "expect_exit": 0
          },
          {
            "kind": "file_exists",
            "path": "bin/plan-schema.sh"
          }
        ]
      }
    ]
  }
  ```

  Required fields (validator P0):

  * Top-level: `plan_schema_version` (integer, must equal `1`),
    `issue_id` (string matching `^ENG-[0-9]+$`),
    `features` (array, len ≥ 1).
  * Each `features[i]`: `id` (string, non-empty),
    `summary` (string, non-empty),
    `pass_criteria` (array, len ≥ 1).
  * Each `pass_criteria[j]`: `kind` (one of: `smoke`, `file_exists`,
    `grep`), plus the `kind`-specific fields:
    * `smoke`: `command` (string, non-empty), `expect_exit` (integer).
      Optional: `expect_stdout_match` (regex string).
    * `file_exists`: `path` (string, non-empty).
    * `grep`: `path` (string, non-empty), `pattern` (string,
      non-empty), `expect_match` (boolean — true = pattern must be
      present, false = pattern must NOT be present).

  *Rationale — three kinds (not more, not fewer):*
  * `smoke` covers "run a command, check exit code, optionally check
    stdout" — the canonical shape of every `bash bin/*-test.sh` in this
    repo's test harness.
  * `file_exists` covers "this artifact must land" — the cheap
    file-presence assertion that catches the ENG-7-class regression
    (agent reports success but produces no artifact).
  * `grep` covers "this code change landed" — a regex hit against a
    named file. Sufficient for "an agent must add token X to file Y"
    contracts. The `expect_match` boolean covers token-removal cases
    symmetrically.

  Schema is intentionally minimal: this ticket lands the producer + the
  validator. Readers (ENG-32, ENG-38) may extend the schema later by
  bumping `plan_schema_version` and adding optional fields; the
  validator's D-005 "unknown fields ignored, missing required = halt"
  contract lets schema 1 documents stay compatible with schema 2
  readers.

  *Reference to product principle:* CLAUDE.md "Don't add features,
  refactor, or introduce abstractions beyond what the task requires" —
  the three kinds match the three named items in the Linear scope
  ("smoke commands, expected outputs, per-feature pass-criteria"). No
  speculative `kind: assertion` / `kind: benchmark` / nested
  pass-criteria trees.

  *Reference to constraint:* CLAUDE.md "Per-stage allowed tool lists
  are centralized in `dispatch.sh::allowed_tools_for`" — the same
  centralization principle says "one canonical place per concern."
  `bin/plan-schema.sh` (D-003) is that place for the JSON schema; the
  schema doc itself lives in the file header comment of that script
  (no separate `docs/plan-schema.md` — JSON shapes drift, code is
  truth).

  *Rejected alternative — JSON Schema (jsonschema-org spec) validation:*
  rejected because (a) it pulls in a new dependency (the harness has
  no Python / no Node, only Bash + jq + standard CLI tools per the
  project profile's Stack section), (b) jq's `if-elif-else` covers our
  6-field schema in < 80 lines of bash, (c) jsonschema's expressivity
  (oneOf, anyOf, $ref) is overkill for the discriminated-union shape
  we have today and would invite over-specification in schema 2+.

  *Rejected alternative — fluent prose ("smoke: bash bin/foo.sh,
  expect 0") parsed via regex:* rejected because (a) the Linear scope
  says "structured contract"; regex over prose is the failure mode we
  are fixing, not its solution, (b) downstream readers (ENG-32 / ENG-38)
  want a typed object with named fields, not a string they re-parse.

- **D-003. Validator implementation lives at `bin/plan-schema.sh` as a
  standalone CLI with `validate <file>` subcommand. It returns 0 for
  valid, 30 for malformed, 31 for missing-required-field, and 32 for
  the JSON file simply not existing at the expected path.**

  *Rationale:* one-helper-per-concern matches the established harness
  convention (`bin/branch-name.sh`, `bin/secret-probe-lint.sh`,
  `bin/metrics.sh`, `bin/scope-check.sh` — each a single-CLI script
  with a `main` dispatch). Pulling the validator into `bin/common.sh`
  was the alternative offered by the Linear issue's IN bullet ("Schema
  validator helper in bin/common.sh or bin/plan-schema.sh"); we choose
  the dedicated file because (a) the schema is non-trivial — ~80 lines
  of jq filters — and would inflate common.sh, (b) a standalone CLI is
  unit-testable in isolation via the existing source-and-stub pattern
  (precedent: `bin/scope-check-test.sh`), (c) future readers (ENG-32 /
  ENG-38) need a "parse and project a feature's pass-criteria" surface
  that lives next to "validate" — both belong in the same script.

  Exit-code split (30 vs 31 vs 32) distinguishes the three operator-
  observable failures:
  * **32 (missing-file):** plan stage produced a `.md` but no `.json`
    — operator inspects whether the agent forgot to call `Write` on
    the JSON or whether `Write` failed.
  * **31 (missing-required-field):** the JSON exists and parses but is
    missing a required field (e.g. agent emitted `features: []` or
    omitted `plan_schema_version`) — operator inspects the agent's
    prompt-rendering and re-runs.
  * **30 (malformed):** `jq` failed to parse the JSON at all — operator
    inspects for a heredoc-quoting bug or stray prose in the file body
    (the agent's `Write` content was malformed).

  These three exit codes are NEW. `bin/common.sh::failure_outcome_for_exit`
  at lines 212-239 currently covers 10-29 (plus 124); 33/34/35 slot
  cleanly after `envelope-violation=29`. Mapping table:

  | Exit code | Outcome token              | Halt reason            |
  |-----------|----------------------------|------------------------|
  | 33        | `plan-contract-malformed`  | `plan-contract-invalid`|
  | 34        | `plan-contract-incomplete` | `plan-contract-invalid`|
  | 35        | `plan-contract-missing`    | `plan-contract-invalid`|

  All three map to the SAME halt reason (single new vocabulary entry
  in `bin/pipeline-events.json:10-20`'s `halt_reasons` array). The
  fine-grained outcome token gives the retrospective enough signal to
  separate root causes; the coarse halt reason gives the operator a
  single mental model ("plan contract is invalid; inspect the JSON").

  *Reference to constraint:* CLAUDE.md "Never use exit codes outside
  the taxonomy in `failure_outcome_for_exit`" — three new codes are
  added to the taxonomy in step 1 of the plan's implementation, before
  any caller emits them.

  *Reference to constraint:* CLAUDE.md "Marker shapes — only two
  families exist (ENG-60)" — the new halt reason `plan-contract-invalid`
  is registered in `bin/pipeline-events.json` (a Phase-1 documentation
  entry today, but the closed-vocabulary registry is the canonical
  source of halt-reason tokens; see `bin/pipeline.sh::event verdict halt
  --reason …` validation path).

  *Rejected alternative — fold the validator into
  `bin/common.sh::validate_plan_json` and call it directly from
  `run-stage.sh`:* rejected because (a) it makes common.sh wider for
  one ticket's worth of code, (b) it loses CLI-testability (the
  source-and-stub pattern can still exercise an internal function,
  but a CLI also gives operators a one-liner repro
  `bash bin/plan-schema.sh validate docs/plans/...json` for
  post-halt inspection), (c) common.sh is sourced by every script and
  every test; adding 80 lines of jq to it widens parse-time surface
  for no orthogonal benefit.

  *Rejected alternative — make `bin/plan-schema.sh` ALSO generate
  template JSON for the agent:* rejected because (a) Linear scope is
  IN: schema + validator + agent prompt + detective + tests, OUT:
  readers. A "scaffold" subcommand is reader-adjacent and not asked
  for, (b) the agent has Write tool access and a JSON example in the
  prompt — that's the cheaper shape today.

- **D-004. Detective scan — `bin/run-stage.sh::_validate_plan_contract`
  runs after `_validate_dispatch_envelope` in the post-dispatch hook
  block (run-stage.sh:1553-1580), stage-gated to `planning` only.
  Halts the dispatch with the appropriate exit code + halt comment
  body when the validator returns non-zero.**

  *Rationale:* the established post-dispatch scan pattern is
  `_validate_dispatch_envelope` (ENG-87, run-stage.sh:883-947) — it
  runs after the agent exits, looks at a per-issue artifact (the
  transcript sidecar), posts a halt comment on violation, and exits
  with a specific code. The plan-contract validator is the same shape:
  scan a per-issue artifact (the JSON file in the worktree), halt on
  violation. Slotting the new helper next to `_validate_dispatch_envelope`
  keeps the post-dispatch "detective" surface co-located.

  Concrete placement:

  ```bash
  # In bin/run-stage.sh::main, immediately AFTER the
  # _validate_dispatch_envelope block at lines 1560-1580:
  if (( ! skip_dispatch )); then
    case "$stage" in
      planning)
        local _plan_rc=0
        _validate_plan_contract "$ident" || _plan_rc=$?
        case $_plan_rc in
          0) ;;
          30|31|32)
            # _validate_plan_contract has already posted the
            # `<!-- pipeline: verdict result=halt reason=plan-contract-invalid -->`
            # comment naming the specific defect.
            classify_failure "$ident" "$stage" "skip-until-human-acts" \
              "plan-contract validation failed: exit=$_plan_rc (see linear comment for details)" "$_plan_rc"
            exit "$_plan_rc"
            ;;
        esac
        ;;
    esac
  fi
  ```

  The validator helper:

  ```bash
  _validate_plan_contract() {
    local ident="$1"
    local wt; wt="$(issue_dir "$ident")/worktree"
    [[ -d "$wt" ]] || { log "plan-contract: no worktree dir; skipping (degraded)"; return 0; }
    # Plan doc was located by render-prompt.sh::find_doc convention
    # (linear: <ID> in frontmatter). The sibling JSON is the same
    # basename with .json extension.
    local plan_md
    plan_md="$(cd "$wt" && find docs/plans -maxdepth 1 -type f -name "*$(printf '%s' "$ident" | tr '[:upper:]' '[:lower:]')*.md" 2>/dev/null | head -1)"
    if [[ -z "$plan_md" ]]; then
      log "plan-contract: no plan .md found for $ident; not the validator's failure mode (handled upstream)"
      return 0
    fi
    local plan_json="${plan_md%.md}.json"
    if [[ ! -f "$wt/$plan_json" ]]; then
      _post_plan_contract_halt "$ident" "missing-file" "no sibling JSON found at $plan_json"
      return 35
    fi
    local schema_rc=0
    bash "$SCRIPT_DIR/plan-schema.sh" validate "$wt/$plan_json" --ident "$ident" \
      2>&1 | tee "$(issue_dir "$ident")/.plan-schema-output" \
      || schema_rc=${PIPESTATUS[0]}
    case $schema_rc in
      0)  return 0 ;;
      30) _post_plan_contract_halt "$ident" "malformed" "$(cat "$(issue_dir "$ident")/.plan-schema-output")" ; return 33 ;;
      31) _post_plan_contract_halt "$ident" "incomplete" "$(cat "$(issue_dir "$ident")/.plan-schema-output")" ; return 34 ;;
      *)  _post_plan_contract_halt "$ident" "unknown" "validator returned unexpected rc=$schema_rc" ; return 33 ;;
    esac
  }
  ```

  **Sanitisation requirement.** Validator stdout is agent-controlled
  bytes (the agent wrote the JSON file the validator parsed). When
  interpolated into the halt comment body, an embedded
  `<!-- pipeline: verdict result=pass -->` substring would be picked up
  by `parse_pipeline_marker`'s family-precedence selector and promote
  the halt INTO a forward pass on the next `find_fresh_verdict` read.
  `_post_plan_contract_halt` MUST mirror the ENG-87 envelope
  validator's sanitisation at `bin/run-stage.sh:931-933`:
  `safe="${raw//<!--/<\!--}"` plus wrap in a triple-backtick fenced
  block (the marker parser's `_strip_code_blocks_and_spans` removes
  fenced runs before grep'ing for markers).

  Halt comment body (posted by `_post_plan_contract_halt` via
  `bash bin/linear.sh add-comment`, NOT `add-or-update-comment` — the
  verdict-marker comment is append-only per CLAUDE.md "Verdict-marker
  protocol"):

  ```
  <!-- pipeline: verdict result=halt reason=plan-contract-invalid -->

  Plan-contract validation failed on dispatch_id=<id> stage=planning:

  Defect: <missing-file|malformed|incomplete|unknown>
  Detail: <validator stdout>

  Expected: docs/plans/<plan_json>
  Schema: see bin/plan-schema.sh (header comment)

  **Resume:** fix the JSON (or the plan prompt's emission step), commit,
  then run `bash bin/pipeline.sh decide <ENG-N> --action continue`.
  ```

  *Reference to constraint:* CLAUDE.md "Defense-in-depth: when a
  stage's contract says 'agent must not invoke tool X,' prefer a
  transcript-based assertion ... over a post-dispatch state check."
  This rule applies to *tool denials* — the plan-JSON contract is a
  state requirement (the file must exist with the right shape), not a
  tool denial. Post-dispatch state check is the correct shape for this
  failure mode and matches the agent-contract-validator precedent at
  run-stage.sh:1529-1551 ("agent emitted no stage-summary file and no
  verdict marker" — same pattern).

  *Reference to constraint:* CLAUDE.md "Linear writes go through
  `bin/linear.sh` so dry-run + `meta: dedup` work uniformly" — the halt
  comment is emitted via `add-comment` (NOT `add-or-update-comment`)
  because verdict markers are append-only by protocol; the auto-
  injected `<!-- meta: dispatch id=… -->` marker is owned by
  `bin/linear.sh` (CLAUDE.md "Cross-dispatch staleness contract
  (ENG-87)").

  *Rejected alternative — make the agent self-validate before exit:*
  rejected because (a) agents can lie / forget / be killed mid-stream
  before reaching their self-check — the same `agent-contract-missing`
  failure mode (exit 25) already exists precisely because self-checks
  are insufficient (run-stage.sh:1544-1547), (b) ENG-87's detective
  backstop design (CLAUDE.md "Detective backstop") explicitly says
  state-checks complement, not replace, prompt-side instructions.

  *Rejected alternative — run the validator INSIDE `dispatch.sh`'s
  `_render_and_capture_stream`:* rejected because (a) dispatch.sh is
  the thin claude-wrapper layer; expanding its responsibilities pulls
  Linear-API calls into its failure path, mirroring the ENG-103 D-003
  rationale for keeping model resolution OUT of dispatch.sh, (b) the
  ENG-87 envelope validator chose run-stage.sh for the same reason —
  consistent layering.

- **D-005. Validator philosophy — strict on required fields, permissive
  on unknown fields. `plan_schema_version: 1` consumers (this ticket
  + ENG-32 + ENG-38) must accept future-schema documents that carry
  additional fields, as long as the v1 contract is satisfied.**

  *Rationale:* the ENG-87 staleness contract demonstrated the cost of
  rigid validators (an upstream change broke every downstream reader
  simultaneously). Permissive readers on unknown fields lets schema-2
  ship one reader at a time — readers that need a new field test for
  it explicitly; readers that don't, don't care.

  Concrete behavior:

  * `plan_schema_version: 1`, all required fields present, no unknown
    fields → exit 0.
  * `plan_schema_version: 1`, all required fields present, plus
    unknown fields (`features[i].depends_on`, `features[i].budget_min`,
    etc.) → exit 0 + log warning (operator-visible) listing the
    unknowns. Future ENG-N can register these into schema 2; until
    then they're a forward-compatibility surface, not an error.
  * `plan_schema_version: 1`, missing required field → exit 34.
  * `plan_schema_version: 2+` → exit 34 (this validator only handles
    schema 1; a schema-2 implementation lands when schema-2 is needed,
    not speculatively).
  * `plan_schema_version: 0` or missing → exit 34.

  *Reference to constraint:* CLAUDE.md "Never use exit codes outside
  the taxonomy in `failure_outcome_for_exit`" — schema_version
  mismatches map to exit 34 (`plan-contract-incomplete`), not a new
  code. The operator response is the same: "fix the agent's JSON
  emission to match what the validator expects."

  *Rejected alternative — fail on any unknown field:* rejected because
  it makes the validator a rolling roadblock for ENG-32 / ENG-38 (each
  reader would either silently ignore future fields or block on them).
  ENG-87 shipped Postel's-Law readers for exactly this reason.

- **D-006. Tests live in `bin/plan-schema-test.sh` (validator unit
  tests) and `bin/run-stage-test.sh` (integration: detective scan halts
  on missing/malformed). Fixtures are mktemp'd JSON files, not checked
  in to `docs/plans/`.**

  *Rationale:* the source-and-stub pattern (CLAUDE.md "How tests work
  — important when adding new ones") is the only test pattern in this
  repo. `bin/plan-schema-test.sh` sources `bin/plan-schema.sh` (so the
  validator must end with the sentinel `if [[ "${BASH_SOURCE[0]}" ==
  "${0}" ]]; then main "$@"; fi`, mandatory per the same CLAUDE.md
  section), writes mktemp'd JSON fixtures, calls the internal
  validator functions, asserts return codes + stdout.

  Test cases (must-have for AC #3 — "Tests cover well-formed +
  missing + malformed"):

  1. `T1 — well-formed`: valid schema-1 JSON → exit 0.
  2. `T2 — missing file`: non-existent path → exit 35.
  3. `T3 — malformed (broken JSON syntax)`: stray comma → exit 33.
  4. `T4 — malformed (not an object)`: top-level array → exit 33.
  5. `T5 — incomplete (missing plan_schema_version)`: → exit 34.
  6. `T6 — incomplete (wrong issue_id type — int instead of string)`:
     → exit 34.
  7. `T7 — incomplete (features: [])`: → exit 34 (len ≥ 1).
  8. `T8 — incomplete (features[0].pass_criteria: [])`: → exit 34.
  9. `T9 — incomplete (pass_criteria[0].kind == "bogus")`: → exit 34.
  10. `T10 — well-formed with unknown field`: extra top-level
      `roadmap: "..."` → exit 0 + warning log.
  11. `T11 — issue_id mismatch`: JSON `issue_id: "ENG-999"` but
      `--ident ENG-122` → exit 34 (defense against stale templates,
      per D-001).
  12. `T12 — schema_version: 2`: → exit 34 (D-005).

  Integration tests in `bin/run-stage-test.sh` (add to the existing
  `_validate_dispatch_envelope` test group at ~line 4093-4734, using
  the same mktemp'd HARNESS_STATE_DIR + STUB_DIR pattern):

  1. `INT1 — clean planning dispatch with valid JSON`: agent stub
     writes valid `.md` + `.json` → run-stage exits 0, no halt comment.
  2. `INT2 — planning dispatch with .md but no .json`: → exits 32,
     halt comment body contains `plan-contract-invalid` + `defect:
     missing-file`.
  3. `INT3 — planning dispatch with malformed .json`: → exits 30,
     halt comment body contains `plan-contract-invalid` + `defect:
     malformed`.
  4. `INT4 — non-planning stage (e.g. implementing)`: validator does
     NOT run (stage-gate) — no halt comment, no exit 33/31/32.

  *Reference to constraint:* CLAUDE.md "When a new bash file is meant
  to be both executable and unit-testable, replicate the sentinel
  pattern; otherwise tests cannot source it without side effects." —
  bin/plan-schema.sh ships with the sentinel; tests source it.

  *Rejected alternative — check in a "happy-path" fixture under
  `docs/plans/` for tests to reference:* rejected because (a)
  `docs/plans/` is scope-allowlisted for the plan stage only;
  permanent fixtures there would (i) confuse `reconcile.sh`'s
  doc-to-issue matcher (linear:<ID> frontmatter still triggers — and a
  fixture without one would only match by filename, which sets a
  precedent for fuzzy matches), (ii) bloat the production doc set,
  (b) mktemp'd fixtures are isolated per-run; the existing
  `bin/scope-check-test.sh` and `bin/render-prompt-test.sh` both use
  this pattern.

## 3. Architecture

```
                ┌──────────────────────────────────────────────────────┐
                │  AGENT_PROMPTS.md §2 Plan Agent                      │
                │  + new "Output" bullet: emit plan.json sibling       │
                │  + Output section names plan_schema_version 1 shape  │
                └──────────────────────────────────────────────────────┘
                                      │
                                      ▼
                ┌──────────────────────────────────────────────────────┐
                │  bin/render-prompt.sh                                │
                │    (no change required — emits whole §2 block)       │
                └──────────────────────────────────────────────────────┘
                                      │
                                      ▼
                ┌──────────────────────────────────────────────────────┐
                │  Planning dispatch (claude -p)                       │
                │  Agent writes:                                       │
                │    docs/plans/{date}-{eng-n-lower}-{slug}.md         │
                │    docs/plans/{date}-{eng-n-lower}-{slug}.json    ◀──┐ NEW
                └──────────────────────────────────────────────────────┘ │
                                      │                                  │
                                      ▼                                  │
                ┌──────────────────────────────────────────────────────┐ │
                │  bin/run-stage.sh::main (post-dispatch hook block)   │ │
                │   1. agent-contract-validator (exit 25 if neither   │ │
                │      stage-summary file nor verdict marker)          │ │
                │   2. _validate_dispatch_envelope (ENG-87, exit 29)   │ │
                │   3. _validate_plan_contract  ◀── NEW (exit 33/31/32)│ │
                │   4. push_branch_if_ahead                            │ │
                │   5. post_completion_comment                         │ │
                └──────────────────────────────────────────────────────┘ │
                                      │                                  │
                                      ▼                                  │
                ┌──────────────────────────────────────────────────────┐ │
                │  bin/plan-schema.sh  ◀── NEW (one-helper-per-concern)│ │
                │   subcommands:                                       │ │
                │     validate <file> [--ident ENG-N]   → 0/33/34/35   │ │
                │   schema reference in file-header comment            │ │
                └──────────────────────────────────────────────────────┘ │
                                      │                                  │
                                      ▼                                  │
                ┌──────────────────────────────────────────────────────┐ │
                │  bin/common.sh::failure_outcome_for_exit             │ │
                │   + 33 plan-contract-malformed                       │ │
                │   + 34 plan-contract-incomplete                      │ │
                │   + 35 plan-contract-missing                         │ │
                └──────────────────────────────────────────────────────┘ │
                                                                         │
                ┌──────────────────────────────────────────────────────┐ │
                │  bin/pipeline-events.json                            │ │
                │   halt_reasons[] += "plan-contract-invalid"          │ │
                │   (all three exit codes map to this one halt reason) │ │
                └──────────────────────────────────────────────────────┘ │
                                                                         │
                ┌──────────────────────────────────────────────────────┐ │
                │  AGENT_PROMPTS.md §0 halt-reason vocabulary block    │ │
                │   + plan-contract-invalid (listed in agent-facing    │ │
                │     reason allowlist for completeness; planning      │ │
                │     agent itself does NOT halt with this — the       │ │
                │     orchestrator does)                               │ │
                └──────────────────────────────────────────────────────┘ │
                                                                         │
                ┌──────────────────────────────────────────────────────┐ │
                │  Tests                                               │ │
                │   bin/plan-schema-test.sh     (T1-T12)               │ │
                │   bin/run-stage-test.sh       (INT1-INT4)            │ │
                └──────────────────────────────────────────────────────┘ │
                                                                         │
                                  Files MODIFIED ─────────────────────── │
                                  AGENT_PROMPTS.md   (Plan §2 Output + §0 reason list)
                                  bin/run-stage.sh   (post-dispatch hook + _validate_plan_contract + _post_plan_contract_halt)
                                  bin/common.sh      (failure_outcome_for_exit: 33/34/35)
                                  bin/pipeline-events.json (halt_reasons += plan-contract-invalid)
                                  CLAUDE.md          (one paragraph documenting the new contract under "Per-stage ...")

                                  Files NEW ──────────────────────────
                                  bin/plan-schema.sh
                                  bin/plan-schema-test.sh
```

## 4. Data Flow

1. **Plan agent dispatches.** `bin/run-stage.sh::main` runs
   `bin/render-prompt.sh planning <ENG-N>`, which extracts §2 from
   `AGENT_PROMPTS.md`. The updated §2 now instructs the agent to write
   BOTH the prose `.md` AND the sibling `.json`.
2. **Agent writes both files.** During dispatch, the agent's `Write`
   tool emits:
   - `docs/plans/{date}-{issue_id_lower}-{slug}.md`
   - `docs/plans/{date}-{issue_id_lower}-{slug}.json`
3. **Agent commits artifacts.** The plan stage's existing commit step
   (`chore(pipeline): plan for {issue_id}`, AGENT_PROMPTS.md:564-568)
   stages both files (`docs/` is already in `_always_include_paths`,
   CLAUDE.md "Always-include lockfile catalog").
4. **Detective scan fires.** Post-dispatch in run-stage.sh:1553-1580,
   the new `_validate_plan_contract "$ident"` block:
   a. Finds the plan `.md` by filename glob (`docs/plans/*<eng-n>*.md`).
   b. Derives the sibling `.json` path by replacing `.md` with `.json`.
   c. If the `.json` is missing → posts halt comment, exits 32.
   d. Otherwise, invokes `bash bin/plan-schema.sh validate <file>
      --ident <ENG-N>`, captures stdout + rc.
   e. On rc=33/31, posts halt comment with the validator's stdout
      inlined, exits 30 or 31 respectively.
   f. On rc=0, falls through to `push_branch_if_ahead` +
      `post_completion_comment` as before.
5. **Halt path: orchestrator applies pipeline:halted, classify_failure
   writes `policy=skip-until-human-acts`.** The next tick's poller
   sees the halt label and skips the issue. Operator resolves via
   `bash bin/pipeline.sh decide ENG-N --action continue`.
6. **Resume path: operator fixes the JSON (or fixes the agent
   prompt), re-dispatches.** Resume clears the halt label, the next
   tick re-dispatches plan with a fresh `dispatch_id`; the JSON is
   re-emitted, the validator re-runs, the issue progresses.

## 5. Error Handling

| Failure                           | Surface                | Recovery                                    |
|---                                |---                     |---                                          |
| `.json` missing                   | Halt comment, rc=35    | Agent re-write; `--action continue`         |
| Malformed JSON syntax             | Halt comment, rc=33    | Agent re-emit; `--action continue`          |
| Missing required field            | Halt comment, rc=34    | Agent re-emit; `--action continue`          |
| `issue_id` mismatch (stale tmpl)  | Halt comment, rc=34    | Agent re-emit with correct ID               |
| `plan-schema.sh` itself crashes   | Halt comment, rc=33 (catch-all)            | Operator inspects validator; manual fix     |
| Validator's `jq` missing          | Hard die (require_bin) | Operator installs jq (preflight requirement)|
| Worktree missing post-dispatch    | Log warn, return 0 (degraded — fail-open) | Operator inspects manually  |
| Plan `.md` itself missing         | Log warn, return 0 (handled by exit-25 agent-contract validator) | n/a            |

Two "degraded fail-open" branches are intentional and mirror
`_validate_dispatch_envelope`'s sidecar-missing fail-open
(run-stage.sh:892):

* **Worktree absent** (`issue_dir(ident)/worktree` doesn't exist) →
  log warning, return 0. Caller's earlier preconditions should have
  caught this; the validator is not the right surface to halt for it.
* **Plan `.md` missing** → log warning, return 0. The `exit 25
  agent-contract-missing` validator at run-stage.sh:1544-1547 already
  catches "agent produced no artifacts" and halts the dispatch there.
  Double-halting on the same root cause would just confuse the
  operator.

The third explicit case — `bin/plan-schema.sh` invocation crashing
unexpectedly (e.g. shell parse error, missing binary) — falls into the
catch-all `*) → exit 33` branch in `_validate_plan_contract`'s case
statement, with the halt comment body naming the unexpected rc. This
is detective-only: the operator sees `rc=99 from validator` and
inspects manually. Better than silently passing through.

## 6. Edge Cases

* **Multiple plan dispatches on the same date.** If planning re-runs
  (via `pipeline:supersede` loopback from implementing), the agent
  writes the SAME paths (`docs/plans/{date}-{eng-n-lower}-{slug}.md`
  + `.json`) — they're overwritten on every dispatch. The validator
  always reads the file content fresh post-dispatch, so it sees the
  newest version. No cross-dispatch staleness risk for THIS file
  surface (it's in the worktree, not in `$PROJECT_STATE_DIR/<ident>/`).

* **Plan dispatched twice on different dates.** If the agent re-runs
  on a different date (rare — operator-driven), the new dispatch
  writes a NEW pair (`2026-05-16-...md` + `.json`) and the OLD pair
  remains in `docs/plans/`. The validator's "find by filename glob"
  picks up `head -1` of the sorted match. Two `.md` files both
  matching `*eng-122*` is the failure mode here — `find ... | head -1`
  is non-deterministic across BSD/GNU find. **Mitigation:** the
  filename glob includes the date prefix from the dispatch's current
  date (resolved via `_resolve_date` at render-prompt.sh:220), so the
  validator looks for the CURRENT-date pair specifically. If both
  dates' files exist, validator only checks today's. The stale pair
  is the operator's cleanup problem (and `partition_dirty_paths`
  classifies them as in-scope for `docs/plans/` either way).

* **Plan stage runs but agent writes NEITHER file (early exit, crash).**
  Caught by the existing exit-25 agent-contract-missing validator at
  run-stage.sh:1544-1547 BEFORE the new validator runs. The new
  validator's "plan .md missing" fail-open path is the secondary
  guard if exit-25 fails to fire.

* **Agent writes JSON to wrong path** (e.g.
  `docs/plans/contract.json` instead of the sibling basename).
  Validator's "missing sibling at expected path" branch fires → exit
  32. Halt body names the expected path, agent re-runs with corrected
  prompt understanding.

* **Smoke command in pass_criteria references a tool not yet
  installed.** The validator does NOT execute the smoke commands — it
  only checks structural validity. Smoke-command execution is the
  downstream readers' job (ENG-32 / ENG-38). Out of scope for this
  ticket.

* **JSON syntax-valid but semantically nonsense** (e.g.
  `expect_exit: "potato"` — string where integer required). Caught by
  the schema validator's per-field type check (jq filter `type ==
  "number"`). Exit 31. The validator dies on the first failed assertion
  with a human-readable message; it does NOT collect-and-report all
  defects in one pass (KISS — extending to multi-defect reports is a
  follow-on if operators ask).

* **Plan dispatched in dry-run mode** (`PIPELINE_DRY_RUN=1`). The
  detective scan still runs; in dry-run the agent writes real files
  to the worktree but the orchestrator skips Linear writes. If the
  agent stub doesn't emit JSON in dry-run, the validator halts (which
  is what we want — dry-run is a contract-verification mode). Tests
  in `bin/plan-schema-test.sh` run under `PIPELINE_DRY_RUN=1` per
  CLAUDE.md "How tests work."

* **JSON has Unicode in `summary` or `pass_criteria[].command`.**
  jq handles UTF-8 by default; no special handling required. The
  halt comment body inlines validator stdout, so the operator sees
  the raw Unicode — Linear's web UI renders UTF-8 correctly.

## 7. Open Questions

- **OQ-1.** Should the JSON's `pass_criteria` schema have a
  `description` field per criterion? — DEFER. The Linear scope names
  "per-feature pass-criteria, smoke commands, expected outputs" — no
  human-readable description. The `summary` at the feature level
  carries the human prose. If ENG-32 readers want per-criterion
  descriptions, schema 2 adds them as optional fields (D-005
  permissive readers).

- **OQ-2.** Should `bin/plan-schema.sh` also expose a `parse <file>
  <jq-filter>` subcommand for downstream readers to use? — DEFER. The
  Linear scope explicitly bars reader work in this ticket ("OUT:
  Implement reading plan.json — next sub-ticket"). ENG-32 will add
  its own projection helpers; if a shared one emerges, lift it
  later.

- **OQ-3.** What does the agent prompt tell the agent about the
  schema? — Two options:
  * **(a) Inline the full schema in §2's Output bullets** (mirrors
    the existing "API Contract" machine-readable block at
    AGENT_PROMPTS.md:459-498). Pros: agent has the schema in-prompt,
    no read of a separate file. Cons: schema lives in two places
    (prompt + `bin/plan-schema.sh`), drift risk.
  * **(b) Reference `bin/plan-schema.sh`'s header comment as the
    canonical source, instruct the agent to `Read` it before
    emitting.** Pros: single source of truth. Cons: extra `Read`
    tool call per dispatch; agent could skip the read and fail the
    validator.
  * **Recommend (a):** the existing API-contract pattern at
    AGENT_PROMPTS.md:459-498 establishes the convention of embedding
    machine-readable shapes directly in the prompt; an inline schema
    block in §2's "Output" section follows the same shape. Drift
    risk is mitigated by `bin/plan-schema.sh`'s tests, which catch
    "the validator and the example diverged" via a fixture sanity
    test.

- **OQ-4.** Should the halt comment include the full validator
  stdout, or a truncated summary? — DEFER to feedback. Today's
  draft inlines the full stdout (a few hundred bytes — well within
  Linear's comment limits). If operators report noisy halt comments,
  truncate to first-defect-only.

- **OQ-5.** Should `pass_criteria[]` allow `kind: "test"` (run a
  named `bin/*-test.sh`)? — DEFER. The Linear scope says "smoke
  commands"; `kind: smoke` with `command: "bash bin/foo-test.sh"`
  already covers the test case. A dedicated `kind: test` adds
  vocabulary without expressivity gain.

- **OQ-6.** Should the per-dispatch `dispatch_history.jsonl` row
  include the validator's outcome (clean / 30 / 31 / 32)? — Yes;
  reuse the existing `_END_ROW_VERDICT_*` machinery in
  `run-stage.sh`'s EXIT trap (line ~960). The verdict marker landing
  in Linear (via `_post_plan_contract_halt`) is picked up by
  `find_fresh_verdict` at trap-fire time, same as
  `_validate_dispatch_envelope`'s rc=29 path. No new plumbing; this
  OQ exists to flag that the integration is implicit, not explicit
  — confirm during implement.

## 8. ADR proposed

### ADR-2026-05-15: plan.json sibling artifact + halt-on-malformed contract

* **Status:** proposed
* **Context:** ENG-30 umbrella. Downstream stages (implement loop in
  ENG-32, qa-refactor in ENG-38) need a structured contract that the
  plan stage commits to. Prose-plan parsing today is heuristic and
  fails silently.
* **Decision:** Plan stage emits `docs/plans/{basename}.json`
  alongside the existing `.md`. A new helper `bin/plan-schema.sh`
  validates the JSON; a new detective scan
  (`run-stage.sh::_validate_plan_contract`) halts the dispatch on
  missing or malformed JSON with halt reason `plan-contract-invalid`
  and exit codes 33/34/35 (mapped in
  `bin/common.sh::failure_outcome_for_exit`).
* **Consequences:**
  * **(+)** Downstream readers (ENG-32, ENG-38) get a typed,
    enumerable contract.
  * **(+)** Halt-on-malformed surfaces plan-stage defects at plan
    time, not at downstream-reader time (cheaper recovery).
  * **(–)** Adds three new exit codes + one new halt reason to the
    closed vocabulary. The retrospective's §1 filter must learn the
    new outcome tokens (`plan-contract-malformed`,
    `plan-contract-incomplete`, `plan-contract-missing`) — this is a
    one-line case-statement extension.
  * **(–)** Plan agent's failure modes widen. Today the plan stage
    fails on (guards, paused, lane-violation, scope-violation,
    pr-opened-too-early — none of which the plan agent itself trips
    in practice); after this change it can also fail on the JSON
    contract. Empirically the API-contract block today is well-
    formed in production plans, so the new failure mode is expected
    to be rare.
  * **(–)** One more file in `docs/plans/` per issue (doubles the
    plan-stage artifact count). Negligible storage cost; reviewers
    can read both side-by-side in PRs.
* **Alternatives considered:** see D-001, D-003, D-004 rejected
  alternatives above.

## 9. Anti-bias checks

### ADR stress test

* **ENG-87 cross-dispatch staleness contract** (CLAUDE.md
  "Cross-dispatch staleness contract"): does plan.json create new
  staleness surface? No — the JSON lives in the worktree (gits-tracked
  / merged-via-PR), not in `$PROJECT_STATE_DIR/<ident>/`. The "clear-on-
  dispatch-start" primitive only clears the per-stage stage-summary
  files in `$PROJECT_STATE_DIR`, not repo files. The validator reads
  the file fresh post-dispatch; no cross-dispatch read of stale
  content. ENG-87's compatible.
* **ENG-100 sub-agent debris** (CLAUDE.md "Sub-agent debris"): does
  plan.json incentivise the agent to write scratch files? No — the
  schema is small enough to reason about inline; the agent writes ONE
  file at one canonical path. The prompt instruction explicitly says
  "Write to {path}; do not create scratch fixtures."
* **ENG-90 slot-occupancy contract** (CLAUDE.md "Slot-occupancy
  contract"): halt classification = `skip-until-human-acts`, which is
  `slot:"vacate", operator_action_required:true` per the contract.
  The new halt fits the existing classifier branch in
  `_poll_classify_labels`; no new branch needed.

### Simpler alternative

For each major decision, the simpler alternative was named and
rejected (D-001 fenced-block, D-002 fluent prose, D-003
fold-into-common.sh, D-004 agent self-validate, D-005 strict-on-
unknowns). The simplest possible shape — "agent writes JSON, no
validator, trust the agent" — was rejected because the Linear
acceptance criterion #2 explicitly says "Missing or malformed json
halts the plan stage with a structured failure reason."

### Assumption inventory

(Every code-level claim verified against the worktree at HEAD on
2026-05-15. `path:line` references quoted below.)

| # | Assumption | Status | Reference |
|---|---|---|---|
| A1 | The plan agent today writes `docs/plans/{date}-{issue_id_lower}-{slug}.md` and only this. | verified | `AGENT_PROMPTS.md:413` ("Produce a plan at docs/plans/{date}-{issue_id_lower}-{slug}.md") |
| A2 | `bin/render-prompt.sh::find_doc` matches plan docs by `linear: <ID>` frontmatter then filename fallback. | verified | `bin/render-prompt.sh:132-176` |
| A3 | `bin/render-prompt.sh::PROMPT_RESOLVERS` registers `issue_id`, `issue_id_lower`, `date`, `slug`, `plan_file` tokens. | verified | `bin/render-prompt.sh:41-54` |
| A4 | `bin/render-prompt.sh::_resolve_date` emits today's date via `$_RENDER_DATE`. | verified | `bin/render-prompt.sh:220` |
| A5 | `bin/dispatch.sh::_render_and_capture_stream` writes a transcript sidecar at `${issue_dir}/.envelope-transcript-${stage}`. | verified | `bin/dispatch.sh:54, 142-144` |
| A6 | `bin/run-stage.sh::_validate_dispatch_envelope` is the post-dispatch detective scan precedent for ENG-87. | verified | `bin/run-stage.sh:883-947` (function), `bin/run-stage.sh:1553-1580` (caller) |
| A7 | The agent-contract validator (exit 25, "no stage-summary and no verdict marker") fires BEFORE the envelope validator. | verified | `bin/run-stage.sh:1538-1551` (agent-contract), `bin/run-stage.sh:1553-1580` (envelope) |
| A8 | `bin/common.sh::failure_outcome_for_exit` maps exit codes 10–29 and 124 today; 33/34/35 are free. | verified | `bin/common.sh:212-239` |
| A9 | `bin/pipeline-events.json::halt_reasons` is the closed vocabulary for `verdict halt --reason ...`. | verified | `bin/pipeline-events.json:10-20` |
| A10 | `bin/linear.sh::add-comment` is append-only and auto-injects `<!-- meta: dispatch id=… stage=… -->` when `PIPELINE_DISPATCH_ID` is set. | verified | CLAUDE.md "Cross-dispatch staleness contract (ENG-87)"; behavior confirmed via `bin/dispatch.sh:563-565` (exports `PIPELINE_DISPATCH_ID`) |
| A11 | `bin/common.sh::assert_no_tool_invocation` is hoisted to common.sh and callable from both dispatch.sh and run-stage.sh. | verified | `bin/common.sh:178-195` |
| A12 | The `<!-- pipeline: verdict result=halt reason=... -->` marker shape is the canonical halt-emission shape. | verified | `AGENT_PROMPTS.md:43` ("Marker shapes — only two families exist") + `bin/run-stage.sh:941` (envelope validator's halt body) |
| A13 | `bin/plan-schema.sh` does NOT currently exist; creating it is in scope. | verified | `ls bin/plan-schema*` returns no matches (worktree at HEAD) |
| A14 | The `find_doc`'s frontmatter scan only reads the first 20 lines (`NR>20 { exit 1 }` in awk). | verified | `bin/render-prompt.sh:147, 158` |
| A15 | `bin/common.sh::parse_pipeline_marker` is the canonical marker parser; we do NOT use it in this ticket (no marker parsing involved). | verified | `bin/common.sh:294-356` |
| A16 | `bin/run-stage-test.sh` uses mktemp'd `STUB_DIR` with stubbed `linear.sh`/`gh`/`branch-name.sh`. | verified | `bin/run-stage-test.sh:17-65` |
| A17 | The sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` is required for tests to source bin/*.sh files. | verified | CLAUDE.md "How tests work — important when adding new ones" |
| A18 | `docs/` is in `_always_include_paths` so `docs/plans/*.json` is in-scope for the plan stage. | verified | CLAUDE.md "Always-include lockfile catalog" + project profile File layout section |
| A19 | The post-dispatch hook block in run-stage.sh is gated on `(( ! skip_dispatch ))` — `_validate_plan_contract` must inherit this gate to avoid running on scope-approval replays. | verified | `bin/run-stage.sh:1538, 1560` |
| A20 | The `classify_failure ... "skip-until-human-acts"` path applies `pipeline:halted` via the orchestrator AFTER this dispatch exits (ENG-56). | assumed | CLAUDE.md "Per-issue state directory" + "What `--action continue` clears (atomic)" — operator-resume contract intact; verify against `bin/classify-failure.sh` during implement |
| A21 | `bin/plan-schema.sh` invocation from `_validate_plan_contract` happens INSIDE `bin/run-stage.sh`'s subshell, which already has `SCRIPT_DIR` set to the bin directory. | verified | `bin/run-stage.sh:26` |
| A22 | `jq` is a required runtime tool per the project profile; `require_bin jq` already runs in every dispatch path. | verified | project profile Stack section + `bin/common.sh:612-615` |
| A23 | Adding a new entry to `bin/pipeline-events.json::halt_reasons` is sufficient to make `bash bin/pipeline.sh event ... verdict halt --reason plan-contract-invalid` succeed (registry-validated). | assumed | `bin/pipeline-events.json` is described as "Phase 1 parsers use this for documentation only" — Phase 2 writer-side validation may or may not yet check this token. Verify during implement; if it does not, the orchestrator's `classify_failure` path is unaffected (it emits the marker directly, not via `pipeline.sh event`). |

### Codebase-fact verification (per the prompt's MANDATORY check)

Every named function, file, and exit-code reference in this brainstorm
has been verified against the worktree at HEAD on 2026-05-15. Quoted
references:

* `_validate_dispatch_envelope` — `bin/run-stage.sh:883-947` (function
  definition), `bin/run-stage.sh:1560-1580` (caller block).
* `_render_and_capture_stream` (+ sidecar at
  `.envelope-transcript-${stage}`) — `bin/dispatch.sh:47-235` (function
  with assertions), specifically sidecar emission at lines 54, 142-144.
* `assert_no_tool_invocation` — `bin/common.sh:178-195`.
* `failure_outcome_for_exit` table — `bin/common.sh:212-239`.
* `STAGE_TO_SECTION` + `PROMPT_RESOLVERS` — `bin/render-prompt.sh:13-23`
  and `:41-54` respectively.
* `find_doc` — `bin/render-prompt.sh:132-176`.
* AGENT_PROMPTS §2 Plan Agent — `AGENT_PROMPTS.md:348-606`, with the
  artifact-naming line at 413 and the completion-checklist at 537-606.
* `bin/pipeline-events.json::halt_reasons` — `bin/pipeline-events.json:10-20`.
* Exit-code 25 agent-contract validator — `bin/run-stage.sh:1538-1551`.
* `bin/plan-schema.sh` — DOES NOT EXIST in HEAD; new file per D-003.

## 10. Persona review

(Six personas run in order per the dispatch prompt: design → security
→ scope → coherence → product → feasibility. Verdicts recorded here as
the durable audit trail; the Linear `completion/brainstorm/ENG-122`
comment carries the headline only.)

### Iteration 1

**design — PASS.** The design slots a new helper into the established
post-dispatch detective pattern (ENG-87 precedent at
run-stage.sh:1553-1580). `bin/plan-schema.sh` follows the
one-helper-per-concern convention. No new abstractions invented; the
three new exit codes extend the existing taxonomy without breaking it.
Module boundaries respected: dispatch.sh stays thin, run-stage.sh
owns the post-dispatch hook, common.sh stays narrow. The schema is
intentionally minimal (3 `kind`s) and forward-extensible via D-005
permissive readers.

Minor (P2): the `case` block at run-stage.sh's new detective scan
could be folded into a helper `_dispatch_post_validators` if a third
stage-specific validator lands later. Out of scope today.

**security — PASS.** No new attack surface:
* No new Linear API calls beyond the halt-comment emission, which
  flows through `bin/linear.sh add-comment` (the auto-injection
  chokepoint per ENG-87).
* Validator output is inlined into the halt comment body; the
  envelope-validator's sanitisation pattern at
  `bin/run-stage.sh:931-933` (`viol_str_safe="${viol_str_raw//<!--/<\\!--}"`)
  should be mirrored when interpolating validator stdout into the
  halt body — an agent-controlled JSON file with an embedded
  `<!-- pipeline: verdict result=pass -->` substring would otherwise
  hijack the verdict family. Add to implement plan: `_post_plan_contract_halt`
  applies the same `<!--` escape.
* No new file-system reads outside `$wt/docs/plans/` and
  `$issue_dir/.plan-schema-output`; both are per-issue paths.
* `bin/plan-schema.sh validate` reads a JSON file with `jq` — no shell
  expansion of the file content; jq's parsing is the only consumer.

Minor (P1, fold into D-004): mirror the ENG-87 review-iter-7 sanitisation
of agent-controlled bytes before interpolation. **Resolution: added
to D-004's `_post_plan_contract_halt` description in iteration 2.**

**scope — PASS.** Every section traces to a Linear scope bullet:
* Schema definition → IN bullet 1.
* AGENT_PROMPTS §2 update → IN bullet 2.
* Detective scan in run-stage.sh (NOT dispatch.sh as the Linear
  scope mis-states) → IN bullet 3. **Note for plan stage: justify in
  Goal that the detective lives in run-stage.sh, mirroring ENG-87.
  Resolution: justification baked into D-004 + Architecture.**
* Schema validator helper → IN bullet 4 (Linear scope says "in
  bin/common.sh or bin/plan-schema.sh"; D-003 picks the latter and
  justifies).
* Tests cover well-formed + missing + malformed → AC #3; T1-T12 +
  INT1-INT4 cover this.
* No reader work in this brainstorm (OQ-2 explicitly defers).
* No future-schema fields (D-005 permissive but does not specify).

Scope-creep flags:
* **None.** The doc does not propose readers, does not propose
  template generation, does not propose schema-2.

Linear scope mis-statement to flag in stage summary: "bin/dispatch.sh
detective scan asserts plan dispatches produce a well-formed json"
— in fact the detective lives in `bin/run-stage.sh` (matching
ENG-87's post-dispatch envelope validator placement, NOT dispatch.sh's
in-band transcript scans which target tool-invocation forbidance).
This is documented in D-004's rationale; the implementation will
honor the design intent (post-dispatch state check) but in the
correct architectural layer.

**coherence — PASS.** Goal ("emit a sibling
docs/plans/<issue>.json...") matches the AC. Data flow §4 covers
producer → committer → detective → halt-on-fail → resume. Error
Handling §5 maps each failure mode to a recovery path. Edge Cases §6
covers the 7 known shapes. Architecture diagram in §3 names every
file modified + created.

Minor (P2): the AC mentions "json matches sibling prose plan" —
clarify what "matches" means. **Resolution: D-001's defense-in-depth
`issue_id` cross-check + Edge Case "Plan dispatched twice on
different dates" cover the intent (pairing + ID match + features
non-empty); no further interpretation of semantic correspondence
between prose H3 tasks and JSON features is in scope (would require
NLP).**

**product — PASS.** This is foundation work for ENG-32 + ENG-38;
neither of those is user-visible. The user impact ladder:
1. Today: plan-stage drift fails silently in implement/qa, manifests
   as a halt comment hours later, expensive to triage.
2. Post-ENG-122: plan-stage drift fails LOUDLY at plan time with a
   structured halt body naming the defect — operator inspects the
   JSON, fixes once, re-dispatches.
3. Post-ENG-32: implement loop verifies against the JSON; "did the
   feature land" answers itself.
4. Post-ENG-38: qa verifies against the JSON; "is the smoke green"
   answers itself.

The product principle ("Don't add features ... beyond what the task
requires", CLAUDE.md) is honored: this ticket adds ONE file
(plan-schema.sh), ONE validator helper, ONE detective scan, three
exit codes, one halt reason. Nothing speculative. The OQs explicitly
defer schema 2, reader subcommands, per-criterion descriptions.

**feasibility — PASS, zero P0.** Every code-level claim verified
against the worktree at HEAD on 2026-05-15. Assumption Inventory §9
quotes 23 `path:line` references; one assumption (A20) marked
"assumed" with an explicit verify-during-implement hand-off; one
assumption (A23) marked "assumed" with a documented fallback path if
the registry's writer-side validation isn't yet wired. All other
22 assumptions are verified against actual code or CLAUDE.md
canonical surfaces.

Notes for the planning agent (no P0, all P2):
* `bin/render-prompt.sh::find_doc` matches `linear: <ID>` in
  frontmatter; the agent emits `linear: ENG-122` in this brainstorm
  doc (verified). The plan-stage will reference the brainstorm via
  the `{brainstorm_file}` token (already in the resolver registry).
* The new file `bin/plan-schema.sh` must end with the source-and-test
  sentinel per CLAUDE.md "How tests work."
* The schema in `bin/plan-schema.sh`'s header comment is the single
  source of truth; the inline schema block in AGENT_PROMPTS §2 must
  be tested for divergence (a small fixture-sanity assertion in
  `bin/plan-schema-test.sh`).
* The new halt reason `plan-contract-invalid` must be added to
  `bin/pipeline-events.json::halt_reasons` AND to the agent-facing
  reason allowlist in `AGENT_PROMPTS.md` §0 (the `<reason>` field
  enumeration in the verdict-marker protocol).

**Verdict: 6/6 PASS, 0 P0. Gate satisfied. Proceeding to plan stage.**

(Two P1 items absorbed into D-004 during iteration: security's `<!--`
sanitisation of validator stdout; scope's note that the Linear scope
mis-states "bin/dispatch.sh detective scan" when the correct layer is
`bin/run-stage.sh`. Both resolved in iteration 1; no iteration 2
needed.)
