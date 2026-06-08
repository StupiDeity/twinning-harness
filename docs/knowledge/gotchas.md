# Gotchas

> **Who writes:** Review agent (proposes via `<!-- meta: metric name=gotcha_new -->`)
>                 and the retrospective agent (verifies + commits).
> **Who reads:** Implement / UI agents — they add `Gotcha-hit: G-<id>` /
>                `Gotcha-avoided: G-<id>` commit trailers when a documented pattern
>                is encountered (see AGENT_PROMPTS.md "Gotcha telemetry").
> **Shelf life:** 90 days. The retrospective re-verifies each entry against current
>                 code before renewing — no auto-renew.
> **Protection:** CODEOWNERS-gated. Agents MUST NOT edit this file directly.

This file was bootstrapped by the 2026-06-08 retrospective. It is already the wired
output surface for the review + retrospective agents (`bin/scope-check.sh:61`,
`bin/run-local-helpers.sh:501`), but had never been created, so the implement prompt's
"Gotcha telemetry" block referenced a non-existent file and could never fire.

Entry format:

```
### G-<NNN>: <short title>
**Added:** YYYY-MM-DD
**Expires:** YYYY-MM-DD (90 days from Added)
**Last verified:** YYYY-MM-DD
**Tags:** <comma-separated: shell, macos, dates, scope, linear, …>
**Pattern:** <the trap, in one or two sentences>
**Avoid:** <the correct alternative>
**Evidence:** <path:line + issue/PR>
```

---

### G-001: `date -u` piped into `touch -t` backdates by the host TZ offset
**Added:** 2026-06-08
**Expires:** 2026-09-06
**Last verified:** 2026-06-08
**Tags:** shell, macos, dates, testing
**Pattern:** Test helpers compute a backdated timestamp with `date -u +%Y%m%d%H%M[.%S]`
and feed it to `touch -t`. `touch -t` interprets its argument in **local** time, not
UTC, so the resulting mtime is offset from the intended instant by the host's timezone
offset (e.g. +5:30 on an IST host). On thresholds that are "barely" crossed the file
lands on the wrong side of the boundary and the assertion flips.
**Avoid:** Drop the `-u` so `date` and `touch -t` agree on the same (local) clock, or
compute an epoch and use `touch -d @<epoch>`. Never mix `date -u` with `touch -t`.
**Evidence:** `bin/halt-sprawl-test.sh:285` (live `date -u … +%Y%m%d%H%M` → `touch -t`);
`bin/stuck-tick-alarm-test.sh:115-124` (documents the hazard in a comment). ENG-132
(PR #131) unmasked two pre-existing AC failures that traced to this pattern, not to the
code under test (memory: `feedback_backdate_file_tz_bug`).
