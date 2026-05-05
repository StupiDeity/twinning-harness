#!/usr/bin/env bash
# Point this clone's git hooks at the tracked .githooks/ directory.
# Idempotent — safe to re-run. No-op if core.hooksPath is already set
# to .githooks.
#
# Why a tracked hooks dir (and not .git/hooks/): hooks under .git/ are
# untracked, so each clone would need a separate copy. core.hooksPath
# (git ≥ 2.9) lets the repo ship its own hook implementations and have
# them version-controlled; the only per-clone state is this single
# config setting, which this script applies.
#
# Run from anywhere inside the repo.

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

[[ -d .githooks ]] || { printf 'install-git-hooks: .githooks/ not found at %s\n' "$REPO_ROOT" >&2; exit 1; }

# Ensure every committed hook is executable on this clone (git preserves
# the +x bit, but a fresh clone via some tools/file-systems can lose it).
chmod +x .githooks/* 2>/dev/null || true

target="$REPO_ROOT/.githooks"
current="$(git config --get core.hooksPath || true)"
if [[ "$current" == "$target" ]]; then
  printf 'install-git-hooks: core.hooksPath already set to %s (no-op)\n' "$target"
  exit 0
fi

# ABSOLUTE path so every linked worktree uses the same hook regardless of
# the feature branch's tip (the alternative — relative `.githooks` —
# resolves per-worktree against each working tree, so a feature branch
# that pre-dates the latest hook hardening would still execute the OLD
# hook on commits triggered from inside its linked worktree, e.g. by
# pipeline.sh decide --action continue's auto_commit_in_scope).
git config core.hooksPath "$target"
printf 'install-git-hooks: core.hooksPath -> %s\n' "$target"
printf '  installed hooks:\n'
for h in .githooks/*; do
  [[ -f "$h" && -x "$h" ]] && printf '    %s\n' "$h"
done
printf '\nBypass a single commit: git commit --no-verify\n'
printf 'Uninstall:               git config --unset core.hooksPath\n'
