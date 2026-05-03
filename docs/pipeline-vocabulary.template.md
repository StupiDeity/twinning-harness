# Pipeline vocabulary

The harness's state machine is driven by HTML comments embedded in Linear
issues. There are two families:

- **`<!-- pipeline: <event> ... -->`** — drives state. Read by the orchestrator.
- **`<!-- meta: <kind> ... -->`** — bookkeeping (dedup keys, metric counters,
  evidence bundles). Read by individual scripts; never affects pipeline state.

## Writing markers

Use `bin/pipeline.sh` — never hand-craft marker bodies. The CLI validates
every field against the closed registry below and dies loudly on unknown
tokens.

- `bin/pipeline event <issue> verdict <result> [--stage X] [--target Y] [--reason Z]`
- `bin/pipeline event <issue> transition "<from> → <to>"`
- `bin/pipeline decide <issue> --action <action> [--gate <gate>]`

## Worked example: scope-violation halt → operator approval → resume

1. Implement agent finishes 6 commits cleanly:
   ```
   bin/pipeline.sh event ENG-N verdict pass --stage implementing
   ```
2. Orchestrator runs scope-check → SEVERE violation. Applies `pipeline:halted`.
3. Operator inspects, judges the touches intentional:
   ```
   bin/pipeline.sh decide ENG-N --action approve --gate scope
   ```
4. Next tick, scope-check sees the approval and bypasses the gate.

<!-- GENERATED:registry -->
<!-- /GENERATED:registry -->

## Migration notes (Phase 2 only)

Old-shape markers (`<!-- pipeline-X: value -->`) continue to be parsed by
`parse_pipeline_marker` for backwards compatibility. Phase 3 will remove the
legacy parsing branch; until then, in-flight issues with mixed-shape comment
histories are handled transparently.
