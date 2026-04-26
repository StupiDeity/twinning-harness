---
linear: ENG-TBD
title: Multi-project harness — implementation plan
date: 2026-04-26
spec: docs/brainstorms/2026-04-26-multi-project-harness.md
status: draft
---

# Multi-Project Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a single harness installation drive N independent target repos
concurrently, with per-project launchd services, slug-namespaced state, a
single onboarding entry point (`bin/setup.sh`), per-slug learned rules, and a
cross-project mutex around `claude -p`.

**Architecture:** Project identity is a Linear-derived `project.slug` (frozen
in the target's `config.json`) that namespaces all per-project state under
`$HARNESS_STATE_DIR/<slug>/`. Each project gets its own `com.twinning.pipeline.<slug>`
+ `com.twinning.retrospective.<slug>` launchd pair. Shared user secrets live
once at `${XDG_CONFIG_HOME}/twinning-harness/`. A new `bin/setup.sh` walks all
onboarding phases idempotently and bundles the legacy-install migration into
`setup.sh /path migrate`.

**Tech Stack:** bash 3.2+ (macOS default), `jq`, `curl`, `launchctl`, `gh`
CLI, Linear GraphQL API, GitHub App tokens, mkdir-based file locks.

---

## Pre-flight

Before starting Task 1, confirm a green baseline. Run from the harness repo
root with `TARGET_REPO` pointing at the existing target repo:

```bash
TARGET_REPO=/path/to/twinning bash bin/dry-run.sh
for t in bin/*-test.sh; do echo "== $t =="; bash "$t" || break; done
```

Expected: `dry-run.sh` reports zero failures; every `*-test.sh` exits 0. If
anything is red, fix it before proceeding — this plan adds tests on top of
existing ones.

## File structure

| File | Action | Responsibility |
|---|---|---|
| `bin/common.sh` | Modify | Add `HARNESS_CONFIG_DIR`, `PROJECT_SLUG`, `PROJECT_STATE_DIR` exports. Bootstrap-bypass via `TWINNING_BOOTSTRAPPING=1`. Add `acquire_lock`/`release_lock` helpers. |
| `bin/setup-helpers.sh` | Create | Shared utilities for `setup.sh` and tests: `slugify_project_name`, `atomic_write_file`, `read_env_file`, `write_env_file`, `prompt_secret`, `print_phase_header`. |
| `bin/setup.sh` | Create | Onboarding entry. CLI dispatch + 11 phases + `migrate` umbrella. |
| `bin/setup-test.sh` | Create | Unit tests for `setup.sh` phases (mocked Linear/GitHub). |
| `bin/install-launchd.sh` | Modify | Take target repo path arg; render slug-suffixed plists; surgical bootout of only the slug's labels. |
| `bin/uninstall-launchd.sh` | Modify | Accept `<path>` or `--slug <slug>`; surgical bootout. |
| `bin/install-launchd-test.sh` | Create | Tests for slug substitution + non-interference with sibling slugs. |
| `launchd/com.twinning.pipeline.plist.template` | Modify | Add `__PROJECT_SLUG__`; slug-suffixed `Label`; per-project log paths. |
| `launchd/com.twinning.retrospective.plist.template` | Modify | Same as above. |
| `bin/run-local.sh` | Modify | Source `secrets.env` then `.env.local`; switch all `$HARNESS_STATE_DIR/*` per-project paths to `$PROJECT_STATE_DIR/*`. |
| `bin/dispatch.sh` | Modify | Wrap `claude -p` invocation in cross-project mutex on `$HARNESS_STATE_DIR/.claude-mutex.lock/`. |
| `bin/mutex-test.sh` | Create | Two concurrent `dispatch.sh` calls serialize. |
| `bin/render-prompt.sh` | Modify | Add `{learned_rules_dir}` token in both python and sed substitution branches. |
| `bin/render-prompt-slug-test.sh` | Create | Verify `{learned_rules_dir}` resolves to `$HARNESS_ROOT/learned-rules/<slug>/`. |
| `AGENT_PROMPTS.md` | Modify | Replace literal `.pipeline/learned-rules/<stage>.md` with `{learned_rules_dir}/<stage>.md` (~12 occurrences). |
| `bin/poll.sh`, `metrics.sh`, `run-stage.sh`, `run-release-observer.sh`, `run-retrospective-local.sh`, `reset-pipeline.sh`, `status.sh`, `halt-sprawl-test.sh`, `halt-sprawl-adversarial-test.sh` | Modify | Mechanical sweep: replace `$HARNESS_STATE_DIR/{metrics,logs,.consecutive-failures,.tick-counter,.run-local.lock,.halt-sprawl-last-alerted,last-observed-release,<issue>}` with `$PROJECT_STATE_DIR/...`. Existing tests get a one-line fixture export. |
| `README.md` | Modify | Document `setup.sh` flow, multi-project layout, migration. |
| `CLAUDE.md` | Modify | Add `PROJECT_SLUG`/`PROJECT_STATE_DIR` to the variable table; update state-dir layout diagram; document the `claude -p` mutex and per-slug learned rules. |

## Conventions used by every task

- **Commit prefix.** Use `feat(ENG-XX): ...` / `fix(ENG-XX): ...` / `refactor(ENG-XX): ...`
  matching the repo's existing style. Replace `ENG-XX` with the real Linear
  issue identifier once created (the spec frontmatter currently reads
  `linear: ENG-TBD`).
- **Branch.** Work on `feat/eng-XX-multi-project-harness` (or whatever the
  Linear issue's slug is) so the harness's reconcile/scope-check sees a
  consistent feature branch across all tasks.
- **Test pattern.** Each new `*-test.sh` follows the existing convention:
  set `PIPELINE_DRY_RUN=1`, mock external scripts via `STUB_DIR`, source the
  script under test (the sentinel at the bottom prevents `main` from firing),
  override globals after sourcing, run inline assertions with `pass_at`/`fail_at`,
  exit non-zero if any failed. See `bin/reconcile-test.sh:1-66` as the
  canonical template.
- **No `git add -A` and no `--no-verify`.** Stage only the files each task
  touched.

---

## Task 1: Foundation — `common.sh` slug-aware path derivations and lock helpers

**Files:**
- Modify: `bin/common.sh`

- [ ] **Step 1: Add a sourced-with-no-slug failure assertion to a smoke test**

Append to a temporary scratch file `/tmp/common-bootstrap-smoke.sh`:

```bash
#!/usr/bin/env bash
set -e
export TARGET_REPO="$(mktemp -d)"
mkdir -p "$TARGET_REPO/.pipeline-config/schemas"
printf '{"linear":{"team_id":"t","project_id":"p"}}\n' > "$TARGET_REPO/.pipeline-config/config.json"
# No project.slug -> common.sh must die.
out="$(bash -c "source bin/common.sh" 2>&1 || true)"
grep -q 'project.slug missing' <<<"$out" || { echo "FAIL: expected die message; got: $out"; exit 1; }

# With bootstrapping flag -> must succeed and leave PROJECT_SLUG empty.
out="$(TWINNING_BOOTSTRAPPING=1 bash -c "source bin/common.sh && printf 'slug=[%s] state=[%s]\n' \"\$PROJECT_SLUG\" \"\$PROJECT_STATE_DIR\"" 2>&1)"
grep -q 'slug=\[\] state=\[\]' <<<"$out" || { echo "FAIL: bootstrapping path; got: $out"; exit 1; }

# Pre-set PROJECT_SLUG -> common.sh respects it.
out="$(PROJECT_SLUG=test-slug bash -c "source bin/common.sh && printf 'slug=[%s]\n' \"\$PROJECT_SLUG\"" 2>&1)"
grep -q 'slug=\[test-slug\]' <<<"$out" || { echo "FAIL: pre-set respected; got: $out"; exit 1; }

# Populated config.json -> common.sh derives PROJECT_STATE_DIR.
jq '.project.slug="my-slug"' "$TARGET_REPO/.pipeline-config/config.json" > /tmp/c && mv /tmp/c "$TARGET_REPO/.pipeline-config/config.json"
out="$(bash -c "source bin/common.sh && printf 'state=[%s]\n' \"\$PROJECT_STATE_DIR\"" 2>&1)"
grep -q "state=\[$HARNESS_STATE_DIR/my-slug\]" <<<"$out" || \
  grep -qE 'state=\[.*/my-slug\]' <<<"$out" || { echo "FAIL: state derived; got: $out"; exit 1; }

echo OK
```

- [ ] **Step 2: Run the smoke test and verify it fails**

Run: `bash /tmp/common-bootstrap-smoke.sh`
Expected: FAIL — current common.sh has no `project.slug` check, no bootstrap
flag, no `PROJECT_SLUG`/`PROJECT_STATE_DIR` exports.

- [ ] **Step 3: Edit `bin/common.sh`**

After the existing `export HARNESS_ROOT TARGET_REPO HARNESS_STATE_DIR ...`
line (line 19), insert:

```bash
HARNESS_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/twinning-harness"

# Project slug resolution. Three modes:
#   1. Caller pre-set $PROJECT_SLUG (test fixtures, setup.sh's slug-freeze
#      phase) — respect it.
#   2. TWINNING_BOOTSTRAPPING=1 — soft-empty (setup.sh phases that run before
#      slug-freeze).
#   3. Otherwise — read from config.json::project.slug; die loudly if absent.
if [[ -z "${PROJECT_SLUG:-}" ]]; then
  if [[ -n "${TWINNING_BOOTSTRAPPING:-}" ]]; then
    PROJECT_SLUG=""
  else
    PROJECT_SLUG="$(jq -r '.project.slug // empty' "$CONFIG" 2>/dev/null || true)"
    [[ -n "$PROJECT_SLUG" ]] || die "config.json::project.slug missing — run bin/setup.sh /path/to/target first"
  fi
fi
PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-${HARNESS_STATE_DIR}${PROJECT_SLUG:+/$PROJECT_SLUG}}"

export HARNESS_CONFIG_DIR PROJECT_SLUG PROJECT_STATE_DIR
```

Also add a lock-helper block after the `export -f issue_dir compute_pipeline_content_hash ...` line (the existing exports of helper functions):

```bash
# ─── Lock helpers (mkdir-based; atomic on POSIX) ─────────────────────
# Used by run-local.sh (per-project tick lock) and dispatch.sh (cross-
# project claude mutex). mkdir is atomic across processes; rmdir is
# safe even if multiple holders lose the race to release.
acquire_lock() {
  local dir="$1" timeout="${2:-0}" waited=0
  while ! mkdir "$dir" 2>/dev/null; do
    (( timeout > 0 && waited >= timeout )) && return 1
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

release_lock() {
  local dir="$1"
  rmdir "$dir" 2>/dev/null || true
}

export -f acquire_lock release_lock
```

- [ ] **Step 4: Run the smoke test and verify it passes**

Run: `bash /tmp/common-bootstrap-smoke.sh`
Expected: `OK`

- [ ] **Step 5: Run all existing tests to confirm no regression**

Run:
```bash
TARGET_REPO=/path/to/twinning bash bin/dry-run.sh
for t in bin/*-test.sh; do bash "$t" || { echo "FAIL: $t"; break; }; done
```

Several existing tests will fail with "config.json::project.slug missing"
because their fixtures don't set `project.slug`. **This is expected** and
will be fixed in Task 15. For now confirm the failure mode is the new die
message (not anything else).

- [ ] **Step 6: Commit**

```bash
git add bin/common.sh
git commit -m "feat(ENG-XX): common.sh derives PROJECT_SLUG and PROJECT_STATE_DIR

Adds slug-aware path namespacing primitives required by every other
multi-project change. TWINNING_BOOTSTRAPPING=1 lets setup.sh's pre-
slug-freeze phases source common.sh without dying. Lock helpers
extracted for reuse by run-local.sh tick lock and dispatch.sh
claude mutex."
rm /tmp/common-bootstrap-smoke.sh
```

---

## Task 2: `bin/setup-helpers.sh` — slugifier + shared utilities

**Files:**
- Create: `bin/setup-helpers.sh`
- Test: inline at the bottom of the file (sourced by `setup-test.sh` later)

- [ ] **Step 1: Write `bin/setup-helpers.sh`**

```bash
#!/usr/bin/env bash
# Helpers shared by bin/setup.sh and bin/setup-test.sh.
# Source-only; no main.

set -euo pipefail

# slugify_project_name <linear-project-name>
# Lowercase, replace non-[a-z0-9-] with '-', collapse repeats, trim, validate.
# Emits the slug on stdout. Exits non-zero with an error if the result fails
# validation; caller decides whether to die or prompt for an override.
slugify_project_name() {
  local raw="$1" slug
  slug="$(printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
  if [[ ! "$slug" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ ]]; then
    printf 'slugify_project_name: %s -> %s does not match ^[a-z][a-z0-9-]{1,38}[a-z0-9]$\n' \
      "$raw" "$slug" >&2
    return 1
  fi
  printf '%s' "$slug"
}

# atomic_write_file <path> <mode>
# Reads stdin into a tempfile in the same directory, chmods, then renames.
# Avoids partial-write hazards on $HOME files.
atomic_write_file() {
  local path="$1" mode="${2:-0644}"
  [[ -n "$path" ]] || { printf 'atomic_write_file: path required\n' >&2; return 1; }
  local dir; dir="$(dirname "$path")"
  mkdir -p "$dir"
  local tmp; tmp="$(mktemp "$dir/.atomic.XXXXXX")"
  cat > "$tmp"
  chmod "$mode" "$tmp"
  mv "$tmp" "$path"
}

# read_env_file <path> <var-name> [<var-name>...]
# Echoes `<var>=<value>` lines for each requested var if present in the env file.
# Lines that are blank or start with `#` are ignored. Quoting matches bash:
# `KEY="value with spaces"` and `KEY=plain` both work.
read_env_file() {
  local path="$1"; shift
  [[ -f "$path" ]] || return 0
  local var
  for var in "$@"; do
    awk -v v="$var" '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      {
        line = $0
        sub(/^[[:space:]]*/, "", line)
        idx = index(line, "=")
        if (idx == 0) next
        key = substr(line, 1, idx - 1)
        if (key != v) next
        val = substr(line, idx + 1)
        # strip a single matching pair of surrounding double quotes
        if (val ~ /^".*"$/) val = substr(val, 2, length(val) - 2)
        print key "=" val
      }
    ' "$path"
  done
}

# write_env_file <path> <mode> <KEY=VALUE>...
# Idempotent upsert: replaces existing KEY= lines in place, appends new ones.
# Re-quotes values that contain whitespace or shell metacharacters.
write_env_file() {
  local path="$1" mode="$2"; shift 2
  mkdir -p "$(dirname "$path")"
  [[ -f "$path" ]] || : > "$path"
  local pair key value tmp
  tmp="$(mktemp)"
  cp "$path" "$tmp"
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    # Quote if needed.
    if [[ "$value" =~ [[:space:]\"\'\$\`\\] ]]; then
      value="\"${value//\"/\\\"}\""
    fi
    if grep -qE "^[[:space:]]*${key}=" "$tmp"; then
      # macOS sed in-place needs '' after -i; keep portable form.
      sed -i.bak -E "s|^[[:space:]]*${key}=.*$|${key}=${value}|" "$tmp"
      rm -f "$tmp.bak"
    else
      printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
  done
  chmod "$mode" "$tmp"
  mv "$tmp" "$path"
}

# prompt_secret <prompt-text> [<default>]
# Reads from stdin (terminal-quiet). Falls back to default if user enters
# blank. Echoes the value on stdout.
prompt_secret() {
  local prompt="$1" default="${2:-}" value
  printf '%s' "$prompt" >&2
  [[ -n "$default" ]] && printf ' [default: %s]' "$default" >&2
  printf ': ' >&2
  IFS= read -rs value
  printf '\n' >&2
  [[ -z "$value" && -n "$default" ]] && value="$default"
  printf '%s' "$value"
}

# print_phase_header <phase-name>
print_phase_header() {
  printf '\n=== %s ===\n' "$1" >&2
}
```

- [ ] **Step 2: Smoke-test the helpers from a scratch file**

```bash
cat > /tmp/setup-helpers-smoke.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source bin/setup-helpers.sh

# slugify happy paths
[[ "$(slugify_project_name 'harness')" == 'harness' ]] || exit 1
[[ "$(slugify_project_name 'Multi-Project Support')" == 'multi-project-support' ]] || exit 2
[[ "$(slugify_project_name 'Twinning · v2')" == 'twinning-v2' ]] || exit 3

# slugify rejects too-short / unsafe names (must fail)
slugify_project_name 'a' >/dev/null 2>&1 && exit 4   # too short
slugify_project_name '' >/dev/null 2>&1 && exit 5    # empty
slugify_project_name '!!!' >/dev/null 2>&1 && exit 6 # all-punct

# atomic_write_file
tmpf="$(mktemp)"
echo "hello" | atomic_write_file "$tmpf" 0600
[[ "$(cat "$tmpf")" == "hello" ]] || exit 7
[[ "$(stat -f %p "$tmpf" | tail -c 4)" == "600" ]] || exit 8

# read_env_file / write_env_file round-trip
envf="$(mktemp)"
write_env_file "$envf" 0600 'KEY1=val1' 'KEY2=val with space'
got1="$(read_env_file "$envf" KEY1)"
got2="$(read_env_file "$envf" KEY2)"
[[ "$got1" == 'KEY1=val1' ]] || { echo "got: $got1"; exit 9; }
[[ "$got2" == 'KEY2=val with space' ]] || { echo "got: $got2"; exit 10; }

# write_env_file replaces in-place (idempotency)
write_env_file "$envf" 0600 'KEY1=val1-updated'
got1="$(read_env_file "$envf" KEY1)"
[[ "$got1" == 'KEY1=val1-updated' ]] || exit 11
# KEY2 still present
got2="$(read_env_file "$envf" KEY2)"
[[ "$got2" == 'KEY2=val with space' ]] || exit 12

rm -f "$tmpf" "$envf"
echo OK
EOF
bash /tmp/setup-helpers-smoke.sh
```

Expected: `OK`. If any exit code 1-12 surfaces, identify the failing helper
and fix.

- [ ] **Step 3: Commit**

```bash
git add bin/setup-helpers.sh
git commit -m "feat(ENG-XX): bin/setup-helpers.sh shared utilities

Adds slugify_project_name (validates against ^[a-z][a-z0-9-]{1,38}[a-z0-9]$),
atomic_write_file, read_env_file/write_env_file (idempotent upsert),
prompt_secret, print_phase_header. Sourced by setup.sh and setup-test.sh."
rm /tmp/setup-helpers-smoke.sh
```

---

## Task 3: `bin/setup.sh` — skeleton, CLI dispatch, `workspace` phase

**Files:**
- Create: `bin/setup.sh`

- [ ] **Step 1: Write the skeleton**

```bash
#!/usr/bin/env bash
# One-stop onboarding for a target repo. Walks every prerequisite phase
# idempotently. See docs/brainstorms/2026-04-26-multi-project-harness.md §5.2
# for the phase contract.
#
# Usage:
#   bash bin/setup.sh /path/to/target [phase]
#
# With no phase: runs all unsatisfied phases 1-11 in order.
# With <phase>: jumps to that phase only. Special phases:
#   validate      - re-runs offline checks (health-check shortcut)
#   migrate       - one-shot upgrade for an existing single-project install

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# common.sh requires TARGET_REPO and (post-bootstrap) project.slug. setup.sh
# runs before slug-freeze on a fresh project, so set the bootstrap flag for
# our own sourcing.
TARGET_REPO="${TARGET_REPO:-${1:-}}"
[[ -n "$TARGET_REPO" && -d "$TARGET_REPO" ]] || {
  printf 'usage: bash bin/setup.sh /path/to/target [phase]\n' >&2
  exit 64
}
export TARGET_REPO TWINNING_BOOTSTRAPPING=1
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=setup-helpers.sh
source "$SCRIPT_DIR/setup-helpers.sh"

PHASE="${2:-}"
SECRETS_FILE="$HARNESS_CONFIG_DIR/secrets.env"
ENV_FILE="$TARGET_CONFIG_DIR/.env.local"

# ── Phase 1: workspace ────────────────────────────────────────────────
phase_workspace() {
  print_phase_header "workspace"
  mkdir -p "$TARGET_CONFIG_DIR" "$TARGET_CONFIG_DIR/schemas"
  mkdir -p "$HARNESS_CONFIG_DIR" && chmod 0700 "$HARNESS_CONFIG_DIR"
  if [[ ! -f "$CONFIG" ]]; then
    atomic_write_file "$CONFIG" 0644 <<'JSON'
{
  "linear": {},
  "orchestrator": {}
}
JSON
    log "wrote scaffolded $CONFIG"
  else
    log "$CONFIG already present"
  fi
  log "workspace ready"
}

is_workspace_done() {
  [[ -d "$TARGET_CONFIG_DIR/schemas" && -d "$HARNESS_CONFIG_DIR" && -f "$CONFIG" ]]
}

# Phase dispatch.
ALL_PHASES=(workspace)
run_phase_or_skip() {
  local phase="$1" check_fn run_fn
  check_fn="is_${phase//-/_}_done"
  run_fn="phase_${phase//-/_}"
  if declare -F "$check_fn" >/dev/null && "$check_fn"; then
    log "phase $phase: already satisfied (skip)"
    return 0
  fi
  "$run_fn"
}

main() {
  if [[ -n "$PHASE" ]]; then
    "phase_${PHASE//-/_}"
    return
  fi
  local p
  for p in "${ALL_PHASES[@]}"; do
    run_phase_or_skip "$p"
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

`chmod +x bin/setup.sh`.

- [ ] **Step 2: Smoke-test the skeleton**

```bash
tmptarget="$(mktemp -d)"
git -C "$tmptarget" init -q
bash bin/setup.sh "$tmptarget" workspace
test -f "$tmptarget/.pipeline-config/config.json" || { echo FAIL; exit 1; }
test -d "${XDG_CONFIG_HOME:-$HOME/.config}/twinning-harness" || { echo FAIL; exit 1; }
# Idempotent
bash bin/setup.sh "$tmptarget" workspace 2>&1 | grep -q 'already present' \
  || { echo FAIL idempotency; exit 1; }
echo OK
rm -rf "$tmptarget"
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add bin/setup.sh
chmod +x bin/setup.sh && git update-index --chmod=+x bin/setup.sh
git commit -m "feat(ENG-XX): bin/setup.sh skeleton + workspace phase

Adds the onboarding entry point with phase-dispatch convention
(phase_<name> + is_<name>_done) and the first phase: scaffold
.pipeline-config/ and the shared XDG config dir."
```

---

## Task 4: `setup.sh` — `linear-auth` phase

**Files:**
- Modify: `bin/setup.sh`

- [ ] **Step 1: Smoke-test plan**

This phase verifies a `LINEAR_API_KEY` by hitting Linear's `viewer` endpoint
and persists a working key into `secrets.env`. Idempotent: if `secrets.env`
already has a working key, skip.

- [ ] **Step 2: Append the phase to `bin/setup.sh`**

Append after `phase_workspace` / `is_workspace_done`:

```bash
# ── Phase 2: linear-auth ──────────────────────────────────────────────
phase_linear_auth() {
  print_phase_header "linear-auth"
  local existing
  existing="$(read_env_file "$SECRETS_FILE" LINEAR_API_KEY | cut -d= -f2-)"
  local key="$existing"
  if [[ -z "$key" ]]; then
    key="$(prompt_secret 'Linear personal API key (Settings → API)')"
  fi
  [[ -n "$key" ]] || die "linear-auth: empty LINEAR_API_KEY"

  # Verify with viewer query.
  local resp http_code
  resp="$(curl -sS -w '\n%{http_code}' -X POST 'https://api.linear.app/graphql' \
    -H "Authorization: $key" \
    -H 'Content-Type: application/json' \
    --data '{"query":"{ viewer { id name } }"}' 2>/dev/null || true)"
  http_code="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"
  [[ "$http_code" =~ ^2 ]] || die "linear-auth: HTTP $http_code from Linear (resp: $resp)"
  jq -e '.data.viewer.id' >/dev/null 2>&1 <<<"$resp" \
    || die "linear-auth: Linear rejected the key (resp: $resp)"
  log "linear-auth: viewer=$(jq -r '.data.viewer.name' <<<"$resp")"

  write_env_file "$SECRETS_FILE" 0600 "LINEAR_API_KEY=$key"
  log "linear-auth: wrote $SECRETS_FILE"
}

is_linear_auth_done() {
  local k
  k="$(read_env_file "$SECRETS_FILE" LINEAR_API_KEY | cut -d= -f2-)"
  [[ -n "$k" ]] || return 1
  # Verify the cached key still works (cheap call).
  local resp http_code
  resp="$(curl -sS -w '\n%{http_code}' -X POST 'https://api.linear.app/graphql' \
    -H "Authorization: $k" -H 'Content-Type: application/json' \
    --data '{"query":"{ viewer { id } }"}' 2>/dev/null || true)"
  http_code="${resp##*$'\n'}"
  [[ "$http_code" =~ ^2 ]] || return 1
  jq -e '.data.viewer.id' >/dev/null 2>&1 <<<"${resp%$'\n'*}"
}
```

Update `ALL_PHASES`:

```bash
ALL_PHASES=(workspace linear-auth)
```

- [ ] **Step 3: Verify the phase signature compiles**

`bash -n bin/setup.sh` — must exit 0.

- [ ] **Step 4: Commit**

```bash
git add bin/setup.sh
git commit -m "feat(ENG-XX): setup.sh linear-auth phase

Verifies LINEAR_API_KEY against Linear viewer endpoint, persists to
shared secrets.env (mode 0600). Idempotency check re-verifies the
cached key on every invocation; phase re-runs if the key was rotated."
```

---

## Task 5: `setup.sh` — `linear-identity` phase

**Files:**
- Modify: `bin/setup.sh`

- [ ] **Step 1: Append the phase**

Append after `phase_linear_auth`:

```bash
# ── Phase 3: linear-identity ──────────────────────────────────────────
_linear_post() {
  local query="$1" vars="${2:-{\}}"
  local key resp
  key="$(read_env_file "$SECRETS_FILE" LINEAR_API_KEY | cut -d= -f2-)"
  [[ -n "$key" ]] || die "linear-identity: secrets.env LINEAR_API_KEY missing"
  local body
  body="$(jq -cn --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}')"
  resp="$(curl -sS -X POST 'https://api.linear.app/graphql' \
    -H "Authorization: $key" -H 'Content-Type: application/json' \
    --data "$body")"
  printf '%s' "$resp"
}

phase_linear_identity() {
  print_phase_header "linear-identity"
  local cur_team cur_proj
  cur_team="$(jq -r '.linear.team_id // empty' "$CONFIG")"
  cur_proj="$(jq -r '.linear.project_id // empty' "$CONFIG")"

  # Team selection.
  if [[ -z "$cur_team" ]]; then
    local teams_json team_count
    teams_json="$(_linear_post '{ teams(first: 50) { nodes { id key name } } }')"
    team_count="$(jq -r '.data.teams.nodes | length' <<<"$teams_json")"
    [[ "$team_count" -gt 0 ]] || die "linear-identity: viewer has no teams"
    printf '\nAvailable Linear teams:\n' >&2
    jq -r '.data.teams.nodes | to_entries[] | "  [\(.key + 1)] \(.value.key) — \(.value.name) (\(.value.id))"' <<<"$teams_json" >&2
    local pick
    printf 'Pick team [1-%d]: ' "$team_count" >&2
    read -r pick
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= team_count )) \
      || die "linear-identity: invalid choice: $pick"
    cur_team="$(jq -r ".data.teams.nodes[$((pick - 1))].id" <<<"$teams_json")"
  fi

  # Project selection.
  if [[ -z "$cur_proj" ]]; then
    local projs_json proj_count
    projs_json="$(_linear_post \
      'query($t: String!) { team(id: $t) { projects(first: 50) { nodes { id name } } } }' \
      "$(jq -cn --arg t "$cur_team" '{t:$t}')")"
    proj_count="$(jq -r '.data.team.projects.nodes | length' <<<"$projs_json")"
    if (( proj_count == 0 )); then
      die "linear-identity: team has no projects. Create one in Linear first, then re-run this phase."
    fi
    printf '\nProjects in this team:\n' >&2
    jq -r '.data.team.projects.nodes | to_entries[] | "  [\(.key + 1)] \(.value.name) (\(.value.id))"' <<<"$projs_json" >&2
    local pick
    printf 'Pick project [1-%d]: ' "$proj_count" >&2
    read -r pick
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= proj_count )) \
      || die "linear-identity: invalid choice: $pick"
    cur_proj="$(jq -r ".data.team.projects.nodes[$((pick - 1))].id" <<<"$projs_json")"
  fi

  # Persist.
  local tmp; tmp="$(mktemp)"
  jq --arg t "$cur_team" --arg p "$cur_proj" \
    '.linear.team_id = $t | .linear.project_id = $p' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
  log "linear-identity: team_id=$cur_team project_id=$cur_proj"
}

is_linear_identity_done() {
  [[ -n "$(jq -r '.linear.team_id // empty' "$CONFIG")" \
     && -n "$(jq -r '.linear.project_id // empty' "$CONFIG")" ]]
}
```

Update `ALL_PHASES`:

```bash
ALL_PHASES=(workspace linear-auth linear-identity)
```

- [ ] **Step 2: Syntax-check**

`bash -n bin/setup.sh`.

- [ ] **Step 3: Commit**

```bash
git add bin/setup.sh
git commit -m "feat(ENG-XX): setup.sh linear-identity phase

Lists viewer's teams and the selected team's projects via Linear
GraphQL, prompts for picks, persists team_id+project_id into
config.json. Skipped on re-run if both fields populated."
```

---

## Task 6: `setup.sh` — `linear-schema` phase

**Files:**
- Modify: `bin/setup.sh`

- [ ] **Step 1: Append the phase**

```bash
# ── Phase 4: linear-schema ────────────────────────────────────────────
phase_linear_schema() {
  print_phase_header "linear-schema"
  # secrets.env vars must be in env for setup-labels.sh / linear.sh refresh-cache.
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  set +a
  log "linear-schema: invoking bin/setup-labels.sh"
  bash "$SCRIPT_DIR/setup-labels.sh"
  log "linear-schema: invoking bin/linear.sh refresh-cache"
  bash "$SCRIPT_DIR/linear.sh" refresh-cache
}

is_linear_schema_done() {
  [[ -f "$IDS_CACHE" ]] || return 1
  # All 15 pipeline labels must resolve.
  local missing=0 label
  for label in stage:brainstorming stage:planning stage:implementing stage:ui \
    stage:reviewing stage:qa stage:building stage:released \
    pipeline:paused pipeline:supersede pipeline:extend pipeline:ignore \
    pipeline:reviewed pipeline:knowledge-reviewed pipeline:rule-reviewed; do
    local id; id="$(jq -r ".labels[\"$label\"] // empty" "$IDS_CACHE")"
    [[ -n "$id" ]] || { missing=1; break; }
  done
  (( missing == 0 ))
}
```

Update `ALL_PHASES`:

```bash
ALL_PHASES=(workspace linear-auth linear-identity linear-schema)
```

- [ ] **Step 2: Syntax-check**

`bash -n bin/setup.sh`.

- [ ] **Step 3: Commit**

```bash
git add bin/setup.sh
git commit -m "feat(ENG-XX): setup.sh linear-schema phase

Wraps bin/setup-labels.sh + bin/linear.sh refresh-cache. Idempotency
check verifies all 15 pipeline labels resolve in the IDs cache."
```

---

## Task 7: `setup.sh` — `slug-freeze` phase + collision sentinel

**Files:**
- Modify: `bin/setup.sh`

- [ ] **Step 1: Append the phase**

```bash
# ── Phase 5: slug-freeze ──────────────────────────────────────────────
phase_slug_freeze() {
  print_phase_header "slug-freeze"
  local existing; existing="$(jq -r '.project.slug // empty' "$CONFIG")"
  if [[ -n "$existing" ]]; then
    log "slug-freeze: project.slug already frozen as '$existing'"
    _slug_freeze_write_sentinel "$existing"
    return 0
  fi

  [[ -f "$IDS_CACHE" ]] || die "slug-freeze: $IDS_CACHE missing — run linear-schema phase first"
  local proj_name
  proj_name="$(jq -r '.project.name // empty' "$IDS_CACHE")"
  [[ -n "$proj_name" ]] || die "slug-freeze: linear-ids.json::.project.name is empty — re-run linear-schema with the correct project_id"

  local slug
  slug="$(slugify_project_name "$proj_name")" || die "slug-freeze: '$proj_name' did not produce a valid slug. Rename the project in Linear or pre-set project.slug in config.json manually."

  # Collision check.
  local sentinel="$HARNESS_STATE_DIR/$slug/target-repo"
  if [[ -f "$sentinel" ]]; then
    local recorded; recorded="$(cat "$sentinel")"
    if [[ "$recorded" != "$TARGET_REPO" ]]; then
      die "slug-freeze: slug '$slug' already in use by $recorded (sentinel: $sentinel). Rename the Linear project or contact the operator."
    fi
  fi

  local tmp; tmp="$(mktemp)"
  jq --arg s "$slug" '.project = (.project // {}) | .project.slug = $s' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
  log "slug-freeze: project.slug='$slug' frozen in $CONFIG"

  _slug_freeze_write_sentinel "$slug"
}

_slug_freeze_write_sentinel() {
  local slug="$1" sentinel="$HARNESS_STATE_DIR/$slug/target-repo"
  mkdir -p "$(dirname "$sentinel")"
  printf '%s\n' "$TARGET_REPO" > "$sentinel"
  log "slug-freeze: wrote sentinel $sentinel"
}

is_slug_freeze_done() {
  local slug; slug="$(jq -r '.project.slug // empty' "$CONFIG")"
  [[ -n "$slug" ]] || return 1
  [[ -f "$HARNESS_STATE_DIR/$slug/target-repo" ]] || return 1
}
```

Update `ALL_PHASES`:

```bash
ALL_PHASES=(workspace linear-auth linear-identity linear-schema slug-freeze)
```

- [ ] **Step 2: Smoke-test slug freeze with a fixture**

```bash
cat > /tmp/slug-freeze-smoke.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tmptarget="$(mktemp -d)"
mkdir -p "$tmptarget/.pipeline-config/schemas"
printf '{"linear":{}}\n' > "$tmptarget/.pipeline-config/config.json"
# Stub the IDs cache.
printf '{"project":{"id":"pid","name":"My Cool Project"}}\n' \
  > "$tmptarget/.pipeline-config/schemas/linear-ids.json"
export HARNESS_STATE_DIR="$(mktemp -d)"

bash bin/setup.sh "$tmptarget" slug-freeze 2>&1
slug="$(jq -r '.project.slug' "$tmptarget/.pipeline-config/config.json")"
[[ "$slug" == 'my-cool-project' ]] || { echo "FAIL slug=$slug"; exit 1; }
[[ "$(cat "$HARNESS_STATE_DIR/my-cool-project/target-repo")" == "$tmptarget" ]] \
  || { echo FAIL sentinel; exit 1; }

# Collision check: pre-fab a different target with the same slug.
tmptarget2="$(mktemp -d)"
mkdir -p "$tmptarget2/.pipeline-config/schemas"
printf '{"linear":{}}\n' > "$tmptarget2/.pipeline-config/config.json"
printf '{"project":{"id":"pid","name":"My Cool Project"}}\n' \
  > "$tmptarget2/.pipeline-config/schemas/linear-ids.json"
out="$(bash bin/setup.sh "$tmptarget2" slug-freeze 2>&1 || true)"
grep -q 'already in use' <<<"$out" || { echo "FAIL no collision check: $out"; exit 1; }

rm -rf "$tmptarget" "$tmptarget2" "$HARNESS_STATE_DIR"
echo OK
EOF
bash /tmp/slug-freeze-smoke.sh
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add bin/setup.sh
git commit -m "feat(ENG-XX): setup.sh slug-freeze phase + collision sentinel

Reads linear-ids.json::.project.name, slugifies, validates, writes
config.json::project.slug. Writes a target-repo sentinel inside
\$HARNESS_STATE_DIR/<slug>/ so subsequent installs targeting a
different repo path are refused with a clear error."
rm /tmp/slug-freeze-smoke.sh
```

---

## Task 8: `setup.sh` — `github-app` phase

**Files:**
- Modify: `bin/setup.sh`

- [ ] **Step 1: Append the phase**

```bash
# ── Phase 6: github-app ───────────────────────────────────────────────
phase_github_app() {
  print_phase_header "github-app"
  cat >&2 <<'TXT'
GitHub App setup
----------------
1. If you don't already have a "twinning-pipeline-bot" GitHub App, create one at:
     https://github.com/settings/apps/new
   Required permissions: Contents=Read+Write, Pull requests=Read+Write,
                         Issues=Read+Write, Metadata=Read.
   Webhook: not required.
2. After creation, install the App on your target repo via:
     https://github.com/settings/installations
   Note the Installation ID (numeric, in the install URL).
3. Generate a private key from the App's settings page; download the .pem.

TXT
  local app_id install_id pem_src pem_dest
  app_id="$(read_env_file "$SECRETS_FILE" GH_APP_ID | cut -d= -f2-)"
  if [[ -z "$app_id" ]]; then
    printf 'GitHub App ID (numeric): ' >&2
    read -r app_id
    [[ "$app_id" =~ ^[0-9]+$ ]] || die "github-app: invalid App ID: $app_id"
  fi
  install_id="$(read_env_file "$ENV_FILE" GH_APP_INSTALLATION_ID | cut -d= -f2-)"
  if [[ -z "$install_id" ]]; then
    printf 'GitHub App Installation ID (numeric, per-repo): ' >&2
    read -r install_id
    [[ "$install_id" =~ ^[0-9]+$ ]] || die "github-app: invalid Installation ID: $install_id"
  fi
  pem_dest="$HARNESS_CONFIG_DIR/github-app.pem"
  if [[ ! -f "$pem_dest" ]]; then
    printf 'Path to private key .pem (will be moved to %s): ' "$pem_dest" >&2
    read -r pem_src
    [[ -f "$pem_src" ]] || die "github-app: file not found: $pem_src"
    cp "$pem_src" "$pem_dest"
    chmod 0600 "$pem_dest"
    log "github-app: copied $pem_src -> $pem_dest (0600)"
  fi

  write_env_file "$SECRETS_FILE" 0600 \
    "GH_APP_ID=$app_id" \
    "GH_APP_PRIVATE_KEY_PATH=$pem_dest"
  write_env_file "$ENV_FILE" 0600 \
    "GH_APP_INSTALLATION_ID=$install_id"

  # Verify by minting a token.
  set -a; source "$SECRETS_FILE"; set +a
  GH_APP_INSTALLATION_ID="$install_id" \
    bash "$SCRIPT_DIR/gh-app-token.sh" >/dev/null \
    || die "github-app: gh-app-token.sh failed — check App permissions and Installation ID"
  log "github-app: token minted successfully"
}

is_github_app_done() {
  local a p i
  a="$(read_env_file "$SECRETS_FILE" GH_APP_ID | cut -d= -f2-)"
  p="$(read_env_file "$SECRETS_FILE" GH_APP_PRIVATE_KEY_PATH | cut -d= -f2-)"
  i="$(read_env_file "$ENV_FILE" GH_APP_INSTALLATION_ID | cut -d= -f2-)"
  [[ -n "$a" && -n "$p" && -n "$i" && -f "$p" ]]
}
```

Update `ALL_PHASES`:

```bash
ALL_PHASES=(workspace linear-auth linear-identity linear-schema slug-freeze github-app)
```

- [ ] **Step 2: Syntax-check**

`bash -n bin/setup.sh`.

- [ ] **Step 3: Commit**

```bash
git add bin/setup.sh
git commit -m "feat(ENG-XX): setup.sh github-app phase

Guides through GitHub App creation/installation, captures App ID,
Installation ID, and private key path. App ID + key path go to
shared secrets.env; Installation ID stays per-project in .env.local.
Verifies by minting a token via bin/gh-app-token.sh."
```

---

## Task 9: `setup.sh` — `gh-cli` and `slack` phases

**Files:**
- Modify: `bin/setup.sh`

- [ ] **Step 1: Append both phases**

```bash
# ── Phase 7: gh-cli ───────────────────────────────────────────────────
phase_gh_cli() {
  print_phase_header "gh-cli"
  if gh auth status >/dev/null 2>&1; then
    log "gh-cli: already authenticated"
    return 0
  fi
  cat >&2 <<'TXT'
gh CLI is not authenticated. The release-watcher in run-local.sh uses
`gh release list` to detect new releases.
Run in a separate terminal:    gh auth login
Press ENTER here when done...
TXT
  read -r _
  gh auth status >/dev/null 2>&1 || die "gh-cli: still not authenticated"
}

is_gh_cli_done() { gh auth status >/dev/null 2>&1; }

# ── Phase 8: slack (optional) ─────────────────────────────────────────
phase_slack() {
  print_phase_header "slack"
  local existing
  existing="$(read_env_file "$SECRETS_FILE" PIPELINE_SLACK_WEBHOOK_URL | cut -d= -f2-)"
  if [[ -n "$existing" ]]; then
    log "slack: PIPELINE_SLACK_WEBHOOK_URL already set"
    return 0
  fi
  printf 'Slack incoming webhook URL (blank to skip): ' >&2
  local url; read -r url
  if [[ -z "$url" ]]; then
    log "slack: skipped (slack.sh will no-op)"
    return 0
  fi
  [[ "$url" =~ ^https://hooks.slack.com/ ]] \
    || die "slack: URL must start with https://hooks.slack.com/"
  write_env_file "$SECRETS_FILE" 0600 "PIPELINE_SLACK_WEBHOOK_URL=$url"
  log "slack: webhook persisted"
}

is_slack_done() {
  # Slack is optional; treat as "done" if either set OR explicitly skipped.
  # The phase asks every time the var is unset, which is fine — the user can
  # press enter to skip.
  local v
  v="$(read_env_file "$SECRETS_FILE" PIPELINE_SLACK_WEBHOOK_URL | cut -d= -f2-)"
  [[ -n "$v" ]]
}
```

Update `ALL_PHASES`:

```bash
ALL_PHASES=(workspace linear-auth linear-identity linear-schema slug-freeze github-app gh-cli slack)
```

- [ ] **Step 2: Syntax-check**

`bash -n bin/setup.sh`.

- [ ] **Step 3: Commit**

```bash
git add bin/setup.sh
git commit -m "feat(ENG-XX): setup.sh gh-cli and slack phases

gh-cli: pause until \`gh auth login\` succeeds (used by release watcher).
slack: optional webhook capture into shared secrets.env. Both phases
idempotent."
```

---

## Task 10: `setup.sh` — `config-defaults` and `validate` phases

**Files:**
- Modify: `bin/setup.sh`

- [ ] **Step 1: Append both phases**

```bash
# ── Phase 9: config-defaults ──────────────────────────────────────────
phase_config_defaults() {
  print_phase_header "config-defaults"
  local tmp; tmp="$(mktemp)"
  jq '
    .orchestrator = (.orchestrator // {}) |
    if (.orchestrator.paused // null) == null then
      .orchestrator.paused = false
    else . end |
    .linear = (.linear // {}) |
    if (.linear.stage_label_prefix // null) == null then
      .linear.stage_label_prefix = "stage:"
    else . end |
    if (.linear.workflow_stages // null) == null then
      .linear.workflow_stages = ["brainstorm","plan","implement","ui","review","qa","build","release"]
    else . end |
    .linear.native_states = (.linear.native_states // {}) |
    if (.linear.native_states.active // null) == null then
      .linear.native_states.active = "In Progress"
    else . end
  ' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
  log "config-defaults: $CONFIG normalized"
}

is_config_defaults_done() {
  jq -e '
    (.orchestrator.paused != null) and
    (.linear.stage_label_prefix != null) and
    (.linear.workflow_stages != null and (.linear.workflow_stages | length) == 8) and
    (.linear.native_states.active != null)
  ' "$CONFIG" >/dev/null 2>&1
}

# ── Phase 10: validate ────────────────────────────────────────────────
phase_validate() {
  print_phase_header "validate"
  set -a; source "$SECRETS_FILE"; set +a
  bash "$SCRIPT_DIR/dry-run.sh"
}

is_validate_done() { return 1; }  # always re-run on demand
```

Update `ALL_PHASES`:

```bash
ALL_PHASES=(workspace linear-auth linear-identity linear-schema slug-freeze github-app gh-cli slack config-defaults validate)
```

- [ ] **Step 2: Syntax-check**

`bash -n bin/setup.sh`.

- [ ] **Step 3: Commit**

```bash
git add bin/setup.sh
git commit -m "feat(ENG-XX): setup.sh config-defaults and validate phases

config-defaults: writes orchestrator.paused, stage_label_prefix,
workflow_stages, native_states.active only if absent — never
overwrites human edits. Idempotency check verifies all four are
present. validate: invokes bin/dry-run.sh as a final health check;
always re-runs on demand."
```

---

## Task 11: launchd plist templates — `__PROJECT_SLUG__` substitution

**Files:**
- Modify: `launchd/com.twinning.pipeline.plist.template`
- Modify: `launchd/com.twinning.retrospective.plist.template`

- [ ] **Step 1: Edit the pipeline template**

Replace the existing `<key>Label</key>...` line at line 7 with:

```xml
  <key>Label</key>
  <string>com.twinning.pipeline.__PROJECT_SLUG__</string>
```

Replace the `StandardOutPath` at line 31:

```xml
  <key>StandardOutPath</key>
  <string>__HARNESS_STATE_DIR__/__PROJECT_SLUG__/logs/launchd.out.log</string>

  <key>StandardErrorPath</key>
  <string>__HARNESS_STATE_DIR__/__PROJECT_SLUG__/logs/launchd.err.log</string>
```

In the `EnvironmentVariables` dict (after the existing `HARNESS_STATE_DIR`
key), add:

```xml
    <key>PROJECT_SLUG</key>
    <string>__PROJECT_SLUG__</string>
```

- [ ] **Step 2: Make the same edits to the retrospective template**

Identical substitutions: Label → `com.twinning.retrospective.__PROJECT_SLUG__`,
log paths → under `__HARNESS_STATE_DIR__/__PROJECT_SLUG__/logs/`, add the
`PROJECT_SLUG` env var.

- [ ] **Step 3: Smoke-check the template substitutions are well-formed**

```bash
for f in launchd/*.plist.template; do
  grep -c '__PROJECT_SLUG__' "$f"
done
```

Expected: each file shows ≥ 3 occurrences (Label + two log paths + env var).

- [ ] **Step 4: Commit**

```bash
git add launchd/
git commit -m "feat(ENG-XX): launchd templates use __PROJECT_SLUG__

Slug-suffixed Label, per-project log paths, and an explicit PROJECT_SLUG
env var so child scripts pick up the slug without re-deriving it from
config.json on every tick. install-launchd.sh substitution to follow."
```

---

## Task 12: `bin/install-launchd.sh` — slug-aware

**Files:**
- Modify: `bin/install-launchd.sh`

- [ ] **Step 1: Replace the script body**

```bash
#!/usr/bin/env bash
# Render and load the per-project launchd pair.
#
# Usage: bash bin/install-launchd.sh /path/to/target

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_REPO="${TARGET_REPO:-${1:-}}"
[[ -n "$TARGET_REPO" && -d "$TARGET_REPO" ]] || {
  printf 'usage: bash bin/install-launchd.sh /path/to/target\n' >&2; exit 64; }
export TARGET_REPO
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

LAUNCHD_DIR="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
mkdir -p "$LAUNCHD_DIR" "$PROJECT_STATE_DIR/logs"

install_one() {
  local kind="$1" kickstart="$2"     # kind: pipeline | retrospective
  local label="com.twinning.${kind}.${PROJECT_SLUG}"
  local template="$HARNESS_ROOT/launchd/com.twinning.${kind}.plist.template"
  local target="$LAUNCHD_DIR/${label}.plist"
  [[ -f "$template" ]] || die "missing template: $template"

  sed \
    -e "s|__HARNESS_ROOT__|$HARNESS_ROOT|g" \
    -e "s|__TARGET_REPO__|$TARGET_REPO|g" \
    -e "s|__HARNESS_STATE_DIR__|$HARNESS_STATE_DIR|g" \
    -e "s|__PROJECT_SLUG__|$PROJECT_SLUG|g" \
    -e "s|__HOME__|$HOME|g" \
    "$template" > "$target"
  log "rendered $target"

  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$label" || true
    log "bootout $label"
  fi
  launchctl bootstrap "$DOMAIN" "$target"
  log "bootstrap $label"
  if [[ "$kickstart" == "1" ]]; then
    launchctl kickstart -k "$DOMAIN/$label"
    log "kickstart $label"
  fi
}

install_one pipeline      1
install_one retrospective 0

cat <<EOF

Pipeline LaunchAgents installed for project '$PROJECT_SLUG':
  com.twinning.pipeline.$PROJECT_SLUG       — every 5 min
  com.twinning.retrospective.$PROJECT_SLUG  — Mondays 09:00
  Logs: $PROJECT_STATE_DIR/logs/launchd.{out,err}.log
EOF
```

- [ ] **Step 2: Smoke-test by rendering into a fixture**

Defer the live `launchctl bootstrap` to Task 21's `install-launchd-test.sh`.
For now, just verify the syntax compiles:

`bash -n bin/install-launchd.sh`.

- [ ] **Step 3: Commit**

```bash
git add bin/install-launchd.sh
git commit -m "feat(ENG-XX): install-launchd.sh slug-aware

Takes target repo path as an arg. Reads PROJECT_SLUG from common.sh
(which derives it from config.json::project.slug), substitutes
__PROJECT_SLUG__ in both templates, renders slug-suffixed labels,
bootouts only the slug's labels (sibling projects untouched)."
```

---

## Task 13: `bin/uninstall-launchd.sh` — slug-aware

**Files:**
- Modify: `bin/uninstall-launchd.sh`

- [ ] **Step 1: Replace the script body**

```bash
#!/usr/bin/env bash
# Bootout and remove the per-project launchd pair.
#
# Usage:
#   bash bin/uninstall-launchd.sh /path/to/target
#   bash bin/uninstall-launchd.sh --slug <slug>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

slug=""
case "${1:-}" in
  --slug)
    slug="${2:-}"
    [[ -n "$slug" ]] || { printf 'usage: bash bin/uninstall-launchd.sh --slug <slug>\n' >&2; exit 64; }
    ;;
  *)
    TARGET_REPO="${TARGET_REPO:-${1:-}}"
    [[ -n "$TARGET_REPO" && -d "$TARGET_REPO" ]] || {
      printf 'usage: bash bin/uninstall-launchd.sh /path/to/target\n' >&2; exit 64; }
    export TARGET_REPO
    # shellcheck source=common.sh
    source "$SCRIPT_DIR/common.sh"
    slug="$PROJECT_SLUG"
    ;;
esac

uninstall_one() {
  local kind="$1"
  local label="com.twinning.${kind}.${slug}"
  local target="$LAUNCHD_DIR/${label}.plist"
  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$label" || true
    printf 'unloaded %s\n' "$label" >&2
  else
    printf '%s was not loaded\n' "$label" >&2
  fi
  if [[ -f "$target" ]]; then
    rm -f "$target"
    printf 'removed %s\n' "$target" >&2
  fi
}

uninstall_one pipeline
uninstall_one retrospective
```

- [ ] **Step 2: Syntax-check**

`bash -n bin/uninstall-launchd.sh`.

- [ ] **Step 3: Commit**

```bash
git add bin/uninstall-launchd.sh
git commit -m "feat(ENG-XX): uninstall-launchd.sh slug-aware

Two argument forms: <path> (resolves slug from config.json) or
--slug <slug> (direct, when target path is unavailable). Bootouts
only the slug-suffixed labels. The legacy un-suffixed bootout is
owned by setup.sh migrate (Task 20)."
```

---

## Task 14: `setup.sh` — `launchd` phase + chaining

**Files:**
- Modify: `bin/setup.sh`

- [ ] **Step 1: Append the phase**

```bash
# ── Phase 11: launchd ─────────────────────────────────────────────────
phase_launchd() {
  print_phase_header "launchd"
  local slug; slug="$(jq -r '.project.slug' "$CONFIG")"
  printf 'Install launchd agents for project '\''%s'\'' now? [Y/n]: ' "$slug" >&2
  local ans; read -r ans
  ans="${ans:-Y}"
  case "$ans" in
    [Yy]*) bash "$SCRIPT_DIR/install-launchd.sh" "$TARGET_REPO" ;;
    *) log "launchd: skipped (run install-launchd.sh manually when ready)" ;;
  esac
}

is_launchd_done() {
  local slug label
  slug="$(jq -r '.project.slug // empty' "$CONFIG")"
  [[ -n "$slug" ]] || return 1
  for label in "com.twinning.pipeline.$slug" "com.twinning.retrospective.$slug"; do
    launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || return 1
  done
}
```

Update `ALL_PHASES`:

```bash
ALL_PHASES=(workspace linear-auth linear-identity linear-schema slug-freeze github-app gh-cli slack config-defaults validate launchd)
```

- [ ] **Step 2: Syntax-check**

`bash -n bin/setup.sh`.

- [ ] **Step 3: Commit**

```bash
git add bin/setup.sh
git commit -m "feat(ENG-XX): setup.sh launchd phase

Final phase prompts the human before kicking install-launchd.sh.
Idempotency check confirms both slug-suffixed agents are loaded
under the user's gui domain."
```

---

## Task 15: Mechanical sweep — per-project state-dir paths in consumer scripts

**Files:**
- Modify: `bin/run-local.sh`, `bin/poll.sh`, `bin/metrics.sh`,
  `bin/run-stage.sh`, `bin/run-release-observer.sh`,
  `bin/run-retrospective-local.sh`, `bin/reset-pipeline.sh`,
  `bin/status.sh`, `bin/halt-sprawl-test.sh`,
  `bin/halt-sprawl-adversarial-test.sh`

- [ ] **Step 1: Identify call sites**

Run:
```bash
grep -nE '\$HARNESS_STATE_DIR/' bin/*.sh | grep -v 'common.sh\|setup\|install-launchd\|uninstall-launchd'
```

Expected output enumerates the call sites listed in §5.6 of the spec
(metrics path, logs path, lock dir, breaker counter, tick counter,
last-observed-release, halt-sprawl debounce, per-issue dirs).

- [ ] **Step 2: Replace each occurrence**

Apply this sed across `bin/`:
```bash
# Only replace HARNESS_STATE_DIR paths that point at PER-PROJECT data,
# never the per-host shared root itself. The list mirrors the grep above.
files=(
  bin/run-local.sh bin/poll.sh bin/metrics.sh bin/run-stage.sh
  bin/run-release-observer.sh bin/run-retrospective-local.sh
  bin/reset-pipeline.sh bin/status.sh
  bin/halt-sprawl-test.sh bin/halt-sprawl-adversarial-test.sh
)
for f in "${files[@]}"; do
  # Per-project paths only. The literal substrings come from the spec
  # §5.6 list.
  sed -i.bak \
    -e 's|\$HARNESS_STATE_DIR/metrics/|\$PROJECT_STATE_DIR/metrics/|g' \
    -e 's|\$HARNESS_STATE_DIR/logs/|\$PROJECT_STATE_DIR/logs/|g' \
    -e 's|\$HARNESS_STATE_DIR/.consecutive-failures|\$PROJECT_STATE_DIR/.consecutive-failures|g' \
    -e 's|\$HARNESS_STATE_DIR/.run-local.lock|\$PROJECT_STATE_DIR/.run-local.lock|g' \
    -e 's|\$HARNESS_STATE_DIR/.tick-counter|\$PROJECT_STATE_DIR/.tick-counter|g' \
    -e 's|\$HARNESS_STATE_DIR/.halt-sprawl-last-alerted|\$PROJECT_STATE_DIR/.halt-sprawl-last-alerted|g' \
    -e 's|\$HARNESS_STATE_DIR/last-observed-release|\$PROJECT_STATE_DIR/last-observed-release|g' \
    "$f"
  rm -f "$f.bak"
done
```

`issue_dir` in `common.sh:25-29` already uses `$HARNESS_STATE_DIR/$issue` —
update it to use `$PROJECT_STATE_DIR/$issue`:

```bash
issue_dir() {
  local issue="$1"
  [[ -n "$issue" ]] || die "issue_dir: missing issue id"
  printf '%s/%s' "$PROJECT_STATE_DIR" "$issue"
}
```

- [ ] **Step 3: Update existing test fixtures to set `PROJECT_SLUG`**

Find every test that exports `HARNESS_STATE_DIR` (or relies on the default):

```bash
grep -lnE 'HARNESS_STATE_DIR|TARGET_REPO=' bin/*-test.sh
```

For each, add immediately after the `export PIPELINE_DRY_RUN=1` line:

```bash
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
export PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-${HARNESS_STATE_DIR:-$(mktemp -d)}/$PROJECT_SLUG}"
mkdir -p "$PROJECT_STATE_DIR"
```

This satisfies common.sh's slug check without the test fixture having to
populate config.json.

- [ ] **Step 4: Re-run all tests**

```bash
TARGET_REPO=/path/to/twinning bash bin/dry-run.sh
for t in bin/*-test.sh; do bash "$t" || { echo "FAIL: $t"; break; }; done
```

Expected: all pass. Any test that still fails reveals a path the sweep
missed; grep for `HARNESS_STATE_DIR` in that file and fix.

- [ ] **Step 5: Commit**

```bash
git add bin/
git commit -m "refactor(ENG-XX): per-project state-dir paths

Consumer scripts now reference \$PROJECT_STATE_DIR for per-project
state (metrics, logs, breaker counter, tick counter, halt-sprawl
debounce, last-observed-release). \$HARNESS_STATE_DIR remains the
shared root used by common.sh, the cross-project claude mutex, and
the slug-namespace parent.

Existing tests bumped to pre-export PROJECT_SLUG=test-slug so common.sh
soft-resolves PROJECT_STATE_DIR without requiring a fixture
config.json::project.slug."
```

---

## Task 16: `run-local.sh` — secrets.env source order + per-project lock

**Files:**
- Modify: `bin/run-local.sh`

- [ ] **Step 1: Edit env sourcing block**

In `bin/run-local.sh:76-82` replace:

```bash
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
```

with:

```bash
SECRETS_FILE="$HARNESS_CONFIG_DIR/secrets.env"
if [[ -f "$SECRETS_FILE" ]]; then
  set -a; source "$SECRETS_FILE"; set +a
fi
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a   # per-project may override
fi
```

- [ ] **Step 2: Confirm lock dir is now per-project**

After Task 15's sweep, `LOCK_DIR` at `bin/run-local.sh:30` should already
read `$PROJECT_STATE_DIR/.run-local.lock`. Verify:

```bash
grep -n 'LOCK_DIR=' bin/run-local.sh
```

Expected: `LOCK_DIR="$PROJECT_STATE_DIR/.run-local.lock"`.

- [ ] **Step 3: Commit**

```bash
git add bin/run-local.sh
git commit -m "feat(ENG-XX): run-local.sh sources shared secrets.env

Source order is shared first (secrets.env from XDG config), then
per-project (.env.local), so per-project values override. Per-project
tick lock is implicit from the Task 15 sweep."
```

---

## Task 17: `dispatch.sh` — cross-project `claude -p` mutex + test

**Files:**
- Modify: `bin/dispatch.sh`
- Create: `bin/mutex-test.sh`

- [ ] **Step 1: Write the failing test (`bin/mutex-test.sh`)**

```bash
#!/usr/bin/env bash
# Verify dispatch.sh serializes claude calls via $HARNESS_STATE_DIR/.claude-mutex.lock/.
# We dry-run dispatch.sh from two parallel children; the second must report
# waiting for the first's PID.

set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY=test-mock-key
export PROJECT_SLUG=test-slug
HARNESS_STATE_DIR="$(mktemp -d)"
export PROJECT_STATE_DIR="$HARNESS_STATE_DIR/$PROJECT_SLUG"
export HARNESS_STATE_DIR
mkdir -p "$PROJECT_STATE_DIR"
trap 'rm -rf "$HARNESS_STATE_DIR"' EXIT

PROMPT="$(mktemp)"
echo "PROMPT BODY" > "$PROMPT"

# Slow-down dispatch.sh so the second invocation actually contends. We do
# this by pre-acquiring the mutex from this test process for 3s before
# launching the dispatch under-test.
mkdir "$HARNESS_STATE_DIR/.claude-mutex.lock"
(
  sleep 3
  rmdir "$HARNESS_STATE_DIR/.claude-mutex.lock"
) &

start="$(date +%s)"
out="$(bash "$HARNESS_DIR/dispatch.sh" brainstorm "$PROMPT" 2>&1)"
elapsed=$(( $(date +%s) - start ))

grep -q 'claude-mutex.*waiting' <<<"$out" \
  || { echo "FAIL: no waiting log line: $out"; exit 1; }
(( elapsed >= 3 )) || { echo "FAIL: did not wait (elapsed=$elapsed)"; exit 1; }

echo "OK (waited ${elapsed}s)"
```

`chmod +x bin/mutex-test.sh`.

- [ ] **Step 2: Run, expect failure**

`bash bin/mutex-test.sh`
Expected: FAIL — current dispatch.sh has no mutex.

- [ ] **Step 3: Add the mutex to `bin/dispatch.sh`**

Add near the top of `bin/dispatch.sh` after `source common.sh`:

```bash
CLAUDE_MUTEX_DIR="$HARNESS_STATE_DIR/.claude-mutex.lock"
CLAUDE_MUTEX_TIMEOUT="${CLAUDE_MUTEX_TIMEOUT:-600}"

acquire_claude_mutex() {
  local waited=0
  while ! mkdir "$CLAUDE_MUTEX_DIR" 2>/dev/null; do
    if (( waited == 0 )); then
      local holder=""
      [[ -f "$CLAUDE_MUTEX_DIR/pid" ]] && holder="$(cat "$CLAUDE_MUTEX_DIR/pid" 2>/dev/null || true)"
      log "[claude-mutex] waiting for lock held by ${holder:-<unknown>}"
    fi
    (( waited >= CLAUDE_MUTEX_TIMEOUT )) && die "[claude-mutex] timeout after ${CLAUDE_MUTEX_TIMEOUT}s"
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\n' "$$" > "$CLAUDE_MUTEX_DIR/pid"
}

release_claude_mutex() {
  rm -rf "$CLAUDE_MUTEX_DIR"
}
```

In the function that actually invokes `claude -p`, wrap the call:

```bash
acquire_claude_mutex
trap 'release_claude_mutex' EXIT
# ... existing claude invocation ...
release_claude_mutex
trap - EXIT
```

(Adjust the trap to chain with any existing EXIT trap in dispatch.sh.)

- [ ] **Step 4: Re-run the test**

`bash bin/mutex-test.sh` → `OK (waited 3s)`.

- [ ] **Step 5: Run the full test suite**

```bash
for t in bin/*-test.sh; do bash "$t" || { echo "FAIL: $t"; break; }; done
```

All green.

- [ ] **Step 6: Commit**

```bash
git add bin/dispatch.sh bin/mutex-test.sh
chmod +x bin/mutex-test.sh && git update-index --chmod=+x bin/mutex-test.sh
git commit -m "feat(ENG-XX): cross-project claude -p mutex in dispatch.sh

mkdir-based mutex on \$HARNESS_STATE_DIR/.claude-mutex.lock/ serializes
all claude -p invocations across projects. Configurable timeout via
CLAUDE_MUTEX_TIMEOUT (default 600s). Holder PID written to lock dir
for diagnostic logs in waiting siblings.

Retrospectives are automatically serialized via the same mechanism
because they go through dispatch.sh."
```

---

## Task 18: `render-prompt.sh` — `{learned_rules_dir}` token + test

**Files:**
- Modify: `bin/render-prompt.sh`
- Create: `bin/render-prompt-slug-test.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Verify render-prompt.sh substitutes {learned_rules_dir} with the slug-aware path.
set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY=test-mock-key
export PROJECT_SLUG=test-slug
HARNESS_STATE_DIR="$(mktemp -d)"
export HARNESS_STATE_DIR
export PROJECT_STATE_DIR="$HARNESS_STATE_DIR/$PROJECT_SLUG"
mkdir -p "$PROJECT_STATE_DIR"

# Mock target repo + linear.sh stub.
FAKE="$(mktemp -d)"
mkdir -p "$FAKE/.pipeline-config/schemas"
printf '{"linear":{},"project":{"slug":"test-slug"}}\n' > "$FAKE/.pipeline-config/config.json"
printf '{}\n' > "$FAKE/.pipeline-config/schemas/linear-ids.json"
export TARGET_REPO="$FAKE"

STUB="$(mktemp -d)"
cat > "$STUB/linear.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get-issue) printf '{"data":{"issue":{"identifier":"ENG-99","title":"Test","description":"d"}}}\n' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB/linear.sh"

trap 'rm -rf "$FAKE" "$STUB" "$HARNESS_STATE_DIR"' EXIT

# render-prompt.sh calls `bash "$SCRIPT_DIR/linear.sh"`, so PATH stubbing
# won't intercept it. Use the canonical source-and-override pattern:
# source common.sh + render-prompt.sh (their sentinels prevent main from
# firing), then override SCRIPT_DIR to point at the stub dir. Subsequent
# main calls then resolve linear.sh from the stub.
# shellcheck source=common.sh
source "$HARNESS_DIR/common.sh"
# shellcheck source=render-prompt.sh
source "$HARNESS_DIR/render-prompt.sh"
SCRIPT_DIR="$STUB"
out="$(main brainstorm ENG-99 2>&1)"

# After the render, the prompt body should contain the absolute path
# $HARNESS_ROOT/learned-rules/test-slug, NOT the literal token.
grep -q "{learned_rules_dir}" <<<"$out" \
  && { echo "FAIL: token not substituted"; exit 1; }
grep -q "learned-rules/test-slug" <<<"$out" \
  || { echo "FAIL: slug-aware path missing in rendered prompt"; exit 1; }

echo OK
```

Save as `bin/render-prompt-slug-test.sh`, `chmod +x`.

- [ ] **Step 2: Run, expect failure**

`bash bin/render-prompt-slug-test.sh`
Expected: FAIL — render-prompt.sh has no `{learned_rules_dir}` token, and
AGENT_PROMPTS.md uses literal `.pipeline/learned-rules/...`.

- [ ] **Step 3: Edit `bin/render-prompt.sh`**

In `main()`, after the existing `stage_summary_path=...` line, add:

```bash
local learned_rules_dir
learned_rules_dir="$HARNESS_ROOT/learned-rules/$PROJECT_SLUG"
```

In the python sub block, extend the args list and the repl dict:

```python
# args: ... learned_rules_dir
tmpl, issue_id, issue_id_lower, title, description, date, slug, brainstorm_file, plan_file, branch_name, stage_summary_path, learned_rules_dir = sys.argv[1:]
out = tmpl
repl = {
  "{issue_id}": issue_id,
  "{issue_id_lower}": issue_id_lower,
  "{issue_title}": title,
  "{issue_description}": description,
  "{date}": date,
  "{slug}": slug,
  "{brainstorm_file}": brainstorm_file,
  "{plan_file}": plan_file,
  "{branch_name}": branch_name,
  "{stage_summary_path}": stage_summary_path,
  "{learned_rules_dir}": learned_rules_dir,
}
```

Update the `python3 - "$block" ...` invocation to pass `"$learned_rules_dir"`
as the last positional arg.

In the sed-fallback block, append:

```bash
        -e "s|{learned_rules_dir}|$learned_rules_dir|g"
```

Now AGENT_PROMPTS.md still has literal `.pipeline/learned-rules/...` —
Task 19 replaces those.

- [ ] **Step 4: Update `AGENT_PROMPTS.md` enough to make the test pass**

For now, replace just the brainstorm section's reference (so the test
passes; full sweep is in Task 19):

`sed -i.bak 's|\.pipeline/learned-rules/brainstorm\.md|{learned_rules_dir}/brainstorm.md|g' AGENT_PROMPTS.md && rm AGENT_PROMPTS.md.bak`

- [ ] **Step 5: Re-run the test**

`bash bin/render-prompt-slug-test.sh` → `OK`.

- [ ] **Step 6: Commit**

```bash
git add bin/render-prompt.sh bin/render-prompt-slug-test.sh AGENT_PROMPTS.md
chmod +x bin/render-prompt-slug-test.sh && git update-index --chmod=+x bin/render-prompt-slug-test.sh
git commit -m "feat(ENG-XX): {learned_rules_dir} token in render-prompt.sh

Resolves to \$HARNESS_ROOT/learned-rules/\$PROJECT_SLUG. Both the
python substitution path and the sed fallback handle the token.
AGENT_PROMPTS.md brainstorm reference updated as a smoke target;
full sweep follows in the next commit."
```

---

## Task 19: `AGENT_PROMPTS.md` — sweep all literal learned-rules paths

**Files:**
- Modify: `AGENT_PROMPTS.md`

- [ ] **Step 1: Replace remaining literal references**

```bash
grep -n '\.pipeline/learned-rules/' AGENT_PROMPTS.md
```

Should show ~11 occurrences after Task 18's brainstorm fix.

- [ ] **Step 2: Sweep**

```bash
sed -i.bak -E 's|\.pipeline/learned-rules/([a-z]+\.md)|{learned_rules_dir}/\1|g; s|\.pipeline/learned-rules/\*\.md|{learned_rules_dir}/*.md|g' AGENT_PROMPTS.md
rm -f AGENT_PROMPTS.md.bak
grep -c '\.pipeline/learned-rules/' AGENT_PROMPTS.md
```

Expected: `0`.

- [ ] **Step 3: Update the retrospective agent's write paths in `AGENT_PROMPTS.md`**

Find the retrospective section's "files written" line (around line 1436 per
the earlier grep) — anywhere it instructs the agent to `Edit` or `Write` to
`learned-rules/<stage>.md`, change it to `{learned_rules_dir}/<stage>.md`.

Verify: `grep -n 'learned-rules' AGENT_PROMPTS.md` should show only
`{learned_rules_dir}/` references and the doc's own header comment.

- [ ] **Step 4: Run `dry-run.sh`'s prompt-extraction smoke**

```bash
TARGET_REPO=/path/to/twinning bash bin/dry-run.sh 2>&1 | grep -E 'render-prompt|extracts'
```

The "render-prompt: extracts all 9 stages" line must still pass — this is
the canary that AGENT_PROMPTS.md fence count and section structure are
intact after the sweep.

- [ ] **Step 5: Commit**

```bash
git add AGENT_PROMPTS.md
git commit -m "feat(ENG-XX): AGENT_PROMPTS.md uses {learned_rules_dir} token

Replaces every .pipeline/learned-rules/<stage>.md reference (~11
occurrences across stage sections + retrospective writes) with
{learned_rules_dir}/<stage>.md. Keeps each project's learned rules
isolated to learned-rules/<slug>/ at render time."
```

---

## Task 20: `setup.sh` — `migrate` umbrella

**Files:**
- Modify: `bin/setup.sh`

- [ ] **Step 1: Append the migrate phase**

```bash
# ── Transitional: migrate ─────────────────────────────────────────────
# One-shot upgrade of the existing single-project install. See spec §6.
phase_migrate() {
  print_phase_header "migrate"

  # 1. Sanity check.
  jq -e '.linear.team_id and .linear.project_id' "$CONFIG" >/dev/null \
    || die "migrate: $CONFIG missing team_id or project_id — abort"

  # Refresh IDs cache if missing.
  if [[ ! -f "$IDS_CACHE" ]]; then
    set -a; source "$SECRETS_FILE" 2>/dev/null || true; set +a
    bash "$SCRIPT_DIR/linear.sh" refresh-cache
  fi

  # 2. Slug freeze (delegate; idempotent).
  phase_slug_freeze

  local slug; slug="$(jq -r '.project.slug' "$CONFIG")"
  local project_state="$HARNESS_STATE_DIR/$slug"

  # 3. Lift shared credentials from per-project .env.local into shared secrets.env.
  mkdir -p "$HARNESS_CONFIG_DIR" && chmod 0700 "$HARNESS_CONFIG_DIR"
  local var
  for var in LINEAR_API_KEY GH_APP_ID GH_APP_PRIVATE_KEY_PATH PIPELINE_SLACK_WEBHOOK_URL; do
    local val; val="$(read_env_file "$ENV_FILE" "$var" | cut -d= -f2-)"
    if [[ -n "$val" ]]; then
      write_env_file "$SECRETS_FILE" 0600 "$var=$val"
      # Strip from per-project .env.local.
      sed -i.bak -E "/^[[:space:]]*${var}=/d" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
      log "migrate: lifted $var → $SECRETS_FILE"
    fi
  done

  # If the GH App private key lives at the legacy state-dir path, move it.
  local key_path; key_path="$(read_env_file "$SECRETS_FILE" GH_APP_PRIVATE_KEY_PATH | cut -d= -f2-)"
  if [[ -n "$key_path" && -f "$key_path" && "$key_path" != "$HARNESS_CONFIG_DIR/github-app.pem" ]]; then
    if [[ "$key_path" == "$HARNESS_STATE_DIR/"* || "$key_path" == "$HOME/.twinning-pipeline/"* ]]; then
      mv "$key_path" "$HARNESS_CONFIG_DIR/github-app.pem"
      chmod 0600 "$HARNESS_CONFIG_DIR/github-app.pem"
      write_env_file "$SECRETS_FILE" 0600 "GH_APP_PRIVATE_KEY_PATH=$HARNESS_CONFIG_DIR/github-app.pem"
      log "migrate: moved GitHub App private key to $HARNESS_CONFIG_DIR/github-app.pem"
    fi
  fi

  # 4. Move state dir contents under <slug>/.
  mkdir -p "$project_state"
  local item src dst
  for item in .consecutive-failures .tick-counter .halt-sprawl-last-alerted last-observed-release; do
    src="$HARNESS_STATE_DIR/$item"
    dst="$project_state/$item"
    [[ -e "$src" && ! -e "$dst" ]] && { mv "$src" "$dst"; log "migrate: moved $item"; }
  done
  for d in logs metrics; do
    src="$HARNESS_STATE_DIR/$d"
    dst="$project_state/$d"
    if [[ -d "$src" && ! -d "$dst" ]]; then
      mv "$src" "$dst"
      log "migrate: moved $d/"
    fi
  done
  # Move ENG-N issue dirs (only direct children that match ENG- prefix and are
  # not already inside a slug dir).
  while IFS= read -r -d '' issue; do
    local name; name="$(basename "$issue")"
    [[ "$name" =~ ^ENG-[0-9]+$ ]] || continue
    [[ -d "$project_state/$name" ]] && continue
    mv "$issue" "$project_state/$name"
    log "migrate: moved $name/"
  done < <(find "$HARNESS_STATE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

  # 5. Move learned-rules.
  local lr="$HARNESS_ROOT/learned-rules"
  mkdir -p "$lr/$slug"
  local rule
  while IFS= read -r -d '' rule; do
    local rname; rname="$(basename "$rule")"
    [[ -f "$lr/$slug/$rname" ]] && continue
    mv "$rule" "$lr/$slug/$rname"
    log "migrate: moved learned-rules/$rname"
  done < <(find "$lr" -mindepth 1 -maxdepth 1 -type f -name '*.md' -print0)

  # 6. Bootout legacy un-suffixed agents.
  local domain="gui/$(id -u)"
  for label in com.twinning.pipeline com.twinning.retrospective; do
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      launchctl bootout "$domain/$label" || true
      log "migrate: bootout legacy $label"
    fi
    [[ -f "$HOME/Library/LaunchAgents/$label.plist" ]] \
      && rm -f "$HOME/Library/LaunchAgents/$label.plist" \
      && log "migrate: removed legacy $label.plist"
  done

  # 7. Install slug-suffixed agents.
  bash "$SCRIPT_DIR/install-launchd.sh" "$TARGET_REPO"

  # 8. Sanity check.
  bash "$SCRIPT_DIR/dry-run.sh" >/dev/null 2>&1 || log "migrate: dry-run.sh reported failures (see above)"
  log "migrate: complete. New labels:"
  launchctl list 2>/dev/null | grep com.twinning >&2 || true
}

is_migrate_done() { return 1; }   # always re-run on demand; substeps are individually idempotent
```

Note: `phase_migrate` is intentionally *not* added to `ALL_PHASES`; it's
explicitly invoked via `setup.sh /path migrate` only.

- [ ] **Step 2: Syntax-check**

`bash -n bin/setup.sh`.

- [ ] **Step 3: Smoke-test the substeps in isolation**

Pure-bash dry-run against a fixture (no actual launchctl):

```bash
cat > /tmp/migrate-smoke.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tmptarget="$(mktemp -d)"
git -C "$tmptarget" init -q
mkdir -p "$tmptarget/.pipeline-config/schemas"
printf '{"linear":{"team_id":"t","project_id":"p"},"project":{"slug":"smoke"}}\n' \
  > "$tmptarget/.pipeline-config/config.json"
printf '{"project":{"name":"smoke"},"labels":{},"states":{}}\n' \
  > "$tmptarget/.pipeline-config/schemas/linear-ids.json"
echo 'LINEAR_API_KEY=k' > "$tmptarget/.pipeline-config/.env.local"
echo 'GH_APP_ID=42' >> "$tmptarget/.pipeline-config/.env.local"
echo 'GH_APP_PRIVATE_KEY_PATH=/tmp/legacy.pem' >> "$tmptarget/.pipeline-config/.env.local"
echo 'GH_APP_INSTALLATION_ID=99' >> "$tmptarget/.pipeline-config/.env.local"
touch /tmp/legacy.pem

export HARNESS_STATE_DIR="$(mktemp -d)"
export XDG_CONFIG_HOME="$(mktemp -d)"
mkdir -p "$HARNESS_STATE_DIR/ENG-1" "$HARNESS_STATE_DIR/logs" "$HARNESS_STATE_DIR/metrics"
echo 7 > "$HARNESS_STATE_DIR/.consecutive-failures"

# Monkey-patch install-launchd.sh + dry-run.sh + linear.sh as no-ops by
# pre-pending a stub dir.
STUB="$(mktemp -d)"
for f in install-launchd.sh dry-run.sh linear.sh; do
  cat > "$STUB/$f" <<SH
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$STUB/$f"
done
PATH_BACKUP="$PATH"
# Setup.sh resolves SCRIPT_DIR to bin/, so we copy/symlink stubs there
# temporarily? Cleaner: we trust that the migrate phase's bash "$SCRIPT_DIR/install-launchd.sh"
# call hits the real script; for this smoke we accept that the launchctl
# bootouts are skipped on a non-loaded label (no-op), and we test the
# file-move substeps instead.

bash bin/setup.sh "$tmptarget" migrate 2>&1 | tee /tmp/migrate.log

# Verify state dir contents moved under slug.
[[ -d "$HARNESS_STATE_DIR/smoke/ENG-1" ]] || { echo FAIL: ENG-1 not moved; exit 1; }
[[ "$(cat "$HARNESS_STATE_DIR/smoke/.consecutive-failures")" == 7 ]] \
  || { echo FAIL: breaker not moved; exit 1; }
# Verify shared secrets lifted.
grep -q '^LINEAR_API_KEY=' "$XDG_CONFIG_HOME/twinning-harness/secrets.env" \
  || { echo FAIL: secrets.env not populated; exit 1; }
# Verify per-project .env.local stripped of shared vars.
grep -q '^LINEAR_API_KEY=' "$tmptarget/.pipeline-config/.env.local" \
  && { echo FAIL: LINEAR_API_KEY not stripped; exit 1; }
grep -q '^GH_APP_INSTALLATION_ID=99' "$tmptarget/.pipeline-config/.env.local" \
  || { echo FAIL: installation id stripped accidentally; exit 1; }

# Idempotent: re-run is harmless.
bash bin/setup.sh "$tmptarget" migrate >/dev/null 2>&1

rm -rf "$tmptarget" "$HARNESS_STATE_DIR" "$XDG_CONFIG_HOME" "$STUB" /tmp/legacy.pem
echo OK
EOF
bash /tmp/migrate-smoke.sh
```

Expected: `OK`. (Idempotency relies on the existence checks at each substep.)

- [ ] **Step 4: Commit**

```bash
git add bin/setup.sh
git commit -m "feat(ENG-XX): setup.sh migrate umbrella

Single command 'bash bin/setup.sh /path migrate' performs the full
upgrade of an existing single-project install: sanity-check, slug
freeze, lift shared credentials into XDG secrets.env, move state-dir
contents under <slug>/, move learned-rules under <slug>/, bootout
legacy un-suffixed launchd agents, install slug-suffixed agents,
final dry-run check. Each substep is individually idempotent."
rm /tmp/migrate-smoke.sh /tmp/migrate.log
```

---

## Task 21: New tests — `setup-test.sh` and `install-launchd-test.sh`

**Files:**
- Create: `bin/setup-test.sh`
- Create: `bin/install-launchd-test.sh`

- [ ] **Step 1: Write `bin/setup-test.sh`**

```bash
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
```

`chmod +x bin/setup-test.sh`.

- [ ] **Step 2: Write `bin/install-launchd-test.sh`**

```bash
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
```

`chmod +x bin/install-launchd-test.sh`.

- [ ] **Step 3: Run both new tests**

```bash
bash bin/setup-test.sh
bash bin/install-launchd-test.sh
```

Expected: both report all green; `passed: N`, `failed: 0`.

- [ ] **Step 4: Commit**

```bash
git add bin/setup-test.sh bin/install-launchd-test.sh
chmod +x bin/setup-test.sh bin/install-launchd-test.sh
git update-index --chmod=+x bin/setup-test.sh bin/install-launchd-test.sh
git commit -m "test(ENG-XX): setup.sh phase tests + install-launchd surgical bootout

setup-test.sh covers: workspace scaffold, slug-freeze derivation +
collision detection, config-defaults preserve-vs-fill semantics.
install-launchd-test.sh stubs launchctl on PATH and verifies plist
substitutions plus that uninstalling slug A leaves slug B intact."
```

---

## Task 22: Documentation — README.md and CLAUDE.md updates

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update `README.md`**

Replace the "Local runtime (Mac Studio / launchd)" section's install snippet:

```markdown
### Install for a target repo

Run from the harness checkout:

```bash
bash bin/setup.sh /path/to/target-repo
```

`setup.sh` walks every onboarding phase idempotently — Linear auth,
team/project selection, label provisioning, slug freeze, GitHub App
credentials, `gh auth`, optional Slack, config defaults, validation, and
finally launchd installation. Re-run any time; satisfied phases are
skipped. To redo just one phase: `bash bin/setup.sh /path <phase>` (e.g.,
`linear-auth`, `slug-freeze`, `validate`).
```

Add a new section "Multi-project layout":

```markdown
## Multi-project layout

A single harness checkout drives N target repos by giving each a unique
project slug (derived once from the Linear project name and frozen in
`config.json::project.slug`). Per-project state lives at
`${XDG_STATE_HOME:-~/.local/state}/twinning-harness/<slug>/`. Each project
gets its own launchd pair: `com.twinning.pipeline.<slug>` and
`com.twinning.retrospective.<slug>`.

Shared secrets (`LINEAR_API_KEY`, `GH_APP_ID`, `GH_APP_PRIVATE_KEY_PATH`,
`PIPELINE_SLACK_WEBHOOK_URL`) live once at
`${XDG_CONFIG_HOME:-~/.config}/twinning-harness/secrets.env`. Per-project
`.env.local` only carries `GH_APP_INSTALLATION_ID`.

Cross-project `claude -p` calls are serialized via a global mutex at
`$HARNESS_STATE_DIR/.claude-mutex.lock/`, so two projects' ticks won't
overlap their agent calls.

### Migrating an existing single-project install

```bash
bash bin/setup.sh /path/to/twinning migrate
```

This single command performs the full upgrade — slug freeze, secrets
lift, state-dir relocation under `<slug>/`, learned-rules relocation
under `<slug>/`, legacy launchd bootout, and slug-suffixed reinstall.
Idempotent.
```

- [ ] **Step 2: Update `CLAUDE.md`**

In the "Three locations every script touches" table, add rows:

| Variable | Default | Holds |
|---|---|---|
| `HARNESS_CONFIG_DIR` | `${XDG_CONFIG_HOME:-~/.config}/twinning-harness` | shared secrets (`secrets.env`) and the GitHub App private key |
| `PROJECT_SLUG` | derived from `config.json::project.slug` | per-project namespace key (frozen at first setup) |
| `PROJECT_STATE_DIR` | `$HARNESS_STATE_DIR/$PROJECT_SLUG` | per-project state (issue dirs, breaker, lock, logs, metrics) |

In the "Per-issue state directory" section, replace the diagram so the
top level shows `<slug>/` between `$HARNESS_STATE_DIR/` and `ENG-N/`:

```
$HARNESS_STATE_DIR/
├── .claude-mutex.lock/         # global single-flight around dispatch.sh
└── <slug>/                     # per-project
    ├── target-repo             # collision sentinel
    ├── .consecutive-failures
    ├── .run-local.lock/
    ├── .tick-counter
    ├── last-observed-release
    ├── logs/local-YYYY-MM-DD.log + per-stage transcripts
    ├── metrics/events.jsonl
    └── ENG-N/
        ├── worktree/
        ├── issue-state.json
        └── stage-summary-<stage>.md
```

In the "When wiring a new script" section, add a bullet:

- New scripts that read or write per-project state must reference
  `$PROJECT_STATE_DIR`, never `$HARNESS_STATE_DIR/<issue>` directly.
  Cross-project shared state (the claude mutex, the project sentinel
  collision check) is the only legitimate use of `$HARNESS_STATE_DIR/`.

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs(ENG-XX): README + CLAUDE.md for multi-project layout

Replaces install-launchd.sh-first onboarding with bin/setup.sh.
Documents the shared/per-project credential split, slug-namespaced
state, the cross-project claude mutex, and the one-command migration
for existing single-project installs."
```

---

## Self-review checklist

After completing all 22 tasks, run this final check:

```bash
# All tests green.
TARGET_REPO=/path/to/twinning bash bin/dry-run.sh
for t in bin/*-test.sh; do bash "$t" || break; done

# No stale literal references.
grep -nE '\.pipeline/learned-rules/' AGENT_PROMPTS.md   # expect: 0 matches
grep -nE '\$HARNESS_STATE_DIR/(metrics|logs|\.run-local|\.consecutive)' bin/*.sh \
  | grep -v 'common.sh\|setup\|install-launchd\|uninstall-launchd'   # expect: 0 matches

# config.json has the new field.
jq -e '.project.slug' /path/to/twinning/.pipeline-config/config.json

# Both launchd labels loaded.
launchctl list | grep com.twinning   # expect 2 lines (or 4 with two projects)
```

Acceptance criteria from the spec §10 to verify manually before declaring
done:

1. Fresh `setup.sh /path/to/target-A` produces a working install (tick succeeds).
2. Re-running it is a no-op.
3. `setup.sh /path/to/target-B` derives a different slug, second install works.
4. Tripping A's breaker leaves B running.
5. Concurrent A/B ticks serialize via the mutex; non-claude work is parallel.
6. `uninstall-launchd.sh /path/to/target-A` only removes A's plists.
7. `setup.sh /path/to/twinning migrate` upgrades the existing install with no data loss.
8. `{learned_rules_dir}` in a rendered prompt resolves to `<slug>/`.
9. Existing tests pass after the namespacing pass.
10. New tests pass: `setup-test.sh`, `install-launchd-test.sh`, `mutex-test.sh`, `render-prompt-slug-test.sh`.
