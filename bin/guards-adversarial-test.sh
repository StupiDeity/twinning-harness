#!/usr/bin/env bash
# Adversarial test suite for bin/guards.sh (ENG-138 — QA-authored).
# Covers paths NOT in the plan's Failure Mode → Test Map:
#   A1: stage=brainstorming (non-rejection stage) → no review_rejection trip
#   A2: stage=reviewing (the exact regression stage pre-ENG-138) → no trip
#   A3: count=1 at stage=implementing (below threshold=2) → no trip
#   A4: qa_rejection at threshold with stage=qa → does NOT trip (ENG-145 inversion)
#   A5: review_rejection + qa_rejection both at threshold, stage=qa → NEITHER trips (ENG-145 inversion)
#   A6: explicit empty-string stage arg → trips (same as no-arg back-compat path)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

TARGET_REPO_TMP="$(mktemp -d)"
mkdir -p "$TARGET_REPO_TMP/.pipeline-config/schemas"
printf '{"project":{"slug":"%s"}}' "$PROJECT_SLUG" \
  > "$TARGET_REPO_TMP/.pipeline-config/config.json"
printf '{}' > "$TARGET_REPO_TMP/.pipeline-config/schemas/linear-ids.json"
export TARGET_REPO="$TARGET_REPO_TMP"

STUB_DIR="$(mktemp -d)"
FAKE_REPO="$STUB_DIR/fake-repo"
mkdir -p "$FAKE_REPO/.pipeline/bin" "$FAKE_REPO/.pipeline/schemas"
ln -sf "$SCRIPT_DIR/guards.sh" "$FAKE_REPO/.pipeline/bin/guards.sh"
ln -sf "$SCRIPT_DIR/common.sh" "$FAKE_REPO/.pipeline/bin/common.sh"

trap 'rm -rf "$STUB_DIR" "$TARGET_REPO_TMP"' EXIT

PASS=0; FAIL=0
pass_at() { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }
fail_at() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

GUARDS="$FAKE_REPO/.pipeline/bin/guards.sh"

# ── Stub helpers ─────────────────────────────────────────────────────────────

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

write_stub_one_review_rejection() {
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
}

write_stub_two_qa_rejections() {
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
}

write_stub_two_review_and_two_qa_rejections() {
  cat > "$FAKE_REPO/.pipeline/bin/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get-comments)
    cat <<'JSON'
[
  {"body":"<!-- meta: metric name=review_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:00:00.000Z"},
  {"body":"<!-- meta: metric name=review_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T09:30:00.000Z"},
  {"body":"<!-- meta: metric name=qa_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T10:00:00.000Z"},
  {"body":"<!-- meta: metric name=qa_rejection --> Counter bumped by guards.sh.","createdAt":"2026-05-16T10:30:00.000Z"}
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

# ── case-A1: stage=brainstorming with 2 review_rejections → no trip ──────────
# The fix suppresses review_rejection for ALL non-implementing stages.
# Brainstorming is the earliest stage; verifies suppression isn't only for qa.
write_stub_two_review_rejections

set +e
cA1_out="$(bash "$GUARDS" check ENG-TA1 brainstorming 2>&1)"
cA1_rc=$?
set -e

if [[ "$cA1_rc" == "0" ]] && grep -q 'guards: clear' <<<"$cA1_out"; then
  pass_at "case-A1: stage=brainstorming does NOT trip review_rejection (other non-implementing stages covered)"
else
  fail_at "case-A1: stage=brainstorming should NOT trip review_rejection" \
    "rc=$cA1_rc out=$cA1_out"
fi

# ── case-A2: stage=reviewing with 2 review_rejections → no trip ─────────────
# This is the EXACT stage that was regressing pre-ENG-138. The fix names qa
# in the brainstorm but the regression was actually on the reviewing→qa forward
# transition, so the reviewing stage itself is the canonical victim.
write_stub_two_review_rejections

set +e
cA2_out="$(bash "$GUARDS" check ENG-TA2 reviewing 2>&1)"
cA2_rc=$?
set -e

if [[ "$cA2_rc" == "0" ]] && grep -q 'guards: clear' <<<"$cA2_out"; then
  pass_at "case-A2: stage=reviewing does NOT trip review_rejection (exact pre-ENG-138 regression stage)"
else
  fail_at "case-A2: stage=reviewing should NOT trip review_rejection" \
    "rc=$cA2_rc out=$cA2_out"
fi

# ── case-A3: count=1 at stage=implementing → no trip (below threshold=2) ────
# The existing case-1 tests count==threshold. This tests count < threshold at
# the implementing stage to confirm the >= boundary is correct (not just >).
write_stub_one_review_rejection

set +e
cA3_out="$(bash "$GUARDS" check ENG-TA3 implementing 2>&1)"
cA3_rc=$?
set -e

if [[ "$cA3_rc" == "0" ]] && grep -q 'guards: clear' <<<"$cA3_out"; then
  pass_at "case-A3: count=1 at stage=implementing does NOT trip (below threshold=2 boundary check)"
else
  fail_at "case-A3: count=1 at implementing should be below threshold (>=2 means 1 is clear)" \
    "rc=$cA3_rc out=$cA3_out"
fi

# ── case-A4 (ENG-145 inversion): qa_rejection at threshold, stage=qa → does NOT trip ──
# Pre-ENG-145 this asserted that qa_rejection trips at stage=qa (ENG-138 fix was
# review_rejection-only). ENG-145 extends the stage gate to qa_rejection: trip
# now fires only at stage=implementing — see bin/guards.sh:138-140.
write_stub_two_qa_rejections

set +e
cA4_out="$(bash "$GUARDS" check ENG-TA4 qa 2>&1)"
cA4_rc=$?
set -e

if [[ "$cA4_rc" == "0" ]] && grep -q 'guards: clear' <<<"$cA4_out"; then
  pass_at "case-A4: qa_rejection does NOT trip at stage=qa (ENG-145 extends the ENG-138 narrowing)"
else
  fail_at "case-A4: qa_rejection at stage=qa should NOT trip post-ENG-145" \
    "rc=$cA4_rc out=$cA4_out"
fi

# ── case-A5 (ENG-145 inversion): both counters at threshold, stage=qa → NEITHER trips ──
# Pre-ENG-145 this asserted that at stage=qa, qa_rejection trips while
# review_rejection is suppressed. ENG-145 extends the suppression: at any non-
# implementing stage, NEITHER counter trips. The scoping is still counter-
# specific (gotcha/rule counters are unaffected), but qa_rejection now joins
# review_rejection in the implementing-only firing edge.
write_stub_two_review_and_two_qa_rejections

set +e
cA5_out="$(bash "$GUARDS" check ENG-TA5 qa 2>&1)"
cA5_rc=$?
set -e

if [[ "$cA5_rc" == "0" ]] \
    && grep -q 'guards: clear' <<<"$cA5_out" \
    && ! grep -q 'qa_rejection(2>=2)' <<<"$cA5_out" \
    && ! grep -q 'review_rejection(2>=2)' <<<"$cA5_out"; then
  pass_at "case-A5: at stage=qa, NEITHER qa_rejection NOR review_rejection trips (ENG-145 symmetric suppression)"
else
  fail_at "case-A5: stage=qa should suppress BOTH qa_rejection and review_rejection post-ENG-145" \
    "rc=$cA5_rc out=$cA5_out"
fi

# ── case-A6: explicit empty-string stage arg → trips (same as no-arg) ────────
# run-stage.sh always passes a non-empty stage, but a direct CLI caller could
# pass "" explicitly. The [[ -z "$stage" ]] branch must catch this.
write_stub_two_review_rejections

set +e
cA6_out="$(bash "$GUARDS" check ENG-TA6 "" 2>&1)"
cA6_rc=$?
set -e

if [[ "$cA6_rc" == "10" ]] && grep -q 'review_rejection(2>=2)' <<<"$cA6_out"; then
  pass_at "case-A6: explicit empty-string stage arg trips as today (ENG-138 D-2 -z branch)"
else
  fail_at "case-A6: explicit empty-string stage arg should trip (same as no-arg back-compat)" \
    "rc=$cA6_rc out=$cA6_out"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\nguards-adversarial-test: passed=%s failed=%s\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
