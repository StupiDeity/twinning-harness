#!/usr/bin/env bash
# Unit tests for bin/setup.sh phases. Mocks Linear via LINEAR_API_KEY=test-mock-key
# and intercepts curl. Mocks gh-app-token.sh and dry-run.sh via PATH stubs.

set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY=test-mock-key

PASS=0; FAIL=0
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
fail_at() { printf '  ❌ %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Each test uses a fresh tmptarget + fresh shared dirs.
fresh_target() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  mkdir -p "$d/.pipeline-config/schemas"
  printf '{}\n' > "$d/.pipeline-config/config.json"
  printf '%s' "$d"
}

# ── workspace phase: scaffolds dirs ────────────────────────────────────
{
  TGT="$(fresh_target)"
  HARNESS_STATE_DIR="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
    bash "$HARNESS_DIR/setup.sh" "$TGT" workspace >/dev/null 2>&1 \
    && [[ -d "$TGT/.pipeline-config/schemas" ]] \
    && pass_at "workspace creates .pipeline-config/schemas" \
    || fail_at "workspace creates .pipeline-config/schemas" "missing"
}

# ── slug-freeze: derives slug + sentinel ───────────────────────────────
{
  TGT="$(fresh_target)"
  printf '{"linear":{"team_id":"t","project_id":"p"}}\n' > "$TGT/.pipeline-config/config.json"
  printf '{"project":{"name":"My Cool Project"}}\n' > "$TGT/.pipeline-config/schemas/linear-ids.json"
  HSD="$(mktemp -d)"
  HARNESS_STATE_DIR="$HSD" XDG_CONFIG_HOME="$(mktemp -d)" \
    bash "$HARNESS_DIR/setup.sh" "$TGT" slug-freeze >/dev/null 2>&1 \
    && [[ "$(jq -r .project.slug "$TGT/.pipeline-config/config.json")" == "my-cool-project" ]] \
    && [[ -f "$HSD/my-cool-project/target-repo" ]] \
    && pass_at "slug-freeze derives 'my-cool-project' and writes sentinel" \
    || fail_at "slug-freeze" "slug or sentinel missing"
}

# ── slug-freeze: collision with another target ─────────────────────────
{
  HSD="$(mktemp -d)"
  TGT1="$(fresh_target)"; TGT2="$(fresh_target)"
  for t in "$TGT1" "$TGT2"; do
    printf '{"linear":{"team_id":"t","project_id":"p"}}\n' > "$t/.pipeline-config/config.json"
    printf '{"project":{"name":"shared-name"}}\n' > "$t/.pipeline-config/schemas/linear-ids.json"
  done
  HARNESS_STATE_DIR="$HSD" XDG_CONFIG_HOME="$(mktemp -d)" \
    bash "$HARNESS_DIR/setup.sh" "$TGT1" slug-freeze >/dev/null 2>&1
  out="$(HARNESS_STATE_DIR="$HSD" XDG_CONFIG_HOME="$(mktemp -d)" \
    bash "$HARNESS_DIR/setup.sh" "$TGT2" slug-freeze 2>&1 || true)"
  grep -q 'already in use' <<<"$out" \
    && pass_at "slug-freeze refuses collision" \
    || fail_at "slug-freeze refuses collision" "$out"
}

# ── config-defaults: fills missing keys, preserves edits ──────────────
{
  TGT="$(fresh_target)"
  printf '{"linear":{"team_id":"t","project_id":"p","stage_label_prefix":"custom:"}}\n' \
    > "$TGT/.pipeline-config/config.json"
  HARNESS_STATE_DIR="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
    bash "$HARNESS_DIR/setup.sh" "$TGT" config-defaults >/dev/null 2>&1
  prefix="$(jq -r .linear.stage_label_prefix "$TGT/.pipeline-config/config.json")"
  paused="$(jq -r .orchestrator.paused "$TGT/.pipeline-config/config.json")"
  [[ "$prefix" == 'custom:' && "$paused" == 'false' ]] \
    && pass_at "config-defaults preserves edits, fills missing" \
    || fail_at "config-defaults" "prefix=$prefix paused=$paused"
}

printf '\n  passed: %d\n  failed: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
