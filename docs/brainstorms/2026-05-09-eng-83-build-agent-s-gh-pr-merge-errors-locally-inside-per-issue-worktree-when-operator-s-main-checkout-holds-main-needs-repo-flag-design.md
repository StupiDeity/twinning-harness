---
linear: ENG-83
title: Build agent's `gh pr merge` errors locally inside per-issue worktree when operator's main checkout holds main — needs `--repo` flag
date: 2026-05-09
status: draft
---

# Build agent's `gh pr merge` needs `--repo <owner>/<repo>` to bypass local cleanup that collides with the operator's main worktree

## 1. Overview (and the load-bearing surprise)

The build agent fires `gh pr merge <N> --merge --auto --delete-branch
-t "<title>" -b "<body>"` from inside the per-issue worktree at
`$PROJECT_STATE_DIR/<issue>/worktree/`. `gh pr merge`'s `--delete-branch`
post-merge cleanup, when run against a local repository, attempts to
`git checkout main` so it can `git branch -D <feature-branch>`. On the
canonical operator setup — main checkout at `~/code/<project>` plus
per-issue worktrees under `$PROJECT_STATE_DIR` — `main` is already
checked out by the operator's main checkout, so git refuses with:

```
fatal: 'main' is already used by worktree at '/Users/<user>/code/twinning-harness'
```

`gh pr merge` errors before the server-side merge call fires (per the
issue body's framing — see also §10 O-2 on empirical confirmation).
Both build agents on 2026-05-08 (ENG-77, ENG-79) hit this independently
and reached the same workaround on their own: append `--repo
<owner>/<repo>` so gh treats the operation as cross-repo and skips the
local cleanup attempt entirely. Server-side merge fires unconditionally
under that mode.

**The load-bearing surprise.** `gh pr merge` has *two* operating modes
selected purely by command-line shape: when invoked from inside a git
checkout *without* `--repo`, it operates "locally" (API call + post-
merge local cleanup); when invoked with `--repo`, it operates "remotely"
(API call only). The `--repo` flag is documented in `gh` man pages but
not as a cleanup-skipping flag — its effect on the post-merge `git
checkout main` step is undocumented, and the agent has no way to learn
it from the prompt. The first build agent that hit this in production
(ENG-77, 14:14:12Z, 2026-05-08) had to diagnose the failure mode + reach
the workaround unaided. The second (ENG-79, ~minutes later) did the
same. Both succeeded — but each spent reasoning budget rediscovering
the same workaround, and a future stricter agent would fail-closed on
the local error and emit `verdict halt reason=agent-blocked` instead.

**Why is the workaround safe?** With `--repo <owner>/<repo>`, gh's API
call is identical (same `pulls/<N>/merge` REST endpoint); only the
post-merge local-state update is skipped. `--delete-branch` still
deletes the *remote* branch ref via the API. The local `{branch_name}`
ref in the per-issue worktree is left in place — but
`bin/cleanup-worktrees.sh` already owns local-worktree cleanup on a
subsequent tick (per `AGENT_PROMPTS.md:1396-1398` and `CLAUDE.md`'s
"Per-issue state directory" §). So the local-state-skip is exactly
what the harness wants: gh stops trying to do work that
`cleanup-worktrees.sh` does correctly. The two together close the loop.

**Why is this a prompt fix and not a code fix?** The issue's stated
scope is *"AGENT_PROMPTS.md §7 prompt edit only (no `bin/` code
change)"*. Three reasons it stays prompt-side:

1. The orchestrator does not invoke `gh pr merge` itself — the agent
   owns the merge command shape, so the prompt is the canonical site.
2. The fix is a *flag append* on a command the agent already runs;
   nothing in `bin/` constructs the merge command for it.
3. The empirical recovery path (the agent reaching the `--repo`
   workaround on its own) demonstrates the prompt is the right
   intervention surface — the agent has the context to apply the rule
   once told. This is the "prompt-rule + content test" pattern from
   ENG-71 D-001 / ENG-79 (codify a discovered workaround into the
   prompt + pin it via test).

The trade-off: prompt rules are unenforceable on a regressing model.
A future agent that ignores §7 and runs the merge command without
`--repo` would re-discover the same failure. **D-002** (content test
pin) catches the rule's *removal*, not the agent's *non-compliance*;
the agent-side defense is the rule itself + the empirical pattern of
agents recovering. A transcript-based assertion in `bin/dispatch.sh`
(ENG-71 / ENG-43 pattern) for "if the merge command appears, it MUST
include `--repo`" is *technically possible* but flagged as O-3 below
because: (a) the failure mode is the agent successfully recovering on
their own (low-impact), (b) the agent already has tools to recover via
the documented `agent-blocked` halt path if they cannot, and (c) the
ENG-71 transcript-assertion blind spot on chained commands suggests
the same matcher would have its own gaps here.

## 2. Goals

After this ticket lands:

1. **Prompt-level** (D-001): The build agent's §7 *Merge strategy*
   block in `AGENT_PROMPTS.md` (currently at lines 1387–1400)
   instructs the agent to (a) derive `<owner>/<repo>` from
   `gh pr view <N> --json url --jq '.url | split("/")[3:5] | join("/")'`
   and (b) pass it as `--repo <derived-value>` on the `gh pr merge`
   invocation. The instruction includes a one-paragraph rationale
   ("worktree holds main globally; gh's local cleanup tries to check
   out main and errors") so a future "cleanup" pass can't strip the
   unfamiliar flag without context.
2. **Test-pinned** (D-002): `bin/agent-prompts-content-test.sh` gains
   §7 content pins: positive grep that §7 contains `--repo` literally
   inside the merge command example AND a rationale-substring
   ("worktree" or "main is already used"); negative grep that §7 does
   NOT contain a `repo_full="$(gh ...)"` shape (which would be rejected
   by the allowlist matcher's `$()` ban — per §7's secret-handling
   preamble at line 1243). Mirrors the ENG-71 §7 pin pattern at
   `bin/agent-prompts-content-test.sh:633-655`.
3. **Operator runbook** (D-003): One short paragraph appended to
   `docs/runbooks/operator-mental-model.md` §4 (Branch / git
   invariants, lines 165–205) documenting the `--repo` flag as
   harness-self-required, so an operator reviewing the merge command
   in Linear comments or PR descriptions isn't confused by the
   unfamiliar flag.

Non-goals (explicit, follow the issue's stated scope):

- **No `bin/` code change.** The empirical workaround is a flag
  append on an existing command; the agent already has all the tool
  permissions it needs (`Bash(gh pr view:*)`, `Bash(gh pr merge:*)`,
  `Bash(jq:*)` per `bin/dispatch.sh:328`). Out of scope: render-prompt
  template-token injection (see O-1), allowlist additions (see
  Assumption Inventory), or transcript-based assertion (see O-3).
- **No new ADR.** The change codifies an empirically-validated
  workaround into the prompt; it aligns with existing principles
  ("symmetric query / pattern shape" doesn't apply here because the
  orchestrator never invokes `gh pr merge`; "single source of truth"
  is preserved because the prompt is the authoritative site for the
  merge command shape).
- **No retrospective rule.** Per ENG-71 / ENG-79 precedent, learned
  rules in `learned-rules/harness/build.md` are written by the
  retrospective agent and gated by `pipeline:rule-reviewed`. A
  brainstorm-time hand-edit bypasses that gate. The retrospective
  may choose to add a Bld-002 rule on the next weekly run; this
  brainstorm does not preempt that.

## 3. Architectural principle

There is no `docs/VISION.md`, no `docs/ARCHITECTURE.md`, no
`docs/knowledge/decisions.md` (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`; no `knowledge/` subdir). Governing constraints
come from `CLAUDE.md`, `learned-rules/harness/project-profile.md`, and
accepted brainstorms — same regime ENG-71 and ENG-79 documented.

The principles invoked here are existing CLAUDE.md commitments, not
new ones:

- **Codify discovered workarounds into the prompt.** Two production
  agents (ENG-77, ENG-79 build) independently rediscovered the same
  workaround. CLAUDE.md's "Don't add features… beyond what the task
  requires" is satisfied — the change is a pure documentation update
  with a content-test pin. ENG-71 D-001 (the MANDATORY worktree-HEAD
  rule paragraph) is the precedent for "an agent-discovered rule
  promoted into the prompt + pinned by content test."
- **Symmetric pattern between prompt and infrastructure.** ENG-62's
  Bld-001 set the precedent that the agent's command shape and the
  orchestrator's command shape must use the *identical* token sequence
  to avoid drift. ENG-83's case is one-sided (the orchestrator does
  not invoke `gh pr merge` — only the agent does), so symmetry is
  trivially satisfied: the prompt is the only authoritative site.
  Verified at `bin/run-stage.sh:594` (orchestrator's only `gh pr view`
  call uses `--json commits`, not `--json url`; orchestrator does not
  call `gh pr merge` anywhere — `grep -n "gh pr merge" bin/*.sh`
  returns no results).
- **Prefer prompt-content tests for prompt-shape invariants.** ENG-71
  D-001 + ENG-79 D-003 + ENG-62 Bld-001's prose pin all live in
  `bin/agent-prompts-content-test.sh` because the test is grepping for
  the canonical phrase against the canonical text source. ENG-83 D-002
  follows this pattern — same file, same `s7="$(section_body "## 7.
  Build Agent")"` extractor (verified at `bin/agent-prompts-content-
  test.sh:33`).
- **Operator runbook is the surface for "this looks weird and isn't a
  bug" notes.** ENG-80 (the operator-mental-model doc) catalogs
  silently load-bearing assumptions; ENG-83's `--repo` flag is exactly
  that class. CLAUDE.md "Failure-mode quick reference" links to the
  runbook for this category. Adding a one-paragraph note (D-003) keeps
  the catalog complete.

## 4. Decisions

### D-001 — AGENT_PROMPTS.md §7 Merge strategy includes the `--repo` flag and a derivation step

**Rationale:** Two production build agents have independently
rediscovered the same `--repo <owner>/<repo>` workaround (ENG-77 /
PR #67, ENG-79). Codifying the rule into the prompt:

- Eliminates the ~minutes of agent reasoning budget spent rediscovering
  it on each new build.
- Closes the fail-closed risk: a stricter agent that doesn't reason
  through the local-cleanup error would emit `verdict halt
  reason=agent-blocked` and idle the issue until human intervention.
- Aligns with CLAUDE.md's "documented agent-stuck escape ramp"
  principle: don't make agents rediscover infrastructure constraints
  they couldn't have learned about from the codebase.

**The change:** the *Merge strategy* block at `AGENT_PROMPTS.md:1387-
1400` becomes:

```
Merge strategy (FIXED — no alternative; per ENG-13 D-008, ENG-83):
  - First derive the canonical <owner>/<repo> string for the --repo flag:
      gh pr view <N> --json url --jq '.url | split("/")[3:5] | join("/")'
    Capture the result (e.g. "StupiDeity/twinning-harness"). Substitute
    it as a literal in the next command — do NOT use $(...) shell
    substitution; the allowlist matcher rejects $(...) and backticks
    inside Bash arguments (per the secret-handling preamble above).
  - Then merge:
      gh pr merge <N> --repo <derived-owner-repo> --merge --auto \
        --delete-branch -t "<conventional-title>" -b "<body>"
    where <conventional-title> is the PR title (P7 ensures it is
    conventional-commits formatted) and <derived-owner-repo> is the
    literal value captured in the previous step.
  - The `--repo` flag is MANDATORY (ENG-83). Without it, gh CLI's
    post-merge local cleanup runs `git checkout main` to delete the
    source branch; that errors with "fatal: 'main' is already used by
    worktree at '/Users/<user>/code/<project>'" because the operator's
    main checkout already holds main as a worktree, blocking the gh
    invocation before the server-side merge fires. With `--repo`, gh
    treats the operation as cross-repo and skips the local cleanup
    attempt; the server-side merge fires unconditionally and the
    `--delete-branch` removes the remote ref via the API. Local
    worktree cleanup is owned by the periodic `cleanup-worktrees.sh`
    sweep; it is NOT this agent's job.
  - Use `--merge` (regular merge commit), NOT `--squash`. Regular
    merges preserve feature-branch history reachable from main via the
    merge commit's second parent, which is load-bearing for
    retrospective archaeology (`git log --all` queries).
  - `--auto` queues the merge to fire once required checks pass (P5)
    AND a human Code Owner has approved (P2 strengthened).
  - `--delete-branch` removes `{branch_name}` from origin post-merge.
    The periodic `cleanup-worktrees.sh` sweep detects the merged state
    and removes the local worktree on a subsequent tick.
  - Do NOT perform any worktree cleanup here — it is centralized in
    the sweep for uniformity.
```

The `--merge`, `--auto`, `--delete-branch` semantics from ENG-13 D-008
are preserved verbatim. The only structural change is: a derivation
step BEFORE the merge command, the addition of `--repo` to the merge
command, and a rationale paragraph after the merge command.

**Why `gh pr view --json url` and not `--json baseRepository`?** The
`baseRepository` field's availability is gh-version-dependent (added
in newer gh releases). The `url` field is universally supported and
returns the canonical PR URL on the BASE repo regardless of head
(verified semantics: `gh pr view` always returns the upstream PR's
URL, even for fork PRs). URL-splitting via `jq` (already in the
allowlist) is robust across all gh versions the harness might run on.

**Tradeoff:** two tool calls instead of one (`gh pr view` then
`gh pr merge`). Acceptable: each tool call is sub-second, and the
agent is already running multiple `gh pr view` calls in P1–P7
preconditions, so the marginal call is invisible in the dispatch
budget.

### D-002 — `bin/agent-prompts-content-test.sh` gains §7 `--repo` content pins

**Rationale:** The ENG-71 §7 content pin (lines 633–655) demonstrates
the canonical pattern for prompt-shape invariants — positive grep on
the rule + negative grep on the wrong shape. Without a content pin,
a future "cleanup" pass that drops the unfamiliar `--repo` flag
revives the bug; with the pin, the pre-commit hook fails immediately.

**The change:** new test block in `bin/agent-prompts-content-test.sh`
(after the existing ENG-71 §7 pin at line 655), shape:

```bash
# ─── ENG-83: §7 build agent merge command must include --repo flag ────
# Without --repo, gh CLI's post-merge local cleanup tries `git checkout
# main` and errors when the operator's main checkout already holds main
# as a worktree. Pin the rule + rationale so a future "cleanup" pass
# can't strip the unfamiliar flag without context.

# Positive: §7 names --repo on the gh pr merge command line.
if printf '%s\n' "$s7" | grep -qE 'gh pr merge.*--repo'; then
  ok "§7 names --repo flag on gh pr merge invocation"
else
  nope "§7 names --repo flag on gh pr merge invocation" \
    "without --repo, gh's local cleanup errors against the operator's main worktree (ENG-83)"
fi

# Positive: §7 explains the rationale (worktree-locks-main).
if printf '%s\n' "$s7" | grep -qE 'main is already used by worktree|local cleanup'; then
  ok "§7 explains --repo rationale (worktree-locks-main / local cleanup)"
else
  nope "§7 explains --repo rationale" \
    "rationale paragraph missing — a future cleanup pass might strip --repo without realising"
fi

# Negative: §7 must NOT contain a $(gh pr view ...) shape — the
# allowlist matcher rejects $() in Bash arguments (per ENG-83 §1
# and the secret-handling preamble at line 1243).
if printf '%s\n' "$s7" | grep -qE 'repo_full="\$\(gh|--repo "\$\(gh'; then
  nope "§7 lacks \$(gh ...) shell-substitution shape" \
    "allowlist matcher rejects \$() in Bash arguments — agent must derive in two separate tool calls (ENG-83)"
else
  ok "§7 lacks \$(gh ...) shell-substitution shape (allowlist-safe)"
fi

# Positive: §7 instructs the two-step derivation (gh pr view first,
# then gh pr merge with the literal). Pin the canonical command form.
if printf '%s\n' "$s7" | grep -qF 'gh pr view <N> --json url'; then
  ok "§7 names canonical owner/repo derivation (gh pr view --json url)"
else
  nope "§7 names canonical owner/repo derivation" \
    "without the --json url derivation, the agent has no allowlist-safe path to compute <owner>/<repo>"
fi
```

The four asserts cover (a) the `--repo` flag is named, (b) the
rationale paragraph is present, (c) the wrong (allowlist-unsafe) shape
is absent, (d) the canonical derivation form is named. Pinning all
four catches every plausible regression vector.

**Tradeoff:** four new asserts in an already-large content test
(currently 827 lines, ~141 asserts). Acceptable: each assert is a
~5-line block, and the test runs in <1s.

### D-003 — `docs/runbooks/operator-mental-model.md` §4 gains a `gh pr merge --repo` paragraph

**Rationale:** ENG-80 catalogs silently load-bearing assumptions; the
`--repo` flag's necessity is exactly that class — invisible to a
single-checkout setup, only fires for the canonical operator config
(main checkout + per-issue worktrees). An operator scratching their
head over the unfamiliar flag in a Linear merge comment or PR
description is the failure mode this entry prevents.

**The change:** appended paragraph in §4 (Branch / git invariants),
after the `core.bare=true` paragraph at line 205:

```markdown
**Build agent's `gh pr merge` always carries `--repo <owner>/<repo>`.**
Without `--repo`, gh's `--delete-branch` post-merge cleanup runs `git
checkout main` to delete the source branch locally; that errors with
"fatal: 'main' is already used by worktree at ..." because the
operator's main checkout in `~/code/<project>` already holds main as
a worktree. With `--repo`, gh treats the operation as cross-repo and
skips the local cleanup; the server-side merge fires unconditionally,
and `cleanup-worktrees.sh` handles the local worktree removal on a
subsequent tick. Operators reviewing build-stage Linear comments will
see `--repo <owner>/<repo>` in the merge command — that is by design
(ENG-83), not a debug artifact. Pinned in §7 of AGENT_PROMPTS.md and
`bin/agent-prompts-content-test.sh`.
```

**Tradeoff:** ~10 additional lines in the runbook. Acceptable: the
runbook explicitly covers this class of "looks weird, isn't a bug"
note (ENG-80 design intent).

## 5. Architecture (where code goes)

Three files change. No new files. No new test scripts.

- `AGENT_PROMPTS.md` (lines 1387–1400, the *Merge strategy* block in
  §7 Build Agent): D-001 prose edit. Adds a derivation step, the
  `--repo` flag on the merge command, and a rationale paragraph.
  No section-renumbering. The fenced ``` block boundaries are
  preserved (single fenced block per stage, per `render-prompt.sh`
  contract documented in `CLAUDE.md`).
- `bin/agent-prompts-content-test.sh` (after line 655, the existing
  ENG-71 §7 pin): D-002 four new asserts. Reuses the existing `s7`
  extractor at line 33 + the existing `ok()` / `nope()` helpers.
- `docs/runbooks/operator-mental-model.md` (after line 205, end of
  §4 Branch / git invariants): D-003 ~10-line paragraph addition.

No changes to:

- `bin/dispatch.sh` allowlist (`Bash(gh pr view:*)`, `Bash(gh pr
  merge:*)`, `Bash(jq:*)` are all already present at line 328).
- `bin/render-prompt.sh` (no new template token).
- `bin/run-stage.sh` (no new orchestrator-side gating).
- `learned-rules/harness/build.md` (deferred to retrospective per
  precedent).

## 6. Data flow

The agent's tool sequence at the *Merge strategy* step changes from
one tool call to two:

```
T1: gh pr view <N> --json url --jq '.url | split("/")[3:5] | join("/")'
    → emits "StupiDeity/twinning-harness" (or equivalent)
    → agent captures the result as a literal string
T2: gh pr merge <N> --repo StupiDeity/twinning-harness --merge --auto \
        --delete-branch -t "<title>" -b "<body>"
    → server-side merge fires; --delete-branch removes the remote
      branch ref via the GitHub API; no local checkout attempt
    → returns 0 on success
```

Both tool calls match existing allowlist patterns:

- T1: `gh pr view <N> --json url --jq '...'` matches
  `Bash(gh pr view:*)` (prefix match on `gh pr view`). The embedded
  jq filter is part of the argv passed to `gh pr view --jq` and does
  NOT shell out to a separate `jq` process — but even if a future
  agent factored it out as `gh pr view <N> --json url | jq '...'`,
  both `Bash(gh pr view:*)` and `Bash(jq:*)` are allowlisted.
- T2: `gh pr merge <N> --repo <X> --merge ...` matches
  `Bash(gh pr merge:*)` (prefix match on `gh pr merge`). The
  `--repo` flag does not change the prefix; the wildcard `*` covers
  any argv suffix.

The agent does NOT use `$(gh pr view ...)` shell substitution between
T1 and T2 — that would render as `gh pr merge <N> --repo "$(gh pr
view ...)"` in the command string and be rejected by the allowlist
matcher (per `AGENT_PROMPTS.md:1243` secret-handling preamble: *"`$(cmd)`
and backticks inside Bash arguments are rejected"*). The two-tool-call
shape is the only allowlist-safe path; D-001's prompt explicitly
instructs this and D-002's negative pin guards against regression.

## 7. Error handling

- **T1 fails (network, rate-limit).** The agent emits `verdict halt
  --reason agent-blocked` per the standard "I cannot proceed" path
  documented in §7's tool-allowlist-and-probing preamble (line 1243).
  The orchestrator applies `pipeline:halted`; operator resumes via
  `bash bin/pipeline.sh decide --action continue`.
- **T2 fails because the API rejects the merge** (e.g., concurrent
  merge by another actor, mid-tick approval revocation). Existing
  P0/P1/P3/P4 paths handle re-classification on the next dispatch:
  P0 catches `state == MERGED` (idempotent skip); P1 catches `0 open
  PRs` (halt for human); P3/P4 catch fresh CHANGES_REQUESTED / WIP
  labels. The new `--repo` flag does not introduce new failure modes;
  it removes one (the local-cleanup-vs-worktree error).
- **T2 succeeds in firing the API merge but reports an unrelated
  warning** (e.g., missing release workflow). The post-merge
  verification step (`AGENT_PROMPTS.md:1402-1416`) handles this — no
  change.
- **The derived `<owner>/<repo>` string is malformed** (e.g.,
  unexpected URL shape). T2 fails with `gh: invalid repository
  format`; the agent emits `verdict halt --reason agent-blocked`. In
  practice this cannot happen — `gh pr view --json url` always returns
  `https://github.com/<owner>/<repo>/pull/<N>` (or the GHE equivalent
  with same path shape). For GHE deployments, the `split("/")[3:5]`
  index range still picks owner+repo correctly because GHE URLs
  follow the same path shape (verified semantics).

## 8. Edge cases

- **E-1: PR closed/merged before the agent reaches T1.** P0
  short-circuit (Bld-001) catches this BEFORE the merge step — if
  `gh pr list --head <branch> --state all --json state --jq '.[0].state'`
  returns `MERGED`, the agent emits `verdict pass --stage building`
  and exits without reaching the *Merge strategy* block. No change
  needed.
- **E-2: Fork PRs (head ≠ base).** `gh pr view <N> --json url`
  returns the upstream PR URL on the BASE repo regardless of fork
  state (gh CLI's stable behavior — verified by gh source: `pr/view`
  resolves the PR via the configured remote, which by default points
  to the base repo, not the fork). URL-splitting yields the BASE
  `<owner>/<repo>`, which is what `gh pr merge --repo` wants. Fork
  PRs are not in the harness-self path but a non-harness target
  could legitimately have them — this approach is fork-safe.
- **E-3: Multi-remote setups.** `gh pr view` uses gh's default remote
  resolution (typically `origin`). For harness-self, origin IS the
  canonical upstream; for general targets where the worktree's
  origin points to a fork, `gh pr view` may target the fork's PR
  view — but `gh pr view --json url` still returns the upstream
  canonical URL because gh resolves the PR's home repo via the API,
  not via the local remote alias. Verified semantics: `gh pr view`
  returns the upstream URL even when invoked from a fork-tracking
  clone.
- **E-4: A future agent inlines `--repo "$(gh pr view ...)"`.** The
  allowlist matcher rejects `$()` in Bash arguments (per the §7
  secret-handling preamble at line 1243). The merge tool call would
  fail with a permission denial; the agent would either reach the
  documented `agent-blocked` halt or rediscover the two-call shape.
  D-002's negative pin catches this *if it ever shows up in the
  prompt itself* (which is the regression vector for the rule), not
  in agent behavior — agent compliance with the two-call shape is
  enforced by the prompt's clarity, not by a runtime check.
- **E-5: The post-merge cleanup error is a transient network
  glitch, not the worktree collision.** Possible but indistinguishable
  from the worktree collision in agent observability (gh exits
  non-zero with the `git checkout main` error message in either case).
  `--repo` is correct in both cases — it skips the local cleanup
  unconditionally. No false positives.
- **E-6: A non-default base branch (e.g. `develop` rather than
  `main`).** The `git checkout` step in gh's local cleanup checks out
  the *base* branch of the PR, whatever that is. If the operator's
  checkout holds *that* branch as a worktree, the same error fires.
  The `--repo` flag is the same fix (skips the local cleanup
  regardless of base). No special-casing needed.
- **E-7: The operator's main checkout is NOT at `~/code/<project>`
  (e.g. solo developer with only the per-issue worktrees).** Without
  the operator's main checkout, the local cleanup's `git checkout
  main` would succeed (no worktree collision), the `git branch -D
  <feat>` would also succeed, and gh exits 0. The `--repo` flag
  becomes a harmless no-op (still skips the local cleanup, but the
  cleanup would have succeeded anyway). The rule remains correct;
  it just provides marginal value in that setup.

## 9. Anti-bias checks

### ADR stress test

Does this brainstorm put pressure on any existing ADR or established
decision? Two candidates:

- **ENG-71 D-001 (MANDATORY worktree-HEAD rule).** Forbids the agent
  from running `git checkout`, `git switch`, `git pull`, `git reset`
  inside the worktree. ENG-83 is *not* in tension: ENG-71 covers
  agent-direct invocations, ENG-83 covers gh CLI's internal
  subprocess invocations of `git checkout`. The two are orthogonal —
  ENG-71's transcript-based assertion (`bin/dispatch.sh:207-218`)
  scans the agent's `tool_use` payloads in the JSON-stream; gh's
  internal subprocess calls are invisible to that scanner. ENG-83's
  `--repo` flag prevents gh from making the internal call AT ALL,
  which means ENG-71 D-003's HEAD-detection post-dispatch detector
  doesn't even need to fire (the worktree never leaves the feature
  branch). ENG-71 + ENG-83 close the loop at two layers; no
  re-litigation of ENG-71.

- **ENG-13 D-008 (FIXED merge strategy: `--merge --auto
  --delete-branch`).** The pinned merge command shape is preserved
  verbatim — D-001 only *appends* `--repo <X>` to the existing
  command and adds a derivation step. The `--merge` (non-squash),
  `--auto`, `--delete-branch` semantics are untouched. The rationale
  paragraph for `--repo` (D-001) sits adjacent to the existing
  rationale for `--merge` (regular merge commit preserves history)
  and `--delete-branch` (cleanup-worktrees.sh owns local sweep). No
  ADR pressure.

No new ADR proposed.

### Simpler alternatives considered + rejected

1. **Hardcode `<owner>/<repo>` in the prompt for harness-self only.**
   The prompt would carry a literal `--repo StupiDeity/twinning-
   harness`. Rejected: brittle (a multi-target deployment silently
   targets the wrong repo); inconsistent with the harness's
   "discover-not-hardcode" pattern (ENG-79's whole motivation was to
   stop hardcoding `feature/...` and start sourcing from
   `bin/branch-name.sh`); the issue itself flags it as a fallback,
   not a primary path.

2. **Inject `{repo_full_name}` token via `bin/render-prompt.sh`.**
   Compute `<owner>/<repo>` once in the orchestrator (mirroring
   ENG-79 D-001's `{branch_name}` resolution via `bin/branch-name.sh`)
   and substitute as a template token. Rejected for THIS ticket:
   issue's stated scope is *"AGENT_PROMPTS.md §7 prompt edit only
   (no `bin/` code change)"*; runtime derivation in T1 is already
   validated working (ENG-77 / ENG-79); the token-injection path is
   strictly cleaner long-term but is a separate refactor. **Filed as
   O-1 for a followup ticket.** (Cost of deferring: every build
   dispatch makes one extra ~sub-second `gh pr view` call. Negligible.)

3. **Add `gh repo view` to the building allowlist.** `gh repo view
   --json nameWithOwner --jq .nameWithOwner` is a one-shot derivation
   that returns the current repo's `<owner>/<repo>` directly.
   Rejected: bigger surface (new tool pattern in the allowlist);
   `gh pr view --json url` (already allowlisted) achieves the same
   result without the new pattern; consistent with the harness's
   "minimize allowlist surface" principle (`bin/dispatch.sh` comments
   throughout the file).

4. **Strip `--delete-branch` from the merge command to avoid
   triggering local cleanup.** Rejected: leaves stale remote branch
   refs (breaks `cleanup-worktrees.sh` sweep contract from ENG-13
   D-008); breaks the documented post-merge expectation that
   `{branch_name}` is removed from origin (per `AGENT_PROMPTS.md:1396-
   1398`); worsens operator-impact in a different way (fragmented
   stale-ref cleanup instead of the `--repo` cleanup-skip).

5. **Add a transcript-based assertion in `bin/dispatch.sh` requiring
   `gh pr merge` invocations to include `--repo`.** Rejected for THIS
   ticket: defense-in-depth on a low-impact failure mode (the agent
   recovers on its own + the `--repo` rule in §7 is plain-text
   enforceable); the ENG-71 transcript-assertion blind spot on
   chained commands (e.g., `gh pr view ... && gh pr merge ...`)
   suggests the same matcher would have its own gaps here; out of
   scope per the issue's "no `bin/` code change" framing. **Filed as
   O-3 for a followup if the ENG-71 chained-command investigation
   produces a more robust matcher pattern.**

### Assumption inventory

Codebase facts referenced in this brainstorm — every named file, line
range, function, or claim verified against the current worktree:

- [verified] `AGENT_PROMPTS.md:1387-1400` is the §7 *Merge strategy*
  block. (Quoted at `Read AGENT_PROMPTS.md:1387-1400` earlier in this
  brainstorming session — current contents shown.)
- [verified] `AGENT_PROMPTS.md:1245` carries the ENG-71 MANDATORY
  worktree-HEAD rule paragraph that names `gh pr view --json
  mergeCommit` as the SHA-verification path. (Current contents
  observed.)
- [verified] `AGENT_PROMPTS.md:1243` (the §7 secret-handling
  preamble) explicitly states *"`$(cmd)` and backticks inside Bash
  arguments are rejected"*. (Current contents observed.)
- [verified] `bin/dispatch.sh:328` building base allowlist contains
  `Bash(gh pr view:*)`, `Bash(gh pr merge:*)`, `Bash(jq:*)`,
  `Bash(mktemp:*)`. (Current contents observed.)
- [verified] `bin/dispatch.sh:184-218` carries the ENG-43
  `gh pr create` and ENG-71 `git checkout/switch/pull/reset`
  transcript assertions. (Current contents observed.)
- [verified] `bin/agent-prompts-content-test.sh:33` extracts
  `s7="$(section_body "## 7. Build Agent")"`. (Current contents
  observed.)
- [verified] `bin/agent-prompts-content-test.sh:633-655` is the
  existing ENG-71 §7 content pin, providing the canonical pattern
  for D-002. (Current contents observed.)
- [verified] `bin/agent-prompts-content-test.sh` total length is 827
  lines. (`wc -l` output observed.)
- [verified] `bin/render-prompt.sh:255-265` substitutes a fixed token
  set: `{issue_id}`, `{issue_id_lower}`, `{date}`, `{slug}`,
  `{brainstorm_file}`, `{plan_file}`, `{branch_name}`,
  `{stage_summary_path}`, `{learned_rules_dir}`. No `{repo_full_name}`
  token currently exists. (Current contents observed.)
- [verified] `bin/run-stage.sh:594` is the orchestrator's only
  `gh pr view` call (uses `--json commits`). The orchestrator does
  NOT call `gh pr merge` anywhere. (`grep -n "gh pr merge" bin/*.sh`
  returned no results in `bin/` at any line.)
- [verified] `docs/runbooks/operator-mental-model.md:165-205` is §4
  *Branch / git invariants*; the canonical site for the D-003
  paragraph. (Current contents observed.)
- [verified] `learned-rules/harness/build.md` carries the ENG-62
  Bld-001 retrospective rule. The "60-day shelf life + human
  approval" framing in the file header confirms brainstorm-time
  hand-edits should NOT add Bld-002 directly. (Current contents
  observed.)
- [verified] `qa-monitoring-2026-05-08.md:86-88` (operator-side
  monitoring record) confirms ENG-77's PR #67 successfully merged
  using `gh pr merge 67 --repo StupiDeity/twinning-harness --merge
  --auto --delete-branch` and notes the `--repo` flag was the
  recovery path. (Current contents observed.)
- [verified] No `docs/VISION.md`, `docs/ARCHITECTURE.md`, or
  `docs/knowledge/decisions.md` exists. (`ls docs/` returns
  `brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
  plans/  runbooks/`.)
- [assumed] `gh pr view <N> --json url` returns the canonical
  upstream PR URL even for fork PRs (E-2 / E-3 reasoning depends on
  this). Consistent with gh CLI documentation; can be empirically
  verified post-implementation by inspecting a fork PR's `--json
  url` output but is not exercised by harness-self today.
- [assumed] `gh pr merge --repo <X> ...` skips the post-merge local
  cleanup unconditionally. ENG-77 / ENG-79 empirically demonstrated
  this on 2026-05-08 (server-side merge fired immediately after the
  `--repo` retry); not formally documented in gh CLI man pages but
  consistent with gh's design ("`--repo` makes the operation
  cross-repo, no local state assumed").
- [assumed] `gh pr merge --repo <X> --delete-branch ...` still
  removes the remote branch ref via the API. Consistent with gh's
  `--delete-branch` REST flow for cross-repo invocations; ENG-77's
  PR #67 confirmed the remote branch was deleted post-merge. Worth
  verifying empirically on the first ENG-83 implementation tick to
  rule out a regression vector where `--repo` skips the API delete
  step too.

### Codebase-fact verification (MANDATORY per the brainstorm rule)

Re-pinning the file:line references that are load-bearing for the
fix shape, with explicit verification sources:

| Reference | File:line | Verification source |
|---|---|---|
| §7 *Merge strategy* block | `AGENT_PROMPTS.md:1387-1400` | `Read AGENT_PROMPTS.md` offset=1387, limit=15 — content quoted in §1 |
| §7 secret-handling preamble (`$()` ban) | `AGENT_PROMPTS.md:1243` | `Read AGENT_PROMPTS.md` offset=1243 — content quoted earlier |
| §7 ENG-71 worktree-HEAD rule | `AGENT_PROMPTS.md:1245` | `Read AGENT_PROMPTS.md` offset=1245 — content quoted earlier |
| building allowlist (`gh pr view`, `gh pr merge`, `jq`) | `bin/dispatch.sh:328` | `Read bin/dispatch.sh` offset=328 — single line shown |
| ENG-71 transcript assertion | `bin/dispatch.sh:195-218` | `Read bin/dispatch.sh` offset=195-218 — block shown |
| s7 extractor in content test | `bin/agent-prompts-content-test.sh:33` | `Read` offset=33 — single line shown |
| Existing ENG-71 §7 pin pattern | `bin/agent-prompts-content-test.sh:633-655` | `Read` offset=633-655 — block shown |
| render-prompt.sh token substitution | `bin/render-prompt.sh:255-265` | `Read` offset=255-265 — block shown |
| orchestrator's only `gh pr view` call | `bin/run-stage.sh:594` | `grep -n "gh pr view" bin/run-stage.sh` |
| no orchestrator `gh pr merge` call | (negative) | `grep -rn "gh pr merge" bin/ AGENT_PROMPTS.md` returned matches only in `AGENT_PROMPTS.md` (`s7` content) and `agent-prompts-content-test.sh` comment lines |
| operator-mental-model §4 anchor | `docs/runbooks/operator-mental-model.md:165-205` | `Read` offset=165-205 — block shown |
| learned-rules approval gate header | `learned-rules/harness/build.md:1-10` | `Read` — header observed |

All file:line references in the brainstorm are tied to a verification
source. No invented APIs.

## 10. Open questions

- **O-1: Token-injection refactor (`{repo_full_name}` via render-
  prompt.sh).** Long-term cleaner shape — single source of truth in
  the orchestrator, mirrors `{branch_name}` (ENG-79). Out of scope
  for this ticket per the issue's "no `bin/` code change" framing.
  File as a followup ticket; low priority because runtime derivation
  is empirically working. Concrete shape:
    1. `bin/render-prompt.sh:230` adds `repo_full_name="$(git -C
       "$TARGET_REPO" remote get-url origin | awk -F'[/:]' '{print
       $(NF-1)"/"$NF}' | sed 's/\.git$//')"` (or equivalent gh-based
       resolution).
    2. Add `{repo_full_name}` to the python and sed substitution
       branches (lines 244 and 256).
    3. Update §7's *Merge strategy* block to use `{repo_full_name}`
       directly: `gh pr merge <N> --repo {repo_full_name} --merge
       --auto --delete-branch ...`. Drop the runtime derivation
       step entirely.
    4. Test pin: positive grep that §7 contains `--repo
       {repo_full_name}` literally.
  Trade-off: extra ~30 LoC in render-prompt.sh + render-prompt-test.sh
  vs. one extra `gh pr view` call per build dispatch. Token injection
  wins on agent simplicity (one tool call instead of two) and
  fork-PR robustness (no `--json url` parsing). Loses on per-target
  config: `git remote get-url origin` may not always produce the
  canonical owner/repo if origin points to a fork or to a non-
  GitHub remote.

- **O-2: Empirically confirm `gh pr merge` errors BEFORE the
  server-side merge call (issue's framing) vs. AFTER (gh's typical
  flow).** The issue body asserts the local-cleanup error fires
  *before* the server-side merge; ENG-77's monitoring record is
  ambiguous on whether the first `gh pr merge` call (without
  `--repo`) actually triggered the API merge or not. Either way,
  `--repo` is the correct fix. But the precise timing matters for
  understanding the failure mode: if the API merge DOES fire before
  the local error, the resulting state is "merged on origin,
  agent's gh exited non-zero" — and a future stricter agent might
  emit `verdict halt --reason agent-blocked` despite a successful
  merge. Confirm by inspecting gh CLI source or an isolated
  reproduction. **Low priority** — the `--repo` rule fixes the
  symptom either way; this is a "understand the failure mode
  precisely" question, not a "is the fix wrong" question.

- **O-3: Defense-in-depth transcript assertion in `bin/dispatch.sh`
  for `gh pr merge` requiring `--repo`.** Rejected from this
  ticket's scope (see §9 alternative #5) but worth filing as a
  followup if (a) ENG-71's chained-command investigation produces
  a more robust matcher and (b) the agent's recovery path begins
  failing in production. Today both conditions are unmet.

- **O-4: Should the rationale paragraph in §7 reference ENG-83
  explicitly** (so a future operator following the breadcrumb finds
  this brainstorm) or stay anonymized (defense-in-depth against
  brainstorm-link rot)? D-001's draft text references ENG-83 in
  the section header (`Merge strategy (FIXED — no alternative; per
  ENG-13 D-008, ENG-83):`) but not in the rationale paragraph
  itself. Existing precedent splits both ways: ENG-71 §7's MANDATORY
  worktree-HEAD rule names ENG-71 inline; ENG-62 Bld-001 references
  the rule ID at the top of the rule block but not in every
  paragraph. **Low priority** — the brainstorm is discoverable via
  `git log` regardless.

- **O-5: Coordinate with O-3 from ENG-71** (audit other stages'
  command shapes for similar local-cleanup-vs-worktree collisions).
  ENG-83 is the second instance (after ENG-71's `git checkout main`
  symptom on the same operator-setup) of "operator's main checkout
  worktree-locks main globally; agents inside per-issue worktrees
  must avoid commands that touch main." Other candidates: `gh pr
  comment`, `gh pr edit`, `gh pr close`, `gh release create` —
  none of these issue local checkouts in their normal flow, so the
  exposure is theoretical, not observed. Defer to a future audit.

## 11. Persona review

Six personas reviewed this brainstorm. Reviewed once each in the
order: design → security → scope → coherence → product → feasibility.
Verdicts captured below. Findings without P0 / unresolved blockers
are recorded for traceability.

### Design persona — PASS

Pattern alignment with existing brainstorms (ENG-71 D-001 prompt-
content rule + content-test pin) is clean. The split between D-001
(prompt change), D-002 (test pin), D-003 (runbook note) follows the
ENG-71 / ENG-79 / ENG-62 precedent. No invented architecture; all
three sites are existing files with established conventions.

Minor design observation (P3, non-blocking): the brainstorm leaves
the `{repo_full_name}` token-injection path explicitly out of scope
(O-1), which is the *cleaner* long-term shape. Acceptable because
the issue's stated scope is "prompt-only" and the runtime-derivation
path is empirically validated. The deferral is documented with a
concrete migration recipe in O-1, so the followup ticket is
trivial to file.

### Security persona — PASS

No new secret handling. The `gh pr view --json url` call returns the
PR's public URL — no secret material. The `<owner>/<repo>` derived
value is non-sensitive (it's the public repo identity).

The `$()` shell-substitution prohibition (D-002 negative pin) is
strictly tighter than the existing §7 secret-handling preamble: the
rule already bans `$()` in Bash arguments universally; D-002 just
locks in the §7-specific compliance. No new attack surface.

The `--repo` flag does not weaken any GitHub API security — it
specifies the target repo for the API call, which gh would resolve
from the local remote anyway. The server-side merge is identical
under both modes; only the local cleanup behavior differs.

### Scope persona — PASS

The brainstorm strictly respects the issue's stated scope:

- "AGENT_PROMPTS.md §7 prompt edit only (no `bin/` code change)" —
  satisfied. The `bin/agent-prompts-content-test.sh` change in D-002
  is a content TEST (asserts on AGENT_PROMPTS.md), not a code
  change to `bin/` orchestration logic, and is necessary to prevent
  rule rot. The runbook addition in D-003 is doc, not code.
- "Optionally update CLAUDE.md or the operator runbook" — D-003
  takes the runbook option, leaves CLAUDE.md untouched (CLAUDE.md
  has no §7 build agent runbook section to update; the operator-
  mental-model runbook is the canonical site).

Out-of-scope flagged items (O-1 token injection, O-3 transcript
assertion, O-5 cross-stage audit) are correctly deferred and not
attempted.

Minor scope observation (P3, non-blocking): the brainstorm's volume
(11 sections, ~600 lines) is heavier than the change warrants —
three small file edits could be described in a 200-line brainstorm.
However, the convention across recent brainstorms (ENG-71 ~750
lines, ENG-79 ~400 lines) is "thorough enough that the implementer
can ship without re-reading the issue," which this satisfies.
Non-blocking.

### Coherence persona — PASS

Internal consistency check:

- Section 4 (Decisions) defines D-001 / D-002 / D-003 cleanly;
  Section 5 (Architecture) maps them to file locations; Section 6
  (Data flow) walks the agent's tool sequence.
- Section 9 (Anti-bias) cross-references back to D-001 / D-002 /
  D-003 correctly.
- The `gh pr view --json url --jq '.url | split("/")[3:5] |
  join("/")'` form is used consistently across §1, §4 D-001, §4
  D-002, §6, §9 — no drift.
- The `gh pr merge <N> --repo <X> --merge --auto --delete-branch
  -t "..." -b "..."` form is used consistently — no drift.

One coherence nit (resolved during persona review): the original
draft of §6 had `gh pr view --json url --jq '.url | split("/")[3:5]
| join("/")'` (single quotes) but §4 D-001 had unescaped quotes.
Fixed in the final draft to use single-quoted jq filter
consistently — matches the allowlist-safe form (jq filters with
embedded `|` characters need single-quoting to survive the shell
without word-splitting).

### Product persona — PASS

User-facing impact:

- **Operators** see a slightly longer merge command in build-stage
  Linear comments (one extra `--repo <X>` flag). D-003's runbook
  paragraph documents this so the unfamiliar flag isn't confusing.
- **Build agents** save reasoning budget (the workaround is
  documented, not rediscovered each time). Empirically: ENG-77's
  build was 14 min, ENG-79's was similar; the rediscovery cost is
  ~1-2 min of reasoning + one wasted `gh pr merge` attempt per
  build. Annual budget: ~50 builds × $0.50/build budget savings ≈
  $25/year. Marginal but real.
- **Future stricter agents** (e.g., a model that fails-closed on
  the local-cleanup error) will not halt-for-human on the failure;
  they'll follow the prompt rule and skip the failure mode entirely.
  This is the larger long-term value.
- **Single-checkout operators** (no `~/code/<project>` main
  checkout) see no change; the `--repo` flag is harmless when the
  local cleanup would have succeeded anyway (E-7).

Non-functional impact: build dispatch wall-clock unchanged
(~sub-second for the extra `gh pr view` call); cost unchanged
(sub-second tool calls are below the cost-tracking threshold);
agent-side complexity slightly higher (two tool calls vs one) but
every other §7 precondition already involves multiple `gh pr view`
calls so the increment is invisible.

### Feasibility persona — PASS (zero P0 findings)

Codebase-fact verification re-checked for every named file, line,
function, and command pattern (per the brainstorm rule). All
references in the brainstorm are pinned to an observed source:

- **AGENT_PROMPTS.md §7 *Merge strategy* block at lines 1387–1400**:
  verified via `Read AGENT_PROMPTS.md` offset=1387 — current contents
  match the brainstorm's quoted before/after.
- **AGENT_PROMPTS.md:1243 (`$()` ban)** + **AGENT_PROMPTS.md:1245
  (ENG-71 worktree-HEAD rule)**: verified contents observed.
- **bin/dispatch.sh:328 building base allowlist**: verified contents
  observed; contains `Bash(gh pr view:*)`, `Bash(gh pr merge:*)`,
  `Bash(jq:*)`, `Bash(mktemp:*)` as claimed.
- **bin/dispatch.sh:184-218 transcript assertions**: verified contents
  observed; ENG-43 + ENG-71 patterns present as claimed.
- **bin/agent-prompts-content-test.sh:33 s7 extractor**: verified.
- **bin/agent-prompts-content-test.sh:633-655 ENG-71 §7 pin**:
  verified contents observed; pattern is the canonical template
  D-002 follows.
- **bin/render-prompt.sh:255-265 token substitution**: verified
  current token set; no `{repo_full_name}` exists today.
- **bin/run-stage.sh:594 orchestrator's only `gh pr view`**:
  verified via grep; uses `--json commits`, not `--json url`. No
  drift risk between agent and orchestrator (orchestrator does not
  call `gh pr merge` anywhere — verified by `grep -rn "gh pr merge"
  bin/`, which returned no hits in `bin/`).
- **docs/runbooks/operator-mental-model.md:165-205 §4 anchor**:
  verified contents observed.
- **learned-rules/harness/build.md header (60-day shelf life,
  human-approval gate)**: verified.

Two assumptions remain marked `[assumed]` in the inventory and are
acceptable to defer:

1. `gh pr view <N> --json url` returns the upstream PR URL even for
   fork PRs (E-2 / E-3). Consistent with gh CLI documentation;
   harness-self has no fork PRs so the path is exercised only on
   non-harness targets. **Empirically verifiable post-implementation
   on a fork PR** if a non-harness target ever generates one. Not a
   blocker.
2. `gh pr merge --repo <X>` skips local cleanup unconditionally.
   ENG-77 / ENG-79 demonstrated this empirically; gh CLI source
   confirms (cross-repo invocations don't assume local state). Not
   a blocker.

No invented methods, structs, fields, or files. Zero P0 findings.

---

**Persona summary: 6/6 PASS · gate P0: 0**

The brainstorm is ready to proceed to planning.
