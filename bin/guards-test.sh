#!/usr/bin/env bash
# Test harness for bin/guards.sh (ENG-138).
# Covers the per-stage scoping of the review_rejection threshold introduced
# in ENG-138 (regression: reviewing→qa transition halted on cumulative count).
#
# Source-and-stub pattern: invokes the REAL guards.sh via a fake-repo overlay
# where linear.sh is a per-case stub returning a parameterised get-comments
# payload. Mirrors the shape of bin/run-stage-test.sh::case-15 exactly.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

# common.sh requires TARGET_REPO to exist with a .pipeline-config/config.json.
# Create a minimal one; thresholds absent → guards.sh defaults all to 2.
TARGET_REPO_TMP="$(mktemp -d)"
mkdir -p "$TARGET_REPO_TMP/.pipeline-config/schemas"
printf '{"project":{"slug":"%s"}}' "$PROJECT_SLUG" \
  > "$TARGET_REPO_TMP/.pipeline-config/config.json"
printf '{}' > "$TARGET_REPO_TMP/.pipeline-config/schemas/linear-ids.json"
export TARGET_REPO="$TARGET_REPO_TMP"

STUB_DIR="$(mktemp -d)"
FAKE_REPO="$STUB_DIR/fake-repo"
mkdir -p "$FAKE_REPO/.pipeline/bin" "$FAKE_REPO/.pipeline/schemas"

# Symlink the real guards.sh, common.sh, and pipeline-events.json so we test the live code.
# linear.sh is a per-case stub written inline below.
ln -sf "$SCRIPT_DIR/guards.sh"            "$FAKE_REPO/.pipeline/bin/guards.sh"
ln -sf "$SCRIPT_DIR/common.sh"            "$FAKE_REPO/.pipeline/bin/common.sh"
ln -sf "$SCRIPT_DIR/pipeline-events.json" "$FAKE_REPO/.pipeline/bin/pipeline-events.json"

trap 'rm -rf "$STUB_DIR" "$TARGET_REPO_TMP"' EXIT

PASS=0; FAIL=0
pass_at() { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }
fail_at() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

GUARDS="$FAKE_REPO/.pipeline/bin/guards.sh"

# ── Shared stub writers ──────────────────────────────────────────────────────

# write_stub_two_review_rejections: stub that returns two review_rejection
# markers and no operator-resume waypoint — triggers the threshold (default 2).
write_stub_two_review_rejections() {
  cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get-comments)
    cat <<'JSON'
[
  {"body":"<!-- meta: metric name=review_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:00:00.000Z"},
  {"body":"<!-- meta: metric name=review_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:30:00.000Z"}
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
}

# write_stub_two_rejections_plus_operator_resume: two review_rejection markers
# followed by a newer operator-resume waypoint — counter resets.
write_stub_two_rejections_plus_operator_resume() {
  cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get-comments)
    cat <<'JSON'
[
  {"body":"<!-- meta: metric name=review_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:00:00.000Z"},
  {"body":"<!-- meta: metric name=review_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:30:00.000Z"},
  {"body":"<!-- pipeline: transition from=implementing to=implementing reason=operator-resume -->","createdAt":"2026-05-16T10:00:00.000Z"}
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
}

# ── case-1: AC#2 — ENG-116 intent preserved at stage=implementing ────────────
# Two review_rejection markers, no operator-resume. Stage=implementing.
# Expected: rc=10, output contains review_rejection(2>=2).
write_stub_two_review_rejections

set +e
c1_out="$(bash "$GUARDS" check ENG-T138A implementing 2>&1)"
c1_rc=$?
set -e

if [[ "$c1_rc" == "10" ]] && grep -q 'review_rejection(2>=2)' <<<"$c1_out"; then
  pass_at "case-1: guards trips review_rejection(2>=2) when stage=implementing (AC#2 / ENG-116 intent preserved)"
else
  fail_at "case-1: stage=implementing should trip on count=2" \
    "rc=$c1_rc out=$c1_out"
fi

# ── case-2: AC#1 — regression fix at stage=qa ────────────────────────────────
# Same two review_rejection markers, no operator-resume. Stage=qa.
# Expected: rc=0 (no trip); guards: clear log line appears.
write_stub_two_review_rejections

set +e
c2_out="$(bash "$GUARDS" check ENG-T138B qa 2>&1)"
c2_rc=$?
set -e

if [[ "$c2_rc" == "0" ]] && grep -q 'guards: clear' <<<"$c2_out"; then
  pass_at "case-2: guards does NOT trip review_rejection when stage=qa (AC#1 / ENG-138 regression fix)"
else
  fail_at "case-2: stage=qa should NOT trip on review_rejection count=2" \
    "rc=$c2_rc out=$c2_out"
fi

# ── case-3: AC#3 — operator-resume still resets the counter ─────────────────
# Two review_rejection markers + a newer operator-resume waypoint. Stage=implementing.
# Expected: rc=0 (counter reset by operator-resume).
write_stub_two_rejections_plus_operator_resume

set +e
c3_out="$(bash "$GUARDS" check ENG-T138C implementing 2>&1)"
c3_rc=$?
set -e

if [[ "$c3_rc" == "0" ]]; then
  pass_at "case-3: operator-resume waypoint resets review_rejection counter (AC#3 / ENG-116 contract preserved)"
else
  fail_at "case-3: operator-resume should clear the counter" \
    "rc=$c3_rc out=$c3_out"
fi

# ── case-4: empty-stage back-compat (operator-triage / case-15 CLI shape) ───
# Two review_rejection markers, no operator-resume. NO stage arg (direct CLI).
# Expected: rc=10 (trip-as-today preserved for back-compat).
write_stub_two_review_rejections

set +e
c4_out="$(bash "$GUARDS" check ENG-T138D 2>&1)"
c4_rc=$?
set -e

if [[ "$c4_rc" == "10" ]] && grep -q 'review_rejection(2>=2)' <<<"$c4_out"; then
  pass_at "case-4: no stage arg still trips review_rejection(2>=2) (back-compat for operator-triage / case-15)"
else
  fail_at "case-4: no-stage-arg invocation should trip as today (ENG-138 D-2 empty-stage branch)" \
    "rc=$c4_rc out=$c4_out"
fi

# ── case-5 (QA-adversarial): stage=reviewing does NOT trip review_rejection ──
# Stage=reviewing with 2 review_rejection markers: the check should fire only
# on stage=implementing, not on any other non-empty stage.
write_stub_two_review_rejections

set +e
c5_out="$(bash "$GUARDS" check ENG-T138E reviewing 2>&1)"
c5_rc=$?
set -e

if [[ "$c5_rc" == "0" ]] && grep -q 'guards: clear' <<<"$c5_out"; then
  pass_at "case-5: stage=reviewing does NOT trip review_rejection (only implementing fires)"
else
  fail_at "case-5: stage=reviewing should NOT trip review_rejection" \
    "rc=$c5_rc out=$c5_out"
fi

# ── case-6 (QA-adversarial): stage=building does NOT trip review_rejection ───
# Same fixture. Stage=building (forward edge post-qa-pass) must not trip.
write_stub_two_review_rejections

set +e
c6_out="$(bash "$GUARDS" check ENG-T138F building 2>&1)"
c6_rc=$?
set -e

if [[ "$c6_rc" == "0" ]] && grep -q 'guards: clear' <<<"$c6_out"; then
  pass_at "case-6: stage=building does NOT trip review_rejection"
else
  fail_at "case-6: stage=building should NOT trip review_rejection" \
    "rc=$c6_rc out=$c6_out"
fi

# ── case-7 (QA-adversarial): below-threshold count (1) at stage=implementing ─
# One review_rejection marker (< threshold 2). Should NOT trip even at
# implementing — boundary test for the >= operator.
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get-comments)
    cat <<'JSON'
[
  {"body":"<!-- meta: metric name=review_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:00:00.000Z"}
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
c7_out="$(bash "$GUARDS" check ENG-T138G implementing 2>&1)"
c7_rc=$?
set -e

if [[ "$c7_rc" == "0" ]] && grep -q 'guards: clear' <<<"$c7_out"; then
  pass_at "case-7: count=1 < threshold=2 does NOT trip at stage=implementing (boundary)"
else
  fail_at "case-7: count below threshold must not trip" \
    "rc=$c7_rc out=$c7_out"
fi

# ── case-8 (QA-adversarial): multi-counter trip at stage=implementing ─────────
# Two review_rejection markers + two qa_rejection markers, stage=implementing.
# Both counters should appear in the trip output.
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get-comments)
    cat <<'JSON'
[
  {"body":"<!-- meta: metric name=review_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:00:00.000Z"},
  {"body":"<!-- meta: metric name=review_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:30:00.000Z"},
  {"body":"<!-- meta: metric name=qa_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:45:00.000Z"},
  {"body":"<!-- meta: metric name=qa_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T10:00:00.000Z"}
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
c8_out="$(bash "$GUARDS" check ENG-T138H implementing 2>&1)"
c8_rc=$?
set -e

if [[ "$c8_rc" == "10" ]] \
   && grep -q 'review_rejection(2>=2)' <<<"$c8_out" \
   && grep -q 'qa_rejection(2>=2)' <<<"$c8_out"; then
  pass_at "case-8: multi-counter trip: review_rejection AND qa_rejection both appear in output"
else
  fail_at "case-8: both review_rejection and qa_rejection should trip at stage=implementing" \
    "rc=$c8_rc out=$c8_out"
fi

# ── case-9 (ENG-145 inversion): qa stage with qa_rejection >=threshold does NOT trip ──
# Pre-ENG-145 this asserted that qa_rejection trips at stage=qa (ENG-138 narrowing
# was review_rejection-only). ENG-145 extends the narrowing to qa_rejection (and
# implement_rejection). The trip now fires only at stage=implementing — see
# bin/guards.sh:138-140 and the symmetric implementer-rejection block at 141-143.
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
c9_out="$(bash "$GUARDS" check ENG-T138I qa 2>&1)"
c9_rc=$?
set -e

if [[ "$c9_rc" == "0" ]] && grep -q 'guards: clear' <<<"$c9_out"; then
  pass_at "case-9: qa_rejection does NOT trip at stage=qa (ENG-145 extends the ENG-138 narrowing to qa_rejection)"
else
  fail_at "case-9: qa_rejection at stage=qa should NOT trip post-ENG-145" \
    "rc=$c9_rc out=$c9_out"
fi

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

# ── case-11: AC#2 — qa_rejection does NOT trip at stage=building (forward edge) ──
# Two qa_rejection markers, no operator-resume, stage=building (post-PASS forward edge).
# Expected: rc=0, output contains "guards: clear".
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
c11_out="$(bash "$GUARDS" check ENG-T145B building 2>&1)"
c11_rc=$?
set -e

if [[ "$c11_rc" == "0" ]] && grep -q 'guards: clear' <<<"$c11_out"; then
  pass_at "case-11: qa_rejection does NOT trip at stage=building (AC#2 — forward edge after qa PASS)"
else
  fail_at "case-11: stage=building should NOT trip on cumulative qa_rejection count=2" \
    "rc=$c11_rc out=$c11_out"
fi

# ── case-12: AC#3 — implement_rejection trips at stage=implementing ──────────
# Two implement_rejection markers, no operator-resume, stage=implementing.
# Expected: rc=10, output contains implement_rejection(2>=2).
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get-comments)
    cat <<'JSON'
[
  {"body":"<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:00:00.000Z"},
  {"body":"<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:30:00.000Z"}
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
c12_out="$(bash "$GUARDS" check ENG-T145C implementing 2>&1)"
c12_rc=$?
set -e

if [[ "$c12_rc" == "10" ]] && grep -q 'implement_rejection(2>=2)' <<<"$c12_out"; then
  pass_at "case-12: implement_rejection trips at stage=implementing (AC#3)"
else
  fail_at "case-12: stage=implementing should trip on implement_rejection count=2" \
    "rc=$c12_rc out=$c12_out"
fi

# ── case-13: AC#4 — operator-resume waypoint resets BOTH qa and implement counters ──
# Two qa_rejection markers + two implement_rejection markers + a NEWER operator-resume
# transition. Stage=implementing. Expected: rc=0 (both counters reset by operator-resume).
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get-comments)
    cat <<'JSON'
[
  {"body":"<!-- meta: metric name=qa_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:00:00.000Z"},
  {"body":"<!-- meta: metric name=qa_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:15:00.000Z"},
  {"body":"<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:30:00.000Z"},
  {"body":"<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:45:00.000Z"},
  {"body":"<!-- pipeline: transition from=implementing to=implementing reason=operator-resume -->","createdAt":"2026-05-16T10:00:00.000Z"}
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
c13_out="$(bash "$GUARDS" check ENG-T145D implementing 2>&1)"
c13_rc=$?
set -e

if [[ "$c13_rc" == "0" ]] && grep -q 'guards: clear' <<<"$c13_out"; then
  pass_at "case-13: operator-resume waypoint resets BOTH qa_rejection and implement_rejection (AC#4 — ENG-116 contract preserved)"
else
  fail_at "case-13: operator-resume should clear both rejection counters at stage=implementing" \
    "rc=$c13_rc out=$c13_out"
fi

# ── case-bump-1: AC#1 — fail-closed without --reason ─────────────────────────
# bump() invoked with no flags → must die with non-zero rc and '--reason' in message.
BUMP_CAPTURE="$STUB_DIR/bump-body.capture"
: > "$BUMP_CAPTURE"

cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
cb1_out="$(bash "$GUARDS" bump ENG-T153A implement_rejection 2>&1)"
cb1_rc=$?
set -e

if [[ "$cb1_rc" != "0" ]] && grep -q -- 'bump: --reason "<text>" required' <<<"$cb1_out"; then
  pass_at "case-bump-1: bump without --reason exits non-zero with exact die message (AC#1)"
else
  fail_at "case-bump-1: bump without --reason should fail citing 'bump: --reason \"<text>\" required'" \
    "rc=$cb1_rc out=$cb1_out"
fi

# ── case-bump-2: AC#3 + AC#4 — populated body with --reason and --reason-code ─
: > "$BUMP_CAPTURE"

# implement_rejection uses count_marker_since_last_operator_resume (post-major-fix);
# stub get-comments returns [] so the no-resume branch counts zero pre-existing markers.
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  query) printf '%s\n' '{"data":{"issue":{"comments":{"nodes":[]}}}}' ;;
  get-comments) printf '%s\n' '[]' ;;
  add-comment)
    printf '%s\n' "\${3:-}" >> "$BUMP_CAPTURE"
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
cb2_out="$(bash "$GUARDS" bump ENG-T153B implement_rejection \
  --reason "SEVERE scope violation on x.sh" \
  --reason-code scope-violation-severe 2>&1)"
cb2_rc=$?
set -e

cb2_pass=1
[[ "$cb2_rc" == "0" ]] || cb2_pass=0
grep -q 'Reason: SEVERE scope violation on x.sh' "$BUMP_CAPTURE" || cb2_pass=0
grep -q '(1/2)' "$BUMP_CAPTURE" || cb2_pass=0
grep -q 'Trips at: 2/2' "$BUMP_CAPTURE" || cb2_pass=0
grep -q '<!-- meta: metric name=implement_rejection reason-code=scope-violation-severe -->' "$BUMP_CAPTURE" || cb2_pass=0

if [[ "$cb2_pass" == "1" ]]; then
  pass_at "case-bump-2: populated body contains reason, (1/2), threshold, and reason-code marker (AC#3+AC#4)"
else
  fail_at "case-bump-2: populated body missing required component(s)" \
    "rc=$cb2_rc out=$cb2_out body=$(cat "$BUMP_CAPTURE")"
fi

# ── case-bump-3: AC#3 — bare-form marker when --reason-code omitted ───────────
: > "$BUMP_CAPTURE"

# implement_rejection reads via get-comments after major fix; stub returns [].
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  query) printf '%s\n' '{"data":{"issue":{"comments":{"nodes":[]}}}}' ;;
  get-comments) printf '%s\n' '[]' ;;
  add-comment)
    printf '%s\n' "\${3:-}" >> "$BUMP_CAPTURE"
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
cb3_out="$(bash "$GUARDS" bump ENG-T153C implement_rejection \
  --reason "scope violation" 2>&1)"
cb3_rc=$?
set -e

cb3_pass=1
[[ "$cb3_rc" == "0" ]] || cb3_pass=0
grep -q 'Reason: scope violation' "$BUMP_CAPTURE" || cb3_pass=0
grep -q '<!-- meta: metric name=implement_rejection -->' "$BUMP_CAPTURE" || cb3_pass=0

if [[ "$cb3_pass" == "1" ]]; then
  pass_at "case-bump-3: bare-form marker emitted when --reason-code omitted (AC#3 fallback path)"
else
  fail_at "case-bump-3: bare-form marker missing or reason text absent" \
    "rc=$cb3_rc out=$cb3_out body=$(cat "$BUMP_CAPTURE")"
fi

# ── case-bump-4: D-003 schema-reject — unknown reason-code dies loud ──────────
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
cb4_out="$(bash "$GUARDS" bump ENG-T153D implement_rejection \
  --reason "x" --reason-code bogus-token 2>&1)"
cb4_rc=$?
set -e

if [[ "$cb4_rc" != "0" ]] && grep -q 'metric_reason_codes' <<<"$cb4_out"; then
  pass_at "case-bump-4: unknown --reason-code dies with metric_reason_codes in message (D-003)"
else
  fail_at "case-bump-4: unknown reason-code should fail citing metric_reason_codes" \
    "rc=$cb4_rc out=$cb4_out"
fi

# ── case-bump-5: D-004 counter math — pre-existing marker bumps count to 2 ────
: > "$BUMP_CAPTURE"

# implement_rejection counts via count_marker_since_last_operator_resume after
# the major fix. Seed the pre-existing marker via get-comments (the helper's
# read source); no operator-resume waypoint, so the no-resume branch counts
# the seeded marker.
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  query) printf '%s\n' '{"data":{"issue":{"comments":{"nodes":[]}}}}' ;;
  get-comments)
    printf '%s\n' '[{"body":"<!-- meta: metric name=implement_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:00:00.000Z"}]'
    ;;
  add-comment)
    printf '%s\n' "\${3:-}" >> "$BUMP_CAPTURE"
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
cb5_out="$(bash "$GUARDS" bump ENG-T153E implement_rejection \
  --reason "x" --reason-code scope-violation 2>&1)"
cb5_rc=$?
set -e

if [[ "$cb5_rc" == "0" ]] && grep -q '(2/2)' "$BUMP_CAPTURE"; then
  pass_at "case-bump-5: counter math shows (2/2) with one pre-existing marker (D-004 §c)"
else
  fail_at "case-bump-5: body should show (2/2) with one pre-existing marker" \
    "rc=$cb5_rc out=$cb5_out body=$(cat "$BUMP_CAPTURE")"
fi

# ── case-bump-6: D-004 gotcha clearing prose variant ─────────────────────────
: > "$BUMP_CAPTURE"

cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  query) printf '%s\n' '{"data":{"issue":{"comments":{"nodes":[]}}}}' ;;
  add-comment)
    printf '%s\n' "\${3:-}" >> "$BUMP_CAPTURE"
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
cb6_out="$(bash "$GUARDS" bump ENG-T153F gotcha_triggered \
  --reason "Gotcha-hit: G-12 found on commit" --reason-code gotcha-hit 2>&1)"
cb6_rc=$?
set -e

cb6_pass=1
[[ "$cb6_rc" == "0" ]] || cb6_pass=0
grep -q 'cleared by label pipeline:knowledge-reviewed' "$BUMP_CAPTURE" || cb6_pass=0
grep -q '<!-- meta: metric name=gotcha_triggered reason-code=gotcha-hit -->' "$BUMP_CAPTURE" || cb6_pass=0

if [[ "$cb6_pass" == "1" ]]; then
  pass_at "case-bump-6: gotcha_triggered body uses knowledge-reviewed clearing prose (D-004)"
else
  fail_at "case-bump-6: gotcha body missing clearing-prose or marker" \
    "rc=$cb6_rc out=$cb6_out body=$(cat "$BUMP_CAPTURE")"
fi

# ── case-bump-7: D-005 reader regression — check() counts new-shape markers ──
# Seeds two implement_rejection markers carrying reason-code= suffix. Without
# Task 2's regex update, count_marker_since_last_operator_resume's contains()
# match misses them (literal close --> not present), so check() returns 0 and
# allows infinite loopback. After Task 2 the test() regex correctly counts both.
# Stub deliberately omits any `<!-- pipeline: transition ... reason=operator-resume -->`
# waypoint to exercise the no-resume branch of count_marker_since_last_operator_resume.
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get-comments)
    cat <<'JSON'
[
  {"body":"<!-- meta: metric name=implement_rejection reason-code=scope-violation-severe --> Counter bumped.","createdAt":"2026-05-16T09:00:00.000Z"},
  {"body":"<!-- meta: metric name=implement_rejection reason-code=scope-violation-severe --> Counter bumped.","createdAt":"2026-05-16T09:30:00.000Z"}
]
JSON
    ;;
  query) printf '%s\n' '{"data":{"issue":{"comments":{"nodes":[]}}}}' ;;
  has-label) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
cb7_out="$(bash "$GUARDS" check ENG-T153G implementing 2>&1)"
cb7_rc=$?
set -e

if [[ "$cb7_rc" == "10" ]] && grep -q 'implement_rejection(2>=2)' <<<"$cb7_out"; then
  pass_at "case-bump-7: reader counts new-shape markers with reason-code= suffix (D-005 regression guard)"
else
  fail_at "case-bump-7: reader must count reason-code markers — regex not updated (Task 2)" \
    "rc=$cb7_rc out=$cb7_out"
fi

# ── case-bump-8: §6 lane-fence — marker-injection via --reason text dies loud ─
# Regression guard for bin/guards.sh:177-180 (defensive case match against
# `<!-- pipeline:` and `<!-- meta:` openers inside --reason). Without the
# guard, a marker-bearing reason string would slip past _classify_comment_body's
# first-line-only inspection while still being readable by full-body parsers,
# defeating the lane-fence semantics named in brainstorm §6.
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
cb8_out="$(bash "$GUARDS" bump ENG-T153H implement_rejection \
  --reason "<!-- pipeline: verdict result=halt -->" 2>&1)"
cb8_rc=$?
set -e

if [[ "$cb8_rc" != "0" ]] && grep -q 'pipeline/meta marker opener' <<<"$cb8_out"; then
  pass_at "case-bump-8: --reason containing pipeline marker opener dies with lane-fence diagnostic (§6 guard)"
else
  fail_at "case-bump-8: pipeline-marker in --reason must die citing 'pipeline/meta marker opener'" \
    "rc=$cb8_rc out=$cb8_out"
fi

# ── case-bump-qa-1: --reason "" (empty string) is rejected like missing flag ─
# Exercises the `[[ -n "$reason" ]]` guard at bin/guards.sh:175.
# The flag is present but its value is empty — parser assigns reason="" via
# `${2:-}` then the -n gate fires. Distinguishes "flag present, empty value"
# from "flag absent" (case-bump-1 covers the latter). Both must die identically.
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
cbq1_out="$(bash "$GUARDS" bump ENG-TQAQ1 implement_rejection \
  --reason "" 2>&1)"
cbq1_rc=$?
set -e

if [[ "$cbq1_rc" != "0" ]] && grep -q 'bump: --reason.*required' <<<"$cbq1_out"; then
  pass_at "case-bump-qa-1: --reason \"\" (empty string) is rejected identical to missing flag"
else
  fail_at "case-bump-qa-1: empty --reason must die with --reason required diagnostic" \
    "rc=$cbq1_rc out=$cbq1_out"
fi

# ── case-bump-qa-2: learned_rule_renewal uses rule-reviewed clearing prose ───
# Parallel to case-bump-6 (gotcha_triggered → knowledge-reviewed). Verifies
# bin/guards.sh:224 `trip_clause` branch for learned_rule_renewal emits
# "cleared by label pipeline:rule-reviewed" (not knowledge-reviewed, not the
# skip-until-human-acts prose).
: > "$BUMP_CAPTURE"

cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  query) printf '%s\n' '{"data":{"issue":{"comments":{"nodes":[]}}}}' ;;
  add-comment)
    printf '%s\n' "\${3:-}" >> "$BUMP_CAPTURE"
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
cbq2_out="$(bash "$GUARDS" bump ENG-TQAQ2 learned_rule_renewal \
  --reason "Rule renewal: retro agent rewrote scope rule for third time" 2>&1)"
cbq2_rc=$?
set -e

cbq2_pass=1
[[ "$cbq2_rc" == "0" ]] || cbq2_pass=0
grep -q 'cleared by label pipeline:rule-reviewed' "$BUMP_CAPTURE" || cbq2_pass=0
# must NOT contain the gotcha or skip-until prose
grep -q 'knowledge-reviewed' "$BUMP_CAPTURE" && cbq2_pass=0
grep -q 'skip-until-human-acts' "$BUMP_CAPTURE" && cbq2_pass=0

if [[ "$cbq2_pass" == "1" ]]; then
  pass_at "case-bump-qa-2: learned_rule_renewal body uses rule-reviewed clearing prose"
else
  fail_at "case-bump-qa-2: learned_rule_renewal body must carry 'cleared by label pipeline:rule-reviewed'" \
    "rc=$cbq2_rc out=$cbq2_out body=$(cat "$BUMP_CAPTURE")"
fi

# ── case-bump-qa-3: unknown CLI flag dies with diagnostic ────────────────────
# Exercises bin/guards.sh:172 `*) die "bump: unknown flag..."`. Ensures the
# parser does not silently discard unrecognised flags (which would allow a
# caller typo like `--resaon` to silently pass, skipping the reason check).
cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_REPO/.pipeline/bin/linear.sh"

set +e
cbq3_out="$(bash "$GUARDS" bump ENG-TQAQ3 implement_rejection \
  --bogus-flag "something" --reason "legit reason" 2>&1)"
cbq3_rc=$?
set -e

if [[ "$cbq3_rc" != "0" ]] && grep -q "bump: unknown flag" <<<"$cbq3_out"; then
  pass_at "case-bump-qa-3: unknown CLI flag dies with 'bump: unknown flag' diagnostic"
else
  fail_at "case-bump-qa-3: unknown flag must die citing 'bump: unknown flag'" \
    "rc=$cbq3_rc out=$cbq3_out"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\nguards-test: passed=%s failed=%s\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
