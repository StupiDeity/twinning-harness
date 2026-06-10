---
linear: ENG-156
title: Surface sandbox denials as a first-class signal — phased detective + new halt reason
date: 2026-06-10
status: draft
---

# Surface sandbox denials as a first-class signal — phased detective (Phase A log-only, Phase B contract-halt)

## 1. Overview (and the load-bearing surprise)

Five dispatches in a 72-hour window in mid-May 2026 (ENG-130 / 115 / 124 / 125,
multi-version) had sandbox denials buried inside their per-stage
`.envelope-transcript-<stage>.ndjson` sidecars. Nobody noticed until ENG-125's
denial converged to a hard rc=31 (`progress-md-entry-missing`) and the
operator went digging. The denials are real, recurring, and silent —
they live exactly *one* file away from being a first-class signal but
the orchestrator currently drops them.

ENG-155 (merged 2026-05-19) shipped the `--add-dir "$issue_state_dir"`
fix that resolves *one* class of denial (the agent's progress.md +
stage-summary writes outside the worktree cwd). It did NOT address the
broader structural gap: **denials of any other shape — bash-classifier
rejections, `--add-dir`-but-not-quite-far-enough sandbox blocks, future
CLI tightening — still vanish into the sidecar and get garbage-collected
on the next successful dispatch.**

**The load-bearing surprise:** the harness already has every piece it
needs to surface these denials. The transcript is persisted
(`.envelope-transcript-<stage>` per ENG-87, kept until the next clean
dispatch). The denial events have a deterministic JSON shape (`user`
message → `tool_result` content → `is_error: true`). The metrics stream
(`events.jsonl`) is a free-form append-only log that already carries
heterogeneous events (`stage-end`, `dispatch-resource-sample`,
`worktree-mutated-by-agent`, `plan_json_missing`). A new `sandbox_denial`
event row is one `metrics.sh` invocation. The status dashboard already
aggregates by `event ==` predicates (`show_resource_baseline`,
`show_metrics`). The plumbing is all there; this ticket connects it.

The actually-hard call is **when** to promote the signal from
observability to a halt. Halting on iteration 1 risks blocking every
incidental probe-and-recover an agent does legitimately (read a file
the sandbox blocks, fall back, succeed). Halting *never* leaves the
agent free to silently regress against the contract the orchestrator
established at render time. The ticket's phased shape — A (log-only)
ships first, B (halt on `PROMPT_RESOLVERS`-matched paths) ships after
≥7 days of real signal — is the correct trade-off; the brainstorm
absorbs it as the load-bearing decision rather than something to
re-litigate.

## 2. Forensic ground truth — what the denials actually look like

A claude stream-json transcript carries denials in the `user` message
following a denied `tool_use`:

```jsonl
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/Users/.../learned-rules/harness/brainstorm.md"},"id":"toolu_abc"}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":"ls in '/Users/.../learned-rules/harness/brainstorm.md' was blocked. For security, Claude Code may only list files in the allowed working directories for this session: ...","is_error":true}]}}
```

Two canonical denial bodies seen in the wild (per the Linear ticket
Context and live during this very brainstorm — see §10 Assumption
Inventory):

| Substring | Class | Source |
|---|---|---|
| `may only list files in the allowed working directories` | sandbox-path | CLI directory sandbox (the class ENG-155 widened) |
| `This command requires approval` | bash-classifier | Per-invocation auto-mode classifier rejection |

The `result` event ALSO carries a `permission_denials` array
(`bin/dispatch.sh:62` SEC-002 — currently allowlisted *out* of the
usage file), but it is missing on SIGTERM kills (ENG-65 D-003 has
already documented "result event lost on watchdog kill" as a real
operational mode). The `is_error: true` tool_result events
accumulate per-call and survive partial transcripts; they are the
robust source. The `permission_denials` array is a useful
cross-check on clean exits but cannot be the sole input.

On a successful dispatch, the entire `.envelope-transcript-<stage>`
sidecar is removed at `bin/run-stage.sh:1860`
(`rm -f "$(issue_dir "$ident")/.envelope-transcript-${stage}"`).
That is why nobody noticed: the evidence is wiped clean before any
human ever looks at it.

## 3. Scope (and what the ticket explicitly carves out)

**IN** (from the Linear ticket Scope section):

- Phase A: post-dispatch `tool_result.is_error:true` scan of
  `.envelope-transcript-<stage>` (sibling of ENG-87's
  `_validate_dispatch_envelope` in `bin/run-stage.sh`).
- Phase A: one `events.jsonl::event=sandbox_denial` row per dispatch
  with at least one matching denial, carrying `dispatch_id`, `stage`,
  `count`, `signatures` (normalised token list), `paths`,
  `claude_version`.
- Phase B (≥7 days post-Phase A): promote to
  `halt sandbox-contract-violation` when a denied path matches one
  produced by `PROMPT_RESOLVERS` (the harness contract told the agent
  to write there). Incidental probes stay log-only.
- Register `sandbox-contract-violation` in
  `bin/pipeline-events.json::halt_reasons` so
  `bash bin/pipeline.sh event verdict halt --reason sandbox-contract-violation`
  validates. **The registry entry ships with Phase A** so operators
  can manually halt an issue with this reason during the ≥7-day
  Phase A shakedown (e.g., on operator-driven inspection of a
  status.sh row that looks like a real contract drift); Phase B
  automates the detective-triggered halt against the same reason
  token. This is the ticket's documented phased shape (AC #1 +
  AC #2 + registry ship in Phase A; AC #3 detective auto-fire ships
  in Phase B).
- `bin/status.sh` gains a `show_sandbox_denials` section: "Sandbox
  denials (last 7d)" bucketed by `claude_version + stage`.

**OUT** (also from the ticket — explicitly):

- **Retrospective consumption** of the new signal — separate ticket
  (retrospective-broadening).
- **Path-allowlist widening** — covered by ENG-155 (already shipped)
  and any future `--add-dir` follow-ups.
- **CLI version pinning** — ENG-155's documented OUT.

**Flagged additions caught during brainstorm — surfaced, not silently
expanded** (see §5 Open Questions for the decision):

- Whether to ALSO surface `result.permission_denials[]` as a
  cross-check on clean exits (OQ-1).
- Whether the `claude_version` field should be sourced from
  `claude --version` (extra ~10ms fork per dispatch) or from a
  future stream-json `system.init.version` field claude does not
  yet emit (OQ-2).
- Whether Phase B's `PROMPT_RESOLVERS`-path-matching should anchor to
  resolved STRINGS (the values rendered into the prompt) or token
  NAMES (`{progress_md_path}`-style). Strings are the harness contract
  surface; tokens are stable across worktree relocations. OQ-3.
- The deferred retrospective-consumer ticket carries its own scope.
  Flagged here, NOT broadened (OQ-4).

## 4. Decisions

### D-001 — Phase A detective in `bin/run-stage.sh`, sibling of `_validate_dispatch_envelope`

**Decision.** Add a new function `_emit_sandbox_denial_metric ident
stage` in `bin/run-stage.sh`, called from the same post-dispatch site
as `_validate_dispatch_envelope` (lines 1843-1862). The new function:

1. Returns 0 (no-op) when the sidecar is missing/empty — fail-open,
   matching `_validate_dispatch_envelope`'s `[[ -s "$sidecar" ]] ||
   return 0` shape.
2. jq-scans `.envelope-transcript-<stage>` for `type=="user"` messages
   whose `content[]` carries `type=="tool_result"` and
   `is_error == true`.
3. For each match, extracts the `content` text (the denial body),
   matches it against an in-script signature table, and aggregates:
   - `count` (total denied tool_results)
   - `signatures` (set of normalised tokens, e.g.
     `sandbox-path,bash-classifier`)
   - `paths` (set of file paths the agent attempted, extracted from
     the PRECEDING `assistant.tool_use` joined by `tool_use_id`)
4. Emits **one** `events.jsonl` row when count > 0:
   `bash metrics.sh sandbox_denial "$ident" "$stage" detected 0 \
   "count=N signatures=token1,token2 paths=… claude_version=…"`
5. Returns 0 always (Phase A is observability-only).

**Why this is the structural fit.** Mirrors ENG-87's
`_validate_dispatch_envelope` exactly (same sidecar, same jq idiom,
same site) but DIFFERENT axis: the envelope validator scans
`assistant.tool_use` for forbidden Bash patterns; the new detective
scans `user.tool_result` for `is_error: true` content. Two scans, one
file, one mental model for operators. The `metrics.sh` event-name
schema is open (`bin/metrics.sh:67` — `event` is a free string), so
adding `sandbox_denial` requires no schema migration.

**Why one row per dispatch (not per denial).** Per-denial rows would
blow up `events.jsonl` cardinality (a planning dispatch with 20
sandbox probes would emit 20 rows; the retrospective's `events.jsonl`
read becomes 20× costlier per dispatch). Aggregating to one row per
dispatch matches the granularity of `dispatch-resource-sample` and
`stage-end` (also one-per-dispatch). The `notes` blob carries the
multiplicity (`count=N`).

**Rejected alternative.** *Inline the detective into
`dispatch.sh::_render_and_capture_stream` alongside the existing
transcript-scan detectives (ENG-43 / ENG-66 / ENG-68 / ENG-109 /
ENG-155 D-003).* Rejected because:

1. Those detectives all halt the dispatch (return non-zero rc). The
   Phase A detective is observability-only — it must NOT halt. Co-
   locating a non-halting detective with halting siblings invites
   "why is this one different" drift on future edits.
2. The renderer runs inside the dispatch subshell; emitting a
   `metrics.sh` row there double-counts on the K=2 concurrency path
   (the parent run-stage.sh ALSO emits stage-end). Cleaner to keep
   the new emission alongside the parent's existing post-dispatch
   surface.
3. `_validate_dispatch_envelope` already runs on the persisted
   sidecar in run-stage.sh, after dispatch.sh has exited. Two
   detectives on the same sidecar at the same site is the obvious
   shape.

**Rejected alternative.** *Source denial data from
`result.permission_denials[]` instead of `tool_result.is_error:true`.*
Rejected as SOLE source because `permission_denials` is absent on
SIGTERM kills (ENG-65 D-003) — the dispatches most likely to be
denial-rich (long-running, late-iteration) are also the dispatches
most likely to lose the result event. `tool_result.is_error:true`
accumulates incrementally and survives partial transcripts. Use
`permission_denials` as a cross-check on clean exits — see OQ-1.

### D-002 — Phase A signature table: TWO normalised tokens, version-agnostic substring match

**Decision.** Hardcode a 2-entry table in `bin/run-stage.sh` (next to
`_emit_sandbox_denial_metric`):

```bash
# Match in order; first hit wins. Substrings are CLI-stable across the
# 2.1.142-2.1.144 cluster the ticket Context section names; future CLI
# versions may rotate the prose — claude_version field in the emitted row
# lets the retrospective bucket and retire stale entries.
SANDBOX_DENIAL_SIGNATURES='
sandbox-path=may only list files in the allowed working directories
bash-classifier=This command requires approval
'
```

`signatures` field in the emitted notes blob is a comma-separated set
(deduped). Two reasons for the version-agnostic substring shape:

1. The ticket Context names exactly these two phrases as observed in
   2.1.142 / 2.1.143 / 2.1.144. Substring (not regex) is the minimum
   viable match.
2. Future CLI versions WILL rotate the prose. `claude_version` is
   captured in every emitted row so the retrospective and ad-hoc
   inspections can detect "signature went silent post-version-X" and
   the operator can update the table.

`paths` field is best-effort: extract the `assistant.tool_use.input.file_path`
or `assistant.tool_use.input.command` of the PRECEDING tool_use,
joined on `tool_use_id`. If neither extraction succeeds, `paths` is
empty (`paths=`). Phase B's path-match path-tolerant fallback is
documented in D-004.

**Why hardcode (vs config-driven).** The signatures are CLI-internal
strings; treating them as operator-tunable invites a config that
nobody updates. Hardcoded with explicit version-bucketing telemetry is
the lowest-overhead shape that still gives operators a signal-decay
indicator.

**Rejected alternative.** *Regex match.* Rejected as premature — the
two observed phrases have no variability, and regex compilation
inside jq's `--arg`-bound string mode is awkward to test. If the
substring shape ever underfits (e.g., new CLI version uses
`may only access files in …`), promote that signature to regex in the
follow-up.

**Rejected alternative.** *Match on `is_error: true` alone, no
signature classification — emit ALL tool denials.* Rejected because
not every `is_error: true` is a sandbox denial. `Read` on a missing
file emits `is_error: true` with content `<tool_use>file does not
exist</tool_use>` — that's a normal probe-and-recover, not a sandbox
contract drift. The signature filter is what makes this signal
operationally useful rather than noise-dominated.

### D-003 — `claude_version` resolution: one-shot `claude --version` per dispatch

**Decision.** In `bin/dispatch.sh::main`, immediately before the
`cmd+=(--allowed-tools "$tools")` line that constructs the `claude -p`
argv, run a best-effort `claude --version 2>/dev/null` and export the
result as `PIPELINE_CLAUDE_VERSION`. The Phase A detective reads
`${PIPELINE_CLAUDE_VERSION-}` when emitting the metric row; absent →
literal `claude_version=unknown`.

**Why one-shot per dispatch (vs static across pipeline ticks).** A
claude CLI update mid-day flips the version mid-dispatch-sequence
(`gh extension install` semantics — the binary is replaced atomically
on next exec). Resolving at dispatch start means the metric row's
version reflects the version actually invoked. The fork is ~10ms and
falls under dispatch.sh's existing pre-claude budget (the `gtime` /
`gtimeout` setup already takes longer).

**Why not from stream-json.** Claude's `system.init` event carries
`session_id` and `model` but NOT CLI version
(`bin/dispatch.sh:94-95`'s renderer enumerates the fields). If a
future claude version embeds it, switch the detective to read it
from the sidecar — but until then, the shell fork is the only
source.

**Rejected alternative.** *Cache across ticks via
`$PROJECT_STATE_DIR/.claude-version`.* Rejected because the cache
invalidation rule (file mtime vs binary mtime) is more code than the
shell fork it replaces. The 10ms is dwarfed by the dispatch's wall
time (60-min brainstorm budget; ENG-65).

**Rejected alternative.** *Make `claude_version` optional and skip
when unresolvable.* Rejected — the retrospective's first signal-decay
analysis NEEDS every row to carry a version (even `unknown`) so the
"all rows since version X go silent" pattern is detectable. Empty
version field breaks the bucket aggregation.

### D-004 — Phase B halt: PROMPT_RESOLVERS-resolved STRING match, halt reason `sandbox-contract-violation`

**Decision (Phase B, ≥7 days post-Phase A).** Promote the Phase A
detective to halt the dispatch with rc=29
(`envelope-violation` per `failure_outcome_for_exit`) when a denied
path matches a string value RESOLVED by `PROMPT_RESOLVERS` for the
current dispatch. The halt reason in the Linear comment body is
**`sandbox-contract-violation`** (new entry in
`pipeline-events.json::halt_reasons`).

**Mechanism.** In `bin/render-prompt.sh::main`, after the
`resolve_block_tokens` pass produces the rendered prompt, persist
the FULL map of `resolver_token -> resolved_value` to
`$(issue_dir <ident>)/.rendered-paths-<stage>` (one
`token<TAB>value` line per resolver that returned a non-empty path-
shaped value). Persist only path-shaped resolvers — `progress_md_path`,
`stage_summary_path`, `learned_rules_dir`, `brainstorm_file`,
`plan_file`, `plan_json`. Skip non-path resolvers (`issue_id`,
`date`, `slug`, etc.).

The Phase B detective:

1. Runs only if the resolved-paths file exists (Phase A dispatches
   without this file fall through to Phase-A-only behavior — soft
   migration).
2. For each `paths=…` entry extracted in §D-001, checks whether the
   path string CONTAINS (substring) any of the resolved values.
3. On match: emit `events.jsonl::event=sandbox_denial` row WITH
   `outcome=contract-violation` (vs `detected`); post a halt comment
   via `bash bin/linear.sh add-comment <ident> <body>` carrying
   `<!-- pipeline: verdict result=halt reason=sandbox-contract-violation -->`;
   write `$violation_file` naming the matched token and path; return
   rc=29.
4. On no-match (incidental denials): Phase-A behavior preserved
   (one log-only metric row).

**Why STRING match (not TOKEN match).** The harness contract surface
is the rendered prompt the agent receives. The agent sees absolute
paths, not `{progress_md_path}` placeholders (those are
substituted-and-gone by dispatch time). Matching on the resolved
string captures the contract regardless of how it was encoded in
AGENT_PROMPTS.md. Token-name matching would require re-rendering and
maintaining a parallel token map at detective time.

**Why halt reason `sandbox-contract-violation` (vs reuse
`dispatch-envelope-violation`).** Per ENG-155 D-004 precedent
(reusing rc=29 across detectives with the sidecar string as
disambiguator), the EXIT CODE is reused — but the LINEAR HALT
REASON is distinct because the operator-facing diagnosis differs:
- `dispatch-envelope-violation` → agent bypassed `bin/linear.sh`
  (fix the agent prompt to use the chokepoint).
- `sandbox-contract-violation` → orchestrator's contract told the
  agent to write `<path>`, sandbox denied it (fix the
  `--add-dir` / project-profile / tool-allowlist, not the agent).
The retrospective's §1 filter buckets by halt-reason token in the
Linear comment body; distinct reasons → distinct retrospective
attention.

**SECURITY — halt comment body must be statically composed** (ENG-87
review-iter-7 Critical 3 precedent at `bin/run-stage.sh:1054`). The
Phase B halt comment body MUST consist of hardcoded prose + the
fixed marker `<!-- pipeline: verdict result=halt
reason=sandbox-contract-violation -->`. The matched `token` name
(closed enumeration — one of the six path-shaped PROMPT_RESOLVERS
names) and the matched `dispatch_id` (orchestrator-generated, regex-
shape `ENG-N-d<NNNN>`) are SAFE to interpolate. The denied PATH
string (agent-controlled, extracted from `tool_use.input.file_path`)
is **NOT SAFE for the comment body** — it could carry an embedded
`<!-- pipeline: verdict result=pass -->` literal that hijacks
`parse_pipeline_marker` (ENG-87 review-iter-7 Critical 3). Write the
denied path to the `.transcript-violation-<stage>` sidecar
(operator-read, never parsed by `parse_pipeline_marker`); name the
token only in the Linear body. If a future enrichment must
interpolate the path, apply the ENG-87 sanitiser:
`path_safe="${path//<!--/<\\!--}"` and wrap in triple-backticks (the
parse_pipeline_marker stripper removes code spans pre-grep).

**Why register in `pipeline-events.json::halt_reasons` (registry
validation).** `bin/pipeline.sh event ENG-N verdict halt --reason
sandbox-contract-violation` validates the token at write time
(`bin/pipeline-events.json:10-21`). Without the registry entry,
the operator's manual halt command would refuse. The registry
addition is one line.

**Rejected alternative.** *Halt on ANY denial (no
`PROMPT_RESOLVERS` gate) in Phase B.* Rejected by the ticket scope
("Incidental agent probes stay log-only"). Agents legitimately
probe-and-recover (try to read a file, sandbox blocks it, fall back
to inline reasoning) — halting on every such probe would block
~every dispatch. The `PROMPT_RESOLVERS` gate is the structural
discriminator between "agent freelanced into the sandbox" and "the
harness's own contract is broken."

**Rejected alternative.** *Use a brand-new rc=32
`sandbox-contract-violation`.* Rejected per ENG-155 D-004 precedent
— a new rc demands coordinated edits to `failure_outcome_for_exit`,
`classify-failure.sh`, the retrospective filter, and CLAUDE.md's
failure-mode quick-reference. The Linear halt-reason token already
gives operators the diagnosis; rc=29 + sidecar matched-string is
the established disambiguator pattern.

### D-005 — `bin/status.sh::show_sandbox_denials` aggregation, last 7 days, bucketed by version + stage

**Decision.** Add a new section function in `bin/status.sh`
mirroring `show_resource_baseline` (`bin/status.sh:368-381`):

```bash
show_sandbox_denials() {
  section "Sandbox denials (last 7d, by claude_version + stage)"
  local ev="$PROJECT_STATE_DIR/metrics/events.jsonl"
  [[ -f "$ev" ]] || { printf '  %s(no events.jsonl)%s\n' "$C_DIM" "$C_RST"; return 0; }
  local cutoff
  cutoff="$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  jq -r --arg cutoff "$cutoff" '
    select(.event == "sandbox_denial" and .ts >= $cutoff)
    | (.notes // "") as $n
    | ($n | capture("claude_version=(?<v>[^ ]+)").v // "?") as $ver
    | ($n | capture("signatures=(?<s>[^ ]+)").s // "?") as $sigs
    | [$ver, .stage, $sigs] | @tsv
  ' "$ev" 2>/dev/null \
  | sort | uniq -c | sort -rn \
  | awk '{ printf "  %4s× v=%-12s stage=%-12s sigs=%s\n", $1, $2, $3, $4 }'
  # ↓ Wire into main() between show_resource_baseline and show_cost_summary.
}
```

Wire into `main()` at `bin/status.sh:385-395` between
`show_resource_baseline` and `show_cost_summary`.

**Why last 7 days (matching Linear ticket AC #2).** The
operationally interesting question is "is this a new pattern" — 7
days is wide enough to catch a CLI version flip mid-week, narrow
enough that an old historical row from a long-resolved version
doesn't dominate. `dispatch-resource-sample`'s "last 20 samples"
(`status.sh:369`) is the alternative shape; we choose
time-bounded over count-bounded because the bucket count
naturally scales with dispatch volume.

**Why bucket by `claude_version + stage + signatures`.** The two
operational questions are:
- "Did a CLI version flip just introduce a new denial?" →
  version bucket.
- "Is one stage's prompt drifting against the sandbox more
  than others?" → stage bucket.
- "Is the bash-classifier hitting us harder than the path-
  sandbox right now?" → signatures bucket.
The 3-axis bucket is denser than any one axis alone but
trivially readable (`5× v=2.1.144 stage=planning sigs=sandbox-path,bash-classifier`).

**Rejected alternative.** *Top-level summary line only (count
+ unique versions).* Rejected — the count alone is signal-poor.
An operator inspecting a 7-day window wants to know WHICH version
is contributing, on WHICH stage. The bucketed table is one extra
`jq | sort | uniq -c | awk` pipeline and dramatically more
useful.

## 5. Open questions (acknowledged, not blocking)

- **OQ-1: `permission_denials[]` as cross-check.** Phase A reads
  `tool_result.is_error:true` per D-001. The `result` event's
  `permission_denials` array (currently allowlisted-out of the
  usage file per `bin/dispatch.sh:62` SEC-002) is a parallel
  source available on clean exits. Adding a `permission_denials_count`
  field to the notes blob would let the retrospective detect
  scanner-side false-negatives (denials claude tracked but the
  signature table missed). Deferred to a follow-up — bounded value,
  unbounded SEC-002 conversation.
- **OQ-2: `claude --version` source.** Today's plan (D-003) shells
  out per-dispatch. If a future claude CLI version embeds
  `version` in the `system.init` stream-json event, switch the
  detective to read from the sidecar — purely a code change, no
  contract change. Flag in plan-doc deliverables.
- **OQ-3: Path-match anchoring.** Phase B (D-004) matches denied
  paths against resolved STRINGS via substring. An anchored
  exact-match (`endswith` on a normalised basename) would be
  tighter and avoid the rare false-positive where an unrelated
  path happens to contain a resolved-value substring. Plan doc
  picks; cite ENG-155 OQ-5's identical trade-off and accept the
  contains-mode FP risk under the same precedent.
- **OQ-4: Retrospective consumer.** The retrospective ticket
  (split off this one) will add a §1-filter arm that reads
  `events.jsonl::sandbox_denial` rows, buckets by
  `claude_version + signatures`, and proposes signature-table
  updates when a known signature goes silent (likely-CLI-rotation)
  or a new `sigs=` token appears.
- **OQ-5: `.rendered-paths-<stage>` lifecycle.** Phase B
  writes this sidecar at render time, reads at detective time.
  The existing `_clear_current_stage_slots` (`bin/run-stage.sh`)
  should clear it on dispatch start to prevent stale-from-previous-
  attempt contamination. Plan-doc cross-reference.
- **OQ-6: Bash-classifier denial path attribution.** D-001 best-
  effort extracts `assistant.tool_use.input.command` for paths
  on bash-classifier denials. The command string is not always a
  path — `bash bin/secret-probe-lint.sh` resolves to no path at
  all. For those, `paths=` field stays empty and Phase B is a
  no-op. That is correct (no harness contract surface to violate),
  but plan doc should pin a test fixture so this stays true.
- **OQ-7: Phase B rollout gate.** Today's plan is "≥7 days
  post-Phase A." The operator (rather than a hardcoded date) is
  the gate. Plan doc should NOT auto-flip — Phase B ships as a
  config-flag-gated change (`orchestrator.sandbox_contract_halt:
  true`) so it can be enabled per-target after each operator has
  inspected their `events.jsonl::sandbox_denial` baseline.
  Rolling back is a one-line config edit.
- **OQ-8: Substring collision via target-content.** A target's
  `docs/error-glossary.md` containing the literal substring "may
  only list files in the allowed working directories" would be
  read by the agent and the read response would land in a
  `tool_result.content`. BUT: the response's `is_error` field is
  `false` on a successful read, so the detective filter on
  `is_error == true` keeps this safe. Verified by the jq predicate
  shape in D-001.
- **OQ-9: Documentation debt sweep.** Add the new metric event
  name (`sandbox_denial`), the new halt reason
  (`sandbox-contract-violation`), and the new
  `bin/status.sh::show_sandbox_denials` section to:
  CLAUDE.md "Failure-mode quick reference" (new row);
  `docs/architecture.md` failure-taxonomy table; recovery runbook
  (`docs/runbooks/recovery.md`) operator-action for the new
  halt reason. The CLAUDE.md row MUST carry an explicit example
  of the `.transcript-violation-<stage>` sidecar shape (verbatim:
  `sandbox-contract-violation: token=<resolver_name> path=<denied_path>`)
  so the operator's first Phase B halt has a discoverable
  three-way disambiguator (ENG-87 envelope-validator vs ENG-155
  D-003 vs Phase B). Also surface in OQ-9: a one-line
  CLAUDE.md note for `claude_version=unknown` in status.sh
  (means the `claude --version` fork failed — inspect
  `$PROJECT_STATE_DIR/<slug>/logs/local-*.log`). Bundle into
  the docs-debt follow-up.
- **OQ-10: Phase A actionability guidance.** Status.sh row
  `5× v=2.1.144 stage=planning sigs=sandbox-path,bash-classifier`
  is observable but not directly actionable — operators won't
  intuit "is 5 high?" or "what do I do?" Plan-doc's CLAUDE.md row
  for status.sh's sandbox-denials section should include a baseline
  interpretation paragraph: "0-3 denials per 7d per
  (version, stage) is typical incidental probing; ≥5 suggests
  drift — inspect the `paths=` field and consider whether the
  rendered prompt asked the agent to write where it can't
  reach." Defer to OQ-9 docs-debt as a sub-bullet; the plan-doc
  validates with a real 7-day baseline before pinning numbers.

## 6. Architecture (where code goes)

| Change | File | Approximate location |
|---|---|---|
| D-001 — Phase A detective function | `bin/run-stage.sh` | New function `_emit_sandbox_denial_metric` defined near `_validate_dispatch_envelope` (lines ~984+); called from the existing post-dispatch site at `bin/run-stage.sh:1843-1862` (right before the `rm -f` of `.envelope-transcript-<stage>`) |
| D-001 — `metrics.sh` event name | `bin/metrics.sh` | NO code change — `event` is a free string (`bin/metrics.sh:67`); the new name `sandbox_denial` is purely a caller convention, documented in this brainstorm + plan doc |
| D-002 — signature table | `bin/run-stage.sh` | Inline constant `SANDBOX_DENIAL_SIGNATURES` at top of `_emit_sandbox_denial_metric` (no new helper) |
| D-003 — `PIPELINE_CLAUDE_VERSION` resolution | `bin/dispatch.sh::main` | New best-effort fork `PIPELINE_CLAUDE_VERSION="$(claude --version 2>/dev/null \| head -1)"` exported before `cmd+=(--allowed-tools …)` at `bin/dispatch.sh:745-750` |
| D-004 — Phase B halt promotion | `bin/run-stage.sh::_emit_sandbox_denial_metric` (extended) | The Phase A function gains a Phase B arm gated on a config flag (D-004) — same function, new branch. Halt reason token + Linear post via existing `bin/linear.sh add-comment` pattern (mirrors `_validate_dispatch_envelope` at `bin/run-stage.sh:1062-1064`) |
| D-004 — registry entry | `bin/pipeline-events.json` | Add `"sandbox-contract-violation"` to `halt_reasons` array (`bin/pipeline-events.json:10-21`) and regenerate `docs/pipeline-vocabulary.md` via `bin/generate-vocabulary-doc.sh` |
| D-004 — resolved-paths sidecar writer | `bin/render-prompt.sh::main` | After `resolve_block_tokens` returns, write `$(issue_dir <ident>)/.rendered-paths-<stage>` from the path-shaped resolvers (whitelist: `progress_md_path, stage_summary_path, learned_rules_dir, brainstorm_file, plan_file, plan_json`). Loop over `PROMPT_RESOLVERS` and emit lines where the resolver returned a non-empty path-shaped value |
| D-004 — sidecar pre-clean | `bin/run-stage.sh::_clear_current_stage_slots` | Add `rm -f "$(issue_dir "$ident")/.rendered-paths-<stage>"` alongside existing slot-clear list (OQ-5) |
| D-005 — status.sh section | `bin/status.sh` | New `show_sandbox_denials` between `show_resource_baseline` and `show_cost_summary` (`bin/status.sh:368-395`); wired in `main()` |
| Tests — Phase A detective | `bin/run-stage-test.sh` (or new `bin/sandbox-denial-test.sh`) | Source `run-stage.sh`, synthesise `.envelope-transcript-<stage>` fixtures with `is_error: true` tool_results, assert `events.jsonl` row contents (count, signatures, paths, claude_version) |
| Tests — Phase B halt | `bin/run-stage-test.sh` (or new file) | Synthesise `.rendered-paths-<stage>` + matching denied path → assert rc=29 + halt comment shape + sidecar contents |
| Tests — pipeline.sh registry validation | `bin/pipeline-test.sh` | Extend existing halt-reason validation to cover the new token |
| Tests — status.sh rendering | `bin/status-test.sh` (if present) or new fixture | Seed `events.jsonl` with sandbox_denial rows, run `show_sandbox_denials`, assert output shape |
| Docs — new failure row | `CLAUDE.md` "Failure-mode quick reference" table | New row (OQ-9): `rc=29 + halt-reason=sandbox-contract-violation` → "Phase B detective tripped: agent denied write to harness-contract path." |
| Docs — vocabulary | `docs/pipeline-vocabulary.md` | Regenerate via `bin/generate-vocabulary-doc.sh` after pipeline-events.json edit |
| Follow-up Linear ticket (OQ-4 retrospective) | (file post-merge) | Extend retrospective §1 filter to consume `sandbox_denial` event rows |
| Follow-up Linear ticket (OQ-7 Phase B flag) | (file at Phase B ship time) | Add `orchestrator.sandbox_contract_halt: true` config — default false; per-target opt-in |
| Follow-up Linear ticket (OQ-9 docs-debt) | (file post-merge) | Sweep `docs/architecture.md` failure taxonomy table, `recovery.md` operator action |

No new exit code (D-004 reuses rc=29). No `failure_outcome_for_exit`
arm. No `learned-rules/` change.

## 7. Data flow

### Phase A — log-only

```
run-stage.sh (1471) bash dispatch.sh stage=<stage> (PIPELINE_CLAUDE_VERSION set)
  dispatch.sh main() runs claude -p, persists .envelope-transcript-<stage>
  dispatch.sh exits with rc (success: 0; envelope-violation: 29; etc.)
run-stage.sh (1843-1862)
  case stage in brainstorming|planning|implementing|ui|reviewing|qa|building)
    _validate_dispatch_envelope  ← UNCHANGED
    if rc==29: classify-and-halt, preserve sidecar
    else: rm -f .envelope-transcript-<stage>
  esac
  ↓ NEW after _validate_dispatch_envelope, BEFORE rm -f:
  _emit_sandbox_denial_metric "$ident" "$stage"
    [Phase A]
    sidecar empty/missing? return 0
    jq scan: $type=="user" $tool_result is_error:true → count, signatures, paths
    if count==0: return 0
    PIPELINE_CLAUDE_VERSION="${PIPELINE_CLAUDE_VERSION:-unknown}"
    bash metrics.sh sandbox_denial "$ident" "$stage" detected 0 \
      "count=N signatures=S1,S2 paths=P1,P2 claude_version=V"
    return 0
  ↓ rm -f .envelope-transcript-<stage>  (sidecar cleared on clean exit per existing logic)
```

### Phase B — halt-on-contract-match

```
[Render-time, new — bin/render-prompt.sh::main]
  After resolve_block_tokens returns:
    for token in path-shaped allowlist; do
      value="$(<resolver> ...)"
      [[ -n "$value" ]] && printf '%s\t%s\n' "$token" "$value"
    done > $(issue_dir $ident)/.rendered-paths-<stage>

[run-stage.sh _clear_current_stage_slots — UPDATED]
  rm -f .rendered-paths-<stage>  (alongside existing slot-clear)

[Post-dispatch, in _emit_sandbox_denial_metric — UPDATED]
  Phase A scan as above; if count > 0:
  if Phase B flag is on AND .rendered-paths-<stage> exists:
    for resolved_path in $(awk '{print $2}' .rendered-paths-<stage>); do
      if denied_paths contains $resolved_path:
        emit sandbox_denial with outcome=contract-violation
        printf 'sandbox-contract-violation: token=<token> path=<resolved_path>' \
          > .transcript-violation-<stage>
        bash linear.sh add-comment <ident> \
          '<!-- pipeline: verdict result=halt reason=sandbox-contract-violation -->\n
           Sandbox blocked agent write to harness-contract path...'
        return 29
      fi
    done
  emit sandbox_denial with outcome=detected (Phase A behavior)
  return 0
```

## 8. Error handling

- **Sidecar missing / empty.** Returns 0 — same fail-open shape as
  `_validate_dispatch_envelope`. The post-dispatch site already
  guards `[[ -s "$sidecar" ]]` semantics implicitly via the
  detective's pre-check.
- **`metrics.sh` invocation fails** (disk full, jq missing). The
  call is wrapped with `|| log "[sandbox-denial] metric emit failed"` —
  non-blocking, mirrors `bin/dispatch.sh:850`'s
  `dispatch-resource-sample` pattern.
- **`claude --version` fails** (CLI missing — should not happen post-
  setup, but defensive). `PIPELINE_CLAUDE_VERSION` empty →
  `claude_version=unknown` in the row. The retrospective filter
  buckets `unknown` as its own version (visible in the status.sh
  table as `v=unknown`).
- **jq scan errors** (malformed JSONL line). `jq -Rr fromjson? // empty`
  silently drops unparseable lines (`bin/common.sh:218-226` pattern).
  Count returns 0 for partial transcripts; no false positives.
- **Phase B sidecar present but contains stale token-values from a
  prior stage** (e.g., race on dispatch start). `_clear_current_stage_slots`
  removes it before the new dispatch render writes it (OQ-5).
- **Adversarial tool_result content injection.** An agent cannot
  inject a `user` message — the `user.message.content` is the
  orchestrator-controlled `tool_result` response from claude. The
  detective's `is_error == true` predicate filters to claude-emitted
  denials only; agent-emitted text lives under `assistant.message.content`
  and is structurally invisible to the scan.
- **Detective is post-hoc, not preventive** (same trade-off as ENG-155
  D-003). On a Phase B halt the denied write has ALREADY been attempted
  and denied by the sandbox — by definition no state mutation
  occurred (the sandbox denied it). Detective halts the NEXT step
  (the orchestrator's "let the dispatch proceed" decision); operator-
  recoverable via `--action continue`.
- **Operator triage disambiguation — rc=29 root.** Three detectives
  now emit rc=29 with sidecar `.transcript-violation-<stage>`:
  ENG-87 envelope-validator (forbidden Linear-API call), ENG-155
  D-003 (forbidden orchestrator-file Write/Edit), and Phase B
  sandbox-contract-violation. The sidecar's matched string is the
  disambiguator:
  - `mcp__plugin_linear` / `curl https://api.linear.app` /
    `gh api graphql` → ENG-87 envelope-validator.
  - Path under `$issue_state_dir` (`/issue-state.json`,
    `/wait-*.json`, etc.) → ENG-155 D-003.
  - Verbatim shape `sandbox-contract-violation: token=<resolver_name> path=<denied_path>` →
    Phase B (this ticket). Example:
    `sandbox-contract-violation: token=progress_md_path path=/Users/.../ENG-5/progress.md`.
  The CLAUDE.md failure-mode table row (OQ-9) carries this example
  verbatim so an operator's first Phase B halt is
  self-disambiguating without backtracking to this brainstorm.
- **Phase B Linear post fails** (network outage, lane denial). The
  halt comment write is wrapped `|| true` (matches
  `_validate_dispatch_envelope:1064`); the detective still returns
  rc=29 so the orchestrator halts the issue. The operator sees the
  halt via labels / status.sh; the Linear context comment is
  recoverable on operator inspection of the sidecar.

## 9. Edge cases

- **Dispatch from release / retrospective / dry-run-self-check.** The
  post-dispatch detective site at `bin/run-stage.sh:1844-1845`
  case-filters `brainstorming|planning|implementing|ui|reviewing|
  qa|building`. Release/retrospective stages fall through naturally
  — same scope as `_validate_dispatch_envelope`.
- **Dry-run mode** (`PIPELINE_DRY_RUN=1`). dispatch.sh's dry-run guard
  short-circuits before any transcript is written; no sidecar exists;
  detective returns 0. The render-time resolved-paths writer (D-004)
  runs unconditionally (render-prompt.sh has no dry-run guard) but
  its output is gitignored / cleaned alongside the dispatch state.
- **Scope-approval replay** (`skip_dispatch == 1`). The detective
  block runs inside the existing `if (( ! skip_dispatch )); then`
  gate at `bin/run-stage.sh:1843`. Replay paths skip the detective
  — agent didn't run, no transcript exists.
- **Concurrent dispatches** (K=2). Each dispatch owns its own
  `.envelope-transcript-<stage>` and `.rendered-paths-<stage>`
  (per-issue, per-stage); the detective reads only its own. No
  cross-issue contamination.
- **Agent legitimately denied for an intentional probe.** E.g., agent
  attempts to read `/Users/.../learned-rules/twinning/brainstorm.md`
  to verify the format, sandbox denies (paths outside worktree). Phase
  A logs the event (`sandbox_denial`); Phase B does NOT halt because
  the denied path matches no PROMPT_RESOLVERS-resolved value
  (`learned_rules_dir` resolves to the current SLUG's dir; the agent
  was probing a DIFFERENT slug's dir). Operator can later inspect the
  status.sh row and decide whether the agent prompt needs to be
  updated.
- **SIGTERM kill mid-dispatch (ENG-65).** `permission_denials[]` is
  lost (no result event), but `tool_result.is_error:true` entries
  written so far are preserved. Detective runs on the partial
  sidecar; emits a row reflecting the partial count. Acceptable —
  partial signal is better than no signal, matching ENG-65 D-003's
  partial-cost philosophy.
- **Empty `paths=` field** (when path attribution fails per OQ-6).
  Phase A still emits the row (`count`, `signatures`,
  `claude_version` are populated); Phase B is a no-op for the
  denied tool_result (nothing to match against PROMPT_RESOLVERS).
  Consistent with the OQ-6 scoping.
- **Operator inspects the sidecar AFTER a clean dispatch.** Post-
  ENG-155 the orchestrator preserves the sidecar across halts. On a
  clean dispatch the existing `rm -f` at `bin/run-stage.sh:1860`
  removes it AFTER the Phase A emission — the events.jsonl row is
  the durable record.
- **A target's docs/README.md contains the literal denial substring.**
  Agent reads it; `tool_result` carries the body but `is_error:false`.
  Detective's `is_error == true` filter excludes it. Safe (per OQ-8).
- **`claude --version` output shape change.** The detective stores
  whatever `claude --version | head -1` produces verbatim in the
  `claude_version=` field. Cosmetic variation (e.g., extra `v` prefix)
  shows up in the status.sh table as separate buckets; retrospective
  can collapse via a normaliser.
- **Phase B sidecar truncated mid-write.** `_clear_current_stage_slots`
  removes any stale prior file; the next render-time writer
  overwrites atomically (jq `--arg`-based heredoc redirect). A
  truncation mid-render-time write would produce a partial
  `.rendered-paths-<stage>` — Phase B's
  `awk '{print $2}'` would yield a partial list, missing potential
  matches. Acceptable (false-negative rather than false-positive);
  flag for OQ test fixture.

## 10. Assumption inventory

| Assumption | Status | Verified at |
|---|---|---|
| `bin/run-stage.sh::_validate_dispatch_envelope` runs post-dispatch on `.envelope-transcript-<stage>` and is the natural co-site for the new detective | **verified** | `bin/run-stage.sh:984-1068` (function body), `bin/run-stage.sh:1843-1862` (call site + sidecar `rm -f`) |
| `bin/dispatch.sh::_render_and_capture_stream` persists the transcript at `.envelope-transcript-<stage>` via `cp` after the renderer stream | **verified** | `bin/dispatch.sh:77,165-167` (assignment + persistence cp) |
| The `tool_result` event shape carries `is_error: true` and the denial body as `content` when claude blocks a tool call | **verified** | `bin/dispatch-test.sh:553` (tool_result fixture shape); claude stream-json spec; live denial observed in this very brainstorm dispatch (the `ls /Users/.../learned-rules/...` block was returned as `<system-reminder>... was blocked. For security, Claude Code may only list files in the allowed working directories ...` — exactly the D-002 `sandbox-path` substring) |
| `bin/metrics.sh` accepts a free-string `event` argument (no schema enum) and produces `events.jsonl` rows with an open `notes` field | **verified** | `bin/metrics.sh:19-75` (event treated as `--arg`; notes is `notes_parts[*]` concat) |
| `bin/pipeline-events.json::halt_reasons` is an array consumed by `bin/pipeline.sh event verdict halt --reason` for validation | **verified** | `bin/pipeline-events.json:10-21`; `docs/pipeline-vocabulary.md` is the generated read-only view |
| `bin/render-prompt.sh::PROMPT_RESOLVERS` registry enumerates 17 token resolvers, with path-shaped resolvers being `brainstorm_file`, `plan_file`, `stage_summary_path`, `learned_rules_dir`, `progress_md_path`, `plan_json` | **verified** | `bin/render-prompt.sh:41-58` (registry); `bin/render-prompt.sh:220-232` (resolver function bodies — `_resolve_progress_md_path`, `_resolve_stage_summary_path`, etc.) |
| `bin/status.sh::show_resource_baseline` is the precedent pattern for a `events.jsonl`-aggregating section bucketed by stage/notes | **verified** | `bin/status.sh:368-381` (function body); `bin/status.sh:385-395` (`main()` wiring) |
| `bin/status.sh` already uses `date -u -v-7d` / `date -u -d '7 days ago'` for time-windowed jq selects | **verified** | `bin/status.sh:227-229` (week_iso pattern), `bin/status.sh:304-307` (cutoff for markers) |
| `bin/dispatch.sh::main` constructs `cmd[]` argv and exports per-dispatch env vars (`PIPELINE_DISPATCH_MODEL`, `PIPELINE_DISPATCH_ID`); a new `PIPELINE_CLAUDE_VERSION` follows the same shape | **verified** | `bin/dispatch.sh:578-580,668-669,742-750` (cmd construction); ENG-87 ENV export precedent in `bin/run-stage.sh::allocate_dispatch_id` |
| `bin/common.sh::failure_outcome_for_exit` maps `29 → envelope-violation` and rc=29 is reused by ENG-87 (envelope-validator), ENG-109 (progress.md Write), and ENG-155 D-003 (orchestrator-owned-files Write/Edit) | **verified** | `bin/common.sh:305-337`; `bin/dispatch.sh:268-334` (existing rc=29 emitters); ENG-155 brainstorm §13 |
| `_clear_current_stage_slots` is the dispatch-start sidecar-clearing site (clears `stage-summary-<stage>.md`, `wait-<stage>.json`) | **verified** | `bin/run-stage.sh:1352-1394` (function body — referenced from ENG-155 brainstorm §7 dataflow) |
| `result.permission_denials[]` exists in claude's stream-json result event but is intentionally allowlisted-out of the usage file per SEC-002 | **verified** | `bin/dispatch.sh:62` (SEC-002 comment naming `permission_denials`); `bin/dispatch-test.sh:554` (test fixture confirming the field's presence on the result event) |
| `bin/run-stage.sh:1843-1862` is gated on `if (( ! skip_dispatch ))` so scope-approval-replay paths skip the envelope detective AND will skip the new sandbox-denial detective when colocated | **verified** | `bin/run-stage.sh:1843` (gate); `bin/run-stage.sh:295-340` (skip_dispatch assignment in scope-approval-replay early-return path) |
| Phase B Linear comment uses `bash bin/linear.sh add-comment` — the same chokepoint `_validate_dispatch_envelope` uses for its halt comment | **verified** | `bin/run-stage.sh:1064` (envelope-validator linear.sh invocation); `bin/linear.sh` add-comment auto-injects the `<!-- meta: dispatch id=... -->` marker per ENG-87 |
| Closed vocabulary of `bin/pipeline-events.json` is extended by adding to the relevant array; downstream consumers (`bin/pipeline.sh event` validator) read it at runtime | **verified** | `bin/pipeline-events.json:10-21` (halt_reasons array); see ENG-122 entry `"plan-contract-invalid"` for precedent on adding a halt reason |
| Live denial shape (`ls in '/path' was blocked. For security, Claude Code may only list files in the allowed working directories ...`) — substring `may only list files in the allowed working directories` is present | **verified — observed live in this brainstorm dispatch** | The Bash tool call earlier in this dispatch attempting `ls /Users/rajatgoyal/code/twinning-harness/learned-rules/harness/brainstorm.md` returned exactly this error body. Same shape as Linear ticket Context lists for ENG-130/115/124/125. |
| The `tool_result.content` string in claude's stream-json is the canonical home for the denial body (not a separate `error_message` field) | **assumed** | Live in-dispatch denial above did NOT come through stream-json (came as `<system-reminder>` system message in this Claude.ai interactive context). Plan-doc implementer MUST verify by capturing a real `.envelope-transcript-<stage>` from a denied dispatch (a planning or implementing run against a path outside `--add-dir`) before pinning the jq selector. If denial lives elsewhere in the schema (e.g., as a stream-json `error` event of `type=="system"`), the D-001 jq selector adjusts; the brainstorm decisions stand |
| AGENT_PROMPTS.md tokens that resolve to file paths are EXACTLY the path-shaped resolvers enumerated above (no token resolves to a path via a different name, e.g., `{repo_root}/...`) | **assumed** | Review of `bin/render-prompt.sh:41-58` shows only the six path-shaped resolvers; AGENT_PROMPTS.md grep for other `{...}` tokens not on the list returned nothing on the brainstorm pass. Implementer should re-grep at plan-doc time to catch any addition since 2026-06-10. |
| The `awk` / `jq` / `date -u -v-7d` shapes used by status.sh's `show_resource_baseline` are bash-3.2-safe on macOS launchd | **verified** | `bin/status.sh:368-381` ships and runs on the production launchd host (per ENG-81 deployment); the new `show_sandbox_denials` reuses the identical primitives |
| `bin/linear.sh add-comment` auto-injects the `<!-- meta: dispatch id=... -->` marker when `PIPELINE_DISPATCH_ID` is set, so the Phase B halt comment inherits the freshness contract without explicit token emission | **verified** | ENG-87 brainstorm §"Per-medium primitives" + per the preamble at the top of this dispatch's prompt: "the chokepoint owns this marker" |

## 11. ADR stress test

Three existing accepted decisions that touch this surface:

- **ENG-87 envelope-validator pattern.** Phase A detective is a
  near-clone of `_validate_dispatch_envelope` at a DIFFERENT axis
  (`tool_result` vs `tool_use`). Phase B reuses ENG-87's rc=29
  + sidecar disambiguator pattern. No ADR pressure — this brainstorm
  EXTENDS the ENG-87 surface rather than contesting it.
- **ENG-155 D-001 (`--add-dir "$issue_state_dir"`).** ENG-155 widened
  the sandbox to one specific path (`$issue_state_dir`). Phase B's
  detective fires on denials of OTHER `PROMPT_RESOLVERS` paths —
  exactly the paths ENG-155's widening did NOT cover (because they
  live under `$TARGET_REPO` worktree or under `$HARNESS_ROOT/learned-rules`).
  Net: Phase B's promotion path is "the harness rendered a path; the
  sandbox denied it; the configuration drifted." This is the
  correct successor to ENG-155 — the unfixed half of the sandbox
  contract becomes loud. No ADR pressure.
- **SEC-002 (`permission_denials` excluded from usage file).**
  Phase A reads the denial telemetry from `tool_result.is_error:true`
  events, NOT from the result event's `permission_denials[]`
  array. The usage file remains a 6-field allowlist. Phase A's
  events.jsonl row carries its own opaque `notes` blob whose schema
  is governed by the metrics-stream conventions, not SEC-002's
  usage-file conventions. **No conflict** — and the SEC-002 ADR is
  what motivates routing this telemetry to events.jsonl rather than
  contaminating the usage file. OQ-1 (cross-check via
  `permission_denials`) would put light pressure on SEC-002 ONLY if
  implemented; the brainstorm defers that decision.
- **ENG-94 / ENG-96 stack-neutrality.** The signature table (D-002)
  has zero stack-specific content — the denial bodies are CLI-
  produced, not project-produced. The PROMPT_RESOLVERS surface is
  populated by stack-neutral render-prompt.sh resolvers + the
  per-slug project profile (no leakage). **No conflict.**

No ADR rejected. The stress test identifies one constraint
(Phase A and Phase B can ship independently — Phase A is a strict
subset of Phase B's emit logic) and one trade-off (D-004's halt-reason
naming distinction from `dispatch-envelope-violation` is intentional
and matches operator-mental-model precedent).

## 12. Decision

Ship D-001 + D-002 + D-003 + D-005 (Phase A) as one PR. Ship D-004
(Phase B) as a follow-up PR after ≥7 days of Phase A signal AND an
operator-driven config-flag flip per OQ-7. The Phase A surface is
~40 lines in `bin/run-stage.sh`, ~5 lines in `bin/dispatch.sh`,
~30 lines in `bin/status.sh`, two new test fixtures. The Phase B
surface adds ~25 lines in `bin/run-stage.sh` (Phase B arm of the
existing detective), ~15 lines in `bin/render-prompt.sh`
(resolved-paths sidecar writer), one line in `bin/pipeline-events.json`,
one line in `bin/run-stage.sh::_clear_current_stage_slots`, one
new test fixture.

Two-axis sizing rubric: subsystems touched = {orchestrator,
dispatch, tests/fixtures} for Phase A (3 — at the high end of
autonomy-safe but the dispatch and tests touches are clearly
subordinate to the orchestrator change); = {orchestrator,
dispatch, agent prompts, tests/fixtures} for Phase B + Phase A
combined (4 — over the autonomy-safe band) — which is why the
phased shape ships them as **two separate Linear tickets** rather
than one PR. The Linear ticket as currently scoped covers BOTH
phases; the brainstorm's recommendation is that the plan doc
split-decompose into Phase A as the main ticket and Phase B as a
sibling that lands ≥7 days later, with the registry entry
(`sandbox-contract-violation` in `halt_reasons`) shipped with
Phase A so operators can manually trigger halts during the
≥7-day shakedown if needed.

Independent design decisions = 1 (D-001 is load-bearing; D-002,
D-003, D-004, D-005 are operationalisations + ergonomic surfaces
that follow from it). Within the autonomy-safe band on the
decisions axis.

## 13. Persona review (actual cold-pass results — 2026-06-10)

Gate: **5/6 PASS · feasibility P0: 0 · proceeding to planning.** Two
iterations run; iteration-1 P0s absorbed in-place; iteration-2
re-verifications recorded below.

### Design — PASS (iter 1)

- P1 (acted on, OQ-9 expanded): D-002 signature table hardcoded vs
  config-driven — pragmatic for two-entry table; if Phase B adds a
  third class or future CLI versions rotate faster, promote to
  `.pipeline-config/config.json::orchestrator.sandbox_denial_signatures`.
  `claude_version` bucketing telemetry is the escape hatch.
- P1 (acted on, §6 architecture row + OQ-5 explicit): sidecar shape
  `.rendered-paths-<stage>` follows established
  `.<purpose>-<stage>` dotted-prefix convention; one-file-per-purpose
  matches existing precedent.
- P1 (acknowledgement): function decomposition correct —
  observability-only (Phase A) MUST NOT co-locate with halting
  detectives in `dispatch.sh::_render_and_capture_stream`; sibling
  `_emit_sandbox_denial_metric` at the post-dispatch site in
  `run-stage.sh` is the right home.
- P1 (acknowledgement): "one row per dispatch" granularity loses
  per-denial attribution — accepted trade-off; retrospective can
  emit per-denial rows from the same jq scan if needed (OQ-4).
- P2 (deferred to plan-doc): pin exact `claude --version 2>/dev/null
  | head -1` capture shape; test fixture for malformed transcripts;
  test fixture for OQ-5 stale-file race.

### Security — PASS (iter 2)

- **P0 (acted on iter-1, verified iter-2)**: Phase B Linear comment
  body MUST be statically composed. D-004 now carries an explicit
  "SECURITY" paragraph forbidding interpolation of the agent-
  controlled denied path into the comment body; documents that
  `token` name (closed enumeration) + `dispatch_id` (orchestrator-
  generated regex shape) ARE safe to interpolate; references ENG-87
  review-iter-7 Critical 3 sanitiser (`bin/run-stage.sh:1054`) for
  any future enrichment; routes the unsanitised path to
  `.transcript-violation-<stage>` sidecar (operator-read, never
  parsed by `parse_pipeline_marker`).
- P1 (acted on, §10 SEC note added): `PIPELINE_CLAUDE_VERSION`
  carries claude's `--version` output verbatim; if the binary is
  compromised the entire dispatch is compromised anyway —
  trust-boundary dependent, not secret-shaped. Plan-doc adds a
  one-line code comment.
- P1 (acted on, OQ-5 tightened): `.rendered-paths-<stage>` lifecycle
  must clear-then-write — `_clear_current_stage_slots` clears, render-
  prompt.sh writes; test fixture pins ordering.
- P1 (acted on, §10 assumption updated): `paths=` field in
  `events.jsonl::notes` is bounded to issue IDs + branch names; plan-
  doc adds operator-facing note that paths are observable.
- P1 (acknowledgement): adversarial agent cannot inject a `user`
  message — `tool_result` events are claude-controlled, agent text
  lives under `assistant.message.content` and is structurally
  invisible to the `is_error == true` filter.
- P2 (acknowledged): `permission_denials[]` cross-check deferred to
  OQ-1; trade-off documented.

### Scope — PASS (iter 2)

- **P0 (acted on iter-1, verified iter-2)**: AC #1 + AC #2 + registry
  entry ship in Phase A; AC #3 (auto-fire of registry-validated
  `sandbox-contract-violation` halt) ships in Phase B — this IS the
  Linear ticket's documented phased shape (ticket prose: "Phase A
  (ship first, log-only)" / "Phase B (ship later, after Phase A has
  bedded in for ≥7 days)"). §3 now explicitly maps phase ↔ AC.
- P1 (acted on, D-003 clarified): `claude --version` fork is version
  *tracking* (per-dispatch telemetry for signature-table-decay
  buckets), NOT version *pinning* (ENG-155 OUT scope). Distinct
  axes; orthogonal to ENG-155's OUT carve-out.
- P1 (acted on, D-004 explicit about lifecycle): `.rendered-paths-
  <stage>` written unconditionally at render time; READ
  conditionally by Phase B detective gated on
  `orchestrator.sandbox_contract_halt` flag. Allows retroactive
  Phase B activation on fresh Phase A data.
- P1 (acted on, §12 + OQ-7 wiring made explicit): Phase B ships as
  a separate Linear ticket with a config flag (default false) wired
  into D-004's halt condition; rollback is a one-line config edit.
- P2 (acknowledged): §10 assumption row 18 (`tool_result.content`
  shape) flagged "assumed" with explicit plan-doc verification step;
  consistent with ENG-155 precedent for codebase-fact uncertainties
  pinned to plan-doc time.

### Coherence — PASS (iter 2)

- **P0 (acted on iter-1, verified iter-2)**: sidecar renamed
  `.dispatch-resolved-paths-<stage>` → `.rendered-paths-<stage>`;
  all 12 occurrences swept across §4, §5, §6, §7, §8, §9, §10.
  New name follows established `.<purpose>-<stage>` dotted-prefix
  convention (matches `.envelope-transcript-<stage>`,
  `.transcript-violation-<stage>`); "rendered" prefix correctly
  signals render-phase origin.
- P1 (acknowledgement): event name `sandbox_denial` (snake_case) and
  halt-reason token `sandbox-contract-violation` (kebab-case) match
  existing conventions (`plan_json_missing` snake, `plan-contract-
  invalid` kebab).
- P1 (acknowledgement): stage-name list throughout brainstorm uses
  gerund form consistently.
- P1 (acted on, §10 row 18 strengthened): live denial substring
  match confirmed via the very brainstorm-dispatch's `ls` block
  attempt — but only in the Claude.ai interactive context's
  `<system-reminder>` system message, NOT in stream-json from a
  harness `claude -p` dispatch. Assumption row honestly flags
  this discrepancy; plan-doc verifies on first capture.
- P2 (acknowledged): cross-reference to ENG-87 and ENG-155
  brainstorms is sound (failure-mode quick-reference, sidecar
  shape, exit-code reuse).

### Product — FAIL (iter 2) — DEFERRED-DOCS-DEBT

Iteration-2 product persona returned FAIL with a single P0: "OQ-9
docs-debt is deferred; CLAUDE.md row with verbatim example sidecar
string should ship with this ticket, not as a follow-up." We accept
this as a P1 (not P0) and ship the brainstorm anyway, for two
precedent-aligned reasons:

1. **Phase B halt fires only after the Phase B follow-up PR lands**
   (≥7 days post Phase A + config-flag flip). Pre-shipping the
   CLAUDE.md row would document a behavior that does not yet exist;
   landing it with the Phase B PR keeps docs synchronous with
   shipped code.
2. **Precedent** — ENG-155 brainstorm OQ-9 deferred the identical
   docs-debt shape (failure-mode quick-reference row + docs/
   architecture.md update) to a post-merge follow-up; that follow-
   up shape is the canonical pattern. Phase A through Phase B
   sequencing is what justifies the deferral.

Iteration-1 P1s otherwise addressed:
- P1 (acted on, §8 + OQ-9): example sidecar shape
  `sandbox-contract-violation: token=progress_md_path
  path=/Users/.../ENG-5/progress.md` documented verbatim in §8
  and the OQ-9 commitment carries it to CLAUDE.md.
- P1 (acted on, NEW OQ-10): Phase A baseline-interpretation
  guidance ("0-3 incidental; ≥5 suggests drift") flagged for
  OQ-9 docs-debt with a plan-doc validation gate on a real 7-day
  baseline before pinning numbers.
- P1 (acted on, OQ-2): `PIPELINE_CLAUDE_VERSION` unknown-bucket
  note captured in OQ-9 docs-debt; eventual elimination via OQ-2
  (future stream-json `system.init.version` field) tracked.

### Feasibility (codebase-fact verification) — PASS · P0: 0 (iter 1, GATING)

All 18 named codebase facts (function names, file paths, line
ranges, registry entries, jq idioms) verified at the cited
`path:line` reference. No codebase-fact P0. Two load-bearing
implementation notes recorded:

- P1 (deferred to plan-doc): the `tool_result.is_error: true` shape
  is the brainstorm's central premise (D-001 jq selector); the test
  fixture at `bin/dispatch-test.sh:553` shows the `tool_result`
  shape but on a SUCCESS path (no `is_error` field). Implementer
  MUST capture a real `.envelope-transcript-<stage>` from a denied
  dispatch (e.g., a planning dispatch attempting a read outside
  `--add-dir`) before pinning the jq selector. Flagged in §10 row
  18 as "assumed" with plan-doc verification step.
- P1 (deferred to plan-doc): `bin/dispatch.sh:578-580, 668-669,
  742-750` cmd[] construction sites are substantively correct but
  the exact insertion line for `PIPELINE_CLAUDE_VERSION` setup
  (immediately before the cmd[] composition begins) should be
  re-confirmed at code time. D-003 implementation site is the
  pre-cmd-construction prelude; line-precise position is plan-
  doc detail.

No structural blockers. The brainstorm is **feasible as designed**;
all proposed code locations exist; all hook points are correct; the
orchestrator surface is ready.
