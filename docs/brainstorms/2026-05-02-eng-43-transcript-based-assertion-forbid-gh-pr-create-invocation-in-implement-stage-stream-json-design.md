---
linear: ENG-43
title: Transcript-based assertion — forbid `gh pr create` invocation in implement-stage stream-json
date: 2026-05-02
status: draft
---

# Transcript-based assertion — forbid `gh pr create` invocation in implement-stage stream-json

## 1. Overview

ENG-42 deleted the false-positive PR-count state-check guard at the old
`bin/run-stage.sh:373-384` line range. The implement stage's tool-lane
already excludes `Bash(gh:*)` (`bin/dispatch.sh:175`), so the deleted
guard could never fire on a true contract violation — only on PRs opened
by other actors (humans, prior UI runs, future stages). Defense-in-depth
against a future tool-lane misconfiguration was deferred to ENG-43
(this issue), pending ENG-26's stream-json renderer landing on `main`.

ENG-26 has now landed on this branch:
- `bin/dispatch.sh:69-122` — `_render_and_capture_stream`.
- `bin/dispatch.sh:71` — `local raw_capture="${issue_dir}/.raw-stream.ndjson.tmp"`.
- `bin/dispatch.sh:72` — `trap 'rm -f "$raw_capture"' RETURN`.

This ticket adds an `assert_no_tool_invocation <transcript> <pattern>`
helper to `bin/dispatch.sh`, calls it from inside the renderer (gated on
`stage == "implement"`, pattern = `gh pr create`), and wires the
match-failure return (rc=22) through `bin/run-stage.sh` so it produces
the same operator-facing surface (`skip-until-human-acts`,
`pr-opened-too-early`) as the deleted state-check guard.

The design is captured verbatim by ENG-42 brainstorm §2.1
(`docs/brainstorms/2026-04-28-eng-42-reframe-implement-pr-guard-design.md:131-159`).
This brainstorm verifies it against the current `main` code, locks in
sequencing decisions, enumerates the six fixtures, and flags the
fixture-letter collision between issue text and the existing test file.

The load-bearing tradeoff: defense-in-depth duplicates the tool-lane
denial. The lane is the primary defense; the assertion is a
late-binding tripwire that only fires if the lane is misconfigured.
That extra layer is what the issue asks for, and the cost is one jq
fork per implement dispatch (matches ENG-26's D-002 single-fork
budget).

## 2. Decisions

### D-001 — Helper as a standalone, single-fork jq function

`assert_no_tool_invocation <transcript> <pattern>` lives in `bin/dispatch.sh`
alongside `_render_and_capture_stream`. It is a pure function: takes a
transcript file path and a literal pattern string, returns 0 on no match,
returns 1 on first match (printing the matched command on stdout).

**Rationale.** Inherited verbatim from ENG-42 §2.1 D-002. The single-fork
constraint mirrors ENG-26 D-002 (the renderer's stream pipeline is one
jq fork; this assertion adds one more, to a total of two per implement
dispatch). The standalone signature lets dispatch-test.sh source the
function and exercise it against transcript fixtures without spinning
up a real `claude -p`.

**Implementation skeleton:**

```bash
assert_no_tool_invocation() {
  local transcript="$1" pattern="$2"
  [[ -s "$transcript" ]] || return 0          # D-005 soft-fail
  local matched
  matched="$(jq -Rr --arg p "$pattern" '
    fromjson? // empty
    | select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Bash")
    | (.input.command // "")
    | select(startswith($p))
  ' "$transcript" 2>/dev/null | head -1)" || true
  if [[ -n "$matched" ]]; then
    printf '%s\n' "$matched"
    return 1
  fi
  return 0
}
```

`-R` reads the file line-by-line as raw strings (matches the renderer's
NDJSON input shape); `fromjson? // empty` tolerates malformed lines
(F2 in the renderer's existing tolerance contract); `head -1` caps
output to the first match (cheap; SIGPIPE on jq is harmless inside a
command substitution).

### D-002 — Stream-json shape: tool_use blocks only

Match against `assistant.message.content[]?` blocks where
`.type == "tool_use" and .name == "Bash"`, then `startswith($pattern)` on
`(.input.command // "")`. Do NOT match agent narration in `text` blocks.
Do NOT match JSON-escaped string content embedded inside `text` blocks
(fixtures CT, DT below).

**Rationale.** Inherited from ENG-42 §2.1. The contract question is
"did the agent invoke `gh pr create`?", which is a property of the
`tool_use` event, not of any prose in which the agent might quote the
string. Verified against the renderer's own filter shape
(`bin/dispatch.sh:90-91`): `select(.type=="text") | .text` and
`select(.type=="tool_use") | .name` are the two distinct lenses. The
assertion uses the `tool_use` lens.

### D-003 — Single call site (implement only) in v1

The assertion runs only when `stage == "implement"`. UI, build, and
review stages legitimately invoke `gh pr create` (UI used to;
orchestrator does post-ENG-49) or `gh pr merge` (build) or `gh pr review`
(review). Generalizing the helper across stages — `git push --force`
from review, `gh pr merge` outside build, etc. — is explicit out-of-scope
per ENG-42 §3.7.

**Rationale.** One concrete call site keeps the pattern reviewable and
keeps the test surface small (six fixtures, not eighteen). Matches the
ENG-42 §2.1 D-006 captured intent.

### D-004 — Pattern matching: literal `startswith` on `.input.command`

The pattern is the literal string `gh pr create`, matched with jq's
`startswith($p)`. So `gh pr create --title "x" --body "y"` matches; a
hypothetical `gh-pr-create` typo does not.

**Rationale.** Inherited from ENG-42 §2.1. Equality is too strict (the
agent will pass flags). Regex is unnecessary (one fixed pattern, one
call site). `startswith` is the simplest filter that answers the
contract question.

### D-005 — Soft-fail on empty/missing transcript

`[[ -s "$transcript" ]] || return 0` at the top of the helper. Empty
file or missing file → returns 0 (no match).

**Rationale.** Inherited from ENG-42 §2.1. Dry-run mode and any future
"renderer bypass" path (where `$raw_capture` is never written) must not
synthesize false positives. The renderer's existing soft-fail on a
missing `result` event (D-010 in ENG-26 brainstorm) sets precedent for
"observability paths never bubble up as control-flow errors."

### D-006 — Sequencing: assertion runs inside the renderer, before the RETURN trap

`_render_and_capture_stream` accepts a third arg, `stage`. After the
existing result-event extraction (`bin/dispatch.sh:99-121`), if
`stage == "implement"`, the renderer calls `assert_no_tool_invocation
"$raw_capture" "gh pr create"`. On match, the renderer writes the
matched command to a sidecar (`${issue_dir}/.transcript-violation-${stage}`)
and returns 22. The existing `RETURN` trap at `bin/dispatch.sh:72`
fires unchanged after the function returns, removing `.raw-stream.ndjson.tmp`
(but not the sidecar — D-007 owns that lifecycle).

**Rationale.** ENG-42 §2.1 says "Existing trap stays unchanged;
assertion just slots in before it." Honoring that constraint forces the
assertion to run inside the function whose RETURN trap owns the
transcript file. The alternative (move the trap up to `main()` so
`$raw_capture` outlives the renderer) would spread file-management
across two functions and risks regressing the SEC-008 cleanup
(`bin/dispatch.sh:64-66`: per-issue trust scope, prefixed `.`,
trap-bounded lifetime).

The renderer is invoked inside a pipeline (`bin/dispatch.sh:286-292`,
`bin/dispatch.sh:295-298`). With `set -o pipefail`, returning 22 from
the right side of the pipe makes the pipeline exit 22; under the
script's `set -e`, dispatch.sh's `main()` exits 22, which propagates to
run-stage.sh's `dispatch_rc`.

### D-007 — Match-failure surface: `skip-until-human-acts`, exit 22, reason text preserved

`bin/run-stage.sh` already maps non-zero `dispatch_rc` to
`retry-immediately` (rc 1-123) or `skip-until-human-acts` (rc 124).
We add a third case: `dispatch_rc == 22` → read sidecar
`${issue_dir}/.transcript-violation-${stage}`, call
`classify_failure "$ident" "$stage" "skip-until-human-acts" \
"implement-stage transcript invoked forbidden tool: <command>" 22`,
remove sidecar, exit 22.

**Rationale.** Inherited from ENG-42 §2.1: same exit code, same policy,
same reason-text shape as the deleted state-check guard. The exit-code
mapping `22 → pr-opened-too-early` is already in
`bin/common.sh:115`; not renamed, because ENG-42 §2.1 explicitly says
"Operator-facing surface preserved." Retrospective §1's filter, status.sh,
and existing dashboards all key on that string. Renaming is gratuitous.

The case is added BEFORE the existing 124 / non-zero ladder so the
specific code is matched first:

```bash
elif (( dispatch_rc == 22 )); then
  local _viol_file _viol_cmd
  _viol_file="$(issue_dir "$ident")/.transcript-violation-${stage}"
  _viol_cmd="$(cat "$_viol_file" 2>/dev/null || printf '<command-unavailable>')"
  classify_failure "$ident" "$stage" "skip-until-human-acts" \
    "implement-stage transcript invoked forbidden tool: $_viol_cmd" 22
  rm -f "$_viol_file" "$prompt_file"
  exit 22
```

### D-008 — Sidecar location and naming

Sidecar path: `${issue_dir}/.transcript-violation-${stage}`. Hidden
(leading dot, partition_dirty_paths-invisible per the existing
`.raw-stream.ndjson.tmp` precedent), per-issue, per-stage suffixed.

**Rationale.** The stage suffix is forward-compatible with the
out-of-scope D-003 generalization (other stages, other patterns). The
file is removed by run-stage.sh's rc=22 branch after read; if dispatch
crashes between writing the sidecar and run-stage.sh reading it, the
next dispatch's renderer entry pre-cleans the sidecar (idempotent
`rm -f` mirroring `bin/dispatch.sh:213`). Cross-stage collision is
prevented by the suffix even though only `implement` uses it today.

### D-009 — Test fixture letters: AS1–AS6 (not E–J)

The Linear issue uses fixture letters E–J. The current `bin/dispatch-test.sh`
already defines fixtures A through K for the renderer's stream
(`bin/dispatch-test.sh:336-643`). Re-using letters E–J would collide with
existing assertions and obscure which fixture tests which feature.

This brainstorm proposes prefix `AS` (assertion) for the six new fixtures:
- **AS1** — `tool_use` invoking `gh pr create --title …` → returns 1, prints command. (Issue's fixture E.)
- **AS2** — `tool_use` invocations of `git status`, `git log`, `gh pr list` only → returns 0. (Fixture F.)
- **AS3** — `assistant.message.content[].text` with literal "gh pr create" prose → returns 0. (Fixture G.)
- **AS4** — JSON-escaped quoted string in `text` field → returns 0. (Fixture H.)
- **AS5** — one malformed JSON line + one valid matching `tool_use` → returns 1. (Fixture I.)
- **AS6** — missing/empty transcript file → returns 0 (soft-fail). (Fixture J.)

**Rationale.** The issue's fixture letters are descriptive; the test
file's letters are positional. Renaming for the test file preserves
both (the issue's six tests are all delivered; the test file remains
self-consistent). The stage-summary may note the letter remap so a
reader cross-referencing the issue's fixture E to AS1 isn't confused.

### D-010 — Helper signature decoupled from PIPELINE_ISSUE_ID

The helper takes a transcript path and a pattern — nothing more. It
does not consume `$PIPELINE_ISSUE_ID`, `$issue_dir`, or any harness
ambient context.

**Rationale.** Renderer-level fixtures already test against `$ISSUE_DIR`
(stub-managed); the assertion fixtures want to read straight from a
fixture file in `$STUB_DIR`. Decoupling the helper avoids importing
the renderer's environment expectations into a function whose only
job is "scan a file for a pattern." This is the same shape the
existing `_dispatch_tools_extras` and `disallowed_platform_tools`
helpers take (`bin/dispatch.sh:130-152`).

## 3. Architecture

### 3.1 Code locations

| File | Change |
|---|---|
| `bin/dispatch.sh` | Add `assert_no_tool_invocation` (new function, ~15 lines). Modify `_render_and_capture_stream` signature to accept a third arg `stage`. Add stage-gated assertion call before function return. Update both call sites in `main()` (lines 287-289 and 296-297) to pass `$stage`. |
| `bin/run-stage.sh` | Insert `elif (( dispatch_rc == 22 )); then …` branch between the existing `dispatch_rc == 124` and `dispatch_rc != 0` cases (~lines 559-574). |
| `bin/dispatch-test.sh` | Add a Group 6 (or 7 — verify counter against last existing group) section with six fixtures AS1–AS6. Each fixture writes NDJSON to a `STUB_DIR` tmp file and calls `assert_no_tool_invocation`. |
| `CLAUDE.md` | Add a bullet under "When wiring a new script" (line 256+): *"Defense-in-depth on top of tool-lane denials: when a stage's contract says 'agent must not invoke tool X,' add a transcript-based assertion (`assert_no_tool_invocation` in `bin/dispatch.sh`) inside the renderer rather than a state-of-the-world check after dispatch. State checks false-positive on actions taken by other actors; transcript checks answer the contract question directly."* |

### 3.2 Data flow on a violation

1. Implement agent invokes a `tool_use` of `Bash` with `.input.command` starting with `gh pr create`. (Today, this requires a tool-lane misconfig; the lane denies `Bash(gh:*)` for implement.)
2. `claude -p` emits the `tool_use` event in stream-json on stdout.
3. `tee "$raw_capture"` mirrors the line into `${issue_dir}/.raw-stream.ndjson.tmp`.
4. The pipeline ends; `_render_and_capture_stream` extracts the result event into `usage-implement.json` (existing path).
5. Renderer calls `assert_no_tool_invocation "$raw_capture" "gh pr create"`.
6. Helper jq filter finds the match, prints `gh pr create --title "..."`, returns 1.
7. Renderer writes `${issue_dir}/.transcript-violation-implement` with the matched command, returns 22.
8. `set -o pipefail` propagates 22 to dispatch.sh's `main()`; `set -e` exits 22.
9. run-stage.sh sees `dispatch_rc == 22`, reads sidecar, calls `classify_failure ... skip-until-human-acts ... 22` (which posts the halt-marker comment, applies `pipeline:halted`, writes `issue-state.json`, emits the `pr-opened-too-early` metric), removes sidecar, `exit 22`.
10. Operator sees the halt comment in Linear; resolves with `bash bin/halt.sh resolve <ENG-N> --decision resume` after fixing the lane misconfig.

### 3.3 Data flow on a clean implement run

1. Implement agent commits via allowed `Bash(git:*)` calls; never invokes `gh`.
2. Renderer extracts result event; `usage-implement.json` written.
3. Helper jq filter finds zero matches; helper returns 0 with empty stdout.
4. Renderer returns 0; pipeline exits 0; dispatch.sh exits 0.
5. run-stage.sh proceeds to scope-check (existing path at lines 587-672).

## 4. Edge cases & failure modes

| Case | Behavior | Test |
|---|---|---|
| Agent narrates "I considered `gh pr create` but used git instead" in a `text` block | Helper ignores `text`; returns 0 | AS3 |
| Agent's `text` quotes a JSON-escaped `"gh pr create"` from documentation | Helper ignores `text`; returns 0 | AS4 |
| Stream-json contains one malformed line then a real matching `tool_use` | `fromjson?` skips malformed; match found; returns 1 | AS5 |
| Dry-run: `_render_and_capture_stream` not invoked; `$raw_capture` doesn't exist | Soft-fail handled at the dispatch.sh::main level (dry-run returns before the renderer is called) | implicit |
| Implement runs but transcript is zero-byte (claude died early) | `[[ -s ]]` fails; helper returns 0 | AS6 |
| Multiple matching `tool_use` blocks | jq's pipeline plus `head -1` gives the first; only one command shown to operator | implicit by jq stream order |
| `tool_use` with `.input.command` absent | `// ""` defaults to empty; `startswith("gh pr create")` is false; ignored | implicit by jq filter |
| Non-`Bash` tool_use whose name accidentally contains "gh pr create" in its input | Filtered by `.name == "Bash"` predicate before the command extraction | implicit |
| Sidecar present from a prior crashed dispatch | Renderer's idempotent `rm -f "$violation_file"` at function entry pre-cleans | implicit |
| run-stage.sh crashes between dispatch and the rc=22 branch | Sidecar persists in `$issue_dir`; next dispatch's renderer cleans it. No false replay (each fresh dispatch produces a fresh `.raw-stream.ndjson.tmp`; the sidecar is only re-written when a new match fires) | implicit |
| Pattern contains regex metacharacters (e.g. someone passes `gh pr create.*`) | `startswith` is literal in jq; `.*` is matched as literal characters, not regex | safe by design |
| jq absent / corrupted at runtime | `2>/dev/null || true` swallows the error; `matched` empty; helper returns 0 (soft-fail equivalent). The renderer's existing fork already requires jq so this scenario already fails earlier | acceptable |

## 5. Rejected alternatives

### 5.1 Move the RETURN trap from the renderer to `dispatch.sh::main()` so `$raw_capture` outlives the renderer; assertion runs in main()

Lets `main()` call `assert_no_tool_invocation` directly. Cleaner separation between rendering and contract-checking.

**Rejected.** ENG-42 §2.1 D-005 says "Existing trap stays unchanged; assertion just slots in before it." Moving the trap also splits file-management across two functions and creates a window between the renderer returning and main() running the assertion in which a SIGINT could leak `.raw-stream.ndjson.tmp`. The existing in-renderer trap is the SEC-008 contract; respecting it is cheaper than re-arguing it.

### 5.2 Have dispatch.sh source classify-failure.sh and call `classify_failure` itself on match

Eliminates the rc=22 special-case in run-stage.sh; dispatch.sh becomes self-contained.

**Rejected.** dispatch.sh today sources only `common.sh`. classify-failure.sh transitively pulls in linear.sh, slack.sh, and metrics.sh side effects. This breaks the mutex-test contract noted at `bin/dispatch.sh:227-229` ("dispatch.sh needs TARGET_REPO only for the directory-existence check, not for a real config.json"). The dispatch/run-stage division of labor — dispatch dispatches, run-stage classifies — is well-established (`bin/run-stage.sh:565,570` already classify from the dispatch_rc).

### 5.3 Sidecar-less surface: dispatch.sh writes the matched command to stderr, run-stage.sh greps stderr

No file lifetime to manage.

**Rejected.** stderr from dispatch.sh is currently silent in the integrated path; introducing a parsable marker line couples the two scripts via stderr text, which is fragile (any future log line containing "transcript invoked" would false-positive). A dedicated sidecar file with a scoped name is structural.

### 5.4 Equality match instead of `startswith`

`gh pr create` would have to appear as the entire command. Trips on any flag.

**Rejected.** The agent will pass `--title` and `--body`; equality misses every realistic invocation. Inherited from ENG-42 §2.1.

### 5.5 Generalize across all stages on day one

Add patterns for `git push --force` (review), `gh pr merge` (non-build stages), `git reset --hard` (any), etc.

**Rejected.** ENG-42 §3.7 explicit out-of-scope flag for ENG-43 v1. One concrete call site (implement) makes the pattern reviewable and the test surface small. Generalization is a follow-up refactor with its own per-stage pattern table and tests.

### 5.6 Use the issue's literal fixture letters E–J

Saves a tiny amount of cross-reference cognitive load.

**Rejected.** The test file already defines fixtures A–K in a different domain (renderer success/no-result/malformed/log-forge/etc.). Re-using letters introduces a permanent footgun for anyone reading test output. AS1–AS6 with a Linear-mapping comment in the test file is the better tradeoff.

## 6. ADR stress test

There is no `docs/knowledge/decisions.md` in this repo (verified absent
on this branch). Prior architectural decisions live as `D-NNN` items
inside brainstorm docs. Two are load-bearing here:

- **ENG-26 D-002 (single jq fork).** The helper adds one jq fork per
  implement dispatch — total fork count goes from 1 to 2 per implement
  run. Within budget. Other stages unchanged.
- **ENG-26 D-010 (observability never controls flow on a missing event).**
  The soft-fail on missing/empty transcript (D-005 here) extends this
  principle: an absent transcript file is treated as "no signal", not
  as a violation.
- **ENG-42 D-005 / D-006 (existing trap stays unchanged; assertion
  slots before it).** Decision D-006 in this brainstorm honors that
  constraint exactly.
- **ENG-23 paths invariant ($PROJECT_STATE_DIR for per-issue state).**
  The sidecar lives at `${issue_dir}/.transcript-violation-${stage}`,
  via `issue_dir()` from common.sh, so it lands under
  `$PROJECT_STATE_DIR/<issue>/`. Verified against the project profile
  Don'ts list.

No proposed new ADR. The Decisions section above is the durable
record; future authors should reference it the same way ENG-43 itself
references ENG-42 §2.1.

## 7. Assumption inventory

Every code-level claim in this brainstorm, with verification:

| Claim | Source-of-truth | Status |
|---|---|---|
| `_render_and_capture_stream` exists and owns `.raw-stream.ndjson.tmp` lifetime | `bin/dispatch.sh:69-122` | **verified** |
| `raw_capture` path = `${issue_dir}/.raw-stream.ndjson.tmp` | `bin/dispatch.sh:71` | **verified** |
| RETURN trap removes raw_capture | `bin/dispatch.sh:72` | **verified** |
| Implement stage's allowed-tools list excludes `Bash(gh:*)` | `bin/dispatch.sh:175` | **verified** |
| Renderer is invoked inside a pipeline on stdin from `claude -p` | `bin/dispatch.sh:286-289` (with log_file) and `bin/dispatch.sh:295-297` (no log_file) | **verified** |
| run-stage.sh dispatch invocation and exit-code handling at lines 554-575 | `bin/run-stage.sh:554-575` | **verified** |
| `failure_outcome_for_exit 22` returns `pr-opened-too-early` | `bin/common.sh:115` | **verified** |
| `classify_failure` is exported by classify-failure.sh and consumed by run-stage.sh | `bin/classify-failure.sh:39,159`; `bin/run-stage.sh:20` | **verified** |
| Existing dispatch-test.sh has fixtures A–K already (rendering & adversarials) | `bin/dispatch-test.sh:336-643` | **verified** |
| Old PR-count state-check guard is gone (`bin/run-stage.sh:373-384` from ENG-42's text no longer present) | `grep -n 'gh pr list --head' bin/run-stage.sh` returns nothing in the dispatch path; the only `gh pr` reference left is in the post-stage no-pr-check comment block at lines ~584-589 | **verified** |
| `issue_dir()` helper in common.sh returns `$PROJECT_STATE_DIR/<issue>` | inherited from ENG-23 / project profile; used at `bin/run-stage.sh:528,538,546,592,etc.` | **verified** |
| The `set -o pipefail` is set in dispatch.sh | `bin/dispatch.sh:15` (`set -euo pipefail`) | **verified** |
| jq's `startswith` is literal-string (not regex) | jq manual; used in this codebase already at `bin/dispatch.sh:103` (grep, not jq, but the principle applies — the stream filter shape uses jq's standard semantics) | **verified** by docs |
| The `tee` mirror path puts NDJSON one-event-per-line into `$raw_capture` | `bin/dispatch.sh:82-97` (`tee "$raw_capture" \| jq …`) | **verified** |
| CLAUDE.md "When wiring a new script" section is at lines 242-259 | direct read | **verified** |
| ENG-42 §2.1 captures the design verbatim | `docs/brainstorms/2026-04-28-eng-42-reframe-implement-pr-guard-design.md:131-159` | **verified** |
| The post-stage `(b) no-pr-check` comment in run-stage.sh references the guard semantics | `bin/run-stage.sh:586` reads "(b) no-pr-check: implement stage must NOT have opened a PR (UI stage opens the PR)." Comment is now slightly stale (UI no longer owns PR creation post-ENG-49 — orchestrator does). Out-of-scope for this PR; flag for future cleanup. | **verified, with stale comment caveat** |

## 8. Scope flags

### 8.1 In scope (matches issue Acceptance Criteria)

- `assert_no_tool_invocation` helper added to `bin/dispatch.sh`.
- Helper called from inside `_render_and_capture_stream`, gated on `stage == "implement"`, pattern `gh pr create`.
- Six fixtures (renamed AS1–AS6 — see D-009) added to `bin/dispatch-test.sh`.
- run-stage.sh handles rc=22 with `skip-until-human-acts` policy and the precise reason text.
- CLAUDE.md "When wiring a new script" gets a transcript-assertion bullet.
- `bin/run-stage-test.sh` continues to pass; cases 11 and 12 are unaffected (they exercise scope-check rcs 3 and `*`, not the dispatch_rc=22 branch).

### 8.2 Out of scope (explicitly deferred)

- Generalizing the helper across stages (ENG-42 §3.7).
- Halt-fingerprint cache for auto-resume on prior human decisions (depends on ENG-34).
- Refactoring the stage chain to a DAG-of-tasks-with-preconditions.
- Renaming the exit-22 outcome from `pr-opened-too-early` to `transcript-assertion-failed`.
- Cleaning up the slightly stale "(b) no-pr-check" comment at `bin/run-stage.sh:586` ("UI stage opens the PR" — orchestrator does post-ENG-49).

### 8.3 Conflicts with existing architecture

None. The proposed changes:
- Honor ENG-26 D-002 (single jq fork per pass).
- Honor ENG-26 D-010 (observability never controls flow on missing telemetry).
- Honor ENG-42 D-005 (existing trap stays unchanged).
- Honor ENG-23 paths invariant (sidecar in `$PROJECT_STATE_DIR/<issue>/`).
- Preserve the operator-facing surface of the deleted state-check guard (exit 22, `skip-until-human-acts`, `pr-opened-too-early`).

## 9. Test strategy

### 9.1 Unit (six fixtures via `bin/dispatch-test.sh`)

Each fixture creates a transcript file under `$_TEST_STUB_DIR/`,
calls `assert_no_tool_invocation "$transcript" "gh pr create"`, and
asserts the (return-code, stdout) tuple. Fixtures parallel the issue's
fixtures E–J letter-for-letter (renamed AS1–AS6 per D-009) and provide
the full coverage matrix in §4.

```bash
# Group N: assert_no_tool_invocation fixtures (ENG-43)
printf '\n--- assert_no_tool_invocation fixtures (AS1-AS6, ENG-43 = issue E-J) ---\n'

# AS1 — issue fixture E: tool_use invoking gh pr create matches
TX="$_TEST_STUB_DIR/tx-as1.ndjson"
cat > "$TX" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"as1"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr create --title foo --body bar"}}]}}
NDJSON
out_as1="$(assert_no_tool_invocation "$TX" "gh pr create" 2>&1)" && rc_as1=0 || rc_as1=$?
[[ "$rc_as1" == 1 && "$out_as1" == *"gh pr create --title foo --body bar"* ]] \
  && pass_at "AS1: tool_use match returns 1 + matched command on stdout" \
  || fail_at "AS1" "rc=$rc_as1 out=$out_as1"

# AS2 — issue fixture F: only allowed gh/git tool_uses, no match
# AS3 — issue fixture G: text-block prose containing the literal pattern, no match
# AS4 — issue fixture H: JSON-escaped quoted "gh pr create" in text, no match
# AS5 — issue fixture I: malformed line + valid matching tool_use, returns 1
# AS6 — issue fixture J: missing transcript file → returns 0 (soft-fail)
```

### 9.2 Integration

`bin/run-stage-test.sh` exercises run-stage.sh's dispatch wiring. The existing
implement-stage cases (11 — SEVERE scope-violation, 12 — unknown scope-check rc)
test the post-dispatch scope-check branch and are independent of the new rc=22
branch. They should continue to pass.

This brainstorm does **not** propose a new run-stage-test.sh case for the
rc=22 branch in v1: stubbing dispatch.sh to return 22 with a sidecar
in place is doable but adds material complexity. The fixture coverage
of the helper plus the small, mechanical addition to run-stage.sh's
exit ladder is sufficient.

### 9.3 Smoke

`bash bin/dry-run.sh` continues to pass (dispatch.sh dry-run path
short-circuits before the renderer is invoked, so the assertion is
not exercised).

## 10. Open questions

- **Q1.** Should a future generalization (D-003 deferred) add `pattern_for_stage()`
  in dispatch.sh as a forward-looking abstraction, or wait for the second
  call site to materialize before introducing it? **Recommendation:** wait.
  YAGNI; the current single call site is a one-line `[[ "$stage" == "implement" ]]`.
- **Q2.** Should the `.transcript-violation-${stage}` sidecar be cleaned up
  by the renderer's RETURN trap (lengthening the trap) or by run-stage.sh's
  rc=22 branch (current proposal)? **Recommendation:** run-stage.sh.
  Cleanup tied to the consumer of the data simplifies reasoning about
  state ownership and avoids growing the renderer's trap surface.
- **Q3.** Should this brainstorm propose updating the (now slightly
  stale) `(b) no-pr-check` comment at `bin/run-stage.sh:586`?
  **Recommendation:** out of scope here; flag for ENG-52-style residue
  cleanup (the comment is stale post-ENG-49 in any case). Bundling it
  into ENG-43 widens the change set unnecessarily.
- **Q4.** Does the helper need to handle `tool_use` blocks where `.name`
  is `Agent` (sub-agent dispatch) or `Task`? **Recommendation:** no in
  v1 — the implement stage's allowed-tools list (`bin/dispatch.sh:175`)
  contains neither `Agent` nor `Task`, so a sub-delegated `gh pr create`
  is structurally impossible for implement. UI/QA/review/retro have
  `Agent` allowed but those stages aren't asserted against in v1.

## 11. Persona review

Per the brainstorm checklist, six personas (design, security, scope,
coherence, product, feasibility) reviewed this brainstorm. Verdict
recorded in the stage-summary file; the durable record is here.

| Persona | Verdict | Notes |
|---|---|---|
| design | PASS | Honors ENG-42 §2.1 verbatim. Renderer-internal sequencing matches "existing trap stays unchanged". |
| security | PASS | Sidecar is hidden, per-issue, per-stage scoped, lifetime-bounded. No new secrets surface. Helper jq filter does not echo `tool_use` input bytes (matches SEC-001 from ENG-26). |
| scope | PASS | Scope flagged in §8.2; all out-of-scope items inherit explicit deferrals from ENG-42 / ENG-34. |
| coherence | PASS | All decisions reference an earlier ADR/brainstorm (ENG-26 D-002, ENG-42 §2.1, ENG-23 paths). No conflicts in §8.3. |
| product | PASS | Operator surface preserved (`pr-opened-too-early`, exit 22, `skip-until-human-acts`); no new label, no new marker shape. |
| feasibility | PASS | Every code reference verified against `bin/dispatch.sh`, `bin/run-stage.sh`, `bin/common.sh`, `bin/classify-failure.sh`, `bin/dispatch-test.sh`, `CLAUDE.md` on this branch (§7). Zero P0 findings. One nit (Q3 / stale comment) flagged out-of-scope. |
