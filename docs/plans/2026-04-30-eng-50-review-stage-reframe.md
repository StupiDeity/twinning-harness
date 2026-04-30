---
linear: ENG-50
topic: Reframe review stage — agent reviews, human approves, orchestrator gates dispatch
date: 2026-04-30
status: draft
---

# Plan — ENG-50 review-stage reframe

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Implementation plan for the design in
`docs/brainstorms/2026-04-30-eng-50-review-stage-reframe-design.md`.

## Goal

Land a single PR off `main` (`eng-50-review-stage-reframe`) with **6 commits** that:

1. Add `bin/review-state.sh` — a source-able helper for bootstrap/read/update of the orchestrator's `last-review-state/<issue>` Linear comment.
2. Add `bin/review-poll.sh::review_should_dispatch` — the cheap `gh pr view` gate that decides whether `poll.sh` should dispatch the review agent for a `stage:reviewing` issue.
3. Wire `poll.sh::_poll_classify_labels` to call `review_should_dispatch` for `stage:reviewing` issues; classify as `slot:hold,advanceable:false` when nothing has changed (effective idle).
4. Wire `apply_transition`'s `to == reviewing` branch to call `bootstrap_review_state` so the bootstrap comment exists before the first dispatch into review.
5. Wire `run-stage.sh` to call `update_review_state` after a successful review dispatch (advance, rejection, or wait) AND expand `_fresh_wait_reason`'s stage allowlist to permit `review` (currently `build`-only).
6. Rewrite `AGENT_PROMPTS.md §5` to remove `gh pr review --approve|--request-changes`, add the new "Preflight (β)" section, replace decision paths A/B/C with A/B/C/D under β, and add `agent-prompts-content-test.sh` invariants.

After merge, a bot-authored PR receives a human approval via GitHub UI; the orchestrator detects on the next tick and transitions `reviewing → qa` automatically without any bot `gh pr review --approve` call. Critical/major findings still drive loopback to `implementing` via the existing `pipeline-rejection: reviewing` marker.

## Architecture

Side effects of stage transitions stay in the orchestrator (`verdict-handler::apply_transition`, per ENG-49). β extends this: the orchestrator also owns *dispatch gating* for review — `poll.sh` consults a cheap `gh pr view` check (against a Linear-stored `last-review-state/<issue>` comment) to decide whether to dispatch the review agent. The agent stays canonical for verdict-marker authorship.

## Tech Stack

- Bash 3+ (Darwin default, harness target).
- `jq` for JSON parsing.
- `gh` CLI for GitHub API (`pr view`, `pr review --comment`).
- Harness scripts: `verdict-handler.sh`, `poll.sh`, `run-stage.sh`, `linear.sh`, `common.sh`, `dispatch.sh`.
- Test pattern: sentinel-guarded `*-test.sh`, source target script, override `SCRIPT_DIR`/stubs post-source, `pass_at`/`fail_at` helpers.

## Assumption inventory

- **A-001:** `bin/verdict-handler.sh::apply_transition` (post-ENG-49) handles `to == reviewing` with three blocks: native-state hook, PR-create hook, side-labels. The bootstrap call from Task 4 inserts a fourth block in this branch.
- **A-002:** `bin/poll.sh::_poll_classify_labels` (lines 193-238) is the single classification function. The default branch (line 235) classifies non-halted, non-paused, non-abandoned issues as `{slot:hold, advanceable:true}`. Task 3 adds a new branch BEFORE the default for `stage:reviewing` that consults `review_should_dispatch`.
- **A-003:** `bin/run-stage.sh::_fresh_wait_reason` (line 302-329) is currently restricted to `build` only via `[[ "$stage" == "build" ]] || return 1`. Task 5 expands to `case "$stage" in build|review) ;; *) return 1 ;; esac`. The reason allowlist (`awaiting-approval|awaiting-ci`, line 326) already includes `awaiting-approval` — no change.
- **A-004:** `bin/run-stage.sh::_handle_wait` (line 338-end) is stage-agnostic: it takes `$stage` as a parameter and writes state to `$(issue_dir)/wait-${stage}.json`. No changes needed for review.
- **A-005:** Linear `add-or-update-comment <sig> <issue> <body>` (per CLAUDE.md line 34) is the harness's existing dedup mechanism. The `last-review-state/<issue>` sig is new but follows the established `<class>/<stage>/<issue>` pattern.
- **A-006:** `linear.sh get-comments <issue>` returns a JSON array of comment objects with at least `id`, `createdAt`, `body` fields (verified by reading existing tests). The body-embedded `<!-- pipeline-state: last-review-state -->` marker lets the agent and orchestrator find the right comment via `jq '[.[] | select(.body | contains(...))]'`.
- **A-007:** Linear issue's `gitBranchName` field is populated by Linear automatically and is what the harness uses elsewhere (e.g., ENG-49 Task 5's PR-create hook reads it via `bash linear.sh get-issue $issue | jq -r '.data.issue.gitBranchName'`). Reusing the same idiom in `review_should_dispatch`.
- **A-008:** `pipeline-wait: awaiting-approval` markers are explicitly NOT verdict markers — `bin/verdict-handler.sh::find_fresh_verdict` (lines 84-90) filters only for `pipeline-stage-summary`, `pipeline-rejection`, `pipeline-halt`. Wait markers are informational only.
- **A-009:** The §5 fenced block in `AGENT_PROMPTS.md` is bounded by lines ~750 (open) and ~907 (close). Task 6's prompt rewrite must preserve exactly 2 column-0 fences in §5 to honor `render-prompt.sh`'s fence-count contract (see CLAUDE.md "AGENT_PROMPTS.md is load-bearing").

## File Structure

```
bin/
  review-state.sh                NEW       — source-able helper: bootstrap/read/update last-review-state Linear comment (Task 1)
  review-state-test.sh           NEW       — covers helper functions (Task 1)
  review-poll.sh                 NEW       — source-able helper: review_should_dispatch (Task 2)
  review-poll-test.sh            NEW       — covers should_dispatch decision logic (Task 2)
  poll.sh                        modified  — _poll_classify_labels gains stage:reviewing branch (Task 3)
  poll-slot-test.sh              modified  — adds gating-integration cases (Task 3)
  verdict-handler.sh             modified  — apply_transition's to==reviewing block calls bootstrap_review_state (Task 4)
  verdict-handler-test.sh        modified  — covers bootstrap call (Task 4)
  run-stage.sh                   modified  — _fresh_wait_reason allowlist expansion + post-dispatch update_review_state hook (Task 5)
  run-stage-test.sh              modified  — covers post-dispatch update + wait-allowlist expansion (Task 5)
  agent-prompts-content-test.sh  modified  — §5 invariants (Task 6)
  dispatch-test.sh               (verify only) — confirms allowlist contract still passes after §5 changes (Task 6)

AGENT_PROMPTS.md                 modified  — §5 rewrite: Preflight (β), Decision A/B/C/D, rubric item 1, Output (Task 6)
```

No changes to: `dispatch.sh` (review allowlist already has `Bash(gh pr review:*)` which suffices for `--comment`), `halt.sh`, `setup.sh`, `metrics.sh`, `slack.sh`, `scope-check.sh`, `classify-failure.sh`, `linear.sh`, `common.sh`, `gh-app-token.sh`, `learned-rules/*`, `launchd/*`, `.github/*`, `docs/knowledge/*`.

## Command API contract

No CLI argv changes to existing scripts. Two new source-able files (`review-state.sh`, `review-poll.sh`) carry sentinel CLIs:
- `bash bin/review-state.sh bootstrap <issue>` — writes initial all-null state.
- `bash bin/review-state.sh update <issue> <sha> <last_approval_at> <last_cr_at>` — writes updated state.
- `bash bin/review-state.sh read <issue>` — prints current state JSON to stdout.
- `bash bin/review-poll.sh <issue> <branch>` — prints `dispatch` or `idle` (exits 0/1 respectively).

These are orchestrator-internal CLIs. The review-stage agent does NOT invoke them — it reads `last-review-state` directly via `linear.sh get-comments | jq` per the §5 preflight.

---

## Task 1 — `bin/review-state.sh` helper

**depends_on:** []

**Files:**
- Create: `bin/review-state.sh`
- Create: `bin/review-state-test.sh`

- [ ] **Step 1.1: Write the failing test first**

Create `bin/review-state-test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# ENG-50: bin/review-state.sh helper covers bootstrap/update/read of the
# orchestrator's last-review-state/<issue> Linear comment.
set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

_TEST_TARGET="$(mktemp -d -t twinning-rstate-target.XXXXXX)"
_TEST_STUB="$(mktemp -d -t twinning-rstate-stub.XXXXXX)"
case "$_TEST_TARGET" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
case "$_TEST_STUB"   in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
trap 'rm -rf "$_TEST_TARGET" "$_TEST_STUB"' EXIT

mkdir -p "$_TEST_TARGET/.pipeline-config"
cat > "$_TEST_TARGET/.pipeline-config/config.json" <<'JSON'
{"project":{"slug":"test-slug"},"orchestrator":{"paused":false}}
JSON
export TARGET_REPO="$_TEST_TARGET"

# Stub linear.sh: capture add-or-update-comment + emulate get-comments
# from a per-test fixture file.
LINEAR_CALLS="$_TEST_STUB/linear-calls.log"
COMMENTS_FIXTURE="$_TEST_STUB/comments.json"
printf '[]' > "$COMMENTS_FIXTURE"
: > "$LINEAR_CALLS"
cat > "$_TEST_STUB/linear.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  add-or-update-comment)
    # \$1=add-or-update-comment \$2=sig \$3=issue \$4=body
    printf 'aouc\\t%s\\t%s\\t%s\\n' "\$2" "\$3" "\$4" >> "$LINEAR_CALLS"
    # Append to fixture so subsequent get-comments returns it.
    body_json="\$(jq -nc --arg b "\$4" '{id:"c1",createdAt:"2026-04-30T10:00:00Z",body:\$b}')"
    jq --argjson new "\$body_json" '. + [\$new]' "$COMMENTS_FIXTURE" > "$_TEST_STUB/_t" && mv "$_TEST_STUB/_t" "$COMMENTS_FIXTURE"
    exit 0 ;;
  get-comments)
    cat "$COMMENTS_FIXTURE" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/linear.sh"

# shellcheck source=common.sh
source "$SCRIPT_DIR_REAL/common.sh"
# shellcheck source=review-state.sh
source "$SCRIPT_DIR_REAL/review-state.sh"
SCRIPT_DIR="$_TEST_STUB"

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# ─── Case 1: bootstrap_review_state writes initial all-null state ─────
: > "$LINEAR_CALLS"; printf '[]' > "$COMMENTS_FIXTURE"
bootstrap_review_state ENG-501 >/dev/null 2>&1
posted="$(awk -F'\t' '$1=="aouc"{print $4; exit}' "$LINEAR_CALLS")"
sig="$(awk -F'\t' '$1=="aouc"{print $2; exit}' "$LINEAR_CALLS")"
[[ "$sig" == "last-review-state/ENG-501" ]] \
  && ok "case-1 bootstrap uses correct sig" \
  || nope "case-1 sig" "got: $sig"
[[ "$posted" == *"<!-- pipeline-state: last-review-state -->"* ]] \
  && ok "case-1 bootstrap body has marker" \
  || nope "case-1 marker" "body: $posted"
# JSON should have all three keys with null values.
state_json="$(printf '%s\n' "$posted" | grep -E '^\{' | head -1)"
[[ "$(jq -r '.sha' <<<"$state_json")" == "null" ]] \
  && ok "case-1 sha=null" || nope "case-1 sha" "got: $(jq -r '.sha' <<<"$state_json")"
[[ "$(jq -r '.last_processed_approval_at' <<<"$state_json")" == "null" ]] \
  && ok "case-1 last_processed_approval_at=null" || nope "case-1 approval_at" "got: $(jq -r '.last_processed_approval_at' <<<"$state_json")"
[[ "$(jq -r '.last_processed_cr_at' <<<"$state_json")" == "null" ]] \
  && ok "case-1 last_processed_cr_at=null" || nope "case-1 cr_at" "got: $(jq -r '.last_processed_cr_at' <<<"$state_json")"

# ─── Case 2: update_review_state writes the supplied values ───────────
: > "$LINEAR_CALLS"; printf '[]' > "$COMMENTS_FIXTURE"
update_review_state ENG-502 "abc1234" "2026-04-30T10:00:00Z" "" >/dev/null 2>&1
posted="$(awk -F'\t' '$1=="aouc"{print $4; exit}' "$LINEAR_CALLS")"
state_json="$(printf '%s\n' "$posted" | grep -E '^\{' | head -1)"
[[ "$(jq -r '.sha' <<<"$state_json")" == "abc1234" ]] \
  && ok "case-2 sha=abc1234" || nope "case-2 sha" "got: $(jq -r '.sha' <<<"$state_json")"
[[ "$(jq -r '.last_processed_approval_at' <<<"$state_json")" == "2026-04-30T10:00:00Z" ]] \
  && ok "case-2 approval_at" || nope "case-2 approval_at" "got: $(jq -r '.last_processed_approval_at' <<<"$state_json")"
[[ "$(jq -r '.last_processed_cr_at' <<<"$state_json")" == "null" ]] \
  && ok "case-2 cr_at=null (empty arg → null)" || nope "case-2 cr_at" "got: $(jq -r '.last_processed_cr_at' <<<"$state_json")"

# ─── Case 3: read_review_state parses back what update wrote ──────────
# (COMMENTS_FIXTURE was populated by Case 2's stubbed add-or-update-comment.)
read_back="$(read_review_state ENG-502)"
[[ "$(jq -r '.sha' <<<"$read_back")" == "abc1234" ]] \
  && ok "case-3 read returns sha" || nope "case-3 read sha" "got: $(jq -r '.sha' <<<"$read_back")"

# ─── Case 4: read_review_state on missing comment returns empty ───────
printf '[]' > "$COMMENTS_FIXTURE"
read_back="$(read_review_state ENG-503 2>/dev/null || printf '')"
[[ -z "$read_back" ]] \
  && ok "case-4 read returns empty when no comment exists" \
  || nope "case-4 empty" "got: $read_back"

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
```

- [ ] **Step 1.2: Run the test, verify it FAILS**

```
chmod +x bin/review-state-test.sh
bash bin/review-state-test.sh 2>&1 | tail -5
```

Expected: an error like `bin/review-state.sh: No such file or directory`.

- [ ] **Step 1.3: Implement `bin/review-state.sh`**

Create `bin/review-state.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# ENG-50: review-state — orchestrator's last-review-state/<issue> Linear
# comment manager. Source-able helper with bootstrap/read/update for the
# JSON state body. Sentinel-guarded for testing and ad-hoc CLI use.
#
# Body format:
#   <!-- pipeline-state: last-review-state -->
#
#   {"sha":"<sha-or-null>","last_processed_approval_at":"<ts-or-null>","last_processed_cr_at":"<ts-or-null>"}
#
# All three values may be JSON null. The marker line lets the agent grep
# for the comment via linear.sh get-comments without needing the sig.

set -euo pipefail
_RS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$_RS_SCRIPT_DIR/common.sh"

# Default linear.sh path; override SCRIPT_DIR in tests post-source.
SCRIPT_DIR="${SCRIPT_DIR:-$_RS_SCRIPT_DIR}"

_RS_MARKER='<!-- pipeline-state: last-review-state -->'

_rs_compose_body() {
  local sha="$1" approval_at="$2" cr_at="$3"
  local sha_json approval_json cr_json
  [[ -z "$sha" ]]         && sha_json=null         || sha_json="$(jq -Rn --arg v "$sha" '$v')"
  [[ -z "$approval_at" ]] && approval_json=null    || approval_json="$(jq -Rn --arg v "$approval_at" '$v')"
  [[ -z "$cr_at" ]]       && cr_json=null          || cr_json="$(jq -Rn --arg v "$cr_at" '$v')"
  local payload
  payload="$(jq -cn \
    --argjson sha "$sha_json" \
    --argjson approval "$approval_json" \
    --argjson cr "$cr_json" \
    '{sha:$sha, last_processed_approval_at:$approval, last_processed_cr_at:$cr}')"
  printf '%s\n\n%s\n' "$_RS_MARKER" "$payload"
}

bootstrap_review_state() {
  local issue="$1"
  [[ -n "$issue" ]] || die "bootstrap_review_state: issue id required"
  local body
  body="$(_rs_compose_body "" "" "")"
  bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "last-review-state/$issue" "$issue" "$body"
}

update_review_state() {
  local issue="$1" sha="${2:-}" approval_at="${3:-}" cr_at="${4:-}"
  [[ -n "$issue" ]] || die "update_review_state: issue id required"
  local body
  body="$(_rs_compose_body "$sha" "$approval_at" "$cr_at")"
  bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "last-review-state/$issue" "$issue" "$body"
}

read_review_state() {
  local issue="$1"
  [[ -n "$issue" ]] || die "read_review_state: issue id required"
  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue" 2>/dev/null || printf '[]')"
  [[ -z "$comments" || "$comments" == "null" ]] && { printf ''; return 0; }
  # Find the most recent comment containing the marker; extract its body's first JSON line.
  local body
  body="$(jq -r --arg m "$_RS_MARKER" '
    [.[] | select(.body | contains($m))]
    | sort_by(.createdAt) | last | (.body // "")' <<<"$comments")"
  [[ -z "$body" || "$body" == "null" ]] && { printf ''; return 0; }
  printf '%s\n' "$body" | grep -E '^\{' | head -1
}

export -f bootstrap_review_state update_review_state read_review_state

# Sentinel — runnable as a CLI for orchestrator-side calls (apply_transition, run-stage.sh).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    bootstrap) bootstrap_review_state "$@" ;;
    update)    update_review_state "$@" ;;
    read)      read_review_state "$@" ;;
    *)         die "usage: review-state.sh <bootstrap|update|read> <issue> [<sha> <approval_at> <cr_at>]" ;;
  esac
fi
```

- [ ] **Step 1.4: Run the test, verify PASS**

```
chmod +x bin/review-state.sh
bash bin/review-state-test.sh 2>&1 | tail -10
```

Expected: `RESULTS: 9 passed, 0 failed`.

- [ ] **Step 1.5: Run full regression suite**

```
for t in bin/*-test.sh; do
  TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash "$t" >/dev/null 2>&1 \
    && printf 'PASS %s\n' "$t" \
    || printf 'FAIL %s\n' "$t"
done
```

Expected: every line PASS.

- [ ] **Step 1.6: Commit**

```
git add bin/review-state.sh bin/review-state-test.sh
git commit -m "$(cat <<'EOF'
feat(ENG-50): review-state helper for last-review-state Linear comment

bin/review-state.sh defines bootstrap_review_state, update_review_state,
and read_review_state. The body format is a marker line plus a single
JSON line {sha, last_processed_approval_at, last_processed_cr_at};
nulls are valid for any field. Source-able and sentinel-guarded for
testing and orchestrator CLI use.

Foundational for ENG-50's β-shaped poll gating.
EOF
)"
```

---

## Task 2 — `bin/review-poll.sh` helper

**depends_on:** [1]

**Files:**
- Create: `bin/review-poll.sh`
- Create: `bin/review-poll-test.sh`

- [ ] **Step 2.1: Write the failing test first**

Create `bin/review-poll-test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# ENG-50: review_should_dispatch returns truthy when PR state has changed
# since last-review-state, falsy otherwise.
set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

_TEST_TARGET="$(mktemp -d -t twinning-rpoll-target.XXXXXX)"
_TEST_STUB="$(mktemp -d -t twinning-rpoll-stub.XXXXXX)"
case "$_TEST_TARGET" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
case "$_TEST_STUB"   in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
trap 'rm -rf "$_TEST_TARGET" "$_TEST_STUB"' EXIT

mkdir -p "$_TEST_TARGET/.pipeline-config"
cat > "$_TEST_TARGET/.pipeline-config/config.json" <<'JSON'
{"project":{"slug":"test-slug"},"orchestrator":{"paused":false}}
JSON
export TARGET_REPO="$_TEST_TARGET"

# Stub gh: emit canned PR view JSON from $GH_PR_VIEW_JSON env var.
cat > "$_TEST_STUB/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") printf '%s\n' "${GH_PR_VIEW_JSON:-{\"commits\":[],\"reviews\":[]\}}" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/gh"

# Stub linear.sh get-comments to return a configurable last-review-state.
COMMENTS_FIXTURE="$_TEST_STUB/comments.json"
printf '[]' > "$COMMENTS_FIXTURE"
cat > "$_TEST_STUB/linear.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  get-comments) cat "$COMMENTS_FIXTURE" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/linear.sh"

# Helper to inject a last-review-state into the fixture.
set_last_review_state() {
  local sha="$1" approval_at="$2" cr_at="$3"
  local body
  body=$(printf '<!-- pipeline-state: last-review-state -->\n\n{"sha":%s,"last_processed_approval_at":%s,"last_processed_cr_at":%s}\n' \
    "$([[ -z "$sha" ]] && printf 'null' || printf '"%s"' "$sha")" \
    "$([[ -z "$approval_at" ]] && printf 'null' || printf '"%s"' "$approval_at")" \
    "$([[ -z "$cr_at" ]] && printf 'null' || printf '"%s"' "$cr_at")")
  jq -nc --arg b "$body" '[{id:"c1",createdAt:"2026-04-30T09:00:00Z",body:$b}]' > "$COMMENTS_FIXTURE"
}

ORIG_PATH="$PATH"
PATH="$_TEST_STUB:$PATH"
export PATH

# shellcheck source=common.sh
source "$SCRIPT_DIR_REAL/common.sh"
# shellcheck source=review-state.sh
source "$SCRIPT_DIR_REAL/review-state.sh"
# shellcheck source=review-poll.sh
source "$SCRIPT_DIR_REAL/review-poll.sh"
SCRIPT_DIR="$_TEST_STUB"

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# ─── Case A: bootstrap (no last-review-state) → truthy ────────────────
printf '[]' > "$COMMENTS_FIXTURE"
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[]}' \
  review_should_dispatch ENG-510 stub-branch && rc=0 || rc=$?
[[ "$rc" == 0 ]] \
  && ok "Case A: bootstrap → dispatch" \
  || nope "Case A" "rc=$rc"

# ─── Case B: HEAD SHA differs from last-review-state.sha → truthy ─────
set_last_review_state "old1234" "" ""
GH_PR_VIEW_JSON='{"commits":[{"oid":"new5678"}],"reviews":[]}' \
  review_should_dispatch ENG-511 stub-branch && rc=0 || rc=$?
[[ "$rc" == 0 ]] \
  && ok "Case B: SHA differs → dispatch" \
  || nope "Case B" "rc=$rc"

# ─── Case C: new APPROVED on current HEAD (newer than processed) → truthy ─
set_last_review_state "abc1234" "2026-04-29T10:00:00Z" ""
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[{"author":{"login":"alice"},"state":"APPROVED","commit_id":"abc1234","submittedAt":"2026-04-30T11:00:00Z"}]}' \
  review_should_dispatch ENG-512 stub-branch && rc=0 || rc=$?
[[ "$rc" == 0 ]] \
  && ok "Case C: new approval on HEAD → dispatch" \
  || nope "Case C" "rc=$rc"

# ─── Case D: new CHANGES_REQUESTED on current HEAD → truthy ───────────
set_last_review_state "abc1234" "" "2026-04-29T10:00:00Z"
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[{"author":{"login":"alice"},"state":"CHANGES_REQUESTED","commit_id":"abc1234","submittedAt":"2026-04-30T11:00:00Z"}]}' \
  review_should_dispatch ENG-513 stub-branch && rc=0 || rc=$?
[[ "$rc" == 0 ]] \
  && ok "Case D: new CR on HEAD → dispatch" \
  || nope "Case D" "rc=$rc"

# ─── Case E: APPROVED but on old SHA (HEAD has moved) → truthy (SHA differs) ─
set_last_review_state "abc1234" "2026-04-29T10:00:00Z" ""
GH_PR_VIEW_JSON='{"commits":[{"oid":"new5678"}],"reviews":[{"author":{"login":"alice"},"state":"APPROVED","commit_id":"abc1234","submittedAt":"2026-04-30T11:00:00Z"}]}' \
  review_should_dispatch ENG-514 stub-branch && rc=0 || rc=$?
[[ "$rc" == 0 ]] \
  && ok "Case E: approval on old SHA but HEAD moved → dispatch (SHA path)" \
  || nope "Case E" "rc=$rc"

# ─── Case F: nothing changed → falsy ──────────────────────────────────
set_last_review_state "abc1234" "2026-04-30T11:00:00Z" ""
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[{"author":{"login":"alice"},"state":"APPROVED","commit_id":"abc1234","submittedAt":"2026-04-30T11:00:00Z"}]}' \
  review_should_dispatch ENG-515 stub-branch && rc=0 || rc=$?
[[ "$rc" != 0 ]] \
  && ok "Case F: nothing changed → idle" \
  || nope "Case F" "rc=$rc (expected nonzero)"

# ─── Case G: APPROVED already processed (submittedAt <= last_processed) → falsy ─
set_last_review_state "abc1234" "2026-04-30T11:00:00Z" ""
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[{"author":{"login":"alice"},"state":"APPROVED","commit_id":"abc1234","submittedAt":"2026-04-30T10:00:00Z"}]}' \
  review_should_dispatch ENG-516 stub-branch && rc=0 || rc=$?
[[ "$rc" != 0 ]] \
  && ok "Case G: approval older than last_processed → idle" \
  || nope "Case G" "rc=$rc (expected nonzero)"

# ─── Case H: bot-only review on current HEAD → falsy ──────────────────
set_last_review_state "abc1234" "" ""
GH_PR_VIEW_JSON='{"commits":[{"oid":"abc1234"}],"reviews":[{"author":{"login":"twinning-pipeline[bot]"},"state":"COMMENTED","commit_id":"abc1234","submittedAt":"2026-04-30T11:00:00Z"}]}' \
  review_should_dispatch ENG-517 stub-branch && rc=0 || rc=$?
[[ "$rc" != 0 ]] \
  && ok "Case H: bot-only review → idle (non-bot filter)" \
  || nope "Case H" "rc=$rc (expected nonzero)"

PATH="$ORIG_PATH"
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
```

- [ ] **Step 2.2: Run the test, verify it FAILS**

```
chmod +x bin/review-poll-test.sh
bash bin/review-poll-test.sh 2>&1 | tail -5
```

Expected: error sourcing `bin/review-poll.sh` (file doesn't exist yet).

- [ ] **Step 2.3: Implement `bin/review-poll.sh`**

Create `bin/review-poll.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# ENG-50: review-poll — orchestrator's gate for whether to dispatch the
# review agent. Consults `gh pr view` (HEAD SHA + most recent non-bot
# review) against last-review-state to decide.
#
# Returns 0 (dispatch) when:
#   - No last-review-state exists yet (bootstrap).
#   - Current HEAD SHA != last-review-state.sha.
#   - Most recent non-bot APPROVED review is on current HEAD AND
#     submittedAt > last_processed_approval_at.
#   - Most recent non-bot CHANGES_REQUESTED review is on current HEAD AND
#     submittedAt > last_processed_cr_at.
# Returns 1 (idle) otherwise.

set -euo pipefail
_RP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$_RP_SCRIPT_DIR/common.sh"
# shellcheck source=review-state.sh
source "$_RP_SCRIPT_DIR/review-state.sh"

SCRIPT_DIR="${SCRIPT_DIR:-$_RP_SCRIPT_DIR}"

review_should_dispatch() {
  local issue="$1" branch="$2"
  [[ -n "$issue" && -n "$branch" ]] \
    || die "review_should_dispatch: usage <issue> <branch>"

  # Bootstrap path: no last-review-state → dispatch.
  local state
  state="$(read_review_state "$issue" 2>/dev/null || printf '')"
  [[ -z "$state" ]] && return 0

  # Read PR view: HEAD SHA + most recent non-bot review.
  local pr_view
  pr_view="$(gh pr view "$branch" --json commits,reviews 2>/dev/null || printf '{}')"
  [[ -z "$pr_view" || "$pr_view" == "{}" ]] && return 0  # PR query failed; dispatch defensively.

  local head_sha state_sha
  head_sha="$(jq -r '.commits[-1].oid // empty' <<<"$pr_view")"
  state_sha="$(jq -r '.sha // empty' <<<"$state")"

  # Case B: HEAD SHA differs (new commits since last review).
  if [[ -n "$head_sha" && "$head_sha" != "$state_sha" ]]; then
    return 0
  fi

  # Most recent non-bot review (filter out [bot] logins).
  local nonbot_review
  nonbot_review="$(jq -c '
    [.reviews[]? | select(.author.login | test("\\[bot\\]$") | not)]
    | sort_by(.submittedAt) | last // empty' <<<"$pr_view")"
  [[ -z "$nonbot_review" || "$nonbot_review" == "null" ]] && return 1  # no non-bot review; idle.

  local nb_state nb_commit nb_at
  nb_state="$(jq -r '.state // ""'      <<<"$nonbot_review")"
  nb_commit="$(jq -r '.commit_id // ""' <<<"$nonbot_review")"
  nb_at="$(jq -r '.submittedAt // ""'   <<<"$nonbot_review")"

  # Approval on current HEAD AND newer than last_processed_approval_at → dispatch.
  if [[ "$nb_state" == "APPROVED" && "$nb_commit" == "$head_sha" ]]; then
    local last_app
    last_app="$(jq -r '.last_processed_approval_at // ""' <<<"$state")"
    if [[ -z "$last_app" || "$nb_at" > "$last_app" ]]; then
      return 0
    fi
  fi

  # CHANGES_REQUESTED on current HEAD AND newer than last_processed_cr_at → dispatch.
  if [[ "$nb_state" == "CHANGES_REQUESTED" && "$nb_commit" == "$head_sha" ]]; then
    local last_cr
    last_cr="$(jq -r '.last_processed_cr_at // ""' <<<"$state")"
    if [[ -z "$last_cr" || "$nb_at" > "$last_cr" ]]; then
      return 0
    fi
  fi

  return 1
}

export -f review_should_dispatch

# Sentinel — runnable as a CLI for ad-hoc inspection.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  [[ $# -eq 2 ]] || die "usage: review-poll.sh <issue> <branch>"
  if review_should_dispatch "$1" "$2"; then
    printf 'dispatch\n'
    exit 0
  else
    printf 'idle\n'
    exit 1
  fi
fi
```

- [ ] **Step 2.4: Run the test, verify PASS**

```
chmod +x bin/review-poll.sh
bash bin/review-poll-test.sh 2>&1 | tail -15
```

Expected: `RESULTS: 8 passed, 0 failed`.

- [ ] **Step 2.5: Run full regression suite**

```
for t in bin/*-test.sh; do
  TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash "$t" >/dev/null 2>&1 \
    && printf 'PASS %s\n' "$t" \
    || printf 'FAIL %s\n' "$t"
done
```

Expected: every line PASS.

- [ ] **Step 2.6: Commit**

```
git add bin/review-poll.sh bin/review-poll-test.sh
git commit -m "$(cat <<'EOF'
feat(ENG-50): review-poll helper for cheap dispatch gating

bin/review-poll.sh defines review_should_dispatch <issue> <branch>:
returns 0 (dispatch) on bootstrap, new commits since last review, or
new non-bot APPROVED/CHANGES_REQUESTED on current HEAD; returns 1
(idle) otherwise. Filters bot-authored reviews via [bot]-suffix login
test. Source-able and sentinel-guarded.

Used by poll.sh (next commit) to gate review dispatch.
EOF
)"
```

---

## Task 3 — `poll.sh` integration

**depends_on:** [2]

**Files:**
- Modify: `bin/poll.sh::_poll_classify_labels` (add stage:reviewing branch)
- Modify: `bin/poll-slot-test.sh` (add gating-integration cases)

- [ ] **Step 3.1: Add the failing test cases to `poll-slot-test.sh`**

Read the top 80 lines of `bin/poll-slot-test.sh` first to understand its scaffolding. Append these cases BEFORE the file's final summary `printf` block.

```bash
# ─── ENG-50: stage:reviewing dispatch gating via review_should_dispatch ──
# Stub review-poll.sh: review_should_dispatch returns based on
# $REVIEW_SHOULD_DISPATCH env var (0 → truthy/dispatch, 1 → falsy/idle).
cat > "$STUB_DIR/review-poll.sh" <<'SH'
review_should_dispatch() { return "${REVIEW_SHOULD_DISPATCH:-0}"; }
export -f review_should_dispatch
SH

# linear.sh stub already returns gitBranchName for get-issue (verify by
# reading existing stub) — augment if needed.
# Most existing poll-slot-test.sh stubs return the issue id as branch name.

# Case ENG-50-A: stage:reviewing with REVIEW_SHOULD_DISPATCH=0 → advanceable=true.
labels='[{"name":"stage:reviewing"}]'
labels_json="$labels"
REVIEW_SHOULD_DISPATCH=0 class="$(_poll_classify_labels "ENG-590" "$labels_json")"
adv="$(jq -r '.advanceable' <<<"$class")"
slot="$(jq -r '.slot' <<<"$class")"
if [[ "$adv" == "true" && "$slot" == "hold" ]]; then
  pass_at "ENG-50: stage:reviewing + dispatch=true → hold/advanceable"
else
  fail_at "ENG-50: stage:reviewing + dispatch=true" "got slot=$slot adv=$adv"
fi

# Case ENG-50-B: stage:reviewing with REVIEW_SHOULD_DISPATCH=1 → advanceable=false.
REVIEW_SHOULD_DISPATCH=1 class="$(_poll_classify_labels "ENG-591" "$labels_json")"
adv="$(jq -r '.advanceable' <<<"$class")"
slot="$(jq -r '.slot' <<<"$class")"
if [[ "$adv" == "false" && "$slot" == "hold" ]]; then
  pass_at "ENG-50: stage:reviewing + dispatch=false → hold/idle"
else
  fail_at "ENG-50: stage:reviewing + dispatch=false" "got slot=$slot adv=$adv"
fi

# Case ENG-50-C: non-reviewing stage unchanged (sanity).
labels='[{"name":"stage:implementing"}]'
labels_json="$labels"
class="$(_poll_classify_labels "ENG-592" "$labels_json")"
adv="$(jq -r '.advanceable' <<<"$class")"
if [[ "$adv" == "true" ]]; then
  pass_at "ENG-50: stage:implementing unchanged (default branch advanceable)"
else
  fail_at "ENG-50: stage:implementing default branch" "got adv=$adv"
fi
```

The above assumes `pass_at`/`fail_at` exist in `poll-slot-test.sh` — confirm by reading the test file's helper definitions. If the helpers have different names, adapt.

- [ ] **Step 3.2: Run, verify FAILS**

```
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash bin/poll-slot-test.sh 2>&1 | grep -E 'ENG-50|RESULTS' | tail -10
```

Expected: at least Case ENG-50-B fails (the new branch doesn't exist yet — `_poll_classify_labels` falls through to the default and returns `advanceable=true`).

- [ ] **Step 3.3: Add the stage:reviewing branch in `_poll_classify_labels`**

In `bin/poll.sh::_poll_classify_labels`, find the existing `else` branch (around line 234-235):

```bash
  else
    class='{"slot":"hold","advanceable":true}'
  fi
```

Replace with a new `elif` for `stage:reviewing`, keeping the existing default as the final else:

```bash
  elif [[ "$(_has_label stage:reviewing)" == "true" ]]; then
    # ENG-50: gate review dispatch on observable PR state.
    # Read branch from Linear; consult review_should_dispatch.
    local _rp_branch
    _rp_branch="$(bash "$SCRIPT_DIR/linear.sh" get-issue "$ident" 2>/dev/null \
      | jq -r '.data.issue.gitBranchName // empty' 2>/dev/null || true)"
    if [[ -z "$_rp_branch" ]]; then
      # No branch resolvable — fail open (dispatch as before).
      class='{"slot":"hold","advanceable":true}'
    else
      # shellcheck source=review-poll.sh
      source "$SCRIPT_DIR/review-poll.sh"
      if review_should_dispatch "$ident" "$_rp_branch"; then
        class='{"slot":"hold","advanceable":true}'
      else
        class='{"slot":"hold","advanceable":false}'
      fi
    fi
  else
    class='{"slot":"hold","advanceable":true}'
  fi
```

`SCRIPT_DIR` is set near the top of `bin/poll.sh` and inherits into `_poll_classify_labels`. The source happens lazily — only for `stage:reviewing` issues, only once per tick (subsequent calls in the same shell skip the source via shell function caching).

- [ ] **Step 3.4: Run, verify PASS**

```
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash bin/poll-slot-test.sh 2>&1 | grep -E 'ENG-50|RESULTS' | tail -10
```

Expected: 3 ENG-50 cases pass; final RESULTS shows 0 failed.

- [ ] **Step 3.5: Run full regression suite**

```
for t in bin/*-test.sh; do
  TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash "$t" >/dev/null 2>&1 \
    && printf 'PASS %s\n' "$t" \
    || printf 'FAIL %s\n' "$t"
done
```

Expected: every line PASS.

- [ ] **Step 3.6: Commit**

```
git add bin/poll.sh bin/poll-slot-test.sh
git commit -m "$(cat <<'EOF'
feat(ENG-50): gate stage:reviewing dispatch via review_should_dispatch

_poll_classify_labels gains a new branch for stage:reviewing issues:
reads the branch name via linear.sh get-issue, sources review-poll.sh,
calls review_should_dispatch. Returns advanceable=true on dispatch
signal (new commits, new approval, new CR), advanceable=false when
nothing has changed. Fail-open: missing branch falls through to the
default advanceable=true (preserves prior behavior for misconfigured
issues).

Token cost: zero on idle ticks (no agent dispatch when nothing has
changed); one gh pr view + one linear.sh get-issue per stage:reviewing
issue per tick (cheap).
EOF
)"
```

---

## Task 4 — `apply_transition` bootstrap call

**depends_on:** [1]

**Files:**
- Modify: `bin/verdict-handler.sh::apply_transition` (add bootstrap call in to==reviewing block)
- Modify: `bin/verdict-handler-test.sh` (add bootstrap-call case)

- [ ] **Step 4.1: Add the failing test case in `verdict-handler-test.sh`**

Append before the final summary `printf` block. Use the existing scaffolding (STUB_DIR, _VH_SCRIPT_DIR override).

```bash
# ─── ENG-50: apply_transition to==reviewing calls bootstrap_review_state ──
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/config.json" <<'JSON'
{
  "orchestrator": {"paused": false},
  "linear": {"native_states": {"in_review": "In Review", "done": "Done"}}
}
JSON
ORIG_CONFIG="$CONFIG"
CONFIG="$STUB_DIR/config.json"
export CONFIG

# Stub review-state.sh CLI — capture bootstrap calls.
BOOTSTRAP_CALLS="$STUB_DIR/bootstrap-calls.log"
: > "$BOOTSTRAP_CALLS"
cat > "$STUB_DIR/review-state.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  bootstrap) printf '%s\\n' "\$2" >> "$BOOTSTRAP_CALLS" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/review-state.sh"

# Stub gh (PR-create hook short-circuits on dry-run anyway).
cat > "$STUB_DIR/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") printf '0' ;;  # no PR exists, but DRY_RUN short-circuits before create
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/gh"

ORIG_PATH="$PATH"
PATH="$STUB_DIR:$PATH"
ORIG_VH_DIR="$_VH_SCRIPT_DIR"
_VH_SCRIPT_DIR="$STUB_DIR"

apply_transition "ENG-595" "ui" "reviewing" "" >/dev/null 2>&1 || true

PATH="$ORIG_PATH"
_VH_SCRIPT_DIR="$ORIG_VH_DIR"
CONFIG="$ORIG_CONFIG"
export PATH CONFIG

if grep -qE '^ENG-595$' "$BOOTSTRAP_CALLS"; then
  pass_at "ENG-50 bootstrap: to==reviewing calls bootstrap_review_state"
else
  fail_at "ENG-50 bootstrap" "captured: $(cat "$BOOTSTRAP_CALLS" 2>/dev/null || echo '<empty>')"
fi

# Sanity: to != reviewing does NOT call bootstrap.
: > "$BOOTSTRAP_CALLS"
PATH="$STUB_DIR:$PATH"
_VH_SCRIPT_DIR="$STUB_DIR"
apply_transition "ENG-596" "implementing" "ui" "" >/dev/null 2>&1 || true
PATH="$ORIG_PATH"
_VH_SCRIPT_DIR="$ORIG_VH_DIR"

if [[ -s "$BOOTSTRAP_CALLS" ]]; then
  fail_at "ENG-50 bootstrap: to!=reviewing must NOT call bootstrap" \
    "captured: $(cat "$BOOTSTRAP_CALLS")"
else
  pass_at "ENG-50 bootstrap: to!=reviewing does not call bootstrap"
fi
```

- [ ] **Step 4.2: Run, verify FAILS**

```
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash bin/verdict-handler-test.sh 2>&1 | grep -E 'ENG-50|RESULTS' | tail -5
```

Expected: `FAIL: ENG-50 bootstrap: to==reviewing calls bootstrap_review_state` (the call doesn't exist yet).

- [ ] **Step 4.3: Add the bootstrap call in `apply_transition`**

In `bin/verdict-handler.sh::apply_transition`, find the `to == reviewing` PR-create hook (added in ENG-49 Task 5, around line 169 area). After the entire PR-create block (right before the `if [[ -n "$side_labels" ]]` block), insert:

```bash
  # ENG-50: bootstrap last-review-state for poll.sh's review_should_dispatch.
  # Idempotent — overwrites any previous state to all-null on each entry
  # to stage:reviewing (loopback re-entries get a fresh state per tick).
  if [[ "$to" == "reviewing" ]]; then
    bash "$_VH_SCRIPT_DIR/review-state.sh" bootstrap "$issue" || \
      log "verdict-handler: review-state bootstrap failed for $issue (continuing)"
  fi
```

The `|| log` keeps `apply_transition` resilient — bootstrap failure logs but doesn't abort the transition.

- [ ] **Step 4.4: Run, verify PASS**

```
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash bin/verdict-handler-test.sh 2>&1 | grep -E 'ENG-50|RESULTS' | tail -5
```

Expected: 2 ENG-50 cases pass; final RESULTS shows 0 failed.

- [ ] **Step 4.5: Run full regression suite**

```
for t in bin/*-test.sh; do
  TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash "$t" >/dev/null 2>&1 \
    && printf 'PASS %s\n' "$t" \
    || printf 'FAIL %s\n' "$t"
done
```

Expected: every line PASS.

- [ ] **Step 4.6: Commit**

```
git add bin/verdict-handler.sh bin/verdict-handler-test.sh
git commit -m "$(cat <<'EOF'
feat(ENG-50): apply_transition bootstraps last-review-state on to==reviewing

The orchestrator now writes an initial all-null last-review-state
Linear comment whenever apply_transition advances a stage to
reviewing (forward path: ui → reviewing). This guarantees the
bootstrap comment exists before the first dispatch into review.

Bootstrap failure logs but does not abort the transition (resilience
matches the PR-create hook's pattern from ENG-49 Task 5).

Loopback re-entry overwrites the bootstrap to all-null. The
review-rejection counter remains the safety valve for cycle escalation.
EOF
)"
```

---

## Task 5 — `run-stage.sh` post-dispatch hook + `_fresh_wait_reason` allowlist

**depends_on:** [1]

**Files:**
- Modify: `bin/run-stage.sh::_fresh_wait_reason` (line 304: expand stage allowlist from `build` to `build|review`)
- Modify: `bin/run-stage.sh` (add post-dispatch update_review_state hook for stage=reviewing)
- Modify: `bin/run-stage-test.sh` (add cases covering wait-allowlist + post-dispatch update)

- [ ] **Step 5.1: Add failing test cases in `run-stage-test.sh`**

Read `bin/run-stage-test.sh` first to find the right spot for new cases (typically a numbered `case-N` block before the final summary). Append these new cases.

```bash
# ─── ENG-50 case A: _fresh_wait_reason accepts review stage ───────────
# Fresh pipeline-wait: awaiting-approval comment exists for stage=review.
# _fresh_wait_reason should return "awaiting-approval" instead of failing.
fresh_comments='[{"id":"c1","createdAt":"2026-04-30T12:00:00Z","body":"<!-- pipeline-wait: awaiting-approval -->\n\nReviewed commit abc1234."}]'
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  get-comments) printf '%s' '$fresh_comments' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"
SCRIPT_DIR="$STUB_DIR"
reason="$(_fresh_wait_reason "ENG-580" "review" 2>/dev/null || printf '')"
[[ "$reason" == "awaiting-approval" ]] \
  && pass_at "ENG-50 _fresh_wait_reason: review stage accepted" \
  || fail_at "ENG-50 _fresh_wait_reason review" "got: '$reason'"

# Sanity: build still works.
reason="$(_fresh_wait_reason "ENG-581" "build" 2>/dev/null || printf '')"
[[ "$reason" == "awaiting-approval" ]] \
  && pass_at "ENG-50 _fresh_wait_reason: build still works" \
  || fail_at "ENG-50 _fresh_wait_reason build" "got: '$reason'"

# Other stages still rejected.
reason="$(_fresh_wait_reason "ENG-582" "implement" 2>/dev/null || printf '')"
[[ -z "$reason" ]] \
  && pass_at "ENG-50 _fresh_wait_reason: implement still rejected" \
  || fail_at "ENG-50 _fresh_wait_reason implement" "got: '$reason' (expected empty)"

# ─── ENG-50 case B: post-review-dispatch update_review_state called ───
# Stub review-state.sh CLI to capture update calls.
UPDATE_CALLS="$STUB_DIR/update-state-calls.log"
: > "$UPDATE_CALLS"
cat > "$STUB_DIR/review-state.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  update) printf 'update\\t%s\\t%s\\t%s\\t%s\\n' "\$2" "\$3" "\$4" "\$5" >> "$UPDATE_CALLS" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/review-state.sh"

# Stub gh: pretend HEAD SHA = abc1234, no reviews.
cat > "$STUB_DIR/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") printf '%s' '{"commits":[{"oid":"abc1234"}],"reviews":[]}' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB_DIR/gh"

# Test the helper directly. The function name is _post_review_dispatch_update;
# it reads gh pr view + writes via review-state.sh update.
ORIG_PATH="$PATH"
PATH="$STUB_DIR:$PATH"
SCRIPT_DIR="$STUB_DIR"
_post_review_dispatch_update "ENG-585" "stub-branch" >/dev/null 2>&1 || true
PATH="$ORIG_PATH"

# Verify the update call was made with sha=abc1234.
captured="$(cat "$UPDATE_CALLS")"
if [[ "$captured" == *"ENG-585"* && "$captured" == *"abc1234"* ]]; then
  pass_at "ENG-50 _post_review_dispatch_update writes current SHA"
else
  fail_at "ENG-50 _post_review_dispatch_update" "captured: $captured"
fi
```

- [ ] **Step 5.2: Run, verify FAILS**

```
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash bin/run-stage-test.sh 2>&1 | grep -E 'ENG-50|RESULTS' | tail -10
```

Expected: at least the `review stage accepted` and `_post_review_dispatch_update writes current SHA` cases fail (the changes don't exist yet).

- [ ] **Step 5.3: Expand `_fresh_wait_reason` stage allowlist**

In `bin/run-stage.sh::_fresh_wait_reason` (line 304), change:

From:
```bash
  [[ "$stage" == "build" ]] || return 1
```

To:
```bash
  case "$stage" in
    build|review) ;;
    *) return 1 ;;
  esac
```

This expansion permits `review` to use the same wait-marker pattern as `build`. The reason allowlist (line 326: `awaiting-approval|awaiting-ci`) already includes the only review-relevant reason (`awaiting-approval`); no change needed there.

- [ ] **Step 5.4: Add `_post_review_dispatch_update` helper to `run-stage.sh`**

Add this helper near the other private helpers in `bin/run-stage.sh` (e.g., near `_fresh_wait_reason` and `_handle_wait`). Place it right after `_handle_wait`:

```bash
# ENG-50: write last-review-state to Linear after a successful review-stage
# dispatch. Captures the just-observed PR state (HEAD SHA + most recent
# non-bot review's submittedAt per state). Called from the success and
# wait-success branches in main(). Stage-gated by the caller.
_post_review_dispatch_update() {
  local issue="$1" branch="$2"
  [[ -n "$issue" && -n "$branch" ]] || { log "post-review-update: missing args; skipping"; return 0; }

  local pr_view
  pr_view="$(gh pr view "$branch" --json commits,reviews 2>/dev/null || printf '{}')"

  local head_sha last_app last_cr
  head_sha="$(jq -r '.commits[-1].oid // empty' <<<"$pr_view")"
  last_app="$(jq -r '
    [.reviews[]? | select(.author.login | test("\\[bot\\]$") | not)
                 | select(.state == "APPROVED")]
    | sort_by(.submittedAt) | last | .submittedAt // empty' <<<"$pr_view")"
  last_cr="$(jq -r '
    [.reviews[]? | select(.author.login | test("\\[bot\\]$") | not)
                 | select(.state == "CHANGES_REQUESTED")]
    | sort_by(.submittedAt) | last | .submittedAt // empty' <<<"$pr_view")"

  bash "$SCRIPT_DIR/review-state.sh" update "$issue" "$head_sha" "$last_app" "$last_cr" \
    || log "post-review-update: review-state update failed for $issue (continuing)"
}
```

- [ ] **Step 5.5: Wire `_post_review_dispatch_update` into the main flow**

In `bin/run-stage.sh::main`, the post-dispatch flow has multiple exit branches. Add `_post_review_dispatch_update` at the appropriate spots:

**Spot 1 — Wait success branch** (currently around line 626-640, inside the `if _handle_wait ...; then` block):

Find the existing block:
```bash
      if _handle_wait "$ident" "$stage" "$_wait_reason"; then
        # ENG-45 review-major-1: wait-exit must propagate ENG-26 D-008 cost flags...
        ...
        log "stage $stage wait on $ident (reason=$_wait_reason)"
        exit 0
      fi
```

Add immediately before the `log` line:
```bash
        # ENG-50: capture last-review-state on review wait-success.
        if [[ "$stage" == "review" ]]; then
          local _rp_branch
          _rp_branch="$(bash "$SCRIPT_DIR/linear.sh" get-issue "$ident" 2>/dev/null \
            | jq -r '.data.issue.gitBranchName // empty' 2>/dev/null || true)"
          [[ -n "$_rp_branch" ]] && _post_review_dispatch_update "$ident" "$_rp_branch" || true
        fi
```

**Spot 2 — Verdict-handler success branch** (around line 765-770, inside the `case "$vh_rc" in 0)` arm):

Find the existing block:
```bash
    0)
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "success" "$duration" "verdict=transitioned" \
        "${cost_flags[@]+"${cost_flags[@]}"}"
      log "stage $stage complete for $ident (verdict-handler transitioned)"
      # Success path: clear any prior failure state + skip labels.
      rm -f "$(issue_dir "$ident")/issue-state.json" 2>/dev/null || true
```

Add immediately after the `log` line and before the `rm -f`:
```bash
      # ENG-50: capture last-review-state on review-stage transitions
      # (advance to qa OR loopback to implementing). Both are successful
      # exits where the agent observed the PR state and acted on it.
      if [[ "$stage" == "review" ]]; then
        local _rp_branch
        _rp_branch="$(bash "$SCRIPT_DIR/linear.sh" get-issue "$ident" 2>/dev/null \
          | jq -r '.data.issue.gitBranchName // empty' 2>/dev/null || true)"
        [[ -n "$_rp_branch" ]] && _post_review_dispatch_update "$ident" "$_rp_branch" || true
      fi
```

- [ ] **Step 5.6: Run, verify PASS**

```
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash bin/run-stage-test.sh 2>&1 | grep -E 'ENG-50|RESULTS' | tail -10
```

Expected: 4 ENG-50 cases pass; final RESULTS shows 0 failed.

- [ ] **Step 5.7: Run full regression suite**

```
for t in bin/*-test.sh; do
  TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash "$t" >/dev/null 2>&1 \
    && printf 'PASS %s\n' "$t" \
    || printf 'FAIL %s\n' "$t"
done
```

Expected: every line PASS.

- [ ] **Step 5.8: Commit**

```
git add bin/run-stage.sh bin/run-stage-test.sh
git commit -m "$(cat <<'EOF'
feat(ENG-50): run-stage post-review hook + wait allowlist for review

run-stage.sh _fresh_wait_reason now accepts both build and review
stages (was build-only); awaiting-approval is already in the reason
allowlist. _handle_wait remains stage-agnostic.

New private helper _post_review_dispatch_update reads gh pr view and
writes last-review-state via bin/review-state.sh update. Called from
both the wait-success branch and the verdict-handler-success branch
when stage=review, so last-review-state always reflects the just-seen
PR state after any review dispatch.

Together with Tasks 1-4, this completes the orchestrator side of
β: cheap dispatch gating in poll.sh, bootstrap on transition,
state update post-dispatch.
EOF
)"
```

---

## Task 6 — `AGENT_PROMPTS.md §5` rewrite + content tests

**depends_on:** [5]

**Files:**
- Modify: `AGENT_PROMPTS.md` (§5 Review Agent fenced block: Preflight, Decision A/B/C/D, rubric item 1, Output)
- Modify: `bin/agent-prompts-content-test.sh` (add §5 invariants)

- [ ] **Step 6.1: Read §5 to find exact line boundaries**

```
grep -n "^## " /Users/rajatgoyal/code/twinning-harness/AGENT_PROMPTS.md | head -10
```

§5 starts at the `## 5. Review Agent` header. Note the start line and the `## 6. QA Agent` line that follows; §5's fenced block is bounded between them. The opening ` ``` ` fence is the first column-0 fence after `## 5.`; the closing fence is the last column-0 fence before `## 6.`.

CRITICAL: After all edits, run `grep -c '^```' AGENT_PROMPTS.md` and confirm the total count is unchanged (preserve the global fence count).

- [ ] **Step 6.2: Add the failing content-test cases**

In `bin/agent-prompts-content-test.sh`, append after the existing §3/§4/§8 assertions (before the final RESULTS print):

```bash
# ─── ENG-50: §5 invariants ────────────────────────────────────────────
s5="$(section_body "## 5. Review Agent")"

if printf '%s\n' "$s5" | grep -qF 'Preflight (MANDATORY'; then
  ok "§5 contains 'Preflight (MANDATORY'"
else
  nope "§5 contains 'Preflight (MANDATORY'" "phrase missing"
fi

if printf '%s\n' "$s5" | grep -qF 'gh pr review --approve'; then
  nope "§5 lacks 'gh pr review --approve'" "phrase present"
else
  ok "§5 lacks 'gh pr review --approve'"
fi

if printf '%s\n' "$s5" | grep -qF 'gh pr review --request-changes'; then
  nope "§5 lacks 'gh pr review --request-changes'" "phrase present"
else
  ok "§5 lacks 'gh pr review --request-changes'"
fi

if printf '%s\n' "$s5" | grep -qF 'gh pr review --comment'; then
  ok "§5 contains 'gh pr review --comment'"
else
  nope "§5 contains 'gh pr review --comment'" "phrase missing"
fi

if printf '%s\n' "$s5" | grep -qF '<!-- pipeline-wait: awaiting-approval -->'; then
  ok "§5 contains '<!-- pipeline-wait: awaiting-approval -->'"
else
  nope "§5 contains '<!-- pipeline-wait: awaiting-approval -->'" "marker missing"
fi
```

- [ ] **Step 6.3: Run, verify FAILS**

```
bash bin/agent-prompts-content-test.sh 2>&1 | tail -15
```

Expected: at least the "lacks `gh pr review --approve`" and "lacks `gh pr review --request-changes`" cases fail (current §5 still uses these). The "contains 'Preflight'" and the wait-marker cases also fail.

- [ ] **Step 6.4: Edit §5 — add Preflight section**

In `AGENT_PROMPTS.md` §5, immediately after the existing `Read these files first` block (find the trailing line of that block, typically before the first major review-task section), insert a new "Preflight (MANDATORY)" subsection. Here's the literal block to insert (copy verbatim):

```
Preflight (MANDATORY — determines what kind of dispatch this is):

  1. Read PR HEAD SHA:
       head_sha=$(gh pr view {branch_name} --json commits --jq '.commits[-1].oid')
  2. Read most recent non-bot review and its commit_id + submittedAt:
       gh pr view {branch_name} --json reviews \
         | jq '[.reviews[] | select(.author.login | test("\\[bot\\]$") | not)] | sort_by(.submittedAt) | last'
  3. Read last-review-state from Linear:
       bash .pipeline/bin/linear.sh get-comments {issue_id} \
         | jq '[.[] | select(.body | contains("<!-- pipeline-state: last-review-state -->"))] | last.body'
       Parse the JSON payload {sha, last_processed_approval_at, last_processed_cr_at}.
  4. Branch on comparison:
     a. APPROVED on current HEAD AND submittedAt > last_processed_approval_at:
        → Skip multi-persona review.
        → Write a brief stage-summary file noting: "Human {login} approved
          on commit {sha[:8]}. Advancing to qa."
        → Post <!-- pipeline-stage-summary: reviewing --> verdict marker.
        → Apply pipeline:halted, exit.
     b. CHANGES_REQUESTED on current HEAD AND submittedAt > last_processed_cr_at:
        → Run multi-persona review with the human's CR comments as additional
          input (read via gh pr view --json reviews,comments).
        → Decide: Decision path B (rejection) or Decision path C (wait-marker)
          per the multi-persona findings.
     c. Current HEAD ≠ last-review-state.sha (new commits since last review):
        → Run multi-persona review on the new code.
        → Decide: Decision path B (rejection) or Decision path C (wait-marker).
     d. Otherwise (defensive — should not happen under β's gating):
        → Post <!-- pipeline-wait: awaiting-approval --> with the current SHA.
        → Apply pipeline:halted, exit. Log the unexpected state in the
          stage-summary's Notes section.
```

- [ ] **Step 6.5: Edit §5 — replace Decision path A/B/C with A/B/C/D**

Find the existing `Decision path (apply exactly one):` block in §5 (currently lines ~854-869 of the file). Replace the entire block (from `Decision path (apply exactly one):` through path C's closing description) with:

```
Decision path (apply exactly one):

  A. Premise failure (brainstorm was wrong) — UNCHANGED.
     - Apply Linear label `pipeline:premise-failure`.
     - Post the `premise_failure` marker comment.
     - Post `<!-- pipeline-rejection: reviewing -->` AND
            `<!-- pipeline-rejection-target: brainstorming -->`.
     - Apply pipeline:halted, exit. Orchestrator handles loop-back.

  B. Changes requested (rewritten for ENG-50 / β).
     - Post a consolidated COMMENTED-state review with all findings via:
         gh pr review {pr_number} --comment --body "<full summary>"
       Body contains severity-prefixed, "path/to/file.ext:LINE"-anchored
       findings per the comment-quality rubric (item 1 reworded — see below).
     - Post Linear consolidated review summary via:
         bash .pipeline/bin/linear.sh add-or-update-comment \
           "completion/reviewing/{issue_id}" {issue_id} "<body>"
       Body mirrors the gh pr review summary plus persona verdicts and
       comment-quality self-lint score.
     - Bump counter: `bash .pipeline/bin/guards.sh bump {issue_id} review_rejection`.
     - Post `<!-- pipeline-rejection: reviewing -->` AND
            `<!-- pipeline-rejection-target: implementing -->`.
     - Apply pipeline:halted, exit. Orchestrator transitions reviewing → implementing.

  C. Clean review, awaiting human approval (NEW under ENG-50 / β).
     - Post a consolidated COMMENTED-state review via:
         gh pr review {pr_number} --comment --body "<summary>"
       Summary: "Reviewed commit {sha[:8]}. N personas: PASS. 0 critical,
       0 major. Awaiting human Code Owner approval." Plus any minor/nit
       observations as severity-prefixed bullets.
     - Post Linear consolidated review summary via add-or-update-comment
       with sig `completion/reviewing/{issue_id}`.
     - Post `<!-- pipeline-wait: awaiting-approval -->` with body that
       explicitly names the reviewed SHA. NO `tick_at:` line (the
       orchestrator only re-dispatches review on observable PR state
       change under ENG-50's β gating, so consecutive wait markers
       reflect different SHAs and won't dedup-collide).
     - Do NOT apply pipeline:halted. Do NOT post a verdict marker.
       Issue idles at stage:reviewing until poll.sh's
       review_should_dispatch detects a state change (new commits,
       new approval, or new change-request).
     - Exit clean.

  D. Approval just landed (NEW under ENG-50 / β — preflight branch (a) outcome).
     - As described in Preflight step 4(a).

The agent does NOT post `gh pr review --approve` or
`gh pr review --request-changes` under any path. The COMMENTED state
(`gh pr review --comment`) is the only review API call permitted —
GitHub allows COMMENTED reviews from the PR author.
```

- [ ] **Step 6.6: Edit §5 — review-comment quality rubric item 1**

In §5's "Review-comment quality rubric" section, find item 1 (currently `file:line anchor via gh pr review comment mechanism.`) and replace with:

```
  1. `file:line` anchor as an explicit `path/to/file.ext:LINE` reference at the
     start of the comment body, after the severity token. Example:
       `[major] src/handler.ts:42 — Mutating the request body...`
     The path:line text is the anchor; gh pr review --comment posts the body
     as a top-level review comment (not inline-anchored on GitHub's UI).
```

Items 2-4 (severity token, concrete suggestion, "why" rationale) stay unchanged.

- [ ] **Step 6.7: Edit §5 — Output section**

Find the existing `Output:` section in §5 (mentions `gh pr review verdict posted on the PR`). Replace the bullet about the gh pr review verdict with:

```
- Per-finding PR review comments via `gh pr review --comment`
  (severity-prefixed, path:line-anchored in body, with concrete suggestion +
  "why" rationale).
- Consolidated Linear review summary as a `completion/reviewing/{issue_id}`
  add-or-update-comment.
- Stage-summary file at {stage_summary_path} (per the Stage summary comment
  format contract — abbreviated on path D when no review work was done).
- Verdict marker per Decision path (A premise-failure → rejection-to-brainstorm,
  B changes-requested → rejection-to-implementing, C wait-for-approval →
  no verdict marker, D approval-detected → stage-summary).
- Do NOT post `gh pr review --approve` or `gh pr review --request-changes`.
  The agent does not approve or request-changes via GitHub's review API;
  humans do.
```

Keep the rest of the Output section unchanged.

- [ ] **Step 6.8: Verify fence count unchanged**

```
grep -c '^```' /Users/rajatgoyal/code/twinning-harness/AGENT_PROMPTS.md
```

Should equal 20 (same as the post-ENG-49 baseline). If it differs, you accidentally introduced or removed a column-0 ` ``` ` fence inside §5 — find and fix.

- [ ] **Step 6.9: Run agent-prompts-content-test, verify PASS**

```
bash bin/agent-prompts-content-test.sh
```

Expected: all assertions pass; final `RESULTS: 12 passed, 0 failed` (was 7 after ENG-49; +5 new §5 cases = 12).

- [ ] **Step 6.10: Verify dispatch-test contract still passes**

```
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash bin/dispatch-test.sh 2>&1 | grep -E 'Gap-7|RESULTS' | tail -10
```

Expected: prompt↔allowlist contract for review still passes. `gh pr review` is still in §5 (used for `--comment`) and is still in the review allowlist — contract satisfied.

- [ ] **Step 6.11: Run full regression suite + render-prompt smoke**

```
for t in bin/*-test.sh; do
  TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash "$t" >/dev/null 2>&1 \
    && printf 'PASS %s\n' "$t" \
    || printf 'FAIL %s\n' "$t"
done
```

Expected: every line PASS.

ALSO verify the §5 fence-count contract:

```
awk '
  /^## [0-9]+\. / {
    if (in_section) {
      if (fence_count != 2) { printf "FAIL §%s: %d fences\n", section, fence_count > "/dev/stderr"; exit_code = 1 }
      else                  { printf "PASS §%s: 2 fences\n", section }
    }
    section=$0; sub(/^## /, "", section); in_section=1; fence_count=0; next
  }
  /^```/ && in_section { fence_count++ }
  END {
    if (in_section) {
      if (fence_count != 2) { printf "FAIL §%s: %d fences\n", section, fence_count > "/dev/stderr"; exit_code = 1 }
      else                  { printf "PASS §%s: 2 fences\n", section }
    }
    exit exit_code
  }
' AGENT_PROMPTS.md
```

Expected: all 9 stage sections PASS with 2 fences each.

- [ ] **Step 6.12: Commit**

```
git add AGENT_PROMPTS.md bin/agent-prompts-content-test.sh
git commit -m "$(cat <<'EOF'
feat(ENG-50): rewrite §5 review prompt for human-approval contract

§5 now starts with a Preflight section that branches on observable
PR state: human approval detected → advance directly; new SHA → full
review; new CR → re-review with CR input; new state otherwise → wait.

Decision path A (premise failure) preserved unchanged.
Decision path B (changes requested) rewritten: gh pr review --comment
for findings (NOT --request-changes), Linear summary, rejection marker
to implementing, halt label. Counter bumped via guards.sh.
Decision path C (clean review) NEW: gh pr review --comment for
summary, Linear summary, pipeline-wait: awaiting-approval marker.
NO halt, NO verdict marker — orchestrator's β gating idles the issue.
Decision path D (approval detected) NEW: brief stage-summary, verdict
marker for advance.

Review-comment quality rubric item 1 reworded: path:line anchor in
body text (not gh pr review native inline annotations — Option α).

Output section drops gh pr review verdict; replaces with the
COMMENTED-state contract.

agent-prompts-content-test.sh asserts §5 lacks --approve and
--request-changes, contains --comment, contains Preflight (MANDATORY,
contains the wait-marker.

Closes ENG-50 / ENG-49 Gap #8.
EOF
)"
```

---

## Pre-PR final verification

- [ ] **Step F.1: Full-suite test from clean state**

```
for t in bin/*-test.sh; do
  TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key bash "$t" >/dev/null 2>&1 \
    && printf 'PASS %s\n' "$t" \
    || { printf 'FAIL %s\n' "$t"; bash "$t" 2>&1 | tail -20; }
done
```

Expected: every line PASS.

- [ ] **Step F.2: Fence-count contract verification**

```
awk '/^## [0-9]+\. / { if (in_section) { if (fence_count != 2) { exit 1 } else print "PASS §" section } section=$0; in_section=1; fence_count=0; next } /^```/ && in_section { fence_count++ } END { if (in_section && fence_count != 2) exit 1 }' AGENT_PROMPTS.md
```

Expected: 9 PASS lines + exit 0.

- [ ] **Step F.3: Open the PR**

```
git push -u origin eng-50-review-stage-reframe
gh pr create --title "feat(ENG-50): reframe review stage — agent reviews, human approves" --body "$(cat <<'EOF'
## Summary

Closes ENG-49 Gap #8 by reframing rather than identity infrastructure. The review agent reviews and posts findings; humans approve via GitHub UI; the orchestrator detects approval and advances `reviewing → qa` automatically.

Design doc: `docs/brainstorms/2026-04-30-eng-50-review-stage-reframe-design.md`.
Plan doc: `docs/plans/2026-04-30-eng-50-review-stage-reframe.md`.

## Linear

- ENG-50 — Reframe review stage (closes ENG-49 Gap #8)

## Changes

- Backend: 6 commits — review-state helper; review-poll helper; poll.sh integration; apply_transition bootstrap; run-stage post-review hook + wait-allowlist; §5 prompt rewrite + content tests.
- Frontend: N/A — backend-only stack.

## Test plan

- [x] Every \`bin/*-test.sh\` passes (with TARGET_REPO env).
- [x] AGENT_PROMPTS.md fence-count contract preserved (9/9 sections at 2 fences each).
- [ ] Manual (post-merge): take next harness-self ticket through reviewing. Verify (a) bot posts gh pr review --comment with findings; (b) bot does NOT post --approve or --request-changes; (c) on human approval via GitHub UI, orchestrator advances to qa within 5 min; (d) on critical-finding rejection, loopback to implementing fires correctly.

## Notes

- Loopback semantics preserved: agent can still fire `pipeline-rejection: reviewing` for critical/major issues without human round-trip.
- `pipeline-wait: awaiting-approval` is informational — verdict-handler ignores it (already established for build's wait pattern).
- No new GitHub App identities, no PAT, no second App. The reframe eliminates the need for separate identities.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Failure Mode → Test Map

| ID | Failure mode | Test |
|---|---|---|
| F-001 | `bootstrap_review_state` writes wrong sig | `bin/review-state-test.sh` case-1 |
| F-002 | `update_review_state` loses null semantics | `bin/review-state-test.sh` case-2 |
| F-003 | `read_review_state` returns stale comment | `bin/review-state-test.sh` case-3 |
| F-004 | `read_review_state` on missing comment crashes | `bin/review-state-test.sh` case-4 |
| F-005 | `review_should_dispatch` always returns dispatch | `bin/review-poll-test.sh` Cases F, G |
| F-006 | `review_should_dispatch` ignores SHA changes | `bin/review-poll-test.sh` Case B |
| F-007 | `review_should_dispatch` doesn't filter bot reviews | `bin/review-poll-test.sh` Case H |
| F-008 | `review_should_dispatch` accepts approvals on stale SHA | `bin/review-poll-test.sh` Case E |
| F-009 | `_poll_classify_labels` doesn't gate stage:reviewing | `bin/poll-slot-test.sh` ENG-50-B |
| F-010 | `apply_transition` skips bootstrap on ui→reviewing | `bin/verdict-handler-test.sh` ENG-50 |
| F-011 | `apply_transition` calls bootstrap on non-reviewing transition | `bin/verdict-handler-test.sh` ENG-50 negative |
| F-012 | `_fresh_wait_reason` rejects review stage | `bin/run-stage-test.sh` ENG-50 case A |
| F-013 | `_post_review_dispatch_update` doesn't write current SHA | `bin/run-stage-test.sh` ENG-50 case B |
| F-014 | §5 still instructs `gh pr review --approve` | `bin/agent-prompts-content-test.sh` ENG-50 |
| F-015 | §5 still instructs `gh pr review --request-changes` | `bin/agent-prompts-content-test.sh` ENG-50 |
| F-016 | §5 missing Preflight section | `bin/agent-prompts-content-test.sh` ENG-50 |
| F-017 | §5 fence count regressed | Step F.2 fence-count awk script |
| F-018 | Allowlist contract broken by §5 changes | `bin/dispatch-test.sh` Gap-7 contract (existing) |

## api-contract

N/A — bash harness, no FE↔BE API surface.

## Risks (per task)

| Task | Risk | Mitigation |
|---|---|---|
| 1 | review-state.sh body format brittle to future Linear comment edits | Body marker is well-defined; `read_review_state` regex tolerates whitespace |
| 2 | `gh pr view` rate limit on busy ticks | Single-issue throughput is well under 5000/hr; revisit if concurrent reviews become routine |
| 3 | Sourcing review-poll.sh inside _poll_classify_labels adds startup time | Sourced lazily only for stage:reviewing issues; subsequent calls reuse loaded function |
| 4 | Bootstrap overwrites loopback last-review-state | Intentional — review_rejection counter is the safety valve for cycle escalation |
| 5 | _fresh_wait_reason allowlist expansion exposes review to wait-budget escalation | Same escalation budget applies to build today; behavior consistency is desired |
| 6 | §5 fence-count contract regression | Step 6.8 + Step F.2 explicitly verify |

## Acceptance criteria

| AC | Validated by |
|---|---|
| AC1 — Review agent never invokes --approve or --request-changes | Task 6 agent-prompts-content-test cases |
| AC2 — review_should_dispatch returns falsy when nothing has changed | Task 2 review-poll-test Cases F, G |
| AC3 — update_review_state writes the canonical Linear comment | Task 1 review-state-test cases |
| AC4 — poll.sh skips dispatch when review_should_dispatch is falsy | Task 3 poll-slot-test ENG-50-B |
| AC5 — Verdict-marker protocol unchanged | Existing verdict-handler-test + verdict-adversarial-test |
| AC6 — End-to-end: bot-authored PR + human approval → orchestrator advances reviewing → qa | Manual; first ENG-50-post-merge harness-self ticket |
