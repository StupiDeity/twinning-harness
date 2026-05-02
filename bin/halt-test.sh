#!/usr/bin/env bash
# ENG-49 Gap #2: halt.sh resolve --decision resume calls verdict-handler
# before clearing pipeline:halted.
# ENG-58: extends coverage to atomic state reset (cases E–R).
set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY

_TEST_TARGET="$(mktemp -d -t twinning-halt-target.XXXXXX)"
_TEST_STUB="$(mktemp -d -t twinning-halt-stub.XXXXXX)"
_TEST_HARNESS_STATE_DIR="$(mktemp -d -t twinning-halt-state.XXXXXX)"
case "$_TEST_TARGET"            in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
case "$_TEST_STUB"              in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
case "$_TEST_HARNESS_STATE_DIR" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;; *) exit 99 ;; esac
trap 'rm -rf "$_TEST_TARGET" "$_TEST_STUB" "$_TEST_HARNESS_STATE_DIR"' EXIT

mkdir -p "$_TEST_TARGET/.pipeline-config"
cat > "$_TEST_TARGET/.pipeline-config/config.json" <<'JSON'
{"project":{"slug":"test-slug"},"orchestrator":{"paused":false},"linear":{"native_states":{"in_review":"In Review","done":"Done"}}}
JSON
export TARGET_REPO="$_TEST_TARGET"

# Isolate per-issue state writes from the operator's real state dir.
HARNESS_STATE_DIR="$_TEST_HARNESS_STATE_DIR"
export HARNESS_STATE_DIR
PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
export PROJECT_STATE_DIR
mkdir -p "$PROJECT_STATE_DIR"

LINEAR_CALLS="$_TEST_STUB/linear-calls.log"
: > "$LINEAR_CALLS"
# More capable linear.sh stub: handles has-label via LABELS_ON CSV and
# stage-of via STAGE_OF env var (default 'stage:ui' preserves old A–D
# semantics). add-comment / remove-label / add-label exit 0; LINEAR_CALLS
# logs every invocation as a single line with all args.
cat > "$_TEST_STUB/linear.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LINEAR_CALLS"
case "\$1" in
  add-comment|remove-label|add-label) exit 0 ;;
  stage-of) printf '%s' "\${STAGE_OF:-stage:ui}" ;;
  has-label)
    case ",\${LABELS_ON:-}," in *,"\$3",*) exit 0 ;; *) exit 1 ;; esac
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$_TEST_STUB/linear.sh"

# metrics.sh stub captures all halt-resume emissions (one line per call).
METRICS_CALLS="$_TEST_STUB/metrics-calls.log"
: > "$METRICS_CALLS"
cat > "$_TEST_STUB/metrics.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$METRICS_CALLS"
exit 0
SH
chmod +x "$_TEST_STUB/metrics.sh"

# Stub verdict-handler — return-code controllable via VH_RC env var.
cat > "$_TEST_STUB/verdict-handler.sh" <<'SH'
verdict_handler() { return "${VH_RC:-0}"; }
export -f verdict_handler
SH

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# ─── ENG-58 fixture helpers ─────────────────────────────────────────────
_eng58_seed_side_state() {
  # Args: <issue> [policy=skip-until-human-acts|skip-until-code-changes]
  local issue="$1" policy="${2:-skip-until-human-acts}"
  local d="$PROJECT_STATE_DIR/$issue"
  mkdir -p "$d"
  printf '{"reason":"awaiting-approval","attempts":12}\n' > "$d/wait-build.json"
  jq -cn --arg p "$policy" '{policy:$p, evidence:{pipeline_content_hash:"abc",branch_head_sha:"def"}}' \
    > "$d/issue-state.json"
}

_eng58_clear_side_state() {
  rm -rf "$PROJECT_STATE_DIR/$1"
}

# Source halt.sh post-config so it sees TARGET_REPO. Override SCRIPT_DIR
# AFTER sourcing so internal calls point at stubs.
# shellcheck source=halt.sh
source "$SCRIPT_DIR_REAL/halt.sh"
SCRIPT_DIR="$_TEST_STUB"

# Case A: --decision resume + verdict-handler returns 0 → halt.sh skips remove-label.
# LABELS_ON injected so D-011's has-label guard sees pipeline:halted and runs verdict_handler.
: > "$LINEAR_CALLS"
LABELS_ON="pipeline:halted" VH_RC=0 resolve "ENG-980" "resume" >/dev/null 2>&1 || true
remove_count="$(grep -c "^remove-label ENG-980 pipeline:halted$" "$LINEAR_CALLS" || true)"
[[ "$remove_count" == "0" ]] \
  && ok "Gap-2 rc=0: halt.sh skips its own remove-label" \
  || nope "Gap-2 rc=0 skip remove-label" "remove-label called $remove_count time(s)"

# Case B: --decision resume + verdict-handler returns 1 → halt.sh removes halt.
: > "$LINEAR_CALLS"
LABELS_ON="pipeline:halted" VH_RC=1 resolve "ENG-981" "resume" >/dev/null 2>&1 || true
remove_count="$(grep -c "^remove-label ENG-981 pipeline:halted$" "$LINEAR_CALLS" || true)"
[[ "$remove_count" == "1" ]] \
  && ok "Gap-2 rc=1: halt.sh removes halt label" \
  || nope "Gap-2 rc=1 remove halt label" "remove-label called $remove_count time(s)"

# Case C: --decision resume + verdict-handler returns 2 → halt.sh exits non-zero, halt preserved.
: > "$LINEAR_CALLS"
exit_code=0
( LABELS_ON="pipeline:halted" VH_RC=2 resolve "ENG-982" "resume" >/dev/null 2>&1 ) || exit_code=$?
remove_count="$(grep -c "^remove-label ENG-982 pipeline:halted$" "$LINEAR_CALLS" || true)"
if [[ "$exit_code" -ne 0 && "$remove_count" == "0" ]]; then
  ok "Gap-2 rc=2: halt.sh exits non-zero, halt preserved"
else
  nope "Gap-2 rc=2: halt.sh exits non-zero, halt preserved" \
    "exit=$exit_code remove-count=$remove_count"
fi

# Case D: --decision scope-approved → no verdict-handler involvement, current behavior.
: > "$LINEAR_CALLS"
LABELS_ON="pipeline:halted" VH_RC=99 resolve "ENG-983" "scope-approved" >/dev/null 2>&1 || true
remove_count="$(grep -c "^remove-label ENG-983 pipeline:halted$" "$LINEAR_CALLS" || true)"
[[ "$remove_count" == "1" ]] \
  && ok "Gap-2 scope-approved: current behavior preserved (rm halt)" \
  || nope "Gap-2 scope-approved" "remove-label called $remove_count time(s)"

# ─── ENG-58 Case E: vh_rc=1 + halted + full side state → atomic reset ───
: > "$LINEAR_CALLS"; : > "$METRICS_CALLS"
_eng58_seed_side_state "ENG-984" skip-until-human-acts
LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
  VH_RC=1 STAGE_OF="stage:building" \
  resolve "ENG-984" "resume" >/dev/null 2>&1 || true
wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-984/wait-build.json" ]] && wait_present=1
state_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-984/issue-state.json" ]] && state_present=1
skip_remove="$(grep -c "^remove-label ENG-984 pipeline:skip-until-human-acts$" "$LINEAR_CALLS" || true)"
halt_remove="$(grep -c "^remove-label ENG-984 pipeline:halted$" "$LINEAR_CALLS" || true)"
waypoint="$(grep -c "operator-resume" "$LINEAR_CALLS" || true)"
if [[ "$wait_present" == "0" && "$state_present" == "0" \
      && "$skip_remove" == "1" && "$halt_remove" == "1" \
      && "$waypoint" -ge "1" ]]; then
  ok "ENG-58 E: vh_rc=1 atomic reset (wait+state cleared, labels removed, waypoint posted)"
else
  nope "ENG-58 E: vh_rc=1 atomic reset" \
    "wait=$wait_present state=$state_present skip_remove=$skip_remove halt_remove=$halt_remove waypoint=$waypoint"
fi
_eng58_clear_side_state "ENG-984"

# ─── ENG-58 Case F: vh_rc=0 + halted → cleanup runs, NO waypoint ───────
: > "$LINEAR_CALLS"; : > "$METRICS_CALLS"
_eng58_seed_side_state "ENG-985" skip-until-human-acts
LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
  VH_RC=0 STAGE_OF="stage:building" \
  resolve "ENG-985" "resume" >/dev/null 2>&1 || true
wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-985/wait-build.json" ]] && wait_present=1
waypoint="$(grep -c "operator-resume" "$LINEAR_CALLS" || true)"
if [[ "$wait_present" == "0" && "$waypoint" == "0" ]]; then
  ok "ENG-58 F: vh_rc=0 cleanup runs without operator-resume waypoint"
else
  nope "ENG-58 F: vh_rc=0 cleanup-only path" \
    "wait=$wait_present waypoint=$waypoint"
fi
_eng58_clear_side_state "ENG-985"

# ─── ENG-58 Case G: vh_rc=2 → NO cleanup, halt preserved, exit 2 ───────
: > "$LINEAR_CALLS"
_eng58_seed_side_state "ENG-986" skip-until-human-acts
exit_code=0
( LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
    VH_RC=2 STAGE_OF="stage:building" \
    resolve "ENG-986" "resume" >/dev/null 2>&1 ) || exit_code=$?
wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-986/wait-build.json" ]] && wait_present=1
halt_remove="$(grep -c "^remove-label ENG-986 pipeline:halted$" "$LINEAR_CALLS" || true)"
if [[ "$exit_code" -ne 0 && "$wait_present" == "1" && "$halt_remove" == "0" ]]; then
  ok "ENG-58 G: vh_rc=2 protocol violation preserves all state, exits non-zero"
else
  nope "ENG-58 G: vh_rc=2 protocol violation" \
    "exit=$exit_code wait=$wait_present halt_remove=$halt_remove"
fi
_eng58_clear_side_state "ENG-986"

# ─── ENG-58 Case H: scope-approved with stale side state → narrower
#                   path + advisory; no cleanup ──────────────────────────
: > "$LINEAR_CALLS"
_eng58_seed_side_state "ENG-987" skip-until-human-acts
stderr_capture="$(LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
  VH_RC=99 STAGE_OF="stage:implementing" \
  resolve "ENG-987" "scope-approved" 2>&1 >/dev/null || true)"
wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-987/wait-build.json" ]] && wait_present=1
skip_remove="$(grep -c "^remove-label ENG-987 pipeline:skip-until-" "$LINEAR_CALLS" || true)"
halt_remove="$(grep -c "^remove-label ENG-987 pipeline:halted$" "$LINEAR_CALLS" || true)"
advisory_seen=0
[[ "$stderr_capture" == *"NOTE — stale side state detected"* ]] && advisory_seen=1
if [[ "$wait_present" == "1" && "$skip_remove" == "0" && "$halt_remove" == "1" \
      && "$advisory_seen" == "1" ]]; then
  ok "ENG-58 H: scope-approved preserves side state + emits advisory"
else
  nope "ENG-58 H: scope-approved narrower path" \
    "wait=$wait_present skip_remove=$skip_remove halt_remove=$halt_remove advisory=$advisory_seen"
fi
_eng58_clear_side_state "ENG-987"

# ─── ENG-58 Case I: vh_rc=1 + policy=skip-until-code-changes →
#                   issue-state.json PRESERVED ─────────────────────────
: > "$LINEAR_CALLS"
_eng58_seed_side_state "ENG-988" skip-until-code-changes
LABELS_ON="pipeline:halted" VH_RC=1 STAGE_OF="stage:building" \
  resolve "ENG-988" "resume" >/dev/null 2>&1 || true
state_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-988/issue-state.json" ]] && state_present=1
if [[ "$state_present" == "1" ]]; then
  ok "ENG-58 I: vh_rc=1 preserves issue-state.json when policy=skip-until-code-changes"
else
  nope "ENG-58 I: D-006 policy conditional" \
    "state file removed (should have been preserved for evidence trail)"
fi
_eng58_clear_side_state "ENG-988"

# ─── ENG-58 Case J: idempotency — back-to-back resume calls succeed ──
: > "$LINEAR_CALLS"; : > "$METRICS_CALLS"
first_rc=0; second_rc=0
( LABELS_ON="pipeline:halted" VH_RC=1 STAGE_OF="stage:building" \
    resolve "ENG-989" "resume" >/dev/null 2>&1 ) || first_rc=$?
( LABELS_ON="pipeline:halted" VH_RC=1 STAGE_OF="stage:building" \
    resolve "ENG-989" "resume" >/dev/null 2>&1 ) || second_rc=$?
metric_count="$(grep -c "^halt-resume ENG-989 building atomic-reset" "$METRICS_CALLS" || true)"
if [[ "$first_rc" == 0 && "$second_rc" == 0 && "$metric_count" -ge "2" ]]; then
  ok "ENG-58 J: back-to-back resume calls are idempotent"
else
  nope "ENG-58 J: idempotency" "rc1=$first_rc rc2=$second_rc metrics=$metric_count"
fi
_eng58_clear_side_state "ENG-989"

# ─── ENG-58 Case K (regression): operator-resume waypoint resets the
#     count_marker_since_last_transition boundary ────────────────────
: > "$LINEAR_CALLS"
LABELS_ON="pipeline:halted" VH_RC=1 STAGE_OF="stage:building" \
  resolve "ENG-990" "resume" >/dev/null 2>&1 || true
contains_transition="$(grep -c "<!-- pipeline-transition: building → building (operator-resume) -->" "$LINEAR_CALLS" || true)"
if [[ "$contains_transition" -ge "1" ]]; then
  ok "ENG-58 K: operator-resume waypoint matches contains() boundary used by guards/find_fresh_verdict"
else
  nope "ENG-58 K: ENG-24 regression — waypoint shape" \
    "no comment with pipeline-transition: building → building (operator-resume) found in LINEAR_CALLS"
fi
_eng58_clear_side_state "ENG-990"

# ─── ENG-58 Case L (D-011): chained scope-approved → resume on an
#     issue with NO halt label does NOT call verdict_handler ──────────
: > "$LINEAR_CALLS"
_eng58_seed_side_state "ENG-991" skip-until-human-acts
exit_code=0
( LABELS_ON="pipeline:skip-until-human-acts" \
    VH_RC=2 STAGE_OF="stage:building" \
    resolve "ENG-991" "resume" >/dev/null 2>&1 ) || exit_code=$?
wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-991/wait-build.json" ]] && wait_present=1
skip_remove="$(grep -c "^remove-label ENG-991 pipeline:skip-until-human-acts$" "$LINEAR_CALLS" || true)"
halt_remove="$(grep -c "^remove-label ENG-991 pipeline:halted$" "$LINEAR_CALLS" || true)"
if [[ "$exit_code" == 0 && "$wait_present" == "0" \
      && "$skip_remove" == "1" && "$halt_remove" == "0" ]]; then
  ok "ENG-58 L (D-011): bypass verdict_handler when pipeline:halted absent"
else
  nope "ENG-58 L (D-011): chained scope-approved → resume bypass" \
    "exit=$exit_code wait=$wait_present skip_remove=$skip_remove halt_remove=$halt_remove"
fi
_eng58_clear_side_state "ENG-991"

# ─── ENG-58 Case M (D-012): scope-approved + wait-build.json →
#     stderr advisory mentions wait-*.json ──────────────────────────
: > "$LINEAR_CALLS"
mkdir -p "$PROJECT_STATE_DIR/ENG-992"
printf '{}' > "$PROJECT_STATE_DIR/ENG-992/wait-build.json"
stderr_capture="$(LABELS_ON="pipeline:halted" VH_RC=99 STAGE_OF="stage:building" \
  resolve "ENG-992" "scope-approved" 2>&1 >/dev/null || true)"
wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-992/wait-build.json" ]] && wait_present=1
if [[ "$wait_present" == "1" && "$stderr_capture" == *"wait-*.json"* ]]; then
  ok "ENG-58 M (D-012): scope-approved advisory mentions wait-*.json without clearing"
else
  nope "ENG-58 M (D-012): scope-approved advisory" \
    "wait=$wait_present advisory='$stderr_capture'"
fi
_eng58_clear_side_state "ENG-992"

# ─── ENG-58 Case N (D-013): metrics.sh halt-resume captures stats ──
: > "$LINEAR_CALLS"; : > "$METRICS_CALLS"
_eng58_seed_side_state "ENG-993" skip-until-human-acts
LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
  VH_RC=1 STAGE_OF="stage:building" \
  resolve "ENG-993" "resume" >/dev/null 2>&1 || true
metric_line="$(grep "^halt-resume ENG-993 building atomic-reset 0 " "$METRICS_CALLS" | head -1)"
if [[ "$metric_line" == *"wait_files=1"* \
      && "$metric_line" == *"skip_labels=1"* \
      && "$metric_line" == *"state_file=true"* \
      && "$metric_line" == *"waypoint_posted=1"* ]]; then
  ok "ENG-58 N (D-013): metrics.sh halt-resume captures full stats"
else
  nope "ENG-58 N (D-013): metrics emission" "line='$metric_line'"
fi
_eng58_clear_side_state "ENG-993"

# ─── ENG-58 Case O (D-014): invalid issue id → die before any FS or
#     Linear write ────────────────────────────────────────────────
: > "$LINEAR_CALLS"
exit_code=0
( resolve "ENG-../../etc" "resume" >/dev/null 2>&1 ) || exit_code=$?
remove_count="$(grep -c "^remove-label" "$LINEAR_CALLS" || true)"
if [[ "$exit_code" -ne 0 && "$remove_count" == "0" ]]; then
  ok "ENG-58 O (D-014): path-traversal issue id rejected before any write"
else
  nope "ENG-58 O (D-014): issue-id validation" \
    "exit=$exit_code remove_count=$remove_count"
fi

# ─── ENG-58 Case P (D-014): malformed stage label → sanitized to
#     'unknown' in operator-resume body ────────────────────────────
: > "$LINEAR_CALLS"
LABELS_ON="pipeline:halted" VH_RC=1 STAGE_OF="stage:foo%s" \
  resolve "ENG-994" "resume" >/dev/null 2>&1 || true
sanitized="$(grep -c "<!-- pipeline-transition: unknown → unknown (operator-resume) -->" "$LINEAR_CALLS" || true)"
if [[ "$sanitized" -ge "1" ]]; then
  ok "ENG-58 P (D-014): stage-shape sanitized to 'unknown' on malformed label"
else
  nope "ENG-58 P (D-014): stage sanitization" \
    "no operator-resume waypoint with 'unknown → unknown' found"
fi
_eng58_clear_side_state "ENG-994"

# ─── ENG-58 Case Q (corrupt JSON guard): issue-state.json with
#     invalid JSON is PRESERVED (jq -e . guard short-circuits) ────
: > "$LINEAR_CALLS"
mkdir -p "$PROJECT_STATE_DIR/ENG-995"
printf 'this is not valid json\n' > "$PROJECT_STATE_DIR/ENG-995/issue-state.json"
LABELS_ON="pipeline:halted" VH_RC=1 STAGE_OF="stage:building" \
  resolve "ENG-995" "resume" >/dev/null 2>&1 || true
state_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-995/issue-state.json" ]] && state_present=1
if [[ "$state_present" == "1" ]]; then
  ok "ENG-58 Q (corrupt JSON): issue-state.json preserved when jq -e . fails"
else
  nope "ENG-58 Q: corrupt-JSON guard" \
    "state file removed despite invalid JSON (operator loses investigation evidence)"
fi
_eng58_clear_side_state "ENG-995"

# ─── ENG-58 Case R (PIPELINE_DRY_RUN): dry-run still removes local
#     filesystem state but suppresses Linear writes ──────────────
: > "$LINEAR_CALLS"; : > "$METRICS_CALLS"
_eng58_seed_side_state "ENG-996" skip-until-human-acts
LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
  VH_RC=1 STAGE_OF="stage:building" PIPELINE_DRY_RUN=1 \
  resolve "ENG-996" "resume" >/dev/null 2>&1 || true
wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-996/wait-build.json" ]] && wait_present=1
state_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-996/issue-state.json" ]] && state_present=1
if [[ "$wait_present" == "0" && "$state_present" == "0" ]]; then
  ok "ENG-58 R (dry-run): local FS cleanup runs under PIPELINE_DRY_RUN=1"
else
  nope "ENG-58 R: dry-run FS contract" \
    "wait=$wait_present state=$state_present (expected both 0; brainstorm §6 says FS ops execute even in dry-run)"
fi
_eng58_clear_side_state "ENG-996"

printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
