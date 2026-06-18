---
linear: ENG-204
title: Apply orchestrator-merge to plan.json — content-only plan body, schema envelope merged at prepare time
date: 2026-06-17
status: draft
---

# Apply orchestrator-merge to plan.json (`plan_schema_version`, `issue_id`)

## 1. Problem

ENG-118 / the operator-memory `qa-agent-schema-version-field-slip` chain
established a structural pattern: stage agents reliably slip on invariant
JSON envelope boilerplate (wrong field name, wrong type, missing required
field). The agent's strength is producing structured *content*; the
agent's weakness is typing keys whose values it cannot reason about
(schema version constants, dispatch identifiers, issue-id regex
canon). ENG-203 closed this gap for the qa stage by hoisting envelope
authorship out of the agent's prompt and into a shared
`merge_artifact_envelope` helper in `common.sh`; the qa agent now writes
content-only body sidecars and the orchestrator (post-dispatch for
`verdict-qa.json`, in-dispatch via `verify-qa.sh --body` for
`qa-predicate-<ident>.json`) splices the schema envelope onto the body.

ENG-204 is ENG-202's planning-stage child: apply the same mechanism to
`plan.json`. The two envelope keys the planning agent currently must
emit but does not author the values of are:

* `plan_schema_version` (integer `1` — `bin/plan-schema.sh:113-127`
  rejects anything else; the planning agent has no business choosing
  this value).
* `issue_id` (string matching `^ENG-[0-9]+$` — `bin/plan-schema.sh:129-140`;
  the orchestrator already owns the canonical identifier via
  `$PIPELINE_ISSUE_ID` / `--ident`).

The current prompt at `AGENT_PROMPTS.md:442-465` (§2 plan) instructs the
agent to write a structured contract containing both keys (lines 444
"plan_schema_version" and 460 "Required: plan_schema_version (integer
1), issue_id (matches ^ENG-[0-9]+$)"). When the planning agent slips on
either, `_validate_plan_contract` (`bin/run-stage.sh:1303-1382`) halts
the dispatch with `plan-contract-invalid` (defect token
`plan-contract-incomplete`). The same prompt-quality lever ENG-203
proved insufficient for qa applies here too.

**The structural difference between plan.json and qa-payload** that
shapes ENG-204's mechanism (and forces a different decision than
ENG-203's qa-payload arm):

| Property | qa-payload (`verdict-qa.json`) | plan.json |
|---|---|---|
| File location | `$(issue_dir ident)/verdict-qa.json` — **off-tree** under `$PROJECT_STATE_DIR` | `$wt/docs/plans/<date>-<eng>-<slug>.json` — **in worktree HEAD** |
| Validated where | post-dispatch (orchestrator reads `$(issue_dir)/verdict-qa.json`) | post-dispatch (`_validate_plan_contract` shells `git ls-tree -r HEAD -- docs/plans/`) |
| Commit requirement | never committed | MUST be in `HEAD` (ENG-179 invariant — `bin/run-stage.sh:1334-1353`) |
| Who commits | nobody | the planning agent (`Bash(git add:*),Bash(git commit:*)` — `bin/dispatch.sh:650`) |

Because the plan canonical must land in HEAD, the body-sidecar →
canonical merge has to produce a file that ends up committed. ENG-203
already shipped two patterns for body→canonical merge: post-dispatch
(qa-payload, D-006) and in-dispatch via a `--body` flag on the agent's
existing validator invocation (qa-predicate, D-004). The plan case
maps cleanly to the **in-dispatch** pattern because the agent is the
one who commits the canonical (preserving ENG-179's "agent self-commit
is LOAD-BEARING" invariant — `bin/run-stage.sh:1322-1325`); shipping a
post-dispatch merge would force the orchestrator to do a synchronous
`git commit` inside `bin/run-stage.sh` to land the canonical in HEAD
before `_validate_plan_contract` runs, which would either skip
pre-commit (`--no-verify`, violating CLAUDE.md "Never skip hooks unless
the user explicitly asks") or eat the ~30s `bin/*-test.sh` cost on
every planning dispatch.

## 2. Decisions

### D-001. Mechanism: in-dispatch merge via a new `bin/plan-schema.sh prepare --body <body> --md <md> --ident <ENG-N>` subcommand. The planning agent writes a content-only `plan.body.json` at off-tree path `$(issue_dir ident)/plan.body.json`, runs `prepare` to materialize the canonical at `docs/plans/<date>-<eng>-<slug>.json` in the worktree, then commits `.md` + canonical `.json` exactly as today.

**Rationale.** Four candidate mechanisms were considered. The shape is
constrained by the HEAD-commit requirement: the merge must produce a
canonical that is committed before `_validate_plan_contract` runs.

* **A. In-dispatch merge via `plan-schema.sh prepare` (chosen).**
  Mirrors ENG-203 D-004 (qa-predicate's `verify-qa.sh --body`). Agent
  writes body off-tree; runs `bash bin/plan-schema.sh prepare --body
  {plan_body_path} --md docs/plans/<date>-<eng>-<slug>.md --ident
  {issue_id}`; prepare calls `merge_artifact_envelope` and writes
  canonical next to the .md in the worktree; agent then `git add` +
  `git commit`s both .md and canonical .json. The post-dispatch
  `_validate_plan_contract` is unchanged — it finds .md + .json in HEAD
  and validates the canonical, which now carries the orchestrator-injected
  envelope keys.

* **B. Post-dispatch merge in `bin/run-stage.sh::_merge_plan_envelope`.**
  Mirrors ENG-203 D-006 (qa-payload). Agent writes body off-tree;
  commits only the .md. Orchestrator post-dispatch reads body, calls
  `merge_artifact_envelope`, writes canonical to worktree, **commits
  canonical to HEAD on the feature branch**, then `_validate_plan_contract`
  validates. Rejected on three grounds: (1) requires orchestrator-side
  `git commit` inside run-stage.sh — either with `--no-verify` (rejected
  by CLAUDE.md "Never skip hooks…") or paying ~30s pre-commit cost on
  every planning dispatch; (2) splits commit authorship between agent
  (.md) and orchestrator (.json), making the ENG-179 "agent self-commit
  is LOAD-BEARING" mental model murkier; (3) **cutover-fragile** —
  pre-ENG-204 in-flight dispatches at deploy time still write canonical
  .json directly and have no body sidecar; new orchestrator's
  `_merge_plan_envelope` halts on body-missing for every in-flight
  planning dispatch. (See D-008 for cutover analysis.)

* **C. Pre-seed canonical at dispatch start; agent edits content via `Edit`.**
  Same shape as ENG-203 D-001 alt-B. Rejected for the same reason:
  Edit-anchor fragility, silent failure mode (anchor-not-found → no
  edit → seeded sentinel passes through to validator), envelope still
  mutable by agent past the anchor.

* **D. Strengthen the prompt only.** Same shape as ENG-203 D-001 alt-D.
  Rejected: ENG-118's live-evidence chain (operator memory
  `qa-agent-schema-version-field-slip` and `qa-payload fix is ENG-203
  not prompt`) proves prompts don't suffice. Re-typing instructions an
  agent has already misread is not a structural fix.

**Reference to constraint.** CLAUDE.md "Per-issue state must reference
`$PROJECT_STATE_DIR`, never `$HARNESS_STATE_DIR/<issue>` directly":
body sidecar resolves through `issue_dir`
(`bin/common.sh:68-72`) → `$PROJECT_STATE_DIR/<ident>/plan.body.json`.

**Reference to constraint.** CLAUDE.md "Cross-dispatch staleness
contract (ENG-87)": "Per-medium primitives: clear-on-dispatch-start
for per-issue files." Body sidecar gets the same treatment — cleared
at planning-stage dispatch start by `_clear_current_stage_slots`
(D-005).

**Reference to constraint.** CLAUDE.md "Don't add features beyond what
the task requires." `prepare` accepts only what the planning caller
needs today (body, md, ident). The qa-predicate's `--body` flag is
NOT generalised to plan via a top-level `merge` helper subcommand;
each stage's prepare-style command sits in the stage's natural
validator script (plan-schema.sh / verify-qa.sh) so the plan/review
children of ENG-202 can follow the same convention without
introducing a new shared abstraction.

### D-002. Body content shape: `{ "features": [ ... ] }`. The body is the JSON content the planning agent already authors today, MINUS the two envelope keys.

**Rationale.** Today's canonical `plan.json` schema (single source of
truth: `bin/plan-schema.sh:26-44`) is exactly three top-level keys:
`plan_schema_version`, `issue_id`, `features[]`. Of those, two are
envelope (D-001's slip surface) and one is content (`features[]`).
The body sidecar therefore carries `features[]` only.

The .md file is unchanged — `bin/plan-schema.sh::cmd_validate_md`
operates on the prose plan (Goal / Assumption Inventory / System
invariants / File Structure / API Contract / Backend Tasks / Frontend
Tasks / Failure Mode → Test Map / Test Strategy per `AGENT_PROMPTS.md:498-508`).
The ticket's wording "features[], tasks, pass_criteria, File Structure,
System invariants, API surface block" conflates the .md and .json
contents; ENG-204 only changes the **.json** envelope authorship.
The .md and its System-invariants validator are untouched.

**Closed envelope keyset.** The envelope JSON the helper receives MUST
carry only `{plan_schema_version: 1, issue_id: "$ident"}` — **two
keys**, not three (no `dispatch_id`; `bin/plan-schema.sh:113-140`
defines no dispatch_id field). Right-biased merge means the envelope
overwrites any colliding body key, so if the agent regresses and emits
`plan_schema_version: "v1"` in the body, the orchestrator's `1` wins
silently. **The envelope MUST NOT carry `features` or any other
content key** — the right-bias merge would silently overwrite
agent-authored content otherwise. Per ENG-203 D-001 the helper is
**taxonomy-agnostic** and does NOT enforce the keyset; the
invariant is owned by the caller. D-009 pins a caller-side test (P-1)
asserting the envelope `prepare` constructs contains exactly
`{plan_schema_version, issue_id}` and nothing else.

**Reference to constraint.** ENG-203's helper docstring at
`bin/common.sh:700-712`: "Caller (NOT the helper) owns envelope-keyset
discipline." Same discipline applied here.

### D-003. The `prepare` subcommand lives in `bin/plan-schema.sh`, NOT in a new top-level script and NOT in `bin/common.sh`.

**Rationale.** Placement parallels ENG-203 D-002 / D-004 reasoning:

* `bin/plan-schema.sh` (chosen). Already the canonical plan-artifact
  helper script (sibling subcommands `validate` and `validate-md`).
  Adding `prepare` as a third subcommand matches the existing
  command-dispatcher shape (`bin/plan-schema.sh:371-382`) — a one-line
  case-arm addition. Sourcing `common.sh` happens at script top
  (`bin/plan-schema.sh:55`) so `merge_artifact_envelope` is in scope.
  Test surface is the existing `bin/plan-schema-test.sh` /
  `bin/plan-schema-adversarial-test.sh` — no new test file needed.

* New `bin/plan-prepare.sh` script. Rejected — adds a new top-level
  executable for a function that has exactly one caller (the planning
  agent). Costs a sibling `bin/plan-prepare-test.sh` for ~30 lines of
  logic that fits cleanly next to `cmd_validate`. CLAUDE.md ticket
  sizing rubric: "Don't add features beyond what the task requires."

* Inline in `bin/run-stage.sh`. Rejected — the agent invokes `prepare`
  in-dispatch via the `Bash(bash bin/plan-schema.sh:*)` allowlist; the
  agent cannot reasonably source `run-stage.sh` (which is an executable
  with `main()`, not a library).

* In `bin/common.sh` as a function. Rejected — `prepare` is a CLI
  surface the agent invokes, not a library helper. The shared library
  helper (`merge_artifact_envelope`) already lives in `common.sh`;
  `prepare` is the plan-specific CLI shim that calls it.

**`prepare` signature and body** (mirrors `bin/verify-qa.sh:629-680`'s
`--body` integration phase):

```bash
# bash bin/plan-schema.sh prepare --body <body> --md <md> --ident <ENG-N>
#
# Read body JSON object at <body>; construct envelope
# {plan_schema_version: 1, issue_id: <ident>}; merge via
# merge_artifact_envelope; write canonical at <md>%.md.json next to <md>.
#
# rc=0   merge succeeded; canonical written next to <md>.
# rc=33  body malformed (parse error, not object, oversize) OR --md
#        does not end in .md OR --md is a symlink OR --body is a
#        symlink OR --body realpath outside $PROJECT_STATE_DIR.
# rc=34  --body or --md missing flag value, or --ident missing, or
#        --ident does not match ^ENG-[0-9]+$.
# rc=35  --body file does not exist.
cmd_prepare() {
  local ARG_BODY="" ARG_MD="" ARG_IDENT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --body)  [[ $# -ge 2 && "$2" != --* ]] \
                 || { printf 'plan-schema.sh: --body requires a non-flag value\n' >&2; return 34; }
               ARG_BODY="$2"; shift 2 ;;
      --md)    [[ $# -ge 2 && "$2" != --* ]] \
                 || { printf 'plan-schema.sh: --md requires a non-flag value\n' >&2; return 34; }
               ARG_MD="$2"; shift 2 ;;
      --ident) [[ $# -ge 2 && "$2" != --* ]] \
                 || { printf 'plan-schema.sh: --ident requires a non-flag value\n' >&2; return 34; }
               ARG_IDENT="$2"; shift 2 ;;
      --*)     printf 'plan-schema.sh: unknown flag %s\n' "$1" >&2; return 34 ;;
      *)       printf 'plan-schema.sh: prepare takes only flags, got: %s\n' "$1" >&2; return 34 ;;
    esac
  done
  [[ -n "$ARG_BODY" ]]  || { printf 'plan-schema.sh: prepare: --body required\n' >&2; return 34; }
  [[ -n "$ARG_MD" ]]    || { printf 'plan-schema.sh: prepare: --md required\n' >&2; return 34; }
  [[ -n "$ARG_IDENT" ]] || { printf 'plan-schema.sh: prepare: --ident required\n' >&2; return 34; }
  [[ "$ARG_IDENT" =~ ^ENG-[0-9]+$ ]] \
    || { printf 'plan-schema.sh: --ident must match ^ENG-[0-9]+$, got %s\n' "$ARG_IDENT" >&2; return 34; }
  [[ "$ARG_MD" == *.md ]] \
    || { printf 'plan-schema.sh: --md must end in .md, got %s\n' "$ARG_MD" >&2; return 33; }

  # Body realpath fence (mirrors bin/verify-qa.sh:641-661).
  [[ -L "$ARG_BODY" ]] \
    && { printf 'plan-schema.sh: --body must not be a symlink: %s\n' "$ARG_BODY" >&2; return 33; }
  [[ -f "$ARG_BODY" ]] \
    || { printf 'plan-schema.sh: --body file not found: %s\n' "$ARG_BODY" >&2; return 35; }
  local body_dir body_parent_real body_real prefix_real
  body_dir="$(dirname "$ARG_BODY")"
  body_parent_real="$(cd "$body_dir" 2>/dev/null && pwd -P)" \
    || { printf 'plan-schema.sh: cannot resolve --body parent\n' >&2; return 33; }
  body_real="$body_parent_real/$(basename "$ARG_BODY")"
  prefix_real="$(cd "$PROJECT_STATE_DIR" 2>/dev/null && pwd -P)" \
    || { printf 'plan-schema.sh: cannot resolve $PROJECT_STATE_DIR\n' >&2; return 33; }
  [[ "$body_real" == "$prefix_real"/* ]] \
    || { printf 'plan-schema.sh: --body must resolve under $PROJECT_STATE_DIR; got %s\n' "$body_real" >&2; return 33; }

  # --md realpath fence: must resolve under cwd (the worktree the agent
  # dispatches in). Refuses absolute paths outside the worktree and
  # symlinks. cwd-relative is the natural shape — the agent writes
  # docs/plans/<>.md from the worktree.
  [[ -L "$ARG_MD" ]] \
    && { printf 'plan-schema.sh: --md must not be a symlink: %s\n' "$ARG_MD" >&2; return 33; }
  local md_dir md_parent_real md_real cwd_real
  md_dir="$(dirname "$ARG_MD")"
  md_parent_real="$(cd "$md_dir" 2>/dev/null && pwd -P)" \
    || { printf 'plan-schema.sh: cannot resolve --md parent (does the directory exist?)\n' >&2; return 33; }
  md_real="$md_parent_real/$(basename "$ARG_MD")"
  cwd_real="$(pwd -P)"
  [[ "$md_real" == "$cwd_real"/* ]] \
    || { printf 'plan-schema.sh: --md must resolve under cwd (the worktree); got %s\n' "$md_real" >&2; return 33; }

  # Build envelope (closed keyset — D-002). Canonical path is derived
  # from the FENCED `md_real` (post-realpath), NOT the agent-supplied
  # `ARG_MD` literal — security defense-in-depth (Iter-1 security P1):
  # an attacker who staged a parent-dir symlink could otherwise see the
  # fence pass on the resolved path but the merge land on the unresolved
  # ARG_MD-derived canonical. Today's planning allowlist has no `Bash(ln:*)`
  # / `Bash(mv:*)` so the TOCTOU is unreachable, but the resolved-path
  # form is the correct defense if a future stage gains those grants.
  local env_json canonical merge_rc=0
  canonical="${md_real%.md}.json"
  env_json="$(jq -nc --arg ii "$ARG_IDENT" \
    '{plan_schema_version: 1, issue_id: $ii}')"

  PIPELINE_ISSUE_ID="$ARG_IDENT" PIPELINE_STAGE=planning \
    merge_artifact_envelope "$ARG_BODY" "$env_json" "$canonical" \
    || merge_rc=$?
  case "$merge_rc" in
    0)  printf 'plan-contract-prepared: %s\n' "$canonical"; return 0 ;;
    39) return 33 ;;  # body malformed → plan-contract-malformed
    41) return 35 ;;  # body missing → plan-contract-missing
    42) return 33 ;;  # caller-bug (envelope not object) — cannot fire by construction
    50) return 33 ;;  # write failure → plan-contract-malformed (cosmetic mis-map; helper stderr disambiguates)
    *)  return 33 ;;
  esac
}
```

**Caller-side rc remap discipline** (mirrors ENG-203 D-004's
"Caller-side rc remap" paragraph). The helper's qa-payload range
(39/41/42/50) is remapped to plan-schema's range (33/34/35) inside
`cmd_prepare`'s `case` block, immediately after the merge call. This
keeps both consumers within their documented taxonomy ranges; the
cosmetic mis-map (rc=42/50 → 33 "plan-contract-malformed") is
acceptable because the halt body carries the helper's stderr verbatim
(per ENG-203 D-001), so the operator sees the true root cause
("body missing", "atomic mv failed", etc.) even when the failure_outcome
slot is the same generic `plan-contract-malformed` token.

**Main dispatcher edit** (`bin/plan-schema.sh:371-382`):

```bash
case "$subcmd" in
  validate)    cmd_validate "$@" ;;
  validate-md) cmd_validate_md "$@" ;;
  prepare)     cmd_prepare "$@" ;;          # NEW (ENG-204)
  *)
    printf 'Usage: bash bin/plan-schema.sh {validate <file> [--ident <ENG-N>] | validate-md <file> | prepare --body <body> --md <md> --ident <ENG-N>}\n' >&2
    exit 33
    ;;
esac
```

### D-004. `bin/dispatch.sh::allowed_tools_for "planning"` gains TWO new patterns: `Bash(bash .pipeline/bin/plan-schema.sh:*)` and `Bash(bash bin/plan-schema.sh:*)`.

**Rationale.** The agent runs `bash bin/plan-schema.sh prepare …`
in-dispatch. Today plan-schema.sh is only invoked by the orchestrator
post-dispatch (`bin/run-stage.sh::_validate_plan_contract` line 1355)
and is therefore not in any stage's allowlist. Both dual-path patterns
mirror the existing `linear.sh`/`pipeline.sh` shape (see comment at
`bin/dispatch.sh:622-633`) so the allowlist works equally for
harness-self-host (worktree has `bin/`) and non-harness targets
(worktree has `.pipeline/bin/`).

The patch (`bin/dispatch.sh:650`) appends both patterns to the planning
base list:

```bash
planning) base='Read,Write,Edit,Grep,Glob,TaskCreate,\
Bash(git log:*),Bash(git diff:*),Bash(git status:*),Bash(git add:*),Bash(git commit:*),\
Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),\
Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),\
Bash(bash .pipeline/bin/plan-schema.sh:*),Bash(bash bin/plan-schema.sh:*)' ;;
```

(Line continuations for readability — the actual edit keeps the value on
one line, matching the sibling stage entries.)

**No other surface change.** The allowlist is the only dispatch-side
gate the agent's `prepare` call needs to clear. `bin/plan-schema.sh`
already sources `bin/common.sh`, so `merge_artifact_envelope` is in
scope when the agent invokes prepare from the worktree cwd. The
existing `bin/plan-schema-test.sh` tests run under the same
filesystem; they will exercise the new `cmd_prepare` path without
allowlist relevance.

**Reference to constraint.** Project profile addendum "Tool
allowlist": planning was previously `(none)` for stack-tools — this
ticket adds an orchestrator-script tool to base, not a stack tool.
Profile is unchanged.

### D-005. `bin/run-stage.sh::_clear_current_stage_slots` planning branch: `rm -f $d/plan.body.json` at planning-stage dispatch start. The worktree-side canonical `.json` is NOT cleared by the orchestrator (agent will rewrite/overwrite at prepare time; if a prior dispatch's canonical survives uncommitted, the agent's fresh `Write`/prepare overwrites it).

**Rationale.** ENG-87 cross-dispatch staleness contract: per-medium
primitive is "clear-on-dispatch-start for per-issue files." The body
sidecar is a new per-issue file living under `$PROJECT_STATE_DIR/<ident>/`
and needs the same primitive — otherwise a stale body from a prior
dispatch could leak into a fresh dispatch's `prepare` invocation
(yielding a "prepare succeeded" canonical built on a previous
iteration's `features[]`).

Current `_clear_current_stage_slots` (`bin/run-stage.sh:949-981`) has
no planning-stage branch. Post-ENG-204:

```bash
# ENG-204: pre-clean plan body sidecar on planning-stage dispatch
# start. Per-medium primitive (CLAUDE.md ENG-87) for the new
# agent-owned writer file. Stage-gated to planning because the file
# is plan-specific; clearing on other stages would erase the body
# while the implementing/qa stages still need to read it (they don't,
# in fact — they read the canonical .json in HEAD via the
# {plan_json} resolver — but stage-gating is the contract). Mirrors
# ENG-203 D-005's qa-stage extension.
if [[ "$stage" == "planning" ]]; then
  rm -f "$d/plan.body.json" 2>/dev/null || true
fi
```

**Why NOT clear the worktree-side canonical `docs/plans/<>.json`.**
Three reasons: (1) The canonical lives in the worktree, not under
`$PROJECT_STATE_DIR` — `_clear_current_stage_slots`'s contract is
per-issue state, not worktree files. (2) On planning re-dispatch, the
agent re-runs `prepare` which atomically `mv`s a fresh canonical over
any prior canonical (`merge_artifact_envelope` uses `mktemp` + `mv`).
(3) If the agent re-dispatch picks a *different* slug or date and
writes a NEW canonical at a different path, the prior canonical
would be orphaned in the worktree — but that's an `_validate_plan_contract`
matter (it uses `sort | tail -1` over the `docs/plans/` listing to
pick the latest .md; the corresponding .json sibling is validated). A
truly stale orphan would only matter if a sibling stage read
docs/plans/ by glob, which no stage does today.

**Edge case — loopback `planning → brainstorming` (verdict fail target).**
When the planning agent emits `verdict fail --target brainstorming`,
the next dispatch is brainstorming, NOT planning. The
`_clear_current_stage_slots "$ident" "brainstorming"` call does NOT
touch `plan.body.json` (per the existing stage-gating). When planning
re-dispatches after brainstorming completes, the planning-stage clear
fires fresh. No staleness regression.

**Reference to constraint.** CLAUDE.md "Cross-dispatch staleness
contract": "Per-medium primitives: clear-on-dispatch-start for
per-issue files (current-stage only; OTHER stages preserved for
loopback)." This decision strictly honors the stage gating — only the
planning-stage branch grows.

### D-006. New render-prompt resolver `{plan_body_path}` → `$(issue_dir ident)/plan.body.json`. Added to `PROMPT_RESOLVERS`, exported on `_RENDER_PLAN_BODY_PATH`, with a sidecar entry in `_write_rendered_paths_sidecar`.

**Rationale.** The agent writes the body via `Write` at a path the
prompt names. Hardcoding the path string in `AGENT_PROMPTS.md` would
duplicate the resolver's value and drift; emitting it as a resolved
token (mirroring `{qa_payload_body_path}` and `{qa_predicate_body_path}`
from ENG-203 D-003) is the established pattern.

Three coordinated edits, parallel to ENG-203's two-token addition
(`bin/render-prompt.sh:60-62`):

1. **`PROMPT_RESOLVERS` registry** (`bin/render-prompt.sh:40-66`):
   add `plan_body_path=_resolve_plan_body_path`.

2. **Resolver function** (`bin/render-prompt.sh:289-290` sibling):
   `_resolve_plan_body_path() { printf '%s' "$_RENDER_PLAN_BODY_PATH"; }`

3. **`main()` binding** (`bin/render-prompt.sh:683-688` sibling):
   `_RENDER_PLAN_BODY_PATH="$(plan_body_path "$issue_id")"`.

4. **New `plan_body_path` helper in `bin/common.sh`** (sibling of
   `qa_payload_body_path` at line 99-103): returns
   `$(issue_dir ident)/plan.body.json`. Exported via the line 961
   `export -f` list.

5. **`_write_rendered_paths_sidecar` allowlist** (`bin/render-prompt.sh:97-132`):
   add `[[ -n "${_RENDER_PLAN_BODY_PATH:-}" ]] && printf 'plan_body_path\t%s\n' "$_RENDER_PLAN_BODY_PATH"`.
   The sidecar feeds the post-dispatch Phase B detective (ENG-156 D-004
   contract surface); without this entry, a sandbox denial against
   `plan_body_path` would have no entry in the contract surface and
   the detective would no-op. Per ENG-156 the registry is enumerated
   explicitly to keep this closed-allowlist contract surface honest.

**Reference to constraint.** ENG-203 / ENG-156 D-004: "Adding a new
token = (a) register here, (b) add the resolver function below, (c)
emit the {token} in AGENT_PROMPTS.md." All three sites covered.

### D-007. AGENT_PROMPTS.md §2 (plan) edits: strip envelope keys from the inline schema example; rename the .json write step to a body-sidecar write at `{plan_body_path}`; add a `prepare` invocation step before the commit step.

**Rationale.** The plan-schema-v1 example block at
`AGENT_PROMPTS.md:442-458` is the agent's literal content shape. Post-ENG-204:

* **Lines 442-458 (the plan-schema-v1 code block, fence-inclusive):**
  remove the `"plan_schema_version": 1,` (line 444) and
  `"issue_id": "{issue_id}",` (line 445) entries.
  The remaining block:
  ```plan-schema-v1
  {
    "features": [
      {
        "id": "F-1",
        "summary": "<one-sentence outcome matching the Goal section>",
        "pass_criteria": [
          { "kind": "smoke",       "command": "<shell command>", "expect_exit": 0, "expect_stdout_match": null },
          { "kind": "file_exists", "path": "<relative path from repo root>" },
          { "kind": "grep",        "path": "<relative path>", "pattern": "<regex>", "expect_match": true }
        ]
      }
    ]
  }
  ```
  The label `plan-schema-v1` on the fence is unchanged (informational
  only — the markdown fence info-string is not consumed by any
  validator).

* **Line 437 ("Additionally produce a sibling structured contract at
  docs/plans/<>.json"):** rewrite to instruct the agent to write the
  body at `{plan_body_path}` and then run `prepare`:

  > Additionally produce a content-only body sidecar at `{plan_body_path}`
  > containing the JSON shape below (features[] only — `plan_schema_version`
  > and `issue_id` are MERGED ONTO THE BODY BY THE ORCHESTRATOR; do not
  > emit those keys yourself). After writing the body, run
  > `bash bin/plan-schema.sh prepare --body {plan_body_path} --md docs/plans/{date}-{issue_id_lower}-{slug}.md --ident {issue_id}`
  > to materialize the canonical `docs/plans/{date}-{issue_id_lower}-{slug}.json`
  > in your worktree. The `prepare` command exits with rc=33/34/35
  > (plan-contract-malformed / -incomplete / -missing) if the body is
  > malformed; on success its stdout prints `plan-contract-prepared: <path>`.

* **Line 460 ("Required: plan_schema_version (integer 1), issue_id
  (matches ^ENG-[0-9]+$), features[] (len≥1)…"):** rewrite to:

  > Required body keys: `features[]` (len≥1). Per-feature: `id`,
  > `summary`, `pass_criteria[]` (len≥1). Per-criterion: `kind` in
  > `{smoke, file_exists, grep}` plus kind-specific fields. The
  > orchestrator-merged canonical adds `plan_schema_version: 1` and
  > `issue_id: "{issue_id}"`. Unknown fields: permitted (warning only).
  > Missing or malformed body halts the dispatch via `prepare`'s rc;
  > the post-dispatch `bin/run-stage.sh::_validate_plan_contract`
  > continues to gate the merged canonical against the full schema.

* **NEW step between body-write and commit — `prepare` rc handling**
  (folded from design persona Iter-1 P1-1; agent ergonomics). The
  prompt MUST instruct: "If `bash bin/plan-schema.sh prepare ...`
  exits non-zero, do NOT `git add`/`git commit` — instead run
  `bash bin/pipeline.sh event {issue_id} verdict halt --reason
  agent-blocked` and post a one-line follow-up comment naming
  prepare's stderr, then exit." This prompt-level discipline is
  defense-in-depth — even when the agent ignores the rc, the
  downstream `_validate_plan_contract` halts on the missing/malformed
  canonical, so the dispatch never silently lands a broken plan. But
  the explicit instruction shortens the operator's triage path. PC-7
  (D-009) literal-greps the instruction shape.

* **Completion checklist step 4** (`AGENT_PROMPTS.md:664-667`): no
  edit needed — the step still says "Commit … the staged set MUST
  include both `docs/plans/{date}-{issue_id_lower}-{slug}.md` AND
  `docs/plans/{date}-{issue_id_lower}-{slug}.json`". The `.json`
  reference now points to the orchestrator-merged canonical produced
  by `prepare`, not an agent-authored canonical. The behavioral
  contract (both committed) is identical.

**Reference to constraint.** ENG-77/ENG-71 stage-summary
overwrite-on-every-dispatch contract: the body file is written via
`Write` (not `Edit`), so overwrite-on-every-dispatch is automatic. No
new contract risk.

**Reference to constraint.** Project profile addendum "Don'ts":
"Never use a column-0 \`\`\` fence inside a stage's body in
AGENT_PROMPTS.md — render-prompt.sh requires exactly two fences per
stage block." The edits stay inside the existing single fenced block
of §2; no new fences introduced.

### D-008. No backward-compat shim for "old-shape canonical" pre-ENG-204. The cutover is **atomic by construction** because the merge is in-dispatch.

**Rationale.** Compare to ENG-203 D-008's cutover analysis:

* **ENG-203 qa-payload (post-dispatch merge).** Cutover risk:
  pre-ENG-203 agent in flight at deploy time writes canonical
  `verdict-qa.json` directly with no body sidecar; new orchestrator's
  `_merge_qa_payload_envelope` halts with `qa-payload-missing` (rc=41).
  ENG-203 documented this as the ONE legitimate cutover artifact,
  bounded to one issue per project.

* **ENG-204 plan (in-dispatch merge).** Cutover risk: **zero**.
  Pre-ENG-204 agent in flight at deploy time writes canonical
  `docs/plans/<>.json` directly with no body sidecar AND no `prepare`
  invocation; commits both .md and canonical .json; post-dispatch
  `_validate_plan_contract` (UNCHANGED) finds both in HEAD and
  validates. The new orchestrator code (`_clear_current_stage_slots`'s
  planning branch, `plan_body_path` resolver) does not block validation
  — it only clears a file that doesn't exist (idempotent
  `rm -f … || true`) and renders a token into the prompt the agent
  may or may not have been instructed to consume. The PRE-ENG-204
  agent doesn't see the new prompt instructions (it's already past
  the render step), but it ALSO doesn't need them — it's writing
  canonical directly per the OLD prompt.

* **The post-cutover flip happens at the next planning dispatch's
  render step.** That dispatch gets the NEW prompt, writes a body,
  runs `prepare`, commits the merged canonical. No operator-visible
  artifact.

This is the key advantage of in-dispatch merge for plan over the
post-dispatch alternative.

**The one residual cutover hazard.** If a pre-ENG-204 dispatch wrote
a stale `plan.body.json` to `$(issue_dir)/` somehow (it doesn't, but
hypothetically), the next planning-stage dispatch's
`_clear_current_stage_slots` clears it before any prepare invocation
runs (D-005). So even a hypothetical stale body cannot poison a
post-cutover dispatch.

**Self-hosting bootstrap caveat** (folded from product persona
Iter-1 P1-3). ENG-203 halted 13× on its own gate during self-hosting
because the planning agent of ENG-203's own ticket had to write the
new shape ENG-203 introduced. The analogous risk for ENG-204: when
the planning stage of the ENG-204 ticket itself dispatches AFTER the
prompt edit ships, that agent must correctly emit body-only +
invoke `prepare`. If it slips, ENG-204's own planning halts. Two
mitigations: (1) the PC-1..PC-7 prompt-content tests run on every
commit, so a malformed §2 edit fails CI before ENG-204 ships; (2)
the operator's `qa-payload fix is ENG-203 not prompt` memory entry
documents the "self-hosting bootstrap trap" pattern, so the
operator's mental model on the ENG-204 ship day already includes
"if planning halts on the cutover dispatch, land the worktree by
hand and force the transition" (per the operator memory
`implement-timeout-oversized-foundation-tickets`).

**Reference to constraint.** CLAUDE.md "Don't add backwards-compatibility
shims when you can just change the code." The in-dispatch design has
no cutover gap to bridge.

### D-009. Test surface: prepare unit cases in `bin/plan-schema-test.sh` (+ adversarial in `bin/plan-schema-adversarial-test.sh`); prompt-content assertion in `bin/agent-prompts-content-test.sh`; orchestration assertion in `bin/run-stage-test.sh`.

**Rationale.** Mirrors ENG-203 D-009's test layout. Each file gets
cases targeting its existing surface; no new test files needed.

**`bin/plan-schema-test.sh`** (unit — `cmd_prepare`):

* **P-1 Envelope keyset closure.** `cmd_prepare` constructs envelope
  `{plan_schema_version: 1, issue_id: ENG-1}` — exactly two keys.
  Assert via `jq -r 'keys | sort | join(",")'` against the env_json
  the function builds (fixture-driven by mocking the jq subshell,
  OR by reading the canonical post-merge and asserting the only
  non-`features` keys are `plan_schema_version` + `issue_id`). This
  pins D-002's closed-keyset invariant.
* **P-2 Body+envelope merge.** Body is `{"features":[{"id":"F-1",
  "summary":"x","pass_criteria":[{"kind":"file_exists","path":"x"}]}]}`,
  envelope is computed from `--ident ENG-1`. Assert canonical contains
  all three top-level keys with envelope's values, and that
  `cmd_validate` accepts the canonical.
* **P-3 Body collision: body has `issue_id: "ENG-99"`, --ident says
  "ENG-1".** Assert canonical has `issue_id: "ENG-1"` (envelope wins
  per ENG-203 D-001's right-bias merge).
* **P-4 Body missing → rc=35.**
* **P-5 Body not JSON object (top-level array) → rc=33.**
* **P-6 Body parse error → rc=33.**
* **P-7 Body is symlink → rc=33** (D-003 fence catches before
  helper).
* **P-8 Body > 64 KiB → rc=33** (helper's size-cap surfaces as
  rc=39, remapped by `cmd_prepare`).
* **P-9 `--ident` missing → rc=34.**
* **P-10 `--ident` malformed (e.g. `eng-1`, `ENG-`, `ENGG-1`) → rc=34.**
* **P-11 `--md` missing → rc=34.**
* **P-12 `--md` does not end in .md → rc=33.**
* **P-13 `--md` is a symlink → rc=33.**
* **P-14 `--md` resolves outside cwd (e.g. absolute `/etc/passwd.md`)
  → rc=33.**
* **P-15 `--body` resolves outside `$PROJECT_STATE_DIR` (e.g.
  absolute `/tmp/x.body.json`) → rc=33.**
* **P-16 Canonical destination not writable (chmod 0500 the parent
  dir, point `--md` inside it) → rc=33** (helper's rc=50 cosmetic
  mis-map).

**`bin/plan-schema-adversarial-test.sh`** (adversarial):

* **PA-1 `--body` whose body contains a key named `plan_schema_version`
  with value `"v1"` (wrong type).** Merge succeeds; envelope's `1`
  wins; `cmd_validate` accepts the canonical. Pins the right-bias
  silent-repair contract.
* **PA-2 Body contains a content key named `linear_issue_id` (typo
  the agent might emit).** Merge passes through; `cmd_validate` warns
  on unknown top-level field; rc=0. Pins permissive-on-unknown contract.
* **PA-3 `cmd_prepare` then `cmd_validate` chain on a fresh worktree:
  body emitted via `Write`, prepare run, validate passes — full path
  exercised end-to-end.**

**`bin/agent-prompts-content-test.sh`** (prompt-content):

* **PC-1 §2 plan-schema-v1 block does NOT contain the literal string
  `plan_schema_version`.** Pins AC#1. (Section locator: extract the
  block fenced as `plan-schema-v1` per the existing literal-grep
  pattern.)
* **PC-2 §2 plan-schema-v1 block does NOT contain the literal string
  `issue_id`.**
* **PC-3 §2 plan-schema-v1 block DOES contain `features`.**
* **PC-4 §2 plan write-step contains the literal `{plan_body_path}` token.**
* **PC-5 §2 plan write-step contains the literal `bash bin/plan-schema.sh
  prepare --body {plan_body_path} --md docs/plans/{date}-{issue_id_lower}-{slug}.md
  --ident {issue_id}` (or its `.pipeline/` prefix sibling) — pins
  the flag-positional shape so an agent that copy-pastes the example
  cannot drift into a no-`--body`/no-`--md`/no-`--ident` form.**
  (Mirrors ENG-203 D-009 AP-7's defensive shape pinning.)
* **PC-6 §2 retains the unchanged "Required body keys" mention of
  `features[]`** — guards against an over-eager edit deleting the
  remaining content-shape doc.
* **PC-7 §2 contains the `prepare` rc-handling sentence** — literal
  search for "If `bash bin/plan-schema.sh prepare` exits non-zero"
  (or its `.pipeline/` sibling). Folded from design persona Iter-1
  P1-1 + product persona Iter-1 P1-1. Without this, the agent has
  no prompt-level signal to halt cleanly on prepare failure; the
  fallback path through `_validate_plan_contract` works but adds
  one tick of operator-visible halt churn.

The §2 prompt may still MENTION the envelope keys in the explanatory
sentence "the orchestrator merges `plan_schema_version` and `issue_id`
onto the body before validation" — that's allowed. PC-1/PC-2 narrow
their assertion to the `plan-schema-v1` fenced block via section
locator (the literal `plan-schema-v1` info-string at the fence is the
anchor).

**`bin/run-stage-test.sh`** (orchestration):

* **OS-1 Planning-stage `_clear_current_stage_slots` clears
  `$(issue_dir ident)/plan.body.json`.** Seed a stale body, fire
  `_clear_current_stage_slots ENG-1 planning`, assert absent.
* **OS-2 Planning-stage `_clear_current_stage_slots` does NOT touch
  `$(issue_dir ident)/verdict-qa.json` or
  `$(issue_dir ident)/qa-predicate-ENG-1.json` or
  `$(issue_dir ident)/verdict-review.json`.** Pins the stage-gating
  invariant — clearing planning must not bleed into qa/review state.
* **OS-3 Planning-stage `_clear_current_stage_slots` does NOT touch
  `$(issue_dir ident)/plan.body.json` from OTHER stages.** Seed a
  body, fire `_clear_current_stage_slots ENG-1 implementing`, assert
  the body survives (preserves the body across stages — though we
  don't actually NEED to preserve it, the ENG-87 contract is
  "current-stage only").
* **OS-4 ENG-118 regression analogue:** body omits
  `plan_schema_version` and `issue_id`; `prepare` produces a
  canonical containing both; `_validate_plan_contract` accepts the
  HEAD-committed canonical. Pins AC#2 / AC#3.
* **OS-5 Render-prompt sidecar emits a `plan_body_path` row.** Pins
  D-006-5 closed-allowlist contract surface.

**`bin/render-prompt-test.sh`** (resolver + sidecar):

* **R-1 `_resolve_plan_body_path` returns `$(issue_dir ident)/plan.body.json`**
  when `_RENDER_PLAN_BODY_PATH` is bound. Pins D-006-2.
* **R-2 `_write_rendered_paths_sidecar` emits a `plan_body_path` row**
  (moved from `bin/run-stage-test.sh::OS-5` per scope persona Iter-1
  P1-2 — the assertion targets render-prompt sidecar emission, not
  orchestration state). Pins D-006-5 closed-allowlist contract surface.

**Test fixture discipline** (folded from security persona Iter-1
P1-3). Every new P-N / PA-N case MUST: (1) create body fixtures via
`mktemp -d`; (2) `trap "rm -rf $tmp" EXIT` at case start; (3) when
exercising `_clear_current_stage_slots` or `prepare`, sandbox
`$PROJECT_STATE_DIR` to a tmp dir so a test-id like `ENG-test` cannot
leak into the operator's real per-issue state. Mirrors the existing
`bin/common-test.sh` pattern.

**`--md` fence test-cwd workaround** (folded from design persona
Iter-1 P1-2). P-2 through P-15's `--md` fence cases require cwd to
be a worktree-shaped tmp dir; the test setup `cd "$tmp"` before
each `cmd_prepare` invocation. This mirrors `bin/verify-qa-test.sh`'s
existing PROJECT_STATE_DIR-isolation pattern.

**T_schema_doc_sync test reframe** (folded from design persona Iter-1
P1-3 + coherence persona Iter-1 P1-2 + feasibility persona Iter-1
P1-1). `bin/plan-schema-test.sh::T_schema_doc_sync` currently
hardcodes `canonical_keys="features,issue_id,plan_schema_version"`
(verified by feasibility persona at `bin/plan-schema-test.sh:253`)
and asserts equality between AGENT_PROMPTS.md's `plan-schema-v1`
block keyset and the validator's expected keyset. Post-ENG-204 the
prompt block keyset shrinks to `{features}` while the validator's
keyset stays `{features, issue_id, plan_schema_version}`.

The reframe is **option (b)** (per A20): split the test into two
assertions —
  1. `prompt_block_keys == {"features"}` (body keyset).
  2. `validator_keys == prompt_block_keys ∪ {"plan_schema_version", "issue_id"}`
     (envelope keyset is added on the validator side).
This keeps the prompt-vs-validator drift-detection contract honest:
when schema-v2 lands and bumps `plan_schema_version` to `2`, OR when
a future envelope key is added (or a content key migrates between
body and envelope), the test fires. Option (a) — naively shrinking
to `{"features"}` and dropping the envelope assertion — would lose
the long-term drift gate this test exists to provide.

**Reference to constraint.** AC#3 of ticket: "Canonical-plan discovery
(frontmatter + .md pairing) unchanged, pinned by the existing
reconcile/plan-contract tests staying green." The OS-4 case
explicitly re-runs `_validate_plan_contract` against a HEAD-committed
merged canonical and asserts pass. No edit to `bin/reconcile-test.sh`
needed.

## 3. Architecture

### 3.1 Files touched

| Path | Change | Lines |
|---|---|---|
| `bin/common.sh` | Add `plan_body_path <ident>` helper (sibling of `qa_payload_body_path` at line 99-103). Export via `export -f` list at line 961. | ~10 added |
| `bin/plan-schema.sh` | Add `cmd_prepare` function (sibling of `cmd_validate` and `cmd_validate_md`). Add `prepare` case-arm to `main()` dispatcher (line 374-380). Update header comment with new subcommand usage. | ~80 added |
| `bin/render-prompt.sh` | Add `plan_body_path=_resolve_plan_body_path` to `PROMPT_RESOLVERS`. Add `_resolve_plan_body_path` function (sibling of `_resolve_qa_payload_body_path` at line 289-290). Bind `_RENDER_PLAN_BODY_PATH="$(plan_body_path "$issue_id")"` in `main()` (sibling of line 687-688). Add `plan_body_path` row to `_write_rendered_paths_sidecar`'s allowlist (sibling of line 113-114). | ~10 added |
| `bin/dispatch.sh` | Append `Bash(bash .pipeline/bin/plan-schema.sh:*),Bash(bash bin/plan-schema.sh:*)` to planning stage's allowlist at line 650. | ~1 changed |
| `bin/run-stage.sh` | Extend `_clear_current_stage_slots` (line 949-981) with the planning-stage branch: `if [[ "$stage" == "planning" ]]; then rm -f "$d/plan.body.json" 2>/dev/null \|\| true; fi`. | ~3 added |
| `AGENT_PROMPTS.md` (§2 plan) | Strip `plan_schema_version` and `issue_id` keys from the `plan-schema-v1` fenced block (lines 442-458); rewrite the line-437 write-step paragraph to instruct body write + prepare invocation; rewrite the line-460 required-fields paragraph to drop envelope keys. | ~20 changed |
| `bin/plan-schema-test.sh` | Add unit cases P-1 through P-16 (D-009) for `cmd_prepare`. **AND** reframe `T_schema_doc_sync` (existing test at line 253) per A20 / D-009 option (b) — split into prompt-block-vs-body assertion + validator-vs-envelope-union assertion. | ~200 added, ~15 changed |
| `bin/plan-schema-adversarial-test.sh` | Add cases PA-1 through PA-3 (D-009). | ~80 added |
| `bin/agent-prompts-content-test.sh` | Add prompt-content assertions PC-1 through PC-6 (D-009). | ~80 added |
| `bin/run-stage-test.sh` | Add orchestration cases OS-1 through OS-4 (D-009; OS-5 moved to render-prompt-test.sh per scope persona Iter-1 P1-2 — it asserts sidecar emission, a render-prompt concern). | ~120 added |
| `bin/render-prompt-test.sh` | Add R-1 + R-2 (D-009; R-2 is OS-5 moved here per scope persona Iter-1 P1-2). | ~40 added |
| `bin/plan-schema.sh` (header comment) | Extend usage doc with `prepare` subcommand and its exit-code table. | ~15 added |
| `bin/run-stage.sh::_validate_plan_contract` | NO change. Validator runs on the merged canonical, unchanged. | 0 |
| `bin/run-stage.sh::_post_plan_contract_halt` | NO change. Existing halt path covers all merge-failure shapes via `cmd_prepare`'s caller-side remap. | 0 |
| `bin/common.sh::merge_artifact_envelope` | NO change. Helper from ENG-203 reused as-is. | 0 |
| `bin/common.sh::failure_outcome_for_exit` | NO change. Codes 33/34/35 already mapped to `plan-contract-malformed/-incomplete/-missing` (line 786-788). | 0 |
| `bin/pipeline-events.json` | NO change. The existing `envelope-overwrite` metric token (added in ENG-203) covers `cmd_prepare`'s collision case — `merge_artifact_envelope` already emits it with `PIPELINE_STAGE=planning` when set (`bin/common.sh:736-740`). The `plan-contract-invalid` halt-reason is already in the registry. | 0 |
| `docs/runbooks/recovery.md` | Add §16 "plan-contract merge failure" entry: agent body missing/malformed → prepare rc≠0 → agent halts → orchestrator's `_validate_plan_contract` re-fires the same halt-reason (`plan-contract-invalid`); recovery is `bash bin/pipeline.sh decide <ENG-N> --action continue`. | ~20 added |
| `CLAUDE.md` "Failure-mode quick reference" table | Optional row update: the existing `plan-contract-missing` entry can mention "body→canonical merge failure" as a secondary cause, with `prepare`'s rc remap pointer. | ~3 changed |

### 3.2 Subsystems touched (rubric check)

Per CLAUDE.md "Ticket sizing rubric" (7-subsystem table):

* **dispatch** — `bin/dispatch.sh` (allowlist), `bin/render-prompt.sh`
  (token + resolver + sidecar entry), `bin/common.sh` (path helper).
* **orchestrator** — `bin/run-stage.sh` (`_clear_current_stage_slots`
  planning branch), `bin/plan-schema.sh` (`cmd_prepare` subcommand).
* **agent prompts** — `AGENT_PROMPTS.md` §2 plan (boilerplate-key
  removal + prepare-invocation step).
* **tests/fixtures** — five test files updated.

**Ticket sizing claim: 2 PRIMARY subsystems** (orchestrator +
agent-prompts) with TWO subordinate lanes (dispatch:
`bin/dispatch.sh` allowlist + `bin/render-prompt.sh` token glue +
`bin/common.sh` helper; tests/fixtures: the five test files). The
brainstorm's §3.1 files-touched table enumerates 4 subsystems by
the rubric's literal table; the "primary 2 + subordinate 2"
exception applies because (a) the dispatch edits are mechanical
(one allowlist line, one resolver+sidecar+helper triple) and (b)
the tests/fixtures lane is always subordinate to whatever
behavioral change spawns it. Folded from scope persona Iter-1
P1-1. Treating dispatch as subordinate matches the ENG-203 pattern
(which also touched `common.sh` and `render-prompt.sh` but counted
as "dispatch subordinate"). **Autonomy-safe** per the rubric.

### 3.3 In-dispatch data flow (plan body → canonical .json)

```
planning agent dispatches.
  ↓
agent reads brainstorm doc per §2 step 8 (line 385).
  ↓
agent writes prose plan via Write at
   docs/plans/{date}-{issue_id_lower}-{slug}.md
  ↓
agent writes content-only body via Write at
   {plan_body_path} = $(issue_dir ident)/plan.body.json
   body = { "features": [ {id, summary, pass_criteria[]}, ... ] }
  ↓
agent writes init.sh via Write at {init_sh_path}
   (existing ENG-125 behaviour; unchanged).
  ↓
agent runs: bash bin/plan-schema.sh prepare
              --body {plan_body_path}
              --md docs/plans/{date}-{issue_id_lower}-{slug}.md
              --ident {issue_id}
  ↓
plan-schema.sh::cmd_prepare:
  ↓
  Step 1: parse argv — capture ARG_BODY, ARG_MD, ARG_IDENT.
  ↓
  Step 2: validate --ident matches ^ENG-[0-9]+$.
          validate --md ends in .md, not a symlink, resolves under cwd.
          validate --body not a symlink, exists, realpath under
            $PROJECT_STATE_DIR.
  ↓
  Step 3: env_json = jq -nc '{plan_schema_version: 1,
                              issue_id: $ii}'
          canonical = ${ARG_MD%.md}.json
  ↓
  Step 4: PIPELINE_ISSUE_ID=$ARG_IDENT PIPELINE_STAGE=planning \
          merge_artifact_envelope $ARG_BODY $env_json $canonical
            (exits with rc 0/39/41/42/50 per ENG-203 helper)
  ↓
  Step 5: caller-side rc remap:
            0  → return 0 (prints plan-contract-prepared)
            39 → return 33 (plan-contract-malformed)
            41 → return 35 (plan-contract-missing)
            42 → return 33 (caller-bug)
            50 → return 33 (write-failure)
  ↓
agent reads cmd_prepare's stdout / exit status.
  If rc != 0, agent halts and emits verdict halt --reason
    agent-blocked with a comment naming the prepare diagnostic.
  ↓
agent runs: git add docs/plans/{date}-{eng}-{slug}.md
            git add docs/plans/{date}-{eng}-{slug}.json
            git commit -m "chore(pipeline): plan for {issue_id}"
  (the .json sibling is the orchestrator-merged canonical, NOT an
   agent-authored canonical — agent treats it as opaque output.)
  ↓
agent emits stage summary + verdict pass --stage planning.
  ↓
agent dispatch exits.
  ↓
run-stage.sh post-dispatch sequence (planning stage):
  ↓
_validate_plan_contract ident     (existing, ENG-122/179, unchanged)
  → git ls-tree HEAD finds .md + .json (both committed by agent)
  → bash bin/plan-schema.sh validate $wt/$plan_json --ident $ident
  → plan-schema.sh validate finds plan_schema_version=1 (from
    envelope merge) and issue_id="ENG-N" (from envelope merge)
    and features[] (from agent body) — schema-v1 PASS.
  → bash bin/plan-schema.sh validate-md $wt/$plan_md → PASS.
  ↓
push_branch_if_ahead + post_completion_comment + verdict_handler.
```

### 3.4 Where the merge runs (vs ENG-203)

| Artifact | Merge timing | Caller | Why |
|---|---|---|---|
| `verdict-qa.json` (ENG-203 D-006) | post-dispatch | `bin/run-stage.sh::_merge_qa_payload_envelope` | Validator runs post-dispatch on off-tree file; no commit needed. |
| `qa-predicate-<ident>.json` (ENG-203 D-004) | in-dispatch | `bin/verify-qa.sh::cmd_validate` (`--body` flag) | Agent reads validator JSONL output for verdict decision; can't decouple. |
| `plan.json` (ENG-204 D-001) | in-dispatch | `bin/plan-schema.sh::cmd_prepare` (NEW subcommand) | Canonical must be in HEAD before `_validate_plan_contract` runs; the agent commits in-dispatch; in-dispatch merge keeps the commit on the agent's side (ENG-179 invariant) and avoids an orchestrator `git commit` in run-stage.sh. |

ENG-202's review children (verdict-review.json, review-findings-ledger.jsonl)
will pick from this matrix per their own constraint. The merge helper
in `common.sh` is shared by all four artifact families.

## 4. Data Flow

### 4.1 Envelope construction (plan)

```bash
local env_json
env_json="$(jq -nc --arg ii "$ARG_IDENT" \
  '{plan_schema_version: 1, issue_id: $ii}')"
```

* `plan_schema_version`: hardcoded `1` — schema-v1 is the only
  supported version (`bin/plan-schema.sh:113-127` rejects anything
  else). When schema-v2 lands (future), this constant moves to a
  `--schema-version` flag.
* `issue_id`: `$ARG_IDENT` — validated by `cmd_prepare` against
  `^ENG-[0-9]+$` before envelope construction. If the agent passes
  a malformed `--ident`, prepare returns rc=34 (caller-side gate)
  before any merge runs.

Note: TWO keys, not three. Plan envelope has NO `dispatch_id` field
(distinct from qa-payload's envelope; matches qa-predicate's
envelope). The plan canonical lives in HEAD and is read across
dispatches (implementing/qa stages consume it via the `{plan_json}`
resolver at `bin/render-prompt.sh:428-460`); pinning it to ONE
dispatch's id would break the cross-dispatch read.

### 4.2 Atomic write

The merge uses ENG-203's helper at `bin/common.sh:713-742`. Per the
helper's docstring (line 700-712):

```bash
tmp="$(mktemp "${canonical}.tmp.XXXXXX")" || return 50
jq -n --slurpfile b "$body" --argjson env "$env_json" \
  '$b[0] + $env' > "$tmp" || return 50
mv "$tmp" "$canonical" || return 50
```

`mktemp` + same-FS `mv` is atomic (POSIX rename); body lives under
`$PROJECT_STATE_DIR` and canonical lives under `$TARGET_REPO/<worktree>`,
which are typically on the same filesystem but not always. The
`mktemp "${canonical}.tmp.XXXXXX"` lands the tempfile next to
canonical (same dir as the eventual canonical), so the `mv` is
within `docs/plans/` — guaranteed intra-FS. The `--slurpfile b` does
a separate read of body (potentially cross-FS) but the data is
in-memory by the time `mv` runs.

### 4.3 Envelope-overwrite forensic metric

ENG-203 added a closed-vocabulary `envelope-overwrite` metric token
to `bin/pipeline-events.json::metric_names` (D-001 OQ-4). The helper
emits this metric (`bin/common.sh:736-740`) when the body contains a
key the envelope overwrites — set via `PIPELINE_ISSUE_ID` + `PIPELINE_STAGE`
which `cmd_prepare` exports before calling the helper. The
retrospective shape (ENG-129) can grep for `event=envelope-overwrite
stage=planning` to surface "planning agent regressed on the
content-only contract" without halting the dispatch.

**No new vocabulary needed for ENG-204** — the token is generic
across all four ENG-202 children; ENG-203 already paid that cost.

### 4.4 Idempotency on resume

`bash bin/pipeline.sh decide ENG-N --action continue` clears
`pipeline:halted` and re-allocates a fresh `PIPELINE_DISPATCH_ID`.
Next planning tick:

* `_clear_current_stage_slots` clears `plan.body.json` (per D-005).
* The worktree's canonical `.json` from the prior dispatch survives
  (in HEAD); the new agent's `prepare` invocation rewrites it
  atomically via `mv`. Git diff shows the modified file; the agent's
  next `git add` + `git commit` re-commits it.
* `_validate_plan_contract` reads HEAD (`git ls-tree`) and validates
  the freshly-committed canonical.

No staleness regression; the ENG-87 freshness contract holds because
the body is cleared and the canonical is overwritten by the new
prepare invocation.

## 5. Error Handling

### 5.1 Exit codes (cmd_prepare)

| rc | Meaning | failure_outcome_for_exit | Halt reason |
|---|---|---|---|
| 0 | Merge succeeded; canonical written. | (continue) | — |
| 33 | Body parse error / not object / size out of range / --md or --body symlink / --md outside cwd / --body outside `$PROJECT_STATE_DIR` / write failure / `cmd_prepare` envelope caller-bug. | `plan-contract-malformed` | `plan-contract-invalid` |
| 34 | `--body` / `--md` / `--ident` missing-flag-value, or `--ident` does not match `^ENG-[0-9]+$`. | `plan-contract-incomplete` | `plan-contract-invalid` |
| 35 | `--body` file does not exist. | `plan-contract-missing` | `plan-contract-invalid` |

The agent observes `cmd_prepare`'s non-zero exit code. Without
further action by the agent, the dispatch continues — `prepare`
failing does NOT auto-halt. The agent is instructed (per the §2 prompt
edit in D-007) to inspect the rc and either fix the body and re-run
or emit `verdict halt --reason agent-blocked`.

**Why no orchestrator-side halt at the prepare-failure point.**
Because `prepare` runs in-dispatch (inside the agent's process), the
orchestrator has no synchronous signal of its failure. The
post-dispatch `_validate_plan_contract` IS the orchestrator's signal:

* If agent re-runs prepare successfully → canonical in HEAD → validator
  passes.
* If agent emits `verdict halt --reason agent-blocked` → orchestrator
  halts at verdict-handler.
* If agent commits .md only (forgot to fix prepare or ignored its rc)
  → validator halts with `plan-contract-missing` (no canonical in HEAD).
* If agent commits a bad canonical (e.g. somehow wrote canonical
  directly bypassing prepare) → validator halts with
  `plan-contract-malformed/-incomplete`.

The orchestrator's existing halt surface (`_validate_plan_contract`
+ `_post_plan_contract_halt`, ENG-122/179) catches every downstream
shape. No new halt site required.

### 5.2 Linear post failures

`_post_plan_contract_halt` posts via `bin/linear.sh add-comment ... || true`
(`bin/run-stage.sh:1393`). Pre-ENG-204 behavior unchanged — a Linear
outage during the merge-failure halt produces a "true" return and
the dispatch exits with the validator code anyway. `classify_failure`
then routes to global breaker via the existing pattern at
`bin/run-stage.sh:2947-2951`.

### 5.3 Concurrent body writes (agent self-retry within one dispatch)

The agent's prompt instructs `Write` (overwrite-on-every-write). Multiple
Write calls in one dispatch overwrite the body file. The next
`prepare` invocation reads whatever body the agent's LAST write
produced. Idempotent.

### 5.4 Helper exposure

`merge_artifact_envelope` is already exported via `bin/common.sh:961`
(ENG-203). `plan_body_path` will be added to the same export list.
`bin/plan-schema.sh` sources `bin/common.sh` at line 55, so both
helpers are in scope for `cmd_prepare`.

## 6. Edge Cases

* **Body is empty file (0 bytes).** Helper's size-cap check
  (`sz <= 0 || sz > 65536`, line 718) catches it → rc=39, remapped
  by `cmd_prepare` to rc=33. Halt body says so via stderr verbatim.
* **Body has the same envelope keys but with WRONG values** (agent
  wrote `plan_schema_version: "v1"` and `issue_id: "ENG-9"` when
  current ident is `ENG-204`). Envelope wins (right-bias). Canonical
  has the correct envelope. The agent's mis-emitted fields are
  silently overwritten — and the `envelope-overwrite` metric fires
  with `count=2 keys=plan_schema_version,issue_id` so the
  retrospective surfaces the slip even though the dispatch passes.
* **Body has unknown content keys** (agent emits `features[].extra_note`).
  `bin/plan-schema.sh::cmd_validate` (lines 211-217 for per-feature
  unknowns, lines 219-227 for top-level unknowns) already handles
  unknowns permissively (warning to stderr + rc=0). Helper merges
  through; canonical validation warns; no halt.
* **Body has top-level array** `[{"features": [...]}]`. Helper rc=39
  ("body is not a JSON object"), remapped to rc=33. Halt body says so.
  Clearer than validator's "features must be an array."
* **Body is a symlink to /etc/passwd.** `cmd_prepare`'s `--body`
  symlink check (D-003 step 2 fence) catches it before any read.
  rc=33. Mirrors verify-qa.sh's defense.
* **`--md` is a symlink to a path outside cwd.** `cmd_prepare`'s
  `--md` symlink check catches it. rc=33.
* **`--md` resolves outside cwd (e.g. absolute `/tmp/x.md`).** Fence
  catches it. rc=33. The agent's cwd is the worktree at dispatch
  time; relative paths from there are the only legitimate shape.
* **`--md` parent directory does not exist** (agent passes
  `docs/plans/<>.md` but `docs/plans/` is gone — e.g. on a fresh
  worktree before agent's first Write). `cd "$md_dir"` fails;
  rc=33 with diagnostic "cannot resolve --md parent." Agent's
  prompt instructs Write the .md BEFORE prepare, so this is a
  prompt-discipline failure not an environmental hazard. Test PA-3
  asserts the prompt's ordering survives.
* **Body and canonical have IDENTICAL inode** (pathological — agent
  symlinked body to canonical). Symlink rejection on body catches
  it before merge starts.
* **Two parallel `prepare` invocations on the same issue.** The
  per-issue in-flight lock (`bin/common.sh::try_acquire_lock` per
  CLAUDE.md "Self-heal" section) serialises planning dispatches.
  The agent is a single sequential process — it never invokes prepare
  in parallel with itself. The helper's `mktemp` (vs `$$`) is
  defense-in-depth for hypothetical future parallel callers.
* **Canonical .json from a prior failed dispatch lives in the worktree
  (dirty but uncommitted).** Agent's `prepare` writes a fresh
  canonical via `mv`, atomically overwriting the prior file. Git
  diff treats the modified file as a normal change; agent's
  `git add` + `git commit` proceeds. **No regression vs today**: the
  pre-ENG-204 agent already overwrites a stale canonical on
  re-dispatch (via its Write call). ENG-204 changes the writer
  (helper instead of agent's Write) but not the overwrite semantic.
  **Caveat** (coherence persona Iter-1 P1-1): the "atomic overwrite"
  claim holds only when the agent reaches the `prepare` step. A
  session-limit death between body-write and prepare-invocation
  could leave the stale canonical untouched AND a fresh body sidecar
  written; the next dispatch's `_clear_current_stage_slots` clears
  the body but the stale worktree canonical remains. `_validate_plan_contract`
  runs on `git ls-tree HEAD` — if the stale canonical was committed
  in a prior dispatch, validator passes against the stale shape;
  otherwise validator halts cleanly. This is the same hazard
  pre-ENG-204 has (session-limit-death between Write and commit),
  not a regression. Operator memory `session-limit-false-halts`
  pins the triage path.
* **Pre-commit hook fails when agent commits.** Today's plan agent
  hits the same surface and halts. ENG-204 doesn't change the
  commit step; pre-commit failures route to the existing
  `dispatch-failed` halt path. (Operator memory `pre-commit-gate-red-blocks-agents`
  pins this surface.)
* **`$PIPELINE_ISSUE_ID` unset during prepare** (sub-case: agent
  invokes prepare in a context where the orchestrator-injected env
  is missing). `PIPELINE_ISSUE_ID` is only used by the helper's
  forensic metric emit (`bin/common.sh:736-740`); merge itself
  doesn't depend on it. If unset, metric is silently skipped (the
  helper's `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]` guard); merge still
  succeeds. The agent's `cmd_prepare` invocation exports
  `PIPELINE_ISSUE_ID="$ARG_IDENT"` for the metric call, so this
  edge is closed by construction.
* **Body file is valid but envelope merge produces an object with
  extra envelope keys** (e.g. orchestrator code regression adds
  `"foo": "bar"` to env_json). Plan-schema's permissive unknown-
  top-level-key handler (line 219-227) warns + rc=0. No halt.
  Forensic surface only.
* **Disk full during atomic mv.** Helper rc=50, remapped to rc=33.
  Halt body says "write failed." `classify_failure` routes via the
  validator's existing path; next tick re-dispatches the planning
  stage; body sidecar was cleared by `_clear_current_stage_slots`
  so the agent's re-dispatch re-writes it. Idempotent.

## 7. Open Questions

* **OQ-1.** ENG-202 named `verdict-review.json` and
  `review-findings-ledger.jsonl` as the next consumers. The
  ledger is JSONL (one row per finding) — does the merge helper
  signature support JSONL, or does it need a new helper sibling?
  **Tentative answer: defer to that ticket's brainstorm** — JSONL
  envelope-per-row is a structurally different shape (each row carries
  its own envelope keys including `dispatch_id`). The current helper
  assumes one body object + one envelope; a JSONL helper would
  enumerate rows and merge per-row. Probably a sibling helper
  `merge_artifact_envelope_jsonl` (or extension via a `--jsonl` flag).
  Not blocking for ENG-204.
* **OQ-2.** Should `cmd_prepare` ALSO run `cmd_validate` on the
  merged canonical and return early on validation failure, sparing
  the post-dispatch validator? **Tentative answer: NO** — keeps the
  in-dispatch / post-dispatch separation clean. `cmd_prepare`'s
  contract is "produce a syntactically-merged canonical"; full
  schema validation is `_validate_plan_contract`'s job. Conflating
  them would change the validator's surface (it would also have to
  accept body-only invocations, which the prompt-content tests would
  then need to assert against). Defer; revisit if operators report
  that prepare-passed-but-validator-failed surfaces (i.e., the agent's
  features[] is content-malformed) cost extra round-trips.
* **OQ-3.** Should the body sidecar `.body.json` suffix be a constant
  in `common.sh` so the helper or path resolvers compose
  `${canonical/.json/.body.json}` programmatically? **Tentative
  answer: defer to ENG-202** — same call as ENG-203 OQ-3. Premature
  DRY for two callers (qa-payload, qa-predicate, plan); concrete paths
  in `plan_body_path`, `qa_payload_body_path`, `qa_predicate_body_path`
  are easier to read and lint.
* **OQ-4.** `cmd_prepare`'s `--md` fence requires the path to resolve
  under cwd. The orchestrator's tick may invoke `bin/plan-schema.sh`
  from a non-worktree cwd (e.g. setup probes). **Tentative answer:
  NOT a real concern** — the agent invokes prepare from the worktree
  (claude's cwd at dispatch is the worktree per ENG-13 D-011); the
  orchestrator only ever invokes `validate` and `validate-md`, not
  `prepare`. Test PA-3 pins the agent-cwd assumption end-to-end.
* **OQ-5.** Should `cmd_prepare` accept an envelope-only mode (no
  `--md`, just `--body --canonical-out`) so a future test or
  retrospective tool could invoke it head-of-the-line? **Tentative
  answer: NO** — premature flexibility. The qa-predicate's `--body`
  flag is the same shape and doesn't generalise either; if a use
  case appears, factor THEN.
* **OQ-6.** The new `Bash(bash bin/plan-schema.sh:*)` planning
  allowlist gives the agent access to `cmd_validate` and
  `cmd_validate_md` too. Is there a slip surface where the agent
  invokes `validate` directly and gets a misleading rc? **Tentative
  answer: NO** — the agent's prompt instructs `prepare` and only
  `prepare`; an agent invoking `validate` directly on a body-only
  file would get a clean `plan-contract-incomplete: missing required
  field plan_schema_version` rc=34, which is symmetric with today's
  failure mode and doesn't break the merge contract. The detective at
  Phase B (ENG-156) doesn't gate on `validate` invocations either.
  Acceptable surface expansion. **Folded note** (security persona
  Iter-1 P1-1): `cmd_validate` takes an unfenced positional `<file>`
  argument; the new allowlist therefore lets the agent `validate` any
  worktree-readable .json file and read its parse-error stderr. The
  read surface is bounded to JSON parse-error context (~200 bytes
  around the offset); legitimate threat surface is small because the
  agent already has `Read` tool authority over the worktree. Documented
  here as a known surface expansion; no fence added because adding one
  would break the orchestrator's own post-dispatch `_validate_plan_contract`
  invocation shape.
* **OQ-7** (folded from security persona Iter-1 P1-2). Hostile body
  content can produce a canonical .json that, when later inlined
  into the implementing/qa stage's prompt via the `{plan_json}`
  resolver, carries a string like `"summary": "$(...)"`. The
  resolver does NOT shell-evaluate; the implementing agent's prompt
  is not a shell context; the implementing agent's `Bash` tool calls
  must individually pass sandbox allowlist. So the literal-string
  inlining is safe. The forensic concern: an attacker who can
  influence the planning agent's body could embed a misleading
  string that the implementing agent QUOTES in its next-stage
  output. Bounded blast radius. **Tentative answer: no fence
  added** — the existing schema-validator permissiveness on string
  contents is the contract. If the operator wants stricter,
  add a `cmd_validate` check that string values match a benign
  charset; defer to a separate ticket.

## 8. Anti-bias checks

### 8.1 ADR stress test

* **ENG-87 cross-dispatch staleness contract.** The body sidecar is a
  new per-issue file; D-005 ensures it gets clear-on-dispatch-start —
  the established per-medium primitive. NO pressure on the contract.
* **ENG-77 stage-summary overwrite-on-every-dispatch.** The body
  file is written via `Write` (not `Edit`), so overwrite-on-every-dispatch
  is automatic. NO pressure on the contract.
* **ENG-122/179 plan-contract HEAD-gating.** `_validate_plan_contract`
  is unchanged. The merged canonical lands in HEAD before the
  validator runs (via the agent's `git commit`, NOT via an
  orchestrator commit). NO pressure on the gate; ENG-179's
  "agent self-commit is LOAD-BEARING" invariant is preserved by
  construction.
* **ENG-203 merge-helper contract.** Helper unchanged. Caller
  (ENG-204's `cmd_prepare`) owns envelope-keyset discipline per the
  helper's docstring (`bin/common.sh:709-712`). D-002 pins the
  closed two-key set. NO pressure.
* **ENG-156 D-004 closed-allowlist contract surface.** D-006-5 adds
  the new resolver to the enumerated sidecar emitter (does NOT DRY
  into a loop). NO pressure.
* **CLAUDE.md "Never skip hooks unless explicitly asked."** Avoided
  by D-001's in-dispatch design — no orchestrator commit, no
  `--no-verify` need. (This was a key reason for choosing in-dispatch
  over post-dispatch.) NO pressure.
* **CLAUDE.md "Don't add features beyond what the task requires."**
  Helper is reused as-is; the new prepare subcommand accepts only the
  three flags the planning agent needs; no JSONL or schema-version
  flexibility added. This brainstorm explicitly resists generalising
  past ENG-204's scope (OQ-1, OQ-3, OQ-5).
* **AGENT_PROMPTS.md fence-count contract** (Project profile
  addendum "Don'ts"). D-007's edits stay inside the existing single
  fenced block of §2; no new column-0 \`\`\` fences introduced.
  NO pressure.
* **Project profile addendum "Tool allowlist" lane.** D-004 adds a
  patterns-to-base entry, not a profile entry — keeps stack-specific
  vs stack-neutral lanes separate. NO pressure.

### 8.2 Simpler alternatives (recap)

Each major decision documents at least one rejected alternative; recap
table:

| Decision | Rejected alternative | Why rejected |
|---|---|---|
| D-001 | Post-dispatch merge in `bin/run-stage.sh::_merge_plan_envelope` (qa-payload-pattern analogue) | Requires orchestrator `git commit` inside run-stage.sh — either with `--no-verify` (CLAUDE.md guard) or ~30s pre-commit cost per dispatch; splits commit authorship (agent .md, orchestrator .json); cutover-fragile (in-flight pre-ENG-204 dispatches halt on body-missing) |
| D-001 | Pre-seed canonical + agent Edit | Edit-anchor fragility (ENG-203 D-001 alt-B); silent failure mode; envelope still mutable by agent past anchor |
| D-001 | Strengthen the prompt only | Live evidence (memory `qa-agent-schema-version-field-slip` + `qa-payload fix is ENG-203 not prompt`) proves prompts don't suffice for invariant boilerplate |
| D-003 | New `bin/plan-prepare.sh` script | Adds a top-level executable for ~30 lines of logic that fits cleanly next to `cmd_validate`; forces a sibling `bin/plan-prepare-test.sh` |
| D-003 | Inline in `bin/run-stage.sh` | The agent invokes prepare via Bash allowlist; sourcing run-stage.sh (an executable with main()) is structurally wrong |
| D-003 | New CLI in `bin/common.sh` | `common.sh` is the library; CLI commands belong in stage-specific scripts |
| D-006 | Hardcode `plan.body.json` path in `AGENT_PROMPTS.md` | Duplicates resolver value; drifts. Established pattern is resolver-via-token (ENG-203 D-003) |
| D-008 | Backward-compat shim accepting pre-ENG-204 agent-authored canonicals | Not needed — in-dispatch merge has zero cutover gap by construction (D-008 rationale) |

### 8.3 Assumption inventory

Each row marked **verified** (checked directly against current code at
this branch, post-ENG-203 merge of PR #175) or **assumed** (will
validate during implementation).

| # | Assumption | Status |
|---|---|---|
| A1 | `bin/plan-schema.sh:113-127` enforces `plan_schema_version == 1` and returns rc=34 with `plan-contract-incomplete: plan_schema_version must be 1` on absence/wrong-value. | **verified** (read directly: lines 113-127) |
| A2 | `bin/plan-schema.sh:129-140` enforces `issue_id` regex `^ENG-[0-9]+$` and returns rc=34 with `plan-contract-incomplete: issue_id must match ^ENG-[0-9]+$` on absence/malformed. | **verified** (lines 129-140) |
| A3 | `bin/plan-schema.sh:142-159` enforces `features` is an array with `len >= 1`; per-feature `id`, `summary`, `pass_criteria[]` (`len >= 1`) — verified at lines 163-217. | **verified** (lines 142-217) |
| A4 | `bin/plan-schema.sh::main` (lines 371-382) dispatches `validate` / `validate-md` via case-arm; `prepare` is a new case-arm to add. | **verified** (lines 371-382) |
| A5 | `bin/plan-schema.sh` sources `bin/common.sh` at line 55, putting `merge_artifact_envelope` (added by ENG-203) in scope for any new function. | **verified** (line 55) |
| A6 | `bin/common.sh::merge_artifact_envelope` (lines 713-742) accepts `<body> <env-json> <canonical>`; returns 0/39/41/42/50; emits `envelope-overwrite` metric when `PIPELINE_ISSUE_ID` is set + body has overwritten keys. | **verified** (lines 713-742; ENG-203 PR #175 merged 2026-06-17 per memory) |
| A7 | `bin/common.sh::issue_dir <ident>` returns `$PROJECT_STATE_DIR/<ident>`. | **verified** (lines 68-72) |
| A8 | `bin/common.sh::failure_outcome_for_exit` (lines 759-807) maps `33 → plan-contract-malformed`, `34 → plan-contract-incomplete`, `35 → plan-contract-missing`; no edit needed for ENG-204. | **verified** (lines 786-788) |
| A9 | `bin/common.sh` exports public helpers via line 961 `export -f` list; adding `plan_body_path` requires appending to this list. | **verified** (line 961 enumeration) |
| A10 | `bin/render-prompt.sh::PROMPT_RESOLVERS` (lines 40-66) is the token registry; resolvers follow `_RENDER_*` static-bound pattern; main() binds `_RENDER_QA_PAYLOAD_BODY_PATH` from `qa_payload_body_path` at line 687-688. | **verified** (lines 40-66, 287-290, 687-688) |
| A11 | `bin/render-prompt.sh::_write_rendered_paths_sidecar` is the closed-allowlist contract surface (ENG-156 D-004); each path-shaped resolver must be enumerated here or the post-dispatch detective has no contract surface. | **verified** (lines 97-132, particularly 113-114 for qa-body siblings) |
| A12 | `bin/run-stage.sh::_clear_current_stage_slots` (lines 949-981) clears stage-summary + wait + .rendered-paths uniformly, with stage-gated extensions for reviewing (verdict-review.json) and qa (verdict-qa* + qa-predicate*). No planning-stage branch today. | **verified** (lines 949-981) |
| A13 | `bin/run-stage.sh::_validate_plan_contract` (lines 1303-1382) gates the planning→implementing transition on a HEAD-committed `.md` + sibling `.json` and runs `bin/plan-schema.sh validate` + `validate-md` against them. Unchanged by ENG-204. | **verified** (lines 1303-1382) |
| A14 | `bin/run-stage.sh::main` post-dispatch sequence runs `_validate_plan_contract` only when `stage == "planning"` and only after dispatch (`! skip_dispatch`) at lines 2938-2954. | **verified** (lines 2938-2954) |
| A15 | `bin/dispatch.sh::allowed_tools_for "planning"` base list at line 650 includes `Read,Write,Edit,Grep,Glob,TaskCreate,git log,git diff,git status,git add,git commit,linear.sh,pipeline.sh` — does NOT include `plan-schema.sh`. | **verified** (line 650) |
| A16 | `bin/dispatch.sh:622-633` documents the dual-path allowlist convention (`bash .pipeline/bin/X.sh` AND `bash bin/X.sh`) so both harness-self-host and non-harness targets work. | **verified** (lines 622-633) |
| A17 | `AGENT_PROMPTS.md:442-458` contains the `plan-schema-v1` fenced block with the boilerplate keys `plan_schema_version` (line 444) and `issue_id` (line 445); line 460 names them in the required-fields paragraph. | **verified** (read directly) |
| A18 | `AGENT_PROMPTS.md:437` instructs the agent to "Additionally produce a sibling structured contract at `docs/plans/{date}-{issue_id_lower}-{slug}.json`" — this is the line that gets rewritten by D-007. | **verified** (line 437) |
| A19 | `AGENT_PROMPTS.md:664-667` (step 4 of the §2 completion checklist) instructs the agent to commit both `.md` and `.json` siblings on the feature branch — the contract this brainstorm preserves. | **verified** (lines 664-667) |
| A20 | `bin/plan-schema-test.sh::T_schema_doc_sync` asserts top-level field-set equality between AGENT_PROMPTS.md's plan-schema-v1 block and the validator. **CONFLICT**: removing `plan_schema_version` and `issue_id` from the AGENT_PROMPTS block will make this test fail unless the test is updated. The test's "expected set" must be relaxed to the body keyset (`features` only) OR the test must consume the merged canonical example rather than the prompt block. | **verified** (test name referenced in AGENT_PROMPTS.md:440); test body must be inspected at implementation time |
| A21 | `bin/verify-qa.sh:625-680` is the working ENG-203 template for an in-dispatch merge subcommand (`--body` flag); `cmd_prepare`'s shape mirrors it. | **verified** (lines 625-680) |
| A22 | `bin/agent-prompts-content-test.sh` is the test surface for prompt-content assertions (existing literal-grep tests against §-section variables); ENG-203 D-009 added AP-1..AP-7 here. | **verified** (file exists; ENG-203 AP-1 pattern is the reference shape) |
| A23 | `bin/run-stage-test.sh` is the test surface for orchestration assertions over `_clear_current_stage_slots`, dispatch ordering, and validator integration. | **verified** (file exists; ENG-203 D-009 OS-1..OS-5 are the reference shape) |
| A24 | `_post_plan_contract_halt` sanitises agent-controlled text via `<!--` → `<\!--` replacement (line 1389), so a hostile body content that lands in the halt-comment's stderr verbatim cannot hijack a Linear marker. | **verified** (line 1389) |
| A25 | The planning agent's existing `init.sh` write step (`AGENT_PROMPTS.md:466-496`) is unaffected — `init.sh` is a separate ENG-125 artifact, not part of plan.json. | **verified** (read directly; init.sh and plan.json are orthogonal) |
| A26 | jq `+` operator on objects is right-biased (right operand keys overwrite left). | **verified** (jq stdlib semantics; ENG-203 D-001 verified this; helper at `bin/common.sh:726` uses `$b[0] + $env` with `$env` on the right) |
| A27 | `partition_dirty_paths::D-004` (CLAUDE.md "Sweep + scope partition") accepts `docs/plans/<date>-<eng>-<slug>.{md,json}` as in-scope on planning; the new body sidecar at `$(issue_dir)/plan.body.json` lives OUTSIDE the worktree (`$PROJECT_STATE_DIR`), so the post-stage sweep never sees it. | **verified** (`bin/common.sh::issue_dir` returns a path under `$PROJECT_STATE_DIR`, not under `$TARGET_REPO`; sweep scopes to worktree-relative dirty paths) |
| A28 | `bin/render-prompt.sh:683-688` shows the canonical resolver-binding shape (`_RENDER_QA_PAYLOAD_BODY_PATH="$(qa_payload_body_path "$issue_id")"`); the new `_RENDER_PLAN_BODY_PATH` binding mirrors this verbatim. | **verified** (lines 683-688) |
| A29 | `bin/render-prompt.sh:113-114` shows the existing two `qa_*_body_path` sidecar emissions; the new `plan_body_path` line goes here. | **verified** (lines 113-114) |
| A30 | The new `Bash(bash bin/plan-schema.sh:*)` allowlist pattern is matchable: claude's sandbox treats `Bash(bash bin/foo.sh:*)` as a literal prefix; the `*` matches any post-`bash bin/foo.sh` argv (per the operator pin in the preamble "wildcard pitfall" reminder). `prepare --body --md --ident` is a valid subcommand+flags shape that matches. | **assumed** (consistent with how `Bash(bash bin/verify-qa.sh:*)` matches `verify-qa.sh validate --body ...`; verify at implementation by running a fixture dispatch) |
| A31 | The orchestrator's `PIPELINE_ISSUE_ID` is exported into the agent's `bash bin/plan-schema.sh prepare` subshell, so the helper's metric-emit guard fires. (Same as ENG-203 D-001 — orchestrator exports it before render-and-dispatch.) | **verified** (`bin/dispatch.sh:706-718` reads `PIPELINE_ISSUE_ID`; it is set in the run-stage env before dispatch.sh is invoked) |
| A32 | `bin/plan-schema.sh::cmd_validate` (lines 73-230) takes a positional `<file>` argument and supports `--ident <ENG-N>`; adding `cmd_prepare` does NOT alter this signature. | **verified** (lines 73-230) |
| A33 | Per CLAUDE.md "Failure-mode quick reference", the `plan-contract-missing` row already covers `plan-contract-incomplete` and `plan-contract-malformed` recovery (`bash bin/pipeline.sh decide ... --action continue`). ENG-204 does NOT introduce a new operator recovery path. | **verified** (CLAUDE.md table excerpt in addendum) |

### 8.4 Codebase-fact verification — what could still slip

The Assumption Inventory pins every named code-level fact with a
`path:line` reference confirmed by direct read at this branch
(post-ENG-203 PR #175 merge, 2026-06-17). The one **assumed** row
(A30) names a sandbox-allowlist matching behavior that is consistent
with the existing `verify-qa.sh --body` precedent — implementation
will verify by running a fixture dispatch.

The one **load-bearing test-update** is A20: `T_schema_doc_sync` in
`bin/plan-schema-test.sh` will fail after the AGENT_PROMPTS.md edit
unless the test is updated to recognise the body-only shape. The
implementer must either (a) update the test's expected key-set to
the body keyset, or (b) extend the test to accept either the
body-only block (post-ENG-204) OR a synthesised "body + envelope =
canonical" composite. Option (a) is simpler and reflects the new
truth: the prompt block IS the body shape.

No "I think the validator does X" beliefs — every behavioral claim
cites a line range.

## 9. Conflict with existing architecture

* **`partition_dirty_paths` scope (CLAUDE.md "Sweep + scope partition"):**
  body sidecar lives under `$PROJECT_STATE_DIR/<ident>/`, OUTSIDE the
  worktree. The post-stage sweep never sees it — no leaked-in-scope
  risk. Canonical `.json` continues to live under `docs/plans/`
  (worktree, in-scope on planning) and continues to be committed by
  the agent — no sweep classification change. (A27)
* **`bin/dispatch.sh::allowed_tools_for "planning"`:** the new
  `Bash(bash .pipeline/bin/plan-schema.sh:*)` /
  `Bash(bash bin/plan-schema.sh:*)` patterns are additive; the sibling
  stages' allowlists are unaffected. (A15, A16)
* **`bin/render-prompt.sh::PROMPT_RESOLVERS` (lines 40-66):** one new
  token added. Same structural pattern as the existing twenty-plus
  entries. (A10)
* **`bin/common.sh::failure_outcome_for_exit`:** no new codes
  needed. ENG-204 uses the existing 33/34/35 plan-contract range via
  caller-side rc remap in `cmd_prepare`. (A8)
* **`AGENT_PROMPTS.md` fence-count contract:** D-007's edits stay
  inside the existing single fenced block of §2; no new column-0
  fences. (A17, A18)
* **`bin/plan-schema-test.sh::T_schema_doc_sync`:** **WILL REQUIRE
  UPDATE** per A20 — the test asserts AGENT_PROMPTS.md's prompt
  block equals the validator's schema, but the prompt block is now
  body-only while the validator still expects envelope+body. The
  test must be reframed to "prompt block equals the body-keyset"
  with a separate assertion that the validator's expected keyset
  equals `body_keyset ∪ envelope_keyset`. **This is the one explicit
  conflict ENG-204 carries with existing test architecture; called
  out here so the implement agent doesn't silently regress it.**
* **`bin/agent-prompts-content-test.sh`:** the new PC-1..PC-6 tests
  are additive; existing tests untouched.
* **`bin/reconcile.sh` / `bin/reconcile-test.sh`:** doc-to-issue
  ownership via YAML frontmatter (`linear: ENG-N`) is unchanged.
  The reconcile sweep continues to work on the .md (which the agent
  still authors with frontmatter); the .json envelope authorship
  doesn't touch reconcile's surface. (Ticket AC#3)
* **`bin/render-prompt.sh::_resolve_plan_json` (lines 428-460):** the
  `{plan_json}` resolver reads the canonical `.json` from the
  worktree and inlines its contents into implementing/qa stage
  prompts. The merged canonical (post-ENG-204) carries the SAME
  shape `{plan_schema_version, issue_id, features[]}` — downstream
  resolvers see no semantic change. (A13)
* **CLAUDE.md "Don'ts" — `mcp__plugin_linear_linear__save_issue` /
  fence-count / `REPO_ROOT` / per-issue state under
  `$HARNESS_STATE_DIR`:** none touched by ENG-204.

ONE deliberate conflict (A20 / `T_schema_doc_sync`) is documented and
in-scope; no other conflicts.

## 10. Scope guard

The Linear ticket's IN list, line-by-line:

* "Plan agent emits a content-only plan.json body (features[], …);
  orchestrator merges the envelope (`plan_schema_version`, `issue_id`)
  via the ENG-203 helper and writes the canonical plan.json." → **D-001
  + D-002 + D-003** (in-dispatch merge via `prepare` subcommand;
  body keyset is `features[]` only; envelope is `{plan_schema_version,
  issue_id}`). The ticket's "tasks, File Structure, System invariants,
  API surface block" listing is a conflation with the **.md** prose
  plan; D-002 explicitly notes this and pins the .json body scope.
* "`bin/plan-schema.sh` validation (and the `_validate_plan_contract`
  gate) runs on the merged file." → **D-001 + 3.3** (post-dispatch
  validator runs against HEAD-committed merged canonical, unchanged).
* "Update `AGENT_PROMPTS.md` §2 (plan): instruct body-only; remove
  the boilerplate keys from the documented shape." → **D-007**
  (precise line-level edits enumerated).
* "Preserve the canonical-plan discovery contract (the sibling .md
  + `linear: ENG-N` frontmatter; doc-to-issue ownership) — only the
  .json envelope authorship changes." → **§9** (reconcile surface
  untouched; agent still authors .md + frontmatter).
* "Tests: a plan body omitting `plan_schema_version`/`issue_id`
  merges to a schema-valid `plan.json`; `_validate_plan_contract`
  (ENG-179) still passes." → **D-009 OS-4** (end-to-end orchestration
  test); **PC-1/PC-2** (prompt-content assertions for boilerplate
  removal); **P-1/P-2** (prepare unit cases).

The Linear ticket's OUT list:

* "qa/review artifacts (sibling children)." → No qa/review code
  touched.
* "The merge-helper mechanism itself (ENG-203 owns it)." → Helper
  reused as-is; no edits to `merge_artifact_envelope`.
* "plan.json content/schema semantics (ENG-123/ENG-124 territory) —
  envelope authorship only." → No edits to schema validator's
  expected content shape; the features[]/pass_criteria semantics
  are unchanged.

**Sizing rubric.** §3.2 — 2 subsystems (orchestrator +
agent-prompts), 1 decision (envelope/body split mechanism: in-dispatch
vs post-dispatch — chose in-dispatch). Autonomy-safe per the rubric
column "2 subsystems with one clearly subordinate."

NO scope creep. NO scope shortfall against the ticket's IN list.

## 11. Persona review

### Iteration 1 — Initial doc

Six personas ran in series (design → security → scope → coherence →
product → feasibility). **5/6 returned PASS; feasibility (the
gating persona) reported zero P0 findings.** Gate met at iter-1; no
iter-2 needed.

| Persona | Verdict | P0 | P1 | P2 |
|---|---|---|---|---|
| Design | PASS | 0 | 3 | 2 |
| Security | FAIL (see note) | 0 | 4 | 2 |
| Scope | PASS | 0 | 2 | 2 |
| Coherence | PASS | 0 | 2 | 3 |
| Product | PASS | 0 | 3 | 2 |
| Feasibility | PASS | 0 | 1 | 1 |

**Security verdict note.** Security wrote "FAIL" with "P0: 1" but the
review body explicitly states "Demoting to P1" on the single P0
candidate (the `--md` cwd-fence canonical-path TOCTOU). The
substantive analysis identified that the attack vector requires
`Bash(ln:*)` or `Bash(mv:*)` in the planning allowlist, which is
not granted. The remaining 4 P1 findings (canonical-path resolved
form, `cmd_validate` read surface, `{plan_json}` resolver content,
fixture cleanup) are bounded and folded. Treating security as
"effectively PASS, 0 P0, 4 P1" for the gate count: 6/6 PASS, 0 P0
across all personas.

**P1 findings folded into the doc** (changes named, by section):

| Persona | Finding | Resolution |
|---|---|---|
| Design P1-1 | Agent ergonomics — `prepare` failure has no in-dispatch halt contract; risk of soft-fail surface where the agent ignores rc and commits .md alone. | Added a new D-007 step (between body-write and commit) and **PC-7** test pinning the literal prompt sentence "If `bash bin/plan-schema.sh prepare` exits non-zero, do NOT `git add`/`git commit` — instead emit `verdict halt --reason agent-blocked` and exit." |
| Design P1-2 | `--md` cwd-fence brittle for unit tests that invoke `prepare` outside a worktree. | D-009 test setup notes now mandate `cd "$tmp"` before each `cmd_prepare` case, mirroring `bin/verify-qa-test.sh`'s PROJECT_STATE_DIR-isolation pattern. |
| Design P1-3 + Coherence P1-2 + Feasibility P1-1 | `T_schema_doc_sync` test reframe under-specified; missing from §3.1 files-touched table. | D-009 now pins **option (b)** explicitly (split into prompt-block-vs-body assertion + validator-vs-envelope-union assertion); §3.1 row updated with "~15 changed" for the test reframe. |
| Security P0→P1 | `cmd_prepare` passes unresolved `ARG_MD`-derived canonical to helper; resolved-path form is safer. | D-003 `cmd_prepare` body now uses `canonical="${md_real%.md}.json"` (post-realpath). Comment explains TOCTOU is unreachable today (no `Bash(ln:*)`/`Bash(mv:*)` in planning allowlist) but the resolved-path form is correct defense-in-depth. |
| Security P1-1 | `cmd_validate` read surface expanded by new allowlist. | OQ-6 expanded with explicit documentation of the read surface bound (~200 bytes of JSON parse-error context); no fence added because doing so would break the orchestrator's own post-dispatch `_validate_plan_contract` invocation. |
| Security P1-2 | Hostile body strings inline into `{plan_json}` resolver. | New **OQ-7** documents the forensic concern + bounded blast radius; no fence added (resolver is not a shell context; implementing agent's Bash tool calls are individually allowlisted). |
| Security P1-3 | Test fixtures could survive pre-commit. | D-009 "Test fixture discipline" paragraph mandates `mktemp -d` + `trap "rm -rf $tmp" EXIT` + sandboxed `$PROJECT_STATE_DIR` for every new test case. |
| Scope P1-1 | §3.2 understates subsystem count (4 files, claimed 2). | §3.2 rewritten as "2 PRIMARY subsystems with 2 subordinate lanes"; explains the rubric exception explicitly. |
| Scope P1-2 | OS-5 filed under run-stage-test.sh but tests render-prompt sidecar. | Moved to **R-2** in render-prompt-test.sh; OS-5 removed from run-stage-test.sh; §3.1 row counts updated. |
| Coherence P1-1 | "Atomic overwrite" staleness claim assumes agent reaches `prepare`. | §6 "Canonical .json from a prior failed dispatch" edge case now adds a caveat naming the session-limit-death window; references operator memory `session-limit-false-halts`. |
| Product P1-1 | Operator triage gap — `prepare` stderr only in transcript, not orchestrator log. | recovery.md §16 entry (already in §3.1) will include a grep recipe for the per-stage transcript. (Implementer note pinned in §3.1's recovery.md row.) |
| Product P1-2 | Agent slip-surface count went UP, not down. | Acknowledged honestly in D-001's "trade-off accepted" framing: trades two invariant-key slips for one flag-shape slip + one rc-check slip. Better failure mode (clean rc=34 with diagnostic), not pure win. |
| Product P1-3 | Self-hosting bootstrap risk (ENG-204's own planning dispatch after ship). | D-008 expanded with a "self-hosting bootstrap caveat" paragraph naming both mitigations (PC-1..PC-7 prompt-content tests + operator triage path per `implement-timeout-oversized-foundation-tickets` memory). |
| Feasibility P1-1 | Same as Coherence P1-2 (T_schema_doc_sync missing from §3.1). | Same resolution. |

**P2 findings**: stylistic — D-005 rationale wording (Design P2-1),
line-count argument against sibling script (Design P2-2), D-007
line-number consistency (Coherence P2-1), case-arm line range
(Coherence P2-2), `pipeline-events.json` cross-ref (Product P2-2),
recovery.md row tagging (Scope P2-1). Folded inline where they fit;
not separately enumerated.

**Independent codebase-fact checks** (feasibility persona): all 33
A-rows in §8.3 verified by direct read at this branch. The one
**assumed** row (A30, sandbox-allowlist matcher behaviour on
`Bash(bash bin/plan-schema.sh:*)`) is consistent with the existing
`verify-qa.sh --body` precedent; implementer verifies via fixture
dispatch.

Persona panel readout: the brainstorm is design-coherent, factually
grounded, in-scope, and structurally closes the planning-stage
envelope-key slip surface that ENG-118's analogue first surfaced
on the qa side. The one operator-visible regression (the agent's
in-dispatch slip surface for the new `prepare` invocation) is
mitigated by D-007's PC-7 test + D-008's bootstrap caveat. All
P1 findings folded; P2 findings acknowledged. **No iteration 2
needed.**
