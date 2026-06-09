---
linear: ENG-151
date: 2026-06-09
topic: linear.sh — human-readable header line on every harness-written comment
---

# linear.sh — human-readable header line on every harness-written comment

## Goal

Every harness-written Linear comment opens with one canonical two-line
header — `[<ident> · <stage> · <dispatch-tail> · <iso-ts> · <actor>]`
followed by `<EVENT-TYPE> — <summary>` — auto-prepended by a single
helper in `bin/linear.sh::add_comment` / `add_or_update_comment`, so
operators can identify event-type, dispatch context, timestamp, and
actor without parsing footer markers.

## Assumption Inventory

Branch-base freshness: `HEAD..origin/main` is NON-EMPTY at plan time
(8 commits from ENG-120 landed on main while this branch was drafting
— touches `AGENT_PROMPTS.md` + `bin/dispatch.sh`; neither file has
semantic conflict with ENG-151's edits but a rebase IS required).
Task 0 (Rebase) handles this; the `path:line` references below are
recorded against current `HEAD` (worktree state) and re-verified post-
rebase by Task 0's checklist.

| # | Assumption | Status | Evidence (`path:line`) |
|---|---|---|---|
| A-001 | `add_comment` is at `bin/linear.sh:496-574`; lane fence at `:505`, dispatch-id auto-inject at `:514`, dry-run gate at `:516`. | verified | `bin/linear.sh:496-574` — current signature `add_comment() { local ident="$1"; shift; ...; _check_lane "add" "$_comment_class" \|\| return $?; ... body="$(_inject_dispatch_marker "$body")"; if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then ...; fi`. |
| A-002 | `add_or_update_comment` is at `bin/linear.sh:576-708`; `_reject_legacy_marker_body` at `:588`, dispatch-id auto-inject at `:595`, dedup append at `:601-605`, dry-run gate at `:607-610`, `strip_re` at `:652`. | verified | `bin/linear.sh:576-708` — `add_or_update_comment() { local sig="$1" ident="$2"; ...; _reject_legacy_marker_body "add-or-update-comment" "$body" \|\| return $?; body="$(_inject_dispatch_marker "$body")"; local marker="<!-- meta: dedup key=$sig -->"; ...; strip_re='/^<!-- meta: (reapplied at=\|dispatch id=)[^>]* -->$/d'`. |
| A-003 | `_inject_dispatch_marker` is at `bin/linear.sh:60-77`; reads `PIPELINE_DISPATCH_ID` + `PIPELINE_STAGE`; idempotent on current-id match. | verified | `bin/linear.sh:60-77` — `_inject_dispatch_marker() { local body="$1"; [[ -n "${PIPELINE_DISPATCH_ID-}" ]] \|\| { printf '%s' "$body"; return 0; }; ...; printf '%s\n\n<!-- meta: dispatch id=%s stage=%s -->' "$body" "${PIPELINE_DISPATCH_ID-}" "${PIPELINE_STAGE-}"`. |
| A-004 | `_classify_comment_body` at `bin/linear.sh:84-96` reads FIRST non-blank line; classifies as `transition_comment` vs `other_comment`. | verified | `bin/linear.sh:84-96` — `_classify_comment_body() { local body="$1"; local first_nonblank; first_nonblank="$(printf '%s' "$body" \| grep -m1 '[^ ]' \|\| true)"; ...`. |
| A-005 | `_check_lane` at `bin/linear.sh:146-171` reads `${PIPELINE_WRITER:-orchestrator}`; valid lanes: `orchestrator\|agent\|classify\|scope-check\|human`. | verified | `bin/linear.sh:146-171` — `_check_lane() { local action="$1" object_class="$2"; local lane="${PIPELINE_WRITER:-orchestrator}"; case "$lane" in orchestrator\|agent\|classify\|scope-check\|human) ;; ...`. |
| A-006 | `dispatch.sh::main` exports `PIPELINE_WRITER=agent`, `PIPELINE_DISPATCH_ID=...`, `PIPELINE_STAGE=$stage` to the agent subshell. | verified | `bin/dispatch.sh:713-716` — `local cmd=(env PIPELINE_WRITER=agent "PIPELINE_DISPATCH_ID=${PIPELINE_DISPATCH_ID-}" "PIPELINE_STAGE=$stage" ...`. |
| A-007 | `failure_outcome_for_exit` at `bin/common.sh:305-337` is a closed `case` taxonomy; exit code 15 is currently unallocated (allocated codes: 10-14, 20-31, 33-35, 124). | verified | `bin/common.sh:305-337` — case arms `10\|11\|12\|13\|14\|20\|21\|22\|23\|24\|25\|26\|27\|28\|29\|30\|31\|33\|34\|35\|124\|*`. No `15)` arm; `15` will fall through to `unknown-exit-15`. |
| A-008 | `bin/pipeline.sh::cmd_event_verdict` at `:261-300` calls `bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"` at `:299` with body = `_render_body verdict ...` output (just the marker line). | verified | `bin/pipeline.sh:261-300`, post at `:299`. The body is a single marker line; ENG-151's chokepoint header derivation will pick it up via Priority 2 (`<!-- pipeline: verdict result=... -->`). |
| A-009 | `_pipeline_post_operator_transition` at `bin/pipeline.sh:414-423` posts the `<!-- pipeline: transition from=X to=X reason=operator-resume -->` waypoint via `bash "$SCRIPT_DIR/linear.sh" add-comment`. | verified | `bin/pipeline.sh:414-423` — `_pipeline_post_operator_transition() { local issue="$1" stage="$2"; ...; bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$waypoint_body" }`. |
| A-010 | `bin/linear-test.sh:520-967` contains the ENG-63 + ENG-111 test blocks with `_eng63_capture_file` / `_eng111_capture_file` capture machinery; uses `linear_query` stub override + `_resolve_issue_uuid` mock under `PIPELINE_DRY_RUN=0`. | verified | `bin/linear-test.sh:520-757` (ENG-63 block); `bin/linear-test.sh:764-967` (ENG-111 block). Capture file pattern `: > "$_eng63_capture_file"; ... add_or_update_comment ...; grep ...`. |
| A-011 | `bin/linear-test.sh` is already in `learned-rules/harness/project-profile.md::"## Build & test gates"` Test command AND `## Tool allowlist` for implementing+qa. No gate-list update needed. | verified | `learned-rules/harness/project-profile.md:17` lists `bash bin/linear-test.sh`; `:43` and `:88` allowlist `Bash(bash bin/linear-test.sh:*)`. ENG-151 EXTENDS this file; no new test file → no profile edit. |
| A-012 | `AGENT_PROMPTS.md` "Pipeline comment dedup convention" section at `:32-43` is the right anchor for the D-009 header-contract paragraph; existing ENG-15/ENG-55/ENG-57/ENG-60 paragraphs cluster there. | verified | `AGENT_PROMPTS.md:32` `## Pipeline comment dedup convention`; `:43` closes with the legacy-shape paragraph. ENG-151's new paragraph appends after `:43`. |
| A-013 | `docs/pipeline-vocabulary.md` has a static "Anatomy of a marker" section at `:10-27` BEFORE the `<!-- GENERATED:event-schemas -->` block at `:29`. Static prose section can be inserted between them. | verified | `docs/pipeline-vocabulary.md:10` `## Anatomy of a marker`, `:29` `<!-- GENERATED:event-schemas -->`. ENG-151's "Comment header" prose section slots at `:28` (between the static "Anatomy" tail and the GENERATED block). |
| A-014 | Bash 3.2 `[[ $var =~ -(d[0-9]+)$ ]]` + `${BASH_REMATCH[1]}` works on macOS; precedent at `bin/run-stage.sh:1376` and `bin/scope-check.sh:200`. | verified | grep `BASH_REMATCH` `bin/run-stage.sh:1376`, `bin/scope-check.sh:200` this session — both production sites. |
| A-015 | `· ` separator (space + U+00B7 middle-dot + space) renders correctly on Linear web UI. | assumed | Not verified against a live Linear render. Fallback: ASCII ` \| ` separator (one-token change in the helper). AC #1 is satisfied independently of separator glyph; only cosmetic. |
| A-016 | `dispatch_id` format is `ENG-N-d<NNNN>` per `bin/common.sh::allocate_dispatch_id`; CLAUDE.md "Cross-dispatch staleness contract (ENG-87)" pins the format. | verified | CLAUDE.md "Cross-dispatch staleness contract (ENG-87)" §"Glue: `PIPELINE_DISPATCH_ID`" — "Format: `ENG-N-d<NNNN>` (monotonic per issue)". |
| A-017 | Sigs follow `<class>/<stage>/<ident>` (e.g. `completion/implementing/ENG-151`, `tdd-evidence/qa/ENG-151`) OR flat `<class>/<ident>` (e.g. `last-review-state/ENG-151`, `worktree-mutation/ENG-151`). | verified | Grep `add_or_update_comment` callers: `completion/<stage>/`, `tdd-evidence/<stage>/`, `scope-approval/<stage>/`, `halt/<stage>/`, `last-review-state/`, `worktree-mutation/`. |
| A-018 | Exit code 14 = `legacy-marker-write` per `bin/common.sh:318`. D-009-b's chokepoint detective (agent-lane hand-rolled header) reuses 14 — semantic match (both are "agent bypassed chokepoint authorial intent"). | verified | `bin/common.sh:318` — `14) printf 'legacy-marker-write' ;;`. |

## File Structure

| File | Status | What changes |
|---|---|---|
| `bin/linear.sh` | modified | Add `_render_event_header` + `_derive_event_type_and_summary` helpers between `_inject_dispatch_marker` (`:60-77`) and `_classify_comment_body` (`:84-96`). Wire helpers into `add_comment` after `_check_lane`. Wire helpers into `add_or_update_comment` after `_reject_legacy_marker_body`. Insert D-009-b chokepoint detective (agent-lane hand-rolled-header reject, exit 14) in BOTH write functions. Extend `strip_re` at `:652` for header-line stripping. Add docstring note to `_classify_comment_body` per D-011 invariant. |
| `bin/common.sh` | modified | Add `15) printf 'header-missing-inputs' ;;` arm to `failure_outcome_for_exit` (`:305-337`). |
| `bin/linear-test.sh` | modified | Add `# ─── ENG-151: header line ───` block after the ENG-111 breadcrumb block (after `:967`). Snapshot tests H-001..H-013 per D-010 (verdict.pass, verdict.halt, completion, scope-approval, counter-bump, last-review-state, tdd-evidence, agent fail-closed, human bypass, byte-equal modulo header, grep-source-of-truth, agent header-spoof reject, orchestrator manual header allowed). |
| `AGENT_PROMPTS.md` | modified | Append D-009 header-contract paragraph to "Pipeline comment dedup convention" section after `:43`. |
| `docs/pipeline-vocabulary.md` | modified | Insert static "Comment header" prose section at `:28` (between the static "Anatomy of a marker" tail and the `<!-- GENERATED:event-schemas -->` block). |
| `docs/plans/2026-06-09-eng-151-linear-sh-human-readable-header-line-on-every-harness-written-comment.md` | new | This plan doc. |
| `docs/plans/2026-06-09-eng-151-linear-sh-human-readable-header-line-on-every-harness-written-comment.json` | new | Sibling structured contract (schema-v1). |

No changes to:

- `bin/pipeline.sh` (verdict / transition / decision posts go through chokepoint unchanged — D-008).
- `bin/pipeline-events.json` (marker schema untouched — D-008).
- `bin/classify-failure.sh`, `bin/run-stage.sh`, `bin/guards.sh`, `bin/review-state.sh`, `bin/poll.sh`, `bin/run-local.sh`, `bin/run-local-helpers.sh`, `bin/mark-abandoned.sh`, `bin/rollback-stage.sh`, `bin/on-new-release.sh`, `bin/dispatch.sh` (zero caller refactors — header is auto-prepended at the chokepoint).
- `learned-rules/harness/project-profile.md` (test file `bin/linear-test.sh` is already in the gate list — A-011).

## API Contract

no new API surface

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (workflow only — no file edits)`
- [ ] Run `git fetch origin main && git rebase origin/main`. The drifted commits (ENG-120 — within-stage iteration loop) touch `AGENT_PROMPTS.md` and `bin/dispatch.sh`. ENG-151's `AGENT_PROMPTS.md` edit appends to the `## Pipeline comment dedup convention` section (`:32-43`); ENG-120 edits the `## 3. Implementation Agent (Backend)` section (`:690+`). Different sections — clean rebase expected; if a conflict arises, prefer origin/main's content and reapply ENG-151's header-contract paragraph manually.
- [ ] After the rebase, re-grep the Assumption Inventory anchors against the rebased worktree to confirm `bin/linear.sh:60-77, :84-96, :146-171, :496-574, :576-708, :652`, `bin/common.sh:305-337`, `bin/dispatch.sh:713-716`, `bin/pipeline.sh:261-300, :414-423` still resolve to the documented shapes. If any anchor drifted, update the plan's Assumption Inventory before the implement agent dispatches.
- [ ] Verify `bin/linear-test.sh` ENG-63 + ENG-111 blocks (capture-file machinery the new H-001..H-013 tests reuse) survived intact via `grep -nE '_eng(63|111)_capture_file' bin/linear-test.sh` — count should be >0 in each block.

### Task 1: Add `_render_event_header` + `_derive_event_type_and_summary` helpers in `bin/linear.sh`

- `depends_on: [0]`
- `touches: bin/linear.sh::_render_event_header, bin/linear.sh::_derive_event_type_and_summary`
- [ ] In `bin/linear.sh`, AFTER the `_inject_dispatch_marker` closing `}` (`:77`) AND BEFORE the `_classify_comment_body` opening comment (`:79`), add a new helper `_render_event_header() { ... }`. Signature: `_render_event_header <ident> <event_type> <summary>`. Reads `PIPELINE_STAGE`, `PIPELINE_DISPATCH_ID`, `PIPELINE_WRITER` from env. Emits exactly two lines on stdout: `[<ident> · <stage-or-dash> · <dispatch-tail-or-dash> · <iso-ts> · <actor>]\n<event-type> — <summary>` (no trailing newline). Extract dispatch-tail via `[[ "$dispatch_id" =~ -(d[0-9]+)$ ]]` → `${BASH_REMATCH[1]}`; empty input renders `-`; malformed (regex no-match, non-empty) emits the verbatim value (visible-bug surface). iso-ts via `date -u +%Y-%m-%dT%H:%M:%SZ`. actor = `${PIPELINE_WRITER:-orchestrator}`. Returns 15 when actor==`agent` AND (`PIPELINE_DISPATCH_ID` empty OR `PIPELINE_STAGE` empty) — structured stderr `'linear.sh: agent-lane comment missing header inputs (PIPELINE_DISPATCH_ID=%q PIPELINE_STAGE=%q). Set both env vars or change the lane.\n'`.
- [ ] In the same file, immediately AFTER `_render_event_header`'s closing `}`, add `_derive_event_type_and_summary() { ... }`. Signature: `_derive_event_type_and_summary <body> <sig?>`. Emits `<event_type>\t<summary>` (tab-delimited, single line, with trailing newline so `IFS=$'\t' read -r` works). Switch in priority order:
  - **P1**: if `$sig` is non-empty, match it against `completion/* tdd-evidence/* last-review-state/* scope-approval/* halt/* wait/* worktree-mutation/* protocol-violation/* retry-pending/*` and emit the corresponding event-type with stage extracted via an inline `_sig_stage` helper (`local mid="${s#*/}"; mid="${mid%/*}"; case "$mid" in ENG-*) printf '' ;; "$s") printf '' ;; *) printf '%s' "$mid" ;; esac`).
  - **P2**: if `$body` contains `<!-- pipeline: verdict result=pass`, extract `stage=<X>` via `grep -oE 'stage=[a-z]+' \| head -1 \| cut -d= -f2`, emit `PASS\tstage <X> complete`. Similar arms for `result=fail` (extract `target=`), `result=halt` (extract `reason=`), `result=wait` (extract `reason=`), `result=pivot` (extract `target=`). Also `<!-- pipeline: transition from=<F> to=<T> -->` → `TRANSITION\t<F> → <T>`. Also `<!-- pipeline: decision action=<A>` → `DECISION\t<A>[ (gate=<G>)]`.
  - **P3**: meta-marker fallback. `[[ "$body" =~ \<\!--\ meta:\ metric\ name=([a-z_-]+) ]]` → `COUNTER-BUMP\t${BASH_REMATCH[1]}`. Similar for `breadcrumb sig=([^ ]+)` → `BREADCRUMB\tre-emit of <sig>`, `forensic kind=([a-z-]+)` → `FORENSIC\t<kind>`.
  - **P4**: fallback. `first_prose="$(grep -m1 -v -e '^<!--' -e '^$' <<<"$body" \| head -c 80)"`; emit `COMMENT\t${first_prose:-(no body)}`.
- [ ] Confirm: `bash -n bin/linear.sh` parses cleanly. Manual smoke: `PIPELINE_WRITER=orchestrator PIPELINE_STAGE=implementing PIPELINE_DISPATCH_ID=ENG-151-d0001 bash -c 'source bin/linear.sh; _render_event_header ENG-151 PASS "stage implementing complete"'` emits the bracket line + `PASS — stage implementing complete`. Confirm `PIPELINE_WRITER=agent PIPELINE_DISPATCH_ID= PIPELINE_STAGE= bash -c 'source bin/linear.sh; _render_event_header ENG-151 PASS x' || echo "rc=$?"` prints rc=15.

### Task 2: Wire helpers into `add_comment` with D-005 lane bypass + D-009-b detective

- `depends_on: [1]`
- `touches: bin/linear.sh::add_comment`
- [ ] In `bin/linear.sh::add_comment` (the function opening at the line containing `add_comment() {`), insert the header-injection block AFTER the `_check_lane "add" "$_comment_class" || return $?` line AND BEFORE the existing `# ENG-87: auto-inject dispatch_id marker.` comment block (which precedes the `body="$(_inject_dispatch_marker "$body")"` line). Block contents:
  ```bash
  # ENG-151: auto-prepend bracketed header + event-type/summary line.
  # Placement: AFTER lane fence (so classifier reads un-headered body),
  # BEFORE dispatch-id auto-inject (so footer reads below header), BEFORE
  # the dry-run short-circuit (so unit tests observe the injection).
  # human lane bypasses (D-005); agent lane with hand-rolled header
  # rejected (D-009-b); agent lane with missing dispatch context fails
  # via _render_event_header rc=15 (D-006).
  case "${PIPELINE_WRITER:-orchestrator}" in
    human) ;;
    *)
      if [[ "${PIPELINE_WRITER:-orchestrator}" == "agent" ]]; then
        local _first_nonblank
        _first_nonblank="$(printf '%s' "$body" | grep -m1 '[^ ]' || true)"
        _first_nonblank="$(printf '%s' "$_first_nonblank" | sed 's/^[[:space:]]*//')"
        if [[ "$_first_nonblank" =~ ^\[ENG-[0-9]+\ · ]]; then
          printf 'linear.sh add-comment: agent-lane comment carries hand-rolled header line — rejected.\n            header line is auto-prepended by the chokepoint; do not emit it manually.\n' >&2
          return 14
        fi
      fi
      local _event_type _summary _header
      IFS=$'\t' read -r _event_type _summary < <(_derive_event_type_and_summary "$body" "")
      _header="$(_render_event_header "$ident" "$_event_type" "$_summary")" || return $?
      body="${_header}"$'\n\n'"${body}"
      ;;
  esac
  ```
- [ ] Confirm: the existing `body="$(_inject_dispatch_marker "$body")"` line still runs AFTER this block (footer renders below the header). The existing dry-run gate (`if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then log ... return 0; fi`) MUST be reached only AFTER both injections so unit tests observe both.

### Task 3: Wire helpers into `add_or_update_comment` with D-005 lane bypass + D-009-b detective

- `depends_on: [1]`
- `touches: bin/linear.sh::add_or_update_comment`
- [ ] In `bin/linear.sh::add_or_update_comment` (function opening `add_or_update_comment() {`), insert the SAME header-injection block as Task 2, with the SOLE difference that `_derive_event_type_and_summary "$body" "$sig"` passes the second arg (the sig is in scope at this point). Placement: AFTER the `_reject_legacy_marker_body "add-or-update-comment" "$body" || return $?` line AND BEFORE the existing `# ENG-87: auto-inject dispatch_id marker.` comment block (which precedes `body="$(_inject_dispatch_marker "$body")"`).
- [ ] Confirm placement: AFTER `_reject_legacy_marker_body`, BEFORE `_inject_dispatch_marker`, BEFORE the dedup-marker append (`marker="<!-- meta: dedup key=$sig -->"; ... body+=$'\n\n'"$marker"`), BEFORE the dry-run gate.

### Task 4: Extend `strip_re` in `add_or_update_comment` to drop the new header lines (D-007)

- `depends_on: [3]`
- `touches: bin/linear.sh::add_or_update_comment (strip_re definition)`
- [ ] Locate the line `strip_re='/^<!-- meta: (reapplied at=|dispatch id=)[^>]* -->$/d'` inside the `if [[ -n "$existing_id" ]]; then` branch (just before `existing_norm="$(printf '%s' "$existing_body" | sed -E "$strip_re")"`). Replace with:
  ```bash
  # ENG-151 D-007: also strip the auto-prepended header lines so the
  # byte-equal-modulo-meta-noise normalisation (ENG-63) survives header
  # rotation across re-applies. Line 1 = bracket; Line 2 = closed
  # event-type vocabulary alternation (anchored to ^_event_types$ to
  # avoid stripping caller prose lines like "TODO — fix later").
  local _event_types='PASS|FAIL|HALT|WAIT|PIVOT|TRANSITION|DECISION|COMPLETION|TDD-EVIDENCE|LAST-REVIEW-STATE|SCOPE-APPROVAL|WORKTREE-MUTATION|COUNTER-BUMP|BREADCRUMB|FORENSIC|PROTOCOL-VIOLATION|RETRY-PENDING|COMMENT'
  strip_re='/^<!-- meta: (reapplied at=|dispatch id=)[^>]* -->$/d; /^\[ENG-[0-9]+ · .* · .* · .* · [a-z-]+\]$/d; /^('"$_event_types"') — /d'
  ```
- [ ] Confirm the line-1 strip pattern matches a full bracket shape (5 ` · `-separated segments, actor token tightened to `[a-z-]+` so caller prose `[ENG-104] follow-up:` does NOT match). The line-2 strip pattern requires the uppercase token AT LINE START followed by literal ` — ` (em-dash + space) — caller prose `TODO — fix later` does NOT match (TODO is not in the alternation).

### Task 5: Add D-011 docstring invariant on `_classify_comment_body`

- `depends_on: [2, 3]`
- `touches: bin/linear.sh::_classify_comment_body (docstring)`
- [ ] Above the line `_classify_comment_body() {` (which is at the section beginning with `# Classify a comment body into transition_comment or other_comment.`), prepend a load-bearing-invariant note BEFORE the existing `# Classify ...` comment. New comment block:
  ```bash
  # IMPORTANT (ENG-151 D-011): must be called on the un-headered body.
  # The ENG-151 header line (`[ENG-N · …]`) is auto-prepended by the
  # chokepoint AFTER this classifier returns. If the order is ever
  # reversed, every comment becomes `other_comment` and the
  # `add transition_comment` lane fence silently admits agent-lane
  # transition writes. Order is asserted indirectly by H-012 in
  # bin/linear-test.sh (agent-lane hand-rolled bracket → exit 14).
  ```

### Task 6: Add `15 → header-missing-inputs` mapping to `failure_outcome_for_exit`

- `depends_on: []`
- `touches: bin/common.sh::failure_outcome_for_exit`
- [ ] In `bin/common.sh::failure_outcome_for_exit` (function body at `:305-337`), AFTER the `14) printf 'legacy-marker-write' ;;` line AND BEFORE the `20) printf 'dispatch-failed' ;;` line, insert: `15) printf 'header-missing-inputs' ;;`. This slots in the existing ascending numeric ordering.

### Task 7: Add D-009 header-contract paragraph to AGENT_PROMPTS.md preamble

- `depends_on: [0]`
- `touches: AGENT_PROMPTS.md (Pipeline comment dedup convention section)`
- [ ] In `AGENT_PROMPTS.md`, find the `## Pipeline comment dedup convention` section header. After the existing paragraph block ending with the legacy-shape paragraph (the line beginning `The legacy hyphenated shapes...`, the last paragraph before the `---` separator and the `## Verdict-marker protocol` header), append the following new paragraph BEFORE the `---` separator:
  ```markdown
  **Header line (ENG-151).** Every `add-comment` / `add-or-update-comment` you post is auto-prepended with `[<ident> · <stage> · <dispatch-id-tail> · <iso-ts> · <actor>]` by the chokepoint, followed by a derived `<EVENT-TYPE> — <summary>` line (the event-type is derived from the body's pipeline/meta marker or the sig). You do NOT manage these lines — the chokepoint owns them. Do NOT emit your own bracketed `[ENG-N · …]` first line; the chokepoint's agent-lane detective REJECTS hand-rolled headers with rc=14 (`legacy-marker-write`). If `PIPELINE_DISPATCH_ID` or `PIPELINE_STAGE` is missing in an agent-lane invocation, the chokepoint exits rc=15 (`header-missing-inputs`). Both are configured by `bin/dispatch.sh::main` before your subshell starts; you do not set them yourself.
  ```

### Task 8: Add static "Comment header" prose section to docs/pipeline-vocabulary.md

- `depends_on: []`
- `touches: docs/pipeline-vocabulary.md`
- [ ] In `docs/pipeline-vocabulary.md`, locate the closing of the `## Anatomy of a marker` section (the last line before `<!-- GENERATED:event-schemas -->`). Insert a new `## Comment header (ENG-151)` H2 section BETWEEN that closing and the `<!-- GENERATED:event-schemas -->` line. Content:
  ```markdown
  ## Comment header (ENG-151)

  Every harness-written Linear comment opens with one canonical two-line
  header, auto-prepended by `bin/linear.sh::add_comment` /
  `add_or_update_comment`:

  ```
  [<ident> · <stage> · <dispatch-tail> · <iso-ts> · <actor>]
  <EVENT-TYPE> — <one-line summary>
  ```

  - `<ident>` — issue identifier (e.g. `ENG-151`).
  - `<stage>` — gerund-form stage from `PIPELINE_STAGE`, or `-` when absent.
  - `<dispatch-tail>` — the `d<NNNN>` suffix of `PIPELINE_DISPATCH_ID` (e.g. `d0007`), or `-` when absent.
  - `<iso-ts>` — `date -u +%Y-%m-%dT%H:%M:%SZ` at render time.
  - `<actor>` — `PIPELINE_WRITER` (`orchestrator | agent | classify | scope-check`); `human` lane bypasses header insertion.
  - `<EVENT-TYPE>` — derived from the body's pipeline/meta marker or the sig (see `bin/linear.sh::_derive_event_type_and_summary`).

  Agents do NOT author this header; the chokepoint owns it. An
  agent-lane post whose first line matches `^\[ENG-[0-9]+ · ` is
  rejected with rc=14 (`legacy-marker-write`).
  ```

### Task 9: Add ENG-151 snapshot tests H-001..H-013 to `bin/linear-test.sh`

- `depends_on: [2, 3, 4, 5, 6]`
- `touches: bin/linear-test.sh`
- [ ] After the closing of the ENG-111 breadcrumb block (the last `pass_at`/`fail_at` of the B-* test set and its `unset` cleanup line, ~`bin/linear-test.sh:967`), insert a new block opened by `printf '\n--- ENG-151: header line ---\n'`. The block reuses the ENG-111 capture-file pattern (`_eng151_capture_file="$(mktemp -t eng151-capture.XXXXXX)"`, override `linear_query` to write `commentCreate`/`commentUpdate` `.body` to the capture file, override `_resolve_issue_uuid`, set `PIPELINE_DRY_RUN=0`).
- [ ] Test H-001 (verdict.pass): set `PIPELINE_WRITER=agent PIPELINE_DISPATCH_ID=ENG-151T-d0001 PIPELINE_STAGE=brainstorming`; call `add_comment ENG-151T --body '<!-- pipeline: verdict result=pass stage=brainstorming -->'`; assert `grep -qE '^\[ENG-151T · brainstorming · d0001 · [0-9-]+T[0-9:]+Z · agent\]$' "$_eng151_capture_file"` AND `grep -qF 'PASS — stage brainstorming complete' "$_eng151_capture_file"`.
- [ ] Test H-002 (verdict.halt): same env; `add_comment ENG-151T --body '<!-- pipeline: verdict result=halt reason=scope-violation -->'`; assert second line `HALT — scope-violation`.
- [ ] Test H-003 (completion via add_or_update): same env (stage=implementing); `add_or_update_comment "completion/implementing/ENG-151T" ENG-151T --body 'agent prose'`; assert second line `COMPLETION — stage implementing summary`.
- [ ] Test H-004 (scope-approval): `add_or_update_comment "scope-approval/implementing/ENG-151T" ENG-151T --body 'approval request'`; assert second line `SCOPE-APPROVAL — implementing`.
- [ ] Test H-005 (counter-bump): `add_comment ENG-151T --body '<!-- meta: metric name=review_rejection --> Counter bumped'`; assert second line `COUNTER-BUMP — review_rejection`.
- [ ] Test H-006 (last-review-state): `add_or_update_comment "last-review-state/ENG-151T" ENG-151T --body '...'`; assert second line starts with `LAST-REVIEW-STATE`.
- [ ] Test H-007 (tdd-evidence): `add_or_update_comment "tdd-evidence/implementing/ENG-151T" ENG-151T --body '...'`; assert second line `TDD-EVIDENCE — stage implementing`.
- [ ] Test H-008 (agent fail-closed missing inputs): `PIPELINE_WRITER=agent PIPELINE_DISPATCH_ID= PIPELINE_STAGE=`; capture stderr+rc of `add_comment ENG-151T --body 'x'`; assert rc=15 AND stderr matches `agent-lane comment missing header inputs`.
- [ ] Test H-009 (human lane bypass): `PIPELINE_WRITER=human`; `add_comment ENG-151T --body 'operator note'`; assert captured body does NOT start with `[` (header skipped).
- [ ] Test H-010 (byte-equal modulo header): under canned existing-body matching the new normalised shape, two identical-body `add_or_update_comment` calls between which the iso-ts must have rotated; assert ENG-63's `<!-- meta: reapplied at=...` footer fires (proves strip_re extension works — Task 4).
- [ ] Test H-011 (grep-source-of-truth AC #2): run `grep -rn ' · orchestrator\| · agent' bin/ | grep -v -e linear-test.sh -e linear.sh -e CLAUDE.md | head` and assert it returns empty (the helper definition + tests are the only sites; CLAUDE.md may legitimately mention the format).
- [ ] Test H-012 (agent header-spoof rejected D-009-b): `PIPELINE_WRITER=agent PIPELINE_DISPATCH_ID=ENG-151T-d0001 PIPELINE_STAGE=brainstorming add_comment ENG-151T --body '[ENG-151T · brainstorming · d0001 · 2026-05-20T10:00:00Z · orchestrator]\nfake header\nbody'`; assert rc=14 AND stderr matches `agent-lane comment carries hand-rolled header line — rejected`.
- [ ] Test H-013 (orchestrator manual header silently allowed): same body as H-012 under `PIPELINE_WRITER=orchestrator`; assert rc=0; capture contains the canonical auto-header line ABOVE the agent-style hand-rolled one (duplicate visible to operator, no rejection).
- [ ] At end of block, restore `linear_query`/`_resolve_issue_uuid` originals + `PIPELINE_DRY_RUN`/`SCRIPT_DIR` + unset all `_eng151_*` locals. Mirror the ENG-111 block's cleanup pattern.

### Task 10: Verify gate suite remains green

- `depends_on: [2, 3, 4, 5, 6, 7, 8, 9]`
- `touches: (no file edits — pre-commit gate)`
- [ ] Run `bash .githooks/pre-commit` to fire all `bin/*-test.sh`. ENG-151 changes touch `bin/linear.sh` + `bin/linear-test.sh` + `bin/common.sh` + `AGENT_PROMPTS.md` + `docs/pipeline-vocabulary.md`; the relevant suites are `bin/linear-test.sh`, `bin/common-test.sh`, `bin/agent-prompts-content-test.sh`, `bin/vocabulary-cleanliness-test.sh`. All must pass.
- [ ] Specifically confirm `bin/linear-test.sh`'s ENG-63 C-001..C-005 + ENG-111 B-001..B-006 still pass (the strip_re extension in Task 4 is a superset; existing properties must be preserved).

## Frontend Tasks

(none — the harness has no FE surface; all changes are in Bash orchestration scripts.)

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Agent-lane missing dispatch context (D-006) | `PIPELINE_WRITER=agent` with empty `PIPELINE_DISPATCH_ID` or `PIPELINE_STAGE` | `_render_event_header` returns 15; chokepoint propagates; `failure_outcome_for_exit 15` returns `header-missing-inputs` | unit | bin/linear-test.sh::H-008 agent fail-closed missing inputs |
| Agent-lane hand-rolled header (D-009-b) | `PIPELINE_WRITER=agent` posting body whose first non-blank line matches `^\[ENG-[0-9]+ · ` | Chokepoint rejects with rc=14; structured stderr; `failure_outcome_for_exit 14` returns `legacy-marker-write` | unit | bin/linear-test.sh::H-012 agent header-spoof rejected |
| Human lane unwanted decoration (D-005) | `PIPELINE_WRITER=human` posting free-form operator note | Header injection bypassed; body posted verbatim | unit | bin/linear-test.sh::H-009 human lane bypass |
| Body has no recognised marker AND no sig (Priority 4 fallback) | `add_comment` with pure prose body, no sig | Event-type = `COMMENT`, summary = first non-blank non-marker line truncated to 80 chars | unit | bin/linear-test.sh::H-009 (asserts header form on a prose body) + manual smoke |
| Byte-equal re-apply across iso-ts rotation (D-007) | `add_or_update_comment` twice with identical content; iso-ts rotates between calls | `strip_re` extension drops header lines; `existing_norm == new_norm` fires; ENG-63 rotating footer appended | unit | bin/linear-test.sh::H-010 byte-equal modulo header |
| Centralisation violation (AC #2) | Header glyph pattern leaks into a non-helper file | grep across `bin/` returns no extra matches | unit | bin/linear-test.sh::H-011 grep-source-of-truth |
| Verdict path emits canonical header | Agent `bash bin/pipeline.sh event ENG-N verdict pass --stage X` → chokepoint | Body opens with `[ENG-N · X · d<NNNN> · <ts> · agent]\nPASS — stage X complete` followed by marker | unit | bin/linear-test.sh::H-001 verdict.pass |
| Halt verdict path emits canonical header | Agent posting `<!-- pipeline: verdict result=halt reason=<R> -->` body | Second line = `HALT — <R>` | unit | bin/linear-test.sh::H-002 verdict.halt |
| Completion summary path emits canonical header | Orchestrator `add_or_update_comment "completion/<stage>/<id>" ...` | Second line = `COMPLETION — stage <stage> summary` (sig-derived) | unit | bin/linear-test.sh::H-003 completion |
| Scope-approval path emits canonical header | `add_or_update_comment "scope-approval/<stage>/<id>" ...` | Second line = `SCOPE-APPROVAL — <stage>` | unit | bin/linear-test.sh::H-004 scope-approval |
| Counter-bump (meta marker) emits header | `add_comment` body containing `<!-- meta: metric name=<n> -->` | Second line = `COUNTER-BUMP — <n>` | unit | bin/linear-test.sh::H-005 counter-bump |
| Last-review-state emits header | `add_or_update_comment "last-review-state/<id>" ...` | Second line opens `LAST-REVIEW-STATE` | unit | bin/linear-test.sh::H-006 last-review-state |
| TDD-evidence emits header | `add_or_update_comment "tdd-evidence/<stage>/<id>" ...` | Second line = `TDD-EVIDENCE — stage <stage>` | unit | bin/linear-test.sh::H-007 tdd-evidence |
| Orchestrator manual header (rare) | `PIPELINE_WRITER=orchestrator` posting body that starts with `[ENG-... · ...` | Chokepoint detective does NOT fire (agent-lane only); canonical header prepended ABOVE the manual one; both visible | unit | bin/linear-test.sh::H-013 orchestrator manual header allowed |
| ENG-63 footer rotation preserved | Identical body re-apply across two `add_or_update_comment` calls | Strip_re extension preserves byte-equal property; footer fires once, prior footer NOT stacked | unit | bin/linear-test.sh::ENG-63 C-001 + H-010 |
| ENG-111 breadcrumb preserved | Body-change `add_or_update_comment` update | Breadcrumb body goes through chokepoint, gets its own header, breadcrumb marker still present | unit | bin/linear-test.sh::ENG-111 B-002 (already passing; verify regression-free in Task 10) |
| Lane fence still classifies correctly post-header | Agent-lane post whose body's FIRST line is a transition marker | `_classify_comment_body` (run BEFORE header inject per D-011) classifies as `transition_comment`; `add transition_comment` lane fence denies agent-lane → rc=13 | unit | bin/linear-test.sh existing lane-fence tests (regression-only) + H-012 indirectly pins ordering |

## Test Strategy

**Unit (primary).** All 13 new ENG-151 tests live in `bin/linear-test.sh` (sibling-pattern per D-010, no new test file). They use the existing capture-file machinery (`_eng63_capture_file` / `_eng111_capture_file` precedent — A-010) under `PIPELINE_DRY_RUN=0` with a stubbed `linear_query` that captures `commentCreate` / `commentUpdate` body argument to a temp file. Coverage matches AC #3's enumerated event-type list (verdict, completion, halt, scope-approval, counter-bump, last-review-state, tdd-evidence) plus AC #4's fail-closed (H-008) and AC #2's source-of-truth (H-011), plus the D-009-b chokepoint detective (H-012) and the D-005 human-lane bypass (H-009).

**Regression (existing tests).** ENG-63 C-001..C-005 + ENG-111 B-001..B-006 must continue to pass after Task 4 extends `strip_re`. The new alternation-anchored line-2 strip pattern is the design fix from coherence persona iter-1 P0; tests pin that caller prose like `TODO — fix later` does NOT get stripped (H-010 implicitly covers this — the canned existing body uses non-event-type prose to prove the strip stays narrow).

**Integration.** Not required for this ticket. The chokepoint is the integration point; D-009 + D-008 explicitly state that no caller-side refactors are needed. The agent prompt's new paragraph (Task 7) plus the pipeline-vocabulary doc (Task 8) are the human-facing integration surfaces; their content is covered by `bin/agent-prompts-content-test.sh` and `bin/vocabulary-cleanliness-test.sh` (gate run in Task 10).

**Smoke.** Manual smoke after implementing (Task 1 manual smoke commands + Task 10 pre-commit gate). No additional smoke beyond the pre-commit suite is required — the chokepoint is fully exercised by the unit suite.

**Adversarial.** Two adversarial scenarios are explicitly covered:
1. **Hand-rolled header by agent (D-009-b)** — H-012 asserts the chokepoint detective rejects the agent-lane attempt with rc=14.
2. **Over-broad strip_re (design persona P1 iter-1)** — the closed-event-type alternation in Task 4 means `TODO — fix later` is preserved through `strip_re`; H-010's canned body deliberately includes a non-event-type uppercase prefix to pin this property (`TODO — line preserved` in the existing-body prose).

**Test-gate closure sweep (per learned-rules feasibility):**
- **Add-side**: Task 9 extends `bin/linear-test.sh`, which is ALREADY in `learned-rules/harness/project-profile.md::"## Build & test gates"` Test command (`project-profile.md:17`) AND the implementing+qa allowlists (`:43, :88`). No new test file is being created; the profile does NOT need editing. Documented explicitly per A-011.
- **Remove-side**: No tokens, allowlist entries, function names, enum variants, or defaults are being REMOVED from production code by this plan. The single `strip_re` modification (Task 4) ADDS strip patterns; the original `<!-- meta: (reapplied at=|dispatch id=)` arm is preserved unchanged so any sibling test grepping for that pattern continues to match.

**Test-gate closure verification:**
- `grep -nE 'strip_re|reapplied at=|dispatch id=' bin/*-test.sh` shows only matches in `bin/linear-test.sh` itself (the ENG-63 + ENG-111 blocks), which are extended/preserved by this plan — confirmed via Read of `bin/linear-test.sh:520-967` during plan drafting.
