---
linear: ENG-155
title: dispatch.sh — thread --add-dir to allow agent writes outside worktree cwd
date: 2026-05-19
status: draft
---

# dispatch.sh — thread `--add-dir "$issue_state_dir"` so agents can write progress.md / stage-summary outside the worktree cwd

## 1. Overview (and the load-bearing surprise)

Six prior progress.md fixes (ENG-106 / 108 / 109 / 144 / 146 plus
`_ensure_progress_md` pre-touch at `bin/run-stage.sh:1332`) shared an
unstated assumption: that the agent's tool universe could *reach*
`$(issue_dir <ident>)` — a path that lives under
`$PROJECT_STATE_DIR/<ident>/`, completely outside the per-issue worktree
the agent is `cd`'d into (`bin/run-local.sh:205`,
`(cd "$dispatch_cwd" && bash run-stage.sh …)`).

That assumption silently broke when the claude CLI tightened its
per-session directory sandbox to restrict tool access to the working
directory unless `--add-dir` is passed. ENG-125 (planning, 2026-05-18)
was the first hard halt of the class — the agent gave up rather than
attempt writes that the sandbox would deny. Quieter forms of the same
denial had been visible in failed-dispatch transcripts for weeks
(claude 2.1.142 1×, 2.1.143 1–2×, 2.1.144 2× per the Linear issue body)
and only converged to a deterministic failure once the sandbox tightened
enough to reject the write outright before any retry could succeed.

**The surprise:** the harness has *one* knob that fixes the entire
class — `claude --add-dir <path>` widens the per-session sandbox to
include additional directories. It is already documented and shipping
in the same CLI version that broke us (`claude --help` lists
`--add-dir <directories...>  Additional directories to allow tool access
to`). The brainstorm exists not because the fix is unclear but because
the *blast radius* of widening the sandbox is — once
`$(issue_dir <ident>)` is writable, the agent can also stomp on
orchestrator-owned files in that directory (`issue-state.json`,
`dispatch_history.jsonl`, every `wait-*.json` and `usage-*.json`). The
detective-side defense (§4.3) is the part that needs careful design.

## 2. Forensic ground truth — ENG-125, 2026-05-18

The Linear issue body (ticket Context section) cites the failed
planning dispatch on ENG-125 halting with rc=31
(`progress-md-entry-missing`) and tags the agent transcript as showing
denied writes. The orchestrator side of that incident is mechanical:

1. `bin/run-stage.sh:1329` runs `mkdir -p "$(issue_dir "$ident")"` —
   the parent dir IS created.
2. `bin/run-stage.sh:1332` runs `_ensure_progress_md "$ident"` —
   `progress.md` IS touched.
3. `bin/run-stage.sh:1470` exports `PIPELINE_ISSUE_ID="$ident"` and
   invokes `bin/dispatch.sh`. The dispatch's child CWD is the
   per-issue worktree (set by the `cd "$dispatch_cwd"` wrap at
   `bin/run-local.sh:205`).
4. `bin/dispatch.sh:521-527` resolves `issue_state_dir="$(issue_dir
   "$PIPELINE_ISSUE_ID")"` — the directory the agent needs to write
   under but cannot reach.
5. `bin/dispatch.sh:645-670` constructs the `claude -p` argv with
   `--setting-sources project,local --disable-slash-commands
   --disallowed-tools "$denies" --allowed-tools "$tools"` and NO
   `--add-dir`. The sandbox closes around the worktree only.
6. The agent's `Edit`/`Write` tool calls against
   `/Users/.../state/twinning-harness/<slug>/<ident>/progress.md` are
   denied; the agent emits a halt verdict; the post-dispatch
   `_assert_progress_md_entry` detective (`bin/dispatch.sh:300-318`)
   independently confirms a missing entry and returns rc=31.

`bin/dispatch.sh:80`'s `mkdir -p "$issue_dir"` inside
`_render_and_capture_stream` does fire — but that runs **after** the
agent process exits (it is the renderer reading the captured stream),
so it has never been load-bearing for the agent's own writes during
dispatch.

## 3. Scope (and what the ticket explicitly carves out)

**IN** (from the Linear ticket Scope section, lightly reordered):

- `bin/dispatch.sh` argv: append `--add-dir "$issue_state_dir"` before
  `--setting-sources project,local`.
- Idempotent `mkdir -p "$issue_state_dir"` immediately before the
  `claude -p` invocation. (Today's pre-dispatch mkdir at
  `bin/run-stage.sh:1329` is upstream of dispatch.sh and runs only when
  dispatch is invoked through run-stage.sh; dispatch.sh has other
  callers — release / retrospective / mutex-test / dry-run-self-check —
  with `PIPELINE_ISSUE_ID` unset, but the per-issue gate at
  `bin/dispatch.sh:521` short-circuits them; the mkdir lives inside the
  same gate.)
- Post-dispatch transcript detective forbidding agent `Write` /
  `Edit` against orchestrator-owned files inside `$issue_state_dir`:
  `issue-state.json`, `dispatch_history.jsonl`, `wait-*.json`,
  `usage-*.json`, plus the dot-prefixed dispatch sidecars
  (`.raw-stream.ndjson.tmp`, `.cmd-capture-*`,
  `.envelope-transcript-*`, `.transcript-violation-*`).
- `Bash(git add:*)` audit across `planning | implementing | ui | qa`
  arms of `bin/dispatch.sh::allowed_tools_for` — verify presence in
  each and add to the one that lacks it.
- AGENT_PROMPTS.md guidance update for the auto-mode bash classifier
  pitfall: one path per `git add` invocation, no `&&` chaining of
  multi-path stages.

**OUT** (also from the ticket):

- Surfacing sandbox denials as a first-class signal (separate
  ticket — would require either a transcript-side detective for the
  CLI's "denied" event shape or a `--debug` stream wiring change).
- Pinning the claude CLI version (separate ticket — supply-chain
  axis, different operator).

**Flagged additions caught during brainstorm — surfaced, not silently
expanded** (see §5 Open Questions for the decision):

- Whether to also pass `--add-dir "$HARNESS_ROOT/learned-rules"`
  ("arguably" per the ticket; tentatively rejected — see §4.2).
- Whether the planning stage's prompt directive to commit (AGENT_PROMPTS.md
  §2 step 4, line 625) is consistent with planning's allowlist
  (today's planning base lacks `Bash(git add:*)` AND
  `Bash(git commit:*)` — so committing has never been possible from
  the agent side; the orchestrator's tick-end sweep is what actually
  commits the plan doc). This is a separate, latent prompt-vs-allowlist
  mismatch (call it OQ-2) — flagged here, NOT fixed in this ticket.

## 4. Decisions

### D-001 — Pass `--add-dir "$issue_state_dir"` from dispatch.sh, gated on `PIPELINE_ISSUE_ID`

**Decision.** In `bin/dispatch.sh::main`, inside the existing
`[[ -n "${PIPELINE_ISSUE_ID:-}" ]]` block (lines 521-527, which also
gates the per-issue usage-file and capture-file resolution), append two
argv elements to `cmd[]`: `--add-dir "$issue_state_dir"`, splicing
them BETWEEN the `gtimeout … claude -p --output-format stream-json
--verbose [--model …]` prefix and the existing `--setting-sources
project,local` flag. Composition order:

```
env PIPELINE_WRITER=agent … [gtime -v -o …] gtimeout … claude -p
  --output-format stream-json --verbose
  [--model "$PIPELINE_DISPATCH_MODEL"]
  --add-dir "$issue_state_dir"         ← NEW (this ticket)
  --setting-sources project,local
  --disable-slash-commands
  --disallowed-tools "$denies"
  --allowed-tools "$tools"
```

**Why.** Architecture principle: the orchestrator already treats
`$(issue_dir <ident>)` as the agent's per-issue scratch + handoff slot
(progress.md, stage-summary-*.md). Without the flag, that contract is
unbacked by the sandbox; with the flag, the contract is enforced
end-to-end. The gate on `PIPELINE_ISSUE_ID` mirrors `usage_file` /
`_capture_path` (`bin/dispatch.sh:521-527`, `:682-687`) — release /
retrospective / mutex-test / dry-run-self-check callers leave the env
unset and observe zero behavior change.

**Why the position matters.** Claude's argv parser is order-insensitive
for flag matching, but the rendered argv shows up in
`$PROJECT_STATE_DIR/<slug>/logs/local-*.log` (the DRY_RUN log at
`bin/dispatch.sh:603`) and the operator scans for these flags by eye.
Placing `--add-dir` between the `claude -p` arg block and the isolation
flag block keeps the isolation block visually contiguous (the
brainstorm reviewer's mental grouping is "isolation block: setting-
sources + disable-slash-commands + disallowed-tools + allowed-tools";
adding `--add-dir` to the middle of that block hides its purpose).

**Architectural constraint touched.** This puts pressure on the
ENG-48 isolation flags' implicit invariant: pre-ENG-155, the only
writable surface in a dispatch was the per-issue worktree, and the
sandbox enforced that. Post-ENG-155, the agent's tool universe spans
two disjoint directory trees. D-003 below restores the invariant for
the orchestrator-owned subset.

**Rejected alternative.** *Move the directory widening into a per-stage
prompt body* (have each agent prompt run a startup `bash -c 'cd
'<issue_state_dir>'; export …'`-style ritual). Rejected because the
sandbox is a CLI-side enforcement, not a shell-level one — no amount of
prompt-time ceremony lets the agent's `Write` tool reach a directory
the CLI sandbox blocks. The fix has to land at argv time.

### D-002 — Tentatively reject `--add-dir "$HARNESS_ROOT/learned-rules"`

**Decision.** Do NOT add `--add-dir "$HARNESS_ROOT/learned-rules"` as
part of this ticket.

**Why.** The project profile + per-stage learned rules are already
inlined into every dispatched prompt by
`bin/render-prompt.sh::append_project_profile`
(`bin/render-prompt.sh:188-214`, reads
`$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md` and
appends to stdin). The agent never needs to `Read` these files
directly — every byte the agent cares about is already in the rendered
prompt the agent receives on stdin. Granting read-only access to
`learned-rules/` would let the agent inspect *other slugs'* profiles,
which is cross-target information leakage with no documented use case.

**Why "tentatively".** If a future agent needs to grep ALL of the
per-stage learned-rule files (e.g., a meta-retrospective that
cross-references rules across stages from within a non-retrospective
dispatch), the right answer is to inline those into the prompt at
render time too — not to widen the sandbox. This rejection should be
revisited only if a concrete agent task demands it; the brainstorm
flags it OQ-1 below.

**Rejected alternative considered.** *Pass `--add-dir
"$HARNESS_ROOT/learned-rules/$PROJECT_SLUG"` (slug-scoped)* —
narrower than the umbrella `learned-rules/` carve-out, but still
unnecessary given the prompt-side inline. Rejected for the same
reason — no demonstrated agent need; the inline path is
authoritative.

### D-003 — Sibling-of-`_assert_progress_md_entry` filesystem detective for orchestrator-owned files

**Decision.** Add a new transcript-scan detective that runs inside
`_render_and_capture_stream` (`bin/dispatch.sh:70-293`) on the agent's
NDJSON transcript and halts the dispatch if the transcript shows the
agent invoking `Write` or `Edit` against any of the
orchestrator-owned files inside `$issue_state_dir`. Reuses the existing
`assert_no_write_to_path` helper from `bin/common.sh:240-257`
(endswith-on-`file_path` semantics — sufficient because the path
suffixes uniquely identify the orchestrator's slot files), and adds a
sibling `assert_no_edit_to_path` if Edit is not already covered (per
`bin/common.sh:240-257`, the helper matches only `tool_use.name ==
"Write"` today; the new helper needs to match `Edit` as well, or
`assert_no_write_to_path` can be parameterised on the tool name —
see §4.4).

Forbidden suffixes (each checked independently so the violation
message names the specific file the agent tried to clobber):

| Suffix | Owner | Why forbidden |
|---|---|---|
| `/issue-state.json` | `bin/run-stage.sh::allocate_dispatch_id` + `classify-failure.sh` | Agent overwrite drops `current_dispatch_seq` → next dispatch collides on dispatch_id (ENG-146 class) |
| `/dispatch_history.jsonl` | `bin/run-stage.sh:1356,1234` | Agent rewrite breaks forensic append-only invariant |
| `/wait-*.json` | `bin/run-stage.sh::_handle_wait` | Agent overwrite resets `external_signal_budget` and lets the agent self-loop |
| `/usage-*.json` | `bin/dispatch.sh::_render_and_capture_stream` (extract + write at lines 110-125) | Agent rewrite biases cost telemetry; SEC-002 ALLOWlist-by-construction means it MUST contain only six fields |
| `/.raw-stream.ndjson.tmp` | `bin/dispatch.sh:72` | Agent forge bytes into the very NDJSON the post-stream detectives scan |
| `/.cmd-capture-*.ndjson.tmp` | `bin/dispatch.sh:683` | Same — forges the capture file the renderer reads |
| `/.envelope-transcript-*` | `bin/dispatch.sh:77,165-167` | Same — the post-dispatch envelope-validator reads this |
| `/.transcript-violation-*` | `bin/dispatch.sh:73,178,...` | Agent fabricates a clean violation file to confuse `verdict-handler.sh` |
| `/.allocate.lock/` | `bin/common.sh:118` | Agent forges a lock-holder pid to deadlock the allocator |

On match: write the matched `file_path` to `${issue_dir}/.transcript-
violation-${stage}` (the existing sidecar shape used for rc=22/26/29/
31), log `[assert] stage=$stage transcript invoked forbidden Write/
Edit on orchestrator-owned path: <matched>`, and return a new exit
code (see D-004).

**Why this is the structural defense.** D-001 widens the agent's
tool reach beyond the worktree to include `$(issue_dir <ident>)`.
The orchestrator-owned files in that directory are the substrate for
six existing structural invariants — dispatch_id monotonicity (ENG-87,
ENG-146), forensic history (ENG-87), wait-budget bounding (ENG-45),
cost telemetry (ENG-26), the dispatch envelope (ENG-87), and the
allocator lock (ENG-146). Each of these has its own detective
catching a different failure mode; D-003 is what stops an
agent-side regression from re-introducing them all silently. The
transcript-scan idiom mirrors how `bin/dispatch.sh:174-181,196-207,
217-230,244-258,269-276,288-292` already enforce eight other
per-stage prohibitions, so the operational surface (sidecar shape, log
shape, rc-based halt) is unchanged.

**Why filesystem detective is rejected.** A filesystem detective
(checksum the files before/after dispatch and halt on mismatch) was
considered. Rejected because:

- The orchestrator legitimately writes these files DURING dispatch
  (the allocator writes `issue-state.json`'s `current_dispatch_seq`
  before invoking dispatch.sh; `_handle_wait` writes `wait-*.json`
  AFTER dispatch on the wait path). Distinguishing "agent wrote this"
  from "orchestrator wrote this" without a transcript scan requires
  yet another snapshot layer.
- The transcript scan is testable in isolation
  (`bin/dispatch-test.sh` already pins similar shapes for
  `gh pr create`, branch creation, `core.bare`); a filesystem
  detective would need a more complex fixture (pre-snapshot,
  agent-run-stub, post-snapshot diff).

**Rejected alternative — rely on the auto-mode bash classifier**
to deny the writes. The classifier already rejects `git add A B`
multi-path (per the ticket body); it does not gate `Write` /
`Edit` tool calls based on file path — those are claude tool-permission
mechanics, not bash classifier mechanics. So the classifier is the
wrong layer.

### D-004 — Exit-code allocation for the new detective

**Decision.** Reuse rc=29 (`envelope-violation`,
`failure_outcome_for_exit` at `bin/common.sh:297`), the same code
ENG-87's envelope detective and ENG-109's progress.md Write detective
already use. The brainstorm reading is "the agent's tool-use envelope
includes its directory-write scope; an orchestrator-owned file write
is an envelope violation by D-003's design."

**Why reuse rc=29 vs allocating a new code.** Three reasons:

1. Operator triage path is identical: `recovery.md`-style steps for
   rc=29 (inspect `.transcript-violation-${stage}`, decide whether to
   resume with `--action continue` or amend the prompt) apply unchanged
   to D-003 violations.
2. `bin/common.sh::failure_outcome_for_exit` doesn't need a new arm
   (the table already routes rc=29 → `envelope-violation`), and
   `bin/classify-failure.sh` doesn't need a new case.
3. The retrospective's §1 filter recognises `envelope-violation`
   already; adding a fourth distinct shape under that umbrella
   doesn't dilute the classification (operators reading the
   sidecar still see which specific surface tripped).

**Rejected alternative.** *Allocate rc=32 `agent-wrote-orchestrator-
file`*. Rejected because (a) the failure_outcome_for_exit table is the
SoT — adding a code there requires a coordinated CLAUDE.md +
retrospective filter + operator-mental-model update for marginal
signal; (b) the sidecar already names the matched path, so the
operator gets the precise diagnosis on triage without a separate
exit code.

### D-005 — Defer `Bash(git add:*)` addition to planning unless the prompt is fixed first

**Decision.** Verify presence across the four stages the ticket
names; ADD only where missing AND where the stage prompt actually
exercises `git add`.

Current state (verified at `bin/dispatch.sh`):

| Stage | Has `Bash(git add:*)`? | Prompt uses git add? |
|---|---|---|
| `planning` (line 478) | NO | The prompt step 4 says "Commit artifacts" but planning ALSO lacks `Bash(git commit:*)` — the prompt directive has always been orchestrator-fulfilled |
| `implementing` (line 479) | YES | YES (commits feature work) |
| `ui` (line 480) | YES | YES (commits frontend work) |
| `qa` (line 482) | YES (via `Bash(git:*)` wildcard) | YES |

The ticket says "if not already present." For planning, the answer
is: NOT present, but the matching `git commit` is also not present, so
adding only `git add` creates an inconsistent half-allowance that
invites a future agent to stage-without-committing. The brainstorm
recommends: do NOT add `Bash(git add:*)` to planning in this ticket;
file a sibling ticket to make planning's commit lane consistent
(either grant both `git add` + `git commit` after auditing the
orchestrator's post-stage sweep for double-commit risk, or rewrite
the planning prompt to drop the misleading "Commit artifacts" step).

For `implementing | ui | qa`: NO changes — the ticket's "if not
already present" pre-condition is already false.

**Why.** Granting partial commit privileges is an LSP violation
that an agent following the prompt literally will trip over. The
manifest-vs-prompt mismatch is the actual bug; the ticket framed it
as "add the missing entry," but the deeper structural fix is
"make the manifest agree with the prompt or vice versa." Surfacing
this in a sibling ticket (call it OQ-2 below) keeps ENG-155 minimal
while preserving the audit trail.

**Rejected alternative.** *Add `Bash(git add:*)` to planning anyway
(strict-ticket-fulfilment reading)*. Rejected because it locks in
half a transition without addressing the consistency problem, and
the planning agent has been running without it since the per-stage
allowlist was first centralised — there is no demonstrated incident
of planning failing for lack of `git add` (the orchestrator's
sweep at `bin/run-local.sh:308` has been doing the commit). Adding it
preemptively widens the agent's blast radius for zero observed
benefit and one observed coupling risk.

### D-006 — Prompt-side guidance: one path per `git add`, no `&&` chaining

**Decision.** Update AGENT_PROMPTS.md sections 3 (Implement) and 4
(UI) — the two stages that actually exercise `git add` per the
prompt — to add a one-line directive under the existing "Commit
artifacts" step:

> When staging files, prefer one path per `git add` invocation; do
> NOT chain with `&&` or pass multiple paths. The auto-mode bash
> classifier may reject multi-path or chained-command shapes even
> when the allowlist would permit them; one path per call is the
> shape that reliably gets through.

Apply to QA only if QA's prompt explicitly stages (its allowlist
admits it via `Bash(git:*)`, but the prompt may or may not exercise
that path — verify at implementation time and add if so).

**Why.** The ticket Context section reports the auto-mode classifier
rejecting `git add A B` even with the allowlist permitting it. This
is the same class of pitfall already documented in CLAUDE.md's tool
allowlist & probing block for `add-or-update-comment` sig variants
(idempotent vs sig-mutate): a prompt-side discipline rule is the
cheapest defense, and the documented evidence (CLAUDE.md's existing
ENG-53/55 preamble) is precedent for this style of guidance.

**Why NOT a transcript-scan detective for the chained shape.** The
chained-shape rejection is a classifier-side denial — the
transcript doesn't carry the denial event in a shape the
`assert_no_tool_invocation` helper currently parses (the denial is
the absence of a tool-use record, not the presence of one). Building
a "missing-tool-use" detective is out of scope and probably the
wrong shape anyway (false-positives whenever an agent legitimately
chooses not to stage).

## 5. Open questions (acknowledged, not blocking)

- **OQ-1:** Should `--add-dir` accept a per-stage tuple instead of
  one path? Today the brainstorm proposes a single path. A future
  stage (e.g., a metrics-export stage) might need access to
  `$PROJECT_STATE_DIR/metrics/` too. Defer: the array-flag shape is
  already supported by claude (`--add-dir <directories...>` per
  `claude --help`), so widening later is purely an argv-construction
  change. No schema/contract redesign needed.
- **OQ-2:** (Spawned from D-005.) File a sibling ticket to reconcile
  planning's prompt directive ("Commit artifacts") with planning's
  allowlist (lacks `git add` + `git commit`). Either grant the full
  commit lane to the agent and remove the orchestrator's
  planning-stage post-sweep commit, or rewrite the prompt to make the
  orchestrator's role explicit. Out of scope for ENG-155.
- **OQ-3:** Should the D-003 transcript detective be gated on a per-
  stage basis? Today the brainstorm proposes "all stages," reasoning
  that no legitimate agent flow writes to orchestrator-owned files
  regardless of stage. Risk: a future stage with a legitimate write
  (a hypothetical "telemetry" stage that needs to amend
  `usage-*.json`) would have to add its own carve-out. Defer; current
  agent fleet has no such case.
- **OQ-4:** Should the `--add-dir` value path be log-redacted?
  `$issue_state_dir` carries the issue id (`ENG-155`) which is not
  secret, but is operator-identifying for cross-org log sharing. The
  rest of dispatch.sh's logs already carry it verbatim
  (`bin/dispatch.sh:603`, `:693-696`), so redacting here would be
  inconsistent. Defer to a future secret-handling sweep.
- **OQ-5:** The startswith / endswith primitives in
  `assert_no_tool_invocation` / `assert_no_write_to_path` are
  bypassable by an agent that uses an absolute path with extra
  trailing characters (e.g., writing to
  `/Users/.../issue-state.json.bak`) or path-traversal
  (`.../issue-state.json/../something`). The current ENG-87
  envelope detectives accept this gap; D-003 inherits it.
  Tightening to anchored exact-match against
  `$issue_state_dir/<basename>` (compute the full path string at
  detective time) is plausible. Defer to follow-up; flag as the
  first hardening pass if any agent ever attempts the bypass.
- **OQ-6:** D-003 shape — enumerated forbidden-suffix deny list
  (today's plan) vs **agent-writable allowlist** (whitelist
  `progress.md` + `stage-summary-*.md` plus the dispatch sidecars
  the orchestrator owns; deny everything else under
  `$issue_state_dir`). The allowlist shape ages better as new
  orchestrator-owned files land — no detective-list edit needed.
  Plan doc to pick at task-decomposition time; surface the call
  in the persona-review there.
- **OQ-7:** New helper signature — sibling `assert_no_edit_to_path`
  vs parameterised `assert_no_tool_with_input_path
  <transcript> <tool_name> <input_field> <suffix>` (or
  tool-name-list variant). Parameterised form is cleaner but
  changes an existing helper signature; sibling form is purely
  additive. Plan doc to pick.
- **OQ-8:** Subcode taxonomy under `envelope-violation` (rc=29) —
  today four distinct detectives all halt with the same
  classification (`envelope-violation`). Retrospective §1
  aggregator cannot distinguish them. Subcodes
  (`envelope-violation:write-progress`,
  `envelope-violation:orch-file`, etc.) would tighten the
  classification but require a coordinated
  `failure_outcome_for_exit` + retrospective filter +
  `bin/classify-failure.sh` change. Defer; flag for the next
  retrospective scope sweep.
- **OQ-9:** Docs-debt sweep — `docs/architecture.md` §"Failure
  taxonomy" table stops at rc=26 (omits rc=29 / rc=31); the
  failure-mode quick-reference table in CLAUDE.md should also gain
  a row for the new D-003 trip surface;
  `bin/render-prompt.sh:206-208`'s `schema_version: 1` warning is
  stale relative to the v2 profile schema (CLAUDE.md). All
  pre-existing; bundle into one docs-debt ticket post-ENG-155.

## 6. Architecture (where code goes)

| Change | File | Approximate location |
|---|---|---|
| D-001 — `--add-dir "$issue_state_dir"` splice + idempotent `mkdir -p` | `bin/dispatch.sh::main` | Inside the `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]` block at lines 521-527 (mkdir) and inside the `cmd+=(…)` composition at lines 665-670 (splice between `--verbose` / optional `--model` and `--setting-sources`) |
| D-003 — new transcript-scan detective | `bin/dispatch.sh::_render_and_capture_stream` | After the existing ENG-109 progress.md Write detective at lines 269-276; before the planning-stage ENG-106 filesystem detective at 288-292. Follow the **ENG-109 shape** (no `-n "$last_result"` guard — fires on any transcript match) NOT the ENG-106 shape (M2 SIGTERM-race guard is for filesystem checks only). Loop over the orchestrator-owned slot list; per match, write the matched path to `.transcript-violation-<stage>` and return rc=29 |
| D-003 — helper signature | `bin/common.sh` | **Preferred (per design persona):** parameterise — `assert_no_tool_with_input_path <transcript> <tool_name> <input_field> <suffix>`; the existing `assert_no_write_to_path` becomes a thin wrapper. **Fallback:** sibling `assert_no_edit_to_path` after `assert_no_write_to_path` at line 257. Plan doc picks; tracked as OQ-7 |
| D-005 — `Bash(git add:*)` audit | `bin/dispatch.sh::allowed_tools_for` | Lines 478-482; NO code change for `implementing | ui | qa` (already present); planning deferred per OQ-2 |
| D-006 — prompt guidance | `AGENT_PROMPTS.md` | §3 Implement (line 690) and §4 UI (line 957) — under the existing "Commit artifacts" step |
| Tests — argv contains `--add-dir "$issue_state_dir"` | `bin/dispatch-test.sh` | New Group at end of file; reuse the ARGV_CAPTURE infrastructure already proven for Group 4 (lines 187-230) |
| Tests — `Bash(git add:*)` audit | `bin/dispatch-test.sh` | Extend Group 1 (lines 80-110) with one assertion per stage |
| Tests — D-003 detective tripping | `bin/dispatch-test.sh` | New Group at end of file; mirror the ENG-109 progress.md Write test shape — synthesise a transcript JSONL with a `Write` tool_use against `/issue-state.json`, source dispatch.sh, call `_render_and_capture_stream` directly, assert rc=29 and sidecar content |
| Tests — D-001 DRY_RUN log line carries `--add-dir` | `bin/dispatch-test.sh` | Extend the DRY_RUN fixture (line ~593-603 of dispatch.sh emits the would-be cmd line) so the test asserts the rendered cmd string contains `--add-dir <path>` between `--verbose` and `--setting-sources` |
| Docs — failure-mode quick-reference row | `CLAUDE.md` "Failure-mode quick reference" table | New row: "Issue halts at rc=29 with sidecar `.transcript-violation-<stage>` whose body names a path under `$issue_state_dir` (`/issue-state.json`, `/wait-*.json`, `/dispatch_history.jsonl`, etc.) → agent attempted forbidden write to orchestrator-owned file (D-003, ENG-155). Recovery: `bash bin/pipeline.sh decide <ENG-N> --action continue`." |
| Follow-up Linear ticket (OQ-2) | (file pre-merge) | Reconcile planning's prompt directive "Commit artifacts" (AGENT_PROMPTS.md:625) with planning's allowlist (lacks `git add` + `git commit`). |
| Follow-up Linear ticket (OQ-9, docs debt) | (file post-merge) | Update `docs/architecture.md` §"Failure taxonomy" table (extend past rc=26 to cover rc=29 / rc=31); update `bin/render-prompt.sh:206-208` schema_version warning (1 → 2). |

No new files. No new exit code (D-004 reuses 29). No `failure_outcome_
for_exit` arm. No `learned-rules/` change.

## 7. Data flow (one dispatch, post-ENG-155)

```
run-stage.sh (1329) mkdir -p $(issue_dir $ident)
run-stage.sh (1332) _ensure_progress_md  →  touch progress.md
run-stage.sh (1344) allocate_dispatch_id  →  writes issue-state.json
run-stage.sh (1352) _clear_current_stage_slots  →  rm stage-summary-<stage>.md, wait-<stage>.json
run-stage.sh (1356-94) append dispatch-start row to dispatch_history.jsonl
run-stage.sh (1470) bash dispatch.sh  (PIPELINE_ISSUE_ID=$ident, cwd=worktree)
  dispatch.sh (522) issue_state_dir=$(issue_dir $PIPELINE_ISSUE_ID)
  dispatch.sh (NEW) mkdir -p $issue_state_dir                     ← D-001 idempotent
  dispatch.sh (646-70) cmd=(env … gtimeout … claude -p …
                            --add-dir $issue_state_dir            ← D-001 splice
                            --setting-sources project,local
                            --disable-slash-commands
                            --disallowed-tools $denies
                            --allowed-tools $tools)
  dispatch.sh (698-700) ( exec perl setsid → cmd ) > $_capture_path &
  dispatch.sh (705) wait → captured ndjson stream
  dispatch.sh (715-20) _render_and_capture_stream $_capture_path …
    [agent's Write/Edit tool calls now reach $issue_state_dir]
    [agent appends to progress.md and writes stage-summary-<stage>.md inside $issue_state_dir]
  _render_and_capture_stream (165-67) cp $raw_capture → .envelope-transcript-<stage>
  _render_and_capture_stream (173-292) existing detectives run …
  _render_and_capture_stream (NEW after 276) D-003 loop over forbidden-suffix list:
    for path in /issue-state.json /dispatch_history.jsonl /wait-*.json /usage-*.json \
                /.raw-stream.ndjson.tmp /.cmd-capture-* /.envelope-transcript-* \
                /.transcript-violation-* /.allocate.lock; do
      if assert_no_write_to_path $raw_capture $path; matches → write violation, return 29
      if assert_no_edit_to_path  $raw_capture $path; matches → write violation, return 29
    done
run-stage.sh (1545) _validate_dispatch_envelope  ← unchanged
run-stage.sh (1734) _dispatch_made_new_commits  ← unchanged
run-local.sh (308) git add `in_scope_paths`  ← orchestrator commits as before
```

**ENG-125 unhalt path (AC #2).** After the operator runs
`bash bin/pipeline.sh decide ENG-125 --action continue`:

```
pipeline.sh decide → clears pipeline:halted, skip-until-* labels,
                      wait-planning.json, .consecutive-failures;
                      drains issue-state.json (preserves seq+id+stage
                      via _pipeline_drain_issue_state, ENG-146 fix).
next tick → run-stage.sh ENG-125 planning
  → mkdir -p $(issue_dir ENG-125)                 (already a no-op)
  → _ensure_progress_md ENG-125                   (file already present)
  → allocate_dispatch_id ENG-125 → ENG-125-d000N+1 (next seq, ENG-146)
  → _clear_current_stage_slots ENG-125 planning
       → rm stage-summary-planning.md             (stale ENG-125 halt artifact)
       → rm wait-planning.json
  → dispatch.sh planning
       → pre-clean: rm $issue_dir/.transcript-violation-planning  ← dispatch.sh:78
       → pre-clean: rm $issue_dir/.envelope-transcript-planning   ← dispatch.sh:78
       → claude -p ... --add-dir $issue_state_dir ... (NEW: writes work)
       → agent appends progress.md entry, writes stage-summary-planning.md
       → _assert_progress_md_entry passes (1 entry stamped with new id)
       → return 0
```

No operator action needed beyond `--action continue`. The pre-existing
`.transcript-violation-planning` from ENG-125's original halt is
removed at `bin/dispatch.sh:78` before the next dispatch's renderer
runs; the success path commits and transitions normally.

## 8. Error handling

- **Agent writes to a forbidden orchestrator-owned path.** Detective
  D-003 trips inside `_render_and_capture_stream`, writes the matched
  path to `.transcript-violation-<stage>`, logs `[assert] stage=<stage>
  transcript invoked forbidden Write/Edit on orchestrator-owned path:
  <matched>`, returns rc=29. `run-stage.sh::_dispatch_envelope_*`
  surface the halt via the existing rc=29 → `envelope-violation`
  classification. No new code paths.
- **`mkdir -p $issue_state_dir` fails** (filesystem readonly, disk
  full). dispatch.sh dies — but the same failure would also block
  the existing `_capture_path` write at `bin/dispatch.sh:684` and the
  renderer's `mkdir -p "$issue_dir"` at `bin/dispatch.sh:80`. No new
  failure mode introduced.
- **`$issue_state_dir` resolves to empty** (e.g., `PIPELINE_ISSUE_ID`
  set but empty string). `bin/common.sh::issue_dir` already
  `die`'s on empty issue ids (line 70). The gate at
  `bin/dispatch.sh:521` (`[[ -n "${PIPELINE_ISSUE_ID:-}" ]]`)
  treats empty-set as unset and skips the block. No behavior change.
- **`--add-dir` flag unrecognised by an older claude CLI.** Would
  cause claude to fail with an argv error; the dispatch fails with
  whatever exit code claude returns; the existing
  `failure_outcome_for_exit` table classifies it as `unknown-exit-N`.
  Mitigation: ENG-155's rollout is gated on a known-good claude
  version range (operator pin) — this is exactly the OUT-of-scope
  ticket from the Linear issue body (CLI pinning).
- **Detective hits a path-substring collision** (e.g., the agent
  legitimately writes to a worktree file named
  `kube/issue-state.json.example`). The endswith on
  `/issue-state.json` would false-positive. Mitigation: the
  detective only runs on the transcript inside the dispatch path; the
  agent's `Write` tool_use absolute file_path would resolve to a
  worktree-relative path that does NOT live under `$issue_state_dir`;
  the false positive is real but bounded to the literal suffix. If a
  target project has such a file, the operator can tighten the
  endswith match to the full `$issue_state_dir/…` prefix using
  the same shape as `bin/dispatch.sh::_assert_progress_md_entry`.
  Deferred to OQ-5.
- **D-003 is post-hoc, not preventive** (security persona P1).
  `assert_no_*_path` runs AFTER the agent's tool call executes
  against the filesystem. By the time rc=29 fires,
  `issue-state.json` (or whichever file matched) may already be
  clobbered. Mitigation: ENG-87's structural invariants are
  self-healing on `--action continue` (the resume path re-allocates
  `dispatch_id`, clears halt state, preserves forensic
  `dispatch_history.jsonl`). Worst-case agent attack is single-shot
  corruption, caught, operator resumes. Acceptable trade-off; a
  preventive design (pre-dispatch snapshot + post-dispatch
  compare for `issue-state.json` + `dispatch_history.jsonl`) is
  flagged as a belt-and-suspenders follow-up if any agent ever
  demonstrates a corruption-then-bypass attack.
- **D-003 scope limit — Write/Edit only** (security persona P1).
  An agent on a stage granted `Bash(rm:*)` or `Bash(mv:*)` could
  bypass the detective via `rm $issue_state_dir/issue-state.json`
  or a shell-redirect `cat > .../wait-building.json <<EOF`. Neither
  appears as a `Write` / `Edit` tool_use in the transcript.
  Bounded today because the operator-decision-2026-05-10 forbids
  any form of `Bash(rm:*)` in agent allowlists (CLAUDE.md memory
  "No scoped rm allowlist for agent stages"); the existing
  Bash-allowlist discipline is the load-bearing defense for this
  axis. D-003's scope is documented as "covers the Write/Edit
  envelope only."
- **Operator triage — disambiguating rc=29 roots** (product
  persona P1). Two distinct detectives now emit rc=29 with sidecar
  `.transcript-violation-<stage>`: ENG-87's envelope-validator
  (forbidden Linear-API call) and D-003 (forbidden orchestrator-
  file Write/Edit). The sidecar's matched-string is the
  disambiguator: a path ending in `/issue-state.json` /
  `/wait-*.json` / `/dispatch_history.jsonl` etc. points at D-003;
  a string matching `mcp__plugin_linear` / `curl https://api.linear.app` /
  `gh api graphql` / `wget https://api.linear.app` / `unset
  PIPELINE_DISPATCH_ID` points at the envelope-validator. The
  plan doc's deliverables list includes a new row for
  CLAUDE.md's failure-mode quick-reference table making this
  explicit.

## 9. Edge cases

- **Dispatch from release / retrospective / mutex-test / dry-run-self-
  check.** These callers leave `PIPELINE_ISSUE_ID` unset; the gate at
  `bin/dispatch.sh:521-527` short-circuits. The new `--add-dir`
  splice lives inside the same gate, so they observe zero behavior
  change. The detective never runs (no `issue_state_dir`, nothing to
  forbid).
- **Dry-run mode** (`PIPELINE_DRY_RUN=1`). The DRY_RUN log at
  `bin/dispatch.sh:603` echoes the would-be command line. The
  `--add-dir` flag must appear in the echo. Test fixture verifies
  the DRY_RUN log surface explicitly.
- **Scope-approval replay** (`bin/run-stage.sh` early-return path
  when `skip_dispatch == 1`). `allocate_dispatch_id` /
  `_clear_current_stage_slots` / dispatch.sh are skipped per
  existing logic at `bin/run-stage.sh:1341-1401`. The new `--add-dir`
  splice does not run; the agent does not run; the detective does
  not run. No interaction.
- **Concurrent dispatches** (K=2). Each dispatch has its own
  `$issue_state_dir` (path includes the issue id); the `--add-dir`
  flags are per-process. The Claude semaphore at
  `$HARNESS_STATE_DIR/.claude-semaphore/` is untouched.
- **Operator-edit during dispatch.** If the operator edits, say,
  `issue-state.json` from a sibling shell during dispatch, the
  detective is transcript-side only (it scans what the agent did, not
  filesystem state), so operator edits are invisible to it. This is
  consistent with the existing ENG-87 envelope detectives' shape.
- **Stage-summary path semantics.** Agents write
  `$(issue_dir <ident>)/stage-summary-<stage>.md` per
  AGENT_PROMPTS.md preamble. That path is NOT in D-003's forbidden
  set — the agent SHOULD be able to write it. Verified at
  `bin/run-stage.sh:340,1146` where the orchestrator reads it post-
  dispatch.
- **Cross-issue contamination.** `--add-dir` widens the sandbox to
  ONE directory (`$(issue_dir <ident>)` for the dispatched issue
  only). The sandbox still blocks the agent from writing into a
  sibling issue's `$(issue_dir <other_ident>)` or into
  `$PROJECT_STATE_DIR/metrics/` or any other slot. Per-issue
  isolation preserved.

## 10. Assumption inventory

| Assumption | Status | Verified at |
|---|---|---|
| `claude` CLI ships `--add-dir <directories...>` flag in current version | **verified** | `claude --help` output (line 11 of the visible help): `--add-dir <directories...>  Additional directories to allow tool access to` |
| `bin/dispatch.sh:521-527` already gates `usage_file` + `issue_state_dir` resolution on `PIPELINE_ISSUE_ID` non-empty | **verified** | `bin/dispatch.sh:521-527` |
| `bin/dispatch.sh:645-670` is where the `cmd` argv array is built for the `claude -p` invocation | **verified** | `bin/dispatch.sh:645-670` |
| `bin/run-stage.sh:1329` already runs `mkdir -p "$(issue_dir "$ident")"` before dispatch | **verified** | `bin/run-stage.sh:1329` (so the new mkdir in dispatch.sh is belt-and-suspenders for non-run-stage callers — see OQ scope at §6) |
| `bin/common.sh::issue_dir` returns `$PROJECT_STATE_DIR/$issue` and dies on empty issue id | **verified** | `bin/common.sh:68-72` |
| `bin/common.sh::assert_no_write_to_path` exists with endswith semantics on `tool_use.input.file_path` for `Write` tool_use | **verified** | `bin/common.sh:240-257` |
| `bin/common.sh::assert_no_tool_invocation` exists with startswith semantics on `tool_use.input.command` for `Bash` tool_use | **verified** | `bin/common.sh:215-232` |
| There is NO existing `assert_no_edit_to_path` helper; Edit must be added as a sibling | **verified** | `grep -n 'assert_no_edit' bin/common.sh bin/dispatch.sh` returned no matches (only the Write variant exists) |
| `failure_outcome_for_exit` at `bin/common.sh:274-306` already maps `29 → envelope-violation` | **verified** | `bin/common.sh:297` |
| `bin/run-stage.sh::_validate_dispatch_envelope` runs the post-dispatch envelope scan over `.envelope-transcript-<stage>` | **verified** | `bin/run-stage.sh:969-1011`. (D-003 runs INSIDE `_render_and_capture_stream`, not here — different layer.) |
| `bin/run-local.sh:205` sets the dispatch CWD via `(cd "$dispatch_cwd" && bash run-stage.sh …)` | **verified** | `bin/run-local.sh:186,205` |
| `bin/render-prompt.sh::append_project_profile` reads `$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md` and appends to stdin | **verified** | `bin/render-prompt.sh:188-214` |
| `bin/dispatch.sh:478` planning base lacks `Bash(git add:*)` and `Bash(git commit:*)` | **verified** | `bin/dispatch.sh:478` (only `git log` + `git diff` git verbs present) |
| `bin/dispatch.sh:479-482` implementing/ui/qa bases include `Bash(git add:*)` directly OR via `Bash(git:*)` wildcard | **verified** | `bin/dispatch.sh:479` (impl), `:480` (ui), `:482` (qa via `Bash(git:*)`) |
| AGENT_PROMPTS.md §3 Implement starts at line 690; §4 UI at line 957 | **verified** | `grep -n '^## ' AGENT_PROMPTS.md` |
| AGENT_PROMPTS.md planning §2 step 4 "Commit artifacts" is at line 625 | **verified** | `AGENT_PROMPTS.md:625-631` (the latent prompt-vs-allowlist mismatch flagged in OQ-2) |
| `bin/dispatch.sh:288-292` shows existing precedent for a stage-gated filesystem detective inside `_render_and_capture_stream` | **verified** | `bin/dispatch.sh:288-292` (`_assert_progress_md_entry`) |
| `bin/dispatch-test.sh::ARGV_CAPTURE` fixture infrastructure already exists and is wired to a `claude` stub | **verified** | `bin/dispatch-test.sh:115-130,187-230` |
| Per-issue worktree path resolves to `$(issue_dir <ident>)/worktree` (NOT the same as `$issue_state_dir`) | **verified** | `bin/run-stage.sh:45`, `bin/run-local.sh::_run_worker dispatch_cwd` semantics, `docs/architecture.md` topology diagram |
| Project profile is appended to every non-retrospective dispatch's prompt, so agent never needs to Read `learned-rules/` directly | **verified** | `bin/render-prompt.sh:188-214` (the `if stage == retrospective` early-return is the only skip path) |
| The `--add-dir` flag is order-insensitive at claude's argv parsing (placement is purely cosmetic for log readability) | **assumed** | claude CLI docs do not pin order; tested empirically once via dispatch-test.sh's argv-capture asserting flag presence (not position). Position matters only for operator-log scanning, not behavior — see D-001 |

## 11. ADR stress test

Two existing accepted decisions that touch this surface:

- **ENG-48 (isolation flags) — `--setting-sources project,local
  --disable-slash-commands --disallowed-tools …`.** D-001 places
  `--add-dir` just before this isolation block. The ENG-48 invariant
  is "headless dispatches must neutralise user-level config and deny
  runaway-enabling platform tools." Widening the writable directory
  scope from {worktree} to {worktree, $issue_state_dir} does NOT
  re-enable any ENG-48-banned tool — the agent's `Write` /
  `Edit` tool itself was always allowed (in stages whose allowlist
  admits it); the sandbox was an orthogonal containment. ENG-48
  invariant preserved.
- **ENG-87 (cross-dispatch staleness — dispatch_id contract).**
  ENG-87's structural invariant is "orchestrator-owned files in the
  per-issue state directory are the substrate for the dispatch_id
  monotonicity contract." Pre-ENG-155, the sandbox enforced this
  by accident (agent couldn't reach the files). Post-ENG-155, the
  agent CAN reach the files; D-003 is what restores the
  enforcement by intent. The ENG-87 invariant survives — but ONLY
  because D-003 ships with D-001. Shipping D-001 without D-003 would
  re-introduce the ENG-146 / ENG-87 failure class as an
  agent-side regression. The brainstorm treats this as a hard
  shipping coupling: D-001 + D-003 ship together or not at all.

No ADR rejected. The ADR stress identifies one shipping constraint
(D-001 ⇔ D-003 are atomic) and one consistency hazard (D-005's
planning half-allowance was caught before merge).

## 12. Persona review (actual cold-pass results — 2026-05-19)

Gate: **6/6 PASS · P0: 0 · proceeding to planning.** P1 findings recorded
here verbatim from each persona's cold pass; the brainstorm body has
been updated in-place to absorb the load-bearing ones (cross-referenced
inline below). Findings the brainstorm deliberately defers are tagged
to OQ-N in §5.

### Design — PASS

- P1 (acted on, §6 row updated): The D-003 forbidden-suffix list is
  enumerated metadata rather than pattern-derived; future
  orchestrator-owned files require coordinated edits at three sites
  (write site, detective list, test). Inversion to an
  **agent-writable allowlist** (`progress.md`,
  `stage-summary-*.md`) is structurally cleaner and ages better. The
  brainstorm now flags this as the preferred shape for the plan
  doc — see §6 row for D-003 (updated below); OQ-6 captures the
  open call between enumerated-deny and inverted-allow.
- P1 (acted on, §6 row updated): `assert_no_edit_to_path` as a sibling
  helper is the wrong abstraction — every future Write+Edit detective
  pays the cost again. Prefer parameterising the existing helper:
  `assert_no_tool_with_input_path <transcript> <tool_name>
  <input_field> <suffix>`, OR accept a tool-name list so one call
  covers `Write|Edit|NotebookEdit`. §6 row updated; OQ-7 records the
  signature-change ergonomic trade-off.
- P1 (deferred — cosmetic): D-001's two-paragraph defense of
  `--add-dir` argv position is bloat; position is one-line-movable.
  Acceptable as-is, no body change.
- P1 (deferred — process): OQ-2 must actually be filed as a Linear
  ticket. Tracking in §5.
- P1 (acted on, §13 made explicit): D-001 ⇔ D-003 atomicity is a
  single-PR constraint, not a multi-pass split.

### Security — PASS

- P1 (acted on, §8 row added): D-003 is post-hoc — the agent's
  forbidden Write/Edit completes against the filesystem before
  the transcript-scan detective fires; rc=29 halts the NEXT
  dispatch. Mitigation: ENG-87's invariants are self-healing
  on `--action continue` (re-allocates dispatch_id). Worst-case:
  one-shot corruption, caught, operator resumes. Forensic record
  (sidecar + `dispatch_history.jsonl`) intact. Documented as
  acceptable trade-off in §8.
- P1 (acted on, §8 + §9 rows added): The detective covers `Write` +
  `Edit` only. `Bash(rm:*)` / `Bash(mv:*)` / shell-redirect
  bypasses are NOT caught — but `Bash(rm:*)` is forbidden across all
  agent stages by operator decision 2026-05-10 (CLAUDE.md "No scoped
  rm allowlist for agent stages" memory), so the bypass is bounded
  by the existing Bash allowlist discipline. Documented in §8 as
  scope limit.
- P1 (deferred — OQ-8): rc=29 reuse blurs four distinct failure
  classes for the retrospective's §1 aggregator. Subcode shape
  (`envelope-violation:write-progress`, `envelope-violation:orch-
  file`) is plausible follow-up; not blocking ENG-155.
- P1 (acknowledgement): D-002 rejection is genuinely load-bearing
  (cross-slug profile leakage), not YAGNI. Endorsed.
- P1 (OQ-5 entry tightened): suffix-match bypass via `.bak` or
  path-traversal IS a residual gap; tighten to anchored exact-match
  against `$issue_state_dir/<basename>` in a sibling ticket.

### Scope — PASS

- P1 (acted on, §6 row + AC mapping clarified): AC #3's "the per-stage
  allowlist contains `Bash(git add:*)`" is satisfied for the three
  stages where the ticket's "if not already present" pre-condition
  applies (impl/ui/qa). Planning is documented-as-deferred via OQ-2
  rather than silently dropped. §6 architecture table now states
  this explicitly.
- P1 (acted on, D-006 expanded): D-006 narrows prompt edits to §3
  Implement and §4 UI. Planning's prompt step 4 "Commit artifacts"
  asymmetry is intentional (tied to OQ-2's planning-allowlist gap);
  fixing planning's prompt-vs-allowlist consistency belongs in the
  OQ-2 follow-up ticket.

### Coherence — PASS

- P1 (acted on, §6 implementation deliverables list updated): the
  failure-mode quick-reference table in CLAUDE.md gains no new row
  in this ticket; the new "rc=29 + sidecar names `/issue-state.json`
  or `/wait-*.json`" → "agent attempted forbidden write to
  orchestrator-owned file" mapping is added to the plan doc's
  implementation deliverables.
- P1 (deferred — docs debt): `docs/architecture.md` §"Failure
  taxonomy" table stops at rc=26 and is silently out of date; this
  is pre-existing, not introduced here. Plan doc should file a
  separate docs-debt follow-up (OQ-9).
- P1 (acknowledgement): Stage-name gerund convention, sidecar shape
  reuse, ENG-87/ENG-48 invariant framing, defense-in-depth pattern
  all match precedent.
- P1 (acted on, §10 updated): `dispatch_history.jsonl` line refs in
  §7 — verify exact line numbers at implementation time (the
  brainstorm cites approximate ranges).

### Product — PASS

- P1 (acted on, §7 + §8 rows added): AC #2's "ENG-125 recovers via
  `--action continue`" has a silent precondition — the pre-existing
  `.transcript-violation-planning` sidecar from ENG-125's halt is
  cleared by the next dispatch's pre-clean (`bin/dispatch.sh:78`
  `rm -f "$violation_file" "$envelope_sidecar"`). `_clear_current_
  stage_slots` clears `stage-summary-planning.md` and
  `wait-planning.json` but NOT `issue-state.json`. The allocator-
  preserved fields survive (ENG-146 fix). Net: no operator action
  needed beyond `--action continue`. Documented in §7 data flow.
- P1 (acted on, §8 row added): Operator triage of an rc=29 halt now
  has two possible roots — ENG-87 envelope-validator (forbidden
  Linear API call) or D-003 (forbidden orchestrator-file write).
  The sidecar's matched-path string is the disambiguator: a path
  ending in `/issue-state.json` etc. points at D-003; a string
  matching `mcp__plugin_linear` / `curl https://api.linear.app` /
  `gh api graphql` points at the envelope-validator. Plan doc
  deliverables include the recovery.md row addition.
- P1 (acknowledgement): planning's prompt-vs-behavior asymmetry
  (prompt says "Commit artifacts," allowlist doesn't admit it) is
  pre-existing AND a separate gap from ENG-155's surface; OQ-2
  captures both halves of the fix.

### Feasibility (codebase-fact verification) — PASS · P0: 0

All 12 named codebase facts verified at the cited `path:line` (see
the persona's full report below). No codebase-fact P0. Three
load-bearing implementation notes recorded:

- P1 (acted on, §6 row updated): D-003 should follow the **ENG-109
  Write detective shape** (no `-n "$last_result"` guard — fires on
  any transcript match), NOT the ENG-106 filesystem detective shape
  (which has the M2 SIGTERM-race guard). Transcript-scan detectives
  don't need the result-event guard because they fire only when the
  transcript HAS a forbidden tool-use event — a `gtimeout` kill that
  races before the offending Write produces no transcript entry to
  match.
- P1 (acted on, D-002 rationale clarified): `append_project_profile`
  inlines `learned-rules/$PROJECT_SLUG/project-profile.md` only;
  per-stage `learned-rules/<stage>.md` files come through a
  different prompt-append path. D-002 rejection still stands but
  the rationale section now names BOTH inline sites.
- P1 (deferred — docs debt): `bin/render-prompt.sh:206-208`'s
  `schema_version: 1` warning is stale (current profile schema is
  v2 per CLAUDE.md); pre-existing inconsistency, not introduced
  here. OQ-9 captures.

## 13. Decision (revised post-review)

Ship D-001 + D-003 + D-006 **atomically in a single PR**. Verify
D-005 (no code change for the four stages' `git add` presence;
planning's gap deferred to OQ-2). Do NOT ship D-002 (the
`learned-rules/` widening). D-003 ships with the **agent-writable
allowlist** shape preferred by the design persona (whitelist
`progress.md` + `stage-summary-*.md`; deny everything else under
`$issue_state_dir`) if the plan doc concurs; the enumerated-deny
shape is the fallback. The new helper ships as the parameterised
`assert_no_tool_with_input_path` rather than as a Write+Edit pair.

The implementation is ~20 lines in `bin/dispatch.sh`, 1 new (or
parameterised) helper in `bin/common.sh`, 1-2 short prompt
directives in `AGENT_PROMPTS.md`, and three new test groups in
`bin/dispatch-test.sh`. The two-axis sizing rubric still holds:
subsystems = {dispatch, agent prompts} (2, with prompts clearly
subordinate); independent design decisions = 1 (D-001 is the
load-bearing decision; D-003 / D-004 / D-006 are defenses +
ergonomics that follow from it). Both axes within the autonomy-safe
band.

## 13. Decision

Ship D-001 + D-003 + D-006 atomically. Verify D-005 (no code change
for the four stages' `git add` presence; planning's gap deferred to
OQ-2). Do NOT ship D-002 (the `learned-rules/` widening). The
implementation is ~20 lines in `bin/dispatch.sh`, 1 new helper in
`bin/common.sh`, 1-2 short prompt directives in `AGENT_PROMPTS.md`,
and three new test groups in `bin/dispatch-test.sh`. The two-axis
sizing rubric: subsystems = {dispatch, agent prompts} (2, with
prompts clearly subordinate); independent design decisions = 1
(D-001 is the load-bearing decision; D-003 / D-004 / D-006 are
defenses + ergonomics that follow from it). Both axes within the
autonomy-safe band.
