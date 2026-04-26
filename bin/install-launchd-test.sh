#!/usr/bin/env bash
# Verifies install-launchd.sh substitutions and surgical bootout. Does NOT
# touch the user's actual launchctl domain — overrides DOMAIN to a no-op
# inline by stubbing launchctl on PATH.

set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export PROJECT_SLUG=foo

STUB="$(mktemp -d)"
LAUNCHCTL_LOG="$STUB/launchctl.log"
cat > "$STUB/launchctl" <<'SH'
#!/usr/bin/env bash
echo "$@" >> "$LAUNCHCTL_LOG"
case "$1" in
  print) exit 1 ;;     # pretend nothing is loaded (skip bootout branch)
  bootstrap|bootout|kickstart) exit 0 ;;
  list) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB/launchctl"
export PATH="$STUB:$PATH"
export LAUNCHCTL_LOG

TGT="$(mktemp -d)"
git -C "$TGT" init -q
mkdir -p "$TGT/.pipeline-config/schemas"
printf '{"linear":{"team_id":"t","project_id":"p"},"project":{"slug":"foo"}}\n' \
  > "$TGT/.pipeline-config/config.json"
HSD="$(mktemp -d)"
fake_la="$(mktemp -d)"
HOME_BACKUP="$HOME"
export HOME="$fake_la/home"
mkdir -p "$HOME/Library/LaunchAgents"

trap 'rm -rf "$STUB" "$TGT" "$HSD" "$fake_la"; export HOME="$HOME_BACKUP"' EXIT

HARNESS_STATE_DIR="$HSD" bash "$HARNESS_DIR/install-launchd.sh" "$TGT" >/dev/null 2>&1

PASS=0; FAIL=0
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
fail_at() { printf '  ❌ %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

[[ -f "$HOME/Library/LaunchAgents/com.twinning.pipeline.foo.plist" ]] \
  && pass_at "pipeline plist rendered with slug 'foo'" \
  || fail_at "pipeline plist rendered" "missing"

[[ -f "$HOME/Library/LaunchAgents/com.twinning.retrospective.foo.plist" ]] \
  && pass_at "retrospective plist rendered with slug 'foo'" \
  || fail_at "retrospective plist rendered" "missing"

grep -q 'com.twinning.pipeline.foo' "$HOME/Library/LaunchAgents/com.twinning.pipeline.foo.plist" \
  && pass_at "Label substitution correct" \
  || fail_at "Label substitution" "missing in plist body"

grep -q "$HSD/foo/logs/launchd.out.log" "$HOME/Library/LaunchAgents/com.twinning.pipeline.foo.plist" \
  && pass_at "log path slug-aware" \
  || fail_at "log path" "missing /foo/logs/"

grep -q 'PROJECT_SLUG' "$HOME/Library/LaunchAgents/com.twinning.pipeline.foo.plist" \
  && pass_at "PROJECT_SLUG env var present" \
  || fail_at "PROJECT_SLUG env var" "missing"

# Sibling slug isolation: install a second slug, then uninstall foo, sibling
# plist must remain.
TGT2="$(mktemp -d)"; git -C "$TGT2" init -q
mkdir -p "$TGT2/.pipeline-config/schemas"
printf '{"linear":{"team_id":"t","project_id":"p2"},"project":{"slug":"bar"}}\n' \
  > "$TGT2/.pipeline-config/config.json"
PROJECT_SLUG=bar HARNESS_STATE_DIR="$HSD" \
  bash "$HARNESS_DIR/install-launchd.sh" "$TGT2" >/dev/null 2>&1

bash "$HARNESS_DIR/uninstall-launchd.sh" "$TGT" >/dev/null 2>&1
[[ ! -f "$HOME/Library/LaunchAgents/com.twinning.pipeline.foo.plist" \
   && -f "$HOME/Library/LaunchAgents/com.twinning.pipeline.bar.plist" ]] \
  && pass_at "uninstall surgical: foo gone, bar intact" \
  || fail_at "uninstall surgical" "wrong files removed"

printf '\n  passed: %d\n  failed: %d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
