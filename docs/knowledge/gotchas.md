# Gotchas

> Known pitfalls the pipeline has hit. Each entry is tagged with module(s) and
> expires 90 days after `Last verified`. The retrospective agent renews via
> code-grep verification or retires the entry if the pattern is gone. New
> entries land via the weekly retrospective PR (CODEOWNERS-protected).

---

### G-001: brainstorming stage shows a high `dispatch-failed` rate (pre-ENG-131 pipe-fd hang)

**Added:** 2026-05-18
**Last verified:** 2026-05-18
**Expires:** 2026-08-16
**Tags:** `dispatch`, `brainstorming`, `gtimeout`

**Pattern:** `stage-end` events with `stage=brainstorming AND outcome=dispatch-failed`
appear at far higher counts than other stages — 28 of 32 brainstorming rejections
in the 2026-04-18 → 2026-05-18 window (87%) carried this outcome.

**Cause:** Pre-ENG-131, `bin/dispatch.sh`'s outer `cmd | renderer` pipe could leave
the renderer blocked when MCP-server descendants reparented to launchd held the
inherited fd1. The lock holder's `wait` stayed blocked past `gtimeout`'s SIGTERM
fire; the tick lock outlived the watchdog. Symptom: tick goes silent ≥10 min,
`tail` shows no `dispatch.sh exit=` line, `pgrep -af claude` enumerates orphan
MCP descendants.

**Fix landed:** 2026-05-17 (#128 — `fix/eng-131-gtimeout-watchdog-can-hang-…`).
`bin/dispatch.sh` now exits within `kill_after + ε` (≤12s) of any `gtimeout` fire.

**Verify-by next retrospective (2026-05-25):** brainstorming `dispatch-failed`
count should drop by ≥50%. If it does not, the cause is a NEW hang class — file
a sibling ticket and retire this entry.

**Evidence:** stage-failure-summary 2026-05-18 (`brainstorming — dispatch-failed
28`); CLAUDE.md "Failure-mode quick reference" row 2 (post-ENG-131 expectation).
