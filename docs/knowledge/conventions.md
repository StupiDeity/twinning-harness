# Conventions

> **Who writes:** Review agent (proposes via `<!-- meta: metric name=convention_candidate -->`)
>                 and the retrospective agent (independently verifies the "5+ files exhibit
>                 the pattern" claim by grep, then commits with citations).
> **Who reads:** All implementing agents.
> **Shelf life:** 120 days. The retrospective recounts matching files before renewing;
>                 <5 files → remove.
> **Protection:** CODEOWNERS-gated. Agents MUST NOT edit this file directly.

Bootstrapped by the 2026-06-08 retrospective (wired output surface at
`bin/run-local-helpers.sh:503`; was never created).

Entry format:

```
### C-<NNN>: <short title>
**Added:** YYYY-MM-DD
**Expires:** YYYY-MM-DD (120 days from Added)
**Pattern:** <the convention>
**Citations (≥5):** <path:line × 5+>
```

---

_No entries yet. No `convention_candidate` review comments were emitted this period
(the harness review stage has not yet produced any)._
