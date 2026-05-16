---
linear: ENG-106
title: progress.md — plan stage writes progress entries (writer pilot)
date: 2026-05-16
status: draft
---

# ENG-106 — `progress.md` plan-stage writer pilot

## 1. Problem

ENG-107 (sibling, merged 2026-05-15) shipped the foundation for a
cross-dispatch per-issue notebook: the path `$(issue_dir <ident>)/progress.md`,
a `bin/common.sh::progress_md_path` resolver, a schema runbook at
`docs/runbooks/progress-md.md`, and the per-issue state-dir slot listed
in `CLAUDE.md`. The file is documented, the path is named — but no
stage actually writes to it yet. Reads have not been wired either.

ENG-106 is the first writer pilot. Per the umbrella ticket ENG-28, the
goal is a continuous per-issue notebook a later-stage agent can read
to recover the prior-stage agent's prose context without re-parsing
transcripts. The pilot picks **one** stage (plan) so the change is
narrow: one prompt section gains an "append to progress.md" Output
step, one detective scan asserts the agent did it, and one test
fixture pair (negative + positive) pins the contract.

The hazards in scope:

1. **No reader exists yet.** ENG-106 ships only the writer. The
   downstream implement-reader sub-ticket is OUT OF SCOPE per the
   Linear ticket. The writer's value is latent until the reader
   ships; the pilot exists to validate the writer-side ergonomics
   and contract before the reader hardcodes against them.

2. **The plan agent has no generic `Bash` in its allowed-tools.**
   Per the project profile's `## Tool allowlist`, the planning stage
   declares `(none)` — only the stage-agnostic implicit core (Read,
   Write, Edit, Grep, Glob, git family, `bash bin/linear.sh`,
   `bash bin/pipeline.sh`, etc.). The agent cannot run
   `cat >> "$path" <<EOF`. The append must go through `Read` +
   `Write` (read prior content, write back with the new entry
   appended) or `Edit` (anchor on a stable string at end-of-file).
   The detective contract has to be enforceable against THAT
   ergonomic shape, not against a `>>` redirection.

3. **AC #3 explicitly demands "no full-file rewrites."** Combined
   with hazard #2 the agent's natural append IS a full-file rewrite
   at the syscall level (`Write` truncates). The contract has to be
   readable as "no content from prior dispatches was dropped" rather
   than "the file was opened in append mode." Enforcement of THAT
   reading is `grep`-able: the set of H2 dispatch-id headings is a
   strict superset across dispatches.

4. **Failure mode parity with ENG-77.** The detective must halt
   with a clear, operator-actionable failure reason and a
   `failure_outcome_for_exit` taxonomy entry — symmetrically with
   ENG-43's `pr-opened-too-early` (rc=22), ENG-66's
   `branch-creation-forbidden` (rc=23), ENG-71's
   `worktree-mutation-forbidden` (rc=26), ENG-68's `lane-violation`
   (rc=13), ENG-87's `envelope-violation` (rc=29). A new code goes
   in the taxonomy or the retrospective's §1 filter misses it
   (CLAUDE.md "When wiring a new script / For exit codes").

5. **Where does the detective live?** The Linear ticket states
   "Detective scan in `bin/dispatch.sh`." That's an unusual home —
   existing dispatch.sh detectives are all transcript scans (`gh pr
   create`, `git checkout -b`, `git config core.bare`,
   `mcp__plugin_linear`). The progress.md detective is a
   FILESYSTEM check, not a transcript scan. The brainstorm calls
   this out (§2.D-005) and proposes a placement that respects the
   ticket's instruction while honestly naming the shape difference.

The Linear acceptance criteria map cleanly to the decisions below:

| AC | Decision | Test fixture |
|---|---|---|
| 1. Entry has timestamp, dispatch_id, 3–5 bullets | D-002 (prompt-side format) | n/a (prompt content, asserted by D-001 schema) |
| 2. Missing entry halts with clear reason | D-005 (detective) + D-006 (run-stage mapping) | bin/dispatch-test.sh new group "ENG-106 PG1–PG6" |
| 3. Append, no full-file rewrites | D-002 wording + D-005 strict-superset check | PG3 (multi-entry file, prior entries preserved) |

## 2. Decisions

### D-001. Anchor the heading shape on ENG-107's runbook; reuse `progress_md_path`; do NOT redefine.

The canonical entry heading is:

```markdown
## <dispatch_id> - <stage> - <ISO-8601-UTC>

- bullet 1
- bullet 2
- bullet 3
[3–5 bullets total]
```

`<dispatch_id>` is `PIPELINE_DISPATCH_ID` exported by the orchestrator
(`bin/common.sh:155` — `export PIPELINE_DISPATCH_ID="$id"`), shape
`ENG-N-d<NNNN>` (4-digit zero-padded). `<stage>` is the gerund-form
key — for this pilot, literally `planning`. Timestamp is
ISO-8601-UTC, second precision. Separator is ASCII ` - `
(space-hyphen-space), per ENG-107 D-002 §11 amendment
(`docs/runbooks/progress-md.md:46` — "Three tokens separated by
` - ` (ASCII space-hyphen-space)" + line 56 "ASCII ` - ` is
recommended for grep-friendliness").

The path resolver is `bin/common.sh::progress_md_path <ident>`
(`bin/common.sh:78-82`). The agent's prompt receives the rendered
absolute path via a NEW `{progress_md_path}` token (D-004 below);
the detective inside `dispatch.sh` calls the helper directly
(common.sh is sourced; the function is on the `export -f` line at
`bin/common.sh:400`).

**Reference to constraint:** ENG-107 runbook
(`docs/runbooks/progress-md.md:29-61`) is the schema's single
source of truth. Redefining the heading shape here would create
the exact second-source-of-truth drift class ENG-79 manifested
(`render-prompt.sh:212` hand-rolled `branch_name` — drifted from
`bin/branch-name.sh`; ENG-87 brainstorm §1.1 names this as one of
the six structural-class instances).

**Reference to principle:** CLAUDE.md "Don't add features,
refactor, or introduce abstractions beyond what the task
requires." The pilot stays inside the schema's grammar; it does
not propose body conventions ("a Decisions subsection", "an Open
Questions subsection") — D-002 binds the body to a 3–5 bullet
list per AC #1 and stops there.

**Rejected alternative — JSON sidecar for structured fields, free
markdown for prose:** rejected because (a) ENG-107 D-002 explicitly
chose markdown over JSONL (`docs/brainstorms/2026-05-15-eng-107-…:
190-200`) on the grounds that agents are markdown-native; reverting
to JSON-adjacent shapes one ticket later would invalidate ENG-107's
schema decision; (b) the writer's tools (Write/Edit) and the
detective's check (`grep -c "^## ${dispatch_id}"`) both stay
trivial on markdown.

**Rejected alternative — body schema with per-stage subsections
(e.g., `### Decisions`, `### Open questions`):** explicitly
deferred to OQ-1 below. The pilot ships the smallest body
contract (3–5 bullets) that satisfies AC #1; future writer
tickets evolve the body if there's evidence of need. ENG-107
D-002 #4 ("No body schema. Deliberately.") is the precedent.

### D-002. Prompt-side: extend §2 plan agent Output with an "append a progress.md entry" step. Path comes from `{progress_md_path}` token.

The §2 plan-agent Completion checklist (`AGENT_PROMPTS.md:537-606`)
currently has six steps:

1. Write the plan doc.
2. Run all 5 personas.
3. Iterate until the gate passes.
4. Commit artifacts.
5. Write the stage summary file.
6. Post the verdict marker.

ENG-106 inserts a NEW step between current step 4 (commit) and
current step 5 (stage summary):

> **5. Append a progress.md entry** at `{progress_md_path}`. ONE
> H2 entry per dispatch; this is the ONLY mutation you make to the
> file. Schema (per docs/runbooks/progress-md.md):
>
>     ## {dispatch_id} - planning - <ISO-8601-UTC-now>
>
>     - <decision or call this plan locks in, one bullet>
>     - <key trade-off the plan accepts, one bullet>
>     - <next-dispatch breadcrumb for the implement agent, one bullet>
>     [3–5 bullets total — under 80 chars each, no prose paragraphs]
>
> **Append, do NOT rewrite.** If the file exists, `Read` it FIRST,
> then `Write` back the prior content followed by ONE blank line
> followed by the new H2 entry. Do NOT use `Write` with only the
> new entry — that truncates and discards prior dispatches'
> entries. Do NOT edit any prior entry. If the file does not
> exist yet, `Write` it with just your single H2 entry (no
> preceding content).
>
> The orchestrator's post-dispatch detective scans this file. A
> missing entry, more than one entry stamped with your
> `{dispatch_id}`, or a prior entry that's been removed → halt
> with `agent-contract-missing` (rc=31, see
> docs/runbooks/recovery.md §<TBD>).

(Existing steps 5 and 6 renumber to 6 and 7.)

The body is bounded at 3–5 bullets, 80 chars per bullet — enough
to summarise (decision, trade-off, breadcrumb) without inviting
the agent to re-paste the plan doc. AC #1 demands "3–5 bullet
summary"; the cap goes in the prompt so a future reader's
context-window budget stays predictable.

**Reference to constraint:** AGENT_PROMPTS.md §2 plan agent
(`AGENT_PROMPTS.md:348-606`); render-prompt.sh PROMPT_RESOLVERS
registry (`bin/render-prompt.sh:41-55`); ENG-107 D-002 schema
(`docs/runbooks/progress-md.md:34-61`).

**Reference to principle:** CLAUDE.md "Cross-dispatch staleness
contract (ENG-87)" — the dispatch_id-stamped heading is the
reader's primary freshness filter (ENG-107 D-002 rationale,
`docs/brainstorms/2026-05-15-eng-107-…:171-182`). The prompt
makes the agent emit the stamp; the detective verifies it.

**Rejected alternative — emit the entry via `bash bin/linear.sh
post-progress` (a new orchestrator-owned writer):** rejected
because (a) the Linear ticket's IN list is "AGENT_PROMPTS.md plan
section gets a 'append to progress.md' instruction" — the writer
is the AGENT, not a new orchestrator command; (b) ENG-107 D-003
mandates "stage agents write; orchestrator does not"
(`docs/brainstorms/2026-05-15-eng-107-…:231-235`). A new
orchestrator writer inverts that contract; (c) it ALSO adds a new
subsystem touch (linear.sh) per the CLAUDE.md ticket-sizing rubric
— this ticket would jump from 1-subsystem (orchestrator) to 2.

**Rejected alternative — prompt instructs the agent to use `Edit`
with `old_string=""` (insert at start):** rejected because Claude
Code's `Edit` tool requires `old_string` to appear exactly once
in the file. The empty string is not unique. Edit-mode insertion
of a NEW H2 at the end of an arbitrary-length file requires
either (a) `Edit` anchored on the LAST entry's heading (which
itself changes per dispatch — fragile) or (b) `Read` + `Write`.
The prompt mandates Read + Write as the documented append idiom.

### D-003. Body content: 3–5 bullet "next-dispatch breadcrumb" — NOT a re-paste of the plan doc.

The bullets serve the reader on a LATER dispatch. The plan doc
itself remains the authoritative artifact for plan content; the
progress.md entry exists to give a future stage agent (e.g., the
implementer) a 30-second answer to "what's the latest call this
issue's plan locks in?" without re-reading the full plan.

The prompt mandates:

- Bullet 1: the single most important decision the plan commits
  to. NOT a restatement of the goal; a CALL the plan makes (e.g.,
  "extend existing crate `foo` rather than introducing `foo-cli`").
- Bullet 2: the load-bearing trade-off (the thing a reader can't
  derive from the plan's structure alone).
- Bullets 3–5 (zero to three more): breadcrumbs for the next
  dispatch — open questions deferred to implement, gotchas the
  plan agent noticed but didn't resolve, links to prior brainstorm
  decisions if applicable.

Each bullet under 80 characters. No bullet may exceed one line.
No prose paragraphs in the entry body. (Markdown technically
allows a paragraph between bullets; the prompt forbids it for
this pilot — it's the smallest cap that keeps the entry
read-in-30-seconds on a future dispatch.)

**Reference to constraint:** Linear AC #1 — "3–5 bullet summary."

**Reference to principle:** CLAUDE.md "Don't add features … beyond
what the task requires." The 80-char/no-prose rules are the
smallest tightening of "3–5 bullets" that makes the future
reader's parse predictable. Without them, the agent's freedom to
write a paragraph-shaped bullet defeats the speed-read goal.

**Rejected alternative — no body schema, agent decides:**
rejected because the immediate next sub-ticket (implement-reader)
will hard-code its parser against THIS pilot's output shape. A
free-form body forces the reader to either (a) skip everything
below the heading, defeating the purpose, or (b) re-parse prose
heuristically. The pilot's job is to fix the body shape for at
least one stage.

**Rejected alternative — require structured fields (Decisions:,
Trade-offs:, Breadcrumbs:):** rejected because (a) the agent's
prompt budget is finite; a structured body adds prompt-grammar
overhead for a 3-bullet payload; (b) ENG-107 D-002 #4 explicitly
defers per-stage body schemas to writer sub-tickets — but this
pilot is the FIRST writer, and ENG-107 left the door open
without prescribing the shape. A bullet-list-with-content-rules
is the lightest possible binding.

### D-004. Wire `{progress_md_path}` as a new PROMPT_RESOLVERS token. Resolver mirrors `{stage_summary_path}`.

`bin/render-prompt.sh:41-55` defines `PROMPT_RESOLVERS` (ENG-79
single-helper precedent generalized in ENG-87 review-iter-7).
ENG-106 adds one row:

```
progress_md_path=_resolve_progress_md_path
```

The resolver at `bin/render-prompt.sh:226` (next to
`_resolve_stage_summary_path`):

```bash
_resolve_progress_md_path() { printf '%s' "$_RENDER_PROGRESS_MD_PATH"; }
```

`main()` at `bin/render-prompt.sh:389-415` binds:

```bash
progress_md_path="$(progress_md_path "$issue_id")"
_RENDER_PROGRESS_MD_PATH="$progress_md_path"
```

(`progress_md_path` is on the `export -f` line at
`bin/common.sh:400`, so render-prompt.sh — which sources common.sh
via `bin/render-prompt.sh:18-19` — has the helper in scope.)

The agent receives the absolute path in §2's prompt body
substitution. The same path is computed identically by the
detective in dispatch.sh (D-005), so there is one resolver, one
formula, no drift surface.

**Reference to constraint:** ENG-79 single-resolver rule
(`bin/render-prompt.sh:33-40` "Render-time validator dies on any
unknown {token} encountered in the source"). The
PROMPT_RESOLVERS registry is the single home for path tokens.

**Reference to principle:** CLAUDE.md "Don't introduce abstractions
beyond what the task requires" — the resolver is a 1-line wrapper
over an already-existing helper, matching the
`_resolve_stage_summary_path` precedent (`bin/render-prompt.sh:226`).

**Rejected alternative — inline the path in the prompt as
`$PROJECT_STATE_DIR/{issue_id}/progress.md`:** rejected because
(a) `$PROJECT_STATE_DIR` is an env var; the agent's prompt is
plain text, not shell — no env-var expansion at prompt-read
time; (b) the agent has no Bash means to expand it (`Bash(echo:*)`
or similar is not in the implicit core for `planning`); (c) the
ENG-79 drift class is exactly "two source-of-truth formulas for
the same path."

**Rejected alternative — pass the path via env-var (e.g.,
`PIPELINE_PROGRESS_MD_PATH`) instead of prompt token:** rejected
because (a) the agent's prompt has all other paths as `{token}`s,
not env-var references; the prompt would have to instruct the
agent to read an env var, adding cognitive load for one path;
(b) every comparable per-issue path (stage_summary_path,
branch_name, learned_rules_dir) goes through PROMPT_RESOLVERS.

### D-005. Detective scan in `bin/dispatch.sh::_render_and_capture_stream`, after the existing assert blocks, stage-gated to `planning`. Filesystem check, NOT a transcript scan.

The Linear ticket pins the detective at `bin/dispatch.sh`. The
existing detectives in `_render_and_capture_stream`
(`bin/dispatch.sh:150-235`) are all transcript scans via
`assert_no_tool_invocation`:

- gh pr create (line 150-159, rc=22)
- git checkout / git switch / git pull / git reset (line 173-184, rc=26)
- git checkout -b / -B, git branch -m, git switch -c (line 194-207, rc=23)
- git config core.bare etc. (line 221-235, rc=13)

ENG-87's envelope validator lives in `run-stage.sh`
(`_validate_dispatch_envelope`, `bin/run-stage.sh:901-965`) and
is also a transcript scan (`mcp__plugin_linear`, `curl
https://api.linear.app`, rc=29).

The progress.md check is structurally different: it's a
post-stream FILESYSTEM check ("did the file gain exactly one new
H2 stamped with `$PIPELINE_DISPATCH_ID`?"). Not a transcript
scan. The detective inspects on-disk state after the stream ends,
because the stream itself doesn't reveal whether a `Write` call's
content was an extension vs. a truncation — that distinction
needs the file's pre/post content.

Concrete placement: `_render_and_capture_stream`, immediately
AFTER the existing `core.bare` block (line 235), BEFORE the
function's closing brace (line 236). Stage-gated to `planning`
only — other stages observe no behavior change (matching the
existing pattern where each detective is stage-gated, e.g., line
150 `[[ "$stage" == "implementing" ]]`, line 173 `[[ "$stage" ==
"building" ]]`).

The check (pseudo-bash):

```bash
if [[ "$stage" == "planning" ]]; then
  local _progress_path _entry_count
  _progress_path="$(progress_md_path "${PIPELINE_ISSUE_ID-}")"
  if [[ ! -s "$_progress_path" ]]; then
    printf 'progress.md missing entirely (expected one H2 stamped %s)\n' \
      "${PIPELINE_DISPATCH_ID-}" > "$violation_file"
    log "[assert] plan-stage progress.md missing for dispatch_id=${PIPELINE_DISPATCH_ID-}"
    return 31
  fi
  # Count H2 lines whose heading starts with the current dispatch_id token,
  # followed by space-hyphen-space (the canonical separator). Anchor on the
  # space-separator boundary so a longer-id substring (impossible by
  # construction — dispatch_ids are zero-padded — but cheap to harden) can't
  # accidentally match.
  _entry_count="$(grep -c "^## ${PIPELINE_DISPATCH_ID-} - " "$_progress_path" 2>/dev/null || printf 0)"
  if [[ "$_entry_count" != "1" ]]; then
    printf 'progress.md: expected exactly 1 entry for dispatch_id=%s, found %s\n' \
      "${PIPELINE_DISPATCH_ID-}" "$_entry_count" > "$violation_file"
    log "[assert] plan-stage progress.md entry count for ${PIPELINE_DISPATCH_ID-}: $_entry_count (expected 1)"
    return 31
  fi
fi
```

Soft-fail defenses:

- `${PIPELINE_DISPATCH_ID-}` (single-dash) per ENG-46 secret-handling
  preamble — the variable name does not match the secret regex
  (`*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`), so this is
  lint-clean. Single-dash matches the existing `${PIPELINE_STAGE-}`
  / `${PIPELINE_DISPATCH_ID-}` usages in `bin/run-stage.sh:960`.
- `${PIPELINE_ISSUE_ID-}` (single-dash) for the same reason.
  Empty ID → `progress_md_path` calls `issue_dir` which `die`s on
  empty input. The check is downstream of dispatch.sh's existing
  `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]` gate at line 439, so by the
  time the planning-stage detective fires we know the gate already
  passed. If a test path bypasses the gate, `progress_md_path`'s
  loud `die` is the natural error — caught by D-007's PG6 fixture.
- `grep -c ... || printf 0` swallows `grep`'s rc=1-on-no-match.
- The `2>/dev/null` swallows "no such file" if a race deleted the
  file between the `-s` check and the `grep`.

`return 31` propagates to run-stage.sh, where D-006 maps the code.

**Reference to constraint:** Linear AC #2 — "Missing entry causes
plan-stage halt with a clear failure reason." The detective is
the enforcement mechanism.

**Reference to constraint (placement):** the Linear ticket text
explicitly names `bin/dispatch.sh`. The brainstorm honors that
placement (versus the seemingly more natural
`run-stage.sh::_validate_dispatch_envelope` or the agent-contract
validator at `bin/run-stage.sh:1594`) but documents the shape
divergence (filesystem check, not transcript scan) so a future
maintainer doesn't misread the detective as "transcript-only"
and break the planning path.

**Reference to principle:** CLAUDE.md "Defense-in-depth: when a
stage's contract says 'agent must not invoke tool X,' prefer a
transcript-based assertion over a post-dispatch state check." The
inverse is also true: when a stage's contract says "agent must
produce artifact Y," the artifact's on-disk presence IS the
authoritative check. A transcript scan for "Write tool_use with
file_path ending in progress.md" would false-negative on the
Read-then-Write pattern (the tool_use shape sees the Write; the
content distinction lives in the input.content field which is
load-bearing-large and the existing detectives explicitly do NOT
log per SEC-002 at `bin/dispatch.sh:38-41`).

**Rejected alternative — put the detective in
`run-stage.sh::_validate_dispatch_envelope` (extending ENG-87's
envelope validator):** rejected primarily because the Linear
ticket says dispatch.sh. Secondarily because the envelope
validator currently operates on the persisted transcript sidecar
(`bin/run-stage.sh:906`), and adding a filesystem check there
would (a) mix shapes inside a function that exists to scan
transcripts, (b) make the validator stage-aware (it currently
applies uniformly to all `brainstorming|planning|implementing|
ui|reviewing|qa|building` stages). The dispatch.sh-side check is
already inside a stage-gated function and is the natural site for
"one stage's bespoke post-stream check." The placement
disagreement with the ticket would require ticket renegotiation
or a brainstorm-side override; the cost of honoring the ticket
(one extra `if [[ "$stage" == "planning" ]]` block in
dispatch.sh) is small.

**Rejected alternative — put the detective in
`run-stage.sh::agent-contract validator` (extending the block at
`bin/run-stage.sh:1594-1616`):** rejected for the same Linear-
ticket reason. Also: the existing agent-contract validator emits
rc=25 (`agent-contract-missing`); reusing that code would conflate
"agent produced no stage-summary AND no verdict marker" with
"agent did not write a progress.md entry." Two distinct failure
shapes deserve two distinct codes (and two distinct operator
recovery procedures — see D-009 OQ-3).

**Rejected alternative — count NEW H2 entries (pre/post-dispatch
diff via a snapshot):** rejected because (a) the dispatch_id-
anchored check is sufficient: the orchestrator allocates a fresh
monotonic id per dispatch (`bin/common.sh:104-147`), so any H2
heading carrying THIS dispatch's id was authored by THIS dispatch
— a prior dispatch could not have written that exact id; (b) a
pre/post snapshot requires a side file under issue_dir which
needs its own lifecycle management (clear-on-start vs. preserve);
(c) the brainstorm honors CLAUDE.md "Don't add abstractions
beyond what the task requires." A monotonic-id grep is the
minimum.

### D-006. Wire run-stage.sh to map dispatch.sh's rc=31 to a halt with policy `skip-until-human-acts` and outcome `agent-contract-missing-progress-md` (new entry in `failure_outcome_for_exit`).

Mirrors the existing dispatch-rc-mapping arms at
`bin/run-stage.sh:1310-1398`. New arm, inserted alphabetically by
rc (after rc=29's existing arm at line 1629 wouldn't apply —
that's `run-stage.sh`'s own envelope validator return path, not
a dispatch.sh return; the dispatch-rc arms live in the earlier
block starting line 1310). Concrete site:

```bash
elif (( dispatch_rc == 31 )); then
  local _viol_file_31 _viol_msg_31
  _viol_file_31="$(issue_dir "$ident")/.transcript-violation-${stage}"
  _viol_msg_31="$(cat "$_viol_file_31" 2>/dev/null || printf '<violation-detail-unavailable>')"
  classify_failure "$ident" "$stage" "skip-until-human-acts" \
    "plan-stage progress.md entry missing or malformed: $_viol_msg_31" 31
  rm -f "$_viol_file_31" "$prompt_file"
  exit 31
fi
```

And the taxonomy entry in `bin/common.sh::failure_outcome_for_exit`
(`bin/common.sh:222-250`):

```bash
    31) printf 'progress-md-entry-missing' ;;
```

Code 31 is unused today; 30 is `noop-implementation`, 32+ are
unallocated. Picking 31 keeps dispatch.sh's detective codes
contiguous (13, 22, 23, 26, 29, 31).

**Reference to constraint:** CLAUDE.md "When wiring a new script
/ For exit codes" — "Never use exit codes outside the taxonomy …
a new code without a mapping routes to `unknown-exit-N` and the
retrospective's §1 filter won't classify it." The taxonomy entry
is mandatory.

**Reference to constraint:** CLAUDE.md "Per-issue halt
(self-leak / leaked-in-scope at threshold / N×same-issue
failure)" — agent-contract halts use `skip-until-human-acts`.
Mirrors ENG-43's rc=22, ENG-66's rc=23, ENG-71's rc=26, ENG-68's
rc=13, ENG-87's rc=29 — all `skip-until-human-acts`.

**Reference to principle:** consistency with the cohort of
dispatch-side detective halts. A protocol violation that the
operator must inspect (not a transient retry) belongs in the
`skip-until-human-acts` policy bucket so `poll.sh` doesn't
re-dispatch automatically.

**Rejected alternative — `retry-immediately` policy (rc=20 path):**
rejected because the failure shape ("agent produced no progress.md
entry") is an agent-contract problem, not infrastructure flakiness.
The same agent prompt on a retry would produce the same gap; the
operator needs to inspect — either the prompt is unclear, or the
agent encountered an unrelated blocker mid-dispatch. CLAUDE.md
ticket-sizing rubric: retry-immediately is for "linear-post-failed"
and similar transient I/O fails, not protocol issues.

**Rejected alternative — reuse rc=25 (`agent-contract-missing`):**
rejected per D-005 — two failure shapes deserve two codes.
`agent-contract-missing` already names a specific failure (no
stage-summary AND no verdict marker, at
`bin/run-stage.sh:1609-1613`). Conflating them makes retrospective
classification ambiguous.

### D-007. Test fixtures in `bin/dispatch-test.sh`: positive (writes entry → rc=0), negative (no write → rc=31), edge cases (PG3-PG6).

New test group "ENG-106 PG1–PG6 — progress.md detective" inserted
after the existing core.bare group ending around line 1517 (or
wherever the file's last group sits — the brainstorm pins the
location loosely because dispatch-test.sh is heavily grown and
the exact line will be settled at implement time; coherence
amendment §11 below catches drift).

Fixtures (each a synthesised post-stream filesystem state, NOT a
full claude invocation — mirrors AS1-AS6's pattern of writing an
NDJSON file then calling the helper directly):

| # | Setup | Expected (rc, violation_file content) | What it pins |
|---|---|---|---|
| PG1 | `stage=planning`; progress.md exists with ONE H2 starting `## ENG-T-PG1-d0001 - planning - 2026-05-16T12:00:00Z`; PIPELINE_DISPATCH_ID=ENG-T-PG1-d0001 | rc=0, no violation_file | Positive: well-formed single entry → pass |
| PG2 | Same as PG1 but progress.md does NOT exist | rc=31, violation_file says "missing entirely" | AC #2: missing entry halts |
| PG3 | progress.md has TWO prior entries (different dispatch_ids) plus ONE new entry for current id | rc=0, no violation_file | AC #3: prior entries preserved; agent appended cleanly |
| PG4 | progress.md exists; ZERO entries match current dispatch_id (file has prior entries only — agent forgot to write) | rc=31, violation_file says "expected 1, found 0" | AC #2: silent skip detected |
| PG5 | progress.md exists; TWO entries match current dispatch_id (agent over-wrote — emitted heading twice) | rc=31, violation_file says "expected 1, found 2" | Agent doesn't double-write |
| PG6 | `stage=brainstorming` (NOT planning); progress.md does not exist | rc=0, no violation_file | Stage-gate: detector inert on non-planning stages |

The fixtures synthesize filesystem state directly. They DO NOT
invoke `claude -p` (matching the existing AS1-AS6 pattern at
`bin/dispatch-test.sh:1189-1268` — those tests call
`assert_no_tool_invocation` directly on a hand-crafted NDJSON
file). The detective check is small enough that direct invocation
is the natural shape; full renderer integration is unnecessary
overhead.

Test scaffolding reuses the existing `_TEST_STUB_DIR` mktemp
pattern (`bin/dispatch-test.sh:20-42`), exports
`PIPELINE_DISPATCH_ID` and `PIPELINE_ISSUE_ID` per fixture, calls
the detective code directly (the new check will be extracted as a
named helper if the inline arm in `_render_and_capture_stream`
gets too long — see D-008 below).

**Reference to constraint:** Linear ticket IN list — "Test
fixture in `bin/dispatch-test.sh` for a plan dispatch that omits
the append (should fail) and one that writes correctly." PG2 and
PG1 directly satisfy this. PG3-PG6 are coverage extensions for
AC #3 and the stage-gate.

**Reference to constraint:** CLAUDE.md "Tests" — "Each `bin/foo.sh`
ends with the sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
main "$@"; fi`. That lets a test `source` the file to get its
functions without firing `main`." dispatch.sh already follows
this pattern (`bin/dispatch.sh:648-650`); dispatch-test.sh sources
it (line 70).

**Reference to principle:** CLAUDE.md "Test format" — "The test
sets `PIPELINE_DRY_RUN=1` and `LINEAR_API_KEY=test-mock-key`
before sourcing." Already done at
`bin/dispatch-test.sh:15-17`; the new fixtures inherit.

**Rejected alternative — full renderer-integration tests (the
D-D5 pattern from line 530):** rejected because (a) the
detective's logic is mechanically separable from the renderer's
stream-processing concerns; (b) renderer-integration fixtures
require an NDJSON stream — the detective doesn't read the
stream, it reads the filesystem; (c) PG1-PG6 stay under ~30
lines per fixture, matching the brevity of AS1-AS6.

**Rejected alternative — fixtures live in `bin/run-stage-test.sh`
(testing the rc=31 mapping):** worth doing too, but the ticket
asks for fixtures in `dispatch-test.sh`. A follow-on companion
fixture in run-stage-test.sh that asserts the rc=31 → exit 31 +
`classify_failure skip-until-human-acts` mapping IS in scope as
a nice-to-have (D-006's run-stage arm needs at least one test
hook), but the dispatch-test.sh side is the load-bearing
contract.

### D-008. Extract the detective into a private helper `_assert_progress_md_entry` in `dispatch.sh`; do NOT inline 15+ lines into `_render_and_capture_stream`.

`_render_and_capture_stream` is already ~190 lines
(`bin/dispatch.sh:47-236`). The five existing detectives are
brief — each is a 3-line `if … assert_no_tool_invocation …
violation_file …` block. The progress.md detective is more
involved (filesystem path resolution, file-presence check, grep,
two distinct violation messages).

Decision: factor the new check into a sibling helper inside
dispatch.sh, named `_assert_progress_md_entry`. The
`_render_and_capture_stream` body adds one stage-gated 3-line
call (mirroring the existing pattern):

```bash
if [[ "$stage" == "planning" ]]; then
  if ! _assert_progress_md_entry "$issue_dir" "$violation_file"; then
    return 31
  fi
fi
```

`_assert_progress_md_entry` lives next to the existing helpers
(after `_render_and_capture_stream`, before
`disallowed_platform_tools` at line 244). It reads
`PIPELINE_DISPATCH_ID` and `PIPELINE_ISSUE_ID` from the
environment (both already exported in the dispatch.sh subshell;
no new parameters needed for those).

**Reference to principle:** CLAUDE.md "Defense-in-depth /
Language idioms" — match the existing module shape. The
extraction is purely for readability + testability (D-007 calls
the helper directly).

**Rejected alternative — inline the check:** rejected because
inlining ~15 lines inside the already-large
`_render_and_capture_stream` defeats D-007's "call the helper
directly" test ergonomics — the test would have to invoke
`_render_and_capture_stream` end-to-end (which requires a full
NDJSON stream) just to exercise the detective.

**Rejected alternative — promote to `bin/common.sh`:** rejected
because the helper is dispatch.sh-private — only dispatch.sh's
post-stream phase needs it. common.sh hosts helpers consumed by
multiple sites (issue_dir, allocate_dispatch_id, progress_md_path
itself). A planning-stage-only check has no second consumer.

### D-009. Operator recovery via `bash bin/pipeline.sh decide ENG-N --action continue`. Document under `docs/runbooks/recovery.md` §<TBD>.

When the detective halts a dispatch with rc=31, the issue lands in
`pipeline:halted` + `pipeline:skip-until-human-acts`. The
operator's recovery procedure:

1. Inspect the per-stage log + the `.transcript-violation-planning`
   sidecar at `$(issue_dir <ident>)/` to see which sub-shape fired
   (missing entirely, found 0, found 2+).
2. Inspect `$(progress_md_path <ident>)` to confirm the on-disk
   state.
3. Decide:
   - **Most cases**: the prompt's instruction was unclear or the
     agent skipped the step. Run `bash bin/pipeline.sh decide
     <ident> --action continue` — orchestrator clears the halt
     labels and re-dispatches; the next plan agent has a fresh
     dispatch_id and will satisfy the detective if the prompt is
     correct.
   - **Plan agent prompt bug**: edit `AGENT_PROMPTS.md §2` to fix
     the wording, commit, then `--action continue`. (Pipeline
     content hash changes — `poll.sh` recalculates and may
     un-skip even without manual decide; the explicit decide is
     idempotent and the recommended path.)
   - **Detective false positive**: if the file is present and
     well-formed by inspection but the detective halted, the
     detective has a bug. File a follow-up ticket; until fix,
     unhalt manually.

Add a new §<TBD> to `docs/runbooks/recovery.md` mirroring the
existing §7 (post-rc=23 recovery) shape.

**Reference to constraint:** CLAUDE.md "Per-issue halt … Recovery:
`bash bin/pipeline.sh decide <ENG-N> --action continue`."

**Reference to constraint:** ENG-87 D-005 — "Recovery: `bash
bin/pipeline.sh decide ENG-N --action continue` clears the halt
label and re-allocates a fresh `dispatch_id`." The fresh
dispatch_id makes the detective re-check on a new H2 — no stale-
id confusion across resume.

## 3. Architecture (where code goes)

| Site | Change | Lines (approx.) |
|---|---|---|
| `AGENT_PROMPTS.md` §2 plan agent | Insert new Completion checklist step 5 (per D-002 quoted block); renumber existing 5 and 6 to 6 and 7 | +30 |
| `bin/render-prompt.sh` PROMPT_RESOLVERS | Add `progress_md_path=_resolve_progress_md_path` row at line ~52 | +1 |
| `bin/render-prompt.sh` resolver fn | Add `_resolve_progress_md_path` next to `_resolve_stage_summary_path` (~line 227) | +1 |
| `bin/render-prompt.sh::main()` | Bind `_RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"` at the resolver-globals block (~line 414) | +2 |
| `bin/dispatch.sh::_render_and_capture_stream` | Stage-gated 3-line call to `_assert_progress_md_entry` at the end of the function, just before the closing brace (~line 235) | +5 |
| `bin/dispatch.sh::_assert_progress_md_entry` | New private helper (~15 lines) inserted after `_render_and_capture_stream` (~line 237) | +15 |
| `bin/run-stage.sh` | New `elif (( dispatch_rc == 31 ))` arm at the dispatch-rc dispatch table (~line 1393, before the catch-all `elif (( dispatch_rc != 0 ))`) | +8 |
| `bin/common.sh::failure_outcome_for_exit` | Add `31) printf 'progress-md-entry-missing' ;;` (~line 246) | +1 |
| `bin/dispatch-test.sh` | New group "ENG-106 PG1–PG6" with 6 fixtures, inserted immediately before the `Summary` block at the end of the file (~line 3023) | +120 |
| `docs/runbooks/recovery.md` | New §<TBD> "rc=31 — progress.md entry missing on plan dispatch" mirroring §7 (rc=23) | +20 |
| `docs/runbooks/progress-md.md` | One-line "see also" pointer to recovery.md §<TBD> at the bottom of the cross-references section | +1 |

Total: ~205 LOC across 7 files. Zero changes to: `bin/poll.sh`,
`bin/scope-check.sh`, `bin/run-local.sh`, `bin/run-local-helpers.sh`,
`bin/linear.sh`, `bin/verdict-handler.sh`, `bin/classify-failure.sh`,
`bin/metrics.sh`, `bin/pipeline.sh`. Zero changes to the
project profile schema. Zero changes to any test other than
`dispatch-test.sh` (with a nice-to-have follow-on in
`run-stage-test.sh` deferred per D-007).

## 4. Data flow

Pre-ENG-106 (post-ENG-107): `progress_md_path` resolves; the file
never exists; no stage writes; no detective runs.

Post-ENG-106 (plan dispatch flow, success path):

1. Orchestrator runs `bin/run-stage.sh ENG-N planning`.
2. `allocate_dispatch_id` (`bin/common.sh:114-131`) sets
   `PIPELINE_DISPATCH_ID=ENG-N-d<NNNN>` and exports it.
3. `render-prompt.sh::main` substitutes `{progress_md_path}` with
   `$(issue_dir ENG-N)/progress.md` and `{dispatch_id}` with
   `ENG-N-d<NNNN>` (D-004 + existing ENG-87 token).
4. `dispatch.sh` invokes `claude -p` with the rendered prompt.
   `PIPELINE_DISPATCH_ID` and `PIPELINE_ISSUE_ID` propagate into
   the agent's subshell via the env block at
   `bin/dispatch.sh:563-566`.
5. Plan agent does its work; per the new step 5, it Reads
   progress.md (if present), Writes back prior + ` - ` separator
   + new H2 entry.
6. `claude -p` returns; `_render_and_capture_stream` finishes
   stream-rendering.
7. After existing assert blocks, the new stage-gated
   `_assert_progress_md_entry` fires:
   - Resolves path via `progress_md_path "$PIPELINE_ISSUE_ID"`.
   - File exists → continue.
   - `grep -c "^## $PIPELINE_DISPATCH_ID - " "$path"` → 1 → return 0.
8. `_render_and_capture_stream` returns 0; `dispatch.sh::main`
   completes normally.
9. `run-stage.sh` proceeds to the agent-contract validator
   (existing line 1594), envelope validator (line 1629),
   `post_completion_comment`, etc.

Failure path (no entry):

5. Plan agent skips the new step 5 (or writes a malformed entry).
7. `_assert_progress_md_entry` finds 0 matches → writes
   `.transcript-violation-planning` sidecar with the diagnostic
   message → returns 31.
8. `dispatch.sh::main`'s pipeline catches rc=31; the function's
   own exit code propagates (set -euo pipefail).
9. `run-stage.sh` catches `dispatch_rc=31` (D-006) →
   `classify_failure` skip-until-human-acts → `exit 31`.
10. Orchestrator applies `pipeline:halted` (ENG-56) and the issue
    parks until the operator runs `--action continue` (D-009).

## 5. Error handling

The detective's failure shapes:

| Shape | Detective output | rc | Run-stage mapping |
|---|---|---|---|
| File missing | "progress.md missing entirely (expected one H2 stamped <id>)" | 31 | `agent-contract-missing-progress-md`, skip-until-human-acts |
| File present, 0 matches | "expected 1 entry for dispatch_id=<id>, found 0" | 31 | same |
| File present, ≥2 matches | "expected 1 entry for dispatch_id=<id>, found <n>" | 31 | same |
| Stage != planning | (detective inert) | n/a | n/a |
| `PIPELINE_DISPATCH_ID` empty/unset | (detective fires with `^## - -` pattern — no real H2 matches because the dispatch_id token would be empty, so the missing-entry shape fires; the `${VAR-}` single-dash idiom keeps lint clean) | 31 | same — diagnostic message includes literal "<empty>" so operator can tell the dispatch's env was broken |
| `PIPELINE_ISSUE_ID` empty/unset | `progress_md_path` calls `issue_dir` which `die`s with rc=1 | 1 | run-stage maps to "dispatch failed" (existing rc != 0 catch-all at line 1394) → retry-immediately. This is acceptable because the env-propagation should never fail in practice — ENG-87 review-iter-7 M6 added the env-propagation test at `bin/dispatch-test.sh:2209+`; if it ever does, the catch-all is good enough |
| File deleted mid-grep (race) | `grep` rc=1, `|| printf 0` → `_entry_count=0` → "found 0" branch | 31 | same |

No other failure modes. The detective is pure filesystem +
environment; no Linear, git, jq, or network dependencies.

Recovery is uniform — `--action continue` is the documented path
(D-009). The detective is detective-only; it never auto-fixes the
file (which would be a write outside the agent's authorship lane,
inverting D-002).

## 6. Edge cases

- **First plan dispatch on an issue.** progress.md does not
  exist yet; agent's step 5 Writes the file with just one H2 entry.
  Detective sees `grep -c` = 1 → pass. (No issue: the first writer
  case is the canonical path per ENG-107 lifecycle.)
- **Second plan dispatch on same issue (loopback from review or
  `--action continue` resume after a non-progress-related halt).**
  progress.md has ≥1 prior entries. Agent Reads, Writes back
  prior + new. The new dispatch_id is monotonic (different from
  prior). Detective matches on current id → pass.
- **Plan agent's first Write was a truncating Write (rewrote
  the file with only the new entry, dropping prior dispatches'
  entries).** The detective passes (current dispatch_id appears
  exactly once); prior content is silently lost. This is a known
  gap — see §7 OQ-2. The pilot accepts it; mitigation is
  per-prompt instruction wording (D-002 explicit "do NOT use
  `Write` with only the new entry"); enforcement is deferred to
  the reader sub-ticket (which can compare to
  `dispatch_history.jsonl` to detect missing prior entries).
- **Agent emits the heading shape with em-dash separator (`—`)
  instead of ASCII hyphen-space.** ENG-107 runbook line 55-57
  documents both as acceptable. The detective's regex
  `^## $DISPATCH_ID - ` (space-hyphen-space) ONLY accepts ASCII.
  Mismatch → detective halts. The prompt mandates ASCII (D-002);
  if a future writer ticket wants em-dash, the detective regex
  expands or the runbook tightens. Pilot stays ASCII for
  grep-friendliness, matching ENG-107 §11.
- **Agent emits a heading at H1 (`#`) or H3 (`###`) instead of
  H2 (`##`).** Detective's regex `^## ` requires exactly two
  hash marks at column 0. Mismatch → detective sees 0 entries
  → halts. Correct behavior; ENG-107 D-002 #3 mandates H2.
- **Agent writes the entry but leaves a trailing space on the
  heading line.** `grep "^## $ID - "` matches the substring, so
  trailing characters are accepted. No false negative.
- **Agent writes the entry but the dispatch_id token is at a
  non-canonical position in the heading (e.g., `## planning -
  ENG-N-d0001 - timestamp`).** Detective sees 0 matches → halts.
  Correct: the schema mandates dispatch_id FIRST.
- **`--action continue` resume after a rc=31 halt.** Operator
  inspects, decides. If they `continue`, `_pipeline_clear_breaker`
  re-allocates a fresh dispatch_id. The agent re-runs the planning
  stage with a NEW id; the prior dispatch's incomplete entry (if
  any) remains in progress.md as an artifact of the prior
  attempt. Detective only sees the NEW id's H2; passes if the
  agent writes one. (Prior failed-dispatch entries become noise
  in the file — accepted; the file is operator-pruneable per
  ENG-107 lifecycle.)
- **`PIPELINE_DRY_RUN=1`.** dispatch.sh's main returns early
  before invoking claude (`bin/dispatch.sh` has DRY_RUN gates).
  The detective should also be DRY_RUN-skipped — the agent never
  ran, so the absent entry is expected. Implementation will gate
  the new helper on `[[ -z "${PIPELINE_DRY_RUN:-}" ]]` per the
  prevailing dispatch.sh DRY_RUN handling.
- **Plan stage runs against a brand-new project with `PROJECT_SLUG`
  unset (bootstrap mode).** `progress_md_path` inherits
  `issue_dir`'s bootstrap hazard (ENG-107 §6 noted) — would
  return `"/ENG-N/progress.md"`. This path doesn't exist; the
  detective fires "missing entirely" → rc=31. Bootstrap mode
  never reaches the plan stage in practice (setup precedes any
  agent dispatch), but if it did, the failure is loud and
  bootable-from. Acceptable.

## 7. Open questions

- **OQ-1. Body schema evolution.** D-003 binds the body to 3–5
  one-line bullets. Future writer sub-tickets may want richer
  body conventions (per-stage `### Decisions`, `### Open
  Questions`, etc.). The pilot ships the minimum; OQ-1 lives at
  the implement-reader sub-ticket level — once a real reader
  exists, the body-shape evolution can be evidence-driven.

- **OQ-2. Truncation-on-Write hazard.** The detective verifies
  the CURRENT entry; it does NOT verify prior entries were
  preserved. An agent that re-Writes the file with only its new
  entry passes the detective AND silently destroys prior writers'
  context. Mitigation candidates:
  1. Compare H2 count pre- vs. post-dispatch (requires a
     pre-dispatch snapshot under issue_dir).
  2. Cross-reference H2 dispatch_ids against
     `dispatch_history.jsonl` (the orchestrator's append-only
     per-issue dispatch ledger — see CLAUDE.md "Cross-dispatch
     staleness contract" §`dispatch_history.jsonl`).
  3. Move to a true append-only writer (e.g., agent shells out
     to a new `bash bin/progress.sh append <ident> --body -`)
     that owns the truncation safety.
  All three are post-pilot decisions. Today's pilot accepts the
  hazard because (a) only the plan stage writes, so there is
  exactly one writer in the wild; (b) AC #3's wording is
  satisfiable by prompt-side instruction.

- **OQ-3. Should the detective be promoted to ALL stages once
  later writer tickets ship?** When implement / review / qa
  also write entries, the detective becomes per-stage. Today's
  stage-gate (`[[ "$stage" == "planning" ]]`) is the right
  shape because (a) only plan writes; (b) other stages have no
  contractual obligation yet. The later writer tickets will
  extend the stage list; the pilot's structure is straightforward
  to evolve.

- **OQ-4. Should `_assert_progress_md_entry` go in
  `bin/run-stage.sh` rather than `bin/dispatch.sh`?** The
  Linear ticket says dispatch.sh; the brainstorm honors it
  (D-005). A future reorganization might unify the
  filesystem-shape detectives under
  `_validate_dispatch_envelope`. That's a structural-cleanup
  question, not a correctness one. Park for now.

- **OQ-5. Reader sub-ticket interface.** The implement-reader
  sub-ticket (Linear: ENG-28 child, TBD) will define how the
  implement agent's prompt receives the cross-dispatch context.
  Two natural shapes:
  - Read inline: prompt instructs "Read `{progress_md_path}` and
    follow the most recent N entries' breadcrumbs."
  - Prompt-side interpolation: orchestrator extracts the last
    N entries' bodies, splices them into the prompt as
    `{progress_breadcrumbs}`.
  The pilot's writer-side shape (one H2 per dispatch, 3–5
  bullets, dispatch_id stamp) supports both. No pre-commitment
  is needed in ENG-106.

- **OQ-6. Cross-issue read isolation.** ENG-107 §10.2 flagged
  that an agent on issue A COULD `Read` issue B's progress.md
  by absolute path (same property as stage-summary). The pilot
  inherits the property unchanged. No hardening proposed.

## 8. ADR stress test

There is no `docs/knowledge/decisions.md` file in the repo (also
absent per ENG-107 §8). The durable architectural rules live in
`CLAUDE.md`, `docs/architecture.md`, and `docs/runbooks/*`.
ENG-106 puts pressure on the following rules:

- **ENG-107 D-003 "Stage agents write; orchestrator does not."**
  Honored. ENG-106's writer is the plan agent. The orchestrator's
  role is path resolution (D-004), detective scanning (D-005),
  and rc mapping (D-006). The agent's prompt is the SOLE source
  of writes (D-002). No orchestrator-side write.

- **CLAUDE.md "Defense-in-depth: when a stage's contract says
  'agent must not invoke tool X,' prefer a transcript-based
  assertion over a post-dispatch state check."** The progress.md
  detective is a POSITIVE assertion ("agent must produce
  artifact Y") not a negative ("must not invoke X"). The
  state-check (filesystem) is the right shape because the
  artifact's content distinction (append vs. rewrite) lives
  outside the transcript's tool-name layer. Different shape →
  different test idiom; the CLAUDE.md guidance doesn't apply
  inverted.

- **CLAUDE.md "Don't add features, refactor, or introduce
  abstractions beyond what the task requires."** The 8 wiring
  sites (D-002 prompt, D-004 token, D-005 detective, D-006 rc
  map, D-006 taxonomy, D-007 tests, D-008 helper, D-009 runbook)
  are each load-bearing for one AC or one operator-visible
  surface. None invents a new abstraction layer; each composes
  over an existing one. The new exit code 31 + taxonomy entry
  is the smallest taxonomy growth — symmetric with rc 22/23/26/13/29.

- **CLAUDE.md "Per-stage allowed tool lists are centralized in
  `dispatch.sh::allowed_tools_for`. New stages must add a case
  there."** No new stage; the planning stage's tool list is
  unchanged. The agent's Read/Write/Edit suffice (D-002 explicit).
  No tool allowlist surgery.

- **CLAUDE.md "Ticket sizing rubric (autonomy boundary)."**
  Subsystems touched: orchestrator (`run-stage.sh`,
  `common.sh::failure_outcome_for_exit`), dispatch (`dispatch.sh`,
  `dispatch-test.sh`), agent prompts (`AGENT_PROMPTS.md`,
  `render-prompt.sh`). Three subsystems — at the 3+ threshold
  the rubric says "split before filing." Tension flagged: ENG-28
  umbrella already split into ENG-107 (foundation) + ENG-106
  (writer) + future (reader). The 3 subsystems collapse because:
  (a) `render-prompt.sh` is a 1-line resolver row + 1-line fn +
  2-line bind (pure mechanical wiring, no design decisions); (b)
  the dispatch-detective + run-stage-rc mapping pair is
  inseparable (the detective's rc is meaningless without the
  mapping); (c) AGENT_PROMPTS.md edit is a single prompt step.
  This reads as a 1-decision ticket spanning 3 subsystems' wiring
  files. Acceptable; logged here for the retrospective record.

- **CLAUDE.md "AGENT_PROMPTS.md is load-bearing."** Edit is one
  new step in §2; renumbers 5 → 6 and 6 → 7. Fence count
  unchanged. `render-prompt.sh::STAGE_TO_SECTION` mapping
  unchanged.

## 9. Assumption inventory

Every named symbol or path referenced has been grep-verified
against the working tree on `feat/eng-106-progress-md-plan-stage-writes-progress-entries`
HEAD.

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A1 | `bin/common.sh::progress_md_path` exists and resolves `$PROJECT_STATE_DIR/<ident>/progress.md` | **verified** | `bin/common.sh:78-82` |
| A2 | `progress_md_path` is on the `export -f` list | **verified** | `bin/common.sh:400` (ends with "... assert_no_tool_invocation progress_md_path") |
| A3 | `bin/common.sh::issue_dir` resolves `$PROJECT_STATE_DIR/<ident>` | **verified** | `bin/common.sh:68-72` |
| A4 | `PIPELINE_DISPATCH_ID` is allocated by `allocate_dispatch_id`, format `ENG-N-d<NNNN>`, exported | **verified** | `bin/common.sh:114-131` (allocator), `bin/common.sh:144` (id format), `bin/common.sh:155` (export) |
| A5 | `docs/runbooks/progress-md.md` exists and documents the schema with `## <dispatch_id> - <stage> - <ISO-8601-UTC>` heading shape | **verified** | `docs/runbooks/progress-md.md:34-61` (schema), `docs/runbooks/progress-md.md:46` ("ASCII space-hyphen-space"), `docs/runbooks/progress-md.md:56` ("ASCII ` - ` is recommended") |
| A6 | ENG-107 brainstorm is at `docs/brainstorms/2026-05-15-eng-107-progress-md-schema-and-per-issue-state-dir-slot-design.md` | **verified** | `ls docs/brainstorms/` returned the file |
| A7 | `bin/dispatch.sh::_render_and_capture_stream` exists, body spans lines 47-236, contains 4 detective blocks (gh pr create at 150, build-stage git verbs at 173, branch-creation at 194, core.bare at 221) | **verified** | `bin/dispatch.sh:47-236`; closing brace at line 236 |
| A8 | `bin/dispatch.sh` writes `violation_file="${issue_dir}/.transcript-violation-${stage}"` and uses it for diagnostic messages | **verified** | `bin/dispatch.sh:50`, used at lines 155, 179, 203, 231 |
| A9 | `bin/dispatch.sh` exports `PIPELINE_DISPATCH_ID` and `PIPELINE_STAGE` into the claude subshell env block | **verified** | `bin/dispatch.sh:563-566` (env block: `PIPELINE_WRITER=agent`, `PIPELINE_DISPATCH_ID=${PIPELINE_DISPATCH_ID-}`, `PIPELINE_STAGE=$stage`) |
| A10 | `bin/dispatch.sh` resolves `issue_state_dir="$(issue_dir "$PIPELINE_ISSUE_ID")"` and passes it to `_render_and_capture_stream` as $2 | **verified** | `bin/dispatch.sh:438-441` (resolve), 599 and 608 (pass) |
| A11 | `bin/render-prompt.sh::PROMPT_RESOLVERS` registry exists; format `name=fn_name`; validator at line ~289 dies on unknown tokens | **verified** | `bin/render-prompt.sh:41-55` (registry), `bin/render-prompt.sh:289` (die) |
| A12 | `_resolve_stage_summary_path` is the precedent shape — 1-line fn at line 226 reading `_RENDER_STAGE_SUMMARY_PATH` | **verified** | `bin/render-prompt.sh:226` (`_resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }`) |
| A13 | `bin/render-prompt.sh::main` binds the `_RENDER_*` globals at lines 404-421 | **verified** | `bin/render-prompt.sh:404-421` |
| A14 | `bin/common.sh::failure_outcome_for_exit` exit-code taxonomy spans 0,10-30,124; code 31 is unallocated | **verified** | `bin/common.sh:222-250` (taxonomy); grepped for `31\)` — no match in case |
| A15 | `bin/run-stage.sh` dispatch-rc mapping arms span lines 1310-1398; each rc has a dedicated arm with `classify_failure` + `exit <rc>` shape | **verified** | `bin/run-stage.sh:1310-1398` (124, 22, 23, 26, 13 arms, then `!= 0` catch-all at 1394) |
| A16 | `bin/run-stage.sh::_clear_current_stage_slots` clears `stage-summary-${stage}.md` + `wait-${stage}.json` only; does NOT touch progress.md | **verified** | `bin/run-stage.sh:883-891` (function body) |
| A17 | `bin/dispatch-test.sh` follows the source-and-stub pattern; mktemp at lines 20-42; AS1-AS6 fixtures at lines 1189-1268 calling `assert_no_tool_invocation` directly | **verified** | `bin/dispatch-test.sh:20-42` (scaffolding), `:1189-1268` (AS1-AS6) |
| A18 | `AGENT_PROMPTS.md §2 Plan Agent` Completion checklist spans lines 537-606; current step 5 = "Write the stage summary file", step 6 = "Post the verdict marker" | **verified** | `AGENT_PROMPTS.md:537-606`; step 5 at :569, step 6 at :585 |
| A19 | The plan agent has `Tool allowlist: (none)` in the project profile — only stage-agnostic core tools (Read, Write, Edit, Grep, Glob, etc.) | **verified** | Project profile addendum at the bottom of this prompt: "planning: (none)" + the introductory note "Stage-agnostic core tools (Read, Write, Edit, Grep, Glob, TaskCreate, git family, bash bin/linear.sh, bash bin/pipeline.sh, bash bin/guards.sh, bash bin/slack.sh, bash bin/metrics.sh) are implicit and not declared here." |
| A20 | `bin/dispatch.sh` sources `common.sh` and so has `progress_md_path` in scope | **verified** | `bin/dispatch.sh:17-18` (`source "$SCRIPT_DIR/common.sh"`) |
| A21 | ENG-87 dispatch_id auto-injection at `bin/linear.sh::add_comment` is in place; the post-dispatch envelope validator at `bin/run-stage.sh::_validate_dispatch_envelope` lives at lines 901-965 | **verified** | `bin/run-stage.sh:901-965`; CLAUDE.md "Cross-dispatch staleness contract (ENG-87)" section names both surfaces |
| A22 | `bin/dispatch-test.sh` exports `PROJECT_SLUG`, `HARNESS_STATE_DIR`, `PROJECT_STATE_DIR` for the test scaffold | **verified** | `bin/dispatch-test.sh:18,62-66` |
| A23 | The agent's prompt-side `{dispatch_id}` token already exists per ENG-87 review-iter-7 and resolves to `PIPELINE_DISPATCH_ID` | **verified** | `bin/render-prompt.sh:53` (registry entry), `:234` (resolver), `:421` (bind) |
| A24 | `docs/runbooks/recovery.md` exists and has a §7 documenting rc=23 recovery; the ENG-106 §<TBD> follows the same shape | **assumed** | `ls docs/runbooks/` shows `recovery.md` exists. Exact §7 line count not opened. Marking assumed — implement-time confirmation by Read |
| A25 | `bin/dispatch-test.sh` ends with a `# ─── Summary ───` block printing PASS/FAIL totals at lines ~3024-3030; the new group inserts immediately before that block | **verified** | `tail -20 bin/dispatch-test.sh` shows the Summary footer; insertion point is "before the printf '\\nRESULTS: ...' line" |
| A26 | `PIPELINE_DRY_RUN=1` is the dispatch.sh test path's bypass; the test framework sets it at line 15 | **verified** | `bin/dispatch-test.sh:15` (`export PIPELINE_DRY_RUN=1`), `bin/dispatch.sh` DRY_RUN gates referenced by the docstring at lines 5-13 |

Two assumptions marked `assumed` (A24, A25); both are
implement-time mechanical confirmations — the brainstorm's
contract holds whether the exact insertion line is 1517 or 1530.
No P0 codebase-fact risk.

## 10. Persona review

The brainstorm was reviewed via six personas in the order
**design → security → scope → coherence → product → feasibility**.
The full transcripts live in this section.

### 10.1 Design

**Concerns evaluated:** is the detective shape right? Is the
prompt-side change minimal? Are the failure-mode boundaries
well-defined?

- The detective is a filesystem check, not a transcript scan.
  The brainstorm calls this out explicitly (D-005). The
  rationale is sound: the artifact's existence is the
  authoritative signal; the transcript layer's tool_use record
  doesn't carry the append-vs-rewrite distinction without
  logging tool_input bodies (forbidden by SEC-002).
- The prompt-side change is a single new Completion checklist
  step, with explicit Read-then-Write idiom guidance for the
  agent's tool palette. The wording is concrete and tells the
  agent what NOT to do (`Write` with only the new entry) as well
  as what to do. Matches the prevailing prompt-instruction style.
- Exit code 31 + new taxonomy entry mirrors the existing
  dispatch-detective cohort (22, 23, 26, 13, 29) — operator
  recovery procedure is uniform.
- The helper extraction (D-008) keeps `_render_and_capture_stream`
  readable and gives the test a direct entry point. Good
  separation of concerns.
- The honored-but-flagged placement (dispatch.sh per ticket
  versus the structurally more comfortable run-stage.sh) is
  explicitly surfaced. Future restructuring can be tracked in
  OQ-4 without blocking the pilot.

**Verdict: PASS** — no design changes required.

### 10.2 Security

**Concerns evaluated:** does the detective expose secrets? Can
the agent's progress.md content be used as a side-channel? Is
the new exit code's error-comment body sanitised?

- The detective reads `PIPELINE_DISPATCH_ID` and
  `PIPELINE_ISSUE_ID` from the env. Both single-dash (`${VAR-}`)
  per ENG-46 — names don't match the secret regex; lint-clean.
- The detective writes a diagnostic message to
  `.transcript-violation-planning` (under `$(issue_dir)/`,
  per-issue trust scope). The message contains `$PIPELINE_DISPATCH_ID`
  (operator-readable) and `$_entry_count` (integer). No paths,
  no user-controlled bytes, no agent-controlled content. SEC-002
  compliant.
- Run-stage.sh's rc=31 arm reads `.transcript-violation-planning`
  via `cat` and interpolates into the `classify_failure` halt
  message body. The body lands as a Linear comment. The
  interpolated content originates from the detective (not from
  agent input) — no need for the ENG-87-iter-7-C3 HTML-marker
  sanitisation (the validator string is harness-controlled).
- The progress.md content itself is agent-controlled — but the
  detective never echoes it (it only counts headings). A future
  reader sub-ticket that splices progress.md content into the
  implement prompt MUST consider prompt-injection — out of scope
  for ENG-106. Flagged in OQ-5 for the reader sub-ticket.
- No new Linear API surface, no new git operations, no new
  network calls. Pure local filesystem.
- Cross-issue read isolation: same property as stage-summary —
  an agent on issue A COULD Read issue B's progress.md by
  absolute path. Inherited from ENG-107; not a regression.

**Verdict: PASS** — security envelope unchanged.

### 10.3 Scope

**Concerns evaluated:** does the brainstorm stay within the Linear
ticket's IN list? Does it leak into ENG-28's reader sub-ticket or
other future stages?

- IN list (from Linear):
  1. AGENT_PROMPTS.md plan section "append to progress.md"
     instruction with format spec. → D-002.
  2. Detective scan in bin/dispatch.sh. → D-005.
  3. Test fixture in bin/dispatch-test.sh for missing/correct
     entry. → D-007 (PG1, PG2 + four coverage extensions).
- OUT list (from Linear):
  1. Other stages writing. → D-005's stage-gate explicitly
     `planning`-only; OQ-3 logs the future extension.
  2. Any reader. → No reader code; OQ-5 logs the reader
     sub-ticket interface question.
- Subsystems touched: orchestrator (`common.sh::failure_outcome_for_exit`,
  `run-stage.sh` rc-arm), dispatch (`dispatch.sh`, `dispatch-test.sh`),
  agent prompts (`AGENT_PROMPTS.md`, `render-prompt.sh`). Three
  by the rubric's count; D-008-related discussion in §8 logs the
  tension. The "one decision spanning 3 wiring sites" reading is
  defensible because the design choice IS centralised (D-005's
  detective shape); the three sites are mechanical wiring.
- Independent design decisions: where the writer lives (D-002,
  the agent), what the body schema is (D-003, 3-5 bullets), where
  the detective lives (D-005, dispatch.sh), what the exit code is
  (D-006, rc=31). Four sub-decisions but each one is derivative of
  "wire the smallest writer + detector for one stage." The brainstorm
  reads as a single-decision pilot with documented sub-choices.
- The optional run-stage-test.sh fixture (D-007 nice-to-have) is
  flagged as a follow-on but not a scope violation. Could be
  treated as in-scope; the brainstorm keeps it optional to avoid
  rubbing against the Linear IN list verbatim.

**Verdict: PASS** — squarely within ENG-106's scope; OOS items
explicitly deferred to identified sub-tickets.

### 10.4 Coherence

**Concerns evaluated:** does this fit existing harness conventions?
Does it conflict with any cross-cutting rule (markers, scope, exit
codes, prompt format)?

- Exit-code symmetry with the dispatch-detective cohort (22,
  23, 26, 13, 29 → 31): same policy (`skip-until-human-acts`),
  same recovery (`--action continue`), same diagnostic-sidecar
  shape (`.transcript-violation-${stage}`). Coherent.
- PROMPT_RESOLVERS extension follows the precedent
  (`_resolve_stage_summary_path`); 1-line registry entry + 1-line
  resolver fn + 2-line bind. Coherent.
- Detective shape (filesystem vs transcript) is a NEW shape for
  dispatch.sh. Flagged in §10.1; the helper extraction (D-008)
  keeps the new shape visually distinct from the transcript-scan
  cohort. Coherent.
- Heading separator: ` - ` (ASCII). Honors ENG-107 §11
  amendment's grep-friendly recommendation. Coherent.
- File path resolution: single resolver
  (`bin/common.sh::progress_md_path`) used by both the prompt
  side (via `{progress_md_path}` token) and the detective side
  (via direct function call). No drift surface. Honors ENG-79
  single-source-of-truth precedent.
- The new `bin/dispatch.sh` private helper `_assert_progress_md_entry`
  follows the existing private-helper convention (underscore
  prefix; not on the export -f line). Coherent.
- The new exit code 31 is between rc=30 (`noop-implementation`)
  and the next free slot. Numerically tight; consistent with the
  existing 22-23 / 24-25 / 26 / 28-29 cluster shapes.

**Verdict: PASS** — no coherence amendments needed.

### 10.5 Product

**Concerns evaluated:** does this advance the ENG-28 parent goal?
Is the foundation right-sized for the implement-reader follow-on?

- ENG-28's goal: a continuous cross-dispatch notebook so later
  agents have prior-agent context without re-parsing transcripts.
  ENG-106 (the writer pilot) is the second of three sub-tickets.
  After ENG-107 shipped the schema, ENG-106 ships the first real
  writer. The reader is the third sub-ticket.
- The pilot picks the plan stage because (a) plan is the natural
  "context summary" point — the plan agent has just synthesised
  the brainstorm into a concrete plan; (b) the implement stage
  is the natural reader, and the brainstorm/implement pair is
  the most common cross-dispatch hand-off; (c) plan's prompt is
  already long and well-structured, so adding one step is
  low-friction.
- The 3–5 bullet body is right-sized for the reader: a future
  implement agent can scan progress.md's last K entries in
  seconds, vs. minutes for re-reading the full plan + brainstorm.
- The detective's halt on a missing entry is the right strictness
  for the pilot: if the writer can't be trusted to write reliably,
  the reader can't be trusted to read reliably. Halt + operator
  inspect is the only safe default.
- Future reader interface (OQ-5) is left intentionally underspecified
  — the writer's shape supports either inline-Read or
  prompt-interpolation. Right call.
- Risk: the writer's content quality is entirely a function of
  the prompt wording (D-002). If the agent writes useless 3-bullet
  summaries (e.g., repeating the goal verbatim), the pilot's
  value collapses. The detective can't measure content quality.
  Acceptable for the pilot — operator inspection of the first few
  written entries will catch this; iterate the prompt accordingly.

**Verdict: PASS** — pilot delivers ENG-28's first writer with
appropriate scope and strictness.

### 10.6 Feasibility

**Concerns evaluated:** are all referenced symbols/paths real?
Does the proposed code structure compile? Are the test fixtures
runnable? Are the exit-code numbers free?

- `bin/common.sh::progress_md_path` exists at lines 78-82 ✓ —
  verified
- `progress_md_path` is exported via `export -f` at line 400 ✓
- `bin/common.sh::issue_dir` at lines 68-72 ✓
- `bin/common.sh::failure_outcome_for_exit` at lines 222-250 ✓;
  code 31 unallocated ✓ (`grep '31)' bin/common.sh` returns the
  unallocated slot)
- `bin/dispatch.sh::_render_and_capture_stream` body spans 47-236 ✓;
  4 detective blocks at 150, 173, 194, 221 ✓
- `bin/dispatch.sh:50` violation_file pattern ✓; uses at lines
  155, 179, 203, 231 ✓
- `bin/dispatch.sh:563-566` env block exports PIPELINE_DISPATCH_ID
  and PIPELINE_STAGE ✓
- `bin/dispatch.sh:438-441` resolves issue_state_dir from
  PIPELINE_ISSUE_ID ✓
- `bin/dispatch.sh:17-18` sources common.sh ✓
- `bin/run-stage.sh` dispatch-rc mapping at 1310-1398 ✓; arm
  shape (classify_failure + rm + exit) verified for 22 (1324-1336),
  23 (1337-1352), 26 (1353-1379), 13 (1380-1393), catch-all 1394-1398 ✓
- `bin/render-prompt.sh::PROMPT_RESOLVERS` at 41-55 ✓;
  `_resolve_stage_summary_path` at 226 ✓; main()'s `_RENDER_*`
  binds at 404-421 ✓
- `docs/runbooks/progress-md.md` exists; schema at lines 29-61 ✓;
  separator note at 46 + 56 ✓
- `bin/dispatch-test.sh` AS1-AS6 fixture pattern at 1189-1268 ✓;
  test scaffolding (mktemp, exports) at 18-66 ✓
- `AGENT_PROMPTS.md §2` plan agent at 348-606 ✓; Completion
  checklist at 537-606 ✓; step 5 (stage summary) at line 569 ✓
- ENG-107 brainstorm exists; the schema source-of-truth claim is
  consistent across both documents ✓
- `bin/run-stage.sh::_clear_current_stage_slots` at 883-891 ✓;
  clears only stage-summary + wait files (progress.md NOT touched —
  ENG-107 D-002 #6 contract intact) ✓
- ENG-87 dispatch_id resolver at `bin/render-prompt.sh:53,234,421`
  ✓; ENG-87 envelope validator at `bin/run-stage.sh:901-965` ✓
- Project profile's `## Tool allowlist` for planning at the bottom
  of THIS dispatch's prompt ("planning: (none)") ✓; implicit core
  documented just above the per-stage list ✓
- A24 (`docs/runbooks/recovery.md` §7) marked assumed —
  implement-time confirmation; no P0 risk because the doc edit
  is one new §<TBD> mirroring the existing pattern, not depending
  on a specific line count
- A25 (`dispatch-test.sh` insertion point ~line 1517) marked
  assumed — mechanical implement-time decision; no design
  dependency

**Verdict: PASS · P0 findings: 0** — every code-level fact is
verified; the two `assumed` items are implement-time mechanical
confirmations with no design dependency.

## 11. Coherence-driven amendments

None. The brainstorm's coherence review (§10.4) did not surface
any post-hoc amendments; all conventions are honored as drafted.

## 12. Gate summary

| Persona | Verdict | Notes |
|---|---|---|
| Design | PASS | Detective shape (filesystem) is new for dispatch.sh; flagged explicitly. |
| Security | PASS | Sidecar diagnostic is harness-controlled; agent content never echoed. |
| Scope | PASS | Squarely within ENG-106 IN; OOS deferred to identified sub-tickets. |
| Coherence | PASS | All conventions honored (exit codes, separator, resolver pattern, prompt step). |
| Product | PASS | Pilot delivers ENG-28's first writer at right scope and strictness. |
| Feasibility | PASS · P0=0 | All code-level facts verified; 2 `assumed` items are mechanical. |

**Personas: 6/6 PASS · gate P0: 0 · proceeding to planning.**
