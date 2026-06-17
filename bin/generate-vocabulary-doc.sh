#!/usr/bin/env bash
# Generate docs/pipeline-vocabulary.md from bin/pipeline-events.json +
# docs/pipeline-vocabulary.template.md. Run from the repo root.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$SCRIPT_DIR/.."
REG="$HARNESS_ROOT/bin/pipeline-events.json"
TEMPLATE="$HARNESS_ROOT/docs/pipeline-vocabulary.template.md"
OUT="$HARNESS_ROOT/docs/pipeline-vocabulary.md"

generated() {
  printf '## Closed event registry\n\n'
  printf 'Source: `bin/pipeline-events.json` — edit there, not here.\n\n'
  for field in verdict_results verdict_authors halt_reasons wait_reasons fail_targets pivot_targets pivot_reasons decision_actions decision_gates meta_kinds stages; do
    printf '### `%s`\n\n' "$field"
    jq -r --arg f "$field" '.[$f][] | "- `" + . + "`"' "$REG"
    printf '\n'
  done
  if jq -e '.legacy_halt_reason_aliases' "$REG" >/dev/null 2>&1; then
    printf '### `legacy_halt_reason_aliases`\n\n'
    jq -r '.legacy_halt_reason_aliases | to_entries[] | "- `" + .key + "` → `" + .value + "`"' "$REG"
    printf '\n'
  fi
}

# ENG-112: events.<name>.linear_comment schemas → "Comment schemas" section.
event_schemas() {
  printf '## Comment schemas\n\n'
  printf 'Source: `bin/pipeline-events.json::events` — edit there, not here.\n\n'
  printf 'Each pipeline-driving comment has a machine-readable schema that names\n'
  printf 'its body shape, required and optional fields, the writer lane that\n'
  printf 'authors it, and the dedup-sig policy (when applicable). `bin/pipeline.sh`\n'
  printf 'validates every emitted body against the schema below.\n\n'
  local ev
  for ev in $(jq -r '.events | keys[]' "$REG"); do
    printf '### `%s`\n\n' "$ev"
    printf -- '- **Body shape:** `%s`\n' "$(jq -r --arg e "$ev" '.events[$e].linear_comment.body_shape' "$REG")"
    printf -- '- **Writer lane:** `%s`\n' "$(jq -r --arg e "$ev" '.events[$e].linear_comment.writer_lane' "$REG")"
    local req
    req="$(jq -r --arg e "$ev" '.events[$e].linear_comment.required // [] | join(", ")' "$REG")"
    [[ -n "$req" ]] && printf -- '- **Required fields:** `%s`\n' "$req"
    local opt
    opt="$(jq -r --arg e "$ev" '.events[$e].linear_comment.optional // [] | join(", ")' "$REG")"
    [[ -n "$opt" ]] && printf -- '- **Optional fields:** `%s`\n' "$opt"
    if jq -e --arg e "$ev" '.events[$e].linear_comment.required_by_arm' "$REG" >/dev/null 2>&1; then
      printf -- '- **Required by arm:**\n'
      jq -r --arg e "$ev" '
        .events[$e].linear_comment.required_by_arm
        | to_entries[]
        | "  - `\(.key)`: " + (if (.value | length) == 0 then "(none)" else (.value | map("`" + . + "`") | join(", ")) end)
      ' "$REG"
    fi
    if jq -e --arg e "$ev" '.events[$e].linear_comment.dedup_sig_by_arm' "$REG" >/dev/null 2>&1; then
      printf -- '- **Dedup sig by arm:**\n'
      jq -r --arg e "$ev" '
        .events[$e].linear_comment.dedup_sig_by_arm
        | to_entries[]
        | "  - `\(.key)`: " + (if .value == null then "_(append-only)_" else "`" + .value + "`" end)
      ' "$REG"
    fi
    printf '\n'
  done
}

# Use perl to do the substitution inline (two sentinel pairs).
TEMP_GEN=$(mktemp)
TEMP_SCHEMAS=$(mktemp)
generated > "$TEMP_GEN"
event_schemas > "$TEMP_SCHEMAS"

perl -e '
  local $/;
  open(my $fh, "<", $ARGV[1]) or die "Cannot read generated file: $!";
  my $gen = <$fh>;
  close($fh);

  open(my $sh, "<", $ARGV[2]) or die "Cannot read event-schemas file: $!";
  my $schemas = <$sh>;
  close($sh);

  open(my $tfh, "<", $ARGV[0]) or die "Cannot read template: $!";
  my $template = <$tfh>;
  close($tfh);

  $template =~ s/<!-- GENERATED:registry -->.*?<!-- \/GENERATED:registry -->/<!-- GENERATED:registry -->\n$gen<!-- \/GENERATED:registry -->/s;
  $template =~ s/<!-- GENERATED:event-schemas -->.*?<!-- \/GENERATED:event-schemas -->/<!-- GENERATED:event-schemas -->\n$schemas<!-- \/GENERATED:event-schemas -->/s;
  print $template;
' "$TEMPLATE" "$TEMP_GEN" "$TEMP_SCHEMAS" > "$OUT"

rm "$TEMP_GEN" "$TEMP_SCHEMAS"

printf 'Generated: %s\n' "$OUT"
