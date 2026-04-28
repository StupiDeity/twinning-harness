---
linear: ENG-46
date: 2026-04-28
topic: Forbid the `${SECRET:-FALLBACK}` env-probe anti-pattern via lint, preamble rule, sweep, and CI workflow
---

# Plan — ENG-46 forbid the `${SECRET:-FALLBACK}` env-probe anti-pattern

Implementation plan for the design in
`docs/brainstorms/2026-04-28-agent-env-probe-pattern-secret-unset-leaks-key-values-into-agent-context-design.md`.

## Anti-anchoring check

**Problem restatement (user perspective).** An agent's env-probe pattern
`${LINEAR_API_KEY:+SET}${LINEAR_API_KEY:-UNSET}` materialized the live key
value into its local shell context (the second expansion returns the value
when the var is set), and the same idiom anywhere that pipes its output to
a durable destination would leak the secret. We need a structural defense
that prevents recurrence in committed code and tells every dispatched agent
not to write the pattern.

**Does the brainstorm address this?** Yes. The brainstorm proposes a static
`git grep` lint that fails on the dangerous pattern, a preamble rule in
`AGENT_PROMPTS.md` (read by every dispatched agent), a learned-rule entry
in `learned-rules/twinning/brainstorm.md`, a one-time lexical sweep of the
existing in-tree `:-` hits to safe equivalents, and a minimal CI workflow
running the lint on every PR. No reframing — these are the exact items the
issue's "IN" scope lists, plus the CI workflow which the issue explicitly
calls out ("machine-runnable on every tick and on every commit").

**Solution proportionality.** Single-PR scope: 2 new bash files (~160 lines
total: lint + its test), 1 new ~11-line CI workflow (the first in this
repo), 1 new section in `AGENT_PROMPTS.md`, 1 appended rule block in
`learned-rules/twinning/brainstorm.md`, 1 `check` line added to
`bin/dry-run.sh`, and 15 single-line lexical rewrites — 11 Group-1
lines (one per file, in 11 test files) plus 4 Group-2 lines (in 3 files:
`bin/status.sh` ×2, `bin/poll-slot-test.sh` ×1, `bin/dry-run.sh` ×1).
Distinct files touched by rewrites: 11 (Group-1) + 3 (Group-2) − 1
(`bin/poll-slot-test.sh` appears in both groups) = **13 distinct files**.
No new orchestration surface, no new label, no new verdict shape, no
behavioral change in any tick path. Proportionate to a security-hygiene
forward-looking fix.

**Result of anti-anchoring checks: PROCEED.**

**Note on template fit.** The Linear plan-prompt template assumes a Tauri +
SvelteKit + Rust target, but ENG-46 is a harness-self issue (bash
orchestration). Per project memory `project_implement_prompt_template_misrouting`,
the implement-prompt salvages on harness-self while UI-prompts halt-for-human.
This plan is a bash-only plan: there are no Rust crates, no Tauri commands,
no SvelteKit components touched. The "Frontend Tasks" section is therefore
empty by design (recorded explicitly to satisfy the template contract).
The "Command API Contract" section reports "no new command API". The same
shape was used in `docs/plans/2026-04-28-eng-42-reframe-implement-pr-guard.md`
("Bash harness — no Tauri/Rust backend.") and is consistent with that
precedent.

## Goal

Land a single PR off `main` that, after merge, satisfies all six acceptance
criteria from the Linear issue:

1. `git grep -nE '\$\{[A-Z_]*(KEY|TOKEN|SECRET)[A-Z_]*:-'` returns zero hits.
2. `git grep -nE '\$\{(ANTHROPIC|GITHUB|LINEAR)[A-Z_]*:-'` returns zero hits.
3. `bin/secret-probe-lint.sh` runs as a `check` line in `bin/dry-run.sh` and
   fails the smoke if either grep finds a hit; passes against the swept tree.
4. `AGENT_PROMPTS.md` carries a "Secret-handling preamble (ENG-46)" section
   in the preamble (every stage reads it; placed outside any per-stage fence).
5. `learned-rules/twinning/brainstorm.md` carries a one-paragraph rule
   entry naming the bug, citing ENG-45, and listing the safe replacement.
6. No new `pipeline-rejection` shape, no new label, no behavioral change in
   `bin/run-stage.sh`'s scope-check or guards.

The lint regex is intentionally a strict superset of AC1/AC2: it covers
`:[\+\-]` (both `:-` and `:+` halves) so the sibling pattern
`${KEY:+--auth=$KEY}` is also rejected. AC1/AC2 are subsets and are
satisfied automatically.

## Assumption Inventory

Each assumption below is verified against the current tree (`git log -1`
points at commit `2f83d68 docs(ENG-46): brainstorm — forbid …`). Quoted
`path:line` excerpts are taken from the current worktree.

### Verified — load-bearing constraints

- **A-01 (verified).** Lint hit list across both AC regexes. From
  `git grep -nE '\$\{[A-Z_]*(KEY|TOKEN|SECRET)[A-Z_]*:[\+\-]'` and
  `git grep -nE '\$\{(ANTHROPIC|GITHUB|LINEAR)[A-Z_]*:[\+\-]'` over the
  current tree (excluding `docs/**` which contains pattern examples in the
  brainstorm itself):
  ```
  bin/classify-failure-test.sh:14:export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
  bin/dispatch-test.sh:16:export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
  bin/dry-run.sh:162:if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  bin/halt-sprawl-adversarial-test.sh:16:export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
  bin/halt-sprawl-test.sh:13:export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
  bin/linear-test.sh:14:export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
  bin/metrics-test.sh:19:export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
  bin/poll-slot-test.sh:13:export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
  bin/poll-slot-test.sh:80:    [[ -n "${LINEAR_STUB_LOG:-}" ]] && printf '%s\n' "$*" >> "$LINEAR_STUB_LOG"
  bin/reconcile-test.sh:22:export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
  bin/run-stage-test.sh:12:export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
  bin/status.sh:93:  if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  bin/status.sh:283:  if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  bin/verdict-adversarial-test.sh:23:export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
  bin/verdict-handler-test.sh:14:export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
  ```
  15 lines across 14 files. Group 1 (Brainstorm § D-004): 11 lines using
  `:-test-mock-key` as a default; rewrite to `:=` (assign-default form).
  Group 2: 4 lines using empty-fallback `:-`; rewrite to single-dash `${VAR-}`.
  Counts match Brainstorm § D-004 and § A-02 exactly.

- **A-02 (verified).** `bin/run-local.sh:75-78` sources `secrets.env`
  with `set -a; source ...; set +a` — the upstream of the bug surface.
  This plan does NOT touch this load path (out per Brainstorm § D-006 and
  per issue § Scope OUT).
  ```bash
  SECRETS_FILE="$HARNESS_CONFIG_DIR/secrets.env"
  if [[ -f "$SECRETS_FILE" ]]; then
    set -a; source "$SECRETS_FILE"; set +a
  fi
  ```

- **A-03 (verified).** `bin/common.sh::compute_pipeline_content_hash`
  (lines 71-95) digests `find $HARNESS_ROOT/bin -type f -name '*.sh'` plus
  `$CONFIG` plus `$HARNESS_ROOT/AGENT_PROMPTS.md`. Edits in this PR all
  fall in that set, so this PR will bump the hash. `bin/poll.sh:75-115`
  auto-clears any halted issue whose `issue-state.json` evidence hash
  differs (removes `pipeline:halted`, posts `<!-- pipeline-decision: resume -->`).
  Side-effect documented in Brainstorm § 4 / E-7. No new label; no new
  marker; benign.

- **A-04 (verified).** `bin/dry-run.sh:19-30` defines a `check "label" command…`
  helper that runs the command, prints ✅/❌, and on failure increments
  `FAIL`. The summary at lines 229-234 exits 1 if `FAIL > 0`. Wiring the
  lint is a single new `check` line — no helper changes needed.

- **A-05 (verified).** `bin/render-prompt.sh:13-23` defines `STAGE_TO_SECTION`
  for nine stages (`brainstorm`, `plan`, `implement`, `ui`, `review`, `qa`,
  `build`, `release`, `retrospective`); `extract_block` dies if a stage
  section's fence count is not exactly 2. The new "Secret-handling
  preamble (ENG-46)" section sits in the `AGENT_PROMPTS.md` preamble
  (between the existing "Stage summary comment format" section ending
  at line 156 and `## 1. Brainstorm Agent` at line 159), outside any
  per-stage fence. The fence-count contract is preserved by construction.
  Existing dry-run check `render-prompt: extracts all 9 stages` (lines 98-108)
  is the smoke for this.

- **A-06 (verified).** `learned-rules/twinning/brainstorm.md` exists and
  defines the rule format used by B-001 (lines 25+):
  `### Rule B-NNN: <title>`, `**Added:**`, `**Expires:**`,
  `**Last verified:**`, `**Source:**`, `**Rule:**`, `**Why:**`,
  `**Evidence:**`. The new entry follows the same shape, appended to
  the file. `learned-rules/harness/` does NOT exist (`ls
  learned-rules/` → only `twinning/`); per Brainstorm § D-005 the rule
  goes into the `twinning/` namespace because it is the only existing
  learned-rules tree and is the highest-read file (retrospective agent's
  primary input).

- **A-07 (verified).** `bin/dispatch.sh::allowed_tools_for` (lines 124-141)
  defines per-stage tool allowlists. This PR does NOT add a new stage,
  does NOT change any allowlist, and the lint is invoked from
  `bin/dry-run.sh` (operator-side smoke), not from a dispatched agent.
  Per Brainstorm § D-002 rejected-alternative discussion, the lint
  intentionally lives outside the per-tick critical path.

- **A-08 (verified).** `.github/workflows/` does NOT currently exist
  (`ls .github/workflows/` → "No such file or directory"). The new
  `.github/workflows/secret-probe-lint.yml` is the first GitHub Actions
  workflow in this repo. Per Brainstorm § D-007 — narrow scope, no
  secrets referenced, no matrix, no caching.

- **A-09 (verified).** Bash test convention from `CLAUDE.md` "How tests work":
  end with sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`,
  set `PIPELINE_DRY_RUN=1` and `LINEAR_API_KEY=test-mock-key` before sourcing,
  override globals post-source. Confirmed pattern at `bin/run-stage.sh` tail
  (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`) and at
  `bin/halt-sprawl-test.sh:1-14` (sets `PIPELINE_DRY_RUN=1`,
  `LINEAR_API_KEY=test-mock-key`, sources `common.sh`). The new
  `bin/secret-probe-lint-test.sh` follows this pattern.

- **A-10 (verified).** Bash semantics for the rewrites: `: "${VAR:=default}"`
  assigns `default` to `VAR` if unset/empty without using the value (POSIX
  2.6.2; bash(1) Parameter Expansion). `${VAR-}` (single-dash, empty
  fallback) returns `default` only when `VAR` is unset, returns `VAR`'s
  value otherwise (including empty). For `[[ -z "${VAR:-}" ]]` and
  `[[ -z "${VAR-}" ]]`, both forms behave identically when the fallback
  is empty: empty-when-unset, empty-when-empty, value-when-non-empty.
  See Brainstorm § A-12, A-13. The Group-2 rewrite is therefore
  semantically a no-op.

### Assumed (validate during implementation)

- **A-11 (assumed).** `git grep -nE '<pat>' -- ':!path'` (pathspec
  exclusion) is supported by git ≥ 1.9 (released 2014). Macs ship a
  newer version; CI runner `ubuntu-latest` is well past. Implementation
  agent runs `git --version` once before relying on the syntax. Mitigation
  if older: `git grep -nE | grep -v '^bin/secret-probe-lint'`.

- **A-12 (assumed).** No agent is concurrently mid-stage on ENG-46 during
  this PR's commit (no other dispatch racing for the worktree). Standard
  expectation; a tick during plan-stage exit re-uses the just-committed
  prompt — desirable, not a regression. Brainstorm § A-16.

## File Structure

```
bin/
  secret-probe-lint.sh                  NEW    (~50 lines: pure shell + git grep, no common.sh source)
  secret-probe-lint-test.sh             NEW    (~120 lines: sentinel + 8 fixture cases — 7 from Brainstorm § 9 plus one negative case for "lint invoked outside a git repo")
  dry-run.sh                            EDIT   (1 new check line + 1 rewrite at L162)
  status.sh                             EDIT   (2 rewrites at L93, L283)
  poll-slot-test.sh                     EDIT   (2 rewrites: L13 group-1, L80 group-2)
  classify-failure-test.sh              EDIT   (1 group-1 rewrite at L14)
  dispatch-test.sh                      EDIT   (1 group-1 rewrite at L16)
  halt-sprawl-test.sh                   EDIT   (1 group-1 rewrite at L13)
  halt-sprawl-adversarial-test.sh       EDIT   (1 group-1 rewrite at L16)
  linear-test.sh                        EDIT   (1 group-1 rewrite at L14)
  metrics-test.sh                       EDIT   (1 group-1 rewrite at L19)
  reconcile-test.sh                     EDIT   (1 group-1 rewrite at L22)
  run-stage-test.sh                     EDIT   (1 group-1 rewrite at L12)
  verdict-adversarial-test.sh           EDIT   (1 group-1 rewrite at L23)
  verdict-handler-test.sh               EDIT   (1 group-1 rewrite at L14)

AGENT_PROMPTS.md                        EDIT   (insert "Secret-handling preamble (ENG-46)" section
                                                between line 156 "Per-stage content slots are listed…"
                                                and line 159 "## 1. Brainstorm Agent"; preamble
                                                position preserves render-prompt's 2-fence-per-stage
                                                contract — A-05)

learned-rules/twinning/brainstorm.md    EDIT   (append "### Rule B-003: Forbid `${SECRET:-FALLBACK}` …"
                                                following the format of the existing B-001/B-002
                                                blocks already in the file — A-06; current file
                                                contains B-001 at line 24 and B-002 at line 42)

.github/
  workflows/
    secret-probe-lint.yml               NEW    (~11 lines, runs lint on every PR push and push to main;
                                                first workflow in this repo — A-08)
```

Total: 2 new bash files in `bin/`, 1 new YAML workflow, 1 new section in
`AGENT_PROMPTS.md`, 1 appended rule block, 1 new `check` line in
`bin/dry-run.sh`, and 15 single-line rewrites across 13 distinct existing
files (11 Group-1 lines + 4 Group-2 lines; the new `check` line is an
addition, not a rewrite, so the rewrite count is 15 not 16).

Files NOT touched (AC6 — "no behavioral change in `bin/run-stage.sh`'s
scope-check or guards"): `bin/run-stage.sh`, `bin/run-local.sh`,
`bin/dispatch.sh`, `bin/scope-check.sh`, `bin/verdict-handler.sh`,
`bin/classify-failure.sh`, `bin/linear.sh`, `bin/poll.sh`,
`bin/reconcile.sh`, `bin/common.sh`. AC6 satisfied by construction.

## Command API Contract

**No new command API.** This is a harness-self plan with no Tauri/Rust
surface. There are no `#[tauri::command]` definitions, no Tauri events,
no TypeScript bindings, and no operator-facing CLI flag changes (`bin/dry-run.sh`'s
argv is unchanged; the new `bin/secret-probe-lint.sh` takes no arguments
and returns POSIX-style exit codes 0/1). Same shape as
`docs/plans/2026-04-28-eng-42-reframe-implement-pr-guard.md` § "Command
API contract" ("No CLI flag changes.").

## Backend Tasks

(Bash harness — no Tauri/Rust backend. Tasks are written for the harness
implementation agent, which operates on `bin/**/*.sh`, `AGENT_PROMPTS.md`,
`learned-rules/**`, and `.github/workflows/**`.)

### Task 1: Create the lint script `bin/secret-probe-lint.sh`

- `depends_on: []`
- `touches: bin/secret-probe-lint.sh (new)`
- [ ] Write `bin/secret-probe-lint.sh` (~50 lines). Header comment names
      ENG-46, links to the brainstorm and to `AGENT_PROMPTS.md "Secret-handling
      preamble (ENG-46)"`, and explicitly notes "this script does NOT source
      `common.sh` — it must run in CI without `TARGET_REPO`" (per Brainstorm
      § D-007 rationale).
- [ ] First action: `git rev-parse --git-dir >/dev/null 2>&1 ||
      { printf 'lint requires a git checkout\n' >&2; exit 2; }`. (Fail
      mode separate from the lint hit case — exit 2 vs. exit 1.)
- [ ] Run two `git grep -nE` invocations against tracked files, with
      pathspec exclusions consolidated in one variable so both regexes
      share the same exclusion list:
      ```bash
      EXCLUDE=(':!bin/secret-probe-lint.sh' ':!bin/secret-probe-lint-test.sh' ':!docs/**' ':!learned-rules/**')
      PAT_KTS='\$\{[A-Z_]*(KEY|TOKEN|SECRET)[A-Z_]*:[\+\-]'
      PAT_PROVIDER='\$\{(ANTHROPIC|GITHUB|LINEAR)[A-Z_]*:[\+\-]'
      ```
      Capture each grep's output (`set +e` around the call; `git grep`
      exits 1 on no matches, 0 on matches — invert in the script).
- [ ] On any hit, emit the three-line per-hit format from Brainstorm § D-001:
      ```
      <path:line:matched-text>
        hint: use ${VAR-} (single-dash, no fallback string) for presence-only checks
        see:  AGENT_PROMPTS.md "Secret-handling preamble (ENG-46)"
      ```
      and `exit 1`. On zero hits across both regexes, `exit 0`.
- [ ] Make the file executable (`chmod +x`). Confirm with
      `bash -n bin/secret-probe-lint.sh` (syntax-check; this is what
      `bin/dry-run.sh:34-36` already runs over `bin/*.sh`).

### Task 2: Create the lint's unit test `bin/secret-probe-lint-test.sh`

- `depends_on: [1]`
- `touches: bin/secret-probe-lint-test.sh (new)`
- [ ] Write `bin/secret-probe-lint-test.sh` (~120 lines) following the
      `CLAUDE.md` "How tests work" pattern: ends with the sentinel
      `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`,
      sets `PIPELINE_DRY_RUN=1` and `LINEAR_API_KEY=test-mock-key`, sources
      `common.sh` (NOTE: the test script DOES source common.sh — only the
      lint itself bypasses it; the test still runs in the harness env).
- [ ] Implement a `setup_git_fixture()` helper that creates a temp dir,
      `git init`s it, writes the requested fixture files, and `git add`s
      them so `git grep` sees them as tracked.
- [ ] Implement eight test cases — seven from Brainstorm § 9 "Test strategy
      preview" plus one negative case for the git-checkout precondition:
      1. Clean fixture (one safe file with `${VAR-}`) → lint exits 0.
      2. Bad `${LINEAR_API_KEY:-leak}` form → lint exits 1; assert stderr
         contains the path:line:match line, the remediation hint, AND the
         `AGENT_PROMPTS.md "Secret-handling preamble (ENG-46)"` pointer.
      3. Bad `${ANTHROPIC_FOO:-x}` form → lint exits 1 (provider regex).
      4. Bad `${KEY:+--auth=$KEY}` form → lint exits 1 (`:[\+\-]`
         superset coverage; this is the security-iter-2 sibling shape).
      5. Bad `${LINEAR_API_KEY:-}` form (empty fallback) → lint exits 1
         (literal AC1 contract — "zero hits", not "zero unsafe hits").
      6. Lint-self-exclusion: place the regex string inside a fixture file
         named `bin/secret-probe-lint.sh` → lint exits 0 (exclusion works).
      7. Prose-exclusion: place the bad pattern inside
         `docs/brainstorms/foo.md` and `learned-rules/twinning/foo.md`
         → lint exits 0 (pathspec excludes prose dirs).
      8. Negative env case — invoke the lint with `cd "$(mktemp -d)"`
         (no git repo) → lint exits 2 (NOT 1); stderr matches
         `lint requires a git checkout`. This validates the env-failure
         vs. lint-hit exit-code distinction from Task 1 step 2.
- [ ] Each case prints `pass: case-N` or `fail: case-N: <reason>` and
      increments `PASS`/`FAIL`. Final exit: `(( FAIL == 0 ))`.

### Task 3: Wire the lint into `bin/dry-run.sh`

- `depends_on: [1]`
- `touches: bin/dry-run.sh::offline-checks-block`
- [ ] Append one new `check` line in the offline checks block (after the
      existing `dispatch.sh: all 9 stages have allowed-tools profiles`
      check ending at line 141 and before the online-checks banner
      `━━━ Online checks ━━━` at line 160). Body:
      ```bash
      check "secret-probe-lint: no \${SECRET:-…} forms in tracked files" \
        bash $HARNESS_ROOT/bin/secret-probe-lint.sh
      ```
- [ ] Also rewrite the existing in-file hit at line 162 from
      `${LINEAR_API_KEY:-}` to `${LINEAR_API_KEY-}` (Group 2 rewrite).
      Validate semantics with the existing context: line 162 is
      `if [[ -z "${LINEAR_API_KEY:-}" ]]; then` — `[[ -z … ]]` with
      empty fallback behaves identically across `:-` and `-` forms (A-10).

### Task 4: Group-1 sweep — rewrite the 11 `${VAR:-test-mock-key}` test defaults to `${VAR:=test-mock-key}`

- `depends_on: []`
- `touches: bin/classify-failure-test.sh:14, bin/dispatch-test.sh:16, bin/halt-sprawl-adversarial-test.sh:16, bin/halt-sprawl-test.sh:13, bin/linear-test.sh:14, bin/metrics-test.sh:19, bin/poll-slot-test.sh:13, bin/reconcile-test.sh:22, bin/run-stage-test.sh:12, bin/verdict-adversarial-test.sh:23, bin/verdict-handler-test.sh:14`
- [ ] At each listed `path:line`, replace
      ```bash
      export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
      ```
      with
      ```bash
      : "${LINEAR_API_KEY:=test-mock-key}"
      export LINEAR_API_KEY
      ```
      The semantic is identical: assign `test-mock-key` if `LINEAR_API_KEY`
      is unset/empty; otherwise leave the existing value (the developer's
      real key in interactive runs); export the var either way (A-10).
- [ ] After all 11 rewrites, run each test file once to confirm pass:
      ```bash
      for f in bin/classify-failure-test.sh bin/dispatch-test.sh \
        bin/halt-sprawl-adversarial-test.sh bin/halt-sprawl-test.sh \
        bin/linear-test.sh bin/metrics-test.sh bin/poll-slot-test.sh \
        bin/reconcile-test.sh bin/run-stage-test.sh \
        bin/verdict-adversarial-test.sh bin/verdict-handler-test.sh; do
        bash "$f" || { printf 'FAIL: %s\n' "$f"; exit 1; }
      done
      ```
      Tests already running in `bin/dry-run.sh` (`run-stage-test`,
      `classify-failure-test`) gate the same paths in the smoke.

### Task 5: Group-2 sweep — rewrite the 3 remaining empty-fallback `${VAR:-}` hits to `${VAR-}`

- `depends_on: [4]`  (Task 4 also touches `bin/poll-slot-test.sh` — at line 13 — so we serialize on that file to avoid a parallel-edit race; Task 3 owns `bin/dry-run.sh:162` so it does not appear in this task's touches)
- `touches: bin/status.sh:93, bin/status.sh:283, bin/poll-slot-test.sh:80`
- [ ] At `bin/status.sh:93` and `bin/status.sh:283`: replace
      ```bash
      if [[ -z "${LINEAR_API_KEY:-}" ]]; then
      ```
      with
      ```bash
      if [[ -z "${LINEAR_API_KEY-}" ]]; then
      ```
      Both occurrences (lines 93 and 283) follow the same pattern.
      (The fourth Group-2 hit at `bin/dry-run.sh:162` is owned by Task 3,
      not this task — Task 3 already adds the new `check` line in the
      same file, and folding the rewrite into Task 3 prevents a
      file-level edit conflict.)
- [ ] At `bin/poll-slot-test.sh:80`: replace
      ```bash
      [[ -n "${LINEAR_STUB_LOG:-}" ]] && printf '%s\n' "$*" >> "$LINEAR_STUB_LOG"
      ```
      with
      ```bash
      [[ -n "${LINEAR_STUB_LOG-}" ]] && printf '%s\n' "$*" >> "$LINEAR_STUB_LOG"
      ```
      `LINEAR_STUB_LOG` is a stub log path, not a secret, but the lint
      regex matches the `LINEAR*` provider prefix; we rewrite anyway
      because the rewrite is purely lexical and avoids an in-tree
      allowlist mechanism (Brainstorm § D-004 Group-3 rationale).

### Task 6: Add the "Secret-handling preamble (ENG-46)" section to `AGENT_PROMPTS.md`

- `depends_on: []`
- `touches: AGENT_PROMPTS.md::preamble`
- [ ] Insert a new section between the end of the "Stage summary comment
      format" section (current line 156, "Per-stage content slots are
      listed in each "Write the stage summary file" step / below…")
      and `## 1. Brainstorm Agent` at line 161 (lines 157-160 are the
      separator block: trailing prose, blank line, `---`, blank line).
      Insert the verbatim
      body specified in Brainstorm § D-003 (header `## Secret-handling
      preamble (ENG-46)`; body explains both `:-` and `:+` halves;
      gives the safe `${VAR-}` form; references the lint).
- [ ] After insertion, run the existing dry-run smoke check
      `render-prompt: extracts all 9 stages` (`bin/dry-run.sh:98-108`)
      to confirm fence counts unchanged (A-05). Also re-run the
      `bash syntax: all $HARNESS_ROOT/bin/*.sh` check.

### Task 7: Append the learned-rule block to `learned-rules/twinning/brainstorm.md`

- `depends_on: []`
- `touches: learned-rules/twinning/brainstorm.md::end-of-file`
- [ ] Append a new rule block following the format established by B-001
      and B-002 already in the file (`### Rule B-NNN: <title>` then
      `**Added:** 2026-04-28`, `**Expires:** 2026-06-27` (60 days),
      `**Last verified:** 2026-04-28`, `**Source:** Surfaced by ENG-45 UI
      stage's pre-flight env probe self-flag (`stage-summary-ui.md` line 17).`,
      `**Rule:**` (the directive — never use `${VAR:-FALLBACK}` or
      `${VAR:+ALT}` against env vars matching `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`;
      use `${VAR-}` instead), `**Why:**` (the bash semantics + leak
      vector), `**Evidence:**` (link to ENG-45 + this brainstorm).
- [ ] Use the next free rule number. Current file contains B-001 (line 24)
      and B-002 (line 42); next free is **B-003**. Implementer should
      still grep the file once before appending and pick `B-(max+1)`
      to defend against concurrent additions.

### Task 8: Add the GitHub Actions workflow `.github/workflows/secret-probe-lint.yml`

- `depends_on: [1]`
- `touches: .github/workflows/secret-probe-lint.yml (new), .github/ (new dir)`
- [ ] Create `.github/` and `.github/workflows/` if absent (A-08:
      neither exists). Verify `mkdir -p .github/workflows`.
- [ ] Write the 11-line workflow per Brainstorm § D-007:
      ```yaml
      name: secret-probe-lint
      on:
        pull_request: {}
        push:
          branches: [main]
      jobs:
        lint:
          runs-on: ubuntu-latest
          steps:
            - uses: actions/checkout@v4
            - run: bash bin/secret-probe-lint.sh
      ```
- [ ] After creation, validate locally with the existing dry-run
      check `YAML syntax: .github/workflows/*.yml` at
      `bin/dry-run.sh:47-55` (which uses `bun -e "import YAML; YAML.parse(...)"`).

### Task 9: Final-tree validation pass

- `depends_on: [1, 2, 3, 4, 5, 6, 7, 8]`
- `touches: (none — verification only)`
- [ ] Run both AC regexes against the working tree:
      ```bash
      git grep -nE '\$\{[A-Z_]*(KEY|TOKEN|SECRET)[A-Z_]*:-' \
        -- ':!docs/**' ':!learned-rules/**' \
        ':!bin/secret-probe-lint.sh' ':!bin/secret-probe-lint-test.sh'
      git grep -nE '\$\{(ANTHROPIC|GITHUB|LINEAR)[A-Z_]*:-' \
        -- ':!docs/**' ':!learned-rules/**' \
        ':!bin/secret-probe-lint.sh' ':!bin/secret-probe-lint-test.sh'
      ```
      Both must return zero hits. If either returns a hit, treat as a
      missed sweep and revisit Task 4 / Task 5.
- [ ] Run `bash bin/dry-run.sh` end-to-end (offline portion). The new
      `secret-probe-lint` check must pass; existing checks must not
      regress.
- [ ] Run `bash bin/secret-probe-lint-test.sh` standalone — all eight
      cases pass.
- [ ] Confirm no edits to: `bin/run-stage.sh`, `bin/scope-check.sh`,
      `bin/dispatch.sh`, `bin/run-local.sh`, `bin/poll.sh`,
      `bin/reconcile.sh`, `bin/classify-failure.sh`, `bin/linear.sh`,
      `bin/verdict-handler.sh`, `bin/common.sh` (`git diff --name-only`
      should not list any of these). AC6 is then proven by construction.

## Frontend Tasks

**None.** This is a harness-self bash plan with no SvelteKit / Tauri /
Rust surface (see Anti-anchoring check note above). The Linear plan-prompt
template assumes a Tauri target; for harness-self issues that section
is empty by design. Same shape as
`docs/plans/2026-04-28-eng-42-reframe-implement-pr-guard.md` (no Frontend
Tasks section); recorded here explicitly to satisfy the template
contract.

## Failure Mode → Test Map

Each row is bound to a concrete test that QA can verify against.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Lint regex misses the surfacing bug shape `${LINEAR_API_KEY:-UNSET}` | Add a fixture file containing the exact bug from ENG-45 | Lint exits 1 with `path:line:match` and the remediation hint | unit | `bin/secret-probe-lint-test.sh::case-2` |
| Lint regex misses the `:+` sibling shape `${KEY:+--auth=$KEY}` | Add a fixture file with the `:+ ALT-references-VAR` form | Lint exits 1 (validates `:[\+\-]` superset coverage) | unit | `bin/secret-probe-lint-test.sh::case-4` |
| Lint regex misses the provider-prefix shape `${ANTHROPIC_FOO:-x}` | Add a fixture file with an `ANTHROPIC*` env var | Lint exits 1 (validates the provider regex covers all three prefixes) | unit | `bin/secret-probe-lint-test.sh::case-3` |
| Lint matches its own regex source (self-recursion) | Place the regex string inside a `bin/secret-probe-lint.sh` fixture file | Lint exits 0 (pathspec self-exclusion works) | unit | `bin/secret-probe-lint-test.sh::case-6` |
| Lint matches markdown prose containing pattern examples (this brainstorm itself) | Place a bad pattern inside `docs/brainstorms/foo.md` and `learned-rules/twinning/foo.md` | Lint exits 0 (pathspec excludes prose dirs) | unit | `bin/secret-probe-lint-test.sh::case-7` |
| Empty-fallback `${VAR:-}` form trips the lint as a literal AC violation | Add a fixture file with `${LINEAR_API_KEY:-}` | Lint exits 1 (literal AC1 contract; safe equivalent is `${VAR-}`) | unit | `bin/secret-probe-lint-test.sh::case-5` |
| Group-1 rewrite changes test default semantics | Run any rewritten test file with `LINEAR_API_KEY` unset and again with set | Both runs pass; the rewritten line behaves identically to the original `${VAR:-test-mock-key}` form | integration | each of the 11 test files in their current entry forms (the existing `bin/dry-run.sh` checks `classify-failure-test`, `run-stage-test`) |
| `AGENT_PROMPTS.md` preamble break the per-stage 2-fence contract | Insert the new section in a way that introduces extra column-0 fences inside any stage body | `bin/render-prompt.sh::extract_block` dies; dry-run `render-prompt: extracts all 9 stages` fails | integration | `bin/dry-run.sh::render-prompt: extracts all 9 stages` (lines 98-108) |
| Lint missing from dry-run smoke (regression after merge) | Remove the `secret-probe-lint` check line from `bin/dry-run.sh` | Dry-run smoke summary shows fewer checks; `bin/dry-run.sh` returns success on a tree with a lint hit | smoke | run `bin/dry-run.sh` end-to-end and grep stdout for `secret-probe-lint:` |
| CI workflow YAML invalid | Malform `.github/workflows/secret-probe-lint.yml` (e.g., bad indentation) | `bin/dry-run.sh::YAML syntax: .github/workflows/*.yml` (lines 47-55) fails | smoke | `bin/dry-run.sh::YAML syntax: .github/workflows/*.yml` |
| Lint script invoked outside a git repo | Run `bin/secret-probe-lint.sh` in `/tmp` | Exits 2 with `lint requires a git checkout`; not exit 1 (so callers can distinguish env failure from lint hit) | unit | `bin/secret-probe-lint-test.sh::case-8` |
| `pipeline_content_hash` bumps and auto-resumes a halted issue (designed side effect) | Merge the PR; on next tick, `bin/poll.sh:75-115` recomputes the hash | Halted issue's `pipeline:halted` is removed; `<!-- pipeline-decision: resume -->` posted; issue advances normally | (no new test) | covered by existing `bin/poll-slot-test.sh` paths |

## Test Strategy

**Unit (`bin/secret-probe-lint-test.sh`).** 8 fixture cases enumerated in
the Failure Mode table. Each builds a temp `git init`'d repo with the
relevant fixtures, invokes the lint, asserts exit code and (for hit
cases) stderr contents. Sentinel-pattern + sourceable-functions per
`CLAUDE.md` "How tests work". Runnable standalone via `bash
bin/secret-probe-lint-test.sh`, returning 0 if all pass.

**Integration (`bin/dry-run.sh`).** The new `secret-probe-lint: …`
`check` line passes against the swept tree; existing checks
(`classify-failure-test`, `run-stage-test`, `render-prompt: extracts
all 9 stages`, `YAML syntax`) continue to pass. The swept-tree pass is
the end-to-end demonstration of AC1/AC2/AC3 (the lint runs with all
exclusions and finds zero hits in production code). The `render-prompt`
extraction check is the regression guard for AC4 (preamble does not
break per-stage fence count).

**Smoke (CI workflow `secret-probe-lint.yml`).** Runs
`bash bin/secret-probe-lint.sh` on every PR push and every push to
`main`. No matrix, no caching, no secrets. Sole gate: lint exit code.
Validates AC3's "machine-runnable on every commit" half (the
`bin/dry-run.sh` integration covers the "every tick"-side equivalent
when an operator runs it).

**Adversarial (covered by unit cases 5, 6, 7, 8).** Four known
false-positive / negative shapes — the empty-fallback safe form (case 5),
the lint self-reference (case 6), the markdown-prose pattern (case 7),
and the no-git-repo invocation (case 8) — each have an explicit unit case
asserting the correct exit code (1 for case 5 by literal AC contract; 0
for cases 6 and 7; 2 for case 8). These are the shapes a future agent
or test author would most likely accidentally mis-trip.

**No new run-stage cases (AC6).** AC6 forbids behavioral changes in
`bin/run-stage.sh`. The existing `bin/run-stage-test.sh` is unchanged
in behavior (only its line-12 `LINEAR_API_KEY` initializer is
rewritten); the file's case count, scope-check coverage, and
agent-contract validator coverage are untouched.

## Persona review (audit trail)

Two-iteration document-review run over feasibility, scope, coherence,
design, and product personas. Headline in the Linear stage-summary
comment; full record below.

### Iteration 1

| Persona      | Verdict | Load-bearing findings |
|---|---|---|
| feasibility  | PASS    | 0 P0. P1: Task 5 `touches:` listed `bin/dry-run.sh:162` despite the body folding that rewrite into Task 3. P1: Tasks 4 and 5 both touch `bin/poll-slot-test.sh` (different lines) without serialization. P2: Task 7 hint "likely B-005" — actual is B-003. P2: insertion offset on `## 1. Brainstorm Agent` (cited 159, actual 161). |
| scope        | PASS    | 0 P0/P1. Three P2 cosmetics on count drift. |
| coherence    | **FAIL** | P0: File Structure said "14 single-line rewrites across 13 files" — actual is 15 rewrites across 13 distinct files (anti-anchoring section had said 15). P1: Task 5 `touches:` overlap with Task 3 narrative. P2: Task 2 enumerated 7 cases but Failure Mode table referenced 8 (including the no-git-repo negative case). |
| design       | PASS    | 0 P0/P1/P2. Test pattern, fence-count contract, common.sh bypass, AC6 verification all confirmed correct. |
| product      | PASS    | 0 P0/P1. Two P2 polish notes. |

**Iteration-1 status:** 4/5 PASS, 1 P0 in coherence. Iterating.

### Iteration 2

Iteration-2 deltas applied to the plan (see commit diff):
- Anti-anchoring + File Structure: rewrite-count corrected from "14" to
  "15"; file-count math spelled out (11 G1 lines / 11 G1 files; 4 G2
  lines / 3 G2 files; 1 overlap on `bin/poll-slot-test.sh`; → 13
  distinct).
- Task 5: `touches:` no longer lists `bin/dry-run.sh:162` (Task 3 owns it);
  `depends_on: [4]` added to serialize on `bin/poll-slot-test.sh`.
- Task 2: case list expanded from 7 to 8 (added the no-git-repo
  negative case, mapped to `bin/secret-probe-lint-test.sh::case-8`
  in the Failure Mode table).
- Task 7: hint corrected to B-003 (next free).
- Task 6 + Task 3: line-number references corrected (AGENT_PROMPTS.md
  `## 1. Brainstorm Agent` is at line 161; offline-checks insertion is
  before banner at line 160).

| Persona      | Verdict | Notes |
|---|---|---|
| feasibility  | PASS    | All iter-1 P1s resolved. Re-verified path:line references; no new errors. |
| coherence    | **FAIL** | P0 still present: anti-anchoring math notation jumped from "4 G2 [lines]" to "11 + 3 distinct − 1 overlap = 13" without disambiguating lines vs. files. |
| scope        | PASS (iter-1, no rerun) | No iter-2 changes to scope surface. |
| design       | PASS (iter-1, no rerun) | No iter-2 changes to design surface. |
| product      | PASS (iter-1, no rerun) | No iter-2 changes to product surface. |

**Iteration-2 status:** 4/5 PASS, 1 P0 in coherence. Iterating to fix
the math-notation issue.

### Iteration 3

Iteration-3 delta: anti-anchoring paragraph rewritten to spell out
line-vs-file disambiguation explicitly ("11 Group-1 lines (one per
file, in 11 test files) plus 4 Group-2 lines (in 3 files: …); 11 + 3
− 1 overlap = 13 distinct files").

| Persona      | Verdict | Notes |
|---|---|---|
| coherence    | PASS    | Math is now coherent across all four sections (anti-anchoring, File Structure summary, Task 4 prose, Task 5 prose). |
| feasibility  | PASS (iter-2, no rerun) | No iter-3 changes to facts surface. |
| scope        | PASS (iter-1, no rerun) | — |
| design       | PASS (iter-1, no rerun) | — |
| product      | PASS (iter-1, no rerun) | — |

**Iteration-3 status: 5/5 PASS, 0 P0 across all personas. Gate passes
cleanly.** Stopping iteration loop.

## Out of scope (reproduced from issue)

Per the issue § Scope OUT, this PR does not:
- Audit prior dispatched-agent logs for past leaks (forward-looking only).
- Rotate `LINEAR_API_KEY` (no exfiltration evidence; agent confined the
  value to local process per ENG-45's self-flag).
- Run external secret scanners (`gh secret-scanning`, trufflehog).
- Re-architect how secrets enter agent context (current `secrets.env`
  load path at `bin/run-local.sh:75-78` stays as-is; the file is
  `0700/0600` mode-restricted by `bin/setup.sh`).
- Extend the regex to non-uppercase or non-`ANTHROPIC|GITHUB|LINEAR`
  provider env vars (follow-up when a new provider's secret enters).
