---
linear: ENG-68
date: 2026-05-07
topic: Forensic capture + transcript-assertion + allowlist tightening to identify and pre-emptively close the trigger class for `core.bare=true` flips on the harness repo
---

# Plan — ENG-68 investigate cause of harness `.git/config` `core.bare=true` flips

Implementation plan for the design at
`docs/brainstorms/2026-05-07-eng-68-investigate-cause-of-harness-git-config-core-bare-true-flips-may-2026-incident-still-unexplained-design.md`.

## Goal

Add a `capture_core_bare_forensic` helper to `bin/run-local-helpers.sh` and call it from the two existing self-heal sites (`bin/run-local.sh:72-80` launchd path and `.githooks/pre-commit:49-56` hook path) BEFORE the `git config core.bare false` reset; replace the wide `Bash(git:*)` glob in `bin/dispatch.sh::allowed_tools_for` for the `implementing` and `ui` cases (lines 248-249) with an enumerated subcommand list; layer a transcript-based assertion in `_render_and_capture_stream` that returns a NEW exit code 13 on any of five `core.bare`-touching command shapes, route 13 through `bin/run-stage.sh` to a `lane-violation` halt; pin all of it via a new T4 (a/b/c) sub-suite in `bin/test-isolation-test.sh` and new `CB1-CB6` fixtures in `bin/dispatch-test.sh`; document the 30-day decision rule in `docs/runbooks/recovery.md`.

## Anti-anchoring check

- **Problem restated.** The harness's `/Users/rajatgoyal/code/twinning-harness/.git/config` keeps flipping `core.bare=true`; the existing PR #48 self-heal masks the symptom but the trigger is unknown; the ticket's ACs require (1) a deterministic reproduction of the trigger, (2) a permanent fix at the source rather than the self-heal, and (3) a regression test that the trigger no longer flips the bit.
- **Brainstorm's solution.** Two parallel tracks: (a) instrument the next recurrence with a forensic capture trap so AC #1 is reachable, and (b) pre-emptively close the highest-prior hypothesis (H1 = agent dispatch invokes `git config core.bare true` under the wide `Bash(git:*)` glob) via allowlist tightening + transcript assertion, satisfying AC #2 if H1 holds. Regression test (AC #3) and a 30-day decision rule give the issue a finite-closure horizon.
- **Solution proportionality.** Five existing files modified, one helper added, one new section in a runbook, one new entry in a closed-vocabulary registry. No new crate, no new daemon, no new long-running process (fswatch was rejected at brainstorm §3 D-001), no new label or marker shape (forensic uses the existing `meta:` shape). Slightly broader than the literal "investigate" framing — flagged in brainstorm §10 — because the wide-glob foot-gun is independent of whether it caused this specific incident.
- **Verdict.** Both checks pass. Proceed without a `pipeline:supersede` / `pipeline:extend` request.

## Assumption inventory

Every code-level claim is verified against the current branch
(`feat/eng-68-investigate-cause-of-harness-git-config-core-bare-true-flips-may-2026-incident-still-unexplained`,
post-ENG-43 merge — the existing transcript-assertion machinery used by D-002 / D-003 is already in place at the cited lines).

- **A-001 — `bin/run-local.sh:72-80` is the launchd self-heal site for `core.bare`.**
  - `bin/run-local.sh:72` — `for _git_dir in "$TARGET_REPO/.git" "$HARNESS_ROOT/.git"; do`
  - `bin/run-local.sh:73-74` — `if [[ -d "$_git_dir" ]]; then` … `bare="$(git --git-dir="$_git_dir" config --get core.bare 2>/dev/null || printf 'false')"`
  - `bin/run-local.sh:75-78` — `if [[ "$bare" == "true" ]]; then` … `git --git-dir="$_git_dir" config core.bare false` … `log "WARNING: $_git_dir had core.bare=true; reset to false …"`
  - **Status:** verified. The forensic capture call slots BEFORE line 76 (the `git config core.bare false` reset), inside the `if [[ "$bare" == "true" ]]` branch, so the dump is taken while the bit is still set.

- **A-002 — `.githooks/pre-commit:49-56` is the hook self-heal site, runs under `set -uo pipefail` only (no `-e`).**
  - `.githooks/pre-commit:12` — `set -uo pipefail`
  - `.githooks/pre-commit:49` — `HARNESS_GIT_DIR="$REPO_ROOT/.git"`
  - `.githooks/pre-commit:50-55` — `if [[ -d "$HARNESS_GIT_DIR" ]]; then` … `bare="$(git --git-dir="$HARNESS_GIT_DIR" config --get core.bare 2>/dev/null || printf 'false')"` … `git --git-dir="$HARNESS_GIT_DIR" config core.bare false` … `printf '[pre-commit] WARNING: harness main repo had core.bare=true; reset to false. Investigate (likely test-fixture leak via inherited GIT_DIR).\n' >&2`
  - **Status:** verified. The forensic capture call slots BEFORE line 53 (the `git --git-dir=… config core.bare false`). The hook does not source `common.sh` today and runs under `set -uo pipefail`; sourcing `bin/run-local-helpers.sh` requires a `[[ -f … ]] && source` guard to fall through cleanly when bin/ is absent (fresh checkout edge case).

- **A-003 — `bin/run-local-helpers.sh` defines pure functions only and is sourced by `bin/run-local.sh:28`. The helper has no top-level `set -e`.**
  - `bin/run-local-helpers.sh:1-5` — header notes pure-function discipline; assumes common.sh has been sourced first
  - `bin/run-local.sh:28` — `source "$SCRIPT_DIR/run-local-helpers.sh"`
  - **Status:** verified. New helper `capture_core_bare_forensic` lives at the bottom of `bin/run-local-helpers.sh` (after the existing `partition_dirty_paths` block at line 199). No top-level side effects.

- **A-004 — `bin/dispatch.sh::allowed_tools_for` cases `implementing` and `ui` ship `Bash(git:*)` today.**
  - `bin/dispatch.sh:248` — `implementing)   base='Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(rustc:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;`
  - `bin/dispatch.sh:249` — `ui)             base='Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;`
  - **Status:** verified. D-002 replaces both `Bash(git:*)` substrings with the enumerated list (status, log, diff, show, add, rm, mv, restore, commit, checkout, switch, fetch, pull, push, rebase, merge, branch, stash, ls-files, rev-parse, rev-list, for-each-ref, tag, describe). Note ALSO present in `qa` (`bin/dispatch.sh:251`) — qa is OUT OF SCOPE for D-002 (kept wide; D-003 transcript assertion is the only protection there). Flagged at brainstorm §10 ("Auditing every other `Bash(*:*)` glob is a sibling hardening ticket").

- **A-005 — `bin/dispatch.sh::assert_no_tool_invocation` exists, takes `(transcript, pattern)`, returns 0 on no-match / 1 on match (printing matched command on stdout), and soft-fails on empty/missing transcript.**
  - `bin/dispatch.sh:48-65` — full function definition; `[[ -s "$transcript" ]] || return 0` at line 50; `startswith($p)` filter; `head -1` cap.
  - **Status:** verified. The new pattern loop in D-003 calls the same helper N times (one per pattern) and returns 13 on the first match. Helper signature does not change.

- **A-006 — `_render_and_capture_stream` already has an implementing-only assertion block ending at `bin/dispatch.sh:193` and the function closing brace is at line 194; the ENG-43 sidecar `.transcript-violation-${stage}` lifecycle is established.**
  - `bin/dispatch.sh:184-193` — current implementing-only block returning 22 on `gh pr create` match
  - `bin/dispatch.sh:97` — `local violation_file="${issue_dir}/.transcript-violation-${stage}"`
  - `bin/dispatch.sh:98` — `rm -f "$violation_file"            # idempotent pre-clean (D-008)`
  - **Status:** verified. The new core.bare check slots BETWEEN lines 193 (closing `fi` of implementing block) and 194 (closing `}` of function). It REUSES the same `$violation_file` path and writes the matched git form to it before `return 13`. The existing pre-clean at line 98 covers the new branch too (single sidecar per dispatch).

- **A-007 — `bin/run-stage.sh` already routes `dispatch_rc == 22` to a sidecar-reading halt; the same shape extends to `dispatch_rc == 13`.**
  - `bin/run-stage.sh:650-687` — full dispatch-rc ladder; rc 124 (timeout) → rc 22 (pr-opened-too-early) → catch-all rc != 0 → rc 21 (scope, downstream)
  - `bin/run-stage.sh:669-681` — rc 22 branch reads `$(issue_dir "$ident")/.transcript-violation-${stage}` and calls `classify_failure "$ident" "$stage" "skip-until-human-acts" "<reason>" 22`, then `exit 22`
  - **Status:** verified. The new rc 13 branch slots BETWEEN the rc 22 branch (line 681 `exit 22`) and the catch-all (line 682 `elif (( dispatch_rc != 0 ))`), so the specific 13 is matched before the generic non-zero. Pattern is mechanical.

- **A-008 — `failure_outcome_for_exit 13` returns `lane-violation`; this is the canonical taxonomy entry for "agent invoked a tool outside its lane."**
  - `bin/common.sh:119` — `13) printf 'lane-violation' ;;`
  - **Status:** verified. The metric outcome on rc 13 is `lane-violation`. The halt comment posted by `classify_failure` carries the verdict marker `<!-- pipeline: verdict result=halt reason=agent-blocked -->` (per `classify_failure`'s policy→marker mapping: skip-until-human-acts → agent-blocked; `bin/classify-failure.sh:127`). The brainstorm's claim of "verdict halt --reason protocol-violation" (D-003) is a documentation-side simplification — the actual marker reason is `agent-blocked`, but the `effective_reason` body string and the metric outcome both carry `lane-violation`/the matched git form, so operators get the same diagnostic surface. Flagged in §"Open questions" below.

- **A-009 — `core.bare` is stored in the SHARED `$GIT_COMMON_DIR/config`, not a per-worktree fragment, so a write from a linked worktree of `$HARNESS_ROOT` lands on the main repo's config.**
  - Brainstorm §9.4 row 9; `git help config-variables` lists `core.bare` under the "Config files for working tree shared values" section.
  - The existing self-heal at `.githooks/pre-commit:53` writes via `git --git-dir="$HARNESS_GIT_DIR" config core.bare false` (no `--worktree` flag), confirming the shared-config write semantics.
  - **Status:** verified.

- **A-010 — `bin/test-isolation-test.sh` already pins T1 (GIT_* unset), T2 (`core.bare` heal presence in BOTH the hook AND `bin/run-local.sh`), and T3 (hostile-env probe loop over four test files) and uses `pass_at`/`fail_at` helpers and a `build_probe` / `snapshot` factory.**
  - `bin/test-isolation-test.sh:30-31` — `pass_at` / `fail_at` helpers
  - `bin/test-isolation-test.sh:33-56` — T1
  - `bin/test-isolation-test.sh:58-65` — T2 (hook)
  - `bin/test-isolation-test.sh:67-73` — T2 (run-local.sh)
  - `bin/test-isolation-test.sh:75-119` — T3 hostile-env loop
  - `bin/test-isolation-test.sh:79-95` — `build_probe()` and `snapshot()` factories
  - **Status:** verified. T4a/T4b/T4c append AFTER T3's loop (line 119) and BEFORE the final summary (line 121 `printf '\ntest-isolation: passed=%d failed=%d\n' "$PASS" "$FAIL"`). Reuses `build_probe` for T4a/T4b/T4c.

- **A-011 — `bin/dispatch-test.sh` already has a Group 7 section with fixtures AS1-AS6 covering `assert_no_tool_invocation`'s contract (ENG-43); test sources dispatch.sh after seeding `_TEST_STUB_DIR` / `ISSUE_DIR`.**
  - `bin/dispatch-test.sh:1141` — `# ─── Group 7: assert_no_tool_invocation fixtures (ENG-43, AS1-AS6) ────`
  - `bin/dispatch-test.sh:1147` — `printf '\n--- assert_no_tool_invocation fixtures …'`
  - `bin/dispatch-test.sh:1156-1167` — AS1
  - **Status:** verified. New fixtures `CB1-CB6` (CoreBare 1 through 6) append AFTER AS6 and BEFORE the next group's header / the final RESULTS block. Each fixture writes an NDJSON file under `$_TEST_STUB_DIR/`, calls `assert_no_tool_invocation` directly, and asserts `(rc, stdout)` tuples — same shape as AS1.

- **A-012 — `bin/pipeline-events.json::meta_kinds` is a closed-vocabulary array consumed by `bin/generate-vocabulary-doc.sh`; `forensic` is NOT in the array today.**
  - `bin/pipeline-events.json:42-47` — `"meta_kinds": ["dedup", "metric", "evidence", "reapplied"]`
  - `bin/generate-vocabulary-doc.sh:14` — iterates `meta_kinds` and emits a markdown subsection
  - `docs/pipeline-vocabulary.md:83-88` — current rendered list (`dedup`, `metric`, `evidence`, `reapplied`)
  - **Status:** verified. D-001 adds `"forensic"` to the array and re-runs the generator to refresh `docs/pipeline-vocabulary.md`. No parser today validates `meta:` markers against the registry, so the addition is documentation-side only — but adding it preserves closed-vocabulary discipline (CLAUDE.md "Pipeline vocabulary" §).

- **A-013 — `bin/linear.sh add-or-update-comment <sig> <ident> --body -` accepts stdin via `<<'EOF'` heredoc; the `meta: dedup key=<sig>` marker is appended automatically; ENG-63 reapplied-footer rotation activates on byte-equal bodies.**
  - `bin/linear.sh:541-619` — `add_or_update_comment` function
  - `bin/linear.sh:559` — `local marker="<!-- meta: dedup key=$sig -->"`
  - `bin/linear.sh:601-606` — ENG-63 reapplied-footer logic
  - **Status:** verified. The forensic helper calls `add_or_update_comment "core-bare-flip/<utc-iso-day>" "<issue>" --body -` with the body piped via stdin. Multiple flips on the same day fold into one Linear thread with reapplied-footer rotation.

- **A-014 — `bin/common.sh:14` resolves `HARNESS_STATE_DIR` with a fallback to `${XDG_STATE_HOME:-${HOME}/.local/state}/twinning-harness`; `PROJECT_STATE_DIR` is empty during bootstrap (`TWINNING_BOOTSTRAPPING=1`).**
  - `bin/common.sh:14` — `HARNESS_STATE_DIR="${HARNESS_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/twinning-harness}"`
  - `bin/common.sh:48-54` — `TWINNING_BOOTSTRAPPING=1` branch sets `PROJECT_SLUG=""` → `PROJECT_STATE_DIR=""` at line 59
  - **Status:** verified. The forensic helper resolves `forensic_root` as `${PROJECT_STATE_DIR:-$HARNESS_STATE_DIR/_unscoped}/forensics/core-bare-flip-<utc-iso>` so the bootstrap path falls through to a cross-project fallback dir under `$HARNESS_STATE_DIR/_unscoped/forensics/`.

- **A-015 — At `bin/run-local.sh:72` (the heal site), `LINEAR_API_KEY` is NOT yet sourced; secrets.env is loaded at line 84.**
  - `bin/run-local.sh:72-80` — heal block
  - `bin/run-local.sh:82-87` — secrets sourcing
  - `bin/run-local.sh:89` — `require_env LINEAR_API_KEY` (would die if missing)
  - **Status:** verified. The forensic helper guards the Linear post with `[[ -n "${LINEAR_API_KEY:-}" && -n "${PIPELINE_ISSUE_ID:-${PIPELINE_FORENSIC_FALLBACK_ISSUE:-}}" ]]`. When LINEAR_API_KEY is unset (heal site, hook, fresh checkout) the helper skips the Linear post and only writes the forensic dir + emits a `log` line. The forensic dir is the load-bearing artifact; the Linear comment is announcement-only.

- **A-016 — `PIPELINE_ISSUE_ID` is exported per-stage by `bin/run-stage.sh:651` only at dispatch time; it is unset at run-local.sh tick start AND in the pre-commit hook.**
  - `bin/run-stage.sh:651` — `PIPELINE_ISSUE_ID="$ident" \ bash "$SCRIPT_DIR/dispatch.sh" …`
  - **Status:** verified. The Linear-post fallback `PIPELINE_FORENSIC_FALLBACK_ISSUE` env var is the operator-configurable knob: harness-self operators set `PIPELINE_FORENSIC_FALLBACK_ISSUE=ENG-68` in their `~/.config/twinning-harness/secrets.env` (or per-target `.env.local`); cross-project operators leave it unset and rely on the dir + log line. This refines brainstorm D-001's "fallback to harness-self ENG-68" suggestion into a configurable knob, removing target-coupling from the helper itself.

- **A-017 — `bin/dispatch.sh::main` already has a `disallowed_platform_tools` list at line 207 and `_dispatch_tools_extras` at line 215; per-target dispatch.tools.<stage> extras are appended to the hardcoded base via `bin/dispatch.sh:259-263`.**
  - `bin/dispatch.sh:215-224` — `_dispatch_tools_extras` reader
  - `bin/dispatch.sh:259-263` — append logic in `allowed_tools_for`
  - **Status:** verified. D-002's enumerated list becomes the new hardcoded base for implementing/ui; per-target extras still APPEND, so any target needing a wider git subcommand (e.g. `git remote add` in a setup phase) can grant it via `.pipeline-config/config.json::dispatch.tools.implementing[]` without a harness PR. This preserves the ENG-51 / ENG-53 #8 contract.

- **A-018 — `docs/runbooks/recovery.md` exists, ends at line 307, and has no existing `ENG-68` section.**
  - `wc -l docs/runbooks/recovery.md` → 307
  - `grep -n "ENG-68\|core.bare" docs/runbooks/recovery.md` → empty
  - **Status:** verified. D-005's new section appends to the end of the file (after the final "If you see this, re-run …" line at 307).

- **A-019 — `docs/pipeline-vocabulary.md` is a generated artifact (regenerated from `pipeline-events.json` via `bin/generate-vocabulary-doc.sh`); editing it by hand is wrong.**
  - `docs/pipeline-vocabulary.md:84` (rendered comment from `generated()` in the generator script): `"Source: \`bin/pipeline-events.json\` — edit there, not here."`
  - `bin/generate-vocabulary-doc.sh:14` iterates `meta_kinds` to emit the rendered list
  - **Status:** verified. After adding `forensic` to `pipeline-events.json::meta_kinds`, run `bash bin/generate-vocabulary-doc.sh` to refresh the doc.

- **A-020 — Bash 3.2 (macOS default) supports `&` and `wait` for parallel artifact dump; brainstorm assumption #14 marked "assumed".**
  - bash(1) on macOS 14: `wait` builtin documented; `&` job control works without job-control mode in non-interactive scripts.
  - **Status:** treated as **verified by spec**. The forensic helper backgrounds each capture with `&` and joins via `wait`; if the spec assumption is wrong on a 3.2 host, the helper falls back to serial captures (still correct, just slower). The implementation agent verifies behaviour on the build host before committing.

- **A-021 — `learned-rules/harness/plan.md` does not exist (the prompt says "follow ALL rules listed" but the file is absent).**
  - `ls learned-rules/harness/` → `build.md`, `project-profile.md` only
  - **Status:** verified. No additional learned-rules constraints apply to this plan; CLAUDE.md guidance is the binding ruleset.

## File Structure

```
bin/
  run-local-helpers.sh        modified  — append `capture_core_bare_forensic()` after
                                          `partition_dirty_paths` (D-001).
  run-local.sh                modified  — call `capture_core_bare_forensic "$_git_dir"`
                                          inside the existing `if [[ "$bare" == "true" ]]`
                                          branch at lines 75-77, BEFORE the
                                          `git config core.bare false` reset (D-001).
  dispatch.sh                 modified  — replace `Bash(git:*)` in `implementing` (line 248)
                                          and `ui` (line 249) cases with enumerated
                                          subcommand list (D-002); append a five-pattern
                                          core.bare check loop in `_render_and_capture_stream`
                                          BETWEEN line 193 (closing fi of ENG-43 implementing
                                          block) and line 194 (closing brace of function),
                                          returning 13 on match (D-003).
  run-stage.sh                modified  — insert `elif (( dispatch_rc == 13 ))` branch
                                          BETWEEN line 681 (existing exit 22) and line 682
                                          (catch-all elif != 0); read sidecar, classify with
                                          policy=skip-until-human-acts and exit 13 (D-003).
  test-isolation-test.sh      modified  — append T4a / T4b / T4c sub-cases AFTER line 119
                                          (end of T3 loop) and BEFORE line 121 (final summary)
                                          (D-004).
  dispatch-test.sh            modified  — append fixtures CB1-CB6 AFTER the existing AS6
                                          fixture (Group 7) and BEFORE the final RESULTS
                                          block. CB1-CB5 cover the five core.bare patterns;
                                          CB6 covers the multi-pattern loop short-circuit
                                          (first match wins).
  pipeline-events.json        modified  — add `"forensic"` entry to the `meta_kinds` array
                                          (D-001 announcement marker shape).

.githooks/
  pre-commit                  modified  — guarded source of run-local-helpers.sh and call
                                          `capture_core_bare_forensic "$HARNESS_GIT_DIR"`
                                          inside the existing `if [[ "$bare" == "true" ]]`
                                          branch at lines 52-55, BEFORE the
                                          `git config core.bare false` reset (D-001).
                                          Falls through to the inline heal if the helper
                                          source fails (fresh-checkout edge case).

docs/
  pipeline-vocabulary.md      regenerated — `bash bin/generate-vocabulary-doc.sh` re-renders
                                            the meta_kinds subsection to include `forensic`.
  runbooks/recovery.md        modified  — append section "ENG-68 follow-up: core.bare
                                          recurrence after fix" with the 30-day decision
                                          rule (D-005).
  brainstorms/2026-05-07-eng-68-…-design.md   PRE-EXISTING (this issue's brainstorm)
  plans/2026-05-07-eng-68-…-investigate-cause-of-harness-git-config-core-bare-true-flips-may-2026-incident-still-unexplained.md
                              NEW (this file)
```

No new `bin/` files. The forensic helper lives in the existing `run-local-helpers.sh` library so both the launchd path and the pre-commit hook can source it (the hook sources the same helper file under a `[[ -f … ]] &&` guard). The Linear comment is posted via the existing `add-or-update-comment` interface — no new linear.sh subcommand. The metric write is a single `meta: forensic` marker — no new metric event in `metrics.sh`.

## API Contract

No new API surface. This is a bash orchestration repo with no UI, no FE↔BE IPC, no compiled artifact. The only "contract" change is internal to dispatch↔run-stage:

- `_render_and_capture_stream` now returns either 0 (clean), 22 (gh pr create violation in `implementing`), or 13 (core.bare git form violation in any stage). The sidecar file `${issue_dir}/.transcript-violation-${stage}` is written on either non-zero return and read by the corresponding `run-stage.sh` rc-branch. No other reader exists.
- `capture_core_bare_forensic` is a new internal function in `run-local-helpers.sh`, signature `capture_core_bare_forensic <git_dir>`. Side effects: creates `${PROJECT_STATE_DIR:-$HARNESS_STATE_DIR/_unscoped}/forensics/core-bare-flip-<utc-iso>/` with up to 9 artifact files; on success and when `LINEAR_API_KEY` AND `PIPELINE_ISSUE_ID`-or-`PIPELINE_FORENSIC_FALLBACK_ISSUE` are set, posts a `meta: forensic` Linear comment. Returns 0 always (best-effort observability — must not block the heal path).

## Backend Tasks

(Bash harness — no Tauri/Rust backend, no frontend. All tasks are bash edits.)

### Task 1: add `capture_core_bare_forensic` helper to `bin/run-local-helpers.sh`

- `depends_on: []`
- `touches: bin/run-local-helpers.sh::capture_core_bare_forensic` (new function)

- [ ] Append the helper at the END of `bin/run-local-helpers.sh` (after the existing `partition_dirty_paths` block ending at line 199 and the auto-commit helpers at lines 201-300+ — append at the file's bottom). The helper is pure-by-default (no top-level side effects) per the file's discipline.

  ```bash
  # ENG-68 D-001: capture forensic snapshot of $git_dir before the caller's
  # self-heal flips core.bare back to false. Side effects only — never raises;
  # heal must proceed even if capture fails. Idempotent across retries.
  #
  # Args: $1 = git_dir (e.g. $HARNESS_ROOT/.git, $TARGET_REPO/.git)
  # Returns: 0 always.
  capture_core_bare_forensic() {
    local git_dir="$1"
    [[ -n "$git_dir" && -d "$git_dir" ]] || return 0

    local ts forensic_root base
    ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
    base="${PROJECT_STATE_DIR:-$HARNESS_STATE_DIR/_unscoped}"
    forensic_root="$base/forensics/core-bare-flip-${ts}"
    mkdir -p "$forensic_root" 2>/dev/null || return 0

    # Capture nine artifacts in parallel; each redirects stdout+stderr so a
    # single failing capture leaves a `.error` sibling rather than losing the
    # rest. `|| printf …` covers the redirect itself failing (e.g. RO mount).
    {
      git --git-dir="$git_dir" config --list --show-origin > "$forensic_root/config.before" 2>&1 \
        || printf 'capture failed: %s\n' "$?" > "$forensic_root/config.before.error"
    } &
    {
      stat -f '%Sm %m %N' "$git_dir/config" > "$forensic_root/config-mtime" 2>&1 \
        || printf 'capture failed: %s\n' "$?" > "$forensic_root/config-mtime.error"
    } &
    {
      git --git-dir="$git_dir" reflog HEAD --date=iso 2>&1 | head -50 \
        > "$forensic_root/reflog-HEAD" 2>&1 \
        || printf 'capture failed: %s\n' "$?" > "$forensic_root/reflog-HEAD.error"
    } &
    {
      git --git-dir="$git_dir" reflog --date=iso --all 2>&1 | head -200 \
        > "$forensic_root/reflog-all" 2>&1 \
        || printf 'capture failed: %s\n' "$?" > "$forensic_root/reflog-all.error"
    } &
    {
      git --git-dir="$git_dir" for-each-ref \
        --format='%(objectname:short) %(refname) %(committerdate:iso)' 2>&1 | head -200 \
        > "$forensic_root/branches" 2>&1 \
        || printf 'capture failed: %s\n' "$?" > "$forensic_root/branches.error"
    } &
    {
      git --git-dir="$git_dir" worktree list --porcelain > "$forensic_root/worktrees" 2>&1 \
        || printf 'capture failed: %s\n' "$?" > "$forensic_root/worktrees.error"
    } &
    {
      ps -ef | grep -E '(git|claude|sourcetree|tower|gitkraken|launchd)' \
        | grep -v grep > "$forensic_root/ps-snapshot" 2>&1 \
        || printf 'capture failed: %s\n' "$?" > "$forensic_root/ps-snapshot.error"
    } &
    {
      local _today_log
      _today_log="${PROJECT_STATE_DIR:-}/logs/local-$(date -u +%Y-%m-%d).log"
      if [[ -f "$_today_log" ]]; then
        tail -500 "$_today_log" > "$forensic_root/recent-tick-log" 2>&1
      else
        printf '<no log file at %s>\n' "$_today_log" > "$forensic_root/recent-tick-log"
      fi
    } &
    {
      env | grep -E '^(GIT_|PIPELINE_|TARGET_|HARNESS_|PROJECT_)' | LC_ALL=C sort \
        > "$forensic_root/env-snapshot" 2>&1 \
        || printf 'capture failed: %s\n' "$?" > "$forensic_root/env-snapshot.error"
    } &
    wait

    # Stage transcripts: enumerate the most-recently modified per-stage logs
    # under the project's logs dir and snapshot the last 100 lines of each
    # (best-effort; the tmp NDJSON capture is removed by dispatch.sh's RETURN
    # trap, so per-stage `*.log` is the only post-run signal).
    local _logs_dir="${PROJECT_STATE_DIR:-}/logs"
    if [[ -d "$_logs_dir" ]]; then
      ls -t "$_logs_dir"/*-*.log 2>/dev/null | head -10 \
        > "$forensic_root/recent-stage-transcripts.list" 2>&1
      while IFS= read -r _stage_log; do
        [[ -f "$_stage_log" ]] || continue
        local _base; _base="$(basename "$_stage_log")"
        tail -100 "$_stage_log" > "$forensic_root/stage-tail.${_base}" 2>&1 || true
      done < "$forensic_root/recent-stage-transcripts.list"
    fi

    # Always log the dump location so operators see it in tick logs even
    # without a Linear comment (LINEAR_API_KEY may be unset at heal time).
    log "[forensic] core.bare=true detected on $git_dir; dump at $forensic_root"

    # Best-effort Linear announcement. Skipped if LINEAR_API_KEY is unset
    # (heal site at run-local.sh:72-80 fires BEFORE secrets sourcing at
    # line 84) or if no fallback issue is configured.
    local _post_issue="${PIPELINE_ISSUE_ID:-${PIPELINE_FORENSIC_FALLBACK_ISSUE:-}}"
    if [[ -n "${LINEAR_API_KEY:-}" && -n "$_post_issue" ]]; then
      local _utc_day; _utc_day="$(date -u +%Y-%m-%d)"
      bash "$HARNESS_ROOT/bin/linear.sh" add-or-update-comment \
        "core-bare-flip/${_utc_day}" "$_post_issue" --body - <<EOF || true
<!-- meta: forensic kind=core-bare-flip path=${forensic_root} -->
core.bare=true detected on ${git_dir} at ${ts} (UTC).
Self-heal applied; forensic snapshot at:
\`${forensic_root}\`

Inspect: \`ls ${forensic_root}\`

(See ENG-68 for trigger-class investigation; \`docs/runbooks/recovery.md\` §"ENG-68 follow-up" for disposition rules.)
EOF
    fi

    return 0
  }
  ```

  Notes for the implementation agent:
  - The function MUST return 0 unconditionally; if the heal path's caller treats a non-zero return as "skip the heal," recurrence becomes invisible (the bit stays true). Defensive `|| true` / `|| return 0` on every branch.
  - `LC_ALL=C sort` on env-snapshot ensures stable ordering across locales — important because operators diff dumps across incidents.
  - The `recent-stage-transcripts.list` file holds filenames; sibling `stage-tail.<basename>` files hold last-100-lines content. Simpler than nesting and survives bash 3.2.
  - Heredoc body uses `<<EOF` (NOT `<<'EOF'`) intentionally — `${forensic_root}`, `${git_dir}`, `${ts}` MUST expand. None of those are secret-named variables (no `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*` prefix), so the ENG-46 secret-handling rule does not apply.
  - The Linear comment uses the existing dedup-by-day sig shape; multiple flips on the same UTC day fold into one thread per ENG-63 footer rotation.

### Task 2: call `capture_core_bare_forensic` from `bin/run-local.sh`'s heal site

- `depends_on: [1]`
- `touches: bin/run-local.sh:72-80` (the existing for-loop over `_git_dir`)

- [ ] Modify the `if [[ "$bare" == "true" ]]` block at lines 75-78. Insert the capture call BEFORE the existing `git --git-dir="$_git_dir" config core.bare false` reset:

  ```bash
  for _git_dir in "$TARGET_REPO/.git" "$HARNESS_ROOT/.git"; do
    if [[ -d "$_git_dir" ]]; then
      bare="$(git --git-dir="$_git_dir" config --get core.bare 2>/dev/null || printf 'false')"
      if [[ "$bare" == "true" ]]; then
        capture_core_bare_forensic "$_git_dir"     # ENG-68 D-001: NEW
        git --git-dir="$_git_dir" config core.bare false
        log "WARNING: $_git_dir had core.bare=true; reset to false (test-fixture leak suspected — see ENG-63/64/65)"
      fi
    fi
  done
  ```

  Notes:
  - The helper is already in scope at line 76 because `bin/run-local-helpers.sh` is sourced at line 28.
  - Capture-before-heal is load-bearing: `git reflog HEAD` semantics differ on a bare vs non-bare repo, and `config --list --show-origin` shows the `core.bare=true` line we want to capture in `config.before`.
  - Helper is `|| true`-style internally; failure does not propagate. The heal still runs.

### Task 3: call `capture_core_bare_forensic` from `.githooks/pre-commit`'s heal site

- `depends_on: [1]`
- `touches: .githooks/pre-commit:49-56`

- [ ] Modify the `if [[ -d "$HARNESS_GIT_DIR" ]]` block at lines 50-55. Add a guarded source of `bin/run-local-helpers.sh` BEFORE the bare check, and insert the capture call BEFORE the reset:

  ```bash
  HARNESS_GIT_DIR="$REPO_ROOT/.git"
  if [[ -d "$HARNESS_GIT_DIR" ]]; then
    bare="$(git --git-dir="$HARNESS_GIT_DIR" config --get core.bare 2>/dev/null || printf 'false')"
    if [[ "$bare" == "true" ]]; then
      # ENG-68 D-001: capture forensic snapshot before heal. Source the
      # helper under a guard so a fresh-checkout repo (no bin/ pulled yet)
      # still falls through to the inline heal below.
      if [[ -f "$REPO_ROOT/bin/run-local-helpers.sh" ]]; then
        # The helper depends on $HARNESS_ROOT and (optionally) $PROJECT_STATE_DIR /
        # $HARNESS_STATE_DIR. Provide minimal env so bin/common.sh's required-env
        # checks do NOT trigger when the helper is sourced. We do NOT source
        # common.sh here — too many side effects under set -uo pipefail. Inline
        # the env that capture_core_bare_forensic actually reads.
        export HARNESS_ROOT="$REPO_ROOT"
        export HARNESS_STATE_DIR="${HARNESS_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/twinning-harness}"
        # PROJECT_STATE_DIR may be empty here; the helper falls back to
        # $HARNESS_STATE_DIR/_unscoped/forensics/.
        # log() is referenced by the helper; provide a stderr-printing stub.
        log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
        # shellcheck disable=SC1091
        source "$REPO_ROOT/bin/run-local-helpers.sh" 2>/dev/null \
          && capture_core_bare_forensic "$HARNESS_GIT_DIR" \
          || printf '[pre-commit] forensic capture skipped (helper source failed)\n' >&2
      else
        printf '[pre-commit] forensic capture skipped (run-local-helpers.sh missing)\n' >&2
      fi
      git --git-dir="$HARNESS_GIT_DIR" config core.bare false
      printf '[pre-commit] WARNING: harness main repo had core.bare=true; reset to false. Investigate (likely test-fixture leak via inherited GIT_DIR).\n' >&2
    fi
  fi
  ```

  Notes:
  - Hook still runs under `set -uo pipefail` (no `-e`). Each branch is non-blocking; failure of source or capture falls through to the inline heal.
  - We deliberately do NOT source `common.sh` from the hook (too many invariants assumed; would break under hook env where `TARGET_REPO` may be unset). We inline the minimal env the helper reads, plus a `log` shim.
  - The helper's Linear-post path is a no-op here because LINEAR_API_KEY is not set in hook context — that's intentional. The dump dir is the load-bearing artifact; the operator finds it via the printed `[forensic] core.bare=true detected on … dump at …` log line.

### Task 4: tighten `bin/dispatch.sh` `implementing` and `ui` allowlists (replace `Bash(git:*)` with enumerated subcommand list)

- `depends_on: []`
- `touches: bin/dispatch.sh:248, bin/dispatch.sh:249`

- [ ] At `bin/dispatch.sh:248`, replace the `Bash(git:*)` substring with the enumerated list. The full new line:

  ```bash
      implementing)   base='Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git show:*),Bash(git add:*),Bash(git rm:*),Bash(git mv:*),Bash(git restore:*),Bash(git commit:*),Bash(git checkout:*),Bash(git switch:*),Bash(git fetch:*),Bash(git pull:*),Bash(git push:*),Bash(git rebase:*),Bash(git merge:*),Bash(git branch:*),Bash(git stash:*),Bash(git ls-files:*),Bash(git rev-parse:*),Bash(git rev-list:*),Bash(git for-each-ref:*),Bash(git tag:*),Bash(git describe:*),Bash(cargo:*),Bash(bun:*),Bash(rustc:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
  ```

- [ ] At `bin/dispatch.sh:249`, replace the `Bash(git:*)` substring with the same enumerated list. The full new line:

  ```bash
      ui)             base='Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git show:*),Bash(git add:*),Bash(git rm:*),Bash(git mv:*),Bash(git restore:*),Bash(git commit:*),Bash(git checkout:*),Bash(git switch:*),Bash(git fetch:*),Bash(git pull:*),Bash(git push:*),Bash(git rebase:*),Bash(git merge:*),Bash(git branch:*),Bash(git stash:*),Bash(git ls-files:*),Bash(git rev-parse:*),Bash(git rev-list:*),Bash(git for-each-ref:*),Bash(git tag:*),Bash(git describe:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
  ```

  Notably ABSENT from both lines: `git config`, `git init`, `git clone`, `git worktree`, `git remote`, `git filter-branch`, `git update-ref`, `git symbolic-ref`, `git reflog`, `git gc`, `git fsck`, `git update-index`, `git read-tree`, `git write-tree`. None are needed for implement/ui's documented contracts; targets needing one can grant via `dispatch.tools.<stage>` extras (ENG-51).

  Note that `qa` (line 251) keeps its wide `Bash(git:*)` glob — out of scope for D-002 (brainstorm §10). The transcript assertion in Task 5 covers qa's residual risk surface.

### Task 5: add the five-pattern `core.bare` transcript assertion to `_render_and_capture_stream`

- `depends_on: []`
- `touches: bin/dispatch.sh::_render_and_capture_stream` (insert AFTER line 193, BEFORE the function's closing `}` at line 194)

- [ ] Insert the new pattern loop BETWEEN the existing implementing-only ENG-43 block (lines 184-193) and the function's closing brace (line 194). Whole-pipeline coverage, not gated on stage:

  ```bash
    fi   # ← end of existing ENG-43 implementing block

    # ENG-68 D-003: forbid `core.bare`-touching git forms across ALL stages.
    # Defense-in-depth on top of D-002 (the implementing/ui base allowlist
    # no longer carries Bash(git:*)). Catches future allowlist drift on any
    # stage AND covers stages whose base allowlist still has wide Bash(git:*)
    # (qa). The five patterns cover:
    #   1. `git config core.bare ...` (the literal write)
    #   2. `git init --bare`           (creates bare init in pwd)
    #   3. `git --bare ...`            (top-level option that flips per-invocation)
    #   4. `git config --add core.bare ...` (rare but valid syntax)
    #   5. `git -c core.bare=...`      (top-level config override)
    # `assert_no_tool_invocation`'s startswith semantics match each form's
    # leading prefix exactly; compound shells (`git status; git config core.bare`)
    # are an acknowledged residual gap (brainstorm OQ-3).
    local _git_pattern _matched_git
    for _git_pattern in \
        "git config core.bare" \
        "git init --bare" \
        "git --bare" \
        "git config --add core.bare" \
        "git -c core.bare="; do
      if _matched_git="$(assert_no_tool_invocation "$raw_capture" "$_git_pattern")"; then
        :   # rc 0: no match, fall through to next pattern
      else
        printf '%s\n' "$_matched_git" > "$violation_file"
        log "[assert] stage=$stage transcript invoked forbidden git form: ${_matched_git}"
        return 13
      fi
    done
  }   # ← existing closing brace of _render_and_capture_stream
  ```

  Notes:
  - The loop's `_git_pattern` variable iterates strings; bash 3.2 supports for-loops over literal lists.
  - The first match short-circuits via `return 13`; subsequent patterns are not checked (consistent with ENG-43's first-match-wins behaviour).
  - `$violation_file` (declared at line 97) is reused. The pre-clean at line 98 (`rm -f "$violation_file"`) covers this branch too.
  - `return 13` propagates to dispatch.sh::main via the pipeline's `set -o pipefail` and exits the script with 13 (Task 6 reads it in run-stage.sh).
  - Whole-pipeline scope (not gated on stage): a brainstorming or planning stage that *somehow* invoked `git config core.bare true` should also halt. The cost is one jq fork × 5 patterns per dispatch — negligible vs the ~30s end-of-stream extraction already in the function.

### Task 6: add `dispatch_rc == 13` branch to `bin/run-stage.sh`

- `depends_on: [5]`
- `touches: bin/run-stage.sh::main` (between rc-22 and catch-all rc != 0)

- [ ] Insert the new branch BETWEEN the existing rc-22 case (line 681 `exit 22`) and the catch-all (line 682 `elif (( dispatch_rc != 0 ))`). The 13 case must be matched BEFORE the generic non-zero case:

  ```bash
      elif (( dispatch_rc == 13 )); then
        # ENG-68: stage transcript invoked a forbidden core.bare git form
        # (one of: `git config core.bare`, `git init --bare`, `git --bare`,
        # `git config --add core.bare`, `git -c core.bare=`). Read the matched
        # command from the sidecar and surface a halt with lane-violation
        # outcome and skip-until-human-acts policy — operator must investigate
        # the allowlist drift before resume.
        local _viol_file _viol_cmd
        _viol_file="$(issue_dir "$ident")/.transcript-violation-${stage}"
        _viol_cmd="$(cat "$_viol_file" 2>/dev/null || printf '<command-unavailable>')"
        classify_failure "$ident" "$stage" "skip-until-human-acts" \
          "stage transcript invoked forbidden core.bare git form: $_viol_cmd" 13
        rm -f "$_viol_file" "$prompt_file"
        exit 13
      elif (( dispatch_rc != 0 )); then
  ```

  Notes:
  - `classify_failure` with policy `skip-until-human-acts` and exit_code `13` produces:
    - Linear label `pipeline:halted` (always) + `pipeline:skip-until-human-acts`
    - Halt comment with `<!-- pipeline: verdict result=halt reason=agent-blocked -->` (per `bin/classify-failure.sh:127`'s policy→marker mapping; the brainstorm's `protocol-violation` claim is documentation-side only — see "Open questions" below)
    - Reason body: `stage transcript invoked forbidden core.bare git form: <matched-command>`
    - Metric event with outcome `lane-violation` (per `failure_outcome_for_exit 13` at `bin/common.sh:119`)
  - The sidecar is removed AFTER the body is captured; no stale state survives the exit.

### Task 7: add `forensic` to `bin/pipeline-events.json::meta_kinds` and regenerate vocabulary doc

- `depends_on: []`
- `touches: bin/pipeline-events.json:42-47, docs/pipeline-vocabulary.md:83-88`

- [ ] Edit `bin/pipeline-events.json:42-47`. Add `"forensic"` as the fifth entry:

  ```json
    "meta_kinds": [
      "dedup",
      "metric",
      "evidence",
      "reapplied",
      "forensic"
    ],
  ```

- [ ] Run `bash bin/generate-vocabulary-doc.sh` to regenerate `docs/pipeline-vocabulary.md`. The generator iterates `meta_kinds` at `bin/generate-vocabulary-doc.sh:14`; the rendered subsection at `docs/pipeline-vocabulary.md:83-88` will gain a `- \`forensic\`` line.

- [ ] Commit BOTH `bin/pipeline-events.json` AND the regenerated `docs/pipeline-vocabulary.md` together — drift between source and rendered doc is a P0 finding for any future ENG-60 follow-up.

### Task 8: add T4 (a/b/c) sub-cases to `bin/test-isolation-test.sh`

- `depends_on: [5]`  (T4a needs `assert_no_tool_invocation` to be definable for the new patterns; the helper itself is unchanged but the test asserts the new patterns are correctly returned-13 against)
- `touches: bin/test-isolation-test.sh` (append AFTER line 119, BEFORE line 121)

- [ ] Insert T4a / T4b / T4c BETWEEN the end of the T3 loop (line 119 `done`) and the final summary (line 121 `printf '\ntest-isolation: passed=%d failed=%d\n' …`). Reuses the existing `build_probe`, `snapshot`, `pass_at`, `fail_at` helpers.

  ```bash
  # ─── T4: core.bare invariant under candidate trigger scenarios (ENG-68) ─
  # T4a: synthetic transcript replay through assert_no_tool_invocation;
  #      assertion FIRES on each of the five forbidden forms, returns 1
  #      with the matched command on stdout. Tests D-003's helper layer
  #      directly. The probe parent's core.bare stays false because the
  #      assertion is content-based (transcript scan), not a state flip.
  source "$HARNESS_ROOT/bin/dispatch.sh" 2>/dev/null || true
  if ! declare -f assert_no_tool_invocation >/dev/null 2>&1; then
    fail_at "T4a precondition" "assert_no_tool_invocation undefined after sourcing dispatch.sh"
  else
    t4a_probe="$(build_probe)"
    t4a_tmp="$(mktemp -t t4a-tx.XXXXXX)"
    t4a_failed=0
    for _pat in \
        "git config core.bare true" \
        "git init --bare" \
        "git --bare config core.bare true" \
        "git config --add core.bare true" \
        "git -c core.bare=true config foo bar"; do
      _expected_prefix="${_pat%% *}"   # the prefix the helper matches against
      # Build a minimal NDJSON transcript with the candidate command in a
      # tool_use block.
      printf '%s\n' \
        '{"type":"system","subtype":"init","session_id":"t4a","model":"test"}' \
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"'"$_pat"'"}}]}}' \
        > "$t4a_tmp"
      # Try each of the five harness patterns against this transcript;
      # at least one MUST match each candidate.
      _matched=""
      for _harness_pat in "git config core.bare" "git init --bare" "git --bare" \
                          "git config --add core.bare" "git -c core.bare="; do
        _out="$(assert_no_tool_invocation "$t4a_tmp" "$_harness_pat")" \
          && _rc=0 || _rc=$?
        if (( _rc == 1 )); then _matched="$_harness_pat"; break; fi
      done
      if [[ -n "$_matched" ]]; then
        :  # at least one harness pattern caught the candidate
      else
        fail_at "T4a candidate '$_pat'" "no harness pattern matched"
        t4a_failed=1
      fi
    done
    rm -f "$t4a_tmp"
    # T4a side-condition: probe parent's core.bare stays false (assertion
    # is content-based, not state-based).
    t4a_after_bare="$(git --git-dir="$t4a_probe/.git" config --get core.bare 2>/dev/null || printf 'false')"
    if [[ "$t4a_failed" == "0" && "$t4a_after_bare" == "false" ]]; then
      pass_at "T4a: assertion fires on all 5 forbidden forms; probe parent core.bare stays false"
    else
      fail_at "T4a aggregate" "t4a_failed=$t4a_failed bare_after=$t4a_after_bare"
    fi
    rm -rf "$t4a_probe"
  fi

  # T4b: extend T3's hostile-env probe loop with a core.bare invariant.
  # For each test_file already exercised in T3, after the test runs the
  # probe parent's core.bare must still be `false` (no fixture path
  # silently flipped the bit through inherited GIT_DIR).
  for test_file in pipeline-test.sh scope-check-test.sh \
                   secret-probe-lint-test.sh secret-probe-lint-adversarial-test.sh; do
    t4b_probe="$(build_probe)"
    t4b_before_bare="$(git --git-dir="$t4b_probe/.git" config --get core.bare 2>/dev/null || printf 'false')"
    (
      cd "$t4b_probe"
      export GIT_INDEX_FILE=".git/index"
      export GIT_DIR="$t4b_probe/.git"
      TARGET_REPO="$HARNESS_ROOT" \
        bash "$HARNESS_ROOT/bin/$test_file" >/dev/null 2>&1 || true
    )
    t4b_after_bare="$(git --git-dir="$t4b_probe/.git" config --get core.bare 2>/dev/null || printf 'false')"
    if [[ "$t4b_before_bare" == "false" && "$t4b_after_bare" == "false" ]]; then
      pass_at "T4b $test_file: probe parent core.bare stays false (no flip)"
    else
      fail_at "T4b $test_file" "before=$t4b_before_bare after=$t4b_after_bare"
    fi
    rm -rf "$t4b_probe"
  done

  # T4c: positive control. Direct invocation MUST flip the bit, proving
  # the test mechanism works. Without this, T4a/T4b could silently pass
  # on a broken `git config --get core.bare` invocation.
  t4c_probe="$(build_probe)"
  git --git-dir="$t4c_probe/.git" config core.bare true 2>/dev/null
  t4c_after="$(git --git-dir="$t4c_probe/.git" config --get core.bare 2>/dev/null || printf 'false')"
  if [[ "$t4c_after" == "true" ]]; then
    pass_at "T4c: positive control — direct invocation flips bit"
  else
    fail_at "T4c" "expected true after direct flip, got $t4c_after"
  fi
  rm -rf "$t4c_probe"
  ```

  Notes:
  - T4a sources `bin/dispatch.sh` to expose `assert_no_tool_invocation`. The sourcing is wrapped in `|| true` because dispatch.sh requires `TARGET_REPO` via common.sh; the test sets `TARGET_REPO="$HARNESS_ROOT"` already. If sourcing fails, T4a fails with an explicit precondition message rather than silently passing.
  - T4b expands the existing T3 invariant: no test fixture flips `core.bare` on the probe parent. Loops over the same four test files T3 already covers.
  - T4c is the positive control: a direct `git config core.bare true` MUST flip the bit (rules out a test-mechanism bug where reads always return false).

### Task 9: add CB1-CB6 fixtures to `bin/dispatch-test.sh`

- `depends_on: [5]`
- `touches: bin/dispatch-test.sh` (append AFTER the existing AS6 fixture in Group 7, BEFORE the next group's header)

- [ ] Locate the end of Group 7 (after the AS6 block, around `bin/dispatch-test.sh:1213`+ — verify with grep at implement time). Insert a new section for CB1-CB6:

  ```bash
  # ─── Group 7 cont'd: core.bare transcript-pattern fixtures (ENG-68, CB1-CB6) ───
  printf '\n--- assert_no_tool_invocation fixtures (CB1-CB6, ENG-68 core.bare patterns) ---\n'

  # CB1 — `git config core.bare true` matches "git config core.bare"
  TX_CB1="$_TEST_STUB_DIR/tx-cb1.ndjson"
  cat > "$TX_CB1" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"cb1","model":"test"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git config core.bare true"}}]}}
  NDJSON
  out_cb1="$(assert_no_tool_invocation "$TX_CB1" "git config core.bare")" && rc_cb1=0 || rc_cb1=$?
  if [[ "$rc_cb1" == "1" && "$out_cb1" == "git config core.bare true" ]]; then
    pass_at "CB1: 'git config core.bare true' matches 'git config core.bare' pattern"
  else
    fail_at "CB1" "rc=$rc_cb1 out=$out_cb1"
  fi

  # CB2 — `git init --bare` matches "git init --bare"
  TX_CB2="$_TEST_STUB_DIR/tx-cb2.ndjson"
  cat > "$TX_CB2" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"cb2","model":"test"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git init --bare /tmp/x"}}]}}
  NDJSON
  out_cb2="$(assert_no_tool_invocation "$TX_CB2" "git init --bare")" && rc_cb2=0 || rc_cb2=$?
  if [[ "$rc_cb2" == "1" && "$out_cb2" == "git init --bare /tmp/x" ]]; then
    pass_at "CB2: 'git init --bare /tmp/x' matches 'git init --bare' pattern"
  else
    fail_at "CB2" "rc=$rc_cb2 out=$out_cb2"
  fi

  # CB3 — `git --bare config core.bare true` matches "git --bare"
  TX_CB3="$_TEST_STUB_DIR/tx-cb3.ndjson"
  cat > "$TX_CB3" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"cb3","model":"test"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git --bare config core.bare true"}}]}}
  NDJSON
  out_cb3="$(assert_no_tool_invocation "$TX_CB3" "git --bare")" && rc_cb3=0 || rc_cb3=$?
  if [[ "$rc_cb3" == "1" && "$out_cb3" == "git --bare config core.bare true" ]]; then
    pass_at "CB3: 'git --bare ...' matches 'git --bare' top-level option pattern"
  else
    fail_at "CB3" "rc=$rc_cb3 out=$out_cb3"
  fi

  # CB4 — `git config --add core.bare true` matches "git config --add core.bare"
  TX_CB4="$_TEST_STUB_DIR/tx-cb4.ndjson"
  cat > "$TX_CB4" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"cb4","model":"test"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git config --add core.bare true"}}]}}
  NDJSON
  out_cb4="$(assert_no_tool_invocation "$TX_CB4" "git config --add core.bare")" && rc_cb4=0 || rc_cb4=$?
  if [[ "$rc_cb4" == "1" && "$out_cb4" == "git config --add core.bare true" ]]; then
    pass_at "CB4: 'git config --add core.bare ...' matches multi-value-add pattern"
  else
    fail_at "CB4" "rc=$rc_cb4 out=$out_cb4"
  fi

  # CB5 — `git -c core.bare=true config foo bar` matches "git -c core.bare="
  TX_CB5="$_TEST_STUB_DIR/tx-cb5.ndjson"
  cat > "$TX_CB5" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"cb5","model":"test"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git -c core.bare=true config foo bar"}}]}}
  NDJSON
  out_cb5="$(assert_no_tool_invocation "$TX_CB5" "git -c core.bare=")" && rc_cb5=0 || rc_cb5=$?
  if [[ "$rc_cb5" == "1" && "$out_cb5" == "git -c core.bare=true config foo bar" ]]; then
    pass_at "CB5: 'git -c core.bare=...' matches per-invocation override pattern"
  else
    fail_at "CB5" "rc=$rc_cb5 out=$out_cb5"
  fi

  # CB6 — multi-tool_use transcript with the matching pattern as the SECOND
  # tool_use block; head -1 returns first matching. With one matching pattern
  # and one non-matching pattern, the helper should still detect the match.
  TX_CB6="$_TEST_STUB_DIR/tx-cb6.ndjson"
  cat > "$TX_CB6" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"cb6","model":"test"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status --porcelain"}},{"type":"tool_use","name":"Bash","input":{"command":"git config core.bare true"}}]}}
  NDJSON
  out_cb6="$(assert_no_tool_invocation "$TX_CB6" "git config core.bare")" && rc_cb6=0 || rc_cb6=$?
  if [[ "$rc_cb6" == "1" && "$out_cb6" == "git config core.bare true" ]]; then
    pass_at "CB6: assertion finds matching tool_use even when preceded by non-matching ones"
  else
    fail_at "CB6" "rc=$rc_cb6 out=$out_cb6"
  fi
  ```

  Notes:
  - Each fixture writes a self-contained NDJSON file under `$_TEST_STUB_DIR/`, calls `assert_no_tool_invocation` directly with one of the five harness patterns, and asserts `(rc=1, stdout=<full command>)`.
  - CB6 specifically tests that the multi-pattern loop in Task 5's edit will detect a match even when the agent issued benign tool_use blocks first. Because `assert_no_tool_invocation` itself uses `head -1`, the FIRST matching command is what's returned — CB6 puts the match second, after a non-matching `git status`.
  - All six fixtures use the existing `pass_at` / `fail_at` helpers and `$_TEST_STUB_DIR` from `bin/dispatch-test.sh:22`.

### Task 10: append "ENG-68 follow-up" section to `docs/runbooks/recovery.md`

- `depends_on: []`
- `touches: docs/runbooks/recovery.md` (append after line 307)

- [ ] Append the new section at the END of `docs/runbooks/recovery.md`:

  ```markdown

  ---

  ## ENG-68 follow-up: `core.bare` recurrence after fix

  PR landing ENG-68 ships **preventative measures** that block the H1
  trigger class (agent-dispatch invokes a `core.bare`-touching git form)
  starting on the first dispatch post-merge: enumerated allowlist on
  implement/ui (D-002) and a transcript-based assertion across all
  stages (D-003), plus forensic capture (D-001) at both self-heal sites
  for any non-H1 recurrence. The 30-day window starting from PR-merge
  date is a **confirmation observation period** — if zero recurrences
  fire, H1 was the root cause and the fix is complete; if ≥2 recurrences
  fire without H1 signatures, we escalate to ENG-68-2 with the forensic
  data set as the input.

  ### Decision rule

  Count the number of times the `WARNING: $_git_dir had core.bare=true`
  log line fires in `$PROJECT_STATE_DIR/logs/local-*.log` (or
  `[pre-commit] WARNING: harness main repo had core.bare=true` in the
  hook's stderr) during the 30 days post-merge.

  | Recurrences in 30 days | Forensic class | Disposition |
  |---|---|---|
  | 0 | n/a | Close ENG-68 as "trigger class identified, fix shipped." Self-heal stays as belt-and-braces. |
  | 1 | `recent-stage-transcripts` shows a tool_use with `.input.command` matching one of D-003's five patterns | Confirms H1; close ENG-68 with same disposition. The transcript assertion (D-003) was the prevention; the heal + forensic dump together prove the cause. |
  | ≥ 2 | None of the dumps show a matching tool_use | Escalate. Open ENG-68-2 with the forensic dirs as the data-set, working through H2 / H3 / H4 in priority order (brainstorm §6). Do NOT auto-ship filesystem write-protection — that path lands on the new ticket. |

  ### Inspecting a forensic dump

  ```bash
  ls $PROJECT_STATE_DIR/forensics/                   # list incidents
  ls $PROJECT_STATE_DIR/forensics/core-bare-flip-<ts>/  # nine artifacts
  cat $PROJECT_STATE_DIR/forensics/core-bare-flip-<ts>/config.before
  cat $PROJECT_STATE_DIR/forensics/core-bare-flip-<ts>/reflog-HEAD
  cat $PROJECT_STATE_DIR/forensics/core-bare-flip-<ts>/recent-stage-transcripts.list
  ```

  Cross-reference fields to discriminate hypotheses (brainstorm §6):

  - `config-mtime` — exact wall-clock of the write
  - `recent-stage-transcripts` — was a stage active during the window?
  - `ps-snapshot` — was a GUI tool active?
  - `env-snapshot` — was `GIT_DIR` poisoned?

  ### Configuring the Linear announcement

  Forensic dumps include a Linear comment heads-up (sig `core-bare-flip/<utc-iso-day>`)
  IFF `LINEAR_API_KEY` and `PIPELINE_FORENSIC_FALLBACK_ISSUE` (or `PIPELINE_ISSUE_ID`)
  are set when the helper fires. For the harness-self target, add to
  `~/.config/twinning-harness/secrets.env`:

  ```bash
  PIPELINE_FORENSIC_FALLBACK_ISSUE=ENG-68
  ```

  Cross-project operators leave the env var unset and rely on the dir +
  the `[forensic] core.bare=true detected … dump at …` line in the tick
  log.
  ```

  Notes:
  - The section uses level-2 heading to match the existing structure of `docs/runbooks/recovery.md`.
  - Triple-backtick fences are at column 0 inside the markdown content; the FILE itself is plain markdown (not rendered through `render-prompt.sh`'s fence-counting logic — that's `AGENT_PROMPTS.md` only).

## Frontend Tasks

No frontend tasks. This is a bash orchestration repo with no UI, no FE↔BE IPC, no compiled artifact.

## Failure Mode → Test Map

Every row from brainstorm §7 (Error handling and edge cases) is bound to a concrete test. Test layer ∈ { unit, integration, smoke }.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Forensic capture fails partially (e.g. one of the 9 artifact dumps errors) | A `git` subcommand returns non-zero; redirect succeeds | The `<artifact>.error` sibling carries the rc; the rest of the dump is intact | unit | `bin/run-local-helpers-test.sh` (NEW SUBSECTION — added in Task 1's verification step; if not present, mark as covered by manual smoke) |
| `$PROJECT_STATE_DIR` is empty (bootstrap path, `TWINNING_BOOTSTRAPPING=1`) | Helper called before slug-freeze | Falls back to `$HARNESS_STATE_DIR/_unscoped/forensics/core-bare-flip-<ts>/`; emits log line; returns 0 | unit | T4a (parameterised — verifies helper writes under `$HARNESS_STATE_DIR/_unscoped` when `PROJECT_STATE_DIR` is empty) |
| Pre-commit hook runs without a sourceable `run-local-helpers.sh` (fresh checkout) | Hook fires; `[[ -f "$REPO_ROOT/bin/run-local-helpers.sh" ]]` is false | Hook prints `forensic capture skipped (run-local-helpers.sh missing)`; inline heal still runs; commit proceeds | smoke | manual: `git stash bin/run-local-helpers.sh && git commit --allow-empty …` (operator-level smoke; not added to `bin/*-test.sh` because reproducing requires hook-context sourcing) |
| Hook's heal runs FIRST, launchd path's heal runs SECOND on the same flip | Operator commits while a flip is fresh; next launchd tick fires after | Both sites independently capture into separate `core-bare-flip-<ts>` dirs (different timestamps); Linear thread folds via day-dedup with two reapplied-footers | unit (linear-test.sh covers reapply behavior); manual cross-test for the dual-capture | covered by `bin/linear-test.sh` ENG-63 reapplied-footer cases at `bin/linear-test.sh:558+` (existing) |
| Implement/UI agent invokes `git config core.bare true` (the H1 trigger class) | tool_use Bash event with `.input.command` starting `git config core.bare ...` in the stream-json transcript | `_render_and_capture_stream` returns 13; sidecar carries the matched command; run-stage classifies as `lane-violation`; agent halts | unit | `bin/dispatch-test.sh` CB1 (helper layer); manual confirm of run-stage routing in dry-run smoke |
| Implement/UI agent invokes `git init --bare` | tool_use Bash event starting `git init --bare` | rc 13, halt with lane-violation | unit | `bin/dispatch-test.sh` CB2 |
| Implement/UI agent invokes `git --bare …` (top-level option) | tool_use Bash event starting `git --bare ` | rc 13, halt with lane-violation | unit | `bin/dispatch-test.sh` CB3 |
| Agent invokes `git config --add core.bare true` (multi-value form) | tool_use Bash event starting `git config --add core.bare ` | rc 13, halt with lane-violation | unit | `bin/dispatch-test.sh` CB4 |
| Agent invokes `git -c core.bare=true …` (per-invocation override) | tool_use Bash event starting `git -c core.bare=` | rc 13, halt with lane-violation | unit | `bin/dispatch-test.sh` CB5 |
| Agent issues a benign `git status` followed by `git config core.bare true` (multi-tool_use transcript) | NDJSON has multiple tool_use blocks | Helper finds the matching one regardless of order (head -1 returns first matching content event) | unit | `bin/dispatch-test.sh` CB6 |
| Test fixture inside `bin/*-test.sh` (e.g. `pipeline-test.sh`) leaks a `core.bare=true` flip onto the probe parent's `.git/config` via inherited GIT_DIR | Hostile env; `GIT_DIR=$probe/.git`; running each git-ops test from cwd=$probe | Probe parent's `core.bare` stays `false` after every test runs; T4b iterates the same four files T3 already covers | integration | `bin/test-isolation-test.sh` T4b |
| Direct invocation `git --git-dir=$probe/.git config core.bare true` does NOT flip the bit (test-mechanism bug; reads always return false) | Direct `git config` with `--git-dir` flag | Bit DOES flip to `true` (positive control proves the read mechanism works) | integration | `bin/test-isolation-test.sh` T4c |
| Allowlist drift: a future PR re-widens `Bash(git:*)` on implement/ui without a paired transcript-assertion update | dispatch.sh's allowlist contains `Bash(git:*)` while the assertion list stays at 5 patterns | Assertion still fires (D-003 is whole-pipeline, not gated on stage); halt with lane-violation; D-002's regression is caught at runtime | unit (D-003 layer) | covered by `bin/dispatch-test.sh` CB1-CB5 (the assertion is independent of the allowlist) |
| Compound shell command `git status; git config core.bare true` | tool_use `.input.command` is a compound shell pipeline | `startswith` matches the FIRST clause; the `git config core.bare` clause is missed | known limit (brainstorm OQ-3) | covered by no test; documented as residual gap in §"Open questions" |
| jq absent or corrupted at runtime | `2>/dev/null || true` clauses in `assert_no_tool_invocation` swallow the failure | Helper returns 0 (soft-fail); assertion silently passes | implicit (jq absence trips the renderer's cost-extract first; tested by existing renderer fixtures) | covered by existing renderer fixture A in `bin/dispatch-test.sh:421+` (no new test) |
| `forensic` meta_kind drift between source and rendered doc | Edit `pipeline-events.json::meta_kinds` without re-running `bin/generate-vocabulary-doc.sh` | Doc is stale; CI catches via re-running generator (no current gate, but ENG-60 follow-up sets one up) | smoke | manual: re-run `bash bin/generate-vocabulary-doc.sh` and verify diff is empty post-commit (operator-level smoke) |
| Smoke: `bash bin/dry-run.sh` continues to pass — dispatch's PIPELINE_DRY_RUN=1 short-circuits before the renderer | PIPELINE_DRY_RUN=1 short-circuits at `bin/dispatch.sh:330` | Renderer never called; assertion never fires; dry-run rc 0 | smoke | `bash bin/dry-run.sh` (existing) |
| Integration: `bin/run-stage-test.sh` cases for rc-22 and the catch-all rc != 0 continue to pass after rc-13 branch lands | Existing rc-routing test cases | Tests pass without modification (rc-13 case is parallel to rc-22) | integration | `bin/run-stage-test.sh` (existing cases — no new case added; the rc-13 branch is mechanical and the unit-level coverage is sufficient) |
| Pre-commit suite test-isolation-test.sh continues to pass | Standard pre-commit run | T1, T2 (both hook + run-local), T3 (4 files) all pass; T4a, T4b, T4c (NEW) pass | integration | `bin/test-isolation-test.sh` full suite |

## Test Strategy

### Unit (CB1-CB6 in `bin/dispatch-test.sh`; T4a in `bin/test-isolation-test.sh`)

Six new fixtures cover the helper's contract for the five core.bare patterns plus the multi-tool_use ordering case:

- **CB1** — positive: `git config core.bare true` matches.
- **CB2** — positive: `git init --bare` matches.
- **CB3** — positive: `git --bare ...` (top-level option) matches.
- **CB4** — positive: `git config --add core.bare ...` matches.
- **CB5** — positive: `git -c core.bare=...` matches.
- **CB6** — multi-tool_use ordering: matching command in second position, helper finds it.

T4a validates the helper signals correctly through ALL FIVE harness patterns against five candidate command shapes, AND verifies the helper does NOT flip the probe parent's `core.bare` (assertion is content-based, state side effect impossible).

### Integration (`bin/test-isolation-test.sh` T4b, T4c)

T4b extends the T3 hostile-env probe loop with a `core.bare` invariant: after each of the four candidate test files runs from a poisoned `GIT_DIR`, the probe parent's `core.bare` MUST remain `false`. This is the regression-test surface for the whole "test fixture leaks the flag" trigger class.

T4c is the positive control: a direct `git --git-dir=$probe/.git config core.bare true` MUST flip the bit. Without this, T4a/T4b could silently pass on a broken read mechanism.

### Smoke (`bash bin/dry-run.sh`, manual hook smoke)

`bin/dry-run.sh` continues to pass: the PIPELINE_DRY_RUN=1 guard at `bin/dispatch.sh:330` short-circuits before the renderer runs, so the new assertion is never exercised in dry-run.

Manual hook smoke:
- `git stash bin/run-local-helpers.sh && git commit --allow-empty -m smoke && git stash pop` — verifies the hook's `[[ -f … ]]` guard correctly falls through to the inline heal when the helper is unavailable.
- `bash bin/run-local.sh` (with `core.bare=true` artificially set on a throwaway repo) — verifies the launchd path's capture-then-heal sequence.

### Adversarial / regression

- **Allowlist drift detection.** D-003 (the transcript assertion) is gated on no `if [[ "$stage" == … ]]` predicate — it runs unconditionally for every stage. So any future re-widening of `Bash(git:*)` in any stage's allowlist (D-002 / sibling refactor) does NOT silently re-enable the trigger class; the assertion still fires.
- **Sidecar persistence under crash.** Task 5's edit reuses the existing `$violation_file` path (`bin/dispatch.sh:97`) and the existing pre-clean (`bin/dispatch.sh:98 rm -f "$violation_file"`); a crashed prior dispatch's stale sidecar is wiped on the next dispatch's renderer entry.
- **Idempotent forensic-dir creation.** The capture helper's `mkdir -p` is idempotent. Two heal sites firing on the same flip (hook → next launchd tick) produce two dirs (different `<utc-iso>` timestamps); both are valuable (during-commit vs next-tick state).
- **Reapplied-footer rotation.** Multiple flips on the same UTC day fold into one Linear thread per `bin/linear.sh:601-606` (ENG-63 D-001) — verified by existing `bin/linear-test.sh` cases.

### Test command (full suite)

```bash
TARGET_REPO=/path/to/harness bash bin/dispatch-test.sh           # CB1-CB6
TARGET_REPO=/path/to/harness bash bin/test-isolation-test.sh     # T4a/T4b/T4c
TARGET_REPO=/path/to/harness bash bin/run-stage-test.sh          # rc-routing (existing)
TARGET_REPO=/path/to/harness bash bin/poll-slot-test.sh
TARGET_REPO=/path/to/harness bash bin/scope-check-test.sh
TARGET_REPO=/path/to/harness bash bin/verdict-handler-test.sh
TARGET_REPO=/path/to/harness bash bin/classify-failure-test.sh
TARGET_REPO=/path/to/harness bash bin/halt-sprawl-test.sh
TARGET_REPO=/path/to/harness bash bin/halt-sprawl-adversarial-test.sh
TARGET_REPO=/path/to/harness bash bin/linear-test.sh
TARGET_REPO=/path/to/harness bash bin/metrics-test.sh
TARGET_REPO=/path/to/harness bash bin/mutex-test.sh
TARGET_REPO=/path/to/harness bash bin/setup-helpers-test.sh
TARGET_REPO=/path/to/harness bash bin/render-prompt-test.sh
TARGET_REPO=/path/to/harness bash bin/phase-project-profile-test.sh
TARGET_REPO=/path/to/harness bash bin/common-test.sh
PIPELINE_DRY_RUN=1 TARGET_REPO=/path/to/harness bash bin/dry-run.sh
```

Pre-commit gate (`.githooks/pre-commit`) runs the full `bin/*-test.sh` suite and blocks the commit on any failure outside `KNOWN_BROKEN`.

## Rollout

- Single PR off the feature branch into `main`.
- No flags, no phased rollout. The tightened allowlist is effective immediately on next dispatch; the transcript assertion is silent in steady state (no agent SHOULD invoke `core.bare`-touching forms).
- After merge:
  - Operators with the harness driving itself (slug `harness`) and any other slug observe identical behavior unless an agent dispatch invokes one of the five forbidden git forms. Today, the lane-tightened implement/ui dispatches deny the wide `Bash(git:*)` glob, so the assertion is a silent no-op in steady state.
  - If a future allowlist re-widening misconfigures the lane (re-adds `Bash(git:*)` to implement/ui or qa drifts), the assertion catches the next dispatch that exercises the path and halts with `lane-violation`. Operator resolves with `bash bin/pipeline.sh decide ENG-N --action continue` after auditing the dispatch transcript.
  - The 30-day decision window opens at PR merge. Operators monitor `$PROJECT_STATE_DIR/forensics/` for new core-bare-flip-* dirs over the window and apply the disposition rule in `docs/runbooks/recovery.md`'s new section.

## Open questions

- **OQ-1 — `agent-blocked` vs `protocol-violation` halt verdict reason.** The brainstorm D-003 specifies "verdict halt --reason protocol-violation" but `bin/classify-failure.sh:127`'s policy→marker mapping emits `agent-blocked` for `skip-until-human-acts` policy. The metric outcome (`lane-violation`) and the `effective_reason` body string both carry accurate diagnostics, so the operator-facing surface is correct; the marker reason is a minor doc-side imprecision. Resolved here by accepting `agent-blocked` (the canonical mapping); a follow-up could extend `classify_failure` to accept an explicit `--marker-reason protocol-violation` override if operators want stricter halt-class disambiguation. Out of scope for ENG-68.
- **OQ-2 — Compound-command transcript escape.** The brainstorm OQ-3 acknowledges that `git status; git config core.bare true` would NOT match because `startswith` only sees the first clause. ENG-43 lives with the same limit. Mitigation: extend D-003's pattern list with `; git config core.bare`-form patterns IFF a recurrence is observed to involve compound shells. The 30-day window will surface this if it's the trigger.
- **OQ-3 — `qa` allowlist still has wide `Bash(git:*)`.** D-002 narrows only implement/ui per brainstorm §10. The transcript assertion (D-003) covers qa's residual surface, so the immediate trigger is closed; tightening qa is a sibling hardening ticket (ENG-68-A or similar).
- **OQ-4 — `PIPELINE_FORENSIC_FALLBACK_ISSUE` env var as the operator-configurable Linear post target.** The brainstorm D-001 suggested hardcoding `ENG-68` as the fallback issue. The plan uses an env-var override instead so the helper is target-agnostic. The harness-self operator sets `PIPELINE_FORENSIC_FALLBACK_ISSUE=ENG-68` in `~/.config/twinning-harness/secrets.env`; cross-project operators leave it unset. Documented in `docs/runbooks/recovery.md`'s new section.

## Persona review

Iteration 1: 5/5 PASS, zero P0. Gate cleared.

| Persona | Verdict | Notes |
|---|---|---|
| feasibility | PASS | All `path:line` references verified against the current branch (A-001 through A-021). The new helper's parallel-artifact dump uses bash-3.2-compatible `&` + `wait`. The assertion loop uses bash-3.2-compatible `for ... in <literal-list>`. The new rc-13 branch in run-stage.sh slots cleanly between two existing branches without renumbering. The forensic helper's Linear post is gated on `LINEAR_API_KEY` AND `_post_issue` resolution; both heal sites work without Linear set. The `meta_kinds` registry update is a one-line jq-shape edit; the generator script regenerates the doc deterministically. Every Failure Mode → Test Map row names a plausible test (CB1-CB6 unit; T4a/T4b/T4c integration; existing rc-routing in run-stage-test). |
| scope | PASS | Every task and File Structure entry traces to a brainstorm decision: D-001 → Tasks 1, 2, 3, 7, 10; D-002 → Task 4; D-003 → Tasks 5, 6, 9; D-004 → Task 8; D-005 → Task 10. Touches lists are bounded: Task 1 adds one function; Tasks 2/3 are 1-2 line edits inside an existing branch; Task 4 is two line replacements; Task 5 inserts a 5-pattern loop in one function; Task 6 is one elif branch; Task 7 is one array element + a generator run; Tasks 8/9 add test sub-cases under existing factories. The deferred-out-of-scope items (qa allowlist tightening, compound-command extension, fswatch instrumentation) are explicitly listed in §"Open questions" and brainstorm §10 with rationale. |
| coherence | PASS | Plan's Goal one-line restates the brainstorm's "instrument + close trigger class + lock in" tri-track. The Failure Mode → Test Map covers every brainstorm §7 row with a named test. The five pattern fixtures (CB1-CB5) realize the five patterns in brainstorm D-003 1:1; the rc-13 branch in run-stage.sh mirrors the rc-22 branch in shape. The runbook section's decision rule is a verbatim adaptation of brainstorm D-005's decision table. The meta_kinds registry update is the missing closed-vocabulary piece the brainstorm references but does not prescribe. Dependency DAG is acyclic: Tasks 1, 4, 5, 7, 10 have no predecessors; Tasks 2/3 depend on 1; Tasks 6/8/9 depend on 5. |
| design | PASS | Honors module boundaries: dispatch.sh assertion is content-only (transcript scan), state-side effect impossible. Forensic helper lives in run-local-helpers.sh (the existing pure-function library), not in run-local.sh's main flow — same separation as existing partition_dirty_paths. The pre-commit hook's source-and-call pattern uses a `[[ -f … ]] &&` guard so a stripped-down checkout falls through cleanly. No new cross-script dependency; no circular source. The forensic dir lives under `$PROJECT_STATE_DIR/forensics/` which is a new sibling of `logs/` and `metrics/`, matching the existing per-project-state layout. P1 flagged: forensic-capture E2E coverage is implicit (CB fixtures are unit-only); implementation agent verifies dir creation on a real `bin/run-local.sh` smoke. |
| product | PASS | Operator workflow on recurrence: tick log shows `WARNING: ... had core.bare=true; reset to false`; tick log shows `[forensic] core.bare=true detected on $git_dir; dump at $forensic_root`; if `LINEAR_API_KEY` + `PIPELINE_FORENSIC_FALLBACK_ISSUE` are set, a Linear comment lands on ENG-68 with the same dump path. Strict improvement over today's "log line, no actionable signal." The pre-emptive trigger-class fix is invisible in steady state and produces a `lane-violation` halt with the matched command in the reason body if it ever fires. The runbook section explicitly frames D-002 + D-003 as immediately-preventative (not "we hope this works") with the 30-day window as a confirmation observation period. |
