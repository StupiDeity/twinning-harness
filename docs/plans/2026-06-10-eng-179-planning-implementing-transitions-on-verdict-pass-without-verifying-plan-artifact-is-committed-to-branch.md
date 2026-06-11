---
linear: ENG-179
date: 2026-06-10
topic: Gate planning→implementing on a HEAD-committed plan artifact (close the verdict-pass-without-commit gap)
---

# ENG-179 — Gate planning→implementing on a committed plan artifact

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## 1. Goal

Tighten `bin/run-stage.sh::_validate_plan_contract` so a `planning` dispatch that emits `verdict=pass` but does NOT leave a committed plan `.md`+`.json` pair in branch HEAD halts with `plan-contract-missing` (rc=35) before the orchestrator's verdict_handler can flip `stage:planning → stage:implementing`.

## 2. Assumption Inventory

Every fact below is verified at the cited `path:line` in this worktree (HEAD = ea41d65). Branch-base freshness: `HEAD..origin/main` empty at plan time (origin/main = 72453cb).

### Codebase facts (verified against current HEAD)

- `bin/run-stage.sh::_validate_plan_contract` is defined at lines **1082–1118** with the current signature `_validate_plan_contract() { local ident="$1"; ... }` — verified `bin/run-stage.sh:1082`.
- The fail-open absent-md branch is at lines **1101–1104**:
  ```
  if [[ -z "$plan_md" ]]; then
    log "plan-contract: no plan .md found for $ident matching ${today}-*${ident_lower}-*.md; fail-open"
    return 0
  fi
  ```
  verified `bin/run-stage.sh:1101-1104`.
- The today-only `find` pattern is at line **1098**:
  `plan_md="$(cd "$wt" && find docs/plans -maxdepth 1 -type f -iname "${today}-*${ident_lower}-*.md" 2>/dev/null | sort | head -1)"` — verified `bin/run-stage.sh:1098`.
- The schema-validator tail at lines **1108–1117** calls `bash "$SCRIPT_DIR/plan-schema.sh" validate "$wt/$plan_json" --ident "$ident"` and routes return codes 33/34/35 through `_post_plan_contract_halt` — verified `bin/run-stage.sh:1108-1117`.
- `_post_plan_contract_halt` is defined at lines **1123–1130**; it sanitises raw text with `local safe="${raw//<!--/<\\!--}"` (line **1125**) and posts via `bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true` (line **1129**) — verified `bin/run-stage.sh:1123-1130`.
- The caller block that runs `_validate_plan_contract` after dispatch is at lines **1921–1937** (`case "$stage" in planning) ... esac`), and routes `_plan_rc != 0` through `classify_failure "$ident" "$stage" "skip-until-human-acts" "plan-contract-invalid: $(failure_outcome_for_exit "$_plan_rc")" "$_plan_rc"; exit "$_plan_rc"` — verified `bin/run-stage.sh:1921-1937`.
- `bin/common.sh::failure_outcome_for_exit` line **334** maps exit code `35` to `plan-contract-missing` — verified `bin/common.sh:334`.
- The partition-sweep + commit lives in `bin/run-local.sh::worker_run` lines **226–317** and runs only AFTER `run-stage.sh` returns rc=0 (the `if [[ $rc -ne 0 ]]; then ... return $rc; fi` gate at line **224**) — verified `bin/run-local.sh:205-207, 224, 226-317`.
- `verdict_handler` is called from `bin/run-stage.sh::main` at line **2019**, AFTER `_validate_plan_contract` runs — verified `bin/run-stage.sh:2019`.
- `find_fresh_verdict` is defined at `bin/verdict-handler.sh:156` and `apply_transition` at `bin/verdict-handler.sh:309` — verified `bin/verdict-handler.sh:156, 309`.
- `bin/scope-check.sh::find_canonical_plan` (lines **142–156**) is the downstream worktree-find that exits 2 on absent plan (lines **286–287**) — verified `bin/scope-check.sh:142-156, 286-287`. Defence-in-depth backstop; intentionally NOT touched by this plan.
- AGENT_PROMPTS.md §2 step 4 instructs the planning agent to commit the `.md`+`.json` pair on the feature branch with message `chore(pipeline): plan for {issue_id}` (`AGENT_PROMPTS.md:627-633`) — verified.

### Existing test fixtures (verified)

- `bin/run-stage-test.sh:4388-4596` houses the ENG-122 plan-contract integration cases: INT1 (122-K), INT2 (122-L), INT3 (122-M), INT4 (122-N — structural lint of the call site), INT5 (122-O — injection sanitisation), INT-P (122-P — worktree missing), INT-Q (122-Q — plan `.md` missing → fail-open).
- INT1, INT2, INT3, INT5 all set up fixtures via `mkdir -p "$(issue_dir <ident>)/worktree/docs/plans" && printf 'stub plan\n' > "...${_ENG122_TODAY}-...-test.md" && _eng122_write_valid_json "...test.json" "ENG-..."`. None call `git init`; the existing validator uses `find docs/plans`, not `git ls-tree HEAD`.
- INT-P at lines **4566–4578** never creates a worktree dir → fail-open path is preserved by this plan (worktree-missing guard at `bin/run-stage.sh:1087` stays).
- INT-Q at lines **4583–4596** asserts `plan .md missing → fail-open (rc=0)` — this assertion is the bug; it flips under this plan to `→ rc=35`.
- A working `git init` recipe lives at lines **3116–3120** in the same file (Case 71-1, ENG-T7): `( cd "$WT" && git init --quiet -b main && git config user.email t@t && git config user.name t && git commit --quiet --allow-empty -m init )`. Tasks below reuse it.
- `bin/plan-schema-test.sh` and `bin/plan-schema-adversarial-test.sh` mention `_validate_plan_contract` only in comments (`bin/plan-schema-test.sh:10`, `bin/plan-schema-adversarial-test.sh:16`) — no behavioural coupling to the validator's worktree-find vs. HEAD-tree shape.

### Test-gate closure sweep (removal side)

Tokens this plan removes from production code:
- The `find docs/plans -maxdepth 1 -type f -iname "${today}-*${ident_lower}-*.md"` invocation in `bin/run-stage.sh:1098`.
- The fail-open log `"plan-contract: no plan .md found for $ident matching ${today}-*${ident_lower}-*.md; fail-open"` at line 1102.
- The bare `return 0` at line 1103.

Grep across all `bin/*-test.sh` for the literal pattern `fail-open` + the today-only glob shape:
- Only `bin/run-stage-test.sh` contains assertions on the fail-open log line and the rc=0 outcome — already listed in File Structure (Task 3 flips INT-Q + Task 4 retrofits INT1/INT2/INT3/INT5).
- `bin/plan-schema-test.sh` / `bin/plan-schema-adversarial-test.sh` only mention `_validate_plan_contract` in module docstrings; no token coupling — no File Structure addition needed.
- `bin/vocabulary-cleanliness-test.sh` references `plan-contract-*` defect tokens by name; this plan preserves all four (missing/malformed/incomplete + `plan-contract-invalid` halt-marker reason) — no breakage.

### Test-gate closure sweep (add side)

No new files are added under any gate-runnable glob (no new `bin/*-test.sh`; this plan extends `bin/run-stage-test.sh` in place). Therefore `learned-rules/harness/project-profile.md` does NOT need to appear in File Structure — verified by reading `learned-rules/harness/project-profile.md:17` (the Test command) — the existing line already runs `bin/run-stage-test.sh` and that's the only test file this plan touches.

### Branch-base freshness

`git log --oneline HEAD..origin/main` empty at plan time (origin/main = `72453cb`); HEAD = `ea41d65 chore(pipeline): brainstorming for ENG-179`. No Task 0 rebase required.

## 3. File Structure

Modify (production):
- `bin/run-stage.sh` — `_validate_plan_contract` (~L1082-1118): replace the worktree `find` with a `git ls-tree HEAD` query; remove the absent-md fail-open; loosen the basename glob to drop the today-only prefix; also gate the sibling `.json` lookup through HEAD.

Modify (tests):
- `bin/run-stage-test.sh` (~L4388-4596):
  - Replace **INT-Q** (~L4580-4596) to assert `plan .md missing in HEAD → rc=35 + halt comment carries plan-contract-missing`.
  - Retrofit **INT1 (122-K)**, **INT2 (122-L)**, **INT3 (122-M)**, **INT5 (122-O)** fixtures (~L4426-4561): each now `git init`s the worktree and commits the plan files before invoking `_validate_plan_contract`, otherwise the tightened HEAD-tree query would no-op them.
  - Add **INT-R (ENG-179R)** — committed pair → rc=0 (regression guard, mirrors AC 1 happy path).
  - Add **INT-T (ENG-179T)** — written-but-uncommitted → rc=35 (AC 3 / criterion (c)).
  - Add **INT-U (ENG-179U)** — committed plan with *yesterday's* date prefix → rc=0 (cross-midnight resume guard).

Modify (docs):
- `CLAUDE.md` (~L772-790): add a row to the "Failure-mode quick reference" table for the `plan-contract-missing` halt, contrasting it explicitly with the downstream `scope-check rc=2` symptom (per brainstorm AC 9).

No new files. No production-code additions other than the two in-function edits in `_validate_plan_contract`.

## 4. API Contract

No new API surface. The harness has no FE↔BE contract; the only "API" affected is the internal validator return-code taxonomy in `bin/common.sh::failure_outcome_for_exit`, and exit code 35 (`plan-contract-missing`) is already defined and unchanged — this plan only widens the set of conditions that route through it.

## 5. Backend Tasks

### Task 1: Tighten `_validate_plan_contract` to query branch HEAD and halt on absent committed plan

- `depends_on: []`
- `touches: bin/run-stage.sh::_validate_plan_contract`

- [ ] **Step 1:** In `bin/run-stage.sh`, locate the `_validate_plan_contract` function. Use the content anchor of the leading docstring:
  ```bash
  # ENG-122: plan-contract validator. Runs after dispatch for stage=planning only.
  ```
  (above the `_validate_plan_contract()` opener at line ~1082).

- [ ] **Step 2:** Replace the lines from the `# Trailing hyphen after ident_lower prevents eng-12 ...` comment (currently `bin/run-stage.sh:1094`) DOWN TO (but NOT including) the `plan_json="${plan_md%.md}.json"` line (currently `bin/run-stage.sh:1106`) with the block below. The content anchor for the END of the replaced region is the line `plan_json="${plan_md%.md}.json"` (preserved intact below the new block):

  ```bash
  # ENG-179: gate planning→implementing on a HEAD-COMMITTED plan artifact.
  # Worktree `find` (pre-ENG-179) saw dirty-but-uncommitted files; that
  # let a session-limit death post verdict=pass + write files into the
  # worktree but die before commit, and the transition would still fire
  # because the orchestrator's partition-sweep runs AFTER verdict_handler.
  # `git ls-tree -r HEAD` returns only committed paths, matching the
  # issue's acceptance criterion ("present in the branch's commits, not
  # just the dirty worktree"). Agent self-commit (AGENT_PROMPTS.md §2
  # step 4) is now LOAD-BEARING for this gate's correctness; if that
  # contract is ever softened, this gate must be reordered behind the
  # partition-sweep commit (a structural change, not a softening here).
  #
  # Trailing hyphen after ident_lower preserves the existing eng-12 vs
  # eng-122 boundary guard. The today-only date prefix was DROPPED
  # (vs pre-ENG-179) so a cross-midnight planning re-dispatch on
  # yesterday's committed plan still satisfies the gate; the schema
  # validator's `issue_id` field check (^ENG-[0-9]+$ matched against
  # --ident) re-asserts the artifact belongs to this ident, so the
  # looser filename pattern cannot let a foreign plan satisfy the gate.
  plan_md="$(cd "$wt" && git ls-tree --name-only -r HEAD -- docs/plans/ 2>/dev/null \
    | grep -iE "^docs/plans/[0-9]{4}-[0-9]{2}-[0-9]{2}-.*${ident_lower}-.*\.md$" \
    | sort | tail -1)"
  if [[ -z "$plan_md" ]]; then
    _post_plan_contract_halt "$ident" "plan-contract-missing" \
      "$(printf 'No committed plan artifact at docs/plans/<date>-*-%s-*.md in branch HEAD. The planning agent emitted verdict=pass but did not commit the canonical plan .md (and sibling .json).\n\nCommon cause: claude -p session-limit / out_of_credits death after marker emission but before file commit (operator memory: session-limit-false-halts). Inspect the dispatch log at $PROJECT_STATE_DIR/<slug>/logs/%s-planning-*.log to confirm before re-running.\n\nResume: bash bin/pipeline.sh decide %s --action continue' "$ident_lower" "$ident" "$ident")"
    return 35
  fi
  ```

  Rationale for each piece:
  - `cd "$wt" && git ls-tree --name-only -r HEAD -- docs/plans/`: queries HEAD's tree, returns committed paths only. `-r` recurses; `--name-only` strips the mode/SHA columns; the `--` separator + `docs/plans/` argument scopes the listing.
  - `grep -iE "^docs/plans/[0-9]{4}-[0-9]{2}-[0-9]{2}-.*${ident_lower}-.*\.md$"`: ISO-date prefix + ident hyphen guard (eng-12 vs eng-122) + `.md` suffix. `^/$` anchors prevent substring drift.
  - `sort | tail -1`: ISO-date sort is lexicographic for `YYYY-MM-DD`; tail -1 picks the latest plan if multiple exist (e.g., abandoned-then-redrafted).
  - `_post_plan_contract_halt`: identical sanitisation pattern as the existing schema-error branches (`<!--` → `<\!--`), so the diagnostic body is injection-safe by reuse.
  - `return 35`: matches `failure_outcome_for_exit 35 → plan-contract-missing` (`bin/common.sh:334`), so `classify_failure` (called at `bin/run-stage.sh:1931`) routes through `skip-until-human-acts` policy and applies `pipeline:halted` per ENG-56.

- [ ] **Step 3:** Just BELOW the unchanged line `plan_json="${plan_md%.md}.json"` (content anchor; do NOT relocate it), add a HEAD-tree presence check for the sibling JSON BEFORE the existing `schema_out="$(bash "$SCRIPT_DIR/plan-schema.sh" validate "$wt/$plan_json" ...` invocation. Insert this block AFTER the `plan_json="${plan_md%.md}.json"` line and BEFORE the `schema_out="$(...` line:

  ```bash
  # ENG-179: also gate the sibling .json on HEAD. plan-schema.sh's
  # rc=35 (missing-file) reads the worktree filesystem and would accept
  # a written-but-uncommitted .json; querying HEAD here closes that
  # gap with the same shape used for the .md above.
  if ! (cd "$wt" && git ls-tree --name-only -r HEAD -- "$plan_json" 2>/dev/null | grep -qxF "$plan_json"); then
    _post_plan_contract_halt "$ident" "plan-contract-missing" \
      "$(printf 'Sibling plan JSON not committed to HEAD at %s. The .md is in HEAD but the .json is not — schema validation cannot proceed.\n\nResume: bash bin/pipeline.sh decide %s --action continue' "$plan_json" "$ident")"
    return 35
  fi
  ```

  Rationale: the existing `plan-schema.sh validate` would either return rc=35 (file missing) or pass against a worktree file that's not in HEAD. The HEAD presence guard makes the gate's substrate uniform (both `.md` and `.json` must be in HEAD).

- [ ] **Step 4:** Leave the schema-validation tail (`schema_out="$(bash "$SCRIPT_DIR/plan-schema.sh" validate "$wt/$plan_json" --ident "$ident")" || schema_rc=$?` and the `case "$schema_rc"` block, ~L1108–1117) UNCHANGED. The existing rc=33/34/35 routes through `_post_plan_contract_halt` already; this plan reuses them verbatim.

- [ ] **Step 5:** Syntax-check the edit:
  ```bash
  bash -n bin/run-stage.sh
  ```
  Expect exit 0.

### Task 2: Add INT-R (committed pair → rc=0) regression test

- `depends_on: [1]`
- `touches: bin/run-stage-test.sh`

- [ ] **Step 1:** In `bin/run-stage-test.sh`, locate the existing INT-Q block (content anchor: the comment line `# INT-Q (case 122-Q): worktree exists but no plan .md → fail-open (rc=0).` at ~L4580). Insert the new INT-R block immediately AFTER the existing INT-Q closing brace `fi` (one line above the `# ─── ENG-119: _validate_review_payload integration tests` header at ~L4598). The new block uses the proven `git init` recipe from `bin/run-stage-test.sh:3116-3120`:

  ```bash
  # ENG-179 INT-R: committed .md + .json pair in HEAD → rc=0, no halt.
  # Pre-ENG-179 the same shape would have passed via worktree-find;
  # post-ENG-179 it must still pass via git ls-tree HEAD. Regression
  # guard for AC 1 (happy path: committed artifact → transitions).
  printf '\n--- ENG-179 INT-R: committed pair in HEAD → rc=0 ---\n'
  reset_capture
  ENG179R_WT="$(issue_dir ENG-179R)/worktree"
  rm -rf "$ENG179R_WT"
  mkdir -p "$ENG179R_WT/docs/plans"
  ( cd "$ENG179R_WT" \
    && git init --quiet -b main \
    && git config user.email t@t \
    && git config user.name t \
    && git commit --quiet --allow-empty -m init ) >/dev/null 2>&1
  printf 'stub plan\n' \
    > "$ENG179R_WT/docs/plans/${_ENG122_TODAY}-eng-179r-test.md"
  _eng122_write_valid_json \
    "$ENG179R_WT/docs/plans/${_ENG122_TODAY}-eng-179r-test.json" "ENG-179R"
  ( cd "$ENG179R_WT" \
    && git add docs/plans \
    && git commit --quiet -m "plan for ENG-179R" ) >/dev/null 2>&1
  _eng179r_rc=0
  _validate_plan_contract ENG-179R 2>/dev/null || _eng179r_rc=$?
  (( _eng179r_rc == 0 )) \
    && pass_at "ENG-179 INT-R: committed pair → rc=0" \
    || fail_at "ENG-179 INT-R: committed pair" "expected rc=0, got rc=$_eng179r_rc"
  if [[ ! -s "$CAPTURE_FILE" ]]; then
    pass_at "ENG-179 INT-R: no halt comment on clean path"
  else
    fail_at "ENG-179 INT-R: unexpected halt comment" "capture=$(cat "$CAPTURE_FILE")"
  fi
  ```

- [ ] **Step 2:** Run only this test file to confirm INT-R is wired:
  ```bash
  bash bin/run-stage-test.sh 2>&1 | grep -E 'INT-R|FAIL'
  ```
  Expect: two `✓ ENG-179 INT-R:` lines, no `FAIL`.

### Task 3: Flip INT-Q from fail-open to strict-halt

- `depends_on: [1]`
- `touches: bin/run-stage-test.sh`

- [ ] **Step 1:** Locate the existing INT-Q block in `bin/run-stage-test.sh`. Content anchors: the comment line `# INT-Q (case 122-Q): worktree exists but no plan .md → fail-open (rc=0).` (~L4580) at the start, and the closing `fi` (~L4596) at the end (immediately before the `# ─── ENG-119: _validate_review_payload integration tests` header).

- [ ] **Step 2:** Replace the entire INT-Q block (from the leading comment through the closing `fi`) with the strict-halt assertions below. Note the intentional behaviour-change marker per brainstorm §Testing point 5:

  ```bash
  # INT-Q (case 122-Q, ENG-179 rewrite): worktree has an initialised git repo
  # but HEAD has no plan .md → rc=35 + halt comment with plan-contract-missing.
  # ENG-179: was fail-open (rc=0); now strict-halt. Pre-ENG-179 the validator
  # used worktree-find and treated absence as "agent-contract validator
  # handles it upstream"; the validator never actually fired in that path,
  # which is the ENG-125 (2026-06-10) defect this case now guards.
  printf '\n--- ENG-179 INT-Q (122-Q): plan .md missing in HEAD → rc=35 ---\n'
  reset_capture
  ENG122Q_WT="$(issue_dir ENG-122-NOMD)/worktree"
  rm -rf "$ENG122Q_WT"
  mkdir -p "$ENG122Q_WT/docs/plans"
  ( cd "$ENG122Q_WT" \
    && git init --quiet -b main \
    && git config user.email t@t \
    && git config user.name t \
    && git commit --quiet --allow-empty -m init ) >/dev/null 2>&1
  _eng122q_rc=0
  _validate_plan_contract ENG-122-NOMD 2>/dev/null || _eng122q_rc=$?
  (( _eng122q_rc == 35 )) \
    && pass_at "ENG-179 INT-Q: plan .md missing in HEAD → rc=35" \
    || fail_at "ENG-179 INT-Q: plan .md missing in HEAD" "expected rc=35, got rc=$_eng122q_rc"
  if grep -qF '<!-- pipeline: verdict result=halt reason=plan-contract-invalid -->' "$CAPTURE_FILE"; then
    pass_at "ENG-179 INT-Q: halt comment carries plan-contract-invalid marker"
  else
    fail_at "ENG-179 INT-Q: plan-contract-invalid marker absent" \
      "capture=$(cat "$CAPTURE_FILE")"
  fi
  if grep -qF 'Defect: plan-contract-missing' "$CAPTURE_FILE"; then
    pass_at "ENG-179 INT-Q: halt comment carries Defect: plan-contract-missing"
  else
    fail_at "ENG-179 INT-Q: Defect: plan-contract-missing absent" \
      "capture=$(cat "$CAPTURE_FILE")"
  fi
  ```

- [ ] **Step 3:** Run only this test file to confirm INT-Q is updated:
  ```bash
  bash bin/run-stage-test.sh 2>&1 | grep -E 'INT-Q|FAIL'
  ```
  Expect: three `✓ ENG-179 INT-Q:` lines, no `FAIL`.

### Task 4: Add INT-T (written-but-uncommitted → rc=35) — the discriminating test

- `depends_on: [1]`
- `touches: bin/run-stage-test.sh`

- [ ] **Step 1:** Insert this new test block immediately AFTER the INT-Q block (which now ends at the closing `fi` of the `Defect: plan-contract-missing absent` check from Task 3) and BEFORE the `# ─── ENG-119: _validate_review_payload integration tests` header at ~L4598. This case is the structural justification for the HEAD-tree switch — a worktree-`find` would still pass this fixture; HEAD-`ls-tree` must reject it.

  ```bash
  # ENG-179 INT-T: plan .md + .json written to worktree but NOT git-added
  # → rc=35. Distinguishes HEAD-tree gate from the pre-ENG-179 worktree-find;
  # a `find docs/plans` would see the .md on disk and pass. The HEAD-tree
  # query must reject. This is the AC 3 criterion (c) test.
  printf '\n--- ENG-179 INT-T: written-but-uncommitted → rc=35 ---\n'
  reset_capture
  ENG179T_WT="$(issue_dir ENG-179T)/worktree"
  rm -rf "$ENG179T_WT"
  mkdir -p "$ENG179T_WT/docs/plans"
  ( cd "$ENG179T_WT" \
    && git init --quiet -b main \
    && git config user.email t@t \
    && git config user.name t \
    && git commit --quiet --allow-empty -m init ) >/dev/null 2>&1
  printf 'stub plan (uncommitted)\n' \
    > "$ENG179T_WT/docs/plans/${_ENG122_TODAY}-eng-179t-test.md"
  _eng122_write_valid_json \
    "$ENG179T_WT/docs/plans/${_ENG122_TODAY}-eng-179t-test.json" "ENG-179T"
  # NB: deliberately NO `git add` / `git commit` here — files exist on disk
  # but not in HEAD; the whole point of this case.
  _eng179t_rc=0
  _validate_plan_contract ENG-179T 2>/dev/null || _eng179t_rc=$?
  (( _eng179t_rc == 35 )) \
    && pass_at "ENG-179 INT-T: written-but-uncommitted → rc=35" \
    || fail_at "ENG-179 INT-T: written-but-uncommitted" \
       "expected rc=35, got rc=$_eng179t_rc (worktree-find would have passed; HEAD-tree must reject)"
  if grep -qF 'Defect: plan-contract-missing' "$CAPTURE_FILE"; then
    pass_at "ENG-179 INT-T: halt comment carries Defect: plan-contract-missing"
  else
    fail_at "ENG-179 INT-T: Defect: plan-contract-missing absent" \
      "capture=$(cat "$CAPTURE_FILE")"
  fi
  ```

- [ ] **Step 2:** Run only this test:
  ```bash
  bash bin/run-stage-test.sh 2>&1 | grep -E 'INT-T|FAIL'
  ```
  Expect: two `✓ ENG-179 INT-T:` lines, no `FAIL`.

### Task 5: Add INT-U (cross-midnight resume → rc=0) guard

- `depends_on: [1]`
- `touches: bin/run-stage-test.sh`

- [ ] **Step 1:** Insert this block immediately AFTER the INT-T block from Task 4 (content anchor: the closing `fi` of INT-T's `Defect: plan-contract-missing absent` check) and BEFORE the `# ─── ENG-119` header. The yesterday-date computation uses macOS-compatible `date` flags per CLAUDE.md ("Bash 3.2+, macOS-compatible") and matches the existing pattern at `bin/run-stage-test.sh:4424` for "today":

  ```bash
  # ENG-179 INT-U: committed plan whose date prefix is YESTERDAY (cross-
  # midnight planning re-dispatch) → rc=0. Pre-ENG-179 the today-only
  # ${today}-*${ident_lower}-*.md glob was the justification for the
  # absent-md fail-open; ENG-179 drops the today anchor and asserts only
  # an ISO-date prefix + ident. Regression guard for that loosening.
  printf '\n--- ENG-179 INT-U: cross-midnight resume → rc=0 ---\n'
  reset_capture
  ENG179U_WT="$(issue_dir ENG-179U)/worktree"
  rm -rf "$ENG179U_WT"
  mkdir -p "$ENG179U_WT/docs/plans"
  ( cd "$ENG179U_WT" \
    && git init --quiet -b main \
    && git config user.email t@t \
    && git config user.name t \
    && git commit --quiet --allow-empty -m init ) >/dev/null 2>&1
  # macOS-compatible yesterday date. -v-1d is BSD/macOS; coreutils `date`
  # on Linux also accepts -d "yesterday". Per CLAUDE.md the harness runs
  # on macOS (Bash 3.2), so the -v form is canonical.
  _ENG179U_YESTERDAY="$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u -d "yesterday" +%Y-%m-%d)"
  printf 'stub plan (yesterday)\n' \
    > "$ENG179U_WT/docs/plans/${_ENG179U_YESTERDAY}-eng-179u-test.md"
  _eng122_write_valid_json \
    "$ENG179U_WT/docs/plans/${_ENG179U_YESTERDAY}-eng-179u-test.json" "ENG-179U"
  ( cd "$ENG179U_WT" \
    && git add docs/plans \
    && git commit --quiet -m "plan for ENG-179U (yesterday)" ) >/dev/null 2>&1
  _eng179u_rc=0
  _validate_plan_contract ENG-179U 2>/dev/null || _eng179u_rc=$?
  (( _eng179u_rc == 0 )) \
    && pass_at "ENG-179 INT-U: cross-midnight committed plan → rc=0" \
    || fail_at "ENG-179 INT-U: cross-midnight committed plan" \
       "expected rc=0, got rc=$_eng179u_rc (loose date pattern should accept yesterday)"
  if [[ ! -s "$CAPTURE_FILE" ]]; then
    pass_at "ENG-179 INT-U: no halt comment on cross-midnight clean path"
  else
    fail_at "ENG-179 INT-U: unexpected halt comment" "capture=$(cat "$CAPTURE_FILE")"
  fi
  ```

- [ ] **Step 2:** Run only this test:
  ```bash
  bash bin/run-stage-test.sh 2>&1 | grep -E 'INT-U|FAIL'
  ```
  Expect: two `✓ ENG-179 INT-U:` lines, no `FAIL`.

### Task 6: Retrofit existing INT1/INT2/INT3/INT5 fixtures to commit their plan files

- `depends_on: [1]`
- `touches: bin/run-stage-test.sh`

The pre-ENG-179 INT1 (`bin/run-stage-test.sh:4426-4445`), INT2 (~L4447-4470), INT3 (~L4472-4497), and INT5 (~L4525-4561) fixtures write plan files into the worktree filesystem only. Post-Task-1 the validator queries `git ls-tree HEAD`, so without `git init && git add && git commit` they all halt with `plan-contract-missing` — mechanical fixture update, not a semantic change. INT4 (122-N, the structural lint at L4499-4523) does not touch the filesystem and stays as-is. INT-P (122-P, worktree missing at L4566-4578) tests the no-worktree branch which is preserved (line 1087 fail-open is unchanged).

- [ ] **Step 1:** For INT1 (122-K) — content anchor: the comment line `# INT1 (case 122-K): valid .md + sibling .json → rc=0, no halt comment.` followed by the line `reset_capture`. Replace the setup block (currently `mkdir -p "$(issue_dir ENG-12201)/worktree/docs/plans"` then the two file writes) with this expanded form that adds `git init` + `git add` + `git commit`:

  Find:
  ```bash
  reset_capture
  mkdir -p "$(issue_dir ENG-12201)/worktree/docs/plans"
  printf 'stub plan\n' \
    > "$(issue_dir ENG-12201)/worktree/docs/plans/${_ENG122_TODAY}-eng-12201-test.md"
  _eng122_write_valid_json \
    "$(issue_dir ENG-12201)/worktree/docs/plans/${_ENG122_TODAY}-eng-12201-test.json" "ENG-12201"
  ```

  Replace with:
  ```bash
  reset_capture
  ENG12201_WT="$(issue_dir ENG-12201)/worktree"
  rm -rf "$ENG12201_WT"
  mkdir -p "$ENG12201_WT/docs/plans"
  ( cd "$ENG12201_WT" \
    && git init --quiet -b main \
    && git config user.email t@t \
    && git config user.name t \
    && git commit --quiet --allow-empty -m init ) >/dev/null 2>&1
  printf 'stub plan\n' \
    > "$ENG12201_WT/docs/plans/${_ENG122_TODAY}-eng-12201-test.md"
  _eng122_write_valid_json \
    "$ENG12201_WT/docs/plans/${_ENG122_TODAY}-eng-12201-test.json" "ENG-12201"
  ( cd "$ENG12201_WT" \
    && git add docs/plans \
    && git commit --quiet -m "plan for ENG-12201" ) >/dev/null 2>&1
  ```

- [ ] **Step 2:** For INT2 (122-L) — content anchor: the comment line `# INT2 (case 122-L): .md present, no sibling .json → rc=35, halt comment` followed by `reset_capture`. Replace the setup analogously. INT2 deliberately writes the `.md` but NOT the `.json`; preserve that — but the `.md` MUST be committed so the HEAD-tree query finds it and routes through the schema-validator tail (which will report the missing `.json`).

  Find:
  ```bash
  reset_capture
  mkdir -p "$(issue_dir ENG-122L)/worktree/docs/plans"
  printf 'stub plan\n' \
    > "$(issue_dir ENG-122L)/worktree/docs/plans/${_ENG122_TODAY}-eng-122l-test.md"
  ```

  Replace with:
  ```bash
  reset_capture
  ENG122L_WT="$(issue_dir ENG-122L)/worktree"
  rm -rf "$ENG122L_WT"
  mkdir -p "$ENG122L_WT/docs/plans"
  ( cd "$ENG122L_WT" \
    && git init --quiet -b main \
    && git config user.email t@t \
    && git config user.name t \
    && git commit --quiet --allow-empty -m init ) >/dev/null 2>&1
  printf 'stub plan\n' \
    > "$ENG122L_WT/docs/plans/${_ENG122_TODAY}-eng-122l-test.md"
  ( cd "$ENG122L_WT" \
    && git add docs/plans/${_ENG122_TODAY}-eng-122l-test.md \
    && git commit --quiet -m "plan .md only for ENG-122L (sibling json deliberately missing)" ) >/dev/null 2>&1
  ```

  Note: INT2's halt path is now driven by Task 1's Step 3 new check (sibling `.json` not in HEAD) rather than by `plan-schema.sh`'s missing-file rc=35. The halt-comment assertions in INT2 (line ~L4458 onward asserting `plan-contract-invalid` marker + `Defect: plan-contract-missing`) remain correct because both code paths use the same defect token.

- [ ] **Step 3:** For INT3 (122-M) — content anchor: the comment line `# INT3 (case 122-M): .md present, sibling .json malformed`. INT3 writes both a `.md` and a malformed `.json` (`{,}`). Both must be committed so the HEAD-tree query routes through `plan-schema.sh validate`, which then fails parse with rc=33.

  Find:
  ```bash
  reset_capture
  mkdir -p "$(issue_dir ENG-122M)/worktree/docs/plans"
  printf 'stub plan\n' \
    > "$(issue_dir ENG-122M)/worktree/docs/plans/${_ENG122_TODAY}-eng-122m-test.md"
  printf '{,}\n' \
    > "$(issue_dir ENG-122M)/worktree/docs/plans/${_ENG122_TODAY}-eng-122m-test.json"
  ```

  Replace with:
  ```bash
  reset_capture
  ENG122M_WT="$(issue_dir ENG-122M)/worktree"
  rm -rf "$ENG122M_WT"
  mkdir -p "$ENG122M_WT/docs/plans"
  ( cd "$ENG122M_WT" \
    && git init --quiet -b main \
    && git config user.email t@t \
    && git config user.name t \
    && git commit --quiet --allow-empty -m init ) >/dev/null 2>&1
  printf 'stub plan\n' \
    > "$ENG122M_WT/docs/plans/${_ENG122_TODAY}-eng-122m-test.md"
  printf '{,}\n' \
    > "$ENG122M_WT/docs/plans/${_ENG122_TODAY}-eng-122m-test.json"
  ( cd "$ENG122M_WT" \
    && git add docs/plans \
    && git commit --quiet -m "plan for ENG-122M (malformed json)" ) >/dev/null 2>&1
  ```

- [ ] **Step 4:** For INT5 (122-O) — content anchor: the comment line `# INT5 (case 122-O): injection sanitization`. The injection fixture writes an `.md` and an injected `.json`; both must be committed for the HEAD-tree query to route through `plan-schema.sh`, which then rejects the injected `issue_id` and triggers the sanitisation path.

  Find:
  ```bash
  reset_capture
  mkdir -p "$(issue_dir ENG-122O)/worktree/docs/plans"
  printf 'stub plan\n' \
    > "$(issue_dir ENG-122O)/worktree/docs/plans/${_ENG122_TODAY}-eng-122o-test.md"
  cat > "$(issue_dir ENG-122O)/worktree/docs/plans/${_ENG122_TODAY}-eng-122o-test.json" <<'INJEOF'
  ```

  Replace with:
  ```bash
  reset_capture
  ENG122O_WT="$(issue_dir ENG-122O)/worktree"
  rm -rf "$ENG122O_WT"
  mkdir -p "$ENG122O_WT/docs/plans"
  ( cd "$ENG122O_WT" \
    && git init --quiet -b main \
    && git config user.email t@t \
    && git config user.name t \
    && git commit --quiet --allow-empty -m init ) >/dev/null 2>&1
  printf 'stub plan\n' \
    > "$ENG122O_WT/docs/plans/${_ENG122_TODAY}-eng-122o-test.md"
  cat > "$ENG122O_WT/docs/plans/${_ENG122_TODAY}-eng-122o-test.json" <<'INJEOF'
  ```

  (Leave the `INJEOF` heredoc body and closing tag untouched.) Then, IMMEDIATELY AFTER the closing `INJEOF` line (content anchor: the literal `INJEOF` on its own line), insert the `git add` + `git commit` pair:

  ```bash
  ( cd "$ENG122O_WT" \
    && git add docs/plans \
    && git commit --quiet -m "plan for ENG-122O (injected json)" ) >/dev/null 2>&1
  ```

- [ ] **Step 5:** Run the full ENG-122 + ENG-179 block to confirm every retrofitted case still asserts the same outcome:
  ```bash
  bash bin/run-stage-test.sh 2>&1 | grep -E 'ENG-122 INT|ENG-179 INT|FAIL'
  ```
  Expect every INT1/INT2/INT3/INT4/INT5/INT-P line as `✓ ...`, every INT-Q/INT-R/INT-T/INT-U line as `✓ ...`, no `FAIL`.

### Task 7: Add the CLAUDE.md failure-mode row

- `depends_on: [1]`
- `touches: CLAUDE.md`

- [ ] **Step 1:** In `CLAUDE.md`, content anchor: the existing row `| scope-check halts on files from a recent upstream merge | Pre-ENG-59 bug; post-ENG-59 (`bin/scope-check.sh:155-…`) fetches `origin main` per run. ...` at ~L784. Insert a new row IMMEDIATELY BEFORE that line (so the new row sits between the wrong-target Linear writes row and the scope-check-fetch row), explicitly contrasting with the downstream `scope-check rc=2` symptom per brainstorm AC 9:

  ```
  | Issue halts at `stage:planning` with `plan-contract-missing` defect immediately after a planning dispatch | ENG-179 gate (`bin/run-stage.sh::_validate_plan_contract`) — the planning agent emitted `verdict=pass` but the canonical plan artifact (`docs/plans/<date>-*<eng-n>-*.md` + sibling `.json`) is NOT in the branch HEAD tree. Common cause: `claude -p` session-limit / `out_of_credits` death after the agent posted its Linear markers but before it committed the plan files (operator memory: `session-limit-false-halts`). **Contrast** with the downstream `scope-check rc=2` "plan not found" symptom — that one fires at `stage:implementing` AFTER the transition and burns the `implement_rejection` budget; the ENG-179 gate halts BEFORE the transition with zero implement dispatches consumed. **Recovery:** inspect `$PROJECT_STATE_DIR/<slug>/logs/<ident>-planning-*.log` for the session-limit signature, fix the underlying cause (credits/quota), then `bash bin/pipeline.sh decide <ENG-N> --action continue`. Operator may alternatively commit the plan pair by hand on the feature branch and resume; the gate honours an operator-committed plan. |
  ```

  The row sits in the existing two-column table; cell separators are `|`. Do not add a trailing newline beyond the existing pattern. Validate the row count with `bash -n CLAUDE.md` (n/a — markdown, but a visual eyeball pass is sufficient).

### Task 8: Full gate + commit

- `depends_on: [1, 2, 3, 4, 5, 6, 7]`
- `touches: (verification + commit only)`

- [ ] **Step 1:** Run the full `bin/*-test.sh` sweep (the pre-commit gate):
  ```bash
  bash .githooks/pre-commit
  ```
  Expect: every test file passes; no `FAILED:` line. Pay particular attention to `bin/run-stage-test.sh` (the only file with changed assertions and new fixtures).

- [ ] **Step 2:** Confirm tree shape:
  ```bash
  git status --short
  ```
  Expect only `bin/run-stage.sh`, `bin/run-stage-test.sh`, `CLAUDE.md` modified.

- [ ] **Step 3:** Commit:
  ```bash
  git add bin/run-stage.sh bin/run-stage-test.sh CLAUDE.md
  git commit -m "fix(ENG-179): gate planning→implementing on HEAD-committed plan

  Pre-ENG-179 _validate_plan_contract used `find docs/plans` and failed
  open on absent .md, so a planning dispatch that emitted verdict=pass
  but died (session-limit / out_of_credits) before committing the plan
  files would still drive the orchestrator's planning→implementing
  transition — the missing artifact only surfaced downstream at
  scope-check rc=2, after burning two implement dispatches.

  Switch the validator to `git ls-tree -r HEAD -- docs/plans/`, drop the
  today-only date anchor (cross-midnight resume still works), gate the
  sibling .json on HEAD too, and remove the absent-md fail-open path —
  absent .md or .json in HEAD now halts with plan-contract-missing
  (rc=35), stage stays at planning, operator resumes via
  `decide --action continue`.

  Tests: INT-Q flipped (fail-open → strict-halt); INT-R/T/U added
  (committed pair → rc=0; written-but-uncommitted → rc=35; cross-
  midnight → rc=0); INT1/2/3/5 retrofitted with git init + commit.

  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
  ```

## 6. Frontend Tasks

No frontend surface. The harness has no UI; this plan changes only bash orchestration scripts and tests.

## 7. Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Planning agent emits `verdict=pass`, dies before any file write or commit | `_validate_plan_contract` runs; HEAD has no plan `.md` for ident | rc=35; halt comment `plan-contract-invalid` / `Defect: plan-contract-missing`; label stays `stage:planning` | integration | `ENG-179 INT-Q` |
| Planning agent writes `.md`+`.json` to worktree but dies before `git commit` | `_validate_plan_contract` runs; worktree dir has files but HEAD does not | rc=35; halt comment `plan-contract-missing` | integration | `ENG-179 INT-T` |
| Planning agent writes & commits clean pair | `_validate_plan_contract` runs; HEAD has `.md`+`.json`; schema valid | rc=0; no halt comment | integration | `ENG-179 INT-R` |
| Planning re-dispatch after midnight on yesterday's committed plan | `_validate_plan_contract` runs; HEAD has plan with `[YYYY-MM-DD]` ≠ today | rc=0; loose pattern accepts any ISO-date prefix | integration | `ENG-179 INT-U` |
| `.md` committed in HEAD, `.json` written but NOT committed | new HEAD-tree presence guard for `$plan_json` fires before schema validator | rc=35; halt comment `plan-contract-missing` (via the Task-1 Step-3 guard) | integration | covered by `ENG-122 INT2` (122-L) post-retrofit (Task 6 step 2 commits only the `.md`; HEAD lacks `.json`) |
| `.md` + `.json` both committed, `.json` malformed (parse failure) | schema validator returns rc=33 | rc=33; halt comment `plan-contract-malformed` (existing path, unchanged) | integration | `ENG-122 INT3` (122-M) |
| `.md` + `.json` both committed, `.json` `issue_id` injected with `<!--` | schema validator returns rc=34; injection sanitisation must replace `<!--` with `<\!--` | rc≠0; halt comment carries sanitised marker; raw `<!--` absent | integration | `ENG-122 INT5` (122-O) |
| Worktree dir absent (precondition check) | early fail-open in `_validate_plan_contract` at line 1087 | rc=0; no halt | integration | `ENG-122 INT-P` (122-P, unchanged) |
| Stage gate structural lint — `_validate_plan_contract` call site must be inside a `planning)` arm | source-level grep + awk extraction of the `case "$stage"` block | call site is found inside `planning)` arm | static lint | `ENG-122 INT4` (122-N, unchanged) |

## 8. Test Strategy

**Unit-level coverage** is absent for this change — `_validate_plan_contract` is naturally an integration boundary (it shells to `git`, `plan-schema.sh`, and `linear.sh` stubs). The closest unit-pattern is the schema validator itself, which has standalone coverage in `bin/plan-schema-test.sh` + `bin/plan-schema-adversarial-test.sh` (not modified by this plan; their behaviour is upstream of the change here).

**Integration coverage** is the canonical layer for this fix. The eight existing ENG-122 INT cases (K, L, M, N, O, P, Q) plus the three new ENG-179 INT cases (R, T, U) jointly exercise:

- happy path (R, K)
- absent `.md` in HEAD (Q) — the AC 1 / criterion (b) discriminator
- written-but-uncommitted (T) — the AC 3 / criterion (c) discriminator that pins HEAD-tree query as load-bearing (worktree-find would pass T)
- cross-midnight resume (U) — regression guard for the today-only anchor drop
- absent `.json` in HEAD (L, post-retrofit) — exercises the Task 1 Step 3 sibling-JSON HEAD guard
- malformed `.json` (M) — existing schema-validator path, unchanged
- injection sanitisation (O) — existing security pattern, unchanged
- absent worktree (P) — fail-open preserved
- structural lint (N) — call-site stays inside `planning)` arm

**Smoke / e2e coverage:** the `bin/*-test.sh` sweep (the pre-commit gate at `.githooks/pre-commit`) acts as the smoke layer. Task 8 step 1 runs it explicitly. No new e2e fixtures are needed — the orchestrator's verdict_handler / apply_transition path is already exercised by `bin/verdict-handler-test.sh` and is upstream-unaffected by the validator tightening (verdict_handler only fires when the validator returns 0).

**Adversarial coverage:** the existing `bin/plan-schema-adversarial-test.sh` covers schema-validator edge cases (unicode `issue_id`, deeply nested unknown fields, large feature lists). Those tests stay green because this plan does not change the schema validator — only the substrate that feeds it (HEAD vs. worktree). The injection-sanitisation case (INT5/122-O) is retained inside the integration sweep and continues to assert `<!--` → `<\!--` substitution.

**Test-gate closure (re-stated):** no new `bin/*-test.sh` file is added; no file in the gate's Test command (`learned-rules/harness/project-profile.md:17`) needs updating; no token removed from production code is asserted-on by any test outside `bin/run-stage-test.sh`. The closure sweep is bounded.
