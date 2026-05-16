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

# Symlink the real guards.sh and common.sh so we test the live code.
# linear.sh is a per-case stub written inline below.
ln -sf "$SCRIPT_DIR/guards.sh"  "$FAKE_REPO/.pipeline/bin/guards.sh"
ln -sf "$SCRIPT_DIR/common.sh"  "$FAKE_REPO/.pipeline/bin/common.sh"

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

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\nguards-test: passed=%s failed=%s\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
