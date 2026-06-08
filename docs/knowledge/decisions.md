# Decisions (ADRs)

> **Who writes:** Brainstorm / plan agents (propose) and the retrospective agent
>                 (records accepted/superseded status).
> **Status vocabulary:** proposed | accepted | superseded-by-ADR-<n>
> **Protection:** CODEOWNERS-gated. Agents MUST NOT edit this file directly.

Bootstrapped by the 2026-06-08 retrospective (wired output surface at
`bin/run-local-helpers.sh:504` and `bin/profile-allowlist-test.sh:208`; was never created).

Entry format:

```
## ADR-<NNN>: <title>
**Date:** YYYY-MM-DD
**Status:** proposed | accepted | superseded-by-ADR-<n>
**Context:** <forces at play>
**Decision:** <what we chose>
**Consequences:** <trade-offs, revert criterion>
```

---

## ADR-001: Bootstrap the `docs/knowledge/` corpus
**Date:** 2026-06-08
**Status:** proposed (pending CODEOWNERS approval of the 2026-06-08 retrospective PR)
**Context:** The retrospective spec and the implement prompt's "Gotcha telemetry" block
both read `docs/knowledge/{gotchas,qa-patterns,conventions,decisions}.md`, and the scope
sweep (`bin/scope-check.sh:61`, `bin/run-local-helpers.sh:501-504`) already grants those
paths in-scope status for the review + retrospective agents. But the files were never
created, so: (1) the implement prompt's gotcha-telemetry directive referenced a
non-existent file and could never fire — confirmed by zero `Gotcha-hit:`/`Gotcha-avoided:`
trailers across the entire period; (2) retrospective sections §3/§4/§6/§10 had nothing to
operate on.
**Decision:** Create the four files with headers, entry-format templates, and any entries
the 2026-06-08 retrospective could verify against current code (one gotcha, G-001).
**Consequences:** Future retrospectives become operable on the knowledge axes. Low risk —
markdown only, no code path changes. Revert criterion: if after two further retrospectives
the corpus is still empty of agent-proposed entries, conclude the proposal/verification
loop is not producing candidates and reconsider the mechanism rather than the files.
