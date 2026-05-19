---
linear: ENG-153
date: 2026-05-19
topic: guards.sh — require --reason on bump (fail-closed); emit reason + count/threshold in body
---

# Plan — guards.sh: require `--reason` on `bump` (fail-closed); emit reason + count/threshold in body (ENG-153)

## Anti-anchoring check

- **Problem (operator-perspective):** "Counter-bump comments in Linear read `<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh.` — no reason, no current count, no trip-threshold. An operator scanning the thread cannot tell why the counter advanced or how close it is to halting." Brainstorm §1 names this exactly.
- **Brainstorm framing:** D-001 makes `--reason` required (fail-closed); D-002 grows the marker by one optional `reason-code=<token>` attribute; D-003 registers the metric event in `bin/pipeline-events.json`; D-004 specifies the populated 3-line body; D-005 updates the readers that anchor on `-->`; D-006 updates the 4 live callers; D-007 covers the test surface. The reframing matches the problem 1:1.
- **Proportionality:** ~20 lines added to `bin/guards.sh::bump`, ~3 line-edits inside the same file's reader jq filters, 1 regex extension in `bin/status.sh`, 4 caller-update sites (one-liners), 1 JSON-registry insertion in `bin/pipeline-events.json`, ~7 new test cases. No new file, no new helper, no new dependency. Proportional — small change to surface a clearer marker shape. Proceed.

## Goal

`bash bin/guards.sh bump <issue> <counter>` fail-closes with a clear error unless `--reason "<text>"` is supplied; on success the posted body explicitly states the human-readable reason, the running count, and the trip threshold, and carries `<!-- meta: metric name=<counter>[ reason-code=<token>] -->` (optional closed-vocab attribute) with the schema registered under `bin/pipeline-events.json::events.metric`.

## Assumption Inventory

Format: `[verified|assumed]` ITEM — `path:line` reference.

**branch-base freshness:** `HEAD..origin/main` empty at plan time (`origin/main = ca36cc6`). No Task 0 rebase needed; content anchors are load-bearing per "Edit-boundary keys" in case a sibling commit lands during implement.

### Verified — code paths quoted from current tree

- `[verified]` `bin/guards.sh:157-164` — current `bump()` signature accepts 2 positional args only and writes the literal body:
  ```bash
  bump() {
    local ident="$1" counter="$2"
    case "$counter" in
      review_rejection|gotcha_triggered|learned_rule_renewal|qa_rejection|implement_rejection) ;;
      *) die "unknown counter: $counter" ;;
    esac
    bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "<!-- meta: metric name=$counter --> Counter bumped by guards.sh."
  }
  ```
  Content anchors: the `case "$counter" in` line (~line 159) and the literal `Counter bumped by guards.sh.` (~line 163) are unique in the file.

- `[verified]` `bin/guards.sh:58-68` — `count_marker()` uses literal `contains($m)` against the bare-form marker:
  ```bash
  jq -r \
    --arg m  "<!-- meta: metric name=$marker -->" \
    --arg m_legacy "<!-- pipeline-metric: $marker -->" \
    '[.data.issue.comments.nodes[]? | .body | select(contains($m) or contains($m_legacy))] | length' <<<"$resp"
  ```
  Content anchor: the unique string `count_marker() {` at line 58.

- `[verified]` `bin/guards.sh:81-100` — `count_marker_since_last_operator_resume()` has TWO `contains($m)` matchers (no-resume branch at ~line 92, post-resume branch at ~line 98), each anchored on the bare-form marker. Content anchor: the unique function name `count_marker_since_last_operator_resume`.

- `[verified]` `bin/guards.sh:106-110` — `check()` reads thresholds via `config_get`. Same lookups `bump()` will reuse for the `<threshold>` body slot. Counter→config-key mapping verified at lines 106-110.

- `[verified]` `bin/guards.sh:113-117` — `check()` defaults each threshold to 2 when `config_get` returns `null` or empty. `bump()` must apply the same default (parity).

- `[verified]` `bin/guards.sh:42-51` — usage-comment block. Current line 50: `#   guards.sh bump <issue_id> <counter_name>`. Content anchor: the unique line `#   guards.sh bump <issue_id> <counter_name>`.

- `[verified]` `bin/run-stage.sh:1702` — SEVERE scope-violation caller:
  ```bash
  bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection || true
  classify_failure "$ident" "$stage" "skip-until-human-acts" \
    "SEVERE scope violation on $branch: $(tr '\n' ' ' <<<"$severe_patch")" 21 3
  ```
  Content anchor: the unique two-line block whose first line is the bump and whose second-line continues `classify_failure ... "SEVERE scope violation on $branch:`. `|| true` is present.

- `[verified]` `bin/run-stage.sh:1708-1714` — other-rc scope-check caller:
  ```bash
  bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection || true
  local scope_detail
  scope_detail="$(_compose_scope_check_detail "$scope_out")"
  classify_failure "$ident" "$stage" "skip-until-code-changes" \
    "scope-check rc=$scope_rc: ${scope_detail:-no diagnostic captured}" \
    21 "$scope_rc"
  ```
  Content anchor: the unique two-line block whose second line starts `local scope_detail`. `|| true` is present.

- `[verified]` `bin/run-stage.sh:1750` — noop-implementation caller:
  ```bash
  bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection || true
  classify_failure "$ident" "$stage" "skip-until-human-acts" \
    "implementing dispatch produced zero new commits (branch HEAD unchanged from $_HEAD_PRE_DISPATCH). ..." \
    30
  ```
  Content anchor: the unique `classify_failure ... "implementing dispatch produced zero new commits` string. `|| true` is present.

- `[verified]` `bin/scan-gotcha-trailers.sh:38` — gotcha-trailer caller, **NO `|| true` suffix**:
  ```bash
  bash "$SCRIPT_DIR/guards.sh" bump "$issue_id" gotcha_triggered
  ```
  Content anchor: the line is inside a `while IFS= read -r gid; do ... done <<<"$hits"` loop (~lines 35-40). The unique surrounding token is `bumping gotcha_triggered on $issue_id (gotcha=$gid)` on line 37.

- `[verified]` `AGENT_PROMPTS.md:1318` — reviewer agent path-B clause:
  ```
  - Bump counter: `bash .pipeline/bin/guards.sh bump {issue_id} review_rejection`.
  ```
  Content anchor: the unique line `- Bump counter: \`bash .pipeline/bin/guards.sh bump {issue_id} review_rejection\`.`. **The brainstorm missed this.** After ENG-153 the reviewer agent's bash invocation would die-loud at the bump call, breaking review loopback. This is a P0 plan-completeness expansion — addressed in Backend Task 5.

- `[verified]` `AGENT_PROMPTS.md:1555` — qa agent path-B clause:
  ```
  - Bump counter: `.pipeline/bin/guards.sh bump {issue_id} qa_rejection`.
  ```
  Content anchor: the unique line `- Bump counter: \`.pipeline/bin/guards.sh bump {issue_id} qa_rejection\`.`. Same scope-expansion concern as the reviewer clause; addressed in Backend Task 5.

- `[verified]` `bin/status.sh:326-330` — dashboard regex + capture, anchored on the literal `-->` immediately after `name=X`:
  ```jq
  | select(.body | test("<!-- meta: metric name=[a-z_-]+ -->|<!-- pipeline-metric: [a-z_-]+ -->"))
  | [.createdAt,
     (if (.body | test("<!-- meta: metric name=[a-z_-]+ -->"))
        then (.body | capture("<!-- meta: metric name=(?<m>[a-z_-]+) -->").m)
  ```
  Content anchor: the literal regex `<!-- meta: metric name=[a-z_-]+ -->` is unique to this file (occurs twice within the same function — both updated by Task 4).

- `[verified]` `bin/classify-failure.sh:194` — emits a multi-attribute metric marker already:
  ```bash
  comment_body="$(printf '<!-- meta: metric name=transient-retry stage=%s attempt=%d -->\n\n...'
  ```
  Confirms the meta-family marker has tolerated trailing k=v attributes in production for months (no reader breakage observed because no `count_marker`-style reader greps for `transient-retry`). Pre-existing precedent for D-002's design — readers that DO grep `metric name=X -->` literally would have broken on this writer if they cared about `transient-retry`, which none do.

- `[verified]` `bin/pipeline-events.json:1-124` — current event registry contains `events` keys for `verdict`, `transition`, `decision` only. Top-level arrays include `verdict_results`, `halt_reasons`, `wait_reasons`, `fail_targets`, `pivot_targets`, `decision_actions`, `decision_gates`, `meta_kinds`, `stages`. **No `events.metric` entry exists.**

- `[verified]` `bin/pipeline-events.json:44-52` — the `meta_kinds` array lists `dedup, metric, evidence, reapplied, forensic, dispatch, breadcrumb`. Confirms `metric` is already an established meta-family kind — this plan's schema entry formalises it under `events.metric.linear_comment`.

- `[verified]` `bin/pipeline.sh:107-258` — `_validate_event_payload` + `_render_body` walk the registry's `events.<event>.linear_comment` parametric on `<event>`. The functions ignore unknown schema keys (`jq -r ... // empty/[]` defaults). Adding `cli_required` as a new schema attribute is back-compat (validator never reads it; orchestrator never invokes it for the metric event — `bin/guards.sh::bump` continues to do its own argv parsing).

- `[verified]` `bin/common.sh:447-455` — `parse_pipeline_marker`'s k=v parser whitespace-splits on `for pair in $rest`. Appending `reason-code=<token>` to a metric marker is correctly parsed (single ASCII-token value, no embedded whitespace). Quoted/spaced values would NOT work, which is why prose `--reason` stays in the comment body, not the marker — D-002.

- `[verified]` `bin/common.sh:720-723` — `config_get()` is `jq -r "$path" "$CONFIG"`. Already returns the literal string `null` on missing key; `bump()` must defensive-default to 2 like `check()` does at `bin/guards.sh:113-117`.

- `[verified]` `bin/guards-test.sh:1-451` — 13 cases. case-16 in `bin/run-stage-test.sh` (NOT in this file) is the only test today that invokes the REAL `guards.sh::bump`. case-1..case-13 here exercise `guards.sh check` only. Adding new cases requires extending the existing source-and-stub pattern; the file's `STUB_DIR` + `FAKE_REPO` infrastructure (lines 27-43) is reusable.

- `[verified]` `bin/run-stage-test.sh:1644-1664` — `case-16 (QA adversarial)` is the ONE existing live `guards.sh::bump` test. Today it asserts `grep -q '<!-- meta: metric name=implement_rejection -->' "$BUMP_CAPTURE"` after `bash "$FAKE_REPO/.pipeline/bin/guards.sh" bump ENG-T16 implement_rejection`. Content anchor: the literal capture pathname `"$STUB_DIR/bump-marker.capture"` is unique. **This case will FAIL after ENG-153 ships** — the bump now dies without `--reason`, AND the grep target `name=implement_rejection -->` would no longer match the new shape if `--reason-code` is supplied. Addressed in Backend Task 6.

- `[verified]` `bin/run-stage-test.sh:406, 430, 469` — three stub-`guards.sh` bump invocations inside `_post_run_stub_for_test`-style heredocs. These invoke `$STUB_DIR/guards.sh` (a mock stub written by the test fixture, NOT the real script), so they do NOT exercise the new fail-closed path. No edit required — confirmed by reading the test scaffold at `bin/run-stage-test.sh:60-95` (`reset_guards_capture` writes a mock that swallows all argv). Recorded for transparency.

- `[verified]` `bin/verdict-handler-test.sh:508-517` — uses two `<!-- meta: metric name=qa_rejection -->` fixtures in a local jq filter (`contains("<!-- meta: metric name=qa_rejection -->")`). Fixture data is BARE-FORM — emitter is the test itself, not `guards.sh::bump`. Reader matches bare-form. Stays green without edit IF the reader matches bare-form too. The proposed regex `name=X( [^>]*)?-->` matches bare-form (the optional group matches the empty string at offset 0). Confirmed.

- `[verified]` `bin/verdict-adversarial-test.sh:158-194` (A10/A10B/A11) — sources `bin/guards.sh` and calls `count_marker_since_last_operator_resume` directly with bare-form `qa_rejection` fixtures. Reader regex must match bare-form for these to stay green. The proposed regex satisfies this.

- `[verified]` `bin/guards-adversarial-test.sh:42-260` — adversarial helpers + 6 cases (A1-A6), all bare-form fixtures. Reader regex updated in `bin/guards.sh` keeps them matching. Stays green without edit.

- `[verified]` `.githooks/pre-commit:88-99` — `KNOWN_BROKEN` allowlist contains only `mutex-test.sh`, `render-pr-body-test.sh`, `render-prompt-slug-test.sh`. Adding no new sibling test means no allowlist edit. The existing `bin/guards-test.sh` and `bin/run-stage-test.sh` are gate-runnable and ENG-153 keeps them so.

### Verified — file/dir existence

- `[verified]` `bin/guards.sh` — modified by Tasks 1, 2.
- `[verified]` `bin/pipeline-events.json` — modified by Task 3.
- `[verified]` `bin/status.sh` — modified by Task 4.
- `[verified]` `bin/run-stage.sh` — modified by Task 5 (3 caller sites).
- `[verified]` `bin/scan-gotcha-trailers.sh` — modified by Task 5 (1 caller site).
- `[verified]` `AGENT_PROMPTS.md` — modified by Task 5 (2 prompt clauses).
- `[verified]` `bin/guards-test.sh` — modified by Task 6 (append `case-bump-1..7`).
- `[verified]` `bin/run-stage-test.sh` — modified by Task 6 (fix case-16).
- `[verified]` `learned-rules/harness/project-profile.md` — **NOT modified.** No new gate-runnable file is added (Tasks 6 extend existing test files). The profile's "Build & test gates" Test command lists existing files; nothing changes.

### Verified — runtime / dependency

- `[verified]` `jq` already used throughout `bin/guards.sh`. No new tooling.
- `[verified]` `bash bin/plan-schema.sh validate` (ENG-122) is the post-dispatch contract; sibling JSON written alongside this plan.

### Assumed — to be verified during implement

- `[assumed]` `count_marker` in `bump()` (D-004 step d) is called BEFORE the wire write. Brainstorm §4 specifies this ordering; verified the helper exists at `bin/guards.sh:58-68` and is callable from within the same file; the call site is new code added by Task 1.

- `[assumed]` Empty `--reason ""` is rejected by the same `[[ -n "$reason" ]]` check that catches the missing-flag case. Brainstorm D-001 specifies this; the `||` chain in `bump` (Task 1 step) enforces it.

- `[assumed]` `bin/linear.sh add-comment "$ident" "$body"` accepts a multi-line `$body` argv string. Existing usage at `bin/classify-failure.sh:188` (`add-or-update-comment "$sig" "$issue" "$comment_body"`) passes multi-line bodies; the call shape works.

## File Structure

### Modified

- `bin/guards.sh` — `bump()` rewrite (Task 1); reader-regex updates in `count_marker` + `count_marker_since_last_operator_resume` two-site (Task 2); usage-comment update (Task 1).
- `bin/pipeline-events.json` — add `metric_reason_codes` array; add `events.metric.linear_comment` schema entry (Task 3).
- `bin/status.sh` — extend dashboard regex + capture to tolerate trailing `reason-code=` attribute (Task 4).
- `bin/run-stage.sh` — pass `--reason ... [--reason-code ...]` to the 3 bump invocations at lines 1702, 1708, 1750 (Task 5).
- `bin/scan-gotcha-trailers.sh` — pass `--reason ... --reason-code gotcha-hit` to the bump at line 38 (Task 5).
- `AGENT_PROMPTS.md` — update reviewer agent clause at line 1318 and qa agent clause at line 1555 to include `--reason "<text>" --reason-code <token>` (Task 5).
- `bin/guards-test.sh` — append `case-bump-1` through `case-bump-7` covering the fail-closed path, the populated body, the reader-regex regression guard, and the schema-reject case (Task 6).
- `bin/run-stage-test.sh` — fix case-16 (bump call + grep both updated for the new argv + new marker shape) (Task 6).

### New

No new files. All edits land in existing files.

### Not modified (called out for transparency)

- `bin/classify-failure.sh:194` — emits `<!-- meta: metric name=transient-retry stage=X attempt=N -->` directly via `bin/linear.sh add-or-update-comment` (does NOT route through `guards.sh::bump`). OUT of scope per brainstorm §5 — refactoring this caller through the schema is a follow-up.
- `bin/run-stage.sh:329, 394, 412, 678` — three other production sites that emit `<!-- meta: metric name=X -->` markers directly (summary_missing, summary_truncated, worktree-mutated-by-agent). All bypass `guards.sh::bump` and continue to write bare-form markers. The reader-regex update in `bin/guards.sh` and `bin/status.sh` is forward-compat (matches both bare and with-attribute forms), so these stay green.
- `bin/verdict-handler-test.sh:508-517`, `bin/verdict-adversarial-test.sh:158-194`, `bin/guards-adversarial-test.sh:42-260` — fixture-based tests that emit bare-form markers as test data. Reader regex update keeps the contains-matches valid. No edit needed.
- `bin/run-stage-test.sh:406, 430, 469` — stub `guards.sh` invocations (NOT the real binary). No edit needed.
- `learned-rules/harness/project-profile.md` — no new gate-runnable test file is added. No edit needed.
- `docs/pipeline-vocabulary.md` — generated by `bin/generate-vocabulary-doc.sh` from `bin/pipeline-events.json`. The implementer should regenerate after Task 3; flagged as a Task 3 step, not a separate file entry.

## API Contract

No new FE↔BE API surface. Harness is Bash-only orchestration (per project profile Stack). The CLI surface this plan touches is `bash bin/guards.sh bump <issue_id> <counter> --reason "<text>" [--reason-code <token>]` — exit code 0 on success, non-zero (via `die`) on missing/empty `--reason` or unknown `--reason-code`. The 4 production callers receive the same string-shape contract.

## Backend Tasks

### Task 1: Rewrite `bin/guards.sh::bump` to require `--reason`, validate `--reason-code`, compose the populated body

- `depends_on: []`
- `touches: bin/guards.sh::bump, bin/guards.sh (usage comment line 50)`
- [ ] Locate the existing `bump()` function. Content anchor: the unique `case "$counter" in` line (~line 159) followed by `review_rejection|gotcha_triggered|learned_rule_renewal|qa_rejection|implement_rejection) ;;` on line 160.
- [ ] Replace the entire function body (lines 157-164) with the new implementation. The new shape:
  ```bash
  bump() {
    local ident="$1" counter="$2"
    shift 2 || true
    case "$counter" in
      review_rejection|gotcha_triggered|learned_rule_renewal|qa_rejection|implement_rejection) ;;
      *) die "unknown counter: $counter" ;;
    esac

    local reason="" reason_code=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --reason)      reason="${2:-}";      shift 2 ;;
        --reason-code) reason_code="${2:-}"; shift 2 ;;
        *) die "bump: unknown flag '$1'" ;;
      esac
    done
    [[ -n "$reason" ]] || die "bump: --reason \"<text>\" required (counter=$counter, ident=$ident)"

    # Defensive marker-injection guard: reject prose payloads containing
    # pipeline- or meta-family marker openers. _classify_comment_body inspects
    # only the first non-blank line for lane attribution, so a marker on a
    # later prose line would slip past the lane fence while still being
    # readable by full-body parsers. Today's callers emit orchestrator-
    # controlled strings — live risk is low — but the one-line guard mirrors
    # _reject_legacy_marker_body's defense-in-depth philosophy.
    case "$reason" in
      *"<!-- pipeline:"*|*"<!-- meta:"*)
        die "bump: --reason contains a pipeline/meta marker opener (rejected to preserve lane-fence semantics)" ;;
    esac

    # Validate --reason-code against the closed-vocab registry if supplied.
    if [[ -n "$reason_code" ]]; then
      local registry="$SCRIPT_DIR/pipeline-events.json"
      local valid
      valid="$(jq -r --arg c "$reason_code" '
        (.metric_reason_codes // []) | index($c) // empty
      ' "$registry" 2>/dev/null || true)"
      [[ -n "$valid" ]] || die "bump: --reason-code '$reason_code' not in metric_reason_codes registry (see bin/pipeline-events.json::metric_reason_codes)"
    fi

    # Pre-bump count from existing markers (excludes the one we are about
    # to write). Local arithmetic — no post-write re-read.
    local existing count
    existing="$(count_marker "$ident" "$counter")"
    count=$((existing + 1))

    # Threshold lookup matches check() at lines 106-110.
    local threshold_key threshold
    case "$counter" in
      review_rejection)     threshold_key="review_rejections_per_feature" ;;
      qa_rejection)         threshold_key="qa_rejections_per_feature" ;;
      implement_rejection)  threshold_key="implement_rejections_per_feature" ;;
      gotcha_triggered)     threshold_key="gotcha_trigger_count" ;;
      learned_rule_renewal) threshold_key="learned_rule_renewals" ;;
    esac
    threshold="$(config_get ".human_checkpoints.require_human_on_threshold.$threshold_key")"
    [[ "$threshold" == "null" || -z "$threshold" ]] && threshold=2

    # Clearing-prose variant per counter family (rejection vs ack-label).
    local trip_clause
    case "$counter" in
      gotcha_triggered)
        trip_clause="Trips at: $threshold/$threshold → halt; cleared by label pipeline:knowledge-reviewed." ;;
      learned_rule_renewal)
        trip_clause="Trips at: $threshold/$threshold → halt; cleared by label pipeline:rule-reviewed." ;;
      *)
        trip_clause="Trips at: $threshold/$threshold within current stage iteration → halt with skip-until-human-acts." ;;
    esac

    # Compose the marker (bare vs with-attribute form).
    local marker
    if [[ -n "$reason_code" ]]; then
      marker="<!-- meta: metric name=$counter reason-code=$reason_code -->"
    else
      marker="<!-- meta: metric name=$counter -->"
    fi

    local body
    body="$(printf 'COUNTER — %s bumped (%d/%d)\nReason: %s\n%s\n\n%s' \
      "$counter" "$count" "$threshold" "$reason" "$trip_clause" "$marker")"

    bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body"
  }
  ```
- [ ] Update the usage-comment line. Content anchor: the unique line `#   guards.sh bump <issue_id> <counter_name>` (~line 50). Replace it with:
  ```
  #   guards.sh bump <issue_id> <counter_name> --reason "<text>" [--reason-code <token>]
  ```
- [ ] Update the `main()` dispatch's die-message at the catch-all. Content anchor: the unique line `*)     die "usage: guards.sh <check|bump> <issue_id> [counter]" ;;` (~line 172). Replace its message with:
  ```
  *)     die "usage: guards.sh check <issue_id> [stage] | guards.sh bump <issue_id> <counter> --reason \"<text>\" [--reason-code <token>]" ;;
  ```
- [ ] DO NOT change `check()` or its helpers; reader updates land in Task 2.

### Task 2: Update marker-reader regexes in `bin/guards.sh` to tolerate trailing attributes

- `depends_on: []`
- `touches: bin/guards.sh::count_marker, bin/guards.sh::count_marker_since_last_operator_resume`
- [ ] Locate `count_marker()`. Content anchor: the unique function-opener line `count_marker() {` (~line 58). The jq filter to update spans ~lines 64-67:
  ```bash
  jq -r \
    --arg m  "<!-- meta: metric name=$marker -->" \
    --arg m_legacy "<!-- pipeline-metric: $marker -->" \
    '[.data.issue.comments.nodes[]? | .body | select(contains($m) or contains($m_legacy))] | length' <<<"$resp"
  ```
- [ ] Replace it with a regex-based matcher tolerating an optional trailing attribute group, AND extend the legacy fallback to keep the bare-form `<!-- pipeline-metric: X -->` working:
  ```bash
  jq -r \
    --arg m_re "<!-- meta: metric name=$marker( [^>]*)?-->" \
    --arg m_legacy "<!-- pipeline-metric: $marker -->" \
    '[.data.issue.comments.nodes[]? | .body | select(test($m_re) or contains($m_legacy))] | length' <<<"$resp"
  ```
- [ ] Locate `count_marker_since_last_operator_resume()`. Content anchor: the unique function-opener line `count_marker_since_last_operator_resume() {` (~line 81). The function contains TWO jq filters (no-resume branch ~line 89-92, post-resume branch ~line 94-98).
- [ ] Update the no-resume branch (~lines 89-92):
  ```bash
  jq -r \
    --arg m_re "<!-- meta: metric name=$marker( [^>]*)?-->" \
    --arg m_legacy "<!-- pipeline-metric: $marker -->" \
    '[.[] | select(.body | test($m_re) or contains($m_legacy))] | length' <<<"$comments"
  ```
- [ ] Update the post-resume branch (~lines 94-98):
  ```bash
  jq -r \
    --arg m_re "<!-- meta: metric name=$marker( [^>]*)?-->" \
    --arg m_legacy "<!-- pipeline-metric: $marker -->" \
    --arg t "$last_ts" \
    '[.[] | select(.createdAt > $t) | select(.body | test($m_re) or contains($m_legacy))] | length' <<<"$comments"
  ```
- [ ] The regex `name=$marker( [^>]*)?-->` matches the bare form (optional group matches the empty string when `-->` immediately follows `name=X`) AND any whitespace-prefixed trailing attribute group (e.g. ` reason-code=scope-violation` or ` stage=implementing attempt=1`). Anchored to the `<!-- meta:` envelope so prose-quoted substrings outside the marker do not false-positive.
- [ ] DO NOT touch the legacy `<!-- pipeline-metric: X -->` matcher — pre-ENG-60 shape is bare-form only and stays a literal `contains()`.

### Task 3: Add `metric_reason_codes` registry + `events.metric.linear_comment` schema to `bin/pipeline-events.json`

- `depends_on: []`
- `touches: bin/pipeline-events.json, docs/pipeline-vocabulary.md (regenerated)`
- [ ] Locate the top-level `meta_kinds` array. Content anchor: the unique line `"meta_kinds": [` (~line 44). The array contains `"dedup", "metric", "evidence", "reapplied", "forensic", "dispatch", "breadcrumb"`.
- [ ] AFTER the `"meta_kinds"` array's closing `]` and BEFORE the `"stages"` array's opening line `"stages": [` (~line 53), insert two new top-level keys:
  ```json
    "metric_names": [
      "review_rejection",
      "qa_rejection",
      "implement_rejection",
      "gotcha_triggered",
      "learned_rule_renewal",
      "transient-retry",
      "summary_missing",
      "summary_truncated",
      "worktree-mutated-by-agent"
    ],
    "metric_reason_codes": [
      "scope-violation-severe",
      "scope-violation",
      "noop-implementation",
      "gotcha-hit"
    ],
  ```
  Trailing comma on `]` of `metric_reason_codes` is JSON-syntactic since `"stages"` follows. Validate with `jq -e . bin/pipeline-events.json` after the edit.
- [ ] Locate the `events.decision` block's closing `}` (the last event in the file). Content anchor: the unique line `"dedup_sig": null` inside the `events.decision.linear_comment` block (~line 120). The block ends with `}` `}` `}` (the inner `linear_comment` close, the `decision` close, and the `events` close, all on consecutive lines).
- [ ] AFTER `events.decision`'s closing `}` (the second `}`, which closes `decision`) and BEFORE the `events` object's closing `}` (the third), insert the new `metric` entry — making `events.decision` no longer the last key. The shape:
  ```json
      },
      "metric": {
        "linear_comment": {
          "body_shape": "<!-- meta: metric name=<name>[ reason-code=<reason-code>] -->",
          "writer_lane": "orchestrator",
          "required": ["name"],
          "cli_required": ["reason"],
          "optional": ["reason-code"],
          "field_registry": {
            "name": "metric_names",
            "reason-code": "metric_reason_codes"
          },
          "dedup_sig": null
        }
      }
  ```
- [ ] `cli_required` is a NEW schema key introduced by ENG-153 to declare CLI-layer-required fields (free prose, lives in the comment body, NOT in the marker). `_validate_event_payload` in `bin/pipeline.sh` ignores unknown schema keys — verified at `bin/pipeline.sh:137-141` and `:155-160` (the "known fields" computation reads `required[]` + `optional[]` + `required_by_arm` + `field_registry` keys; `cli_required` is not in that union, so it's a no-op for the existing validator). The key is documentation-only today; consumed by `bin/guards.sh::bump`'s argv layer (Task 1).
- [ ] Verify the file is valid JSON: `jq -e . bin/pipeline-events.json >/dev/null` MUST exit 0.
- [ ] Regenerate `docs/pipeline-vocabulary.md`: `bash bin/generate-vocabulary-doc.sh` (the existing generator already walks `events.<name>.linear_comment` — confirmed in brainstorm §3). Commit the regenerated file alongside the registry edit.

### Task 4: Extend `bin/status.sh` dashboard regex + capture to tolerate `reason-code=` suffix

- `depends_on: []`
- `touches: bin/status.sh (the events-section jq filter, ~lines 320-334)`
- [ ] Locate the dashboard filter. Content anchor: the unique line ``      | select(.body | test("<!-- meta: metric name=[a-z_-]+ -->|<!-- pipeline-metric: [a-z_-]+ -->"))`` (~line 326). The block spans ~lines 323-334.
- [ ] Update the regex inside the `test()` and `capture()` calls to extend `name=[a-z_-]+` with the optional trailing-attribute group `( [^>]*)?` before `-->`. Three sites within the same jq filter:
  - Line ~326 (the outer `test(...)`):
    ```jq
    | select(.body | test("<!-- meta: metric name=[a-z_-]+( [^>]*)?-->|<!-- pipeline-metric: [a-z_-]+ -->"))
    ```
  - Line ~328 (the inner `if` test branch):
    ```jq
    (if (.body | test("<!-- meta: metric name=[a-z_-]+( [^>]*)?-->"))
    ```
  - Line ~329 (the corresponding `capture`):
    ```jq
       then (.body | capture("<!-- meta: metric name=(?<m>[a-z_-]+)( [^>]*)?-->").m)
    ```
- [ ] The capture group `(?<m>[a-z_-]+)` continues to extract ONLY the counter name (without the attribute group), so the dashboard's per-row label stays clean (`implement_rejection`, not `implement_rejection reason-code=scope-violation`). Operator visibility into `reason-code` post-MVP is the OQ-4 retrospective follow-up; today the dashboard reads the counter name only.
- [ ] DO NOT change the legacy `<!-- pipeline-metric: X -->` branch — bare-form only by definition.

### Task 5: Update all 4 live `guards.sh bump` callers + 2 AGENT_PROMPTS.md clauses

- `depends_on: [1]`
- `touches: bin/run-stage.sh (3 sites), bin/scan-gotcha-trailers.sh (1 site), AGENT_PROMPTS.md (2 prompt clauses)`
- [ ] **`bin/run-stage.sh:1702`** — SEVERE scope-violation caller. Content anchor: the unique two-line block whose second line is `classify_failure "$ident" "$stage" "skip-until-human-acts" \` immediately followed by `"SEVERE scope violation on $branch: $(tr '\n' ' ' <<<"$severe_patch")" 21 3`. Replace the `bump` line:
  ```bash
  bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection \
    --reason "SEVERE scope violation on $branch: $(tr '\n' ' ' <<<"$severe_patch")" \
    --reason-code scope-violation-severe || true
  ```
- [ ] **`bin/run-stage.sh:1708`** — other-rc scope-check caller. Content anchor: the unique two-line block whose first line is the bump and whose second line is `local scope_detail`. Replace the `bump` line:
  ```bash
  bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection \
    --reason "scope-check rc=$scope_rc: ${scope_detail:-no diagnostic captured}" \
    --reason-code scope-violation || true
  ```
  NOTE: `$scope_detail` is computed two lines BELOW the current bump. The plan re-orders by computing `scope_detail` BEFORE the bump (move the existing `local scope_detail` + `scope_detail="$(_compose_scope_check_detail "$scope_out")"` lines to immediately precede the bump). Re-check the surrounding control flow during implement to confirm no other consumer reads `scope_detail` between the bump and the `classify_failure` call.
- [ ] **`bin/run-stage.sh:1750`** — noop-implementation caller. Content anchor: the unique two-line block whose first line is the bump and whose second line is `classify_failure "$ident" "$stage" "skip-until-human-acts" \` immediately followed by `"implementing dispatch produced zero new commits (branch HEAD unchanged from $_HEAD_PRE_DISPATCH). ...`. Replace the `bump` line:
  ```bash
  bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection \
    --reason "implementing dispatch produced zero new commits (branch HEAD unchanged from $_HEAD_PRE_DISPATCH)" \
    --reason-code noop-implementation || true
  ```
- [ ] **`bin/scan-gotcha-trailers.sh:38`** — gotcha-trailer caller. Content anchor: the unique three-line block whose first line is `log "scan-gotcha-trailers: bumping gotcha_triggered on $issue_id (gotcha=$gid)"` and whose second is the bump. NO `|| true` on this caller — adding it now is OUT of scope (callers' existing error-handling semantics preserved per brainstorm A14/B-1). Replace the `bump` line:
  ```bash
  bash "$SCRIPT_DIR/guards.sh" bump "$issue_id" gotcha_triggered \
    --reason "Gotcha-hit: $gid trailer found on commit on $branch" \
    --reason-code gotcha-hit
  ```
- [ ] **`AGENT_PROMPTS.md:1318`** — reviewer agent path-B. Content anchor: the unique line ``     - Bump counter: `bash .pipeline/bin/guards.sh bump {issue_id} review_rejection`.``. Replace with:
  ```
       - Bump counter: `bash .pipeline/bin/guards.sh bump {issue_id} review_rejection --reason "<one-line summary of the rejection cause referencing critical/major findings>"`.
         (Omit `--reason-code` — no token registered for review-side rejection yet; the prose reason is enough for the audit trail.)
  ```
- [ ] **`AGENT_PROMPTS.md:1555`** — qa agent path-B. Content anchor: the unique line ``     - Bump counter: `.pipeline/bin/guards.sh bump {issue_id} qa_rejection`.``. Replace with:
  ```
       - Bump counter: `bash .pipeline/bin/guards.sh bump {issue_id} qa_rejection --reason "<one-line summary of the genuine-failure cause (P0 / non-flake)>"`.
         (Omit `--reason-code` — no token registered for qa-side rejection yet; the prose reason is enough for the audit trail.)
  ```
- [ ] DO NOT add a `--reason-code` registry entry for reviewer/qa rejection paths in this PR — the closed vocab seed (D-003) intentionally covers only the 4 mechanically-emitted codes from `run-stage.sh` + `scan-gotcha-trailers.sh`. Reviewer/qa codes are deferred to the OQ-4 retrospective follow-up.
- [ ] DO NOT modify `AGENT_PROMPTS.md` Section H2 numbering, fence count, or the per-section fenced-block boundary (`render-prompt.sh` dies if fence count != 2).

### Task 6: Test cases — append 7 to `bin/guards-test.sh`; fix the live bump assertion in `bin/run-stage-test.sh::case-16`

- `depends_on: [1, 2, 3]`
- `touches: bin/guards-test.sh, bin/run-stage-test.sh::case-16`
- [ ] AFTER the closing line of the existing case-13 block in `bin/guards-test.sh` (~line 447) and BEFORE the `# ── Summary ──` header (~line 449), append 7 new cases. Each case follows the established pattern: write a per-case `linear.sh` stub under `$FAKE_REPO/.pipeline/bin/linear.sh`, invoke `$GUARDS` with `bump` + flags, capture rc + posted body (via the existing `BUMP_CAPTURE` pattern in `bin/run-stage-test.sh:1644-1651` — adapt for this file), assert.

  **case-bump-1 (AC#1 — fail-closed without `--reason`).**
  Set up a no-op `linear.sh` stub (the bump dies BEFORE the wire write, so the stub need not handle `add-comment`). Invoke `bash "$GUARDS" bump ENG-T153A implement_rejection`. Assert `rc != 0` AND `grep -q -- '--reason' <<<"$out"` (the die-message contains the flag name).

  **case-bump-2 (AC#3 + AC#4 — populated body with `--reason` and `--reason-code`).**
  Stub `linear.sh` to write its `add-comment` `$3` argv to a `$BUMP_CAPTURE` file. Invoke `bash "$GUARDS" bump ENG-T153B implement_rejection --reason "SEVERE scope violation on x.sh" --reason-code scope-violation-severe`. Assert `rc == 0` AND the captured body contains all four substrings (each as a separate `grep -q` against `"$BUMP_CAPTURE"`):
    - `'Reason: SEVERE scope violation on x.sh'`
    - `'(1/2)'`
    - `'Trips at: 2/2'`
    - `'<!-- meta: metric name=implement_rejection reason-code=scope-violation-severe -->'`

  **case-bump-3 (AC#3 — populated body without `--reason-code`).**
  Same as case-bump-2 minus `--reason-code`. Assert the captured body contains `'<!-- meta: metric name=implement_rejection -->'` (bare-form marker) AND `'Reason: <text>'`.

  **case-bump-4 (D-003 schema-reject — unknown reason-code dies loud).**
  Invoke `bash "$GUARDS" bump ENG-T153D implement_rejection --reason "x" --reason-code bogus-token`. Assert `rc != 0` AND `grep -q 'metric_reason_codes' <<<"$out"`.

  **case-bump-5 (D-004 counter math — pre-existing markers bump count).**
  Stub `linear.sh::get-comments` to return one pre-existing `<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh.` marker. Stub `linear.sh::query` to return the same shape under `.data.issue.comments.nodes[]`. Invoke `bash "$GUARDS" bump ENG-T153E implement_rejection --reason "x" --reason-code scope-violation`. Assert the captured body contains `'(2/2)'` (1 existing + 1 new).

  **case-bump-6 (D-004 prose-variant for `gotcha_triggered`).**
  Invoke `bash "$GUARDS" bump ENG-T153F gotcha_triggered --reason "Gotcha-hit: G-12 found on commit" --reason-code gotcha-hit`. Assert the captured body contains `'cleared by label pipeline:knowledge-reviewed'` AND `'<!-- meta: metric name=gotcha_triggered reason-code=gotcha-hit -->'`.

  **case-bump-7 (D-005 reader-update regression — `check()` counts the new marker shape).**
  Stub `linear.sh::query` to return two markers with `reason-code` suffix: `<!-- meta: metric name=implement_rejection reason-code=scope-violation-severe --> ...` and a second identical marker (different timestamps). Stub `linear.sh::get-comments` to return the same two comments (no operator-resume waypoint). Invoke `bash "$GUARDS" check ENG-T153G implementing`. Assert `rc == 10` AND `grep -q 'implement_rejection(2>=2)' <<<"$out"`. This is the regression-guard: without Task 2's reader update, the regex would not match the new shape and `check` would return 0, allowing infinite loopback.

- [ ] Each case writes its own `linear.sh` stub (mirror the patterns at `bin/guards-test.sh:49-67` and `:73-92`). For bump-side cases (case-bump-1 through case-bump-6), the stub captures `add-comment`'s `$3` argv to `$BUMP_CAPTURE` and (for cases that exercise pre-existing count) also serves `get-comments` / `query` payloads.
- [ ] Use distinct issue identifiers (`ENG-T153A` through `ENG-T153G`) for log clarity; the stubs do not key off the id.
- [ ] DO NOT modify case-1 through case-13 — those exercise `check()`, unaffected by Task 1's changes.

- [ ] **`bin/run-stage-test.sh::case-16` fix.** Content anchor: the unique pathname `"$STUB_DIR/bump-marker.capture"` near line 1644-1645 followed by the heredoc that defines the stub. The case currently invokes `bash "$FAKE_REPO/.pipeline/bin/guards.sh" bump ENG-T16 implement_rejection` (line 1658, missing `--reason`) and asserts `grep -q '<!-- meta: metric name=implement_rejection -->' "$BUMP_CAPTURE"` (line 1660).
- [ ] Update the bump invocation (line 1658) to supply a literal `--reason`:
  ```bash
  bash "$FAKE_REPO/.pipeline/bin/guards.sh" bump ENG-T16 implement_rejection \
    --reason "case-16 QA fixture: assert marker text matches count_marker grep target" \
    >/dev/null 2>&1
  ```
  (No `--reason-code` so the bare-form marker is emitted — preserving the original grep target.)
- [ ] Update the comment above the case (~lines 1638-1642) to reflect that the assertion now also implicitly confirms the bare-form marker stays the default when `--reason-code` is omitted. Add one line to the existing block before the grep:
  ```
  # ENG-153: the bare-form marker remains the default when --reason-code is
  # omitted, preserving the count_marker grep target for back-compat.
  ```
- [ ] DO NOT change the grep target itself (line 1660) — it asserts the bare-form marker is emitted when `--reason-code` is unset. That's the new invariant of this case.

### Task 7: Run gate suite and confirm green

- `depends_on: [1, 2, 3, 4, 5, 6]`
- `touches: (no source edits — gate execution only)`
- [ ] Run the touched test files individually first for fast feedback:
  - `bash bin/guards-test.sh` — expect 13 + 7 = 20 PASS, exit 0.
  - `bash bin/guards-adversarial-test.sh` — expect A1-A6 PASS, exit 0 (reader regex extension is forward-compat for bare-form fixtures).
  - `bash bin/run-stage-test.sh` — case-16 now PASS (was the only case affected by the new `--reason` contract).
  - `bash bin/verdict-handler-test.sh` and `bash bin/verdict-adversarial-test.sh` — fixture-based tests; expect PASS unchanged.
  - `bash bin/profile-allowlist-test.sh` — comment-only refs to bump counter names; PASS unchanged.
- [ ] Validate the registry edit: `jq -e . bin/pipeline-events.json >/dev/null && jq -e '.metric_reason_codes | length == 4' bin/pipeline-events.json && jq -e '.events.metric.linear_comment.required == ["name"]' bin/pipeline-events.json`.
- [ ] Run the full pre-commit hook: `bash .githooks/pre-commit`. Expect zero failures beyond the existing `KNOWN_BROKEN` allowlist (`mutex-test.sh`, `render-pr-body-test.sh`, `render-prompt-slug-test.sh`).
- [ ] Validate the plan-schema sidecar: `bash bin/plan-schema.sh validate docs/plans/2026-05-19-eng-153-guards-sh-require-reason-on-bump-fail-closed-emit-reason-count-threshold-in-body.json` — expect rc=0.

## Frontend Tasks

**None.** Harness-self bash plan with no FE surface (per project profile Stack). Recorded explicitly to satisfy the template contract.

## Failure Mode → Test Map

Each row binds an edge case from the brainstorm §6 + acceptance criteria to a concrete test.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `bump` invoked without `--reason` (AC#1) | `bash bin/guards.sh bump ENG-T153A implement_rejection` (no flags) | rc != 0; stderr contains `--reason` | unit | `bin/guards-test.sh::case-bump-1` |
| `bump` invoked with `--reason ""` (empty value) | Same as above with `--reason ""` | rc != 0; same die-message | unit | (subsumed by case-bump-1 — `[[ -n "$reason" ]]` rejects both) |
| Populated body present when `--reason` + `--reason-code` supplied (AC#3, AC#4) | `bash bin/guards.sh bump ENG-T153B implement_rejection --reason "SEVERE..." --reason-code scope-violation-severe` | rc=0; body contains `Reason: SEVERE...`, `(1/2)`, `Trips at: 2/2`, marker with `reason-code=` | unit | `bin/guards-test.sh::case-bump-2` |
| Bare-form marker when `--reason-code` omitted (AC#3 fallback path) | Same as above without `--reason-code` | rc=0; body contains `<!-- meta: metric name=implement_rejection -->` (bare form) | unit | `bin/guards-test.sh::case-bump-3` |
| Unknown `--reason-code` token (D-003 schema-reject) | `bump ... --reason-code bogus-token` | rc != 0; stderr names `metric_reason_codes` | unit | `bin/guards-test.sh::case-bump-4` |
| Counter math reflects pre-existing markers (D-004 §c) | One pre-existing `implement_rejection` marker in stub; bump produces `(2/2)` | rc=0; body contains `(2/2)` | unit | `bin/guards-test.sh::case-bump-5` |
| `gotcha_triggered` body emits the alt clearing-prose (D-004) | `bump ... gotcha_triggered ...` | body contains `cleared by label pipeline:knowledge-reviewed` | unit | `bin/guards-test.sh::case-bump-6` |
| `check()` correctly counts new-shape markers with `reason-code=` suffix (D-005 regression guard) | Two `implement_rejection` markers with `reason-code=scope-violation-severe`; `check ENG-T153G implementing` | rc=10; output `implement_rejection(2>=2)` | unit | `bin/guards-test.sh::case-bump-7` |
| `bin/run-stage.sh:1702` SEVERE caller invokes new contract (AC#2) | grep verifies `--reason "SEVERE scope violation` + `--reason-code scope-violation-severe` appear on the bump invocation | source-grep | smoke | `grep -F '--reason-code scope-violation-severe' bin/run-stage.sh` (no test runner; verified by grep at task close) |
| `bin/run-stage.sh:1708` scope-check caller invokes new contract (AC#2) | Same grep, target `--reason-code scope-violation` | smoke | source grep |
| `bin/run-stage.sh:1750` noop-implementation caller invokes new contract (AC#2) | Same grep, target `--reason-code noop-implementation` | smoke | source grep |
| `bin/scan-gotcha-trailers.sh:38` gotcha caller invokes new contract (D-006) | grep verifies `--reason-code gotcha-hit` | smoke | source grep |
| AGENT_PROMPTS.md reviewer + qa clauses pass `--reason` (avoid agent-side die-loud) | grep verifies both clauses include `--reason "<...>"` | smoke | `grep -n -- '--reason' AGENT_PROMPTS.md` |
| Marker-injection via `--reason` text (§6 edge) | `bump ... --reason "<!-- pipeline: verdict result=halt -->"` | rc != 0; stderr names "pipeline/meta marker opener" | unit | (subsumed by Task 1 step; covered defensively by the `case "$reason" in *"<!-- pipeline:"*|*"<!-- meta:"*` guard) |
| `--reason-code` containing chars outside the closed registry (§6 edge — metacharacter rejection) | `bump ... --reason-code "foo;rm -rf /"` | rc != 0; registry-validate denies | unit | (subsumed by case-bump-4 — registry-validate is the single enforcement point) |
| `count_marker` outage / Linear API down | `count_marker` returns 0 on jq-empty; body shows `(1/<threshold>)` | rc=0; body posts with `(1/T)` | (no new test) | covered by case-bump-3 default-empty path (existing marker fixture absent → count=1) |
| Concurrent K=2 bumps (TOCTOU on `count_marker`) | Two simultaneous bumps; both report same pre-count N | Worst case: two bodies claim `(N+1/T)`; `check()` still trips at threshold | (no new test) | acknowledged trade-off — per-issue in-flight lock already serialises dispatches (brainstorm §6) |
| Status dashboard shows new-shape markers under the right name (Task 4 reader update) | Run `bash bin/status.sh` against an issue with mixed bare-form + with-attribute markers | dashboard prints counter name only (no attribute leakage) | (no new test) | manual verification step at Task 7 close; status.sh has no sibling test today |

## Test Strategy

**Unit (`bin/guards-test.sh`).** Seven new `case-bump-N` cases per Task 6. Each uses the established source-and-stub pattern: symlink real `guards.sh` + `common.sh` into a fake-repo overlay; per-case `linear.sh` stub returns parameterised payloads. Reuses the `$BUMP_CAPTURE` pattern from `bin/run-stage-test.sh:1644-1651` (adapted for this file — write a small helper at the top of the new block to centralise the capture-file setup).

**Unit (`bin/run-stage-test.sh::case-16`).** Single-case update: bump invocation gains `--reason "..."`; grep target stays the bare-form marker (asserts that omitting `--reason-code` preserves the original shape).

**Adversarial coverage.** Three adversarial vectors covered by the design + tests:
- *Schema-reject of unknown `--reason-code`* — case-bump-4. Guards against future drift between the closed-vocab registry and caller-supplied tokens.
- *Marker-injection via `--reason` prose* — Task 1 step adds a defensive guard that rejects `<!-- pipeline:` and `<!-- meta:` substrings inside `--reason`. No standalone test case is added (the defensive check is one literal substring match; correctness is by inspection).
- *Reader regression after marker-shape growth* — case-bump-7. Asserts `check()` continues to count markers carrying `reason-code=` suffix. If a future refactor reverts the regex to `contains()`, this case fires.

**Integration backstop.** Three existing test surfaces verify no-regression:
- `bin/guards-adversarial-test.sh` (A1-A6) — bare-form fixture matchers, all stay green (the new regex matches bare-form).
- `bin/verdict-handler-test.sh:508-517` and `bin/verdict-adversarial-test.sh:158-194` — source `bin/guards.sh::count_marker_since_last_operator_resume` directly with bare-form fixtures. Stay green.
- `bin/run-stage-test.sh::case-15` — exercises `guards.sh check` against bare-form `implement_rejection` fixtures with no stage arg. Stays green.

**Smoke (`.githooks/pre-commit`).** Runs the full `bin/*-test.sh` suite. Task 7 closes by running it. KNOWN_BROKEN allowlist is unchanged.

**Test-gate closure sweep (feasibility persona).** The plan adds `--reason` and an optional `reason-code=` attribute; it does NOT remove any token from production code. Tokens that change:
- `<!-- meta: metric name=$counter --> Counter bumped by guards.sh.` (the literal old body) is REMOVED from `bin/guards.sh::bump`. Grepped across `bin/`: appears in test fixtures (`bin/guards-test.sh`, `bin/guards-adversarial-test.sh`, `bin/verdict-handler-test.sh`, `bin/verdict-adversarial-test.sh`, `bin/run-stage-test.sh::case-15`) as input data representing PRE-ENG-153 markers. These fixtures correctly test backward-compat: readers must keep counting bare-form bare-prose markers — guaranteed by Task 2's regex (matches bare form) and by the legacy fallback. The string is not a SHAPE expectation; it's an input payload. No test inversion required.
- The `Counter bumped by guards.sh.` literal prose is dropped from production. Grepped: appears only in test-fixture input payloads. Tests that grep for it as an OUTPUT contract: none (verified by `grep -rn 'Counter bumped by guards.sh.' bin/` — every match is inside a heredoc-served fixture).

No file is newly created under a gate-runnable glob (`bin/*-test.sh`), so the profile's `## Build & test gates` Test command line does not need updating per the add-side test-gate closure sweep.

## Out of scope (reproduced from issue + brainstorm)

- Header line on every comment (`[<ident> · <stage> · <dispatch-id> · <UTC> · <writer>]`) — explicitly deferred by the ticket to a separate follow-up.
- Removing `add-or-update-comment` from any caller — separate follow-up per the ticket.
- Refactoring `bin/classify-failure.sh:194` (`transient-retry` writer) to route through the new `events.metric` schema — brainstorm §5 OUT.
- Refactoring `bin/run-stage.sh:329/394/412/678` direct-marker writers (`summary_missing`, `summary_truncated`, `worktree-mutated-by-agent`) through `events.metric` — same.
- `bin/pipeline.sh` gaining a `bump` sub-command (OQ-3) — out unless an operator-ergonomics need surfaces.
- Adding reviewer/qa-side `reason-code` tokens to `metric_reason_codes` — deferred to OQ-4 retrospective follow-up (closed-vocab grows on demand).
- Retrospective §1 consumer of `reason-code` — OQ-4 load-bearing follow-up; without it the closed-vocab is documentation-only. A separate ticket should be filed (recommended title: *"Retrospective §1 — bucket metric markers by reason-code"*).
- Changing threshold defaults (still 2 across all five counters).

**Ticket sizing rubric (CLAUDE.md "Ticket sizing rubric").** Subsystems touched: **Linear contract** (`guards.sh` body shape, `pipeline-events.json` schema, marker shape, `status.sh` dashboard reader, `AGENT_PROMPTS.md` agent invocations) is the primary; **orchestrator** (`run-stage.sh` + `scan-gotcha-trailers.sh` caller updates) is mechanical subordinate to the contract change; **tests/fixtures** is mechanical regression coverage. Per the rubric "2 subsystems with one clearly subordinate → autonomy-safe IF the scope boundary is explicit". Boundary IS explicit: ENG-153 is a single contract-shape change (`bump` CLI + marker + populated body); everything else follows mechanically. Independent design decisions: two — "fail-closed without `--reason`" (D-001) and "marker grows `reason-code` attribute" (D-002). D-003 through D-007 are mechanical consequences. Within rubric.

**Scope flag (brainstorm §5).** The ticket's IN scope names only `bin/run-stage.sh` as the caller-update surface. The plan expands to:
1. `bin/scan-gotcha-trailers.sh:38` — 4th live mechanical caller, NO `|| true`, would fail-closed at the first Gotcha-hit trailer (brainstorm §5 covers).
2. `AGENT_PROMPTS.md:1318, 1555` — reviewer + qa agent prompt clauses invoke `guards.sh bump` from inside their dispatched `claude -p` shell. **The brainstorm missed this surface entirely.** After ENG-153 the agent's bash invocation would die-loud at the bump call, breaking review/qa loopback. The implement-stage agent on this ticket MUST post a one-line comment on the Linear issue calling out this caller-update delta before opening the PR so the operator can ack the wording-vs-reality gap. The PROMPT clauses do not pass a `--reason-code` (no token registered for reviewer/qa rejection paths today — that's the OQ-4 follow-up); the prose `--reason` is sufficient for AC#1's fail-closed contract.

## Persona review (audit trail)

Five-persona document-review run inline during this dispatch. Headline goes in the Linear stage-summary; full record below.

### Iteration 1

| Persona     | Verdict | Load-bearing findings |
|---|---|---|
| feasibility | PASS · 0 P0 | Every `path:line` cited has been opened during this dispatch (Assumption Inventory). Edit boundaries use content anchors (unique function-opener line, unique `case "$counter" in` line, unique heredoc-stub setup pattern); no bare-line-only boundaries. Branch-base freshness pinned (`HEAD..origin/main` empty at plan time, `origin/main = ca36cc6`). **Test-gate closure sweep ran**: `Grep meta: metric name=` across `bin/` returned 7 files; verified each. The literal old body `<!-- meta: metric name=$counter --> Counter bumped by guards.sh.` appears in test-fixture INPUT payloads (representing pre-ENG-153 markers), not as an OUTPUT contract — fixtures stay valid input shapes; readers updated to forward-compat. Two production writers OUTSIDE `guards.sh::bump` (`bin/run-stage.sh:329/394/412/678` and `bin/classify-failure.sh:194`) continue emitting bare-form via direct `linear.sh add-comment` — confirmed OUT of scope (brainstorm §5). Sibling-test halt risk: NONE. Task `depends_on` graph is acyclic (1, 2, 3, 4 independent; 5 depends on 1; 6 depends on 1, 2, 3; 7 depends on all). **Test-gate closure add-side sweep ran**: no new file is added under `bin/*-test.sh`, so the profile's `## Build & test gates` Test command line does not need an update — `learned-rules/harness/project-profile.md` correctly absent from File Structure. |
| scope       | PASS · 0 P0 | All edits trace to brainstorm §2 decisions or the Linear ticket §Scope IN list. The two ticket-undercount expansions (`scan-gotcha-trailers.sh`, `AGENT_PROMPTS.md`) are explicitly named in §Out of scope's Scope-flag block with the operator-ack-comment requirement. No gold-plating. The single dispatched change is the `bump` CLI shape; everything else is mechanical follow-on. The `cli_required` schema-key extension (Task 3) is the smallest possible addition to keep ENG-112's `required[]` semantic clean — within rubric. |
| coherence   | PASS · 0 P0 | Goal sentence matches brainstorm §1 verbatim (fail-closed without `--reason`; populated body with reason/count/threshold; schema-registered). AC#1-AC#5 from the Linear ticket (mapped in brainstorm §1's table) are 1:1 traceable to Failure Mode → Test Map rows: AC#1 → case-bump-1; AC#3 → case-bump-2, case-bump-3, case-bump-5; AC#4 → case-bump-2; AC#5 → Task 3's `events.metric` registry entry (verified by Task 7's `jq -e` smoke). AC#2 (all `run-stage.sh` callers updated) → Task 5's three site updates, verified by Failure Mode rows' source-grep entries. Backend Tasks 1+2 jointly realise D-001 + D-002 + D-004 + D-005 of the brainstorm; Task 3 realises D-003; Task 4 covers the `status.sh` reader-update gap from D-005; Task 5 covers D-006 plus the AGENT_PROMPTS.md expansion; Task 6 covers D-007 plus the run-stage-test.sh::case-16 fix. |
| design      | PASS · 0 P0 | The new `bump()` body composes a single multi-line string and posts via the existing `linear.sh add-comment` chokepoint — no new helper, no new module boundary. The schema entry follows ENG-112's parametric shape exactly (`linear_comment.body_shape` template + `required[]` + `optional[]` + `field_registry`). The `cli_required[]` extension is additive and back-compat with the existing three event entries (verified at `bin/pipeline.sh:155-160` — `cli_required` is not in the known-fields union, so the validator ignores it). Reader updates use a single regex shape (`name=X( [^>]*)?-->`) across three jq filter sites, anchored to the `<!-- meta:` envelope so prose-quoted substrings outside markers do not false-positive. No layering violation, no circular dep. Reversible via single revert. Plan respects the project profile's File layout (only `bin/` + `AGENT_PROMPTS.md` + `docs/` are touched). |
| product     | PASS · 0 P0 | AC#1-AC#5 (Linear ticket §Acceptance criteria) are observable from `bin/guards-test.sh` output and from inspecting the Linear thread of any issue post-ENG-153 (the populated body explicitly states reason, current count, trip threshold). The operator-burden complaint from the ticket Context (need to cross-reference transcript + `issue-state.json` to recover meaning) is directly addressed: every bump body now stands on its own. The expanded scope (AGENT_PROMPTS.md clauses) prevents a guaranteed production fail-closed at the first review/qa loopback after ENG-153 — caught by the implementer not the operator. The closed-vocab `reason-code` is documentation-only until OQ-4 ships; flagged as a load-bearing follow-up in Out of scope. The trade-off (closed vocab can be over-restrictive for novel causes) is acknowledged in §6 — operators can extend the registry with a one-line PR. |

**Gate decision: 5/5 PASS · feasibility P0 = 0 · proceeding to implementing.**
