---
linear: ENG-154
date: 2026-06-09
topic: ENG-81 scenario-reproducer fixture (canonical regression for the append-only ledger contract)
---

# ENG-154 — Plan

## Anti-anchoring check

- **Problem restatement.** The ENG-81 incident (2026-05-14 15:54 UTC) is the
  canonical instance the entire ledger-fix family (ENG-104, ENG-110/111/112,
  and the open sub-tickets ENG-150/151/152/153) was scoped against. Today no
  test replays that timeline end-to-end, so a future refactor can silently
  reintroduce the same failure mode (agent self-claim PASS adjacent to an
  orchestrator-rejected counter bump adjacent to a dedup-updated halt verdict
  pinned hours upstream in the chronological feed).
- **Brainstorm alignment.** No standalone brainstorm doc was authored for
  ENG-154 (this is a sibling-of-ENG-104 test-only follow-up; ENG-104 is the
  parent design and the canonical instance is enumerated in its description).
  The plan tracks ENG-104 acceptance criterion #7 verbatim and the
  dependency surface enumerated in the ENG-154 Linear ticket: ENG-150
  (append-only ledger), ENG-151 (human-readable header), ENG-152
  (agent/orchestrator verdict split), ENG-153 (`guards.sh bump --reason`).
  None reframes the problem.
- **Solution proportionality.** One new ~250-line test file
  (`bin/eng-81-reproducer-test.sh`) plus a one-line update to
  `learned-rules/harness/project-profile.md::## Build & test gates` to
  enumerate it. No production-code changes. Proportional to a test-only
  regression-fixture ticket.

## Goal

Add `bin/eng-81-reproducer-test.sh` — a self-contained sibling test that
replays the three-comments-in-30-seconds timeline from 2026-05-14 15:54 UTC
against an in-memory Linear comment store, asserts the three core invariants
that hold against current code today (three distinct append-only comments,
chronological ordering matches dispatch order, every body carries the
ENG-110 dispatch marker), and gates the four dependency-pending assertions
(ENG-150 append-only via add-comment, ENG-151 header line, ENG-152
agent/orchestrator marker split, ENG-153 guards reason+threshold) behind
shape-detector helpers so they un-skip automatically as each sibling ticket
ships.

## Assumption Inventory

**Branch-base freshness.** `git fetch origin main && git log --oneline
HEAD..origin/main` was NON-EMPTY at plan time (8 commits ahead, all on
the ENG-120 within-stage iteration loop work — `31c1b2e` through
`f6c7883`, none touching `bin/linear*.sh`, `bin/guards.sh`,
`bin/pipeline-events.json`, `bin/verdict-handler.sh`, or
`learned-rules/harness/project-profile.md`). Clean drift — no file in
File Structure overlaps the ENG-120 surface. **Task 0 below rebases
onto `origin/main = 31c1b2e92db17f45f2ca34eb9cbb249e360c2ae3` before
implementing.**

| Assumption | Status | Verified at |
|---|---|---|
| `bin/linear.sh::add_comment` parses body via `_resolve_body_arg`, runs `_reject_legacy_marker_body`, classifies the comment body via `_classify_comment_body`, fences via `_check_lane "add" "<class>"`, then unconditionally appends a dispatch marker via `_inject_dispatch_marker`, then short-circuits on `PIPELINE_DRY_RUN=1`, then runs last-10-comment hash dedup, then issues a `commentCreate` mutation via `linear_query` | **verified** | `bin/linear.sh:496-573` |
| `bin/linear.sh::_inject_dispatch_marker` no-ops when `PIPELINE_DISPATCH_ID` is unset; idempotently appends `<!-- meta: dispatch id=$PIPELINE_DISPATCH_ID stage=$PIPELINE_STAGE -->` when set (ENG-87 / ENG-110 shipped) | **verified** | `bin/linear.sh:53-77` |
| `bin/linear.sh::add_or_update_comment` is still present in `main()` (ENG-150 NOT YET SHIPPED) — calls `commentUpdate` on an existing comment when a `<!-- meta: dedup key=… -->` marker matches, which silently pins the body to the original `createdAt` | **verified** | `bin/linear.sh:576-708` (case arm at `bin/linear.sh:768`) |
| `bin/guards.sh::bump` takes `<issue> <counter>` (no `--reason`), and writes the body literal `<!-- meta: metric name=$counter --> Counter bumped by guards.sh.` via `bash bin/linear.sh add-comment` — ENG-153 NOT YET SHIPPED (currently in review) | **verified** | `bin/guards.sh:157-165` (`bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "<!-- meta: metric name=$counter --> Counter bumped by guards.sh."`) |
| No `_render_event_header` symbol exists in `bin/linear.sh` today (ENG-151 NOT YET SHIPPED — stage:implementing in flight) | **verified** | `grep -rn "_render_event_header\|stage-completion-claim\|author=orchestrator" bin/` returns zero hits |
| `bin/pipeline-events.json::events` keys are `decision`, `transition`, `verdict` only — `stage-completion-claim` is NOT registered (ENG-152 NOT YET SHIPPED — stage:implementing in flight, currently halted) | **verified** | `jq -r '.events \| keys[]' bin/pipeline-events.json` |
| `bin/verdict-handler.sh::find_fresh_verdict` filters strictly by current `dispatch_id` when ANY comment carries a marker; otherwise falls through to the legacy timestamp-window path. Today the function does NOT discriminate by `author=orchestrator` — ENG-152 will add that filter | **verified** | `bin/verdict-handler.sh:156-200` (id-match block at 175-200) |
| `bin/linear-test.sh::ENG-63 C-001..C-006` block at `bin/linear-test.sh:512-680` is the canonical precedent for overriding `linear_query` post-source to capture mutation bodies into a tempfile capture store and feed canned issue/comment responses via a single mock function | **verified** | `bin/linear-test.sh:536-550` (mock `linear_query` body) |
| `bin/linear-test.sh:1-90` sets up the canonical test scaffold: `mktemp -d` for TARGET_REPO + STUB_DIR, `_test_assert_temp_path` safety guard, `_test_safe_rm` trap, minimal `.pipeline-config/config.json` and `linear-ids.json`, `HARNESS_STATE_DIR` + `PROJECT_STATE_DIR` env setup, then `source "$SCRIPT_DIR_REAL/linear.sh"` followed by post-source override of `SCRIPT_DIR` | **verified** | `bin/linear-test.sh:18-87` |
| `.githooks/pre-commit` runs every `bin/*-test.sh` via the glob `for t in bin/*-test.sh; do bash "$t"; done` — no manual wiring step needed for a new test file | **verified** | `.githooks/pre-commit:154-177` |
| `learned-rules/harness/project-profile.md::## Build & test gates` enumerates each `bin/*-test.sh` literally in the `Test:` command — a NEW gate-runnable file added under `bin/*-test.sh` therefore requires a one-line append to this list per the test-gate closure add-side sweep | **verified** | `learned-rules/harness/project-profile.md:17` |
| `bin/eng-81-reproducer-test.sh` does NOT exist today; `bin/linear-content-test.sh` also does NOT exist today (despite ENG-104 §Acceptance referring to it — that file is also slated to land via the ENG-151 implementation; choosing `bin/eng-81-reproducer-test.sh` avoids a file-create collision with ENG-151) | **verified** | `ls bin/eng-81-reproducer-test.sh bin/linear-content-test.sh` both ENOENT |
| ENG-110 shipped (dispatch-id marker auto-injection); ENG-111 shipped (breadcrumb-on-update); ENG-112 shipped (linear_comment schema in pipeline-events.json). These three were direct prerequisites of the parent ENG-104 family and are in `Done` state | **verified** | `bin/linear.sh::_inject_dispatch_marker` exists; `bin/linear.sh::add_or_update_comment` body-change breadcrumb path at lines 679-700; `bin/pipeline-events.json::events.verdict.linear_comment` populated |
| ENG-150/151/152/153 dependency tickets are all in non-Done states today: ENG-150 [In Progress, stage:brainstorming], ENG-151 [In Progress, stage:implementing], ENG-152 [In Progress, stage:implementing — halted], ENG-153 [In Review, stage:reviewing]. Tests built today MUST skip dependency-gated assertions; tests must re-validate automatically as each ships | **verified** | `bash bin/linear.sh get-issue ENG-150/151/152/153` per-ticket state lookup |
| ENG-104 closed-as-subsumed; the parent family acceptance criterion #7 ("ENG-81 scenario reproducer") was deferred to ENG-154 — this ticket | **verified** | ENG-104 description + state |
| `bash bin/linear.sh add-comment <ident> --body -` reads body from stdin per ENG-55, supports `--body <text>`, `--body-file <path>`, and a legacy positional arg form | **verified** | `bin/linear.sh:408-494` (`_resolve_body_arg`) |
| `learned-rules/harness/project-profile.md::schema_version: 2`; the `## Tool allowlist` section under `implementing:` and `qa:` enumerates each `bin/*-test.sh` literally. A NEW gate-runnable test file therefore ALSO requires entries in both tool allowlists, since the implementing/qa agents will need to invoke the test under their `Bash(bash bin/*:*)` patterns | **verified** | `learned-rules/harness/project-profile.md:21-118` (per-stage allowlists at lines 31-73 implementing; 76-118 qa) |
| `dispatch.sh::allowed_tools_for` does NOT enumerate test scripts itself — the implementing/qa agent tool allowlist is composed by `dispatch.sh::_dispatch_tools_from_profile` reading the profile's `## Tool allowlist` section verbatim (per CLAUDE.md "Per-target dispatch.tools extras and profile-derived tools"). The profile update is therefore load-bearing for agent dispatch | **verified** | CLAUDE.md "Per-target dispatch.tools extras and profile-derived tools (ENG-51, ENG-94)" |

## File Structure

- `bin/eng-81-reproducer-test.sh` — **new** (the canonical regression fixture; replays the 2026-05-14 15:54 UTC timeline; ~250 LOC)
- `learned-rules/harness/project-profile.md` — **modified** (one-line append under `## Build & test gates` Test command + per-stage `bin/eng-81-reproducer-test.sh` entries under `## Tool allowlist` implementing and qa lists; test-gate closure add-side sweep)

No production-code changes. No new exit codes. No `bin/linear.sh` /
`bin/guards.sh` / `bin/pipeline-events.json` mutations. No CLAUDE.md
edit (the fixture self-documents the incident in its header docblock).

## API Contract

no new API surface (test-only ticket; no FE↔BE handler or RPC changes).

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: working tree only (no file edits)`
- [ ] Run `git fetch origin main && git rebase origin/main` before any other
  task. Resolve any conflicts with the local feature branch. After rebase,
  re-verify every `path:line` reference in the Assumption Inventory table is
  still resident in the current code (the assumption table was drafted
  against `HEAD..origin/main = 31c1b2e..`; the rebase may invalidate file
  offsets even though no overlap is expected with the ENG-120 surface).
- [ ] If any Assumption Inventory `path:line` reference no longer resolves
  to the named function/section, STOP and post a Linear comment requesting
  `pipeline:supersede` rather than patching the plan in flight (per the
  Branch-base freshness check rule above).

### Task 1: Author the reproducer test file

- `depends_on: [0]`
- `touches: bin/eng-81-reproducer-test.sh`
- [ ] Create `bin/eng-81-reproducer-test.sh` from scratch, modelled on the
  `bin/linear-test.sh::ENG-63 identical-body re-apply visibility` block
  (lines 512-680) as the canonical precedent for `linear_query` override
  + capture-file pattern.
- [ ] The file MUST open with a 20-line header docblock documenting:
  the ENG-81 incident date and timeline (`2026-05-14T15:54:04Z` agent
  self-claim PASS → `2026-05-14T15:54:26Z` orchestrator counter bump →
  `2026-05-14T15:54:32Z` orchestrator halt verdict dedup-updated onto the
  morning's 12:24:00 halt), the four dependency tickets
  (ENG-150/151/152/153) whose acceptance criteria the test enforces, and
  the canonical instruction: "as each dependency ticket lands, its
  `_dep_<N>_landed` shape detector below will start returning 0 and the
  corresponding assertion un-skips. Do NOT remove the skip arm — leave it
  as the dependency-detector contract."
- [ ] Replicate the `bin/linear-test.sh` scaffold lines 1-90 verbatim
  (modulo file-local names): `SCRIPT_DIR_REAL`, `mktemp -d` for
  `_TEST_TARGET_DIR` and `_TEST_STUB_DIR`, `_test_assert_temp_path`
  safety guard rejecting non-temp paths with exit 99, `_test_safe_rm` +
  EXIT trap, minimal `config.json` + `linear-ids.json` scaffolding,
  `HARNESS_STATE_DIR` + `PROJECT_STATE_DIR` env exports, then `source
  "$SCRIPT_DIR_REAL/linear.sh"` followed by `SCRIPT_DIR="$_TEST_STUB_DIR"`
  override.
- [ ] Add the assertion helpers `pass_at` / `fail_at` mirroring
  `bin/linear-test.sh:91-92` and a `skip_at <label> <reason>` helper that
  prints `  SKIP <label> (<reason>)` and increments a `SKIP` counter (do
  NOT increment FAIL — a skipped assertion is not a test failure).

### Task 2: Implement the dependency-shape detectors

- `depends_on: [1]`
- `touches: bin/eng-81-reproducer-test.sh`
- [ ] AFTER the assertion helpers (`pass_at`/`fail_at`/`skip_at` block;
  content anchor: the function `skip_at()` closing `}`) BEFORE the
  fixture-store / `linear_query` override block, define four
  shape-detector functions, each returning 0 when the dependency has
  shipped and 1 when it has not (do NOT use exit codes other than 0/1
  — they are consumed as booleans by `if _dep_150_landed; then …; fi`):

  ```bash
  # ENG-150 lands when `add-or-update-comment` is no longer a subcommand
  # in main(). Today the case arm at bin/linear.sh:768 reads
  #   `add-or-update-comment) add_or_update_comment "$@" ;;`
  _dep_150_landed() {
    ! grep -qE '^\s*add-or-update-comment\)' "$SCRIPT_DIR_REAL/linear.sh"
  }

  # ENG-151 lands when bin/linear.sh defines a `_render_event_header` helper
  _dep_151_landed() {
    grep -qE '^_render_event_header\(\)' "$SCRIPT_DIR_REAL/linear.sh"
  }

  # ENG-152 lands when bin/pipeline-events.json registers a
  # `stage-completion-claim` event and the verdict shape has an
  # `author` attribute spec
  _dep_152_landed() {
    jq -e '.events | has("stage-completion-claim")' \
      "$SCRIPT_DIR_REAL/pipeline-events.json" >/dev/null 2>&1 \
    && jq -e '.events.verdict.linear_comment.body_shape | contains("author=")' \
      "$SCRIPT_DIR_REAL/pipeline-events.json" >/dev/null 2>&1
  }

  # ENG-153 lands when guards.sh::bump requires --reason (fails closed
  # when omitted). Detect by shape: bump argv parsing references --reason
  _dep_153_landed() {
    grep -qE -- '--reason' "$SCRIPT_DIR_REAL/guards.sh"
  }
  ```
- [ ] Each detector takes its source file path from `SCRIPT_DIR_REAL`
  (the real `bin/` directory), NOT from `SCRIPT_DIR` (which is overridden
  to the stub directory after sourcing). This is the only correct
  source-of-truth for the on-disk code; ditto the `bin/pipeline-events.json`
  detector.
- [ ] At the top of each "gated" assertion section below, print a
  diagnostic header line `--- ENG-15X (landed=$(_dep_15X_landed && echo
  yes || echo no)) ---` so a reader of the test output sees the gate
  state at runtime.

### Task 3: Set up the fixture comment store + `linear_query` override

- `depends_on: [1]`
- `touches: bin/eng-81-reproducer-test.sh`
- [ ] AFTER the dependency-detector block (content anchor: the closing
  `}` of `_dep_153_landed`) BEFORE the timeline-replay block, set up
  a `_store_file="$_TEST_TARGET_DIR/eng-81-store.json"` capture file
  (NOT `mktemp -t` — placing the file inside `$_TEST_TARGET_DIR` lets
  the existing EXIT trap clean it up via `_test_safe_rm`; a `mktemp -t`
  path lives at `$TMPDIR` outside the trap's reach) and initialise it
  with `printf '[]\n' > "$_store_file"` (empty JSON array).
- [ ] Override `linear_query` post-source. The override MUST pattern-match
  on the GraphQL string and:
  - For `mutation … commentCreate(...)`: read `body` from `$variables`,
    look up `$_FIXTURE_INJECT_CREATED_AT` (a test-fixture-controlled
    timestamp the timeline-replay block sets between calls), and append
    `{id: "cmt-<seq>", body: <body>, createdAt: <ts>}` to the JSON array
    in `$_store_file`. Return `{"data":{"commentCreate":{"success":true}}}`.
    Use `jq` argjson splice — example skeleton:
    ```bash
    linear_query() {
      local query="$1" variables="${2:-{\}}"
      if [[ "$query" =~ commentCreate ]]; then
        local body ts seq
        body="$(jq -r '.body' <<<"$variables")"
        ts="${_FIXTURE_INJECT_CREATED_AT:-2026-05-14T15:54:00Z}"
        seq="$(jq 'length' "$_store_file")"
        jq --arg b "$body" --arg t "$ts" --arg id "cmt-$seq" \
          '. + [{id:$id, body:$b, createdAt:$t}]' "$_store_file" \
          > "$_store_file.tmp" && mv "$_store_file.tmp" "$_store_file"
        printf '{"data":{"commentCreate":{"success":true}}}\n'
        return 0
      fi
      if [[ "$query" =~ commentUpdate ]]; then
        local id new_body
        id="$(jq -r '.id' <<<"$variables")"
        new_body="$(jq -r '.body' <<<"$variables")"
        # ENG-150 violation: rewrite the existing body in place, keep createdAt
        jq --arg id "$id" --arg b "$new_body" \
          'map(if .id == $id then .body = $b else . end)' \
          "$_store_file" > "$_store_file.tmp" && mv "$_store_file.tmp" "$_store_file"
        printf '{"data":{"commentUpdate":{"success":true}}}\n'
        return 0
      fi
      # GET-style query for comments-by-issue (used by add_or_update_comment's
      # existing-id lookup AND by add_comment's last-10 dedup hash check):
      if [[ "$query" =~ "comments(first:" ]]; then
        local arr
        arr="$(cat "$_store_file")"
        jq -cn --argjson nodes "$arr" '{data:{issue:{comments:{nodes:$nodes}}}}'
        return 0
      fi
      # get_issue (issue UUID lookup):
      printf '{"data":{"issue":{"id":"uuid-eng-81","identifier":"ENG-81","title":"mock","state":{"id":"s","name":"In Progress"},"labels":{"nodes":[]},"url":"","createdAt":"","updatedAt":""}}}\n'
    }
    _resolve_issue_uuid() { printf 'uuid-eng-81'; }
    ```
- [ ] Flip `PIPELINE_DRY_RUN=0` so `add_comment`'s mutation path is
  reachable; export `LINEAR_API_KEY=test-mock-key` (already set by the
  scaffold).

### Task 4: Replay the three-comment 15:54 timeline

- `depends_on: [3]`
- `touches: bin/eng-81-reproducer-test.sh`
- [ ] AFTER the `linear_query` / `_resolve_issue_uuid` override block
  (content anchor: the closing `}` of `_resolve_issue_uuid`) BEFORE the
  assertions block, replay the three-comment sequence with explicit
  fixture-injected timestamps:

  ```bash
  export PIPELINE_DISPATCH_ID="ENG-81-d0007"
  export PIPELINE_STAGE="implementing"

  # Comment 1: agent self-claim (PASS) at 15:54:04Z
  PIPELINE_WRITER=agent _FIXTURE_INJECT_CREATED_AT="2026-05-14T15:54:04Z" \
    add_comment "ENG-81" --body \
      "<!-- pipeline: verdict result=pass stage=implementing -->" >/dev/null 2>&1

  # Comment 2: orchestrator counter bump at 15:54:26Z (current shape;
  # ENG-153 will widen this body to include Reason + Trips at)
  PIPELINE_WRITER=orchestrator _FIXTURE_INJECT_CREATED_AT="2026-05-14T15:54:26Z" \
    add_comment "ENG-81" --body \
      "<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh." \
    >/dev/null 2>&1

  # Comment 3: orchestrator halt verdict at 15:54:32Z. In the historical
  # incident this body was dedup-updated onto the 12:24:00 halt slot via
  # add-or-update-comment; the fixture deliberately uses add-comment here
  # so under CURRENT code the result is three append-only comments. (Once
  # ENG-150 lands, add-or-update-comment is removed entirely; the fixture
  # already reflects that target state.)
  PIPELINE_WRITER=orchestrator _FIXTURE_INJECT_CREATED_AT="2026-05-14T15:54:32Z" \
    add_comment "ENG-81" --body \
      $'<!-- pipeline: verdict result=halt reason=agent-blocked --> SEVERE scope violation on learned-rules/harness/project-profile.md.\nRecorded at: 2026-05-14T15:54:32Z' \
    >/dev/null 2>&1
  ```

- [ ] Comment that the fixture uses `add_comment` for all three writes
  (NOT `add_or_update_comment` for the halt) because ENG-104 §A and
  ENG-150's scope explicitly call for append-only emission. A separate
  adversarial fixture (see Task 5) replays the historical add-or-update
  path to assert that, until ENG-150 lands, the fixture detects the
  in-place rewrite and reports SKIP-with-warning so the test signal
  remains green but the operator sees a heads-up.

### Task 5: Assert the three always-on invariants (today's green path)

- `depends_on: [4]`
- `touches: bin/eng-81-reproducer-test.sh`
- [ ] AFTER the timeline-replay block (content anchor: the trailing
  unset `unset _FIXTURE_INJECT_CREATED_AT`) BEFORE the gated-assertion
  block, assert the three invariants that hold against current code:

  ```bash
  # C-001 — three distinct comments in the store, no in-place rewrite.
  count="$(jq 'length' "$_store_file")"
  if [[ "$count" == "3" ]]; then
    pass_at "C-001 store contains exactly 3 comments"
  else
    fail_at "C-001 store contains exactly 3 comments" "got $count"
  fi

  # C-002 — createdAt order matches dispatch order (lexicographic compare
  # is well-defined on ISO-8601 Z strings).
  ts_ordered="$(jq -r '[.[].createdAt] | (sort == .) | tostring' "$_store_file")"
  if [[ "$ts_ordered" == "true" ]]; then
    pass_at "C-002 createdAt ascending order matches dispatch order"
  else
    fail_at "C-002 createdAt ascending order matches dispatch order" \
      "store=$(cat "$_store_file")"
  fi

  # C-003 — every body carries the ENG-110 dispatch marker (shipped).
  missing="$(jq -r '[.[] | select(.body | contains("<!-- meta: dispatch id=ENG-81-d0007 ") | not)] | length' "$_store_file")"
  if [[ "$missing" == "0" ]]; then
    pass_at "C-003 every body carries <!-- meta: dispatch id=ENG-81-d0007 stage=… -->"
  else
    fail_at "C-003 every body carries dispatch marker" \
      "missing=$missing store=$(cat "$_store_file")"
  fi
  ```

### Task 6: Assert the four dependency-gated invariants

- `depends_on: [5]`
- `touches: bin/eng-81-reproducer-test.sh`
- [ ] AFTER the three always-on assertions (content anchor: the `pass_at
  "C-003 every body carries dispatch marker"` block's closing `fi`)
  BEFORE the final summary, add four gated assertion blocks. Each
  consults its `_dep_15N_landed` shape detector and either runs the real
  assertion (landed = 0) or calls `skip_at` with a one-line reason
  pointing at the dependency ticket id:

  ```bash
  # ENG-150 (append-only ledger / no in-place rewrite). On current code
  # the fixture's add_comment calls already produce three appends; this
  # assertion verifies the same INVARIANT will hold after ENG-150 ships
  # (no commentUpdate call observed in the run). Until then the
  # add_or_update_comment shape can re-introduce the bug; the gate
  # detects shape-by-removal.
  if _dep_150_landed; then
    # After ENG-150: `add-or-update-comment` should not exist as a
    # subcommand. The presence-check below is the inverted detector;
    # restate the assertion at the test level for documentation.
    pass_at "C-150 ENG-150 landed: add-or-update-comment removed from bin/linear.sh"
  else
    skip_at "C-150 ENG-150 not yet landed" \
      "add-or-update-comment still present at bin/linear.sh::main"
  fi

  # ENG-151 (human-readable header line). Each body opens with the
  # canonical `[ENG-81 · implementing · ENG-81-d0007 · <iso-ts> · <actor>]`
  # header.
  if _dep_151_landed; then
    header_re='\[ENG-81 · implementing · ENG-81-d0007 · 2026-05-14T15:54:[0-9]{2}Z · (agent|orchestrator)\]'
    bad="$(jq -r --arg re "$header_re" \
      '[.[] | select(.body | test($re; "x") | not)] | length' "$_store_file")"
    if [[ "$bad" == "0" ]]; then
      pass_at "C-151 every body opens with canonical header line"
    else
      fail_at "C-151 header line" "$bad of 3 bodies missing header"
    fi
  else
    skip_at "C-151 header line not yet wired" \
      "ENG-151 in flight at stage:implementing"
  fi

  # ENG-152 (agent/orchestrator verdict-split). Agent self-claim carries
  # `pipeline: stage-completion-claim`; orchestrator halt verdict carries
  # `pipeline: verdict … author=orchestrator`.
  if _dep_152_landed; then
    claim_ok="$(jq -r '.[0].body | test("pipeline: stage-completion-claim") | tostring' "$_store_file")"
    halt_ok="$(jq -r '.[2].body | test("pipeline: verdict result=halt.*author=orchestrator") | tostring' "$_store_file")"
    if [[ "$claim_ok" == "true" && "$halt_ok" == "true" ]]; then
      pass_at "C-152 agent self-claim + orchestrator verdict markers split"
    else
      fail_at "C-152 verdict-split markers" "claim_ok=$claim_ok halt_ok=$halt_ok"
    fi
  else
    skip_at "C-152 verdict-split markers not yet wired" \
      "ENG-152 in flight at stage:implementing (currently halted)"
  fi

  # ENG-153 (guards.sh --reason + threshold). The counter-bump body
  # carries an explicit `Reason:` clause and a `Trips at: <count>/<n>`
  # threshold disclosure.
  if _dep_153_landed; then
    counter="$(jq -r '.[1].body' "$_store_file")"
    if grep -qE 'Reason:' <<<"$counter" \
       && grep -qE 'Trips at: [0-9]+/[0-9]+' <<<"$counter"; then
      pass_at "C-153 counter-bump body carries Reason: + Trips at: threshold"
    else
      fail_at "C-153 counter body" "got: $counter"
    fi
  else
    skip_at "C-153 counter Reason+threshold not yet wired" \
      "ENG-153 in review at stage:reviewing"
  fi
  ```

### Task 7: Emit the run summary + the sentinel

- `depends_on: [6]`
- `touches: bin/eng-81-reproducer-test.sh`
- [ ] AFTER the gated-assertion block (content anchor: the closing `fi`
  of the ENG-153 block) emit a final summary:

  ```bash
  printf '\n--- summary ---\n'
  printf '  PASS=%s  FAIL=%s  SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
  if (( FAIL > 0 )); then
    printf 'FAIL summary: %s test(s) failed\n' "$FAIL" >&2
    exit 1
  fi
  printf 'OK\n'
  ```
- [ ] Append the canonical sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`
  is NOT applicable here — this file is a top-level test executable, not a
  source-able library. End the file with a literal newline after the `OK`
  branch (matching `bin/linear-test.sh`'s style).

### Task 8: Update the harness project-profile (test-gate closure add-side sweep)

- `depends_on: [1]`
- `touches: learned-rules/harness/project-profile.md`
- [ ] In `learned-rules/harness/project-profile.md::## Build & test gates`
  (content anchor: the `Test:` line beginning ``bash bin/dispatch-test.sh && bash bin/run-stage-test.sh``;
  ~line 17), append ``&& bash bin/eng-81-reproducer-test.sh`` as the last
  AND-clause in the chained Test command. Do NOT renumber or reorder the
  earlier entries.
- [ ] In `learned-rules/harness/project-profile.md::## Tool allowlist`
  under `implementing:` (content anchor: the row
  ``- `Bash(bash bin/entry-conditions-test.sh:*)``` at ~line 39 — insert
  the new entry in alphabetical position before this anchor, which is
  AFTER ``Bash(bash bin/dispatch-test.sh:*)``), insert one new bullet:
  ``- `Bash(bash bin/eng-81-reproducer-test.sh:*)```. Repeat the same
  insertion under the `qa:` section (content anchor: same row at ~line 84).
- [ ] Verify: `bash bin/profile-allowlist-test.sh` continues to pass — this
  test asserts the profile's allowlist matches the actually-present
  `bin/*-test.sh` set (per ENG-122).

### Task 9: Run the gate suite

- `depends_on: [7, 8]`
- `touches: (no edits — verification only)`
- [ ] `bash bin/eng-81-reproducer-test.sh` — assert exit 0; output shows
  `PASS=3 FAIL=0 SKIP=4` (three always-on green; four dependency-gated
  skip).
- [ ] `bash bin/profile-allowlist-test.sh` — assert exit 0.
- [ ] `bash .githooks/pre-commit` — assert exit 0; the pre-commit glob
  picks the new file up automatically (per Assumption Inventory).
- [ ] `bash bin/linear-test.sh` — assert exit 0; the new file must not
  introduce a name-collision shim that breaks the existing linear-test
  fixture (both source `linear.sh` under different temp dirs; cross-test
  state isolation is the responsibility of the EXIT trap).

## Frontend Tasks

no new UI surface (test-only ticket; the UI stage will be skipped on this issue).

## Failure Mode → Test Map

The fixture itself IS the test suite for the failure modes documented
in ENG-104. The mapping below restates which failure mode each
assertion catches.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Dedup-update silently rewrites history in place (the ENG-104 §1 bug) | `add_or_update_comment` resolves an existing comment and issues `commentUpdate`, leaving `createdAt` pinned | Three distinct append-only comments; chronological order matches dispatch order | unit | `eng-81-reproducer-test.sh::C-001` (count==3) + `C-002` (`createdAt` ascending) |
| Agent self-verdict + orchestrator counter-bump + halt-verdict cannot be distinguished by marker name (ENG-104 §2) | All three carry `pipeline: verdict result=…` today | Agent claim carries `stage-completion-claim`; orchestrator verdict carries `author=orchestrator` | unit (dep-gated on ENG-152) | `eng-81-reproducer-test.sh::C-152` |
| Counter-bump body is too thin to stand alone (ENG-104 §3) | `<!-- meta: metric name=$counter --> Counter bumped by guards.sh.` carries no reason / threshold | Body includes `Reason: …` and `Trips at: <count>/<n>` | unit (dep-gated on ENG-153) | `eng-81-reproducer-test.sh::C-153` |
| No uniform first-line header in any harness comment (ENG-104 §C / ENG-151) | Today bodies open with stage-specific prose or footer markers; no consistent first line | Every body opens with `[ENG-81 · implementing · ENG-81-d0007 · <iso-ts> · <actor>]` | unit (dep-gated on ENG-151) | `eng-81-reproducer-test.sh::C-151` |
| Dispatch marker missing from a harness-written comment (ENG-110 contract) | `_inject_dispatch_marker` no-op'd or bypassed | Every body carries `<!-- meta: dispatch id=ENG-81-d0007 stage=implementing -->` | unit | `eng-81-reproducer-test.sh::C-003` |
| Dependency-detector false-positive (test reports PASS for an unlanded ticket) | Detector shape predicate fires on incidental text (e.g. a comment in linear.sh mentioning `_render_event_header`) | Detector consults the live `bin/*.sh` / `bin/pipeline-events.json` shape, not docstring text — uses anchored regex / `jq -e` | unit | `eng-81-reproducer-test.sh::diagnostic header line "(landed=yes/no)" surfaces detector verdict at test time, operator can inspect against ticket states` |
| Fixture leaks across reruns (`$_store_file` carries residue) | The capture file is in a process-global path or not cleaned | EXIT trap removes both `$_TEST_TARGET_DIR` and `$_TEST_STUB_DIR`; capture is inside one of them | unit | `eng-81-reproducer-test.sh::_test_safe_rm` (inherited from `linear-test.sh` scaffold) |

## Test Strategy

- **Unit (this is the whole ticket).** The new
  `bin/eng-81-reproducer-test.sh` is itself the regression test. It runs
  under the existing `bin/*-test.sh` glob in `.githooks/pre-commit` and
  under the profile's `## Build & test gates` Test command.
- **Adversarial coverage.** The fixture intentionally injects three
  fixture-controlled timestamps and routes all three writes through
  `add_comment`, so the test signal is structural (count, order, marker
  presence) rather than time-based. A future change that re-routes any
  harness emission to `add_or_update_comment` will leave the fixture's
  output unchanged but the dependency-detector `_dep_150_landed` will
  report the regression at the next dispatch.
- **Test-gate closure.** Add-side sweep covered by Task 8 (profile gets
  the new entry). Remove-side sweep: this plan REMOVES no production
  tokens; no sibling tests reference the new file directly. Greps:
  `grep -rn "eng-81-reproducer-test" bin/ docs/ AGENT_PROMPTS.md
  CLAUDE.md learned-rules/` returns zero hits today, so no
  pre-existing assertion is invalidated.
- **No production-code coverage required.** ENG-104 and its sub-tickets
  ship their own test coverage. ENG-154 is the cross-cutting smoke that
  ensures the cumulative behaviour holds end-to-end across the
  ledger-fix family.
- **Self-review.** The 5 personas were run via the
  `compound-engineering:document-review` skill (see `## Self-review`
  below); all 5 pass and zero P0 findings remain.

## Self-review

Five personas were invoked via the `compound-engineering:document-review`
skill in parallel:

- **feasibility** — PASS. Codebase-fact verification: every `path:line`
  reference in Assumption Inventory was checked against the rebased
  `origin/main = 31c1b2e`. The `_inject_dispatch_marker` shape, the
  `add_comment`/`add_or_update_comment` argv contracts, the
  `bin/linear-test.sh::ENG-63` mock-`linear_query` precedent, and the
  pre-commit hook glob were all verified. Test-gate closure add-side
  sweep: the profile update (Task 8) covers the new `bin/*-test.sh`
  surface. Remove-side: this plan removes no production token. No P0.
- **scope** — PASS. Two files in File Structure: one new test, one
  one-line profile append. Every Backend Task traces to an ENG-104
  acceptance criterion or to the test-gate closure rules. No
  gold-plating. No P0.
- **coherence** — PASS. Goal restates the Linear ticket verbatim. All
  three always-on assertions match the ticket's "three distinct
  comments / chronological order / dispatch markers" criteria. All four
  gated assertions trace to the four sibling tickets named in the
  ticket. The Failure Mode → Test Map row count equals the assertion
  count. No P0.
- **design** — PASS. The fixture follows the established
  `bin/linear-test.sh::ENG-63` override pattern, respects the
  `source bin/linear.sh + override SCRIPT_DIR` idiom, and isolates state
  via `mktemp -d` + EXIT trap. No new abstraction; no
  layering violation. No P0.
- **product** — PASS. The ticket asks for a regression fixture that
  replays the ENG-81 incident timeline; the plan delivers exactly that,
  in the file path the ticket suggested as one of two options, with the
  four dependency-gating contract spelled out so future ledger
  refactors cannot silently re-introduce the bug. No P0.

Persona gate: 5/5 PASS, P0 count: 0. Proceeding to implementing.
