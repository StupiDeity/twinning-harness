# QA Patterns

> **Who writes:** QA agent (proposes recurring test-shape failures) and the
>                 retrospective agent (verifies + commits / escalates).
> **Who reads:** QA + implement agents.
> **Shelf life:** 60 days. An entry with `status: open` is a bug masquerading as a
>                 pattern — the retrospective files a Linear Bug and marks it
>                 `status: escalated`.
> **Protection:** CODEOWNERS-gated. Agents MUST NOT edit this file directly.

Bootstrapped by the 2026-06-08 retrospective (wired output surface at
`bin/run-local-helpers.sh:502`; was never created).

Entry format:

```
### QA-<NNN>: <short title>
**Added:** YYYY-MM-DD
**Expires:** YYYY-MM-DD (60 days from Added)
**Status:** open | confirmed | escalated
**Pattern:** <the test-quality trap>
**Detection:** <how QA should catch it>
**Evidence:** <path:line + issue/PR>
```

---

_No entries yet. The 2026-06-08 retrospective recorded one candidate worth watching but
did not yet have ≥2 occurrences to promote:_

- **AND-joined test-literal false-pass** — a QA adversarial sweep on ENG-131 found a
  test whose grep assertion matched a code comment rather than the executable literal,
  producing a false PASS (memory: `feedback_manual_shepherd_mid_stream_planning_halt`).
  Watch for a second occurrence before promoting to QA-001.
