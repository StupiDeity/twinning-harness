---
linear: ENG-74
date: 2026-05-07
topic: prompt-text fix forbidding env-var prefixes (e.g. `PIPELINE_WRITER=agent`) on `bash bin/...` invocations + per-stage test pin
---

# Plan — ENG-74 forbid env-var prefix on agent's `bash bin/...` invocations

> **For agentic workers:** REQUIRED SUB-SKILL — use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to walk this task-by-task. Steps use
> `- [ ]` for tracking.

Implementation plan for the design in
`docs/brainstorms/2026-05-07-eng-74-build-agent-wait-exit-fails-pipeline-writer-agent-bash-bin-pipeline-sh-rejected-by-sandbox-allowlist-design.md`.

## Anti-anchoring

- **Problem (operator's words):** the build agent attempts
  `PIPELINE_WRITER=agent bash bin/pipeline.sh event ENG-N verdict wait
  --reason awaiting-approval` for the ENG-45 wait-exit path, the Claude
  sandbox matcher rejects the invocation (the first token is
  `PIPELINE_WRITER=agent`, not `bash`), and the agent exits silently —
  `run-stage.sh`'s no-output detector classifies it as `agent-failure`
  and applies `pipeline:halted`. Every issue that reaches build
  pre-approval hits this; bursts risk tripping the breaker
  (`.consecutive-failures ≥ 3`).
- **Does the brainstorm address it?** Yes — and the brainstorm reframes
  one detail: the Linear issue proposed a §7-only prompt edit; the
  brainstorm broadens to all 9 stages because the matcher gotcha is
  matcher-shape, not stage-shape (build is just the empirical hit).
  Reframe is justified by §1.3 (any stage that nudges the agent to
  reason about lanes can hit the same matcher) and §8.2 alt A (same
  edit cost, strictly broader coverage). The brainstorm explicitly
  flags this as scope expansion (§9) and notes that reverting to
  §7-only during planning is trivial — but the universal-paragraph
  approach is strictly more durable.
- **Proportional?** Yes. Two-file diff: ~5 lines × 9 sites in
  `AGENT_PROMPTS.md` (~45 lines), ~15 lines of test in
  `bin/agent-prompts-content-test.sh` (one new iteration loop with two
  assertions per stage, mirroring the existing ENG-53 #11 / ENG-57 /
  ENG-55 / ENG-56 multi-stage loops). No new helpers, no schema change,
  no orchestrator change, no learned-rules edit, no `bin/dispatch.sh`
  allowlist change, no new dynamic-prompt surface (rejected D-001 alt B
  / §8.2 alt B), no `bin/run-stage.sh` change (per D-004).
- **No escalation needed.**

## Goal

Append one sentence forbidding env-var prefixes (e.g.
`PIPELINE_WRITER=agent`) on `bash bin/...` invocations to the universal
"Tool allowlist & probing" paragraph at all 9 stage sites in
`AGENT_PROMPTS.md`, and pin its presence per-stage in
`bin/agent-prompts-content-test.sh`, such that the next build
dispatch on a not-yet-approved PR runs `bash bin/pipeline.sh event ENG-N
verdict wait --reason awaiting-approval` (no prefix), the wait verdict
lands, and the orchestrator re-dispatches on the next tick — verifiable
via `bash bin/agent-prompts-content-test.sh && bash bin/render-prompt-test.sh && bash -n bin/agent-prompts-content-test.sh`
exiting 0 with the new ENG-74 assertions (18 new lines, 9 stages × 2
assertions) all PASS.

## Architecture

The change is two files:

1. `AGENT_PROMPTS.md` — append one sentence to the existing universal
   "Tool allowlist & probing" paragraph at each of 9 sites
   (lines 246, 361, 567, 714, 855, 1068, 1232, 1483, 1595 — see §3.1
   below). The sentence wedges between the existing "retry with the
   same sig — never mutate it (ENG-57)" sentence and the existing
   "If you cannot accomplish your task with the documented tools..."
   sentence. The paragraph is plain prose (no triple-backtick), so
   `bin/render-prompt.sh::extract_block`'s fence-count contract
   (`fence_count == 2` per H2 section) is unchanged.
2. `bin/agent-prompts-content-test.sh` — append one new iteration
   loop after the existing ENG-57 same-sig loop (lines 294-325). The
   loop iterates the same 9 stage sections used by the surrounding
   loops, asserts the new instructional substring is present in each,
   and asserts the canonical forbidden form `PIPELINE_WRITER=agent` is
   named in each (so the agent sees the exact forbidden shape, not
   just a prose hint).

Architecturally trivial — no new control flow, no new state, no new
helpers. The brainstorm's §3.1 / §3.2 / §3.3 already specify the exact
edit sites.

There is no `docs/VISION.md`, no `docs/knowledge/decisions.md`, no
`SYSTEM_ARCHITECTURE.md` in this repo (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`). Governing constraints come from `CLAUDE.md` and
`learned-rules/twinning/plan.md` rules P-001 (frontmatter `linear:
ENG-N`) and P-002 (enumerate every signature change). P-002 binds even
though no Bash function signatures change here — the test-loop
extension still gets a `path:line` quote per A-009 below.

## Tech stack

- Bash 3.2+ (Darwin default, harness target).
- No `jq`, `gh`, `gtimeout`, `git`, or `claude` interaction in the
  changed code paths.
- No new dependencies. No `bin/dispatch.sh::allowed_tools_for` cases
  added. No `bin/render-prompt.sh` change. No `bin/run-stage.sh`
  change. No `bin/pipeline-events.json` registry edits.
- The test extension uses only `printf` + `grep -qF` (literal-string
  match) per the precedent in the surrounding loops.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the
current worktree per learned-rules P-002 and B-001 (no "follows the
existing pattern" without an excerpt). The brainstorm's §8.3 and §8.4
already verified most of these; this section restates the load-bearing
claims with quoted excerpts so the implementing agent can edit without
re-reading the brainstorm.

### Modified files — current signatures, call sites, and edit-point boundaries

- **A-001 — `AGENT_PROMPTS.md` contains the universal "Tool allowlist
  & probing" paragraph at exactly 9 sites.** Verified by grep:

  ```
  246:**Tool allowlist & probing (ENG-53 #11 / ENG-57):** Your `--allowed-tools` permission grants a fixed list of Bash patterns. ...
  361:**Tool allowlist & probing (ENG-53 #11 / ENG-57):** ...
  567: ...
  714: ...
  855: ...
  1068: ...
  1232: ...   ← §7 Build Agent (the empirical hit on ENG-64)
  1483: ...
  1595: ...
  ```

  The 9 occurrences are byte-for-byte identical (verified by
  `grep -c "Tool allowlist & probing (ENG-53 #11 / ENG-57)"
  AGENT_PROMPTS.md` returning 9). The implementing agent applies the
  same insertion to each occurrence.

- **A-002 — Each occurrence's terminal sentence ends with `...do not
  probe.` immediately before the next paragraph.** Verified at
  `AGENT_PROMPTS.md:1232` (representative; identical at all 9 sites).
  The new sentence lands AFTER `Sig variants like ... duplicate Linear
  comments.` and BEFORE `**If you cannot accomplish your task with the
  documented tools, run \`bash bin/pipeline.sh event {issue_id} verdict
  halt --reason agent-blocked\`...`. This mid-paragraph insertion
  preserves the surrounding sentence rhythm.

- **A-003 — `AGENT_PROMPTS.md:1230` is the §7 Secret-handling sentence
  (`**Secret-handling (ENG-46):**`).** Verified — the universal
  "Tool allowlist & probing" paragraph follows on line 1232 in §7.
  Insertion in §7 only touches line 1232's paragraph; line 1230 is
  unchanged. The same shape holds for every other section: the
  `Tool allowlist & probing` paragraph is its own line and the new
  sentence wedges inside that single line (the paragraph is rendered
  as one unwrapped line in the source, per `grep -n` showing 9 single
  hits).

- **A-004 — `bin/render-prompt.sh::extract_block` requires exactly 2
  column-0 ``` fences per H2 section.** Verified per CLAUDE.md
  "AGENT_PROMPTS.md is load-bearing" §; runtime check at
  `bin/render-prompt.sh:35-61` (per the ENG-62 plan §3.1's reference
  to this same contract). The new sentence is plain prose (no
  triple-backtick), so fence count remains 2 in every section.

- **A-005 — `bin/dispatch.sh:361` wraps the `claude -p` subprocess
  with `env PIPELINE_WRITER=agent ...`.** Verified:

  ```
  361:  local cmd=(env PIPELINE_WRITER=agent
  362:    gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
  363:    claude -p
  ```

  Means: `PIPELINE_WRITER=agent` is inherited into every shell the
  agent spawns. The new sentence's claim "the orchestrator already
  exports `PIPELINE_WRITER=agent` for your dispatch via
  `bin/dispatch.sh::main`" is grounded.

- **A-006 — `bin/common.sh:293-294` defaults `PIPELINE_WRITER` to
  `orchestrator` and exports it.** Verified:

  ```
  293:PIPELINE_WRITER="${PIPELINE_WRITER:-orchestrator}"
  294:export PIPELINE_WRITER
  ```

  Means: even outside the agent path the env var is always exported.
  The agent's prefix is therefore never required at the env layer; it
  is purely the agent's defensive over-provisioning that introduced
  it. This grounds the rule's "the prefix is redundant" claim.

- **A-007 — `bin/pipeline.sh:124-131` warns (does NOT refuse) on
  `PIPELINE_WRITER != agent` when posting a verdict.** Verified:

  ```
  124:  # Lane fence: agents emit verdicts. dispatch.sh sets PIPELINE_WRITER=agent
  ...
  129:  if [[ "$PIPELINE_WRITER" != "agent" ]]; then
  130:    log "warning: PIPELINE_WRITER=$PIPELINE_WRITER writing a verdict (lane mismatch — set PIPELINE_WRITER=agent to suppress)"
  131:  fi
  ```

  Then line 138 calls `bash "$SCRIPT_DIR/linear.sh" add-comment "$issue"
  "$body"` unconditionally. Means: even if the agent runs the command
  WITHOUT the prefix, the verdict still posts (the inherited
  `PIPELINE_WRITER=agent` from A-005 satisfies the lane fence; the
  warning never even fires under the dispatched agent). The new rule
  is therefore both safe (no functional regression) and load-bearing
  (it removes the matcher-breaking prefix).

- **A-008 — `bin/linear.sh::_check_lane` reads
  `${PIPELINE_WRITER:-orchestrator}` at line 122; `add other_comment`
  allows lanes `orchestrator,agent,classify,scope-check,human` at
  line 109.** Verified:

  ```
  109:    "add other_comment")          printf 'orchestrator,agent,classify,scope-check,human' ;;
  ...
  120:_check_lane() {
  121:    local action="$1" object_class="$2"
  122:    local lane="${PIPELINE_WRITER:-orchestrator}"
  ```

  Means: the verdict comment posts cleanly under either
  `PIPELINE_WRITER=agent` (preferred) or `PIPELINE_WRITER=orchestrator`
  (fallback). The lane fence is permissive; the matcher is the only
  hard gate.

- **A-009 — `bin/agent-prompts-content-test.sh:294-325` is the ENG-57
  same-sig multi-stage iteration loop; the new ENG-74 loop lands
  immediately after it (before the existing ENG-55 stdin-heredoc loop
  at lines 337-353).** Verified:

  ```
  294:for stage_section in \
  295:  "## 1. Brainstorm Agent" \
  296:  "## 2. Plan Agent" \
  297:  "## 3. Implementation Agent (Backend)" \
  298:  "## 4. UI Agent (Frontend)" \
  299:  "## 5. Review Agent" \
  300:  "## 6. QA Agent" \
  301:  "## 7. Build Agent" \
  302:  "## 8. Release Agent" \
  303:  "## 9. Retrospective Agent (Scheduled)"; do
  304:  body="$(section_body "$stage_section")"
  305:  short="${stage_section## }"
  ...
  311:  if printf '%s\n' "$body" | grep -qF 'retry with the same sig'; then
  312:    ok "$short contains 'retry with the same sig' rule (ENG-57)"
  313:  else
  314:    nope "$short contains 'retry with the same sig' rule (ENG-57)" "phrase missing"
  315:  fi
  ...
  325:done
  ```

  The new loop replicates this exact shape (same 9-section list, same
  `section_body` helper, same `ok`/`nope` reporters, same `grep -qF`
  literal-string match, same per-stage iteration); only the asserted
  substring differs.

- **A-010 — `bin/agent-prompts-content-test.sh:20-28` is the
  `section_body` helper.** Verified:

  ```
  20:section_body() {
  21:  local heading="$1"
  22:  awk -v h="$heading" '
  23:    BEGIN{in_section=0; in_fence=0}
  24:    /^```/{if (in_section) in_fence = !in_fence}
  25:    /^## /{ if (in_section && !in_fence) exit; if (!in_section && index($0, h)) {in_section=1; next} }
  26:    in_section{print}
  27:  ' "$PROMPTS"
  28:  }
  ```

  Means: the helper is paragraph-agnostic — it returns the entire H2
  section body, so `grep -qF` substring presence is what matters, not
  exact paragraph position. Brainstorm §6 edge case ("paragraph
  rewrite lands the new sentence outside the original paragraph") is
  covered by construction.

- **A-011 — `bin/agent-prompts-content-test.sh:489-491` is the
  RESULTS print + exit; the new ENG-74 loop must land BEFORE
  line 489.** Verified:

  ```
  489:printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
  490:[[ "$FAIL" == 0 ]] || exit 1
  491:exit 0
  ```

  Insertion point: after line 325 (end of ENG-57 loop), before line
  327 (start of ENG-55 stdin-heredoc loop comment). Per the brainstorm
  §3.3 sketch.

- **A-012 — `partition_dirty_paths::D-004` requires basename to contain
  `eng-N` (case-insensitive) for in-scope bucketing of brainstorm/plan
  artifacts.** Verified at `bin/run-local-helpers.sh:140-141, 182`:

  ```
  140:  local apply_d004=0
  141:  case "$stage" in brainstorming|planning) apply_d004=1 ;; esac
  ...
  182:        if [[ "$base_lower" =~ (^|[^a-z0-9])${issue_lower_re}([^a-z0-9]|$) ]]; then
  ```

  Means: this plan's basename
  `2026-05-07-eng-74-build-agent-wait-exit-fails-pipeline-writer-agent-bash-bin-pipeline-sh-rejected-by-sandbox-allowlist.md`
  contains `eng-74`, satisfies the regex, and is bucketed in-scope.
  No filename change needed.

- **A-013 — `.githooks/pre-commit` runs the entire `bin/*-test.sh`
  suite on every commit.** Verified per CLAUDE.md "Pre-commit hook" §.
  Means: the new ENG-74 assertions are gated by the pre-commit hook
  in <30s on every commit. Bypass via `--no-verify` is the same
  bypass concern as every other pre-commit check; not unique to
  ENG-74 (per brainstorm §5).

### Read-only callees / state shapes — verified, not modified

- **A-014 — `bin/run-stage.sh:846-857` is the no-output detector
  (`agent dispatch returned 0 but emitted no stage-summary file and
  no verdict marker`).** Verified — the post-fix wait-exit posts a
  verdict marker (`<!-- pipeline: verdict result=wait
  reason=awaiting-approval -->`), so `find_fresh_verdict` returns
  non-empty and the no-output gate is satisfied. The detector itself
  is unchanged.

- **A-015 — `bin/run-stage.sh:376-388` (`_post_dispatch_apply_halt`)
  has a wait-shape carve-out that skips the `pipeline:halted` apply
  when `_fresh_wait_reason` returns non-empty.** Verified at
  `bin/run-stage.sh:380-383`. Means: post-fix, the wait verdict lands,
  `_fresh_wait_reason` returns `awaiting-approval`, and the halt
  carve-out fires correctly. No code change needed in this hook.

- **A-016 — `bin/run-stage.sh:306-360` (`_fresh_wait_reason`)
  allow-lists `building` only at lines 308-311.** Verified — only the
  build stage exercises wait verdicts, so the rule's universal-paragraph
  scope is broader than the wait-exit hot path (defense-in-depth for
  any future stage that nudges the agent toward lane reasoning).

- **A-017 — `bin/pipeline-events.json::wait_reasons` registers
  `awaiting-approval` and `awaiting-ci`.** Verified per brainstorm §1.3.
  Means: `bash bin/pipeline.sh event ENG-N verdict wait --reason
  awaiting-approval` validates against the registry and posts the
  marker. No registry edit needed.

- **A-018 — `AGENT_PROMPTS.md:1281-1302` is §7's P2 wait-exit
  instruction block (the empirical hit site).** Verified — instructs
  the agent to run `bash bin/pipeline.sh event {issue_id} verdict wait
  --reason awaiting-approval` (no prefix, by the post-fix rule), then
  post the informational comment via `bash .pipeline/bin/linear.sh
  add-comment {issue_id} --body - <<'EOF' ... EOF`. The block itself
  is unchanged by ENG-74 — the rule is upstream prose that constrains
  HOW the agent invokes the commands the block already names.

- **A-019 — Operator-side `PIPELINE_WRITER=human` usage in
  `docs/runbooks/recovery.md` is OUT OF SCOPE.** Verified — operators
  run from their own shell, outside the agent sandbox, where the
  matcher does not apply. The new sentence's wording explicitly scopes
  itself to "your dispatch environment ... via `bin/dispatch.sh::main`"
  so operator commands at `docs/runbooks/recovery.md:50-307` are
  unaffected (per brainstorm §5).

## File Structure

| Path | Status | Purpose |
| --- | --- | --- |
| `AGENT_PROMPTS.md` | modified | Append one sentence to the universal "Tool allowlist & probing" paragraph at all 9 stage sites (lines 246, 361, 567, 714, 855, 1068, 1232, 1483, 1595). |
| `bin/agent-prompts-content-test.sh` | modified | Add one new ENG-74 iteration loop after the existing ENG-57 loop (after line 325, before line 327). Two assertions per stage: instructional substring presence + canonical forbidden form `PIPELINE_WRITER=agent` named in body. |
| `docs/plans/2026-05-07-eng-74-build-agent-wait-exit-fails-pipeline-writer-agent-bash-bin-pipeline-sh-rejected-by-sandbox-allowlist.md` | new | This plan doc (created by the planning agent). |

No other files changed. Explicit non-changes per brainstorm D-004:
`bin/dispatch.sh::allowed_tools_for`, `bin/run-stage.sh`,
`bin/render-prompt.sh`, `bin/pipeline.sh`, `bin/linear.sh`,
`learned-rules/harness/build.md`, `docs/runbooks/recovery.md`.

## API Contract

no new API surface. (This is a Bash orchestration repo with no FE↔BE
API; the change is prompt-text + a Bash test loop.)

## Backend Tasks

### Task 1: Append the env-var-prefix forbidden-form sentence to all 9 universal "Tool allowlist & probing" paragraph sites in `AGENT_PROMPTS.md`

- `depends_on: []`
- `touches: AGENT_PROMPTS.md` (lines 246, 361, 567, 714, 855, 1068, 1232, 1483, 1595)

Steps:

- [ ] Open `AGENT_PROMPTS.md` and locate each occurrence of the
      universal paragraph by grepping for the exact prefix
      `**Tool allowlist & probing (ENG-53 #11 / ENG-57):**`. Confirm
      9 hits. If grep returns ≠ 9 hits, STOP and re-verify
      `learned-rules/twinning/plan.md` rule P-002 — the brainstorm's
      A-001 claim has drifted; do not proceed.
- [ ] At each of the 9 sites, append the following sentence
      immediately AFTER the existing
      `Sig variants like \`-v2\`, \`-v3\`, \`-trial\`, \`-retry\` defeat dedup and produce permanent duplicate Linear comments.`
      and BEFORE the existing
      `**If you cannot accomplish your task with the documented tools, run \`bash bin/pipeline.sh event {issue_id} verdict halt --reason agent-blocked\`...`.
      Insertion text (verbatim, kept on one line in the source so the
      paragraph stays a single unwrapped line consistent with the
      surrounding ENG-53 / ENG-55 / ENG-57 sentences):

      ```
       **Do NOT prepend env-var assignments** (e.g. `PIPELINE_WRITER=agent`, `LINEAR_API_KEY=...`) **to your `bash bin/...` invocations** — the sandbox allowlist matcher anchors on the FIRST token of the command line, and an env-var assignment is not `bash`, so the `Bash(bash bin/pipeline.sh:*)` / `Bash(bash bin/linear.sh:*)` patterns fail to match. The orchestrator already exports `PIPELINE_WRITER=agent` into your dispatch via `bin/dispatch.sh::main`; the prefix is redundant AND unmatchable.
      ```

      The leading single space joins the new sentence to the prior
      one with the same spacing the surrounding ENG-57 sentence uses.

- [ ] Verify each insertion lands BEFORE
      `**If you cannot accomplish your task with the documented tools`
      (so the agent reads the matcher gotcha BEFORE the agent-blocked
      escape-ramp instruction). Use `grep -n 'Do NOT prepend env-var
      assignments' AGENT_PROMPTS.md` and confirm 9 hits, each
      preceded (one line up) by the unchanged 9-occurrence
      `**Tool allowlist & probing (ENG-53 #11 / ENG-57):**` line.
- [ ] Run `bash bin/render-prompt-test.sh` to confirm the
      fence-count contract (`fence_count == 2` per H2 section) is
      preserved at all 9 stages.
- [ ] Run `bash bin/agent-prompts-content-test.sh` (it will fail on
      the new assertions added in Task 2 if Task 2 hasn't run yet;
      that is expected — Task 1 in isolation should still pass every
      pre-existing assertion).
- [ ] Confirm `git diff --stat AGENT_PROMPTS.md` shows ~9 line
      additions (one per site; brainstorm §3.2 cites ~5 lines × 9
      sites = ~45 lines IF the insertion is multi-line; the
      one-line-per-site form above is the actually-correct shape per
      A-001 since the existing paragraph IS one line per site).

### Task 2: Add the per-stage ENG-74 iteration loop to `bin/agent-prompts-content-test.sh`

- `depends_on: [1]`
- `touches: bin/agent-prompts-content-test.sh` (insertion at end of ENG-57 loop, after line 325, before line 327)

Steps:

- [ ] Open `bin/agent-prompts-content-test.sh` and locate the closing
      `done` of the ENG-57 same-sig loop at line 325. Insertion point:
      blank line between the existing `done` (line 325) and the
      existing `# ─── ENG-55: stdin heredoc pattern ...` comment
      (line 327).
- [ ] Insert this stanza:

      ```bash
      # ─── ENG-74: env-var-prefix rule ──────────────────────────────────────
      # PIPELINE_WRITER=agent (or any leading VAR=val) must NOT be prepended
      # to `bash bin/...` invocations from inside the agent sandbox. The
      # Claude allowlist matcher anchors on the first token; an env-var
      # assignment is not `bash`, so the Bash(bash bin/pipeline.sh:*) pattern
      # fails to match a `PIPELINE_WRITER=agent bash bin/pipeline.sh ...`
      # invocation. ENG-64's build dispatch on 2026-05-05 hit this exact case
      # — agent silently exited rc=0, no-output detector applied
      # pipeline:halted. Pin the rule per-stage so a future prompt edit can't
      # drop it from one stage and silently regress.
      for stage_section in \
        "## 1. Brainstorm Agent" \
        "## 2. Plan Agent" \
        "## 3. Implementation Agent (Backend)" \
        "## 4. UI Agent (Frontend)" \
        "## 5. Review Agent" \
        "## 6. QA Agent" \
        "## 7. Build Agent" \
        "## 8. Release Agent" \
        "## 9. Retrospective Agent (Scheduled)"; do
        body="$(section_body "$stage_section")"
        short="${stage_section## }"

        if printf '%s\n' "$body" | grep -qF 'Do NOT prepend env-var assignments'; then
          ok "$short contains env-var-prefix rule (ENG-74)"
        else
          nope "$short contains env-var-prefix rule (ENG-74)" "phrase missing"
        fi

        if printf '%s\n' "$body" | grep -qF 'PIPELINE_WRITER=agent'; then
          ok "$short names canonical forbidden prefix PIPELINE_WRITER=agent (ENG-74)"
        else
          nope "$short names canonical forbidden prefix PIPELINE_WRITER=agent (ENG-74)" \
               "agent must see the exact forbidden form, not just a prose hint"
        fi
      done

      ```

      This shape mirrors the existing ENG-57 loop (lines 294-325) and
      ENG-53 #11 loop (lines 216-249) verbatim; only the asserted
      substrings differ. Same `section_body` helper (A-010), same
      `ok`/`nope` reporters, same `grep -qF` literal match.

- [ ] Run `bash bin/agent-prompts-content-test.sh` from the worktree
      root and confirm:
      - All pre-existing assertions still PASS.
      - 18 new lines: 9 `OK: <stage> contains env-var-prefix rule (ENG-74)`
        and 9 `OK: <stage> names canonical forbidden prefix
        PIPELINE_WRITER=agent (ENG-74)`.
      - Final `RESULTS: <total> passed, 0 failed` and exit 0.

      If any of the new assertions FAIL, the Task 1 insertion did not
      land in that stage's section body — fix the insertion (do not
      relax the assertion).

- [ ] Confirm `git diff --stat bin/agent-prompts-content-test.sh`
      shows ~36 line additions (9 stages × 2 assertions × ~2 lines
      per assertion + ~9 lines of comment header + blank lines).

### Task 3: Run the full pre-commit-equivalent test suite to confirm no regression

- `depends_on: [1, 2]`
- `touches: (no file changes — verification only)`

Steps:

- [ ] Run the in-scope pre-commit gate (per CLAUDE.md "Pre-commit
      hook" §):

      ```
      bash bin/agent-prompts-content-test.sh
      bash bin/render-prompt-test.sh
      ```

      Both must exit 0. The first asserts the new ENG-74 rule (Task 2)
      AND every pre-existing assertion. The second asserts the
      fence-count contract (A-004) survives the 9 paragraph
      modifications.

- [ ] Run a syntax sanity check on the modified test file:

      ```
      bash -n bin/agent-prompts-content-test.sh
      ```

      Expected: silent exit 0. (Backstop in case the Task 2 stanza
      introduced a typo; `AGENT_PROMPTS.md` itself is markdown so a
      `bash -n` against it would be meaningless — the actual
      prompt-content gate is `bash bin/agent-prompts-content-test.sh`
      + `bash bin/render-prompt-test.sh` per Goal.)

- [ ] OPTIONAL but recommended: run the broader bin/*-test.sh suite
      that the pre-commit hook will run on commit. Per CLAUDE.md
      "Tests" §:

      ```
      bash bin/dispatch-test.sh
      bash bin/run-stage-test.sh
      bash bin/poll-slot-test.sh
      bash bin/scope-check-test.sh
      bash bin/verdict-handler-test.sh
      bash bin/classify-failure-test.sh
      bash bin/halt-sprawl-test.sh
      bash bin/halt-sprawl-adversarial-test.sh
      bash bin/linear-test.sh
      bash bin/metrics-test.sh
      bash bin/mutex-test.sh
      bash bin/setup-helpers-test.sh
      bash bin/render-prompt-test.sh
      bash bin/phase-project-profile-test.sh
      bash bin/common-test.sh
      ```

      None of these touch the modified files except via
      `bin/render-prompt-test.sh` (already covered above). All should
      remain green.

## Frontend Tasks

There is no frontend in this project — the harness is bash-only and
the change is purely prompt-text + bash test. **No frontend tasks.**

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
| --- | --- | --- | --- | --- |
| New rule sentence missing from one or more stage sections (e.g., copy-paste error during Task 1, or a future edit drops it from one section) | Run `bash bin/agent-prompts-content-test.sh` | Assertion `<stage> contains env-var-prefix rule (ENG-74)` FAILs for the missing section; suite exits 1 | unit | `bin/agent-prompts-content-test.sh` ENG-74 loop, first assertion (per-stage) |
| Rule sentence present but does not name the canonical forbidden form `PIPELINE_WRITER=agent` (e.g., a future "cleanup" edit replaces the example with prose like "do not prepend env vars" without naming the literal form) | Run `bash bin/agent-prompts-content-test.sh` | Assertion `<stage> names canonical forbidden prefix PIPELINE_WRITER=agent (ENG-74)` FAILs for that section | unit | `bin/agent-prompts-content-test.sh` ENG-74 loop, second assertion (per-stage) |
| Insertion accidentally introduces a column-0 ``` fence in a section body (e.g., copy-paste of a fenced example) | Run `bash bin/render-prompt-test.sh` (also `bash bin/render-prompt.sh <stage> <issue>` for any in-flight issue) | `extract_block`'s schema check (`fence_count != 2`) dies with schema-error message | integration | `bin/render-prompt-test.sh` (existing; covers all 9 sections) |
| Insertion lands in §7 only (regressing to the Linear issue's literal proposal) instead of all 9 | Run `bash bin/agent-prompts-content-test.sh` | New ENG-74 loop FAILs for §§1–6, 8, 9 | unit | `bin/agent-prompts-content-test.sh` ENG-74 loop |
| Agent emits the prefix anyway despite the rule (training-data drift / future regression in retrospective rule edits) | Build dispatch on a not-yet-approved PR; observe sandbox denial + agent-failure halt + `pipeline:halted` apply | Same observable failure as today (§4.2 of brainstorm); the test pin would have already FAILed on the rule's textual removal in CI before this regression shipped | smoke | (not a unit test; verified by `bin/run-stage-test.sh`'s existing no-output-detector cases — the failure mode is identical to today's, the rule's job is to PREVENT the agent from getting there) |
| Agent reasons that some OTHER env-var prefix is needed (e.g., `LINEAR_API_KEY=...`, `GH_TOKEN=...`) | Same as above with a different leading env var | Rule's wording explicitly names `PIPELINE_WRITER=agent` AND `LINEAR_API_KEY=...` as canonical examples and refers to "any leading `VAR=val` token" via the matcher anchor explanation | unit | `bin/agent-prompts-content-test.sh` ENG-74 loop, first assertion (the rule sentence itself contains "env-var assignments" generically) |
| Pre-commit hook bypassed during emergency edit removes the new rule | `git commit --no-verify` after deleting the sentence | Same generic concern as every other pre-commit gate; not unique to ENG-74 | (out of test scope) | (none — operator policy issue per brainstorm §5) |
| Agent reads the rule, omits the prefix, but `bin/pipeline.sh` itself errors (Linear outage, registry mismatch, etc.) | Build dispatch with Linear unreachable | Falls into existing `bin/pipeline.sh::cmd_event_verdict` error path; nonzero rc bubbles to agent, which can retry or halt-for-human (unchanged from today) | (existing path) | (none new — covered by existing `bin/pipeline.sh` error handling) |
| `bin/render-prompt.sh` template substitution mishandles the new sentence (e.g., a `{learned_rules_dir}`-style placeholder accidentally introduced) | Render any stage's prompt | render-prompt-test.sh template-fidelity assertions catch the corruption | integration | `bin/render-prompt-test.sh` (existing) |

## Test Strategy

The change is prompt-text + a bash test loop; the test strategy is
correspondingly narrow.

**Unit (gating).** `bin/agent-prompts-content-test.sh` is the
load-bearing test. The new ENG-74 loop adds two assertions per
stage (18 new assertions total) over all 9 stage sections. Pattern:
literal-string presence (`grep -qF`) inside the per-section body
extracted by the existing `section_body` helper. Failure modes
covered: rule omitted from any section, canonical example deleted,
section heading drift (a section_body returning empty would FAIL
both assertions, surfacing the heading drift LOUDLY rather than
silently passing).

**Integration.** `bin/render-prompt-test.sh` exercises
`extract_block` end-to-end across all 9 stages. The fence-count
contract (`fence_count == 2`) is the load-bearing schema check; the
new sentence is plain prose (no triple-backtick), so the contract is
preserved. No new test case needed — the existing test already
covers every section.

**Smoke / e2e.** None added. The brainstorm's verification recipe
(§9) — wait for the next issue to reach build pre-approval, observe
the `<!-- pipeline: verdict result=wait reason=awaiting-approval -->`
marker land, observe `pipeline:halted` NOT applied, observe the wait
counter increment in `wait-building.json` — is the natural
post-deployment confirmation. It is not pre-merge gateable (requires
a real Linear issue + real PR + real CI delay), and the brainstorm
explicitly notes that the symptom under regression is identical to
today's so the operator-recovery cost is bounded by D-003's
two-step.

**Adversarial.** None added. The brainstorm's §6 edge cases
("a 10th stage is added", "paragraph rewrite lands the new sentence
outside the original paragraph", "agent asks 'can I verify by
`echo $PIPELINE_WRITER`?'") are all covered by construction: the
9-section list is the same maintenance pattern as ENG-53/55/57 (a
10th stage requires updating ALL multi-stage loops in lockstep,
acceptable per existing precedent); the `section_body` helper is
paragraph-agnostic; the `Bash(echo:*)` pattern is not in any
allowlist so the agent's hypothetical probe attempt itself fails
fast (the rule pre-empts the probe attempt).

**Lint.** `bash -n bin/agent-prompts-content-test.sh` is a
syntax-only check, included in Task 3 as a backstop in case the
heredoc-style insertion in Task 2 introduced a typo. No
`bin/secret-probe-lint.sh` interaction (no `${VAR:-FALLBACK}`
patterns introduced; the test's existing `${stage_section## }`
pattern-removal idiom is unaffected; `MOCK_*` and `PIPELINE_*` test
vars do not match the secret regex).

## Persona review

Personas run in canonical order: feasibility (gating) → scope →
coherence → design → product. All 5 personas iterated below; final
gate counts at the end.

### Iteration 1

#### Persona 1 — Feasibility (gating, PASS, 0 P0)

Codebase-fact verification (every code-level fact in the plan,
checked against current worktree):

- A-001 (9-occurrence count) — verified by `grep -c 'Tool allowlist
  & probing (ENG-53 #11 / ENG-57)' AGENT_PROMPTS.md` returning 9.
  Lines confirmed at 246, 361, 567, 714, 855, 1068, 1232, 1483, 1595.
- A-002 (sentence neighbourhood) — verified at line 1232; same shape
  at all 9 sites.
- A-003 (§7 layout: line 1230 secret-handling, 1232 tool-allowlist) —
  verified by Read.
- A-004 (`bin/render-prompt.sh::extract_block` fence-count contract)
  — verified per CLAUDE.md "AGENT_PROMPTS.md is load-bearing" §; the
  ENG-62 plan's A-026 (`bin/render-prompt.sh:35-61`) cites the same
  invariant.
- A-005 (`bin/dispatch.sh:361` `env PIPELINE_WRITER=agent` wrapper) —
  verified.
- A-006 (`bin/common.sh:293-294` PIPELINE_WRITER default + export) —
  verified.
- A-007 (`bin/pipeline.sh:124-131` lane warning, line 138 unconditional
  add-comment) — verified.
- A-008 (`bin/linear.sh:120-145` _check_lane, line 109 add
  other_comment lane allow-list) — verified.
- A-009 (`bin/agent-prompts-content-test.sh:294-325` ENG-57 loop) —
  verified by Read.
- A-010 (`bin/agent-prompts-content-test.sh:20-28` section_body) —
  verified by Read.
- A-011 (test file ends at line 489-491 RESULTS+exit) — verified by
  Read.
- A-012 (partition_dirty_paths D-004 basename rule) — verified at
  `bin/run-local-helpers.sh:140-141, 182`.
- A-013 (.githooks/pre-commit suite) — verified per CLAUDE.md.
- A-014–A-019 (read-only callee verifications) — all verified by
  Read against the named line ranges.

Task `depends_on` lists checked: Task 1 has no deps (pure
AGENT_PROMPTS.md edit); Task 2 depends on Task 1 (the test asserts
substrings that Task 1 introduces; running Task 2 first FAILs by
construction); Task 3 depends on both (it runs the test suite to
confirm). No hidden coupling — each task touches a different file
or runs commands.

Failure-Mode → Test Map: every row names either a unit test
(`bin/agent-prompts-content-test.sh` ENG-74 loop), an integration
test (`bin/render-prompt-test.sh` existing), or explicitly states
"no new test, covered by existing path / out of test scope" with
justification. No row is unbound.

No P0; no P1.

#### Persona 2 — Scope (PASS, 0 P0)

Every File Structure entry traces to a brainstorm decision:
`AGENT_PROMPTS.md` is D-001; `bin/agent-prompts-content-test.sh` is
D-002; the plan doc itself is required by the planning stage's
contract (CLAUDE.md "AGENT_PROMPTS.md is load-bearing" §
implies-but-does-not-name plan-doc requirement; the planning prompt
explicitly asks for the doc).

Every task's `touches` list stays inside the declared File
Structure: Task 1 touches AGENT_PROMPTS.md only; Task 2 touches
`bin/agent-prompts-content-test.sh` only; Task 3 touches no files
(verification only).

Explicit non-changes per brainstorm D-004 are NOT introduced (no
helper additions, no orchestrator changes, no learned-rules edit, no
allowlist extension, no render-time injection, no operator-runbook
edit, no new ADR file).

P2 (already flagged by brainstorm §9 / §8.2 alt A): the §7-only →
universal-paragraph broadening is technically outside the Linear
issue's literal proposal. The brainstorm justifies it (matcher gotcha
is stage-agnostic; build is the empirical hit). Plan inherits the
broadening unchanged. Reverting to §7-only is trivial (delete 8 of
the 9 insertions and tighten the test loop's stage list to `## 7.
Build Agent` only) if the operator disagrees. **Not a P0; not a
gating concern.**

No P0.

#### Persona 3 — Coherence (PASS, 0 P0)

- Plan's Goal matches brainstorm's stated outcome (§4.1 happy path):
  next build dispatch on a not-yet-approved PR runs the no-prefix
  invocation, the wait verdict lands, orchestrator re-dispatches.
- Backend tasks (Task 1 + Task 2 + Task 3) jointly realise every row
  of the (no-API) contract — there is no API contract, so the rows
  to satisfy are the brainstorm decisions D-001 (Task 1) and D-002
  (Task 2). Task 3 is the verification harness for both.
- Test Strategy covers every Failure Mode row: each failure mode
  binds to either the new ENG-74 unit assertions, the existing
  render-prompt integration test, or an explicitly-out-of-scope
  category (operator bypass, in-flight Linear outage).
- Plan composes with the brainstorm's prior-art chain: ENG-45
  (wait-exit contract preserved), ENG-49 (paragraph-host preserved),
  ENG-56 (orchestrator-managed `pipeline:halted` carve-out
  preserved), ENG-62 (P0 merge-state precheck independent), ENG-65
  (sister allowlist-disconnect addressed analogously). No
  contradiction.

No P0.

#### Persona 4 — Design (PASS, 0 P0)

- No layering violations: the change does not cross the
  orchestrator/agent boundary in a new way; it tightens the prompt
  the agent receives (already an established surface) and adds a
  test loop in the existing test file (already an established test
  surface).
- No circular deps: the test (Task 2) reads the prompt (Task 1
  output) via `section_body`/`grep -qF`; no circular reference.
- Crate / module responsibilities: bash repo with no crates; module
  boundaries inferred from `bin/` subscript structure — every
  invocation through the existing `bin/*.sh` helpers (`linear.sh`,
  `pipeline.sh`, `dispatch.sh`, `render-prompt.sh`, `run-stage.sh`)
  is preserved verbatim.
- No new dynamic-prompt surface (rejected D-001 alt B / §8.2 alt B);
  no new env vars; no new state files; no new lanes; no new registry
  entries.
- The test stanza follows the established multi-stage iteration
  pattern (ENG-53 #11 / ENG-55 / ENG-56 / ENG-57). Adding a new
  stanza for ENG-74 is the same kind of addition the existing test
  file has accepted four times before — coherent with prior art.

P2 (already flagged by brainstorm §8.1 tradeoff): the universal
paragraph keeps growing on each ENG-N gotcha addition (~150 words
post-ENG-74). Risk: density. Mitigation: bolded `**Do NOT ...**`
visual shape matches the existing ENG-57 sentence, preserving
high-priority-callout rhythm; and the test pin makes the rule
durable so a future "factor into a Sandbox allowlist gotchas
subsection" cleanup can land safely. **Not a P0; flagged for
follow-up if a future incident shows agents skimming.**

No P0.

#### Persona 5 — Product (PASS, 0 P0)

User-facing impact: every issue that reaches build without a
pre-existing non-bot Code Owner approval no longer halts spuriously
on the agent's invocation shape. Removes one halt cycle + one
`--action continue` per issue per build pre-approval window. The
breaker-trip risk on bursts (3+ consecutive build halts on different
issues during a pre-approval window) is closed.

Aligned with the harness's CLAUDE.md "Failure-mode quick reference"
principle that halts should be cheap escape ramps, not silent traps.
This fix preempts a halt class that didn't need to fire in the first
place, restoring the load-bearing property "documented invocations
work" that the universal probe-rule paragraph at line 1232
implicitly assumes.

Linear issue's "Proposed scope" mapping (per brainstorm §9):
- Scope item 1 (prompt fix in §7): D-001 covers, broadened to all 9.
- Scope item 2 (test pin): D-002 covers.
- Scope item 3 (defense-in-depth banner): correctly rejected per
  D-001 alt B.

Pre-existing observation logged for follow-up (NOT in scope, per
brainstorm §7 Q1): the agent's failure path on ENG-64 (silent rc=0
exit instead of `verdict halt --reason agent-blocked` after a
documented invocation failed) is a separate prompt-conformance
question. The plan respects the brainstorm's scope discipline and
files this for a separate Linear issue.

No P0.

### Persona-review summary

Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.
