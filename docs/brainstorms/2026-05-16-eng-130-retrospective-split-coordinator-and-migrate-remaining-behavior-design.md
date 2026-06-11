---
linear: ENG-130
title: Retrospective split — coordinator and migrate remaining behavior
date: 2026-05-16
status: draft
---

# Retrospective split — coordinator and migrate remaining behavior

## 1. Problem

ENG-129 shipped the first retrospective shape (`stage-failure-summary`)
as a proof of the architectural pattern: a plain-markdown prompt body
under `bin/retro-prompts/`, a wrapper driver at
`bin/retro-shape-<name>.sh`, a sibling test, and an artifact at
`$PROJECT_STATE_DIR/retrospective-${date}/<name>.md` consumed by the
parent retrospective via path-token interpolation. The PoC left
behaviors §2–§12 of `AGENT_PROMPTS.md` §9 inline (per ENG-129 D-010).

The remaining monolith — `bin/run-retrospective-local.sh` lines
103–128 (extract §9 fenced block from `AGENT_PROMPTS.md`,
sed-substitute one token, dispatch one `claude -p` for all eleven
remaining behaviors) — still has the same problems ENG-129 §1
catalogued: single-failure blast-radius covers eleven behaviors, no
unit-test surface for any of them, single context window for twelve
different reasoning shapes, and a single retrospective-stage timeout
budget (30 min per `bin/dispatch.sh:469`) shared across them all.

Three concrete consequences keep recurring:

- A confused §6 expiry-verification pass that names a non-existent
  file path blocks the §1 stage-failure-summary's output from
  landing — the entire PR halts because the agent halts mid-task.
- New behavior tickets pile up against an already-full context.
  ENG-39 (calibration) and ENG-40 (component audit) are queued
  behind the architectural restructure, not against it.
- The 30-min retrospective timeout (`bin/dispatch.sh:469`) is shared
  across twelve behaviors; the gtimeout SIGTERM fires when the
  agent is mid-way through §10, losing the §1–§9 work even though
  the agent had not yet written a PR commit. ENG-129 D-010 punted
  on this; ENG-130 must address it because the symptom returns.

This ticket — ENG-130, sub-ticket of ENG-33 — restructures
`bin/run-retrospective-local.sh` into a deterministic bash
coordinator, extracts the eleven remaining behaviors as shape
scripts, and replaces the outer "monolith dispatch" with
per-shape dispatches whose outputs the coordinator aggregates
into a single PR.

## 2. Decisions

### D-001. `bin/run-retrospective-local.sh` becomes a bash coordinator with zero `claude -p` dispatches at the coordinator level; all model work happens inside shape scripts.

This is the load-bearing decision the Linear AC #1 spells out
verbatim: "run-retrospective-local.sh contains no claude invocations
directly; all model work happens inside shape scripts."

Concretely:

- Lines 103–128 of `bin/run-retrospective-local.sh` (extract §9
  fenced block via awk; sed-substitute
  `{stage_failure_summary_path}`; `bash dispatch.sh retrospective
  "$prompt_file" "$log_file"`; rm `$prompt_file`) are deleted.
- In their place: an ordered iteration over a hard-coded `SHAPES=(…)`
  array (D-002), each iteration `bash`-invoking
  `bin/retro-shape-<name>.sh` with `--artifact-path`,
  `--period-start-iso`, `--period-end-iso`, and (where applicable)
  `--previous-period-path`.
- The PR body is composed in bash by concatenating per-shape
  artifacts (D-006), not by an outer claude agent.
- `AGENT_PROMPTS.md` §9 — including the "Output (the
  retrospective PR body)" template at lines ~1901–1942 — is
  deleted. Its content moves into per-shape prompts (the "Period"
  preamble + per-shape section becomes the coordinator's bash-side
  PR body template).

*Reference to constraint:* CLAUDE.md "AGENT_PROMPTS.md is
load-bearing" — sections 1–8 are dispatch stages keyed in
`bin/render-prompt.sh::STAGE_TO_SECTION` at `bin/render-prompt.sh:13-22`;
§9 has always been an outlier (no entry in that table, extracted by a
local awk in `bin/run-retrospective-local.sh:105-109`). Removing the
outlier is consistent with the "sections 1–8 are dispatch stages,
period" rationale ENG-129 D-002 used to justify
`bin/retro-prompts/`.

*Rejected alternative — keep §9 as a thin coordinator-prompt stub
(one paragraph: "Read each artifact in
`$PROJECT_STATE_DIR/retrospective-${date}/` and compose them into a
PR body"):* rejected because it adds a 13th claude dispatch (the
"compose-PR-body" agent) for purely mechanical work (string
concatenation + a `## Period` header). The coordinator's bash can do
this deterministically in ~10 lines of `cat` + heredoc. Per CLAUDE.md
"Defense-in-depth: prefer deterministic bash-side computation over
prompt-instructed agent computation when the computation is
mechanical." Composition of the PR body is mechanical.

*Rejected alternative — keep `run-retrospective-local.sh` dispatching
an "outer" claude that reads all the shape artifacts and writes the
PR body:* rejected because AC #1 forbids it ("contains no claude
invocations directly"). Even ignoring AC #1: the outer dispatch
re-introduces the same monolith failure mode the split is meant to
break — a confused outer agent that writes a wrong PR body blocks
all eleven shapes' contributions.

### D-002. Hard-coded ordered `SHAPES` array in `bin/run-retrospective-local.sh`; no auto-discovery, no config-driven shape list.

The coordinator's shape registry is one ordered bash array:

```bash
# Order mirrors §1–§12 of the pre-ENG-130 AGENT_PROMPTS.md §9, which
# encoded the dependency order chosen by humans (e.g., expiry decisions
# in §6 affect §10 budget counts; §3/§4 candidate harvesting before §7
# bias audit).
SHAPES=(
  stage-failure-summary           # §1 (already shipped by ENG-129)
  gotcha-recurrence               # §2
  convention-drift                # §3
  gotcha-promotion                # §4
  human-override                  # §5
  expiry-verification             # §6
  confirmation-bias-audit         # §7
  recency-bias                    # §8
  survivorship-bias               # §9
  knowledge-budget                # §10
  pipeline-health-score           # §11
  prompt-workflow-amendment       # §12
)
```

Adding a new shape = (a) drop a new prompt body under
`bin/retro-prompts/<name>.md`, (b) write a sibling driver
`bin/retro-shape-<name>.sh` + test, (c) append the name to `SHAPES`.
Pure additive change; no implicit ordering surprises.

*Reference to constraint:* CLAUDE.md "Don't add features, refactor,
or introduce abstractions beyond what the task requires." A
hard-coded array is the simplest registry that exercises AC #2 ("one
combined PR across all shapes that produced changes"). Auto-discovery
or config-driven registries trade simplicity for a use case nobody
has asked for yet (per-target shape disabling).

*Rejected alternative — auto-discover by `for s in
$HARNESS_ROOT/bin/retro-shape-*.sh; do …; done`:* rejected because
(a) the dependency order between shapes (§6 → §10 above) is lost in
filesystem-order iteration, (b) disabling a shape requires renaming
or deleting its driver file (a "soft delete" gets clobbered by the
glob), (c) introduces a load-time dependency on directory contents
that the test harness has to mock around. The hard-coded array is
both more explicit and easier to test.

*Rejected alternative — JSON config at
`.pipeline-config/config.json::retrospective.shapes[]`:* rejected as
YAGNI per CLAUDE.md. The retrospective is a single binary running
weekly; per-target shape enablement is a use case nobody has named
yet. The harness-self target's `learned-rules/harness/` and a
hypothetical second target's `learned-rules/<other>/` already share
the same shape set (the shapes operate on `events.jsonl` +
`docs/knowledge/` + `learned-rules/` — all per-target paths that the
shape inherits from `TARGET_REPO`). When a per-target shape-disable
use case shows up, add the config knob then; not now.

### D-003. Each of §2–§12 is extracted into its own shape — eleven new shapes — by mechanical replication of the ENG-129 stage-failure-summary pattern.

The eleven new shapes:

| Shape name (kebab-case)        | Source §  | Reads                                              | Writes (artifact + checked-in)                          |
|---                              |---        |---                                                 |---                                                       |
| `gotcha-recurrence`             | §2        | `git log --grep=^Gotcha-hit:`, `git log --grep=^Gotcha-avoided:`, `docs/knowledge/gotchas.md` | artifact + `docs/knowledge/gotchas.md`, `learned-rules/<slug>/<agent>.md` |
| `convention-drift`              | §3        | Linear `meta: metric name=convention_candidate` comments, repo grep | artifact + `docs/knowledge/conventions.md` |
| `gotcha-promotion`              | §4        | Linear `meta: metric name=gotcha_new` comments, repo grep | artifact + `docs/knowledge/gotchas.md` |
| `human-override`                | §5        | `git log --author='twinning-pipeline-bot' --diff-filter=M`, profile `## File layout`, file diffs | artifact + `learned-rules/<slug>/<agent>.md` |
| `expiry-verification`           | §6        | `docs/knowledge/*.md`, repo grep, `events.jsonl`   | artifact + `docs/knowledge/*.md`, `learned-rules/<slug>/*.md` |
| `confirmation-bias-audit`       | §7        | `docs/knowledge/{gotchas,conventions,qa-patterns,decisions}.md`, `learned-rules/<slug>/*.md` | artifact (proposals; no auto-edit — flag-only) |
| `recency-bias`                  | §8        | `learned-rules/<slug>/*.md`, `.pipeline-config/config.json::anti_bias.retrospective` | artifact (proposals; no auto-edit — flag-only) |
| `survivorship-bias`             | §9        | `events.jsonl` + Linear `pipeline:abandoned` issues | artifact |
| `knowledge-budget`              | §10       | `.pipeline-config/config.json::knowledge_budget`, `docs/knowledge/*.md` | artifact + eviction edits to `docs/knowledge/*.md` |
| `pipeline-health-score`         | §11       | `events.jsonl`, prior period artifact for Δ        | artifact (one ratio + Δ; or insufficient-sample) |
| `prompt-workflow-amendment`     | §12       | `events.jsonl`, `.pipeline/AGENT_PROMPTS.md`, `.pipeline/config.json`, `.github/workflows/pipeline*.yml`, `.github/workflows/release*.yml` | artifact + edits to AGENT_PROMPTS.md / config.json / workflows |

Each shape gets:

1. `bin/retro-prompts/<name>.md` — verbatim move of §N's text from
   the pre-ENG-130 `AGENT_PROMPTS.md` §9 body, restructured with the
   five-section ENG-129 template (`## Inputs`, `## Insufficient-sample
   carve-out` where applicable, `## Task`, `## Output schema`,
   `## Mandatory exit instructions`).
2. `bin/retro-shape-<name>.sh` — driver mirroring
   `bin/retro-shape-stage-failure-summary.sh`. CLI flags: same five
   (`--artifact-path`, `--period-start-iso`, `--period-end-iso`,
   `--previous-period-path`) plus any shape-specific extras (e.g.,
   `--target-repo` is implicit from `$TARGET_REPO`; no per-shape
   flags needed in this batch).
3. `bin/retro-shape-<name>-test.sh` — sibling test mirroring
   `bin/retro-shape-stage-failure-summary-test.sh`. Fixture set:
   missing-arg dies, dry-run produces placeholder, token resolution
   leaves no leftover `{tok}`, artifact-missing dies, dispatch-rc
   non-zero dies, unknown-flag dies.

*Reference to constraint:* CLAUDE.md "Tests are sibling shell
scripts" + "When a new bash file is meant to be both executable and
unit-testable, replicate the sentinel pattern." Each new driver +
test pair is mechanical replication of the ENG-129 PoC.

*Rejected alternative — collapse §7 (confirmation-bias) and §8
(recency-bias) into one `bias-audit` shape because both are
analysis-only:* rejected because (a) collapsing trades a per-shape
test surface for a slightly smaller registry; per ENG-129 the test
surface is the win, (b) §7 and §8 already have different inputs
(§7 cross-greps knowledge + learned-rules pairwise; §8 classifies
learned-rules by failure-domain enum) — the cross-shape coupling
would re-introduce monolith intuition that ENG-129 fought to remove.

*Rejected alternative — defer §12 prompt-workflow-amendment to its
own ticket because it's the only shape that writes outside
`docs/knowledge/` and `learned-rules/`:* rejected because (a) AC #1
("all model work happens inside shape scripts") would be violated if
§12 stayed in §9 inline, (b) §12's write surface
(`.pipeline/AGENT_PROMPTS.md`, `.pipeline/config.json`,
`.github/workflows/*.yml`) is already in scope for the existing
retrospective dispatch's allowed-tools (`Write,Edit` at
`bin/dispatch.sh:403`), so no allowlist edit is needed — the shape
inherits the existing capability via `dispatch.sh retrospective`.

### D-004. Shapes have a dual output channel: ALWAYS write an artifact under `$PROJECT_STATE_DIR/retrospective-${date}/<name>.md`; MAY additionally edit checked-in files (`docs/knowledge/*.md`, `learned-rules/<slug>/*.md`, `AGENT_PROMPTS.md`, `config.json`, workflow yamls).

ENG-129 D-005's PoC was strict — stage-failure-summary writes ONLY
the artifact; the parent retrospective writes everything checked-in.
Tomorrow's shapes (§2–§12) inherit no parent — the coordinator does
not dispatch claude. Therefore each shape must own its checked-in
write authority directly.

Concretely, each shape's prompt body declares two output channels:

- **Required:** `Write {artifact_path}` (a markdown summary, even if
  the body is "no findings this period"). The coordinator
  concatenates these for the PR body.
- **Optional, scope-bounded:** `Write` or `Edit` of files in a
  shape-declared write whitelist. The whitelist is enumerated in the
  prompt body; example for `expiry-verification`:
  > Write or Edit files under `docs/knowledge/` (specifically
  > `gotchas.md`, `conventions.md`, `qa-patterns.md`,
  > `decisions.md`) and `{learned_rules_dir}/*.md`. Do NOT modify
  > files outside this list.

The allowed-tools list at `bin/dispatch.sh:403` already grants
`Read,Write,Edit,Grep,Glob`. No allowlist edit needed — the
prompt-side scope is the operative constraint, matching the pattern
ENG-129 D-005 noted for stage-failure-summary's Write target.

*Reference to constraint:* CLAUDE.md "Don't add features … beyond
what the task requires." Pushing write authority into each shape (vs
adding a 13th "writer" shape that takes every artifact and applies
edits) avoids inventing a new orchestration role. Each shape owns
its own analysis + proposed-edits round trip.

*Rejected alternative — every shape produces ONLY an artifact (no
checked-in writes); a final `apply-edits` shape parses all artifacts
and writes the actual file changes:* rejected because (a) it adds a
13th dispatch whose job is to parse markdown back into file edits —
introducing a structured intermediate format (machine-readable
artifact schema, parser, edit applier) that's overkill for the
"each shape writes its own slice" model; (b) it concentrates failure
risk into one writer shape (if the writer hallucinates an edit, all
eleven shapes' work is wrong); (c) it doubles the spend (every
proposed edit is reasoned about twice — once by the proposing shape,
once by the writer).

*Rejected alternative — shapes write artifacts to a per-shape branch
in `$TARGET_REPO`; coordinator merges branches:* rejected as
needless complexity. Each shape's write surface is shape-scoped by
the prompt; collisions are improbable (only §6 expiry + §10 budget
both touch `docs/knowledge/`, and §6 deletes / §10 evicts are
operating on different criteria). When a real collision shows up,
the operator sees the conflicting diff in the PR review and can ask
for re-runs in isolation.

### D-005. Per-shape failure semantics: shape-rc non-zero → log + slack-notify + skip; surviving shapes still contribute to the PR. After ALL shapes attempt, the coordinator opens ONE PR if any tracked-file changes accumulated.

ENG-129 D-006's "halt the parent retrospective on shape failure" was
chosen because there was only ONE shape; partial success wasn't a
concept. With eleven shapes, AC #3 explicitly demands a
"some-shapes-skip" test path, which only makes sense if surviving
shapes can still contribute.

Coordinator pseudocode:

```bash
local failed_shapes=()
local succeeded_shapes=()
for shape in "${SHAPES[@]}"; do
  local artifact="$PROJECT_STATE_DIR/retrospective-${today}/${shape}.md"
  if bash "$SCRIPT_DIR/retro-shape-${shape}.sh" \
       --artifact-path "$artifact" \
       --period-start-iso "$period_start_iso" \
       --period-end-iso   "$period_end_iso" \
       --previous-period-path "$(_resolve_previous_period_artifact "$shape" "$today")"
  then
    succeeded_shapes+=("$shape")
  else
    failed_shapes+=("$shape")
    log "coordinator: shape '$shape' failed; continuing with remaining shapes"
  fi
done
```

After the loop:

- If `failed_shapes` is non-empty, send a single slack `error` line
  naming the failed shapes (`"Weekly retrospective: 3 of 12 shapes
  failed: gotcha-promotion, expiry-verification, survivorship-bias.
  PR will reflect surviving shapes."`). No per-shape slack spam.
- Coordinator runs `git add -A; git diff --cached --quiet` to detect
  whether ANY shape's edits landed. If no tracked changes: log
  "no changes proposed this week"; do NOT open a PR (matches
  today's behavior at `bin/run-retrospective-local.sh:131-138`).
- If changes exist: compose PR body by concatenating
  succeeded-shapes' artifacts (failed-shapes' artifacts are listed
  in a "## Failed shapes" footer with rc + log path);
  commit + push + `gh pr create`.

*Reference to constraint:* Linear AC #3 "Tests cover: …
some-shapes-skip …" — the test path only exists if soft-failure is
the policy. Plus CLAUDE.md "Don't ship half-finished
implementations" cuts the other way too: a coordinator that halts
on first failure can't fulfill AC #2 ("opens one combined PR across
all shapes that produced changes") because "all shapes that produced
changes" requires running them all.

*Rejected alternative — halt on first failure (mirror ENG-129
D-006):* rejected because it cannot satisfy AC #3's
"some-shapes-skip" test path; the only way "some-shapes-skip" makes
sense is if remaining shapes still execute. Note this is a
SUPERSESSION of ENG-129 D-006's coordinator-side gating policy — the
shape-side contract (a shape itself dies on internal errors,
returning non-zero to its caller) is unchanged. The coordinator
catches that non-zero and continues; the PoC's run-retrospective
caught it and halted because there was nothing else to run.

*Rejected alternative — fail-threshold (halt if ≥ N shapes failed,
e.g., N = 4):* rejected as premature optimization. Today we have no
data on shape failure correlation; a threshold gate adds tunable
complexity for a problem that hasn't manifested. If a "cascading
failure" symptom shows up after rollout, add the threshold then.
Slack notification surfaces the count today; an operator monitoring
the slack channel can manually intervene.

*Rejected alternative — soft-rollback failed shape's partial
edits via `git checkout -- <files>` before next shape runs:*
rejected because (a) by the time the shape returns non-zero, the
agent may have already partially written files; per the existing
allowed-tools the agent has Write/Edit but not commit authority
(committing is bash-coordinator only). Partial files are bounded by
the agent's tool boundary — the worst case is a half-written
`docs/knowledge/gotchas.md` whose markdown is malformed, which the
operator sees in the PR review. Auto-rollback would silently mask
shape bugs that the operator should know about.

### D-006. PR body composition by bash-side concatenation of per-shape artifacts under a `## Period` preamble + `## Failed shapes` footer. No claude dispatch for composition.

Coordinator bash builds `$PROJECT_STATE_DIR/retrospective-${today}/pr-body.md`:

```bash
{
  printf '## Period\n'
  printf '%s → %s\n\n' "$period_start_iso" "$period_end_iso"
  for shape in "${succeeded_shapes[@]}"; do
    if [[ -s "$PROJECT_STATE_DIR/retrospective-${today}/${shape}.md" ]]; then
      printf '\n---\n\n'
      cat "$PROJECT_STATE_DIR/retrospective-${today}/${shape}.md"
    fi
  done
  if (( ${#failed_shapes[@]} > 0 )); then
    printf '\n---\n\n## Failed shapes\n\n'
    for s in "${failed_shapes[@]}"; do
      printf '- %s (rc=%s, log=%s)\n' \
        "$s" "${shape_rcs[$s]}" "$PROJECT_STATE_DIR/logs/retro-shape-${s}-${today}.log"
    done
  fi
} > "$pr_body_path"
```

Then:

```bash
gh pr create \
  --title "chore(pipeline): weekly retrospective ${today}" \
  --body-file "$pr_body_path" \
  --label pipeline-retrospective
```

Each shape's artifact is responsible for being PR-body-shaped — i.e.,
starting with an H2 header (`## Gotcha recurrence`, `## Convention
drift`, etc.) that the concatenation surfaces under the `## Period`
preamble.

The pre-ENG-130 §9 "Output (the retrospective PR body)" template
(lines ~1901–1942 of AGENT_PROMPTS.md) is decomposed: each cell of
that template (Systemic findings, Proposals, Expiry decisions, Bias
findings, Recency/survivorship, Knowledge budget, Pipeline health,
Slack summary) becomes part of its source shape's `## Output schema`.
Operators reading the new PR body see the same information; the
visual organization is per-shape rather than cross-cutting.

*Reference to constraint:* CLAUDE.md "Don't add features … beyond
what the task requires." Bash-side composition is the minimal
mechanism that satisfies AC #2 ("one combined PR with combined
artifacts"). Per CLAUDE.md "Defense-in-depth: prefer deterministic
bash-side computation over prompt-instructed agent computation when
the computation is mechanical" — concatenation under fixed delimiters
is mechanical.

*Rejected alternative — Synthesizing "compose-pr-body" shape that
reads all artifacts and rewrites them in the pre-ENG-130 §9 output
shape (Systemic findings, Proposals, Expiry decisions, etc.):*
rejected because (a) violates AC #1 ("no claude invocations
directly" at the coordinator level — a synthesizing shape IS a
claude invocation, just one more shape; technically AC #1 is
satisfied because the shape is in `bin/retro-shape-*.sh`, but the
result re-introduces the monolith failure mode for PR body shape),
(b) doubles the spend (every finding is reasoned about twice).

*Rejected alternative — emit the PR body as YAML/JSON for
machine-readable downstream consumption:* rejected as
scope-creep (no consumer asked for a structured PR body) and as
operator-hostile (the PR body is consumed by a human reviewer
in GitHub's web UI; markdown is the right shape).

### D-007. The PR is opened iff `git diff --cached --quiet` returns non-zero after all shapes run AND `git add -A`. Otherwise: log "no changes proposed", slack-notify with `info` level, no PR.

Today's `bin/run-retrospective-local.sh:131-138` already encodes
this:

```bash
git -C "$TARGET_REPO" add -A
if git -C "$TARGET_REPO" diff --cached --quiet; then
  log "retrospective: no changes proposed this week"
  bash "$SCRIPT_DIR/slack.sh" info "Weekly retrospective: no changes proposed."
  git -C "$TARGET_REPO" checkout main
  git -C "$TARGET_REPO" branch -D "$branch" || true
  return 0
fi
```

ENG-130 preserves this gate verbatim. Shape artifacts under
`$PROJECT_STATE_DIR/retrospective-${today}/` are NOT in
`$TARGET_REPO` (per ENG-129 D-005); they don't show up in `git add
-A`. Only checked-in file edits (per D-004's optional channel) move
the diff.

The "no PR opened" branch IS a coordination path the test must
cover (AC #3 third bullet: "none-produce-changes (no PR)"). Fixture
asserts: every shape stub succeeds, none of them modify
`$TARGET_REPO`, coordinator logs the "no changes proposed" line,
`gh pr create` is NOT invoked.

*Reference to constraint:* `bin/run-retrospective-local.sh:131-138`
is the existing implementation of this gate; ENG-130 preserves it.

*Rejected alternative — always open a PR carrying the per-shape
artifacts as a `docs/retrospective-runs/${today}.md` commit (so
every run produces a PR):* rejected because (a) doubles PR volume
without adding signal; per CLAUDE.md "Don't add features …", a PR
that says "no changes proposed this week" wastes a CODEOWNERS
review cycle, (b) ENG-129 D-005's rationale (artifacts are state,
not source) applies symmetrically — committing them as docs
inverts the artifact-vs-source decision.

### D-008. Period semantics: coordinator calls `_compute_retro_period` ONCE per run; passes `period_start_iso` / `period_end_iso` to every shape. Identical to the ENG-129 contract.

`bin/run-retrospective-local.sh:38-49` defines `_compute_retro_period`
(introduced by ENG-129). It emits two ISO 8601 UTC timestamps on
stdout (start, end). ENG-130 reuses this helper unchanged.

The coordinator's loop passes both timestamps to every shape:

```bash
period_lines="$(_compute_retro_period)"
period_start_iso="$(printf '%s' "$period_lines" | sed -n '1p')"
period_end_iso="$(printf '%s' "$period_lines"   | sed -n '2p')"
# ... loop body uses these two variables for every shape ...
```

This guarantees every shape sees the same period. No cross-shape
drift.

*Reference to constraint:* ENG-129 D-008's "centralizing in the
shape script (or later in a coordinator) prevents drift" — ENG-130
is the "later in a coordinator" half of that prediction.

*Rejected alternative — each shape recomputes period inside its own
prompt body (the pre-ENG-129 default):* rejected because (a) eleven
agents each running `git log --merges | grep | head -1` is eleven
opportunities for one of them to misinterpret the result (e.g., pick
the second-most-recent merge if HEAD contains a non-retrospective
merge with the substring), (b) wastes the agent's reasoning budget
on a mechanical computation that bash already does.

### D-009. `--previous-period-path` resolution centralized in a coordinator helper `_resolve_previous_period_artifact(shape, today)`. Helper finds the most-recent prior `retrospective-YYYY-MM-DD/<shape>.md` directory; emits `(none)` if no prior run exists for that shape.

ENG-129 D-005's per-run dated directory
(`$PROJECT_STATE_DIR/retrospective-${today}/`) means prior runs
sit under `$PROJECT_STATE_DIR/retrospective-2026-05-08/`,
`retrospective-2026-05-15/`, etc. Each shape that wants
period-to-period trend comparison passes
`--previous-period-path <path-to-prior-shape-artifact>` to the
next run's invocation.

Coordinator helper:

```bash
_resolve_previous_period_artifact() {
  local shape="$1" today="$2"
  # Find the most-recent dated directory strictly before $today
  # that contains the named shape's artifact. Emits absolute path
  # or "(none)" if no prior artifact exists.
  local most_recent
  most_recent="$(
    find "$PROJECT_STATE_DIR" -maxdepth 1 -type d \
      -name 'retrospective-*' \
      | awk -F'/retrospective-' -v today="$today" \
          '$2 < today { print $0 }' \
      | sort -r | head -1
  )"
  if [[ -n "$most_recent" && -f "$most_recent/${shape}.md" ]]; then
    printf '%s' "$most_recent/${shape}.md"
  else
    printf '%s' '(none)'
  fi
}
```

Only shapes whose prompt body declares `{previous_period_path}` as a
token actually use it (today: stage-failure-summary; potentially
pipeline-health-score and recency-bias for Δ comparisons). Shapes
that don't reference the token just ignore the flag — the driver
accepts it but the prompt body doesn't substitute it.

*Reference to constraint:* CLAUDE.md "Use `log` / `die` /
`require_env` / `require_bin` from common.sh; don't roll your own"
— the helper sits in `bin/run-retrospective-local.sh`, not
common.sh, because it's retrospective-binary-internal (no other
caller). Mirrors `_compute_retro_period`'s location.

*Rejected alternative — each shape computes its own
previous-period path:* rejected because each shape would
duplicate the find+sort logic; centralization in the coordinator is
the obvious shape.

*Rejected alternative — pass the entire `$PROJECT_STATE_DIR` to the
shape and let the shape's agent find the prior artifact:* rejected
because (a) it expands the shape's read surface unnecessarily,
(b) the find+sort logic is mechanical bash, not agent reasoning.

### D-010. New coordinator-level test `bin/run-retrospective-local-test.sh` covering AC #3's three coordination paths plus error-path fixtures.

Test follows the source-and-stub pattern (CLAUDE.md "How tests
work"). The coordinator's `main()` invokes git, gh, slack, and each
shape script; the test stubs ALL of these and runs the coordinator
in dry-mode against a disposable git repo.

Test fixtures:

| Fixture name                              | Stubs                                                                    | Asserts                                                                                                                  |
|---                                        |---                                                                       |---                                                                                                                       |
| `cf-1-all-shapes-succeed-pr-opened`        | All 12 retro-shape-*.sh stubs return 0; each writes a tracked file       | `gh pr create` was called once; PR body file exists and contains a `## Period` line + one `## <shape>` header per shape  |
| `cf-2-some-shapes-skip-pr-opened`          | 3 stubs return non-zero; 9 return 0 with tracked-file edits              | `gh pr create` called once; PR body contains `## Failed shapes` footer naming the 3 failures; surviving shapes' sections present |
| `cf-3-no-shape-produces-changes-no-pr`     | All 12 stubs return 0 but write artifacts only (no tracked-file changes) | `gh pr create` NOT called; slack `info` "no changes proposed" sent; "no changes proposed" log line present              |
| `cf-4-all-shapes-fail-no-pr`               | All 12 stubs return non-zero                                             | `gh pr create` NOT called (no diff to PR); slack `error` listing all 12 failures sent                                    |
| `cf-5-shape-array-is-the-source-of-truth`  | n/a (static-check fixture)                                               | `SHAPES` array contains exactly the 12 names enumerated in this brainstorm; each name resolves to an existing `bin/retro-shape-<name>.sh` |
| `cf-6-period-passed-to-every-shape`        | Stubs record argv to a file                                              | Each stub's argv captures the same `--period-start-iso` / `--period-end-iso` values                                      |
| `cf-7-previous-period-helper-fallback`     | `$PROJECT_STATE_DIR` empty (no prior dirs)                               | `_resolve_previous_period_artifact stage-failure-summary 2026-05-16` emits `(none)`                                      |
| `cf-8-previous-period-helper-finds-prior`  | Fabricate `$PROJECT_STATE_DIR/retrospective-2026-05-09/<shape>.md`        | Helper returns absolute path to that file                                                                                |
| `cf-9-dry-run-no-git-commit-no-gh-pr`      | `PIPELINE_DRY_RUN=1`                                                     | No `git commit` / `git push` / `gh pr create` invocations recorded                                                       |
| `cf-10-pr-body-omits-empty-artifacts`      | One stub writes empty (zero-byte) artifact                               | PR body does NOT include a section for that shape (per D-006's `[[ -s ... ]]` guard)                                     |
| `cf-11-aggregator-orders-by-shapes-array`  | All stubs succeed; each writes a marker line                             | PR body section order matches the `SHAPES` array order, not filesystem order                                             |

The test creates a temp directory as `TARGET_REPO`, runs `git init`
+ initial commit so `git add -A` / `git diff --cached` work
naturally. The eleven new shape drivers are stubbed under
`STUB_DIR/bin/`; `SCRIPT_DIR` is overridden post-source per the
existing CLAUDE.md test pattern.

*Reference to constraint:* Linear AC #3 names exactly three test
paths; fixtures cf-1, cf-2, cf-3 satisfy them. The remaining
fixtures (cf-4 through cf-11) cover error/edge paths that exist in
the coordinator code but aren't named in AC; per ENG-129 D-009's
precedent of adding error-path fixtures beyond the AC bullets.

*Rejected alternative — integration test that actually invokes
each shape's `claude -p`:* rejected per existing test-suite
convention; all `bin/*-test.sh` use `PIPELINE_DRY_RUN=1` + stub
claude.

### D-011. AGENT_PROMPTS.md §9 is deleted in this ticket. The fence count discipline survives because §9 was the last numbered section; no renumbering required.

After this ticket lands, the canonical answer to "where does the
retrospective's prompt live?" is `bin/retro-prompts/<name>.md` for
every behavior. `AGENT_PROMPTS.md` returns to the invariant
ENG-129 D-002 named: "sections 1–8 are dispatch stages, period."

The §9 H2 header (`AGENT_PROMPTS.md:1735`) and the fenced block
that follows are removed in the same commit. The
`STAGE_TO_SECTION` table in `bin/render-prompt.sh:13-22` has no
entry for §9 to begin with, so it is unaffected. Tests that scan
`AGENT_PROMPTS.md` content (`bin/agent-prompts-content-test.sh`)
need a small update to drop any §9-specific assertions; an
inspection pass before commit confirms what to edit.

Pre-existing extraction code in
`bin/run-retrospective-local.sh:103-128` (the awk + sed + dispatch
block) is removed by D-001's coordinator rewrite. The two changes
land together — there is no intermediate state where §9 is gone
but the awk still tries to extract it (or vice versa). The
launchd plist (`launchd/com.twinning.retrospective.plist.template`)
points at `bin/run-retrospective-local.sh` unchanged; the external
contract (Mondays 09:00, output is a PR) is preserved.

*Reference to constraint:* CLAUDE.md "AGENT_PROMPTS.md is
load-bearing" — fence count discipline applies per-section.
Removing §9 entirely (rather than emptying it) avoids leaving a
zero-fence section that would trip
`bin/render-prompt.sh::extract_block`'s `die "expected exactly 2
fences"` guard if anything ever tried to extract it.

*Rejected alternative — keep §9 as documentation prose (no fenced
block) describing the shape architecture:* rejected because (a) the
canonical home for documentation prose about the shape pattern is
already CLAUDE.md "Retrospective shapes (ENG-129)" lines 78–95;
duplicating it in AGENT_PROMPTS.md creates two sources of truth, (b)
a numbered H2 in AGENT_PROMPTS.md visually parallels the dispatch
stages and invites future contributors to misread the file's
structure.

*Rejected alternative — defer §9 deletion to a follow-up ticket
post-rollout (to maintain the option to revert):* rejected because
(a) keeping §9 + the awk extraction code creates a "two retrospective
implementations in the same binary" state that the coordinator
explicitly forbids in AC #1, (b) reverting ENG-130 in case of
regression is a `git revert` of the merge commit, which restores both
§9 and the extraction block atomically.

### D-012. Scope fence: no new shape categories (calibration ENG-39, component audit ENG-40 explicit OUT). No per-shape model tiering (defer to ENG-103 follow-up). No parallel shape execution (defer). No structured PR body schema (defer).

The Linear ticket's "OUT" section names "New shape categories
(calibration, audit — separate tickets)." ENG-130 ships:

- The coordinator (D-001, D-002).
- Eleven new shapes mechanically extracted from §2–§12 (D-003).
- The dual-output contract (D-004).
- Per-shape failure semantics (D-005).
- Bash-side PR body aggregation (D-006).
- Tests covering the three AC paths plus error fixtures (D-010).
- Deletion of AGENT_PROMPTS.md §9 (D-011).

ENG-130 does NOT ship:

- Calibration (ENG-39) or component-audit (ENG-40) shapes.
- Per-shape model tier overrides
  (`dispatch.model[<retro-shape-name>]` — defer to an ENG-103
  follow-up that expands stage-key handling to include
  shape names).
- Parallel shape execution (defer; the claude-semaphore
  K=2 default makes it possible but the dependency-tracking
  surface is its own design problem — see OQ-2 below).
- Per-shape `usage-shape-<name>.json` cost telemetry (defer;
  same reasoning as ENG-129 §8: `PIPELINE_ISSUE_ID` gate at
  `bin/dispatch.sh:439` is the chokepoint; expanding it is
  separate scope).
- Auto-discovery of shapes from filesystem (defer; D-002 chose
  hard-coded explicitly).
- Per-target shape disabling
  (`.pipeline-config/config.json::retrospective.shapes`).
- Structured (YAML/JSON) PR body format (defer; D-006 chose
  markdown).

*Reference to constraint:* CLAUDE.md "Ticket sizing rubric" —
ENG-130 sits at the boundary of the rubric: 1 subsystem
(retrospective), but ~3 design clusters (coordinator architecture,
shape extraction mechanics, PR body composition). The eleven new
shapes are mechanical replications of one pattern, not eleven
independent designs. Each is 30-50 lines of driver + prompt + test
following the ENG-129 template; the intellectual work is the
coordinator. Acceptable for one ticket because (a) the
coordinator and the shapes ship together by AC #1's "all model work
happens inside shape scripts" — the coordinator's correctness depends
on the shapes existing, (b) reverting partial work isn't an option
once §9 is deleted; the ship boundary is "all-or-nothing".

*Rejected alternative — split ENG-130 into "(a) coordinator restructure
+ stage-failure-summary remains the only shape" and "(b) extract
remaining ten shapes in a follow-up":* rejected because (a) AC #1
("no claude invocations directly") requires §9 deletion, which
requires all eleven shapes; (b) the intermediate state — coordinator
exists but §9 still dispatches — is the worst of both designs (two
retrospective binaries in one process). The natural split point per
the rubric is "coordinator + all shapes" vs "new shape categories"
which is exactly the ENG-130 / ENG-39+ENG-40 line.

## 3. Architecture

### Files added (24 new files)

- **`bin/retro-prompts/gotcha-recurrence.md`** — §2 verbatim move + ENG-129 template restructure.
- **`bin/retro-prompts/convention-drift.md`** — §3.
- **`bin/retro-prompts/gotcha-promotion.md`** — §4.
- **`bin/retro-prompts/human-override.md`** — §5.
- **`bin/retro-prompts/expiry-verification.md`** — §6.
- **`bin/retro-prompts/confirmation-bias-audit.md`** — §7.
- **`bin/retro-prompts/recency-bias.md`** — §8.
- **`bin/retro-prompts/survivorship-bias.md`** — §9.
- **`bin/retro-prompts/knowledge-budget.md`** — §10.
- **`bin/retro-prompts/pipeline-health-score.md`** — §11.
- **`bin/retro-prompts/prompt-workflow-amendment.md`** — §12.
- **`bin/retro-shape-gotcha-recurrence.sh`** — driver mirroring `bin/retro-shape-stage-failure-summary.sh`.
- **`bin/retro-shape-convention-drift.sh`**
- **`bin/retro-shape-gotcha-promotion.sh`**
- **`bin/retro-shape-human-override.sh`**
- **`bin/retro-shape-expiry-verification.sh`**
- **`bin/retro-shape-confirmation-bias-audit.sh`**
- **`bin/retro-shape-recency-bias.sh`**
- **`bin/retro-shape-survivorship-bias.sh`**
- **`bin/retro-shape-knowledge-budget.sh`**
- **`bin/retro-shape-pipeline-health-score.sh`**
- **`bin/retro-shape-prompt-workflow-amendment.sh`**
- **`bin/retro-shape-<name>-test.sh`** — eleven test siblings, one per new shape, each ~6 fixtures (argv-missing, dry-run-happy, token-resolution, dryrun-noinvoke, artifact-production, artifact-missing, dispatch-nonzero, unknown-flag).
- **`bin/run-retrospective-local-test.sh`** — coordinator-level test per D-010 (11 fixtures).

### Files modified

- **`bin/run-retrospective-local.sh`**:
  - Add `SHAPES` array (D-002) at top of file (after env loading, before `main()`).
  - Add `_resolve_previous_period_artifact` helper (D-009).
  - Rewrite `main()`:
    - Keep lines 51–77 unchanged (today computation, fresh-checkout
      guard, branch checkout/reset).
    - Keep `_compute_retro_period` invocation unchanged (lines
      85–88) — it's the ENG-129 helper, now used by the loop instead
      of by a single shape invocation.
    - Delete lines 89–101 (existing single-shape invocation block —
      the ENG-129 hard-coded call to `retro-shape-stage-failure-summary.sh`;
      replaced by the loop body of D-005).
    - Delete lines 103–128 (existing §9 awk extraction + sed
      substitution + dispatch + cleanup).
    - Insert: the shape-iteration loop (D-005 pseudocode).
    - Insert: the PR body composition block (D-006 pseudocode).
    - Modify lines 131–138 (no-changes branch) to also slack the
      failed-shapes summary if any.
    - Modify lines 140–149 (commit/push/gh pr create) to use
      `--body-file "$pr_body_path"` (D-006).
- **`AGENT_PROMPTS.md`**: delete §9 (lines 1735 through the closing
  fence, ~1947), including the two `## …` heading and the fenced
  block.
- **`CLAUDE.md`**: update the "Retrospective shapes (ENG-129)" section
  (lines 78–95) to reflect the coordinator architecture. Specifically:
  delete the "stay inline in §9 until the coordinator ticket ships"
  sentence; replace with "All twelve behaviors are shapes; the
  coordinator (`bin/run-retrospective-local.sh`) iterates `SHAPES`
  and aggregates artifacts."
- **`bin/agent-prompts-content-test.sh`**: if it contains any §9-
  specific assertions, drop them. (Inspection pass before commit.)
- **`.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]`** —
  if the operator's harness-self config requires every `bin/*-test.sh`
  to be listed literally (per CLAUDE.md "Wildcard pitfall"), add the
  twelve new test siblings via the documented regeneration snippet.

### Files NOT modified (intentional)

- **`bin/dispatch.sh`** — D-004 reuses the existing `retrospective`
  case in `allowed_tools_for` at `bin/dispatch.sh:403`; no new case
  arm. Allowed-tools already includes `Read,Write,Edit,Grep,Glob`
  which covers every shape's needs.
- **`bin/render-prompt.sh`** — shape prompt rendering happens in
  each shape's `_render_prompt` per ENG-129 D-007; not in
  render-prompt's per-issue registry. `STAGE_TO_SECTION` table
  unchanged.
- **`bin/run-stage.sh`** — shapes are NOT pipeline stages; no
  changes to per-stage code.
- **`bin/pipeline-events.json`** — no new vocabulary. Shapes
  don't emit verdict markers; their success/failure is internal to
  the coordinator.
- **`bin/metrics.sh`** — no new metric type emitted by the
  coordinator. (Future: a coordinator-emit `retrospective-shape-end`
  metric per shape is sensible; scope creep here.)
- **`launchd/com.twinning.retrospective.plist.template`** — same
  binary entrypoint (`bin/run-retrospective-local.sh`), same trigger
  (Mondays 09:00). Internal restructure is transparent to launchd.
- **`bin/scope-check.sh` / `bin/run-local-helpers.sh::partition_dirty_paths`** —
  shapes run only inside `bin/run-retrospective-local.sh`, which
  doesn't go through the scope-sweep machinery (it's not a per-issue
  dispatch). Coordinator's `git add -A` on the retrospective branch is
  the operating-mode for picking up shape edits.
- **`learned-rules/<slug>/project-profile.md`** — shapes are
  stack-agnostic; profile doesn't gate the coordinator. §5 human-
  override DOES read the profile's `## File layout` to know which
  code-bearing dirs to diff, mirroring today's §5 behavior.
- **`docs/architecture.md`** — the two-binary topology is unchanged.
  Internal restructure of the retrospective binary. A doc update is
  reasonable AFTER ENG-130 lands and the new structure is observed
  stable for a week or two; not in this ticket.

## 4. Data flow

### Flow 1: weekly retrospective (the new common path)

```
launchd (com.twinning.retrospective, Mon 09:00)
  → bin/run-retrospective-local.sh::main()
    → fresh-checkout guard (unchanged)
    → checkout/reset working branch off origin/main (unchanged)
    → _compute_retro_period (unchanged from ENG-129)
        → emit "$period_start_iso\n$period_end_iso\n"
    → mkdir -p $PROJECT_STATE_DIR/retrospective-${today}/
    → for shape in "${SHAPES[@]}":
        → artifact="$PROJECT_STATE_DIR/retrospective-${today}/${shape}.md"
        → prev="$( _resolve_previous_period_artifact $shape $today )"
        → bash bin/retro-shape-${shape}.sh \
              --artifact-path "$artifact" \
              --period-start-iso "$period_start_iso" \
              --period-end-iso   "$period_end_iso" \
              --previous-period-path "$prev"
          → shape renders prompt, dispatches `claude -p` via
            `bash bin/dispatch.sh retrospective <rendered> <log>`
            (inherits ENG-48 isolation flags, ENG-65 gtimeout,
            ENG-81 mutex, ENG-26 cost capture gate)
            → agent Reads inputs (events.jsonl, knowledge files,
              git log, etc.)
            → agent Writes shape's artifact to
              $PROJECT_STATE_DIR/retrospective-${today}/${shape}.md
            → agent OPTIONALLY Writes/Edits checked-in files
              within the shape's declared write whitelist
          → shape validates artifact-written; returns rc=0 if so
        → coordinator records succeeded[$shape] or failed[$shape]
    → coordinator concatenates succeeded shapes' artifacts into
      $PROJECT_STATE_DIR/retrospective-${today}/pr-body.md
      (D-006 template: ## Period preamble + ---/H2 per shape +
      ## Failed shapes footer)
    → git add -A
    → if no diff: log "no changes proposed", slack info, exit 0
    → else: git commit (using twinning-pipeline-bot user); push;
            gh pr create --body-file pr-body.md
            --label pipeline-retrospective
    → slack info (or error if any failed_shapes) with summary line
```

### Flow 2: manual / debugging invocation of a single shape

Unchanged from ENG-129 Flow 2. Operator runs:

```bash
TARGET_REPO=/path bash bin/retro-shape-<name>.sh \
  --artifact-path /tmp/retro-<name>.md \
  --period-start-iso 2026-05-09T00:00:00Z \
  --period-end-iso   2026-05-16T00:00:00Z \
  --previous-period-path '(none)'
```

Each shape script is independently invocable; AC #1 doesn't change
that.

### Flow 3: dry-run path

```
PIPELINE_DRY_RUN=1 TARGET_REPO=/path bash bin/run-retrospective-local.sh
  → fresh-checkout guard
  → branch checkout
  → for shape in "${SHAPES[@]}":
      → bash bin/retro-shape-${shape}.sh ... (each in dry-run)
        → each shape logs "[DRY_RUN] would dispatch.sh ..."
        → each shape writes a placeholder artifact
  → coordinator composes pr-body.md from placeholders
  → git add -A finds no tracked-file changes (placeholders are in
    $PROJECT_STATE_DIR, not $TARGET_REPO)
  → log "no changes proposed this week"; no PR
```

The dry-run end-to-end exits 0 with `pr-body.md` materialized for
operator inspection but no PR opened.

### Flow 4: some shapes fail

```
... per-shape loop, but 3 of 12 shapes return non-zero ...
  → succeeded_shapes=(stage-failure-summary convention-drift
                      gotcha-promotion human-override
                      confirmation-bias-audit recency-bias
                      survivorship-bias pipeline-health-score
                      prompt-workflow-amendment)
  → failed_shapes=(gotcha-recurrence expiry-verification
                   knowledge-budget)
  → coordinator concatenates 9 surviving artifacts + 1 footer
  → git add -A: tracked changes exist (some surviving shapes
    edited learned-rules/, knowledge/, etc.)
  → commit + push + gh pr create
  → slack error "Weekly retrospective: 3 of 12 shapes failed:
                gotcha-recurrence, expiry-verification,
                knowledge-budget. PR opened for surviving 9."
```

## 5. Error handling

### Single shape exits non-zero (rc != 0)

Coordinator catches the rc, appends `$shape` to `failed_shapes`,
logs a single line, and continues to the next shape. The shape's
own log file under `$PROJECT_STATE_DIR/logs/retro-shape-${shape}-…`
captures the dispatch detail (per ENG-129 D-009's log_file
convention).

### All shapes exit non-zero

`succeeded_shapes` is empty. PR body would be a `## Period`
preamble + `## Failed shapes` footer with twelve entries. After
`git add -A`, the diff is empty (no shape wrote tracked files), so
the no-PR branch fires. Operator gets a slack error naming all
twelve failures; no PR clutter. This is `cf-4` fixture coverage in
D-010's test set.

### A shape returns 0 but did not write its artifact

The shape's internal `[[ -f "$artifact_path" ]]` check (per
ENG-129's `bin/retro-shape-stage-failure-summary.sh:108-109`) dies
with `shape: artifact not written at $artifact_path`. Shape's rc
becomes 1; coordinator treats as a failure (per the rc != 0 path
above).

### A shape writes its artifact AND a checked-in file edit, then crashes (rc != 0)

The agent's writes are committed to disk before the process dies
(Write/Edit are immediate). The coordinator sees rc != 0, records
the shape as failed, but the next shape's run sees the partial edit
in `$TARGET_REPO`. After all shapes complete, `git add -A` includes
the partial edit; the PR opens with it.

This is intentional: the operator should see partial work in the
PR review and decide whether to keep, revise, or roll it back. Auto-
rollback would silently mask the shape bug. D-005's "rejected
alternative — soft-rollback" rationale covers this.

### Shape's prompt rendering leaves an unresolved `{token}`

Shape's `_validate_no_unresolved_tokens` dies (per ENG-129's
`bin/retro-shape-stage-failure-summary.sh:55-74`). Shape returns
non-zero; coordinator catches per the rc != 0 path.

### Period computation returns identical start and end ISO (degenerate empty period)

If `git log --merges | grep | head -1` returns a timestamp equal to
`now` (e.g., a same-second re-run after a fresh retrospective
merge), the period is degenerate. Each shape sees a zero-length
period; the shape's own `## Insufficient-sample carve-out` (per
ENG-129's template) emits the "absent or empty" stub artifact.
Coordinator concatenates the stubs; no tracked-file changes; no PR.
Acceptable degenerate behavior.

### `gh pr create` fails (network / auth)

The coordinator's existing line 146 (`gh pr create …`) is wrapped
in the existing implicit `set -euo pipefail` behavior — failure
propagates an error exit. Add explicit failure handling:

```bash
if ! gh pr create --title ... --body-file "$pr_body_path" \
       --label pipeline-retrospective; then
  bash "$SCRIPT_DIR/slack.sh" error \
    "Weekly retrospective: gh pr create failed; commit pushed to $branch but PR not opened. Run 'gh pr create' manually."
  exit 20
fi
```

Branch is pushed; commit is on the remote; operator can manually
open the PR. No data loss.

### `$PROJECT_STATE_DIR` directory write permission denied

`mkdir -p "$shape_artifact_dir"` (line 91 today) fails with `set
-euo pipefail`. Coordinator exits non-zero; launchd next-fire is
next Monday. Operator sees the launchd log error
(`$PROJECT_STATE_DIR/logs/retrospective-launchd.err.log`).

### A shape's claude dispatch SIGTERMs at the 30-min gtimeout boundary

ENG-65 gtimeout fires; shape sees rc=124 from `gtimeout`.
Coordinator catches; shape is marked failed. The partial dispatch's
usage capture (per ENG-87 D-003 partial-usage envelope) handles
the SIGTERM-mid-dispatch case correctly because retrospective's
existing path doesn't write `usage-<stage>.json` (no
`PIPELINE_ISSUE_ID`); the partial-usage path is not exercised.
Successor shapes continue.

### Concurrent retrospective + pipeline tick

Per ENG-81, claude-semaphore K=2 caps total claude invocations.
With twelve shapes sequential and the pipeline polling every 5
minutes, the retrospective may take the K=2 slots in alternation
with pipeline ticks. Worst case: retrospective's twelve-shape run
takes ~30 min × 12 = 6h wall-clock if every shape hits its
dispatch timeout. Acceptable for a weekly job. If wall-clock becomes
operationally painful, see OQ-2 (parallelization).

### Coordinator crashes mid-loop (e.g., disk full, OOM)

`set -euo pipefail` propagates failure. Working branch `pipeline/
retrospective-${today}` may exist with partial commits if a previous
loop iteration wrote to disk. Same-day re-run will reuse the branch
(line 71–74 today: `git reset --hard origin/main`). Operator can
also `git push --delete origin pipeline/retrospective-${today}`
manually before re-running. No state leak.

### `_resolve_previous_period_artifact` returns the wrong directory because of timestamp drift

The helper sorts dated dirnames lexically (per D-009). Dirname format
is `retrospective-YYYY-MM-DD`; lexical sort is correct for ISO-8601
dates. If a future shape introduces a non-ISO date format, the sort
breaks. Mitigation: keep the dirname format frozen at
`retrospective-YYYY-MM-DD`. Test fixture cf-8 asserts the lookup
returns the expected absolute path.

### Two shapes try to edit the same file (e.g., §6 expiry + §10 budget both touch `docs/knowledge/gotchas.md`)

Today: §6 deletes entries past `expires:` date; §10 evicts entries
to fit the budget. If both shapes target the SAME entry, the
later-running shape (per the SHAPES order: §10 runs after §6) sees
the §6-deleted file as input. If §6 already removed the entry, §10
has nothing to evict for that slot; budget may be undershot. Result
is correct (the entry is gone either way).

If both shapes propose REWRITES to the same line, the second shape's
Edit may fail to find the expected text (the first shape's Edit
already changed it). The agent's Edit tool surfaces the mismatch;
the shape's prompt body instructs the agent to investigate (Read the
current file state) rather than blindly retrying. Worst case: the
second shape returns non-zero; coordinator marks it failed; the
first shape's edits stand. Operator sees the partial state in PR
review.

This is one motivation for the §1–§12 ordering choice (D-002): the
order is the dependency order from the pre-ENG-130 monolith; it
encodes which shape "wins" conflict resolution.

## 6. Edge cases

1. **First-ever ENG-130 retrospective run (no prior dated dirs).**
   `_resolve_previous_period_artifact` returns `(none)` for every
   shape that asks. Shapes that use `{previous_period_path}` see
   `(none)` and emit "no prior period available for comparison."
   per the ENG-129 template's instructions.

2. **No shape produces any tracked-file changes.** Every shape's
   artifact is written (stub or substantive) under
   `$PROJECT_STATE_DIR/retrospective-${today}/`; no checked-in file
   edits. `git add -A` shows no diff. Coordinator hits the no-PR
   branch; slack info; exits 0. Fixture cf-3 covers this.

3. **Every shape fails.** No successful artifacts to concatenate; no
   tracked-file changes; no PR. Slack `error` with all twelve
   failures. Fixture cf-4 covers this.

4. **Same-day re-run after a partial failure.** Branch exists; line
   71–74 today resets to origin/main. Every shape re-runs; new
   artifacts overwrite old (same `${today}` dir). Same-day re-run is
   idempotent. ENG-129 D-005's same-day overwrite property holds
   per-shape.

5. **The shape array contains a name that doesn't exist on disk
   (`bin/retro-shape-typo.sh` missing).** `bash bin/retro-shape-typo.sh
   …` fails with "No such file or directory"; rc != 0; coordinator
   marks `typo` as failed; continues. Fixture cf-5 statically checks
   `SHAPES` against disk to prevent this from silently regressing.

6. **The shape array DOESN'T contain a name whose driver exists on disk
   (a shape was added but never registered).** The disk shape never
   runs. Coordinator output is silently missing that section.
   Fixture cf-5 catches this by asserting `SHAPES` matches every
   `bin/retro-shape-*.sh` on disk (per ENG-94's profile-test
   precedent for asserting registry matches disk).

7. **`AGENT_PROMPTS.md` §9 is gone but operator's local config still
   references `{stage_failure_summary_path}` somewhere.** No
   consumer remains: the §9 prompt is the only reader of that
   token. Grep finds zero non-test references after the §9 deletion.
   `bin/agent-prompts-content-test.sh` may have an explicit assertion;
   update or delete.

8. **A shape's prompt body grows new tokens (e.g.,
   `{target_branch}`) but the driver wasn't updated.** Per ENG-129's
   `_validate_no_unresolved_tokens`, the unresolved `{token}` dies
   the shape. Coordinator marks failed. Symmetric to
   stage-failure-summary's behavior.

9. **Operator wants to re-run a single shape for debugging.** Per
   Flow 2 above, each shape is invocable standalone. Operator passes
   a temp artifact path. No coordinator changes needed for
   debuggability.

10. **The launchd plist isn't updated (still calls
    `bin/run-retrospective-local.sh`).** This is intentional — the
    plist's entrypoint is unchanged. Operator doesn't need to
    rerun `install-launchd.sh`.

11. **The §12 prompt-workflow-amendment shape proposes an edit to
    `.pipeline/AGENT_PROMPTS.md` itself.** Allowed under the
    retrospective allowed-tools (`Write,Edit` at
    `bin/dispatch.sh:403`). Edit appears in the PR; CODEOWNERS
    review gates merge. Same surface as today's §12 inline behavior.

12. **The §6 expiry-verification shape proposes removing an entry,
    and the §10 knowledge-budget shape then evicts a DIFFERENT
    entry from the same file.** Both edits accumulate in `git
    status`; PR contains both. Operator reviews the combined diff.

13. **Shape ordering changes the outcome (e.g., §10 runs before §6
    in a future refactor).** Bug: §10 would count
    not-yet-expired-removed entries against budget. Tests document
    the order assumption (cf-11 asserts PR-body section order =
    SHAPES order). If the SHAPES array is reordered, a follow-up
    test asserts dependency invariants — out of scope for ENG-130.

14. **A new shape ships in a follow-up (calibration ENG-39) and is
    inserted in the middle of the SHAPES array.** Insertion is
    additive; no existing shape's behavior changes. The new shape's
    name is appended to SHAPES; the registry remains a hard-coded
    array. Operators add the new shape's driver + prompt + test
    files alongside the array edit.

15. **Total wall-clock time exceeds launchd's expected
    weekly-fire boundary (e.g., retrospective takes >24h).**
    launchd doesn't kill long-running jobs; the next Monday's fire
    will see the prior week's retrospective branch (if any) and
    reuse it per line 71–74. Practical scope: 12 × 30 min cap = 6h
    worst case; well below 24h. If observed, escalate to OQ-2
    parallelization.

16. **A shape's prompt body uses a sed delimiter (`|`) that collides
    with a value in a token.** Per ENG-129 edge case 13, switch to
    ASCII unit-separator `\x1f`. The first manifestation will be a
    shape whose `_validate_no_unresolved_tokens` dies because the
    sed sub silently no-op'd. Per-shape fix; not a coordinator
    concern.

17. **The PR body grows large (e.g., 12 shapes × 100 lines each =
    1200 lines).** `gh pr create --body-file` accepts large bodies
    (GitHub limit is ~65 KB). 1200 lines × ~80 chars = ~96 KB —
    approaches the limit. Mitigation: per-shape artifact size cap
    documented in each shape's prompt body (e.g., "≤100 lines of
    markdown"). The cap is shape-side prose, not coordinator-side
    truncation; coordinator concatenates whatever the shapes
    produce.

18. **A shape's stub artifact (zero-byte or "no findings" line)
    pollutes the PR body.** D-006's `[[ -s ... ]]` guard skips
    zero-byte artifacts. Stubs that are one-line "no findings"
    still appear in the PR (one-line section per shape with no
    findings — accurate); operators can scan-skip them. If the
    operator prefers a tighter PR body, the shape's prompt can be
    amended to write zero bytes when "no findings" rather than the
    one-line stub; that's a per-shape prompt tweak, not coordinator.

## 7. Open questions

1. **OQ-1. Should the coordinator emit per-shape metrics (e.g.,
   `retrospective-shape-end` events with outcome `pass|fail|skip`)
   to events.jsonl for observability?** Today, retrospective
   overall emits no metric events; the new coordinator inherits
   that. Per-shape metrics would let a future "meta-retrospective"
   surface trends in shape reliability ("the gotcha-promotion
   shape has failed 4 of the last 5 weeks"). Defer to a follow-up;
   not blocking.

2. **OQ-2. Should the coordinator parallelize independent shapes
   (those whose write whitelists don't overlap)?** Today: sequential
   only. Independent shapes (e.g., §1 stage-failure-summary, §11
   pipeline-health-score, §8 recency-bias) could run in parallel
   under the K=2 claude-semaphore. The dependency tracking surface
   (which shapes write to overlapping files?) is the main design
   problem; deferred. Today's sequential model is operationally
   acceptable per edge case 15. Worth a follow-up if wall-clock
   becomes painful.

3. **OQ-3. Should each shape's artifact be PR-body-shaped (`## Shape
   name` H2) or should the coordinator wrap each artifact in an H2
   header from the SHAPES name?** D-006 picks the former (shape
   owns its H2 header). Alternative: coordinator owns the header,
   shape's artifact is "naked" (no top-level H2). Tradeoff:
   shape-owned headers let the shape phrase the section title
   naturally; coordinator-owned headers guarantee uniform
   formatting. Vote: shape-owned (D-006); revisit if header drift
   becomes a PR-readability problem.

4. **OQ-4. Should the coordinator persist `pr-body.md` somewhere
   stable (e.g., commit it to a `docs/retrospective-runs/`
   directory) as a permanent record beyond the PR's lifetime?**
   Today: pr-body.md sits in `$PROJECT_STATE_DIR/retrospective-${today}/`
   forever (no TTL — per ENG-129 edge case 15). Committing it would
   double-record content already in the PR description. Defer per
   ENG-129's "no per-run commit" pattern.

5. **OQ-5. The §12 prompt-workflow-amendment shape's prompt body
   instructs the agent to edit `.pipeline/AGENT_PROMPTS.md`. After
   ENG-130 deletes §9 from `AGENT_PROMPTS.md`, §12's prompt body
   needs updated phrasing (no §9 to reference). Should §12's prompt
   body be updated AS PART of ENG-130, or deferred?** Vote: update
   in ENG-130 — the §12 shape's prompt body is one of the eleven
   new files; phrasing it correctly with §9 already gone is part of
   shipping the shape. Specifically: drop §12's references to "§9
   itself" and treat it as a generic "may propose edits to the
   AGENT_PROMPTS.md retained sections 1–8 and to per-shape prompts
   under bin/retro-prompts/" instruction.

6. **OQ-6. Should the `--previous-period-path` flag be made
   shape-specific (only passed when the shape declares the token)
   to avoid pollute the flag-set?** All eleven new shape drivers
   accept the flag; only shapes whose prompt body references
   `{previous_period_path}` actually use it. Today: pass the flag
   always; shapes ignore if not needed. Alternative: coordinator
   reads each shape's prompt for `{previous_period_path}`
   reference, conditionally passes the flag. Vote: pass-always —
   the cost of an unused flag is zero; the cost of the
   conditional-passing complexity in the coordinator is non-zero.
   Not blocking.

7. **OQ-7. The coordinator currently emits one slack notification at
   the end (success-info or failure-error). Should it emit per-shape
   slack notifications for failures?** Per-shape slack would let
   operators react in real-time (e.g., kill the launchd job if four
   shapes have already failed). Single end-of-run slack is quieter.
   Vote: end-of-run only — the weekly retrospective is not a
   page-worthy event. Single notification keeps slack-noise low.
   Revisit if cascade-failure becomes a recurring symptom.

## 8. ADR stress test

This brainstorm interacts with several existing decisions:

- **ENG-129 ADR-001 (proposed): shape-extraction pattern.** ENG-130
  ratifies the pattern by extracting the eleven remaining behaviors.
  ENG-129 D-006's "halt on shape failure" coordinator policy is
  SUPERSEDED by ENG-130 D-005's "log + continue" policy — explicitly
  noted in D-005's rationale. The PoC's policy made sense for one
  shape; the coordinator's policy needs to satisfy AC #3's
  "some-shapes-skip" path. **Pressure on ENG-129 ADR-001: non-zero —
  one paragraph of the consequences section is rewritten.** ADR-001
  was filed as "proposed"; ENG-130 accepts it and refines the
  coordinator policy. Worth filing as ADR-002 (proposed) per §10.

- **ENG-26 (six-field usage-<stage>.json with cost telemetry).** The
  coordinator's shape dispatches flow through
  `bin/dispatch.sh::main` → `_render_and_capture_stream` gate at
  `bin/dispatch.sh:439` (`PIPELINE_ISSUE_ID` required). Retrospective
  dispatches today leave `PIPELINE_ISSUE_ID` unset; per-shape spend
  is invisible to the cost-telemetry system. With twelve shapes
  per run, the invisible-spend window widens 12×. **Pressure on
  ENG-26: noted but not immediate.** Future ENG could add
  `usage-shape-<name>.json` by expanding the gate to cover
  `PIPELINE_RETRO_SHAPE` env var (set by the coordinator).
  Out of scope for ENG-130.

- **ENG-48 / ENG-65 (gtimeout watchdog + per-stage timeout).**
  Each shape inherits the `retrospective` stage timeout (30 min per
  `bin/dispatch.sh:469`). Total worst-case wall-clock: 12 × 30 = 360
  min (6h). Per-shape timeout is independent (each shape gets a
  fresh gtimeout boundary), which is BETTER than today's monolith
  (one 30-min budget for twelve behaviors). **Pressure on ENG-48 /
  ENG-65: zero — the coordinator unlocks per-shape budgets.**

- **ENG-81 (per-project dispatch concurrency, K=2 default).** The
  shape dispatches consume one semaphore slot at a time (sequential
  per D-005). Twelve serial slot-acquires; the pipeline's K=2 cap
  means at most one slot is "owned" by the retrospective at a time,
  leaving one slot for pipeline ticks. **Pressure on ENG-81: zero.**
  OQ-2 (parallelization) would change this.

- **ENG-87 (cross-dispatch staleness, dispatch_id hand-off).** Each
  shape's dispatch is internal to the coordinator; no Linear-side
  state to stamp. `PIPELINE_DISPATCH_ID` remains unset for shape
  dispatches (consistent with `PIPELINE_ISSUE_ID` unset). Per
  `bin/dispatch.sh:563-565`, the empty-fallback `${VAR-}` means no
  marker injection. **Pressure on ENG-87: zero.**

- **ENG-100 (sub-agent debris).** Each shape writes exactly one
  artifact + (optionally) checked-in file edits. The artifact is
  under `$PROJECT_STATE_DIR` (no scope-sweep visibility, per ENG-129
  D-005). The checked-in edits ARE under `$TARGET_REPO` but the
  retrospective binary doesn't go through `partition_dirty_paths` —
  it operates on a dedicated branch and uses bare `git add -A` /
  `git diff --cached`. **Pressure on ENG-100: zero.**

- **ENG-103 (per-stage model tiering).** All twelve shapes inherit
  the `retrospective` subscription default (per ENG-103 D-005
  carve-out: retrospective is intentionally untiered). Per-shape
  tiering (e.g., Haiku for pipeline-health-score, Opus for
  human-override) is a sensible follow-up; defer per D-012's
  explicit scope fence. **Pressure on ENG-103: zero today.**

- **CLAUDE.md "AGENT_PROMPTS.md is load-bearing" + fence-count
  invariant.** D-011 deletes §9 entirely (removes header + fenced
  block). The remaining sections (1–8) preserve their two-fence
  shape. `bin/render-prompt.sh::extract_block`'s schema check
  (`bin/render-prompt.sh:91-109`) continues to pass for sections
  1–8; §9 is no longer in the file so the check doesn't apply to
  it. **Pressure on the AGENT_PROMPTS.md schema: zero (positive —
  the file's "sections 1–8 are dispatch stages" invariant is now
  literally true).**

- **CLAUDE.md "Retrospective shapes (ENG-129)" section.** The
  documentation paragraph names "the parent retrospective Reads
  each artifact via a `{<name>_path}` token interpolated into
  AGENT_PROMPTS.md §9." After ENG-130, this is wrong (no §9, no
  parent retrospective). D-011's CLAUDE.md update fixes the
  paragraph. **Pressure on CLAUDE.md docs: noted — one paragraph
  rewrite, no other doc surfaces affected.**

No existing ADR is overturned; one (ENG-129 ADR-001) is refined.
One new proposed ADR (ADR-002 below) names the coordinator policy.

## 9. Assumption inventory

Format: `[verified|assumed]` ITEM — `path:line` (or
"needs to be created"/"behavioral claim" for assumed items).

### Verified — code paths quoted from the current tree

- `[verified]` `bin/run-retrospective-local.sh:51` — `main()` entrypoint.
- `[verified]` `bin/run-retrospective-local.sh:38-49` — `_compute_retro_period`
  helper (introduced by ENG-129; D-008 reuses unchanged).
- `[verified]` `bin/run-retrospective-local.sh:53` — `today="$(date -u +%Y-%m-%d)"`;
  the coordinator's artifact directory uses this date variable.
- `[verified]` `bin/run-retrospective-local.sh:62-66` — fresh-checkout
  guard (`die` on dirty worktree).
- `[verified]` `bin/run-retrospective-local.sh:71-77` — branch
  checkout/reset off origin/main (idempotent on same-day re-run).
- `[verified]` `bin/run-retrospective-local.sh:89-101` — existing
  ENG-129 single-shape invocation block. D-001 deletes lines 89–101
  and replaces with the shape-loop.
- `[verified]` `bin/run-retrospective-local.sh:103-128` — existing
  §9 awk extraction + sed substitution + dispatch.sh invocation +
  cleanup. D-001 deletes these.
- `[verified]` `bin/run-retrospective-local.sh:131-138` — existing
  no-changes branch; D-007 preserves verbatim.
- `[verified]` `bin/run-retrospective-local.sh:140-149` — existing
  commit/push/gh pr create. D-006 modifies to use `--body-file`.
- `[verified]` `AGENT_PROMPTS.md:1735` — `## 9. Retrospective Agent
  (Scheduled)` header. D-011 deletes from this line through the
  closing fence (~line 1947).
- `[verified]` `AGENT_PROMPTS.md:1785-1791` — §1 paragraph now
  reading "Stage failure analysis (pre-computed): Read the
  pre-computed artifact at `{stage_failure_summary_path}`." (the
  ENG-129 edit). D-011 deletes along with §2–§12.
- `[verified]` `AGENT_PROMPTS.md:1793-1947` — §2–§12 paragraphs +
  the "Output (the retrospective PR body)" template + closing
  fence + trailing "Apply the `pipeline:rule-reviewed` label"
  / "Do NOT merge your own PR" lines. D-003 moves each §N to
  `bin/retro-prompts/<name>.md`; D-011 deletes from
  AGENT_PROMPTS.md.
- `[verified]` `bin/dispatch.sh:403` — retrospective allowed-tools
  base (`Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git
  log:*),Bash(git diff:*),Bash(git show:*),Bash(git rev-list:*),Bash(git
  describe:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),Bash(bash .pipeline/bin/guards.sh:*),Bash(bash bin/guards.sh:*),Bash(bash .pipeline/bin/metrics.sh:*),Bash(bash bin/metrics.sh:*)`). D-004 reuses verbatim;
  no allowlist edit needed.
- `[verified]` `bin/dispatch.sh:375-422` — `allowed_tools_for` per-
  stage case statement; `retrospective` arm exists.
- `[verified]` `bin/dispatch.sh:439` — `PIPELINE_ISSUE_ID` gate for
  usage capture; retrospective leaves unset. Inherited by shapes.
- `[verified]` `bin/dispatch.sh:469` — per-stage timeout resolution
  (retrospective falls through to 30-min default). Each shape gets
  its own gtimeout boundary.
- `[verified]` `bin/retro-shape-stage-failure-summary.sh` — the
  shape driver pattern D-003 mirrors for the eleven new shapes.
  Key elements: `_parse_args`, `_render_prompt`, `_validate_no_unresolved_tokens`,
  `main`, sentinel at EOF.
- `[verified]` `bin/retro-shape-stage-failure-summary.sh:108-109` —
  artifact-written check (`[[ -f "$_ARTIFACT_PATH" ]] || die …`).
  Pattern replicated by every new shape driver.
- `[verified]` `bin/retro-shape-stage-failure-summary-test.sh` — the
  sibling-test pattern D-003 mirrors. Key fixtures: argv-missing,
  dry-run, token resolution, dispatch-rc-non-zero, artifact-missing.
- `[verified]` `bin/retro-prompts/stage-failure-summary.md` — the
  prompt body shape D-003 mirrors. Key sections: `## Inputs`,
  `## Insufficient-sample carve-out`, `## Task`, `## Output schema`,
  `## Mandatory exit instructions`.
- `[verified]` `bin/common.sh:30-37` — `log`, `die` helpers (used by
  coordinator + every shape driver).
- `[verified]` `bin/common.sh:617-622` — `require_env`, `require_bin`
  (used by coordinator).
- `[verified]` `bin/common.sh:57-62` — `PROJECT_STATE_DIR`
  resolution. Coordinator and every shape use this var.
- `[verified]` `bin/render-prompt.sh:13-22` — `STAGE_TO_SECTION`
  table has NO entry for retrospective; §9 has never been part of
  the per-stage extraction surface. D-011's §9 deletion has zero
  impact on this table.
- `[verified]` `bin/render-prompt.sh:91-109` — `extract_block` fence
  count check applies to sections in STAGE_TO_SECTION (1–8); §9 was
  extracted by a local awk in run-retrospective-local.sh, not by
  render-prompt.
- `[verified]` `bin/slack.sh:12-25` — `main()` accepts `info | error`
  + body; coordinator uses both per D-005's failure-summary line.
- `[verified]` `launchd/com.twinning.retrospective.plist.template:12` —
  ProgramArguments → `bin/run-retrospective-local.sh`. Unchanged by
  ENG-130 (per "Files NOT modified").
- `[verified]` CLAUDE.md "Retrospective shapes (ENG-129)" section
  lines 78–95 — names the parent-retrospective-reads-artifact
  pattern. D-011 update rewrites this paragraph for the coordinator
  architecture.
- `[verified]` CLAUDE.md "Tests are sibling shell scripts named
  `*-test.sh` in `bin/`. There is no test runner" — new tests join
  the pre-commit hook automatically per CLAUDE.md "Pre-commit hook"
  section.
- `[verified]` `docs/architecture.md:7-14` — "Two binaries, peer
  roles". Internal restructure of one binary; external contract
  unchanged.
- `[verified]` `docs/knowledge/decisions.md` does NOT exist in the
  tree (per ENG-129 §9 verification). Proposed ADRs land inline in §10.

### Assumed — needs verification at implementation time

- `[assumed]` Eleven new prompt bodies under `bin/retro-prompts/`
  (gotcha-recurrence.md through prompt-workflow-amendment.md). To be
  created. Each is a verbatim move + restructure of one §N from the
  pre-ENG-130 `AGENT_PROMPTS.md` §9 body.
- `[assumed]` Eleven new shape drivers `bin/retro-shape-<name>.sh`.
  To be created; each ~80–100 lines mirroring
  `bin/retro-shape-stage-failure-summary.sh`.
- `[assumed]` Eleven new sibling tests `bin/retro-shape-<name>-test.sh`.
  To be created; each ~200–400 lines mirroring
  `bin/retro-shape-stage-failure-summary-test.sh`.
- `[assumed]` New coordinator-level test
  `bin/run-retrospective-local-test.sh`. To be created; ~400 lines
  covering the 11 fixtures in D-010.
- `[assumed]` `bin/agent-prompts-content-test.sh` may have
  §9-specific assertions to drop. **To verify in implementation:**
  read the test's source and adjust any §9-anchored assertions.
- `[assumed]` `.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]`
  needs regeneration to include the twelve new `bin/*-test.sh` files
  (per CLAUDE.md "Wildcard pitfall" — each test must be enumerated
  literally for the harness-self target). **To verify:** run the
  documented `jq` regeneration snippet from CLAUDE.md after the
  test files exist.
- `[assumed]` The §6 expiry-verification shape can read
  `learned-rules/<slug>/*.md` from inside the retrospective dispatch's
  Read tool boundary. **To verify in implementation:** the
  retrospective allowed-tools (`Read,Write,Edit,Grep,Glob` at
  `bin/dispatch.sh:403`) is path-unconstrained, so the agent can Read
  any file under HARNESS_ROOT including learned-rules. No allowlist
  edit needed.
- `[assumed]` `_resolve_previous_period_artifact`'s find+sort+head
  pipeline yields the correct most-recent prior directory across all
  realistic shapes. Lexical sort works for ISO-8601 dates; the
  shape's name is the directory's only suffix differentiator. **To
  verify:** fixture cf-8 asserts the helper returns the expected
  path; fixture cf-7 asserts `(none)` fallback.
- `[assumed]` Each shape's prompt body, when restructured per the
  ENG-129 template, produces output BYTE-COMPATIBLE with today's §N
  inline behavior. **Behavioral claim — verify by inspection of
  each shape's output schema in PR review:** for the verbatim-move
  shapes (§2–§11), the output schema is the relevant cell of the
  AGENT_PROMPTS.md §9 "Output" template; for §12 prompt-workflow-
  amendment, the output is the proposed edits themselves (no
  schema). Drift risk: minor — each move is mechanical.
- `[assumed]` The PR body composition order (per `SHAPES` array
  iteration) is operator-acceptable. **Behavioral claim — verify
  via fixture cf-11 + operator review of the first ENG-130 PR.**
  If operators prefer the pre-ENG-130 cross-cutting "Systemic
  findings / Proposals / Expiry decisions / …" order, that's a
  synthesizing-shape decision deferred to a follow-up; the
  bash-concatenation default is per-shape.
- `[assumed]` `gh pr create --body-file` is supported on the
  installed `gh` version. **To verify in implementation:** `gh --version`
  on the launchd host; `gh pr create --help | grep body-file`.
  The `--body-file` flag has been supported since `gh` 2.0 (released
  2022); the launchd host's gh predates ENG-23, so very likely
  supported. Fall back to `--body "$(cat pr-body.md)"` if needed.
- `[assumed]` The eleven new shape's `claude -p` invocations, in
  aggregate, do not exceed the operator's weekly subscription
  budget. **Behavioral claim — observable post-rollout via the
  operator's subscription dashboard.** Today's monolith uses
  one dispatch; the new path uses twelve. Per-shape token
  consumption is bounded by each shape's narrower context; total
  may be similar (twelve smaller contexts ≈ one large one) or
  larger (twelve full-prompt loads). Mitigation: per-shape model
  tiering (deferred to ENG-103 follow-up) can cap cheap shapes at
  Haiku.
- `[assumed]` The harness-self target's pre-commit hook
  (`.githooks/pre-commit` per CLAUDE.md) takes <60s to run the
  full `bin/*-test.sh` suite plus the new twelve test files.
  **To verify in implementation:** time the pre-commit hook before
  and after; if >60s, document the new baseline in CLAUDE.md.
  Today's hook is ~30s per CLAUDE.md; +12 new tests ~+5s each = ~90s.
  Borderline; may need to be flagged.
- `[assumed]` The `_resolve_previous_period_artifact` helper's
  `find -maxdepth 1` BSD-compatibility on macOS. **To verify:**
  `find $PROJECT_STATE_DIR -maxdepth 1 -type d -name 'retrospective-*'`
  is portable across GNU and BSD find — verified by manual test.

## 10. Proposed ADRs

`docs/knowledge/decisions.md` does not exist (per ENG-129 §9). The
single proposed ADR is filed inline below.

### ADR-002 (proposed): Retrospective coordinator policy — bash-orchestrated, log-and-continue, bash-side PR body composition

**Status:** proposed
**Date:** 2026-05-16
**Context:** ENG-129 ADR-001 introduced the shape-extraction
pattern with one shape extracted and "halt on shape failure"
coordinator semantics (suitable for a one-shape PoC). ENG-130
extracts the remaining eleven shapes and replaces the outer
"monolith dispatch" with a bash coordinator that iterates shapes,
catches per-shape failures, and aggregates surviving artifacts into
one PR.

**Decision:** The retrospective coordinator
(`bin/run-retrospective-local.sh::main`) shall:

- Iterate a hard-coded `SHAPES` array (one ordered name per shape).
- Catch per-shape rc != 0 as a non-blocking failure; log + continue.
- Compose the PR body deterministically in bash by concatenating
  succeeded shapes' artifacts under a `## Period` preamble + a
  `## Failed shapes` footer.
- Open exactly one PR when `git diff --cached` shows non-zero
  changes after all shapes run; skip the PR otherwise.
- Send exactly one slack notification per run (info when no
  changes proposed; info when PR opened with no failures; error
  when any shape failed, naming failures and the PR — if any —
  in one message).

**Consequences:**

- Per-shape failures no longer halt the whole retrospective;
  surviving shapes can still propose changes. SUPERSEDES ENG-129
  ADR-001's coordinator gating policy.
- The pre-ENG-130 cross-cutting PR body shape (Systemic findings /
  Proposals / Expiry decisions / Bias findings / Recency /
  Knowledge budget / Pipeline health) is decomposed into per-shape
  H2 sections. Operators see the same information; the visual
  organization is per-shape.
- AGENT_PROMPTS.md §9 is deleted; the file's "sections 1–8 are
  dispatch stages" invariant becomes literally true.
- The shape registry is a hard-coded bash array; adding a shape is
  a four-step process (new prompt body, new driver, new test,
  append to SHAPES). YAGNI alternatives (auto-discovery,
  config-driven registry) deferred.

**Alternatives rejected:**

- (1) Halt-on-first-failure coordinator (ENG-129's policy) — cannot
  satisfy AC #3's "some-shapes-skip" test path.
- (2) Synthesizing "compose-PR-body" shape — reintroduces the
  monolith failure mode for PR body shape; doubles spend.
- (3) Auto-discovered shape registry — loses dependency ordering,
  complicates testing, conflicts with shape-disable use case.
- (4) Structured PR body format (YAML/JSON) — no consumer asked
  for it; operator-hostile.

## 11. Persona review

Personas applied in the mandated order:
design → security → scope → coherence → product → feasibility
(feasibility is the gating persona).

### Iteration 1

#### design — PASS

D-001 through D-012 compose cleanly with one explicit refinement:
D-005 SUPERSEDES ENG-129 D-006's halt-on-failure policy with
log-and-continue. The supersession is named in D-005's rationale,
in §8 ADR stress-test, and in ADR-002 (proposed). Clean, not
hidden.

The architecture parallels existing precedents:

- `bin/run-local.sh` is a bash coordinator over per-issue
  state and dispatch decisions (the same shape as ENG-130's
  per-shape coordinator).
- `bin/setup.sh::run_phase_or_skip` iterates phases via dynamic
  dispatch (`phase_$name`). ENG-130's `SHAPES` array iteration is
  a simpler shape of the same pattern — bash array vs dynamic
  dispatch, but the same "ordered registry of per-step drivers"
  abstraction.
- ENG-129's PoC shape pattern is mechanically replicated for the
  eleven new shapes — no new architectural surface invented; the
  PoC's design judged at least once.

The 12-shape coordinator is the right size for "one ticket" because
all eleven new shapes are mechanical replications of one design.
The intellectual work concentrates in the coordinator + the
log-and-continue policy choice. Per CLAUDE.md "Ticket sizing
rubric," this is one subsystem (retrospective) with effectively
one design decision (the coordinator's iteration shape).

D-006's bash-side PR body composition is the mechanically-cleanest
delegation: anything beyond concatenation requires a synthesizing
agent (rejected per double-spend) or a structured format (rejected
per no-consumer).

No P0 / P1. One P2: the eleven new shape prompt bodies are verbatim
moves of §N from AGENT_PROMPTS.md; behavioral equivalence with the
pre-ENG-130 monolith depends on the moves being faithful. Mitigation:
each shape's prompt body is a separate commit in the PR series so
PR review can compare line-by-line. Named in §9 Assumption Inventory
as a behavioral claim verifiable at PR review.

#### security — PASS

No new auth surface. The coordinator's bash → shape drivers → claude
dispatch path is identical to ENG-129's path; all isolation
properties (ENG-48 `--setting-sources project,local`,
`--disable-slash-commands`, `--disallowed-tools`; ENG-65 gtimeout;
ENG-81 mutex; ENG-87 dispatch_id contract) inherit unchanged from
`bin/dispatch.sh`.

The expanded write surface is per-shape and prompt-bounded:

- §6 expiry-verification: docs/knowledge/, learned-rules/<slug>/
- §10 knowledge-budget: docs/knowledge/
- §12 prompt-workflow-amendment: .pipeline/AGENT_PROMPTS.md,
  .pipeline/config.json, .github/workflows/*.yml
- Other shapes: per-shape declared in each shape's prompt body

The allowed-tools `Write,Edit` permission at `bin/dispatch.sh:403`
is broader than any shape's scope; the prompt-side restriction is
the operative constraint — consistent with how every dispatched
agent stage works today (per ENG-129 D-005's analysis).

The PR body composition is bash-side `cat` of artifact files; no
shell injection surface (filenames are coordinator-controlled). The
slack notification body is a fixed string + a list of shape names
(coordinator-controlled). No external untrusted input.

CODEOWNERS gates merge of any proposed edit to AGENT_PROMPTS.md,
config.json, workflows — unchanged from today.

No P0 / P1 / P2 findings.

#### scope — PASS

The brainstorm addresses each Linear AC bullet:

- AC #1 ("run-retrospective-local.sh contains no claude invocations
  directly; all model work happens inside shape scripts"):
  satisfied by D-001 (delete lines 89–128's existing dispatch) +
  D-002 (`SHAPES` array iteration → eleven new `bash bin/retro-shape-*.sh`
  invocations) + D-011 (delete §9 from AGENT_PROMPTS.md). No
  `dispatch.sh` call inside `run-retrospective-local.sh`'s rewritten
  `main()`.
- AC #2 ("Weekly retrospective opens one combined PR across all
  shapes that produced changes"): satisfied by D-006 (bash-side PR
  body composition) + D-007 (PR opened iff `git diff --cached`
  shows changes). The PR's `--body-file` is the concatenation of
  succeeded shapes' artifacts.
- AC #3 ("Tests cover the three coordination paths"): satisfied by
  D-010's fixtures cf-1 (all-succeed), cf-2 (some-skip), cf-3
  (none-produce-changes). Eight additional fixtures cover
  error-path and edge-case coverage beyond the AC bullets.

Nothing implemented beyond AC scope:

- D-012 fences scope. Calibration (ENG-39), component-audit
  (ENG-40), per-shape model tiering, parallel shape execution,
  per-shape cost telemetry, auto-discovery, structured PR body,
  per-target shape disabling — all explicitly OUT.
- The eleven new shapes are mechanical replications of one pattern;
  no new architectural surface beyond what ENG-129 introduced.

One scope flag for operator-awareness: ENG-130 ships ~24 new files
(12 prompts + 11 drivers + 11 tests + 1 coordinator test, where one
of the prompts/drivers/tests already exists from ENG-129 leaving 11
new files in each category, plus the coordinator test = 34 files;
re-counting: 11 + 11 + 11 + 1 = 34). This is a lot of net-new files.
The intellectual work is the coordinator restructure; the rest is
boilerplate replication. PR review can be staged commit-by-commit
to make review tractable. Not a P0/P1/P2; mentioned for operator
context.

No P0 / P1 / P2 findings.

#### coherence — PASS (with one P2 note)

Internal consistency check:

- D-001 deletes the §9 dispatch from the coordinator. D-011 deletes
  §9 from AGENT_PROMPTS.md. The two deletions land together (D-011
  describes them as a single commit); no intermediate state where
  §9 is gone but the awk extraction remains, or vice versa.
  Symmetric.
- D-002's `SHAPES` array order encodes pre-ENG-130 §1–§12
  dependencies. D-009's `_resolve_previous_period_artifact` is
  invariant across shape order. D-008's period computation is
  invariant across shape order. Consistent.
- D-003's eleven new shape pattern mirrors the ENG-129 PoC; D-009's
  `--previous-period-path` flag is passed to every shape but used
  only by shapes whose prompts reference it (OQ-6). Symmetric and
  ENG-129-compatible.
- D-004's dual-output channel (artifact always; checked-in
  conditionally) is implemented by the existing dispatch.sh
  allowed-tools (no allowlist edit). D-005's failure semantics
  (log-and-continue) is implemented in the coordinator's loop, not
  in any shape. Clean separation of concerns.
- D-006's bash-side PR body composition uses `[[ -s ... ]]` to
  skip empty artifacts (edge case 18 covers). D-007's PR-opened
  gate uses `git diff --cached --quiet` (existing line 132).
  Compatible.
- D-010's fixture set covers AC #3 paths (cf-1, cf-2, cf-3) plus 8
  error/edge fixtures. Test surface matches D-005's failure
  semantics + D-006's composition + D-009's helper.
- D-011's AGENT_PROMPTS.md edit deletes §9 entirely (header + fence
  + body); D-012's scope fence prevents adding §10 (calibration) or
  §11 (audit) in this ticket. The file ends with §8 Release Agent
  after ENG-130. Clean.

One P2 coherence note: D-002's `SHAPES` array hard-codes the order
that today encodes implicit dependencies (§6 expiry before §10
budget). The dependency is NOT enforced by the coordinator (each
shape script is self-contained); the order is encoded only in the
SHAPES array. If a future ticket changes SHAPES order without
understanding the dependency, §10 may evict an entry that §6 was
about to remove (causing budget miscount). Mitigation: add a
comment block above `SHAPES=` in the coordinator explaining the
dependency. (Captured here; the brainstorm doesn't ship code, so
the comment is an implementation note.) P2.

No P0 / P1 findings.

#### product — PASS

The PoC's user (the operator) gets:

- Reliability: a confused shape (e.g., gotcha-promotion naming a
  nonexistent file) no longer blocks ten other shapes' work. PR
  review surfaces partial progress; weekly retrospective always
  produces a PR if ANY shape proposed changes.
- Observability: per-shape artifacts under
  `$PROJECT_STATE_DIR/retrospective-${date}/` give per-shape
  inspection; PR body's `## Failed shapes` footer surfaces
  failures with log paths.
- Verifiability: each shape's behavior is unit-testable (sibling
  test file). Coordinator behavior is unit-testable (D-010 fixture
  set).
- Reversibility: a `git revert` of the merge commit restores §9
  and the prior dispatch path atomically; no half-state.
- Forward-compatibility: adding a new shape (e.g., ENG-39
  calibration) is a four-step additive change; no coordinator
  surgery.

The PoC explicitly does NOT introduce:

- Operator-facing config knobs (no per-shape enable/disable, no
  per-shape model tier — deferred per D-012).
- New Linear markers or labels.
- New slack notification cadence (still one notification per run).
- Changes to the weekly schedule (launchd plist unchanged).

One operator-visible CHANGE worth flagging in the PR description:
the PR body shape changes from the cross-cutting layout (Systemic
findings / Proposals / Expiry decisions / …) to the per-shape
layout (## Stage failure summary / ## Gotcha recurrence / …).
Operators currently scanning a section like "Expiry decisions" will
now find equivalent content under the §6 shape's section. The TL;DR
in slack remains the same shape (a few headline findings); the PR
review surface is what changes.

No P0 / P1 / P2 findings.

#### feasibility — PASS

This is the gating persona; codebase-fact errors here would be P0.

Every code reference in the brainstorm has been verified against the
current tree (per §9 Assumption Inventory — Verified items have
`path:line` quotes; Assumed items are either (a) new files to be
created in implementation, or (b) behavioral claims verifiable at
implementation time or post-rollout).

Specific verification of named symbols / files / line ranges:

- `bin/run-retrospective-local.sh::main()` — verified at
  `bin/run-retrospective-local.sh:51`.
- `bin/run-retrospective-local.sh::_compute_retro_period` —
  verified at `bin/run-retrospective-local.sh:38`.
- The existing ENG-129 single-shape invocation block —
  verified at `bin/run-retrospective-local.sh:89-101`.
- The existing §9 awk extraction + sed substitution + dispatch
  block — verified at `bin/run-retrospective-local.sh:103-128`.
- The no-changes branch — verified at
  `bin/run-retrospective-local.sh:131-138`.
- The commit/push/gh pr create block — verified at
  `bin/run-retrospective-local.sh:140-149`.
- `AGENT_PROMPTS.md` §9 H2 header — verified at line 1735.
- `AGENT_PROMPTS.md` §9 fenced block — verified to start at line 1737
  and span through line 1947 by inspection. §9 is the file's only
  retrospective section (per `grep -n '^## 9' AGENT_PROMPTS.md`
  returning line 1735) and the only section absent from
  `bin/render-prompt.sh::STAGE_TO_SECTION` (lines 13–22).
- `bin/dispatch.sh::allowed_tools_for`'s `retrospective` arm —
  verified at `bin/dispatch.sh:403`.
- `bin/dispatch.sh::_render_and_capture_stream`'s
  `PIPELINE_ISSUE_ID` gate — verified at `bin/dispatch.sh:439`.
- Retrospective's per-stage timeout default — verified at
  `bin/dispatch.sh:469` (falls through to 30 min).
- `bin/retro-shape-stage-failure-summary.sh::main` and its
  `_parse_args / _render_prompt / _validate_no_unresolved_tokens`
  helpers — verified by inspection of the file's 115 lines.
- `bin/retro-shape-stage-failure-summary-test.sh` fixture pattern —
  verified by inspection of the file's 579 lines (13 production
  fixtures + 4 QA-adversarial fixtures).
- `bin/retro-prompts/stage-failure-summary.md` template structure —
  verified by inspection of the file's 71 lines.
- `bin/common.sh::log` and `die` — verified at lines 30 and 34.
- `bin/common.sh::PROJECT_STATE_DIR` resolution — verified by
  inspection of common.sh's `_setup_project_state_dir` (per ENG-129).
- `bin/render-prompt.sh::STAGE_TO_SECTION` — verified at lines 13–22;
  no retrospective entry.
- `bin/slack.sh::main` accepts `info | error` — verified at line 23–25.
- `launchd/com.twinning.retrospective.plist.template` ProgramArguments —
  verified at line 12.
- CLAUDE.md "Retrospective shapes (ENG-129)" — verified at lines 78–95.

NEW symbols (to be created in implementation per D-002/D-003/D-009/D-010):

- `SHAPES` array in `bin/run-retrospective-local.sh` (new; D-002).
- `_resolve_previous_period_artifact` helper in
  `bin/run-retrospective-local.sh` (new; D-009).
- Eleven new `bin/retro-prompts/<name>.md` files (new; D-003).
- Eleven new `bin/retro-shape-<name>.sh` drivers (new; D-003).
- Eleven new `bin/retro-shape-<name>-test.sh` siblings (new; D-003).
- One new `bin/run-retrospective-local-test.sh` (new; D-010).

The "new symbol" items are appropriately marked as `[assumed]` in §9
and the exact files to be created are named.

One adversarial check on a key assumption: D-002's claim that the
SHAPES array order encodes pre-ENG-130 dependency is verifiable by
reading the AGENT_PROMPTS.md §9 source: §6 "Expiry verification"
mentions that §10 "Knowledge-budget enforcement" counts entries;
§3/§4 (candidate harvesting) feeds §7 (bias audit). The §1–§12
numerical order reflects this. Reading the file confirms the
dependency claim.

One adversarial check on D-006's claim that `gh pr create
--body-file` is supported: GitHub's `gh` CLI `--body-file` flag has
been documented since at least 2022 (gh v2.x); the harness's
launchd host should have a recent gh per the install instructions.
If `gh` is too old, fallback per §5's "gh pr create fails" path is
`--body "$(cat pr-body.md)"`.

No P0 / P1 / P2 findings.

### Iteration 1 verdict

All six personas: PASS. Feasibility persona returned zero P0
findings.

**Gate status: 6/6 PASS · feasibility P0: 0 · proceeding to planning**

No iteration 2 required.

## 12. Summary

This brainstorm proposes restructuring
`bin/run-retrospective-local.sh` into a deterministic bash
coordinator that iterates an ordered `SHAPES` array of twelve
shape names. Each shape is an independently-invocable driver
(`bin/retro-shape-<name>.sh`) with its own prompt body
(`bin/retro-prompts/<name>.md`), its own sibling test
(`bin/retro-shape-<name>-test.sh`), and its own artifact at
`$PROJECT_STATE_DIR/retrospective-${date}/<name>.md`.

Concrete changes:

1. Eleven new prompt bodies under `bin/retro-prompts/` (verbatim
   moves of §2–§12 from the pre-ENG-130 `AGENT_PROMPTS.md` §9 body,
   restructured per the ENG-129 template).
2. Eleven new shape drivers + eleven new sibling tests under `bin/`,
   mechanically replicated from the ENG-129
   `bin/retro-shape-stage-failure-summary.sh` pattern.
3. One new coordinator-level test
   `bin/run-retrospective-local-test.sh` covering AC #3's three
   coordination paths plus eight error/edge fixtures.
4. Rewritten `bin/run-retrospective-local.sh::main()` that:
   iterates `SHAPES` sequentially, catches per-shape failures
   (log + continue), composes the PR body in bash by concatenating
   succeeded shapes' artifacts under a `## Period` preamble +
   `## Failed shapes` footer, opens exactly one PR if any
   tracked-file changes accumulated, sends exactly one slack
   notification per run.
5. Deletion of `AGENT_PROMPTS.md` §9 in its entirety; the
   "sections 1–8 are dispatch stages" invariant becomes literally
   true.
6. CLAUDE.md "Retrospective shapes (ENG-129)" paragraph rewrite to
   reflect the coordinator architecture.

ENG-129 ADR-001 (the shape-extraction pattern) is refined by
ADR-002 (proposed) which formalizes the coordinator policy
(bash-orchestrated, log-and-continue, bash-side PR body
composition). ENG-129 D-006's halt-on-shape-failure policy is
SUPERSEDED by ENG-130 D-005's log-and-continue policy — explicitly
noted because the supersession is a non-trivial behavior change
that the PoC's "one shape" constraint had hidden.

Calibration (ENG-39), component-audit (ENG-40), per-shape model
tiering (ENG-103 follow-up), parallel shape execution, per-shape
cost telemetry, auto-discovery, structured PR body, and per-target
shape disabling are all explicit OUT per D-012.

Pre-existing ADRs (ENG-26, ENG-48, ENG-65, ENG-81, ENG-87, ENG-100,
ENG-103) are unchanged. The CLAUDE.md "AGENT_PROMPTS.md is
load-bearing" invariant strengthens (sections 1–8 are now literally
all dispatch stages).
