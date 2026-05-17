---
linear: ENG-145
date: 2026-05-17
topic: Extend ENG-138 stage-gate to qa_rejection and implement_rejection in bin/guards.sh::check
---

# Plan — guards: extend the ENG-138 stage gate to `qa_rejection` and `implement_rejection` (ENG-145)

## Anti-anchoring check

- **Problem (operator-perspective):** "When QA loops back to implementing twice and then PASSes, the orchestrator halts the `qa → building` forward transition on the cumulative `qa_rejection` counter — penalising convergence and stranding the loop's agent output behind an operator-resume. The same shape is latent on `implement_rejection`." Brainstorm names this and proposes the surgical fix.
- **Brainstorm framing:** D-1 applies ENG-138's stage-gate pattern symmetrically to the other two rejection counters; only the check-side firing edge narrows, ENG-116's reset-side contract is preserved verbatim. The reframing matches the problem one-for-one.
- **Proportionality:** two trip-line edits in `bin/guards.sh:138-143` (~6 characters each), one header-comment paragraph rewrite, one usage-comment update; in `bin/guards-test.sh` invert one existing case and add three new ones; in `bin/guards-adversarial-test.sh` invert two existing cases that explicitly pin the old `qa_rejection` behaviour. Total production-code diff is ~2 lines + a doc paragraph. No new state, no new marker, no schema change. Proportional. Proceed.

## Goal

`bin/guards.sh::check` trips the `qa_rejection` and `implement_rejection` thresholds ONLY when `stage == implementing` (the loopback-continuation edge shared by all three rejection counters) or when no stage is passed (preserves the direct-CLI back-compat path used by `bin/run-stage-test.sh::case-15` and operator triage). Reset semantics from ENG-116 (`count_marker_since_last_operator_resume`; operator-resume waypoint clears the counter) are unchanged.

## Assumption Inventory

Format: `[verified|assumed]` ITEM — `path:line` reference.

**branch-base freshness:** `HEAD..origin/main` empty at plan time (`origin/main = c23d0ff`). No Task 0 rebase needed; content anchors are still load-bearing per "Edit-boundary keys" in case a sibling commit lands during implement.

### Verified — code paths quoted from current tree

- `[verified]` `bin/guards.sh:98-151` — `check()` body. Current signature already accepts the optional stage arg (`local stage="${2:-}"` at line 100) — ENG-138 introduced it. No signature change needed.

- `[verified]` `bin/guards.sh:129-131` — existing stage-gated `review_rejection` trip (the pattern to mirror):
  ```bash
  if (( rev >= review_threshold )) && [[ -z "$stage" || "$stage" == "implementing" ]]; then
    tripped+="review_rejection($rev>=$review_threshold) "
  fi
  ```
  Content anchor: the literal token `review_rejection($rev>=$review_threshold)` is unique in the file.

- `[verified]` `bin/guards.sh:138-143` — current unguarded trips for `qa_rejection` and `implement_rejection`:
  ```bash
  if (( qa >= qa_threshold )); then
    tripped+="qa_rejection($qa>=$qa_threshold) "
  fi
  if (( impl >= impl_threshold )); then
    tripped+="implement_rejection($impl>=$impl_threshold) "
  fi
  ```
  Content anchors: the literal tokens `qa_rejection($qa>=$qa_threshold)` and `implement_rejection($impl>=$impl_threshold)` are each unique in the file (Grep verified, 2026-05-17).

- `[verified]` `bin/guards.sh:119-120` — count read sites: `qa="$(count_marker_since_last_operator_resume "$ident" qa_rejection)"` and `impl="$(count_marker_since_last_operator_resume "$ident" implement_rejection)"`. Unchanged by this plan — the helper signature is untouched, reset semantics intact.

- `[verified]` `bin/guards.sh:21-27` — header-comment block currently names only `review_rejection`:
  > "ENG-138 narrows the firing-side: the review_rejection threshold trips only when the dispatched stage is 'implementing' …"
  Content anchor: the line `# ENG-138 narrows the firing-side: the review_rejection threshold trips` is unique in the file. The paragraph ends at the line `# semantics (operator-resume waypoint clears) are unchanged.` (line 27); the next line is `# gotcha_triggered and learned_rule_renewal count` (line 28) — also unique.

- `[verified]` `bin/guards.sh:38-47` — usage comment block. Current line 42-45 reads:
  ```
  #     When [stage] is omitted, the review_rejection trip fires as today
  #     (operator-triage / case-15 back-compat). When [stage] is provided
  #     (e.g. by bin/run-stage.sh), the review_rejection trip is scoped to
  #     stage == implementing — see header comment above for the ENG-138
  ```
  Content anchor: the literal `(operator-triage / case-15 back-compat)` is unique in the file.

- `[verified]` `bin/guards.sh:77-96` — `count_marker_since_last_operator_resume()`. Not modified by this plan; reset semantics intact.

- `[verified]` `bin/run-stage.sh:1261, 1263` — both `guards.sh check` invocations already pass `"$stage"` as second positional (ENG-138):
  ```bash
  if ! bash "$SCRIPT_DIR/guards.sh" check "$ident" "$stage" 2>/dev/null; then
    local tripped
    tripped="$(bash "$SCRIPT_DIR/guards.sh" check "$ident" "$stage" 2>&1 || true)"
  ```
  Content anchor: the comment `# Guards (threshold-based human gates). ENG-138: pass the dispatched` at line 1258 is unique in the file. **No `bin/run-stage.sh` edit needed.**

- `[verified]` `bin/run-stage.sh:1684, 1690, 1732` — three `bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection || true` call sites. All fire inside `stage == implementing` dispatches and immediately `classify_failure` with `skip-until-human-acts`. Read, not modified by this plan; cited so the implementer knows where `implement_rejection` enters the counter stream.

- `[verified]` `bin/run-stage.sh:1891-1896` — `stage_label_long` normalisation runs AFTER the guards check, so `$stage` at line 1261 is already in long-form gerund (`implementing`, not `implement`). Confirms the `"$stage" == "implementing"` clause matches what run-stage passes.

- `[verified]` `bin/verdict-handler.sh:19-27` — forward transition table; `bin/verdict-handler.sh:32-38` — loopback transition table:
  ```
  reviewing|implementing|
  qa|implementing|
  building|implementing|
  ```
  Confirms all three rejection loops target `implementing`. Not modified by this plan.

- `[verified]` `AGENT_PROMPTS.md:1462` — QA agent path-B bumps `qa_rejection`: ``Bump counter: `.pipeline/bin/guards.sh bump {issue_id} qa_rejection`.`` Not modified.

- `[verified]` `bin/guards-test.sh` exists at HEAD (introduced by ENG-138). 9 cases (case-1 through case-9). Case-9 (lines 269-302) explicitly asserts `qa_rejection` trips at `stage=qa` — the assertion this plan inverts. Content anchor: the literal comment `# ── case-9 (QA-adversarial): qa stage with qa_rejection >=threshold still trips` is unique in the file.

- `[verified]` `bin/guards-adversarial-test.sh` exists at HEAD (introduced by ENG-138 QA stage). 6 adversarial cases (A1 through A6). Two assertions are inverted by ENG-145:
  - `case-A4` (lines 183-199): asserts `qa_rejection` STILL trips at `stage=qa` with a comment "ENG-138 fix must not over-suppress". Content anchor: the literal comment `# ── case-A4: qa_rejection at threshold, stage=qa → DOES trip` is unique.
  - `case-A5` (lines 201-218): asserts `qa_rejection` STILL trips at `stage=qa` even when `review_rejection` is suppressed (counter-specific scoping). Content anchor: the literal comment `# ── case-A5: review_rejection + qa_rejection both at threshold, stage=qa` is unique.

- `[verified]` `bin/guards-test.sh::case-1, case-3, case-4, case-7, case-8` — pass `stage=implementing` or no stage and exercise `review_rejection`. Unaffected by ENG-145 (review_rejection gate already in place).

- `[verified]` `bin/guards-test.sh::case-2, case-5, case-6` — assert `review_rejection` does NOT trip at non-implementing stages (qa/reviewing/building). Unaffected; the symmetric assertions for `qa_rejection`/`implement_rejection` are added as new cases.

- `[verified]` `bin/run-stage-test.sh::case-15` (lines 1523-1635) — calls `guards.sh check ENG-T15` with NO stage arg using `implement_rejection` markers. The empty-stage branch of D-1's clause preserves the trip-as-today path. Case-15 stays green without modification (AC#5).

- `[verified]` `bin/run-stage-test.sh:73-83` — `guards.sh` stub used by case-1 through case-14 swallows all args and `exit 0`. Adding a second positional via `"$stage"` upstream doesn't affect the stub. Stays green.

- `[verified]` `bin/run-stage-test.sh::case-11, case-12` (lines 393-457) — test that SEVERE / unknown-rc scope-violations bump `implement_rejection`. These exercise the `bump` path, not `check`. Unaffected by ENG-145.

- `[verified]` `bin/verdict-adversarial-test.sh:158-194` (A10/A10B/A11) — sources `bin/guards.sh` and tests `count_marker_since_last_operator_resume` directly. The helper signature is unchanged; tests use `qa_rejection` markers but call the helper, not `check`. Stays green.

- `[verified]` `bin/verdict-handler-test.sh:508-517` — uses `qa_rejection` markers but tests the helper signature, not `check`. Stays green.

- `[verified]` `bin/profile-allowlist-test.sh:326, 342` — only comment references to `qa_rejection`/`implement_rejection`; no behaviour assertion. Stays green.

- `[verified]` `.githooks/pre-commit` runs every `bin/*-test.sh`. The edited `bin/guards-test.sh` and `bin/guards-adversarial-test.sh` are picked up automatically; no hook change needed.

### Verified — file/dir existence

- `[verified]` `bin/guards.sh` — exists at HEAD; modified by Tasks 1, 2.
- `[verified]` `bin/guards-test.sh` — exists at HEAD; modified by Tasks 3.
- `[verified]` `bin/guards-adversarial-test.sh` — exists at HEAD; modified by Task 4.
- `[verified]` `bin/run-stage.sh` — exists at HEAD; **NOT modified** (ENG-138 already passes `$stage`).

### Verified — runtime / dependency

- `[verified]` `jq` already used by `bin/guards.sh::check`; no new tooling. Pre-commit hook is the gate venue.

### Assumed — to be verified during implement

- `[assumed]` `bin/pipeline.sh decide --action continue` posts the `<!-- pipeline: transition ... reason=operator-resume -->` waypoint that resets all three counters. Per `CLAUDE.md::"What --action continue clears (atomic)"` step 7 and `bin/guards.sh:11-13`. ENG-116 / ENG-138 plans already relied on this; reset semantics unchanged here.

- `[assumed]` Default threshold of 2 (`bin/guards.sh:112-113` when config absent) is acceptable for both `qa_rejection` and `implement_rejection` on the trip-at-implementing edge. ENG-138 carries the same default for `review_rejection` without observed pain; brainstorm OQ-1 defers the tunability question.

## File Structure

### Modified

- `bin/guards.sh` — wrap the `qa_rejection` trip (lines 138-140) and `implement_rejection` trip (lines 141-143) with `[[ -z "$stage" || "$stage" == "implementing" ]]`; rewrite the header-comment block (lines 21-27) to name all three counters; extend the usage block (lines 42-45) to name all three.
- `bin/guards-test.sh` — invert `case-9` (lines 269-302): change expected `rc=10` → `rc=0`, change positive assertion from `grep -q 'qa_rejection(2>=2)'` to `grep -q 'guards: clear'`, rewrite the comment block to reflect ENG-145's qa_rejection narrowing. Append `case-10` (qa_rejection trips at implementing), `case-11` (qa_rejection does NOT trip at building), `case-12` (implement_rejection trips at implementing), and `case-13` (operator-resume resets both qa_rejection and implement_rejection counters).
- `bin/guards-adversarial-test.sh` — invert `case-A4` (lines 183-199): expected rc 10 → 0, positive assertion flips to `guards: clear`, rewrite the comment block to reflect that ENG-145 extends the suppression to qa_rejection. Invert `case-A5` (lines 201-218): expected rc 10 → 0, change assertion to assert NEITHER `qa_rejection` NOR `review_rejection` appears in output (both suppressed at non-implementing stages). Update test-file header (lines 1-10) to note ENG-145 inversions.

### New

No new files. Both test files exist; both code files exist; no schema or marker change.

### Not modified (called out for transparency)

- `bin/run-stage.sh` — call sites at lines 1261, 1263 already pass `"$stage"` (ENG-138). No edit.
- `CLAUDE.md` — no row added to "Failure-mode quick reference"; ENG-138 row covers the only observed-in-wild instance. The qa/impl shape is preventive and warrants a row only after observation (brainstorm D-4 rejected adding one).

## API Contract

No new FE↔BE API surface. Harness is Bash-only orchestration (project profile Stack). The CLI surface this plan touches is `bash bin/guards.sh check <issue_id> [stage]` — exit code semantics unchanged (0 clear / 10 tripped), argument shape unchanged, behaviour narrowed on `qa_rejection` and `implement_rejection` per the Goal section.

## Backend Tasks

### Task 1: Add stage-gate clause to `qa_rejection` and `implement_rejection` trips in `bin/guards.sh`

- `depends_on: []`
- `touches: bin/guards.sh::check`
- [ ] Locate the `qa_rejection` trip block. Content anchor: the unique three-line block whose middle line is `tripped+="qa_rejection($qa>=$qa_threshold) "` (~line 139). The current shape (lines 138-140):
  ```bash
  if (( qa >= qa_threshold )); then
    tripped+="qa_rejection($qa>=$qa_threshold) "
  fi
  ```
- [ ] Replace with the stage-gated form, mirroring `bin/guards.sh:129-131` exactly:
  ```bash
  if (( qa >= qa_threshold )) && [[ -z "$stage" || "$stage" == "implementing" ]]; then
    tripped+="qa_rejection($qa>=$qa_threshold) "
  fi
  ```
- [ ] Locate the `implement_rejection` trip block IMMEDIATELY following the qa block. Content anchor: the unique three-line block whose middle line is `tripped+="implement_rejection($impl>=$impl_threshold) "` (~line 142). Current shape (lines 141-143):
  ```bash
  if (( impl >= impl_threshold )); then
    tripped+="implement_rejection($impl>=$impl_threshold) "
  fi
  ```
- [ ] Replace with the stage-gated form:
  ```bash
  if (( impl >= impl_threshold )) && [[ -z "$stage" || "$stage" == "implementing" ]]; then
    tripped+="implement_rejection($impl>=$impl_threshold) "
  fi
  ```
- [ ] DO NOT change the `review_rejection` trip (line 129-131) — already gated by ENG-138.
- [ ] DO NOT change the `gotcha_triggered` / `learned_rule_renewal` trips (lines 132-136) — lifetime counters by design, OUT of scope per the Linear ticket.
- [ ] DO NOT change the `guards: clear on $ident (rev=$rev got=$got rule=$rule qa=$qa impl=$impl)` log line (line 150) — `qa` and `impl` are still computed so operators can read the cumulative count from the per-stage transcript.

### Task 2: Rewrite the `bin/guards.sh` header and usage comments to name all three counters

- `depends_on: [1]`
- `touches: bin/guards.sh (comments)`
- [ ] Locate the ENG-138 paragraph in the header-comment block. Content anchor: the line `# ENG-138 narrows the firing-side: the review_rejection threshold trips` (~line 21). The paragraph ends at `# semantics (operator-resume waypoint clears) are unchanged.` (~line 27); the next line `# gotcha_triggered and learned_rule_renewal count` (~line 28) is the unique boundary.
- [ ] Replace the seven-line paragraph (lines 21-27 inclusive) with:
  ```bash
  # ENG-138/ENG-145 narrow the firing-side for all three rejection
  # counters: each threshold (review_rejection, qa_rejection,
  # implement_rejection) trips only when the dispatched stage is
  # 'implementing' — the loopback continuation edge shared by all
  # three loops (verdict-handler.sh:35-37). Reaching a downstream
  # stage after a clean upstream PASS no longer halts even when the
  # cumulative count is at or over the threshold. The counter still
  # accumulates across loopback cycles for operator audit (visible
  # in the `guards: clear` log line), and reset semantics
  # (operator-resume waypoint clears) are unchanged.
  ```
- [ ] Locate the usage-comment lines about the stage arg. Content anchor: the literal line `#     (operator-triage / case-15 back-compat). When [stage] is provided` (~line 43). The block to update spans from `#     When [stage] is omitted, the review_rejection trip fires as today` (~line 42) through `#     stage == implementing — see header comment above for the ENG-138` (~line 44) and the closing `#     contract.` (~line 45).
- [ ] Replace those four lines with:
  ```bash
  #     When [stage] is omitted, the review_rejection, qa_rejection,
  #     and implement_rejection trips fire as today (operator-triage /
  #     case-15 back-compat). When [stage] is provided (e.g. by
  #     bin/run-stage.sh), all three trips are scoped to stage ==
  #     implementing — see header comment above for the ENG-138/ENG-145
  #     contract.
  ```
- [ ] DO NOT change the lines about `gotcha_triggered` / `learned_rule_renewal` (lines 28-32) or the legacy-shape tolerance paragraph (lines 34-36).

### Task 3: Invert `bin/guards-test.sh::case-9` and append four new cases

- `depends_on: [1]`
- `touches: bin/guards-test.sh`
- [ ] Locate `case-9`. Content anchor: the literal block comment `# ── case-9 (QA-adversarial): qa stage with qa_rejection >=threshold still trips` (~line 269). The case spans through the closing `fi` of its `if … pass_at … else … fail_at … fi` block (~line 302), immediately before `# ── Summary ──`.
- [ ] Rewrite the `case-9` block. Replace the existing six lines of preamble comment (lines 269-271) with:
  ```bash
  # ── case-9 (ENG-145 inversion): qa stage with qa_rejection >=threshold does NOT trip ──
  # Pre-ENG-145 this asserted that qa_rejection trips at stage=qa (ENG-138 narrowing
  # was review_rejection-only). ENG-145 extends the narrowing to qa_rejection (and
  # implement_rejection). The trip now fires only at stage=implementing — see
  # bin/guards.sh:138-140 and the symmetric implementer-rejection block at 141-143.
  ```
- [ ] Keep the stub setup (lines 272-290) unchanged — the two `qa_rejection` markers + no operator-resume fixture is reusable for the inverted assertion.
- [ ] Change the invocation arg from `qa` to keep it `qa` — the assertion changes, not the input. The current line (~line 293) is `c9_out="$(bash "$GUARDS" check ENG-T138I qa 2>&1)"`. Keep `qa`.
- [ ] Replace the if-block (lines 297-302) with:
  ```bash
  if [[ "$c9_rc" == "0" ]] && grep -q 'guards: clear' <<<"$c9_out"; then
    pass_at "case-9: qa_rejection does NOT trip at stage=qa (ENG-145 extends the ENG-138 narrowing to qa_rejection)"
  else
    fail_at "case-9: qa_rejection at stage=qa should NOT trip post-ENG-145" \
      "rc=$c9_rc out=$c9_out"
  fi
  ```
- [ ] AFTER the inverted case-9 closing `fi` (~line 302) and BEFORE the `# ── Summary ──` header (~line 304), insert four new cases. Each case must use the same fake-repo overlay shape used by case-1 through case-9 (per-case stub `linear.sh` symlinked into `$FAKE_REPO/.pipeline/bin/`). Mirror case-1's shape verbatim, substituting marker name + invocation stage + assertion as below.

  **case-10 — `qa_rejection` trips at stage=implementing (AC#1).**
  ```bash
  # ── case-10: AC#1 — qa_rejection trips at stage=implementing ─────────────────
  # Two qa_rejection markers, no operator-resume, stage=implementing.
  # Expected: rc=10, output contains qa_rejection(2>=2).
  cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
  #!/usr/bin/env bash
  case "${1:-}" in
    get-comments)
      cat <<'JSON'
  [
    {"body":"<!-- meta: metric name=qa_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:00:00.000Z"},
    {"body":"<!-- meta: metric name=qa_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:30:00.000Z"}
  ]
  JSON
      ;;
    query)
      printf '%s\n' '{"data":{"issue":{"comments":{"nodes":[]}}}}'
      ;;
    has-label) exit 1 ;;
    *) exit 0 ;;
  esac
  SH
  chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

  set +e
  c10_out="$(bash "$GUARDS" check ENG-T145A implementing 2>&1)"
  c10_rc=$?
  set -e

  if [[ "$c10_rc" == "10" ]] && grep -q 'qa_rejection(2>=2)' <<<"$c10_out"; then
    pass_at "case-10: qa_rejection trips at stage=implementing (AC#1)"
  else
    fail_at "case-10: stage=implementing should trip on qa_rejection count=2" \
      "rc=$c10_rc out=$c10_out"
  fi
  ```

  **case-11 — `qa_rejection` does NOT trip at stage=building (forward edge after qa PASS) (AC#2).** Reuse the same stub-payload shape as case-10 (two qa_rejection markers, no operator-resume). Invoke `bash "$GUARDS" check ENG-T145B building`. Assert `rc=0` AND `grep -q 'guards: clear' <<<"$c11_out"`.

  **case-12 — `implement_rejection` trips at stage=implementing (AC#3).** Stub payload: two `<!-- meta: metric name=implement_rejection -->` markers, no operator-resume. Invoke `bash "$GUARDS" check ENG-T145C implementing`. Assert `rc=10` AND `grep -q 'implement_rejection(2>=2)' <<<"$c12_out"`.

  **case-13 — operator-resume waypoint resets both counters (AC#4).** Stub payload: two `qa_rejection` markers + two `implement_rejection` markers + a newer `<!-- pipeline: transition from=implementing to=implementing reason=operator-resume -->`. Invoke `bash "$GUARDS" check ENG-T145D implementing`. Assert `rc=0` (both counters reset by operator-resume).
- [ ] All four new cases use distinct issue identifiers (`ENG-T145A` / `ENG-T145B` / `ENG-T145C` / `ENG-T145D`) for log clarity. The `linear.sh` stub does not look up by id (returns the same payload for any `get-comments` call), so the identifiers are cosmetic.
- [ ] DO NOT modify `case-1` through `case-8` — they exercise `review_rejection`, which is unchanged.
- [ ] DO NOT modify the `# ── Summary ──` block at the bottom (lines 304-306) or the `PASS`/`FAIL` accumulation.

### Task 4: Invert `bin/guards-adversarial-test.sh::case-A4` and `case-A5`

- `depends_on: [1]`
- `touches: bin/guards-adversarial-test.sh`
- [ ] Locate `case-A4`. Content anchor: the literal comment block starting `# ── case-A4: qa_rejection at threshold, stage=qa → DOES trip` (~line 183). The case spans through the closing `fi` of its assertion block (~line 199), immediately before `# ── case-A5`.
- [ ] Rewrite the `case-A4` preamble comment (lines 183-186) to:
  ```bash
  # ── case-A4 (ENG-145 inversion): qa_rejection at threshold, stage=qa → does NOT trip ──
  # Pre-ENG-145 this asserted that qa_rejection trips at stage=qa (ENG-138 fix was
  # review_rejection-only). ENG-145 extends the stage gate to qa_rejection: trip
  # now fires only at stage=implementing — see bin/guards.sh:138-140.
  ```
- [ ] Keep the stub setup (`write_stub_two_qa_rejections` at line 187) and invocation (line 190: `cA4_out="$(bash "$GUARDS" check ENG-TA4 qa 2>&1)"`) unchanged — the input shape is reusable; only the assertion flips.
- [ ] Replace the if-block (lines 194-199) with:
  ```bash
  if [[ "$cA4_rc" == "0" ]] && grep -q 'guards: clear' <<<"$cA4_out"; then
    pass_at "case-A4: qa_rejection does NOT trip at stage=qa (ENG-145 extends the ENG-138 narrowing)"
  else
    fail_at "case-A4: qa_rejection at stage=qa should NOT trip post-ENG-145" \
      "rc=$cA4_rc out=$cA4_out"
  fi
  ```
- [ ] Locate `case-A5`. Content anchor: the literal comment block starting `# ── case-A5: review_rejection + qa_rejection both at threshold, stage=qa` (~line 201). The case spans through the closing `fi` of its assertion block (~line 218), immediately before `# ── case-A6`.
- [ ] Rewrite the `case-A5` preamble comment (lines 201-203) to:
  ```bash
  # ── case-A5 (ENG-145 inversion): both counters at threshold, stage=qa → NEITHER trips ──
  # Pre-ENG-145 this asserted that at stage=qa, qa_rejection trips while
  # review_rejection is suppressed. ENG-145 extends the suppression: at any non-
  # implementing stage, NEITHER counter trips. The scoping is still counter-
  # specific (gotcha/rule counters are unaffected), but qa_rejection now joins
  # review_rejection in the implementing-only firing edge.
  ```
- [ ] Keep the stub setup (`write_stub_two_review_and_two_qa_rejections` at line 204) and invocation (line 207: `cA5_out="$(bash "$GUARDS" check ENG-TA5 qa 2>&1)"`) unchanged.
- [ ] Replace the if-block (lines 211-218) with:
  ```bash
  if [[ "$cA5_rc" == "0" ]] \
      && grep -q 'guards: clear' <<<"$cA5_out" \
      && ! grep -q 'qa_rejection(2>=2)' <<<"$cA5_out" \
      && ! grep -q 'review_rejection(2>=2)' <<<"$cA5_out"; then
    pass_at "case-A5: at stage=qa, NEITHER qa_rejection NOR review_rejection trips (ENG-145 symmetric suppression)"
  else
    fail_at "case-A5: stage=qa should suppress BOTH qa_rejection and review_rejection post-ENG-145" \
      "rc=$cA5_rc out=$cA5_out"
  fi
  ```
- [ ] Update the file-header comment at lines 6-9. Content anchor: the line `#   A4: qa_rejection at threshold with stage=qa → DOES trip (other counters unaffected)` is unique. Replace lines 7-8 with:
  ```bash
  #   A4: qa_rejection at threshold with stage=qa → does NOT trip (ENG-145 inversion)
  #   A5: review_rejection + qa_rejection both at threshold, stage=qa → NEITHER trips (ENG-145 inversion)
  ```
- [ ] DO NOT modify `case-A1`, `case-A2`, `case-A3`, `case-A6` — they exercise `review_rejection` or the empty-stage branch, both unchanged by ENG-145.

### Task 5: Run gate suite and confirm green

- `depends_on: [1, 2, 3, 4]`
- `touches: (no source edits — gate execution only)`
- [ ] Run the new file directly: `bash bin/guards-test.sh`. Expect cases 1-13 PASS, exit 0.
- [ ] Run the adversarial file directly: `bash bin/guards-adversarial-test.sh`. Expect A1-A6 PASS, exit 0.
- [ ] Run the case-15 regression: `bash bin/run-stage-test.sh`. Case-15's three subcases must remain green (empty-stage back-compat preserved by the `[[ -z "$stage" || ... ]]` clause on `implement_rejection`).
- [ ] Run the helper-source assertions: `bash bin/verdict-adversarial-test.sh`. A10/A10B/A11 must remain green (they source `bin/guards.sh` and call the helper directly; `check()` is untouched in signature).
- [ ] Run the allowlist test: `bash bin/profile-allowlist-test.sh`. Reviewing/qa allowlist assertions for `Bash(bash bin/guards.sh:*)` must remain green.
- [ ] Run the full pre-commit hook: `bash .githooks/pre-commit`. Expect zero failures (KNOWN_BROKEN allowlist unchanged by this plan).

## Frontend Tasks

**None.** Harness-self bash plan with no FE surface (per project profile Stack). Recorded explicitly to satisfy the template contract.

## Failure Mode → Test Map

Each row binds an edge case from the brainstorm §7 to a concrete test.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Cumulative `qa_rejection` halts forward `qa → building` after clean PASS (the regression) | Invoke `guards.sh check ENG-T145B building` with two prior `qa_rejection` markers, no operator-resume | rc=0; `guards: clear`; `qa_rejection` absent from output | unit | `bin/guards-test.sh::case-11` |
| Cumulative `qa_rejection` still halts at next `implementing` dispatch (ENG-116 intent) | Invoke `guards.sh check ENG-T145A implementing` with two prior `qa_rejection` markers, no operator-resume | rc=10; output matches `qa_rejection(2>=2)` | unit | `bin/guards-test.sh::case-10` |
| Cumulative `implement_rejection` still halts at next `implementing` dispatch | Invoke `guards.sh check ENG-T145C implementing` with two prior `implement_rejection` markers, no operator-resume | rc=10; output matches `implement_rejection(2>=2)` | unit | `bin/guards-test.sh::case-12` |
| Operator-resume waypoint clears both `qa_rejection` and `implement_rejection` (ENG-116 contract preserved) | Invoke `guards.sh check ENG-T145D implementing` with two of each marker + a newer `reason=operator-resume` transition | rc=0 | unit | `bin/guards-test.sh::case-13` |
| Direct-CLI invocation with no stage arg still trips `qa_rejection`/`implement_rejection` (back-compat for case-15 and operator triage) | Run `bin/run-stage-test.sh::case-15` (NO stage arg, two `implement_rejection` markers) | rc=10; output matches `implement_rejection(2>=2)` | integration | `bin/run-stage-test.sh::case-15` |
| Stage=qa with `qa_rejection` >= threshold does NOT trip (the inversion) | Invoke `guards.sh check ENG-T138I qa` with two `qa_rejection` markers | rc=0; `guards: clear`; `qa_rejection` absent | unit | `bin/guards-test.sh::case-9` (inverted) |
| Stage=qa with `qa_rejection` >= threshold AND `review_rejection` >= threshold — NEITHER trips | Invoke `guards.sh check ENG-TA5 qa` with two of each marker | rc=0; `guards: clear`; both `qa_rejection` and `review_rejection` absent | unit | `bin/guards-adversarial-test.sh::case-A5` (inverted) |
| Stage=qa with `qa_rejection` >= threshold (isolated) does NOT trip | Invoke `guards.sh check ENG-TA4 qa` with two `qa_rejection` markers | rc=0; `guards: clear` | unit | `bin/guards-adversarial-test.sh::case-A4` (inverted) |
| `count_marker_since_last_operator_resume` helper signature stays compatible | Run `bin/verdict-adversarial-test.sh::A10/A10B/A11` | A10 returns 3, A10B returns 1, A11 returns 2 | integration | `bin/verdict-adversarial-test.sh::A10`, `::A10B`, `::A11` |
| Unknown stage value (defensive) does NOT trip `qa_rejection`/`implement_rejection` | Covered by case-11's shape (any non-`implementing` non-empty stage takes the same gate branch) | rc=0 | unit | `bin/guards-test.sh::case-11` (representative); no separate case needed |
| Stage-drift race: `run-stage.sh` dispatches `building` but Linear flips to `reviewing` mid-tick | Pre-dispatch guards sees `stage=building` (dispatched value); no `qa_rejection` trip; subsequent stage-drift exit fires at `bin/run-stage.sh:1899` | rc=0 from guards; clean stage-drift exit | (no new test) | covered by existing `bin/run-stage-test.sh` drift case + this plan's case-11 |
| `building → implementing` rebase loopback after high cumulative `qa_rejection` (acknowledged trade-off, mirror of ENG-138 OQ-3) | At next implementing dispatch, `qa_rejection` evaluated; if still >= threshold AND no operator-resume, halt fires | rc=10 (intentional — operator must `--action continue` to grant fresh budget) | (no new test) | semantic preserved by Tasks 1+3; documented in brainstorm §7 |

## Test Strategy

**Unit (`bin/guards-test.sh`).** Inverted case-9 + four new cases (case-10 through case-13) per Task 3. Each uses the established fake-repo overlay shape (symlink real `guards.sh` + `common.sh` into `$FAKE_REPO/.pipeline/bin/`; per-case stub `linear.sh` returns a parameterised `get-comments` payload). All cases live in the same `bin/guards-test.sh` file ENG-138 established — no new file. The four new cases mirror ENG-138's case-1/case-2/case-3 structure for each of qa_rejection and implement_rejection.

**Unit (`bin/guards-adversarial-test.sh`).** Inverted case-A4 (qa_rejection at stage=qa no longer trips) and case-A5 (at stage=qa, NEITHER qa_rejection NOR review_rejection trips — symmetric suppression). Case-A1, A2, A3, A6 unchanged.

**Integration backstop.** Three existing test surfaces verify the no-regression promise:
- `bin/run-stage-test.sh::case-15` — verifies empty-stage back-compat via NO stage arg with `implement_rejection` markers. Stays green because the new `[[ -z "$stage" || ... ]]` clause matches the empty-stage branch.
- `bin/verdict-adversarial-test.sh::A10/A10B/A11` — sources `bin/guards.sh` and tests `count_marker_since_last_operator_resume` directly. The helper signature is unchanged; tests pass `qa_rejection` markers to the helper, not `check`.
- `bin/profile-allowlist-test.sh` — asserts `Bash(bash bin/guards.sh:*)` is present in reviewing/qa allowlists. Unaffected by argument-shape preservation.

**Smoke (`.githooks/pre-commit`).** Runs the full `bin/*-test.sh` suite. The edited `bin/guards-test.sh` and `bin/guards-adversarial-test.sh` are picked up automatically. AC#7 from the brainstorm §2 is verified at commit time.

**Adversarial coverage.** Two adversarial shapes worth calling out:
- *Empty-stage CLI invocation* — case-15 in `bin/run-stage-test.sh` (NOT modified) plus case-A6 in `bin/guards-adversarial-test.sh` (NOT modified) explicitly assert the `[[ -z "$stage" || ... ]]` empty-stage branch trips as today. Both stay green; the inversions in Tasks 3-4 do not affect these.
- *Mixed-counter at non-implementing stage* — inverted case-A5 explicitly asserts BOTH counters are suppressed at `stage=qa`. Guards against a future refactor that re-introduces partial suppression (e.g., gating one counter but not the other).

**Test-gate closure check.** This plan inverts assertions, not removes tokens — the strings `qa_rejection(2>=2)` and `implement_rejection(2>=2)` continue to appear in production code (the trip text) and in tests (now in the `! grep -q` negative assertions or inside positive assertions at `stage=implementing`). The literal tokens `qa_rejection` and `implement_rejection` continue to appear in `bin/guards.sh:138-143`, the bump sites in `bin/run-stage.sh`, and the comment marker bodies. No sibling test file references the OLD trip-at-stage=qa semantic outside the two files this plan modifies (verified via Grep `qa_rejection|implement_rejection` across `bin/` — see Assumption Inventory). Both edited files are listed in File Structure with explicit task entries inverting the affected assertions.

## Out of scope (reproduced from issue)

- `review_rejection` gate — already shipped by ENG-138, unchanged.
- `gotcha_triggered` and `learned_rule_renewal` — lifetime counters by design (`bin/guards.sh:117-118, 132-136`), explicitly OUT.
- Counter accumulation / reset semantics — ENG-116 contract preserved verbatim.
- Threshold-value change (default 2) — brainstorm OQ-1, OUT.
- Per-counter split (Option c) — brainstorm D-1 rejected.

## Persona review (audit trail)

Five-persona document-review run inline during this dispatch. Headline goes in the Linear stage-summary; full record below.

### Iteration 1

| Persona     | Verdict | Load-bearing findings |
|---|---|---|
| feasibility | PASS · 0 P0 | Every `path:line` cited has been opened during this dispatch (Assumption Inventory). Edit boundaries use content anchors (`tripped+="qa_rejection($qa>=$qa_threshold) "` token; `# ── case-9 (QA-adversarial)` comment; `# ── case-A4: qa_rejection at threshold, stage=qa → DOES trip` comment) — no bare-line-only boundaries. Branch-base freshness pinned (`HEAD..origin/main` empty at plan time, `origin/main = c23d0ff`). **Test-gate closure sweep ran**: `Grep qa_rejection\|implement_rejection` across `bin/` returned 8 files; verified each — `bin/guards.sh` (production), `bin/guards-test.sh` (covered by Task 3 inversion), `bin/guards-adversarial-test.sh` (covered by Task 4 inversion — initially missed by the brainstorm, surfaced by this sweep), `bin/run-stage.sh` (production bump sites, no `check` assertions), `bin/run-stage-test.sh` (case-11/12/15/16 exercise `bump`, not `check`; case-15 NO-stage path preserved by empty-stage branch), `bin/verdict-handler-test.sh` (tests helper signature, not `check`), `bin/verdict-adversarial-test.sh` (tests helper signature, not `check`), `bin/profile-allowlist-test.sh` (comment refs only). No sibling-test halt risk. Task `depends_on` graph is acyclic (1 → 2/3/4; all → 5). |
| scope       | PASS · 0 P0 | All edits in `bin/guards.sh` (lines 138-143 gate + header/usage comments per D-4) + `bin/guards-test.sh` new cases + `bin/guards-adversarial-test.sh` inversions trace to Linear issue §Scope IN: list. **Note** (mirrors ENG-138 plan's scope note): the `bin/guards-test.sh::case-9` inversion and `bin/guards-adversarial-test.sh::case-A4/case-A5` inversions are edits to existing cases, not strictly "new regression cases". The brainstorm §10 calls this out as "test-fixture inversion is load-bearing". Not a scope violation; called out for transparency. `OUT:` clause (counter semantics, review_rejection gate, gotcha/rule counters) honoured — none of those files/blocks are touched. No gold-plating. |
| coherence   | PASS · 0 P0 | Goal sentence matches brainstorm §2 verbatim (qa_rejection + implement_rejection, implementing-only firing edge). AC#1-AC#7 (brainstorm §2) are 1:1 traceable to Failure Mode → Test Map rows: AC#1 → case-10; AC#2 → case-11; AC#3 → case-12; AC#4 → case-13; AC#5 → case-15 (empty-stage CLI); AC#6 → case-10/11/12/13 + inverted case-9 + inverted case-A4/A5; AC#7 → pre-commit hook smoke. Backend Tasks 1+2 jointly realise D-1, D-2, D-4 of the brainstorm; Task 3 realises D-3; Task 4 covers the test-gate closure gap the brainstorm missed (guards-adversarial-test.sh). |
| design      | PASS · 0 P0 | The `[[ -z "$stage" || "$stage" == "implementing" ]]` clause is the established harness shape (already present on `review_rejection` at line 129). No new module boundary, no new dependency, no new state. Single-file production change with no caller adjustment (ENG-138 already threaded `$stage`). The change is reversible via a single revert. Plan respects the project profile's File layout (only `bin/` is touched). |
| product     | PASS · 0 P0 | AC#1-AC#7 (brainstorm §2) are observable from `bin/guards-test.sh` and `bin/guards-adversarial-test.sh` output and from the existing Linear flow. The cost-asymmetry argument from ENG-138 (~$25-30 of agent spend held behind operator-resume on the reviewing side) applies symmetrically to the qa side once the reproduction occurs; D-1 prevents that cost on convergent qa cycles. The acknowledged trade-off (cross-loop re-entry after `building → implementing` rebase still inherits the lifetime counter) is honestly named in §7 of the brainstorm and "Out of scope" of this plan. |

**Gate decision: 5/5 PASS · feasibility P0 = 0 · proceeding to implementing.**
