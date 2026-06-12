---
linear: ENG-150
date: 2026-06-10
topic: linear.sh — delete add-or-update-comment, migrate all callers to add-comment with --sig flag and /d<NNNN> dispatch-suffixed sigs
---

# ENG-150 — Plan

## Anti-anchoring check

- **Problem restatement.** Every harness "canonical comment per logical
  event" write (halt, completion, protocol-violation, worktree-mutation,
  retry-pending, last-review-state, core-bare-flip) calls
  `bin/linear.sh add-or-update-comment`, which `commentUpdate`s in place
  on re-emission. `commentUpdate` preserves the original `createdAt`, so
  the chronological feed lies: a halt that re-fires under dispatch d0008
  still shows the d0001 timestamp. ENG-63 and ENG-111 layered footer /
  breadcrumb workarounds; this ticket removes the contract violation at
  the root by deleting the API and making every emission append a fresh
  comment carrying a dispatch-suffixed sig.
- **Brainstorm alignment.** The brainstorm's D-001 (delete the function),
  D-002 (sig shape `<category>/<stage>/<issue>/d<NNNN>`), D-003 (new
  `--sig` flag on `add_comment`), D-008 (eight caller migrations) is a
  direct match to the issue's acceptance criteria. No reframing.
- **Solution proportionality.** ~25 lines added to `add_comment`
  (sig parser + body validator + marker append + hash-dedup skip);
  ~135 lines deleted (the whole `add_or_update_comment` function); 8
  call-site mechanical migrations; 12 test files updated; one CLAUDE.md
  paragraph swap; one operator-runbook section rewrite; 14 AGENT_PROMPTS.md
  hits split into prose rewrite + literal-command swap. Proportional
  — the bulk is mechanical caller migration, not new design.

## Assumption Inventory

**Branch-base freshness.** `git log --oneline HEAD..origin/main` was
NON-EMPTY at plan time — 21 commits ahead. ENG-151 (header-line on every
harness-written comment), ENG-153 (`guards.sh: require --reason on bump`),
ENG-120 (within-stage iteration loop directive in AGENT_PROMPTS.md §3),
ENG-160 (progress.md seeding) all landed. The single material overlap is
ENG-151: it added `_render_event_header` + `_derive_event_type_and_summary`
helpers, wraps the existing `add_comment` AND `add_or_update_comment`
with a header-injection block, and threads `$sig` into the type-derivation
inside `add_or_update_comment` (P1 sig-derivation surfaces COMPLETION /
HALT / PROTOCOL-VIOLATION / etc. on the rendered header line). Clean drift
— ENG-151's additions interact with ENG-150 in a known shape (the new
`add_comment --sig` path threads the sig into `_derive_event_type_and_summary`
so the header derivation still fires under append-only, matching what
`add_or_update_comment` did pre-delete) but no commit on origin/main
rewrites or removes the call sites this plan migrates. Task 0 rebases;
content anchors below survive the rebase. Every `path:line` in this
inventory was verified against the CURRENT (pre-rebase) tree; the
content anchors carry the same shape post-rebase (verified via
`git show origin/main:bin/linear.sh` for the chokepoint sites).

| # | Assumption | Status | Verification |
|---|---|---|---|
| A-1 | `add_or_update_comment` function lives in `bin/linear.sh` between header line `add_or_update_comment() {` and the matching closing `}` ~130 lines below | **verified** | `bin/linear.sh:576-708` (current); `git show origin/main:bin/linear.sh` shows `add_or_update_comment() {` at line 817, closing `}` at ~990; ENG-151 inserted the header-injection block at lines 831-857 inside the function body |
| A-2 | The dispatcher arm `add-or-update-comment) add_or_update_comment "$@" ;;` is the sole reference inside `linear.sh::main`'s `case` switch | **verified** | `bin/linear.sh:768` (current); post-rebase line 1070 — same shape |
| A-3 | The header doc reference `(same flags accepted by add-or-update-comment, after the <sig> argument)` is the only mention in the header-comment block above `set -euo pipefail` | **verified** | `bin/linear.sh:17` (current); post-rebase same line |
| A-4 | `add_comment` lives in `bin/linear.sh` between `add_comment() {` and the closing `}` ~80-150 lines below; it composes body via `_resolve_body_arg → _reject_legacy_marker_body → _classify_comment_body + _check_lane → (ENG-151 header inject) → _inject_dispatch_marker → DRY_RUN short-circuit → hash-dedup arm → commentCreate` | **verified** | `bin/linear.sh:496-574` (current — pre-ENG-151); `git show origin/main:bin/linear.sh` (post-rebase: `add_comment` at line 708, closing `}` at line 815; the ENG-151 header-inject block sits at lines 719-744 between `_check_lane` and `_inject_dispatch_marker`) |
| A-5 | The existing hash-dedup-skip predicate is `if [[ "$body" == *'<!-- pipeline: '* ]]; then : # fall through; else <hash dedup>; fi` | **verified** | `bin/linear.sh:528-530` (current); post-rebase `bin/linear.sh:769-771` (line shifted by ENG-151's insertion above) — same shape |
| A-6 | `_inject_dispatch_marker` reads `PIPELINE_DISPATCH_ID` env, no-ops when unset, idempotency check is `grep -qF "<!-- meta: dispatch id=${PIPELINE_DISPATCH_ID-} "` (trailing space, current-id-specific) | **verified** | `bin/linear.sh:60-77` (current and post-rebase — ENG-151 did not touch this helper) |
| A-7 | `_resolve_body_arg` consumes `--body / --body-file / --body= / --body -` (stdin) + `--` separator + final-positional fallback; unknown args are silently dropped (shifts past them) | **verified** | `bin/linear.sh:444-494` (current); ENG-151 did not modify this helper |
| A-8 | `PIPELINE_DISPATCH_ID` format is `ENG-<N>-d<NNNN>` (zero-padded 4-digit sequence); `bin/common.sh::_allocate_dispatch_id_locked` is the sole writer via `printf '%s-d%04d' "$issue" "$seq"` | **verified** | `bin/common.sh:144` (`printf '%s-d%04d'`); ENG-151 didn't change `common.sh` |
| A-9 | `bin/run-stage.sh::post_completion_comment` calls `bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body"` twice (first attempt + retry-once after 5-second sleep) with `sig="completion/${stage}/${issue}"` | **verified** | `bin/run-stage.sh:424,428`; ENG-151 did not touch this function |
| A-10 | `bin/run-stage.sh`'s worktree-mutation breadcrumb post calls `bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "worktree-mutation/$ident" "$ident" "$_body"` with `\|\| log "linear.sh add-or-update-comment failed for worktree-mutation/$ident (non-blocking)"` | **verified** | `bin/run-stage.sh:680-682`; ENG-151 didn't touch this function |
| A-11 | `bin/classify-failure.sh::classify_failure` posts halt verdicts at the literal line `bash "$_CFS_SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body" \|\| true` with `sig="halt/$stage/$issue"` inside the `skip-until-*` case arm | **verified** | `bin/classify-failure.sh:188` (sig assignment at line 170); no main drift |
| A-12 | `bin/classify-failure.sh::classify_failure` posts retry-pending notifications at the literal line `bash "$_CFS_SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body" \|\| true` with `sig="retry-pending/$stage/$issue"` inside the `retry-immediately` case arm | **verified** | `bin/classify-failure.sh:196` (sig assignment at line 191); no main drift |
| A-13 | `bin/verdict-handler.sh::_vh_protocol_violation` posts via `bash "$_VH_SCRIPT_DIR/linear.sh" add-or-update-comment "protocol-violation/$case_id/$issue" "$issue" "$body" \|\| true` | **verified** | `bin/verdict-handler.sh:56-57`; no main drift |
| A-14 | `bin/review-state.sh::bootstrap_review_state` posts via `bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "last-review-state/$issue" "$issue" "$body"` (no fallback) | **verified** | `bin/review-state.sh:45`; no main drift |
| A-15 | `bin/review-state.sh::update_review_state` posts via `bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "last-review-state/$issue" "$issue" "$body"` (no fallback) | **verified** | `bin/review-state.sh:53`; no main drift |
| A-16 | `bin/run-local-helpers.sh::_handle_core_bare_flip` posts the forensic announcement via `bash "$HARNESS_ROOT/bin/linear.sh" add-or-update-comment "core-bare-flip/${_utc_day}" "$_post_issue" --body - <<EOF … EOF \|\| true` (heredoc-stdin form) | **verified** | `bin/run-local-helpers.sh:877-878`; no main drift |
| A-17 | `bin/review-state.sh::read_review_state` already uses `[.[] \| select(.body \| contains($m))] \| sort_by(.createdAt) \| last`, which is append-only-correct (returns latest by createdAt) | **verified** | `bin/review-state.sh:63-66`; no main drift |
| A-18 | `bin/verdict-handler.sh::find_fresh_verdict` selects by ENG-87 strict-`dispatch_id`-match (the comment body must carry `<!-- meta: dispatch id=$current_dispatch_id ... -->`), not by sig literal | **verified** | `bin/verdict-handler.sh:128-200` (the function is multi-block; the strict-id arm dominates when markers exist); no main drift |
| A-19 | `bin/poll.sh::_poll_emit_halt_sprawl_alert` counts classifier-output (`slot == "vacate"`), not comment bodies; it never greps by sig | **verified** | per brainstorm A-010 verified in iter-1; no main drift on `bin/poll.sh` |
| A-20 | `_reject_legacy_marker_body` rejects bodies matching `<!-- pipeline-(stage-summary|rejection|rejection-target|halt|wait|decision|sig|metric|transition): [^>]+ -->`; the new shape `<!-- meta: dedup key=… -->` is NOT in this regex and will pass through | **verified** | `bin/linear.sh:429-441` (current); ENG-151 didn't touch this helper |
| A-21 | The 6 production callers + 2 lines in `post_completion_comment` (first + retry) = 8 distinct `add-or-update-comment` invocation lines across 7 categories: `completion`, `worktree-mutation`, `halt`, `retry-pending`, `protocol-violation`, `last-review-state`, `core-bare-flip` | **verified** | `grep -rn 'add-or-update-comment' bin/*.sh \| grep -v test \| grep -v '^bin/linear\.sh:'` returns exactly 8 hits (lines: run-stage.sh:424,428,680,682; classify-failure.sh:188,196; verdict-handler.sh:56-57; review-state.sh:45,53; run-local-helpers.sh:877) |
| A-22 | `bin/linear-test.sh` ENG-63 block runs `:512-762` (C-001..C-006 + AD-001..AD-005 adversarial cases); ENG-111 block runs `:764-963` (B-001..B-006); ENG-87 block runs `:967-1234` including the ENG-87-L4-int integration test at `:1117-1188` and ENG-87-L7 at `:1342-1418`; ENG-110 block runs `:1190-1245`; ENG-87-QA-adversarial at `:1246-1340`; ENG-87-L8 at `:1422-1448` | **verified** | `bin/linear-test.sh:512,764,967,1117,1190,1246,1342,1422`; `wc -l` = 1458 |
| A-23 | Post-rebase `bin/linear-test.sh` gains an ENG-151 block headered at line ~977 (H-001..H-013) ending where the next H3 `# ─── ENG-87` begins (post-rebase line ~1431); the block contains multiple `add_or_update_comment` invocations testing the header rendering on the upsert path (H-003, H-004, etc.) | **verified** | `git show origin/main:bin/linear-test.sh \| grep -n '^# ─── ENG-151\|^# ─── ENG-87\|^add_or_update_comment'` shows the ENG-151 H3 at line 977, next ENG-87 H3 at ~1431, and 8+ `add_or_update_comment` invocations between them |
| A-24 | `bin/run-stage-test.sh` linear.sh stub recognises the `add-or-update-comment)` case at line 281 inside its case-arm dispatcher; 4 prose/stub comment references at lines 281, 1012, 1834, 4345 | **verified** | `bin/run-stage-test.sh:281,1012,1834,4345` |
| A-25 | `bin/classify-failure-test.sh` capture stub records argv via `printf '%s\n' "$*"` flat space-delimited; assertions at lines 276, 319, 320, 324 match the literal prefix `add-or-update-comment retry-pending/implement/ENG-924b ENG-924b ` (followed by the body) | **verified** | `bin/classify-failure-test.sh:276,319-324` |
| A-26 | `bin/verdict-handler-test.sh` has `calls_contains` assertions at lines 228, 244, 261, 281, 312 with the literal token `add-or-update-comment protocol-violation/<case>/<issue> <issue>`; the linear.sh stub case allowlist at line 980 reads `add-label\|remove-label\|add-comment\|add-or-update-comment) printf 'ok' ;;` | **verified** | `bin/verdict-handler-test.sh:34,228,244,261,281,312,980` |
| A-27 | `bin/review-state-test.sh` linear.sh stub captures the `add-or-update-comment)` case at line 32; the stub case-arm sets `\$1=add-or-update-comment \$2=sig \$3=issue \$4=body` (comment at line 33 documents this) | **verified** | `bin/review-state-test.sh:23,32-34` |
| A-28 | `bin/halt-sprawl-test.sh` linear.sh stub case allowlist at line 67 reads `remove-label\|add-label\|swap-stage\|transition-state\|add-comment\|add-or-update-comment\|refresh-cache\|stage-of\|has-label)`; halt-sprawl reads classifier output, NOT comment bodies — the stub allowlist is the ONLY reference and removing the token is a one-line edit | **verified** | `bin/halt-sprawl-test.sh:67`; halt-sprawl-adversarial-test.sh contains zero hits |
| A-29 | `bin/poll-slot-test.sh` linear.sh stub case allowlist at lines 78 AND 1233 carries the same `\|add-or-update-comment\|` token (two stubs in the same file — one for each test block) | **verified** | `bin/poll-slot-test.sh:78,1233` |
| A-30 | `bin/verdict-adversarial-test.sh` has assertions at lines 199 (replay enhancement comment), 243 (`A23` calls_contains literal), 413-426 (A23 classify-failure double-apply pin) with the literal token `linear.sh [add-or-update-comment] [halt/implement/ENG-N] [ENG-N]` | **verified** | `bin/verdict-adversarial-test.sh:199,243,413,417,423,426` |
| A-31 | `bin/agent-prompts-content-test.sh` has prose comment references at lines 777, 778, 860 — narrative prose only, no literal command assertions | **verified** | `bin/agent-prompts-content-test.sh:776-860` |
| A-32 | `bin/vocabulary-cleanliness-test.sh` has one prose comment at line 9 (`# handler::apply_transition, poll auto-resume, linear::add_or_update_comment,`) — narrative-only | **verified** | `bin/vocabulary-cleanliness-test.sh:9` |
| A-33 | `CLAUDE.md:700-704` contains the `meta: dedup` paragraph under the `## When wiring a new script` H2 heading at line 695 | **verified** | `CLAUDE.md:695,700-704` |
| A-34 | `docs/runbooks/operator-mental-model.md:136-157` contains `## §3 — Comment dedup invisibility <a id="sig-dedup"></a>` and a `bash bin/linear.sh query` recipe demonstrating the dedup-update detection | **verified** | `docs/runbooks/operator-mental-model.md:136-157` |
| A-35 | `AGENT_PROMPTS.md` has 14 hits for `add-or-update-comment\|add_or_update_comment` total — mix of narrative prose AND literal command examples agents are instructed to execute | **verified** | `grep -c 'add-or-update-comment\|add_or_update_comment' AGENT_PROMPTS.md` = 14 |
| A-36 | The closed-vocabulary registry `bin/pipeline-events.json::meta_kinds` array carries `["dedup","metric","evidence","reapplied","forensic","dispatch","breadcrumb"]`; auto-generated vocabulary doc iterates this array | **verified** | per brainstorm A-007; `bin/pipeline-events.json` unchanged on main |
| A-37 | ENG-151's `_derive_event_type_and_summary` helper accepts an OPTIONAL second arg (the sig prefix) and uses P1 sig-derivation to map `halt/*`, `completion/*`, `protocol-violation/*`, etc., to the matching event-type token; passing empty sig falls through to P2 (pipeline-marker body content) or P4 (prose). Post-rebase `add_comment` at the chokepoint calls `_derive_event_type_and_summary "$body" ""` (empty sig); post-ENG-150 the new `--sig` flow needs to thread `"$sig"` (the full suffixed sig) into this call so the header renders with the correct EVENT-TYPE token | **verified** | `git show origin/main:bin/linear.sh` shows `_derive_event_type_and_summary "$body" ""` in `add_comment` (line ~740) and `_derive_event_type_and_summary "$body" "$sig"` in `add_or_update_comment` (line ~853) — confirming the helper accepts both shapes and the post-cutover `add_comment --sig` path must mirror the upsert call form to preserve header-quality (otherwise halt re-fires render as `COMMENT — <body excerpt>` instead of `HALT — stage <stage> halt`) |
| A-38 | `bin/plan-schema.sh validate <file>` is the schema-v1 validator; rc=0 = valid; rc=33/34/35 = malformed / incomplete / missing-file; the canonical shape is documented in the file's header comment block at lines 1-37 | **verified** | `bin/plan-schema.sh:1-37` |

Assumptions A-37 is the only NEW-this-plan invariant — every other row
pins a current-tree code shape that the migration deletes, replaces, or
preserves. A-37 captures the cross-ticket interaction with ENG-151 that
the brainstorm could not anticipate (it was drafted against the pre-
ENG-151 `add_comment` body). The plan's Task 3 step accounts for it.

## File Structure

- `bin/linear.sh` — **modified** (delete `add_or_update_comment` body + dispatcher arm + header doc; extend `add_comment` with `--sig` parsing + body strip + dedup marker append + hash-dedup-skip on `--sig`; thread sig into `_derive_event_type_and_summary`)
- `bin/run-stage.sh` — **modified** (`post_completion_comment` 2 lines; worktree-mutation breadcrumb 1 line; inline comments at `:372-379`, `:423`, `:664`, `:682`)
- `bin/classify-failure.sh` — **modified** (halt-arm + retry-pending arm: 2 lines)
- `bin/verdict-handler.sh` — **modified** (`_vh_protocol_violation` 1 line; inline comment at `:62`)
- `bin/review-state.sh` — **modified** (bootstrap + update: 2 lines)
- `bin/run-local-helpers.sh` — **modified** (`_handle_core_bare_flip` 1 line — heredoc `<<EOF` body form preserved)
- `bin/linear-test.sh` — **modified** (delete ENG-63 C+AD block; delete ENG-111 block; delete `add_or_update_comment` cases from ENG-87 block including L4-int + L7 reapplied-audit; **post-rebase: also delete ENG-151 H-003/H-004 upsert-lane cases that exercise `add_or_update_comment`**; ADD ENG-150 A-001..A-006 + B-LEG)
- `bin/run-stage-test.sh` — **modified** (stub case-arm at `:281`; comment refs at `:1012, 1834, 4345`)
- `bin/classify-failure-test.sh` — **modified** (capture-prefix assertions at `:276, 319-324`)
- `bin/verdict-handler-test.sh` — **modified** (`calls_contains` at `:228, 244, 261, 281, 312`; stub allowlist at `:980`)
- `bin/review-state-test.sh` — **modified** (stub case-arm at `:32-34`)
- `bin/halt-sprawl-test.sh` — **modified** (stub allowlist at `:67`, one-token removal)
- `bin/poll-slot-test.sh` — **modified** (stub allowlist at `:78` AND `:1233`, two-token removals)
- `bin/verdict-adversarial-test.sh` — **modified** (assertions at `:199, 243, 413-426`; seed `PIPELINE_DISPATCH_ID` per case)
- `bin/agent-prompts-content-test.sh` — **modified** (prose at `:776-860`)
- `bin/vocabulary-cleanliness-test.sh` — **modified** (prose at `:9`)
- `CLAUDE.md` — **modified** (replace paragraph at `:700-704` under the `## When wiring a new script` H2)
- `docs/runbooks/operator-mental-model.md` — **modified** (replace `## §3 — Comment dedup invisibility` section at `:136-157`)
- `AGENT_PROMPTS.md` — **modified** (14 hits: 9 prose rewrites + 5 literal-command swaps per D-010)

No new files. No new exit codes. No `failure_outcome_for_exit` taxonomy
change. `bin/pipeline-events.json::meta_kinds` UNCHANGED — `dedup` keeps
its registry slot (its semantic shifts from "deduplication key" to
"ledger discoverability tag" via the CLAUDE.md / runbook rewrite);
`reapplied` and `breadcrumb` keep their slots for legacy-comment read-back
(`docs/pipeline-vocabulary.md` regenerates from the registry on the next
sweep — no manual edit needed).

**Test-gate closure — remove-side.** The token `add-or-update-comment`
(string literal) AND `add_or_update_comment` (function-name shape) are
the soon-to-be-removed surfaces. `grep -rln 'add-or-update-comment\|add_or_update_comment' bin/*-test.sh`
returns hits in **10 test files**: `bin/agent-prompts-content-test.sh`,
`bin/classify-failure-test.sh`, `bin/halt-sprawl-test.sh`,
`bin/linear-test.sh`, `bin/poll-slot-test.sh`, `bin/review-state-test.sh`,
`bin/run-stage-test.sh`, `bin/verdict-adversarial-test.sh`,
`bin/verdict-handler-test.sh`, `bin/vocabulary-cleanliness-test.sh` —
ALL 10 appear in File Structure above, each with its own line-number
locator. Post-implement, an `assert-grep-clean` smoke (Task 14) re-runs
`grep -rn` and exits non-zero if any hit remains.

**Test-gate closure — add-side.** No new gate-runnable file is added
under `bin/*-test.sh`. The plan adds new test CASES to the existing
`bin/linear-test.sh` (which is already enumerated in
`learned-rules/harness/project-profile.md::## Build & test gates`'s
`Test:` line per `learned-rules/harness/project-profile.md:17`). No
project-profile edit is required.

## API Contract

no new API surface (this is harness-internal bash plumbing; no FE↔BE
handler, RPC, or wire-format change).

## Backend Tasks

### Task 0: Rebase onto origin/main
- `depends_on: []`
- `touches: bin/linear.sh, bin/linear-test.sh, AGENT_PROMPTS.md, CLAUDE.md (rebase-pull only — no edits in this task)`
- [ ] Run `git fetch origin && git rebase origin/main` from this feature branch. Expected: clean rebase pulling in the 21-commit drift dominated by ENG-151 (`bin/linear.sh` header-line additions at lines 76-294 + 716-748 + 826-858 + 936-957; `bin/linear-test.sh` H-001..H-013 block at lines ~977-1924), ENG-153 (`bin/guards.sh`), ENG-120 (`AGENT_PROMPTS.md` §3 iteration loop), ENG-160 (`bin/run-stage.sh::_ensure_progress_md` seeding).
- [ ] After rebase, re-verify the Assumption Inventory `path:line` references by spot-checking three anchors: (a) `grep -n '^add_or_update_comment' bin/linear.sh` should still hit ONE line (renamed to ~817 post-rebase, function still present pre-Task 1 delete); (b) `grep -n '^add_comment' bin/linear.sh` should still hit ONE line (~708 post-rebase); (c) `grep -c 'add-or-update-comment\|add_or_update_comment' AGENT_PROMPTS.md` should still equal 14 (ENG-151 + ENG-120 did NOT touch the AGENT_PROMPTS.md references this plan migrates). If any anchor shifted unexpectedly, STOP and re-audit before Task 1.
- [ ] DO NOT touch any file in the rebase pull. All edits below are post-rebase content-anchored.

### Task 1: Extend `add_comment` with `--sig` flag in `bin/linear.sh`
- `depends_on: [0]`
- `touches: bin/linear.sh::add_comment`
- [ ] In `bin/linear.sh`, at the TOP of `add_comment` (content anchor: the line `local ident="$1"; shift` which is the FIRST line inside the function body — appears once per ENG-151 post-rebase + once in the pre-ENG-150 body), INSERT a sig-parsing block BEFORE the existing `body="$(_resolve_body_arg "$@")"` line:

      # ENG-150 D-003: pull --sig out of args BEFORE _resolve_body_arg so
      # the body resolver sees only its native flag set. Empty sig =
      # caller did not opt into the append-only ledger contract; behaviour
      # is bit-identical to today's add_comment (no marker append, hash
      # dedup runs).
      local sig=""
      local _rest=()
      while (( $# > 0 )); do
        case "$1" in
          --sig)
            [[ $# -ge 2 ]] || die "linear.sh add-comment: --sig requires a value"
            sig="$2"; shift 2
            ;;
          --sig=*)
            sig="${1#--sig=}"; shift
            ;;
          *)
            _rest+=("$1"); shift
            ;;
        esac
      done
      set -- "${_rest[@]}"

      # ENG-150 D-007 sig validation: reject characters that would corrupt
      # the marker shape (newline splits the marker over multiple lines;
      # the literal `-->` closes the HTML comment early; NUL is jq-toxic).
      if [[ -n "$sig" ]]; then
        if [[ "$sig" == *$'\n'* || "$sig" == *'-->'* || "$sig" == *$'\0'* ]]; then
          die "linear.sh add-comment: --sig contains illegal characters (newline / --> / NUL)"
        fi
      fi

- [ ] In `add_comment`, AFTER the existing `body="$(_inject_dispatch_marker "$body")"` line (content anchor: the literal `body="$(_inject_dispatch_marker "$body")"` substring — appears once in `add_comment` per A-4) AND BEFORE the existing DRY_RUN short-circuit `if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then` line, INSERT:

      # ENG-150 D-003 + D-007a: when --sig set, defensively strip any
      # caller-embedded `<!-- meta: dedup key=... -->` line (prevents the
      # chokepoint's appended marker from becoming the SECOND such line on
      # the wire when an agent stage-summary quoted a fixture body), then
      # suffix with /d<NNNN> from PIPELINE_DISPATCH_ID and append the
      # canonical dedup marker. dispatch_seq is empty when
      # PIPELINE_DISPATCH_ID is unset (operator-manual / test-fixture
      # path), producing the legacy suffix-less sig shape that the
      # back-compat reader recipe (D-006) handles uniformly.
      if [[ -n "$sig" ]]; then
        body="$(printf '%s' "$body" | sed -E '/^<!-- meta: dedup key=.* -->$/d')"
        local dispatch_seq=""
        if [[ -n "${PIPELINE_DISPATCH_ID-}" ]]; then
          dispatch_seq="${PIPELINE_DISPATCH_ID##*-}"
        fi
        local full_sig="${sig}${dispatch_seq:+/${dispatch_seq}}"
        body+=$'\n\n'"<!-- meta: dedup key=${full_sig} -->"
      fi

- [ ] In `add_comment`, REPLACE the hash-dedup-skip predicate. Content anchor: the existing line `if [[ "$body" == *'<!-- pipeline: '* ]]; then` (per A-5). Change to:

      # ENG-150 D-007: skip hash dedup on any caller that passed --sig
      # (declaring append-only ledger semantics) OR on the existing
      # pipeline-marker bypass. The two checks are independent — verdict
      # posts via bin/pipeline.sh::cmd_event_verdict don't pass --sig but
      # do carry `<!-- pipeline: verdict ... -->` markers; ledger posts
      # via D-008 don't carry pipeline markers but DO pass --sig.
      if [[ "$body" == *'<!-- pipeline: '* ]] || [[ -n "$sig" ]]; then

### Task 2: Thread `$sig` into ENG-151 header derivation in `add_comment`
- `depends_on: [1]`
- `touches: bin/linear.sh::add_comment (ENG-151 header-injection block)`
- [ ] In `add_comment`, REPLACE the `_derive_event_type_and_summary "$body" ""` call inside the ENG-151 header-injection `case ... esac` block (content anchor: the literal substring `IFS=$'\t' read -r _event_type _summary < <(_derive_event_type_and_summary "$body" "")` — appears once inside the `*)` arm of the post-rebase header-injection case). Change the trailing `""` to `"$sig"` so the new `--sig` path benefits from P1 sig-derivation (HALT / COMPLETION / WORKTREE-MUTATION / etc.) and the legacy no-sig path keeps its P2/P4 body-content derivation:

      IFS=$'\t' read -r _event_type _summary < <(_derive_event_type_and_summary "$body" "$sig")

- [ ] No other changes to the ENG-151 header-inject block. The placement (AFTER `_check_lane`, BEFORE `_inject_dispatch_marker`) is correct for the new sig path: the dedup-marker append in Task 1 happens AFTER both the header and the dispatch marker, so the rendered comment ends with `<header>\n\n<body>\n\n<!-- meta: dispatch id=... -->\n\n<!-- meta: dedup key=...-->`.

### Task 3: Delete `add_or_update_comment` function + dispatcher arm + header doc
- `depends_on: [2]`
- `touches: bin/linear.sh::add_or_update_comment (deletion), bin/linear.sh::main (dispatcher), bin/linear.sh header comment`
- [ ] In `bin/linear.sh`, DELETE the entire `add_or_update_comment` function. Content anchor: the line `add_or_update_comment() {` through its matching closing `}` (post-rebase: function spans `add_or_update_comment() { ... }`, ~180 lines including ENG-63 byte-equal-modulo-noise arm, ENG-111 breadcrumb arm, ENG-87 dispatch-marker inject, ENG-151 header inject + H-017 re-prepend). Use `awk '/^add_or_update_comment\(\)/,/^}/'` to confirm boundaries before deletion. NOTHING from this function is retained — every guard inside it (legacy-marker reject, lane fence, dispatch-marker inject, dedup-marker append, ENG-63 footer, ENG-111 breadcrumb, ENG-151 header) is either preserved in `add_comment` (lane fence, dispatch-marker inject, header) or made obsolete by append-only semantics (footer, breadcrumb).
- [ ] In `bin/linear.sh::main`'s dispatcher `case` (content anchor: the line `add-or-update-comment) add_or_update_comment "$@" ;;` — appears once per A-2), DELETE the entire line.
- [ ] In `bin/linear.sh`'s header comment block (content anchor: the line `#   (same flags accepted by add-or-update-comment, after the <sig> argument)` per A-3), DELETE the entire line. The remaining `linear.sh add-comment` shape examples already cover the migrated callers' usage.

### Task 4: Migrate `bin/run-stage.sh` callers
- `depends_on: [3]`
- `touches: bin/run-stage.sh::post_completion_comment, bin/run-stage.sh worktree-mutation breadcrumb`
- [ ] In `bin/run-stage.sh::post_completion_comment`, REPLACE both call lines. Content anchor: the literal comment line `# Retry once on failure. add-or-update-comment appends the canonical sig itself.` followed by `if bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body"; then`, retry at `bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body"` (per A-9). Change to:

      # Retry once on failure. add-comment --sig stamps the dispatch-
      # suffixed dedup marker; each retry posts a fresh chronological
      # comment if the first one didn't land.
      if bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" --sig "$sig" --body "$comment_body"; then
        return 0
      fi
      sleep 5
      bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" --sig "$sig" --body "$comment_body"

- [ ] In `bin/run-stage.sh`'s worktree-mutation post path. Content anchor: the literal block beginning `bash "$SCRIPT_DIR/linear.sh" add-or-update-comment \` and continuing `"worktree-mutation/$ident" "$ident" "$_body"` then `\|\| log "linear.sh add-or-update-comment failed for worktree-mutation/$ident (non-blocking)"` (per A-10). Change to:

      bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" \
        --sig "worktree-mutation/$ident" --body "$_body" \
        || log "linear.sh add-comment failed for worktree-mutation/$ident (non-blocking)"

- [ ] Update three inline-comment references in `bin/run-stage.sh` that still reference `add-or-update-comment` semantics:
  - Content anchor: the comment block `# ENG-96: also strip ...` lines containing `the chokepoint at bin/linear.sh::add_or_update_comment owns this marker`. Replace `add_or_update_comment` with `add_comment` in that prose.
  - Content anchor: the comment `# Retry once on failure. add-or-update-comment appends the canonical sig itself.` — covered by the Task-4 first bullet above (replacement comment supplied inline).
  - Content anchor: the comment block beginning `# Operator-visibility: post a non-halting Linear comment` containing `Sig-deduped via add-or-update-comment`. Replace `Sig-deduped via add-or-update-comment` with `Append-only via add-comment --sig`.

### Task 5: Migrate `bin/classify-failure.sh` callers
- `depends_on: [3]`
- `touches: bin/classify-failure.sh::classify_failure (halt-arm + retry-pending arm)`
- [ ] In the `skip-until-*) ... skip-until-human-acts) marker_reason="agent-blocked" ;;` halt arm (content anchor: the literal line `bash "$_CFS_SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body" \|\| true` immediately preceding the `;;` of the skip-until-* arm, per A-11). Change to:

      bash "$_CFS_SCRIPT_DIR/linear.sh" add-comment "$issue" --sig "$sig" --body "$comment_body" || true

- [ ] In the `retry-immediately)` arm (content anchor: the literal line `bash "$_CFS_SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body" \|\| true` immediately preceding the `;;` of the retry-immediately arm, per A-12). Change to:

      bash "$_CFS_SCRIPT_DIR/linear.sh" add-comment "$issue" --sig "$sig" --body "$comment_body" || true

### Task 6: Migrate `bin/verdict-handler.sh::_vh_protocol_violation`
- `depends_on: [3]`
- `touches: bin/verdict-handler.sh::_vh_protocol_violation`
- [ ] In `_vh_protocol_violation`, REPLACE the call. Content anchor: the literal two-line block:

      bash "$_VH_SCRIPT_DIR/linear.sh" add-or-update-comment \
        "protocol-violation/$case_id/$issue" "$issue" "$body" || true

  (per A-13). Change to:

      bash "$_VH_SCRIPT_DIR/linear.sh" add-comment "$issue" \
        --sig "protocol-violation/$case_id/$issue" --body "$body" || true

- [ ] Update the inline comment immediately below this call (content anchor: the line containing `picks up the halt comment this function just posted via add-or-update-comment`). Replace `add-or-update-comment` with `add-comment`.

### Task 7: Migrate `bin/review-state.sh` callers
- `depends_on: [3]`
- `touches: bin/review-state.sh::bootstrap_review_state, bin/review-state.sh::update_review_state`
- [ ] In `bootstrap_review_state` (content anchor: the literal line `bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "last-review-state/$issue" "$issue" "$body"` inside the function body — per A-14). Change to:

      bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" --sig "last-review-state/$issue" --body "$body"

- [ ] In `update_review_state` (content anchor: the identical literal line — per A-15). Change to:

      bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" --sig "last-review-state/$issue" --body "$body"

### Task 8: Migrate `bin/run-local-helpers.sh::_handle_core_bare_flip`
- `depends_on: [3]`
- `touches: bin/run-local-helpers.sh::_handle_core_bare_flip`
- [ ] REPLACE the call line. Content anchor: the literal heredoc-opening block:

      bash "$HARNESS_ROOT/bin/linear.sh" add-or-update-comment \
        "core-bare-flip/${_utc_day}" "$_post_issue" --body - <<EOF || true

  (per A-16). Change to:

      bash "$HARNESS_ROOT/bin/linear.sh" add-comment \
        "$_post_issue" --sig "core-bare-flip/${_utc_day}" --body - <<EOF || true

  (`--body -` stdin form survives unchanged because `_resolve_body_arg` consumes `--sig` AFTER the Task-1 sig-parser strips it from argv. The closing `EOF` on its own line + the `|| true` are unchanged.)

### Task 9: Migrate `bin/linear-test.sh` — delete ENG-63 + ENG-111 + ENG-87 upsert cases + ENG-151 upsert cases; add ENG-150 cases
- `depends_on: [3]`
- `touches: bin/linear-test.sh (ENG-63 / ENG-111 / ENG-87 / ENG-151 blocks; new ENG-150 block)`
- [ ] In the ENG-55 block (content anchor: H3 header `# ─── ENG-55: _resolve_body_arg + add-comment / add-or-update-comment ────` at line ~410), MIGRATE the three `add_or_update_comment` direct-invocation cases at the END of the block (content anchors: the literal comment lines `# add_or_update_comment with --body - reads stdin and reaches dry-run.`, `# add_or_update_comment legacy positional body still works.`, `# add_or_update_comment with empty body dies.`). The cases exercise `_resolve_body_arg`'s body-shape acceptance via the upsert call — `_resolve_body_arg` is shared with `add_comment` post-cutover, so the behaviour the cases assert is preserved by rewriting each `add_or_update_comment "test/sig/ENG-55T" ENG-55T ...` to `add_comment ENG-55T --sig "test/sig/ENG-55T" ...`. Rename the `pass_at` / `fail_at` labels from `ENG-55 add_or_update_comment: ...` to `ENG-55 add_comment --sig: ...`. Also UPDATE the block's H3 header at line ~410 to drop `add-or-update-comment`: `# ─── ENG-55: _resolve_body_arg + add-comment body shapes ────`. Also UPDATE the prose at line 411 (`# \`add-comment\` and \`add-or-update-comment\` accept body via:`) to drop `and \`add-or-update-comment\``.
- [ ] DELETE the ENG-63 block. Content anchor: the line `# ─── ENG-63: add_or_update_comment identical-body footer (C-001..C-006) ──` through and including the line immediately before `# ─── ENG-111: breadcrumb-on-body-change in add_or_update_comment (B-001..B-006) ─` (per A-22; pre-rebase `:512-762`, post-rebase shifted by ENG-151 insertions but bracketed by the same H3 comments).
- [ ] DELETE the ENG-111 block. Content anchor: the line `# ─── ENG-111: breadcrumb-on-body-change in add_or_update_comment (B-001..B-006) ─` through and including the line immediately before `# ─── ENG-87: dispatch_id auto-injection in add_comment / add_or_update_comment ─` (per A-22).
- [ ] Within the ENG-87 block (content anchor: the H3 header `# ─── ENG-87: dispatch_id auto-injection in add_comment / add_or_update_comment ─`), DELETE the two `add_or_update_comment`-exercising sub-cases:
  - Case 87-L4-int integration test (content anchor: the literal comment `# Case 87-L4-int (review-iter-2 M6): integration test for` through and including the closing `unset _eng87_l4i_log _eng87_l4i_orig_log ...` line — per A-22 pre-rebase `:1117-1188`).
  - Case 87-L7 reapplied-audit (content anchor: the literal `# Case 87-L7-reapplied-audit: same byte body across two dispatches → footer.` through and including the `_iter7_l7_orig_dry_run _iter7_l7_orig_script_dir` unset line — per A-22 pre-rebase `:1390-1420`).

  The Case 87-L1, 87-L5, 87-L8, and ENG-87 QA-adversarial cases stay (they exercise `add_comment` and `_inject_dispatch_marker` directly).
- [ ] **Post-rebase only**: within the ENG-151 block (content anchor: the H3 header `# ─── ENG-151: header line on every harness-written comment (H-001..H-013) ──`), DELETE the H-003, H-004, H-005, etc. cases that exercise `add_or_update_comment`. Use `grep -n 'add_or_update_comment' bin/linear-test.sh` from inside the ENG-151 block to enumerate. Each case opens with a `# H-NNN:` comment line and closes with an `unset _eng151_h... ...` restore — content-anchor the block boundaries by `# H-NNN:` / `unset _eng151_hNNN_...`. Cases that exercise `add_comment` (header injection on the new chokepoint) stay; only the upsert-lane cases are deleted.
- [ ] ADD a new block `# ─── ENG-150: append-only ledger writes (A-001..A-006) ──` immediately after the (now-pruned) ENG-87 block AND before the FIRST ENG-110 H3 (content anchor: the FIRST occurrence of `# ─── ENG-110: agent-lane auto-injection ───────────────────────────────` — post-rebase line ~1657; there is a second ENG-110 H3 at ~1690 followed by additional ENG-87 sub-blocks at ~1713 / ~1809, so pin to the FIRST occurrence). The block exercises:
  - **A-001** — `PIPELINE_DISPATCH_ID=ENG-X-d0007 PIPELINE_STAGE=implementing PIPELINE_DRY_RUN=1 add_comment ENG-X --sig "halt/implementing/ENG-X" --body "halt body"`; assert the captured dry-run log contains both `<!-- meta: dispatch id=ENG-X-d0007 stage=implementing -->` AND `<!-- meta: dedup key=halt/implementing/ENG-X/d0007 -->`.
  - **A-002** — same call with `PIPELINE_DISPATCH_ID` UNSET; assert the captured log contains `<!-- meta: dedup key=halt/implementing/ENG-X -->` (no `/d<NNNN>` suffix) AND no dispatch marker.
  - **A-003** — two `add_comment --sig "halt/implementing/ENG-X" ...` invocations with distinct PIPELINE_DISPATCH_ID (`ENG-X-d0007` then `ENG-X-d0008`) under non-dry-run stubs (mirror ENG-87 L4-int's `linear_query` stub shape but capturing `commentCreate` only); assert TWO distinct `commentCreate` mutations captured (no `commentUpdate`).
  - **A-004** — same dispatch, same sig, BYTE-IDENTICAL bodies — TWO calls; per Task 1 hash-dedup-skip rule (skip on `--sig`), assert TWO `commentCreate` mutations captured. (NOT one — the ledger contract is "every emission appends".)
  - **A-005** — back-compat reader fixture: construct a comment-list JSON payload with one legacy `<!-- meta: dedup key=halt/X/Y -->` comment (createdAt=2026-01-01) and three post-cutover `…/d0007`, `…/d0008`, `…/d0009` comments (createdAt=2026-01-02/03/04); assert the prefix-match-sort-latest jq recipe `[.[] | select(.body | contains("<!-- meta: dedup key=halt/X/Y")) ] | sort_by(.createdAt) | last | .id` returns the `…/d0009` comment id. Confirms D-006.
  - **A-006** — `add_comment ENG-X --body "no sig"` (NO `--sig`); assert behaviour unchanged from today (lane fence + dispatch marker inject + hash dedup all run; no dedup marker appended). Pins that the `--sig` flag is opt-in.
  - **A-007** — sig-content validation: `add_comment ENG-X --sig $'halt/implementing/\nENG-X' --body "x"` exits non-zero with stderr containing `illegal characters`. Same for `--sig "halt/--><script>"`. Confirms D-007 sig validation.
- [ ] ADD case **B-LEG**: legacy single-comment shape under sig `last-review-state/ENG-X` (no `/d<NNNN>` suffix); `read_review_state` returns its JSON payload correctly. Confirms D-006 back-compat for the review-state read path. (The block contains exactly one comment matching the marker; sort_by-last picks it; existing `read_review_state` jq pipeline is unchanged so the assertion is read-only.)
- [ ] **Prose-only mop-up** — in `bin/linear-test.sh`, prose-comment references to the deleted `add_or_update_comment` symbol survive inside test blocks that this plan does NOT delete. First ENUMERATE every surviving hit (post all preceding deletes in this Task) by running `grep -nF 'add_or_update_comment' bin/linear-test.sh`; this is the authoritative site-list. Then update EACH hit to `add_comment` with a `(retired in ENG-150)` parenthetical where the prose explains historical context. Known surviving sites at plan time (the enumerated grep IS authoritative if the post-rebase tree differs):
  - **ENG-151 block intro prose** at line ~978 — content anchor `# bin/linear.sh::add_comment / add_or_update_comment auto-prepend a`. Drop ` / add_or_update_comment` so the prose reads `# bin/linear.sh::add_comment auto-prepends a`. (The ENG-151 block H3 header at line ~977 does NOT contain the symbol — only the intro prose at ~978 does.)
  - **ENG-87 block H3 header** at line ~1431 — content anchor `# ─── ENG-87: dispatch_id auto-injection in add_comment / add_or_update_comment ─`. Rewrite the header to `# ─── ENG-87: dispatch_id auto-injection in add_comment ─` (drop ` / add_or_update_comment`).
  - **ENG-110 add_comment source-pin block** at lines ~1692-1694 — content anchor the prose lines `# Case 87-L4-int pinned inject-before-dedup ordering in` / `# add_or_update_comment via source-text grep (lines 967-979). The`. Rewrite to refer to `add_comment` only (or strike the historical reference entirely if the lines were a forward-pointer to the now-deleted L4-int case).
  - **ENG-87 QA-4 block** at lines ~1760-1765 — content anchor the prose lines `# QA-4 (foreign-dispatch update via add_or_update_comment).` / `# add_or_update_comment finds an in-flight comment under the same` / `# add_or_update_comment now under d0009 with a fresh body will:`. Replace `add_or_update_comment` with `add_comment` and add the parenthetical where the prose explains "the in-flight comment under the same `meta: dedup key=...`" (the append-only mode no longer finds an in-flight comment, so the QA-4 case prose needs re-explaining — re-purpose to describe the post-cutover semantic: "with append-only, this case demonstrates inject-stamps-current-id on a fresh comment whose body QUOTES a stale dispatch id in prose").
  - **ENG-87 Crit-4 block H4** at line ~1810 — content anchor `# ENG-63's add_or_update_comment byte-equal-modulo-marker arm strips`. Re-purpose the comment block: the byte-equal-modulo-marker arm was inside `add_or_update_comment` which is gone, so the QA-5/Crit-4 narrative becomes "historical context — strip semantics no longer exist; this test pins legacy behaviour observable in pre-cutover Linear comments". Or, if the Crit-4 case's underlying assertion was specific to the upsert path, DELETE the entire Crit-4 case (mirroring the L7 reapplied-audit deletion above).

  After all 5 prose sites are addressed, `grep -F 'add_or_update_comment' bin/linear-test.sh` returns 0.
- [ ] ADD a forensic consistency check **A-008** at the END of the new block: `if grep -rln 'add-or-update-comment\|add_or_update_comment' "$SCRIPT_DIR_REAL"/../bin/*.sh "$SCRIPT_DIR_REAL"/../bin/AGENT_PROMPTS.md "$SCRIPT_DIR_REAL"/../bin/CLAUDE.md 2>/dev/null \| grep -v -- '-test\.sh' \| grep -v 'docs/' ; then fail; fi` — mechanically pins AC #1 (grep returns zero hits in non-test bin/ + AGENT_PROMPTS.md).
- [ ] ADD a **second** forensic check **A-009** specifically for `bin/linear-test.sh` itself: `if grep -qF 'add_or_update_comment' "$SCRIPT_DIR_REAL"/../bin/linear-test.sh; then fail; fi` — pins the prose mop-up so F-4's pass criterion holds.

### Task 10: Migrate per-file test stubs (run-stage-test.sh, classify-failure-test.sh, verdict-handler-test.sh, review-state-test.sh, halt-sprawl-test.sh, poll-slot-test.sh, verdict-adversarial-test.sh)
- `depends_on: [3]`
- `touches: bin/run-stage-test.sh, bin/classify-failure-test.sh, bin/verdict-handler-test.sh, bin/review-state-test.sh, bin/halt-sprawl-test.sh, bin/poll-slot-test.sh, bin/verdict-adversarial-test.sh`

This task batches the mechanical stub + assertion updates across 7 test files. Each file is a literal-token edit; no test infra refactor.

- [ ] `bin/run-stage-test.sh`: REPLACE the `add-or-update-comment)` stub case-arm with an `add-comment)` arm that recognises the `--sig`/`--body` flag-form. Content anchor: the literal `add-or-update-comment)` opening line at `:281` and its `;;` terminator. The new arm parses `$@` for `--sig <val>` and `--body <val>` (or `--body -` from stdin), captures `SUBCMD=add-comment\nSIG=<sig>\nIDENT=<issue>\nBODY_BEGIN\n<body>\nBODY_END\n---`. Then update the THREE prose-comment refs at `:1012, 1834, 4345` from `add-or-update-comment` to `add-comment`.
- [ ] `bin/classify-failure-test.sh`: REPLACE the literal prefix `add-or-update-comment retry-pending/implement/ENG-924b ENG-924b ` at line 324 (and the sibling capture lookup pattern at `:276` `linear_calls | grep '^add-or-update-comment'`) with `add-comment ENG-924b --sig retry-pending/implement/ENG-924b --body ` (NOTE: the new flat-argv shape is `add-comment <issue> --sig <sig> --body <body>` — capture stub records argv verbatim so the literal-prefix assertion shifts to this new order). Likewise update the halt-sig assertions (sig pattern `halt/<stage>/<issue>`).
- [ ] `bin/verdict-handler-test.sh`: REPLACE the FIVE `calls_contains "add-or-update-comment protocol-violation/<case>/<issue> <issue>"` assertions at `:228, 244, 261, 281, 312` with `calls_contains "add-comment <issue> --sig protocol-violation/<case>/<issue>"` (the calls_contains substring needs to mirror the new flat-argv shape). At `:980`, REMOVE the `add-or-update-comment` token from the linear.sh stub's case-arm allowlist `add-label|remove-label|add-comment|add-or-update-comment) printf 'ok' ;;` so it reads `add-label|remove-label|add-comment) printf 'ok' ;;`. Update the prose comment at `:34` from `add-or-update-comment` to `add-comment`.
- [ ] `bin/review-state-test.sh`: REPLACE the `add-or-update-comment)` stub case-arm at `:32-34` with `add-comment)` parsing the new `--sig`/`--body` flag form. The capture lines `SUBCMD=add-comment\nSIG=<sig>...` mirror the comment at `:33` (which today says `$1=add-or-update-comment $2=sig $3=issue $4=body`); the new shape is `$2=issue` then `--sig <sig>` then `--body <body>`. The existing `SIG=last-review-state/ENG-X` literal in assertions stays valid when `PIPELINE_DISPATCH_ID` is unset in test env; for the post-cutover assertion, seed `PIPELINE_DISPATCH_ID=ENG-X-d0001` and assert `SIG=last-review-state/ENG-X/d0001`. ALSO update the line 23 prose comment from `Capture add-or-update-comment` to `Capture add-comment`.
- [ ] `bin/halt-sprawl-test.sh`: REMOVE the `|add-or-update-comment` token from the case-arm allowlist at `:67`. Single one-character edit (drop the `|add-or-update-comment` substring). No assertion change; halt-sprawl reads classifier output, NOT comment bodies (per A-19).
- [ ] `bin/poll-slot-test.sh`: REMOVE the `|add-or-update-comment` token from BOTH case-arm allowlists at `:78` AND `:1233` (two stubs in the same file).
- [ ] `bin/verdict-adversarial-test.sh`: For each case at `:199, 243, 413-426`, (a) seed `PIPELINE_DISPATCH_ID="ENG-<n>-d0001"` at the top of the case so the asserted sig has a deterministic `/d0001` suffix; (b) update the `calls_contains` literal `linear.sh [add-or-update-comment] [halt/implement/ENG-N] [ENG-N]` to the new flat-argv shape `linear.sh [add-comment] [ENG-N] [--sig] [halt/implement/ENG-N/d0001] [--body] [...]`. The bracket-around-arg format in calls_contains is the existing test idiom; the migration is a literal-string swap. Update the prose `A23` test name to drop the words `add-or-update-comment` (e.g. rename `A23 classify-failure: double-apply uses add-or-update-comment` to `A23 classify-failure: double-apply uses add-comment --sig`).

### Task 11: Migrate `bin/agent-prompts-content-test.sh` + `bin/vocabulary-cleanliness-test.sh` prose
- `depends_on: [3]`
- `touches: bin/agent-prompts-content-test.sh, bin/vocabulary-cleanliness-test.sh`
- [ ] In `bin/agent-prompts-content-test.sh`, update THREE prose-comment refs at `:777, 778, 860` from `add-or-update-comment` to `add-comment --sig`. Content anchors: the literal comment lines `# because the agent retried \`add-or-update-comment\` with mutated sigs every`, `# time a post appeared to fail. \`add-or-update-comment\` is idempotent —`, `# stdin support to bin/linear.sh's add-comment / add-or-update-comment via`. Note: the THIRD line lists both forms; update to read `bin/linear.sh's add-comment` (drop ` / add-or-update-comment`).
- [ ] In `bin/agent-prompts-content-test.sh`, ADD a new content assertion at the END of the file (before the `RESULTS:` print): `if grep -q 'add-or-update-comment\|add_or_update_comment' "$AGENT_PROMPTS_PATH"; then fail; fi`. Pins AC #1 for AGENT_PROMPTS.md from the test side (mirror of the bin/linear-test.sh A-008 forensic check; AGENT_PROMPTS.md gets its own assertion because the agent-prompts-content-test.sh dedicates itself to that file).
- [ ] In `bin/vocabulary-cleanliness-test.sh`, update ONE prose-comment ref at `:9`. Content anchor: the literal line `# handler::apply_transition, poll auto-resume, linear::add_or_update_comment,`. Change `linear::add_or_update_comment` to `linear::add_comment` (drop the legacy form).

### Task 12: Migrate AGENT_PROMPTS.md (14 hits: 9 prose + 5 literal commands)
- `depends_on: [3]`
- `touches: AGENT_PROMPTS.md`

The 14 hits split per brainstorm D-010 into 9 prose lines (substantive
rewrite — semantic shifts from in-place update to append-only) and 5
literal command examples (mechanical replacement). All 14 land in this
single task because partial migration leaves the agent reading
out-of-date prompts.

- [ ] **Prose rewrites — 9 sites** (lines per brainstorm D-010 + verified against current tree):
  - Line ~34 ("Comment dedup (ENG-15)") — content anchor: the prose subsection header about comment dedup. Rewrite to describe append-only behaviour: "`bash bin/linear.sh add-comment <issue> --sig <category>/<stage>/<issue> --body <body>` is the canonical write for a logical event. The chokepoint suffixes `/d<NNNN>` (the dispatch sequence from `PIPELINE_DISPATCH_ID`) and appends `<!-- meta: dedup key=<full-sig> -->` for operator grep. Every emission appends a fresh chronological comment; pre-ENG-150 dedup-update behaviour was retired."
  - Line ~36 ("Retry with the same sig — never mutate") — content anchor: the `Retry with the same sig — never mutate (ENG-57)` bullet. Rewrite to preserve the anti-pattern guidance under the new mechanism: pre-ENG-150 sig variants defeated dedup; post-ENG-150 sig variants defeat operator grep (the prefix-match recipe). Keep the bullet's core message ("retry with the same sig"); change the mechanism prose.
  - Line ~43 — content anchor: the prose mentioning `add_or_update_comment`'s lane fence. Update to point at `add_comment`'s lane fence (which is unchanged — same `_check_lane` call site).
  - Line ~93 — content anchor: the parenthetical `Use \`add-comment\`, NOT \`add-or-update-comment\``. DROP the negation entirely (the alternative no longer exists).
  - Lines ~223, ~225, ~362 — retry semantics + dispatch-id chokepoint documentation. Mechanical string-replace `add-or-update-comment` → `add-comment --sig` in each prose block (preserve surrounding sentence structure).
  - Lines ~1329, ~1352 — reviewing-stage prose about how the review summary is posted. Mechanical string-replace.

- [ ] **Literal-command swaps — 5 sites** (each is a bash invocation an agent is told to execute):
  - Lines ~343, ~665, ~916, ~1089, ~1311 — content anchor for each: the line beginning with `bash .pipeline/bin/linear.sh add-or-update-comment "<sig>"`. Replace with `bash .pipeline/bin/linear.sh add-comment "<issue>" --sig "<sig>"`. The body-form is unchanged (still `--body -` with a heredoc or `--body "<literal>"`). For line ~916 specifically (`tdd-evidence/implement/<issue>` sig), the same migration shape applies — the semantic shift is "each TDD-evidence checkpoint posts a fresh chronological comment instead of in-place updating the canonical".

- [ ] After ALL 14 migrations, run `grep -c 'add-or-update-comment\|add_or_update_comment' AGENT_PROMPTS.md` and confirm it returns 0. Any remaining hit is a P0 plan defect.

### Task 13: Update CLAUDE.md + docs/runbooks/operator-mental-model.md
- `depends_on: [3]`
- `touches: CLAUDE.md, docs/runbooks/operator-mental-model.md`
- [ ] In `CLAUDE.md`, REPLACE the paragraph at lines ~700-704. Content anchor: the `## When wiring a new script` H2 heading at line ~695 and the bullet beginning `- Linear writes go through \`bin/linear.sh\`` (per A-33). Replace the 5-line bullet with:

      - Linear writes go through `bin/linear.sh add-comment`, which is
        append-only — every emission produces a fresh chronological
        comment. Callers needing a discoverability tag pass
        `--sig <category>/<stage>/<issue>`; the chokepoint suffixes
        `/d<NNNN>` (the dispatch sequence from `PIPELINE_DISPATCH_ID`)
        and emits `<!-- meta: dedup key=… -->` on the body for operator
        grep (legacy marker name; semantic is "ledger discoverability
        tag", not deduplication). The `add-or-update-comment` API and
        its sig-based commentUpdate behaviour were retired in ENG-150.

- [ ] In `docs/runbooks/operator-mental-model.md`, REPLACE the §3 section at lines ~136-157. Content anchor: the H2 line `## §3 — Comment dedup invisibility <a id="sig-dedup"></a>` through and including the line immediately before the next H2 `## §...` (per A-34). Replace with:

      ## §3 — Comment chronology (append-only ledger) <a id="sig-dedup"></a>

      Linear comments posted by the harness are append-only — each
      emission is a fresh comment with its own `createdAt`. The
      `<!-- meta: dedup key=<category>/<stage>/<issue>/d<NNNN> -->`
      marker tags the dispatch that emitted the comment. The pre-ENG-150
      "dedup-update rewrites chronology" failure mode is gone; ENG-63's
      `<!-- meta: reapplied at=… -->` footer and ENG-111's
      `<!-- meta: breadcrumb sig=… -->` breadcrumb survive on legacy
      comments only (back-compat readable, never written by post-cutover
      code).

      Spot it (operator grep recipe — works for BOTH legacy and post-
      cutover comment shapes; prefix-match excludes the `-->` closing
      tag so the legacy `…ENG-N -->` AND post-cutover `…ENG-N/d0007 -->`
      both match):

      ```bash
      TARGET_REPO=/path/to/target bash bin/linear.sh get-comments ENG-N \
        | jq -r '.[] | select(.body | contains("<!-- meta: dedup key=halt/implementing/ENG-N"))
                     | "\(.createdAt) \(.body[0:120])"' \
        | sort | tail -1
      ```

      Halt fire-rate recovery: pre-ENG-150 the `<!-- meta: reapplied at=… -->`
      footer encoded "this halt re-fired N times". Post-cutover use:

      ```bash
      TARGET_REPO=/path/to/target bash bin/linear.sh get-comments ENG-N \
        | jq '[.[] | select(.body | contains("<!-- meta: dedup key=halt/implementing/ENG-N"))]
              | { count: length, first: .[0].createdAt, last: .[-1].createdAt }'
      ```

  This replaces the original §3 wholesale; the prose anchor (`<a id="sig-dedup"></a>`) is preserved so any external link to the section continues to resolve.

### Task 14: Verification
- `depends_on: [4, 5, 6, 7, 8, 9, 10, 11, 12, 13]`
- `touches: (read-only — runs gates)`
- [ ] Run `grep -rn 'add-or-update-comment\|add_or_update_comment' bin/ AGENT_PROMPTS.md CLAUDE.md docs/runbooks/operator-mental-model.md`. Expect EXACTLY zero hits. Any hit is a missed migration (P0 verification failure).
- [ ] Run the full test gate from the project profile's "Build & test gates" `Test:` line: `bash bin/dispatch-test.sh && bash bin/run-stage-test.sh && bash bin/poll-slot-test.sh && bash bin/scope-check-test.sh && bash bin/verdict-handler-test.sh && bash bin/classify-failure-test.sh && bash bin/halt-sprawl-test.sh && bash bin/halt-sprawl-adversarial-test.sh && bash bin/linear-test.sh && bash bin/metrics-test.sh && bash bin/mutex-test.sh && bash bin/setup-helpers-test.sh && bash bin/render-prompt-test.sh && bash bin/phase-project-profile-test.sh && bash bin/common-test.sh && bash bin/stuck-tick-alarm-test.sh` plus the additional `bash bin/review-state-test.sh && bash bin/verdict-adversarial-test.sh && bash bin/agent-prompts-content-test.sh && bash bin/vocabulary-cleanliness-test.sh`. Every test exits 0.
- [ ] Run `bash .githooks/pre-commit` (mirrors the gate the operator hits on commit).

## Frontend Tasks

no frontend (this is harness-internal bash plumbing).

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `add-or-update-comment` called after deletion | A caller missed in Task 4-8 still invokes it | `bin/linear.sh::main` dies with `unknown command: add-or-update-comment` | smoke | `bin/linear-test.sh::A-008` forensic grep |
| `add-comment --sig` with `PIPELINE_DISPATCH_ID` set | Production call site post-cutover | Comment body carries `<!-- meta: dedup key=<sig>/d<NNNN> -->` AND `<!-- meta: dispatch id=ENG-N-d<NNNN> stage=<stage> -->` | unit | `bin/linear-test.sh::A-001` |
| `add-comment --sig` with `PIPELINE_DISPATCH_ID` UNSET | Operator manual / test fixture | Sig collapses to legacy shape `<sig>` (no `/d<NNNN>` suffix); no dispatch marker | unit | `bin/linear-test.sh::A-002` |
| Two distinct dispatches re-emit same logical event | Reviewing dispatched twice on the same ENG-N | TWO distinct `commentCreate` calls (no `commentUpdate`) — AC #2 | integration | `bin/linear-test.sh::A-003` |
| Same dispatch retries with byte-identical body | `post_completion_comment` retry on Linear flake | TWO `commentCreate` calls (hash dedup skipped on `--sig` per D-007) | unit | `bin/linear-test.sh::A-004` |
| Operator reads halt history on a post-cutover issue | `bin/linear.sh get-comments ENG-N` + prefix-match recipe | The recipe returns the LATEST halt by createdAt (most recent dispatch's comment) | integration | `bin/linear-test.sh::A-005` |
| Operator reads halt history on a legacy (pre-cutover) issue | Same recipe against an issue with one legacy `<!-- meta: dedup key=… -->` comment | The recipe returns the single legacy comment | integration | `bin/linear-test.sh::A-005` (paired fixture) |
| `add-comment` called WITHOUT `--sig` | `bin/pipeline.sh::cmd_event_verdict` and other free-form posters | Behaviour unchanged from today: lane fence + dispatch marker inject + hash dedup all run; no dedup marker appended | unit | `bin/linear-test.sh::A-006` |
| Caller passes a sig containing newline / `-->` / NUL | Adversarial caller-side data corruption | `add-comment` dies with stderr `illegal characters` | unit | `bin/linear-test.sh::A-007` |
| `read_review_state` against append-only-shape comments | `bin/review-state.sh::read_review_state` after multiple `update_review_state` calls across dispatches | Returns the latest JSON payload by createdAt (existing logic was already append-only-correct per A-17) | unit | `bin/review-state-test.sh` (existing block, new assertion path) |
| `find_fresh_verdict` against append-only-shape halt comments | Reviewing dispatch reads a halt comment from a prior failed reviewing dispatch | ENG-87 strict-id-match selects ONLY the current dispatch's comment; prior halts are filtered out by dispatch_id mismatch | integration | `bin/verdict-handler-test.sh` (existing assertions; new sig shape) |
| Halt sprawl alert | Multiple `slot:"vacate"` issues accumulate | Per A-19 reads classifier output, not comment bodies — alert fires unchanged | smoke | `bin/halt-sprawl-test.sh` + `bin/halt-sprawl-adversarial-test.sh` |
| Header-line derivation under `add-comment --sig` | A halt verdict posted via the new path | Header reads `[ENG-N · implementing · d0007 · <iso> · agent]\nHALT — stage implementing halt` (P1 sig-derivation fires via Task-2's `$sig` threading) | integration | `bin/linear-test.sh::A-001` (extended assertion verifying header type) |
| Agent-lane caller passes `--sig` AND a hand-rolled bracket header | Anti-pattern from agent prompt drift | ENG-151 hand-rolled-header detector returns rc=14 BEFORE the sig path runs; AGENT_PROMPTS.md prose is the prompt-side defense | unit | `bin/linear-test.sh` ENG-151 block (existing hand-rolled-header reject test; unchanged) |
| AGENT_PROMPTS.md still contains `add-or-update-comment` literal | Plan-implementation miss | New test assertion in `agent-prompts-content-test.sh` greps the file and fails | unit | `bin/agent-prompts-content-test.sh` (new assertion in Task 11) |
| Forensic regression — any `bin/*.sh` still references the deleted symbol | Plan-implementation miss | `bin/linear-test.sh::A-008` greps the tree and fails | unit | `bin/linear-test.sh::A-008` |
| Operator reads an old `<!-- meta: reapplied at=… -->` or `<!-- meta: breadcrumb sig=… -->` marker on a legacy comment | Operator running the post-cutover runbook against a pre-cutover issue | The markers ARE legacy-readable per the unchanged registry `meta_kinds`; the runbook §3 documents this and points operators at the prefix-match recipe (which works for both shapes) | (docs-only, no test) | n/a — runbook prose per Task 13 |

## Test Strategy

- **Unit** — new `bin/linear-test.sh::A-001..A-007` covers the `--sig` chokepoint behaviour (marker append, dispatch-id suffix, sig-content validation, hash-dedup-skip, no-flag fallback). One smoke test per acceptance criterion plus one adversarial per security-relevant guard.
- **Integration** — `bin/linear-test.sh::A-003` exercises the two-distinct-dispatches contract end-to-end through stubbed `linear_query` (mirroring the ENG-87 L4-int pattern); `A-005` exercises the operator's prefix-match read recipe on a synthetic comment list.
- **Smoke** — `bin/linear-test.sh::A-008` runs `grep -rn 'add-or-update-comment\|add_or_update_comment' bin/ ...` and pins zero hits in production source. `bin/agent-prompts-content-test.sh`'s new assertion does the same for AGENT_PROMPTS.md.
- **Adversarial** — `bin/verdict-adversarial-test.sh` updates (Task 10) cover the protocol-violation-halt sig hygiene under append-only. `bin/linear-test.sh::A-004` (hash-dedup-skip under byte-identical body) is the security-relevant adversarial case (a future regression that re-enabled hash dedup on `--sig` would silently drop legitimate halts).

**Why the existing 16 sibling test files were updated, not augmented.**
The migration is mechanical token replacement at the test-stub layer: every
stub recognises a `linear.sh <subcmd>` argv shape via case-arm, and the
subcmd token shifts from `add-or-update-comment` to `add-comment` with
new flags. The fixtures' SEMANTIC coverage (halt sigs, completion sigs,
breadcrumb behaviour, etc.) is preserved by re-emitting the same shapes
under the new chokepoint. The ENG-63 + ENG-111 + ENG-151-upsert blocks in
`bin/linear-test.sh` are DELETED (not adapted) because they exercise
behaviour the post-cutover code physically lacks; deleting them is the
right shape, not test-coverage regression.

The DECISION to delete (rather than re-purpose) ENG-63 / ENG-111 tests:
both blocks exercise commentUpdate-side behaviour
(footer-rotation-on-identical-body, breadcrumb-on-body-change). Post-
cutover there is no commentUpdate path through `add_comment`, so the
behaviour the tests assert is unreachable. Keeping the tests as "skip
me, my SUT is gone" comments would be dead code; deleting is honest.
