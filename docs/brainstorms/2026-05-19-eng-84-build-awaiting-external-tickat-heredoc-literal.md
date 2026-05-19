---
linear: ENG-84
title: Build agent's `awaiting-external/build/<issue>` comment carries literal `$(date …)`
date: 2026-05-19
status: brainstorm
shepherded-by: operator
---

# ENG-84 — Build agent's `awaiting-external/build/<issue>` `tick_at:` carries literal `$(date …)`

## Problem statement

Build agent's per-tick informational `awaiting-external/build/<issue>` Linear
comment is constructed via a **single-quoted heredoc** (`<<'EOF'`). Per the
`AGENT_PROMPTS.md` §0 Common-rules contract, the single-quoted form is
**mandatory** for safety (`$VAR`, `$(cmd)`, backticks inside the body are
sent verbatim to Linear rather than expanded by the agent's shell). The
prompt at §7 P2 and §7 P5 instructs the agent to use a `tick_at:` line "of
the exact shape `tick_at: $(date -u +"%Y-%m-%d %H:%M:%SZ")`". The agent
literally pastes that string inside the single-quoted heredoc, where it
DOES NOT expand. The Linear comment therefore carries the literal text
`$(date -u +"%Y-%m-%d %H:%M:%SZ")` rather than a UTC timestamp.

## Observed

ENG-79 monitoring run on 2026-05-08; build agent self-reported the issue
verbatim during its second build dispatch (ticket description quotes the
transcript). The agent attempted an unquoted-heredoc workaround which the
sandbox rejected — single-quoted heredoc is the only safe shape per §0.

## Effect

* The per-tick informational comment looks **static** in the Linear UI
  even though the orchestrator is re-dispatching every tick.
* Operators reading the comment see a frozen literal `tick_at: $(date
  ...)` line and may misread it as "the orchestrator stopped
  re-dispatching."
* `linear.sh add-or-update-comment`'s normalised-hash dedup
  (`bin/linear.sh::add_comment`) collapses subsequent re-emissions
  because the body never varies — so the dedup-vulnerability the
  per-tick line was supposed to defeat is **active**.
* **Load-bearing pipeline marker is unaffected.** `<!-- pipeline:
  verdict result=wait reason=awaiting-approval -->` is emitted via
  `bin/pipeline.sh event {issue_id} verdict wait …`, which uses its
  own internal timestamp logic; the orchestrator's pre-dispatch
  budget hook (ENG-45) reads only that marker.

## Severity

**Low (cosmetic).** Verdict marker and `external_signal_budget`
escalation are unaffected. The fix is a prompt-only edit (no
behavioural change to `bin/*.sh` or any executable surface).

## Constraints

1. **Single-quoted heredoc is non-negotiable** — §0 Common rules at
   `AGENT_PROMPTS.md:223` mandates it for safety. Switching the §7
   construction to `<<EOF` (double-quoted) violates that contract and
   regresses the safety property §0 protects.
2. **Building stage allowlist** (`bin/dispatch.sh:483`) does NOT grant:
   - `Bash(bash -c:*)` — no shell-out for `TS=$(date …)` plumbing.
   - `Bash(printf:*)` / `Bash(date:*)` — no standalone substitution
     helpers either.
   So the agent CANNOT pre-compute a `TS` variable in a separate
   Bash invocation and reference it inside a subsequent `linear.sh`
   call.
3. **Per-tick variation must survive `bin/linear.sh::add_comment`'s
   dedup hash** — the timestamp's space separator (no literal `T`)
   is what makes the line variable; the hash normaliser strips ISO
   `T`-separated timestamps as boilerplate.

## Fix shape candidates

### A. Switch to double-quoted heredoc
Violates §0 (constraint 1). Rejected.

### B. Pre-compute `TS` into a shell variable + reference inside heredoc
Cannot work — single-quoted heredoc doesn't expand variables (same
mechanism that swallows `$(date …)` swallows `${TS}`). To make `${TS}`
expand the heredoc must be unquoted, which re-introduces §0's safety
problem AND the sandbox rejects unquoted heredocs.

### C. Pipe a `printf` body into stdin
`printf` is not allowlisted for building (constraint 2); cannot
shell-out via `bash -c` either. Rejected.

### D. **Agent-resolved literal timestamp** (recommended)
Rewrite the §7 prompt instruction to tell the agent to **compute the
current UTC time itself and embed the value as a literal string**
inside the single-quoted heredoc. The agent has its dispatch time in
its world-state and can format an ISO-ish stamp inline. This:

* Preserves §0's single-quoted heredoc contract verbatim.
* Requires no allowlist additions.
* Produces a per-tick varying body (each dispatch the agent embeds
  a different literal), satisfying the dedup-survival requirement.
* Is exactly Fix B from the ticket description, re-interpreted for
  the sandbox constraints (the ticket's example `TS="$(date …)"`
  pre-compute path doesn't work under building's allowlist, but the
  spirit — "don't rely on heredoc-time substitution" — does).

The cost is that the agent must do one extra mental step
(compute timestamp); on a turn-based LLM agent this is trivial.

## Recommendation

Fix D (agent-resolved literal). Edits:

1. **`AGENT_PROMPTS.md` §7 P2 wait-exit** (around line 1653) — change
   "of the exact shape `tick_at: $(date -u +"%Y-%m-%d %H:%M:%SZ")`"
   to instructions that say: **embed the current UTC time as a literal
   string of shape `tick_at: YYYY-MM-DD HH:MM:SSZ`** (compute it
   yourself; do NOT paste shell substitution syntax inside a
   single-quoted heredoc — §0 rule).
2. **`AGENT_PROMPTS.md` §7 P5 wait-exit** (around line 1690) — body
   says "same shape as P2"; carries through automatically once P2
   is fixed. No additional edit needed.
3. **`bin/agent-prompts-content-test.sh`** — add a regression pin
   asserting §7's body does NOT contain the literal substring
   `tick_at: $(date` (the regression shape we want to prevent
   re-introduction of).

## Out of scope

* Behavioural changes to `bin/linear.sh::add_comment` dedup logic
  (the agent-side fix is sufficient).
* Backfilling the literal-`$(date …)` comments already in Linear
  on prior build runs (cosmetic; humans can ignore).
* Adding `Bash(date:*)` or `Bash(printf:*)` to building's allowlist
  (broader threat-surface change, separate ticket if ever desired).

## Open questions

None. The fix surface is intentionally small (prompt edit + content
test pin). The original ticket already enumerated Fix shapes A/B; this
brainstorm adds the sandbox-constraint analysis that selects D.

## References

* Ticket: ENG-84
* Related: ENG-79 (monitoring transcript), ENG-45 (build-stage wait
  pre-dispatch hook), ENG-55 (stdin-heredoc convention), ENG-56
  (wait-shape labels)
* §0 mandate: `AGENT_PROMPTS.md:223` (single-quoted heredoc rule)
* Building allowlist: `bin/dispatch.sh:483`
* Memory: `feedback_build_wait_tickat_quoted_heredoc` — operator
  learnt the same property at 2026-05-15 while writing wait
  comments by hand.
