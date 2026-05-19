---
linear: ENG-84
title: ENG-84 — Build agent's `tick_at:` heredoc-literal fix
date: 2026-05-19
status: plan
shepherded-by: operator
brainstorm: docs/brainstorms/2026-05-19-eng-84-build-awaiting-external-tickat-heredoc-literal.md
---

# ENG-84 — Implementation plan

## Goal

Stop the build agent from emitting the literal string `$(date -u
+"%Y-%m-%d %H:%M:%SZ")` inside its `awaiting-external/build/<issue>`
Linear comment, restoring per-tick `tick_at:` variation that defeats
`bin/linear.sh::add_comment`'s normalised-hash dedup.

## Approach

Prompt-only fix (Fix D from brainstorm): rewrite §7 P2 wait-exit
instruction in `AGENT_PROMPTS.md` to tell the agent to **embed the
current UTC time as a literal string** (computed by the agent at
turn-time) rather than as a shell substitution. Add a content-test
regression pin so future edits cannot re-introduce the
`tick_at: $(date` shape.

P5 wait-exit body says "same shape as P2" and carries through with no
additional edit needed.

## Changes

### 1. `AGENT_PROMPTS.md` §7 P2 wait-exit (lines ~1649–1657)

Before:
```
… per-tick varying line of the exact
shape `tick_at: $(date -u +"%Y-%m-%d %H:%M:%SZ")` (the space separator and
lack of a literal `T` are required so the line survives the
dedup-by-normalized-hash in `bin/linear.sh::add_comment` — without it
ticks 2..N are silently swallowed because their bodies are identical
after timestamp + SHA stripping).
```

After:
```
… per-tick varying `tick_at:` line. **Embed the current UTC time as a
literal string** of the shape `tick_at: YYYY-MM-DD HH:MM:SSZ` (e.g.
`tick_at: 2026-05-19 14:07:14Z`) — compute the value yourself; do
NOT paste shell-substitution syntax such as `$(date ...)` inside the
single-quoted heredoc, because §0 Common rules mandate `<<'EOF'`
and inside `<<'EOF'` the substitution is sent verbatim to Linear
rather than expanding (ENG-84 regression). The space separator
between date and time, and the lack of a literal `T`, are required
so the line survives the dedup-by-normalized-hash in
`bin/linear.sh::add_comment` — without per-tick variation ticks
2..N are silently swallowed because their bodies are identical
after timestamp + SHA stripping.
```

### 2. `bin/agent-prompts-content-test.sh` — regression pin

Add a new assertion in the §7-section block:

```bash
# ENG-84: §7 must not instruct the agent to embed `tick_at: $(date …)`
# inside a single-quoted heredoc. The heredoc is mandated single-quoted
# by §0 Common rules (Tool allowlist & probing) so any $(…) inside the
# body is sent verbatim to Linear — the literal `$(date …)` shape
# defeats per-tick dedup variation. Operators previously saw frozen
# `tick_at: $(date -u +"…")` lines in the awaiting-external comment.
build_body="$(section_body '## 7. Build Agent')"
if printf '%s' "$build_body" | grep -qF 'tick_at: $(date'; then
  nope 'ENG-84 §7 tick_at literal-$(date) pin' \
       '§7 still instructs `tick_at: $(date …)` — single-quoted heredoc sends substitution verbatim'
else
  ok 'ENG-84 §7 does NOT instruct `tick_at: $(date …)`'
fi
```

Use `section_body` (already defined in the file) rather than
`rendered_stage_body` because the assertion is §7-specific (the
violating string only exists inside §7, not §0).

## Files touched

| Path | Change |
|---|---|
| `AGENT_PROMPTS.md` | §7 P2 wait-exit prose rewrite |
| `bin/agent-prompts-content-test.sh` | +1 assertion |
| `docs/brainstorms/2026-05-19-eng-84-build-awaiting-external-tickat-heredoc-literal.md` | new |
| `docs/plans/2026-05-19-eng-84-build-awaiting-external-tickat-heredoc-literal.md` | new (this file) |

## Test plan

1. `bash bin/agent-prompts-content-test.sh` — passes pre-fix on every
   pin EXCEPT the new ENG-84 pin (which fails until the prompt edit
   lands), and passes on every pin including the new one post-fix.
2. Full pre-commit hook (`bash .githooks/pre-commit`) — must pass
   green, no new SKIPs introduced.
3. Visual spot-check: render the §7 block via
   `bash bin/render-prompt.sh building ENG-84` and confirm the
   "Embed the current UTC time as a literal string" sentence is
   present and the literal `$(date` substring is absent.

## Risk

Very low. Prompt-only edit; the existing build-agent fleet has been
emitting the literal `$(date …)` string for weeks already with no
load-bearing breakage (verdict marker is independent). The fix
restores cosmetic per-tick variation; worst-case regression is "we
remain on the existing broken behaviour."

## Rollback

`git revert` the single commit that edits `AGENT_PROMPTS.md` + the
content-test addition. No state-file migration; no runtime config
change.

## Decisions / open questions

None — brainstorm closed every open question.
