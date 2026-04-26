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
  local dir; dir="$(dirname "$path")"
  mkdir -p "$dir"
  [[ -f "$path" ]] || : > "$path"
  local pair key value safe_value tmp
  tmp="$(mktemp "$dir/.write-env.XXXXXX")"
  cp "$path" "$tmp"
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    # Quote if needed.
    if [[ "$value" =~ [[:space:]\"\'\$\`\\] ]]; then
      value="\"${value//\"/\\\"}\""
    fi
    if grep -qE "^[[:space:]]*${key}=" "$tmp"; then
      # Escape sed replacement-side metacharacters before interpolating into
      # the s|…|…| expression.  Order matters: backslash first.
      safe_value="${value//\\/\\\\}"   # escape backslash first
      safe_value="${safe_value//&/\\&}"  # escape & (sed back-ref)
      safe_value="${safe_value//|/\\|}"  # escape | (sed delimiter)
      # macOS sed in-place needs '' after -i; keep portable form.
      sed -i.bak -E "s|^[[:space:]]*${key}=.*$|${key}=${safe_value}|" "$tmp"
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
