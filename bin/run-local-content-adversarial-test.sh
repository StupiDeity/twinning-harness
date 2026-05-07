#!/usr/bin/env bash
# QA-authored adversarial coverage for ENG-67 (sibling to
# run-local-content-test.sh). The plan's Failure Mode → Test Map binds
# four content-pins to the deletion-site (legacy `feature/*` coexistence)
# and the soft-fallback removal. This file pins regression classes the
# four base pins do NOT catch:
#
#   AD-1 die-presence:        someone deletes the `die` guard but leaves
#                             `dispatch_cwd="$worktree_path"`. Empty
#                             worktree_path → silent-empty dispatch
#                             (effectively `cd ""`, dispatch into $PWD,
#                             which can be $TARGET_REPO). Base pin 4
#                             only matches the literal
#                             `dispatch_cwd="$TARGET_REPO"` LHS.
#
#   AD-2 die-message-shape:   CLAUDE.md "Per-issue state directory" §
#                             quotes the die message verbatim as the
#                             operator-recognition contract. If either
#                             side rewords, operators grepping logs by
#                             the runbook quote get a silent miss.
#                             Bidirectional substring pin between
#                             bin/run-local.sh and CLAUDE.md.
#
#   AD-3 broader-fallback:    base pin 4 only matches the literal
#                             `dispatch_cwd="$TARGET_REPO"` LHS. Trip
#                             the broader class — any executable line
#                             where `dispatch_cwd=` is followed by a
#                             reference to the `TARGET_REPO` variable
#                             (braced, unquoted, etc.) is also a soft
#                             fallback. The existing canonical
#                             `dispatch_cwd="$worktree_path"` does NOT
#                             match.
#
#   AD-4 init-presence:       run-local.sh runs under `set -euo pipefail`.
#                             The `[[ -n "$worktree_path" ]]` die guard
#                             requires worktree_path to be SET (not
#                             merely empty). If a future edit drops the
#                             `worktree_path=""` initialization, the die
#                             never fires — bash errors at the `[[ -n ]]`
#                             check with "unbound variable" instead,
#                             producing a different exit code and log
#                             shape than the operator-recognition
#                             contract documents. Pin the initializer.
#
# Operates on bin/run-local.sh + CLAUDE.md as text (awk + grep). Does
# NOT source run-local.sh (no sentinel — sourcing would fire main).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_LOCAL="$SCRIPT_DIR/run-local.sh"
CLAUDE_MD="$SCRIPT_DIR/../CLAUDE.md"
[[ -f "$RUN_LOCAL" ]] || { printf 'FAIL: missing %s\n' "$RUN_LOCAL" >&2; exit 1; }
[[ -f "$CLAUDE_MD" ]] || { printf 'FAIL: missing %s\n' "$CLAUDE_MD" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS + 1)); }
nope() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

# Strip comment lines (lines whose first non-blank char is `#`) and
# blank lines before scanning. The same convention as
# run-local-content-test.sh — citations in prose are documentation,
# not code.
non_comment="$(awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/' "$RUN_LOCAL")"

# AD-1: die guard for the unreachable-by-construction worktree_path
# emptiness must be present. Pin the canonical substring of the die
# message (per ENG-67 D-003) — not the whole line, so future
# whitespace/wording tweaks within the same contract don't trip the
# pin, but a deletion does.
if printf '%s\n' "$non_comment" | grep -qF 'worktree_path empty after reconcile=proceed (ENG-67)'; then
  ok 'D-003 die guard present (worktree_path empty contract)'
else
  nope 'D-003 die guard present' \
    'die-on-empty guard appears to have been deleted; silent-empty dispatch returns; see ENG-67 D-003'
fi

# AD-2: the die message in run-local.sh and the CLAUDE.md operator-
# recognition string must agree on the canonical phrase. CLAUDE.md
# "Per-issue state directory" § quotes it verbatim as the runbook for
# operators grepping logs. Two substring checks (rather than one
# whole-phrase) because CLAUDE.md word-wraps the phrase across line
# 221/222 — a single `grep -F` of the full phrase would silently miss.
ad2_left='worktree_path empty after'
ad2_right='reconcile=proceed (ENG-67); refusing to dispatch from'
if   grep -qF -- "$ad2_left"  "$RUN_LOCAL" \
  && grep -qF -- "$ad2_right" "$RUN_LOCAL" \
  && grep -qF -- "$ad2_left"  "$CLAUDE_MD" \
  && grep -qF -- "$ad2_right" "$CLAUDE_MD"; then
  ok 'die message and CLAUDE.md operator-recognition string agree (ENG-67 D-004)'
else
  nope 'die message ⇄ CLAUDE.md operator-recognition substring' \
    'one side rewords the canonical phrase; operator grep-by-runbook silently misses; see ENG-67 D-004'
fi

# AD-3: broader form of base pin 4. Any executable line where the
# dispatch_cwd LHS is assigned from anything referencing TARGET_REPO is
# the soft-fallback class — including `${TARGET_REPO}`, unquoted
# `$TARGET_REPO`, `"${TARGET_REPO}/sub"`, etc. The current canonical
# `dispatch_cwd="$worktree_path"` does NOT mention TARGET_REPO.
if printf '%s\n' "$non_comment" | grep -qE '^[[:space:]]*dispatch_cwd=.*TARGET_REPO'; then
  nope 'dispatch_cwd= never assigned from TARGET_REPO (broader form)' \
    'soft fallback (any TARGET_REPO-derived shape) re-introduced; see ENG-67 D-003'
else
  ok 'dispatch_cwd= assignment never references TARGET_REPO'
fi

# AD-4: initializer for worktree_path. run-local.sh runs under
# `set -u`. If a future edit drops `worktree_path=""` (line 223 in the
# post-ENG-67 layout), the `[[ -n "$worktree_path" ]]` guard errors
# with "unbound variable" before the die can fire — different exit
# code, different log line, breaks the D-004 operator-recognition
# contract.
if printf '%s\n' "$non_comment" | grep -qE '^[[:space:]]*worktree_path=""'; then
  ok 'worktree_path="" initializer present (set -u safety)'
else
  nope 'worktree_path="" initializer present' \
    'D-003 guard now errors as unbound-variable instead of dying with the operator-recognition message; see ENG-67 D-003/D-004'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
