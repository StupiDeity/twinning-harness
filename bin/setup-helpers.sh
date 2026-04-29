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

# _validate_project_profile_schema <path>
# Returns 0 if path is a valid project-profile.md per the stack-aware
# addendum spec §6:
#   - YAML frontmatter (--- ... ---) at top
#   - frontmatter contains schema_version: 1
#   - five H2 sections in exact order: Stack, Build & test gates,
#     File layout, Language idioms, Don'ts
# Returns non-zero with a one-line reason on stderr otherwise.
_validate_project_profile_schema() {
  local path="$1"
  [[ -f "$path" ]] || { printf '_validate_project_profile_schema: not a file: %s\n' "$path" >&2; return 1; }

  # Frontmatter must open at line 1 with `---` and close before any H1/H2.
  local has_fm
  has_fm="$(awk '
    NR==1 { if ($0=="---") { in_fm=1; next } else { exit 1 } }
    in_fm && $0=="---" { print "yes"; exit 0 }
    NR>40 { exit 1 }
  ' "$path")"
  [[ "$has_fm" == "yes" ]] || { printf '_validate_project_profile_schema: missing frontmatter\n' >&2; return 1; }

  # schema_version: 1 must appear inside frontmatter
  local has_ver
  has_ver="$(awk '
    NR==1 && $0=="---" { in_fm=1; next }
    in_fm && $0=="---" { exit }
    in_fm && /^schema_version:[[:space:]]+1[[:space:]]*$/ { print "yes"; exit }
  ' "$path")"
  [[ "$has_ver" == "yes" ]] || { printf '_validate_project_profile_schema: schema_version != 1\n' >&2; return 1; }

  # Required H2 sections in exact order.
  local sections
  sections="$(grep -E '^## ' "$path" | head -5 | tr '\n' '|')"
  local expected='## Stack|## Build & test gates|## File layout|## Language idioms|## Don'\''ts|'
  if [[ "$sections" != "$expected" ]]; then
    printf '_validate_project_profile_schema: expected sections [%s], got [%s]\n' "$expected" "$sections" >&2
    return 1
  fi
  return 0
}

# _resolve_profile_markers <path>
# Reads <path>, finds <<NEEDS-INPUT: question>> markers, prompts the
# operator (stdin) for each, replaces the entire line containing the
# marker with the answer (preserving the line's leading text up to the
# marker). Empty answers re-prompt; after 3 consecutive empties, returns
# non-zero. Uses fd 3 for the profile read so the operator-prompt read
# stays bound to stdin.
_resolve_profile_markers() {
  local path="$1"
  [[ -f "$path" ]] || { printf '_resolve_profile_markers: not a file: %s\n' "$path" >&2; return 1; }
  if ! grep -q '<<NEEDS-INPUT:' "$path"; then
    return 0
  fi

  local tmp; tmp="$(mktemp "${path}.XXXXXX")"
  local line answer retries
  while IFS='' read -r -u 3 line || [[ -n "$line" ]]; do
    if [[ "$line" == *'<<NEEDS-INPUT:'* ]]; then
      local prefix question
      prefix="${line%%<<NEEDS-INPUT:*}"
      question="${line#*<<NEEDS-INPUT:}"
      question="${question%%>>*}"
      question="${question# }"
      retries=0
      answer=""
      while [[ -z "$answer" ]]; do
        printf '\n  %s\n  > ' "$question" >&2
        IFS='' read -r answer || answer=""
        if [[ -z "$answer" ]]; then
          retries=$((retries + 1))
          if (( retries >= 3 )); then
            rm -f "$tmp"
            printf '_resolve_profile_markers: 3 empty answers; aborting\n' >&2
            return 1
          fi
        fi
      done
      printf '%s%s\n' "$prefix" "$answer" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done 3< "$path"
  mv "$tmp" "$path"
  return 0
}
