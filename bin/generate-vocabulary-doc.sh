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
  for field in verdict_results halt_reasons wait_reasons fail_targets pivot_targets decision_actions decision_gates meta_kinds stages; do
    printf '### `%s`\n\n' "$field"
    jq -r --arg f "$field" '.[$f][] | "- `" + . + "`"' "$REG"
    printf '\n'
  done
  printf '### `legacy_halt_reason_aliases`\n\n'
  jq -r '.legacy_halt_reason_aliases | to_entries[] | "- `" + .key + "` → `" + .value + "`"' "$REG"
  printf '\n'
}

# Use perl to do the substitution inline
TEMP_GEN=$(mktemp)
generated > "$TEMP_GEN"

perl -e '
  local $/;
  open(my $fh, "<", $ARGV[1]) or die "Cannot read generated file: $!";
  my $gen = <$fh>;
  close($fh);

  open(my $tfh, "<", $ARGV[0]) or die "Cannot read template: $!";
  my $template = <$tfh>;
  close($tfh);

  $template =~ s/<!-- GENERATED:registry -->.*?<!-- \/GENERATED:registry -->/<!-- GENERATED:registry -->\n$gen<!-- \/GENERATED:registry -->/s;
  print $template;
' "$TEMPLATE" "$TEMP_GEN" > "$OUT"

rm "$TEMP_GEN"

printf 'Generated: %s\n' "$OUT"
