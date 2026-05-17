---
linear: ENG-133
title: Review agent — make path-B / path-C verdict mechanical from (critical, major) counts
date: 2026-05-17
status: draft
---

# ENG-133 — Review Agent emits path-B fail verdict on path-C clean summary

## 1. Overview

`AGENT_PROMPTS.md` §5 (Review Agent) currently describes the path-B
/ path-C verdict choice in prose:

> B. Changes requested (any `critical` or `major` findings).
> C. Clean review (no `critical` / `major` findings).

The agent then writes a free-form "Verdict: …" line inside the
consolidated review summary AND, separately, emits a
`<!-- pipeline: verdict … -->` marker via `bin/pipeline.sh event`.
Nothing in the prompt forces those two outputs to derive from the same
data. On ENG-122 (2026-05-15T23:03Z) the agent printed
`Findings: 0 critical, 0 major, 5 minor, 7 nit. Verdict: advancing to QA`
in the summary body (path-C) and then, 27 seconds later, emitted
`verdict result=fail target=implementing` (path-B). The mismatch tripped
`guards.sh review_rejection`, looped back to implement, and cascaded
six dispatch cycles + a scope halt before the operator intervened.

The defect is structural, not stylistic: the prompt allows the agent to
*narrate* a verdict in one place and *emit* a different verdict
elsewhere because neither output is anchored to a shared, structured
number.

## 2. Goal

After ENG-133 lands:

- **AC#1.** §5 instructs the agent to print an exact count-tuple line —
  `Findings: (critical=N, major=N, minor=N, nit=N)` — as a verbatim,
  structured pre-verdict step, BEFORE the Decision-path block.
- **AC#2.** The Decision-path block is rewritten so the path-B / path-C
  branch is a mechanical predicate on `(critical, major)`:
  - `critical == 0 AND major == 0` → path C, emit
    `verdict pass --stage reviewing`.
  - `critical > 0 OR major > 0` → path B, emit
    `verdict fail --target implementing`.
  - The two are mutually exclusive — emitting both, neither, or a
    different verdict under either branch is a P0 prompt violation.
- **AC#3.** `bin/agent-prompts-content-test.sh` gains grep-anchored
  assertions for both: (a) the count-tuple emission instruction is
  present in §5; (b) the mechanical predicate language is present in
  §5's Decision-path block.
- **AC#4.** Pre-commit (`.githooks/pre-commit`, full `bin/*-test.sh`
  suite) stays green.

## 3. Design

### 3.1 Where to inject the count-tuple instruction

The count tuple must be emitted as a structured line BEFORE the
Decision-path block, so a transcript reader (operator or future
detective check) can confirm `(critical, major)` reflects what the
verdict marker did. The natural insertion site is immediately after
the existing "Merge findings into a single severity-tagged list" block
(currently the last input that produces the four counts) and
immediately before "Anti-bias pass (MANDATORY …)" — i.e., right after
the agent has computed the counts and before it spends time on
unrelated tasks that could distract it from the binary choice.

Format pinned by the prompt:

```
Findings: (critical=N, major=N, minor=N, nit=N)
```

Exact case, exact punctuation, exact order. The test asserts the
literal string `Findings: (critical=` is present in §5 — operators get
auditable transcripts; the test is grep-anchored and survives
non-structural wording changes elsewhere.

### 3.2 Decision-path rewrite

Today's Decision-path block (lines 1233–1276) labels the branches
A / B / C and describes path B as "Changes requested (any `critical`
or `major` findings)" and path C as "Clean review (no `critical` /
`major` findings)". The labels and per-branch action lists stay
unchanged — they encode the recovery contract the orchestrator
depends on. What changes is the gate sentence at the top of B and C:

- B header becomes:
  `B. Changes requested (mechanical: critical > 0 OR major > 0).`
- C header becomes:
  `C. Clean review (mechanical: critical == 0 AND major == 0) — ENG-54 contract.`

Plus a new sentence inserted between the "Decision path (apply exactly
one):" header and the path A entry:

> Compute `(critical, major)` from the merged findings list. The
> path-B / path-C choice is a mechanical predicate on those two
> counts — not a judgment call, not derived from a free-text
> "Verdict:" line. Emitting path B on `(0, 0)` or path C on a
> non-zero count is a P0 prompt violation.

The pre-verdict count-tuple emission instruction (3.1) closes the
loophole that allowed the ENG-122 cascade: the agent must publish the
two numbers it's keying off, in a single auditable line, before the
mechanical branch fires.

### 3.3 Test additions

`bin/agent-prompts-content-test.sh` already extracts §5's body via
`section_body "## 5. Review Agent"`. Two new assertions, modeled on
the existing §3 ENG-108 pattern (literal-string grep):

1. `§5 ENG-133: count-tuple emission instruction present` —
   `printf '%s\n' "$s5" | grep -qF 'Findings: (critical='`
2. `§5 ENG-133: Decision-path predicate is mechanical (critical/major)` —
   `printf '%s\n' "$s5" | grep -qF 'mechanical: critical == 0 AND major == 0'`
   `printf '%s\n' "$s5" | grep -qF 'mechanical: critical > 0 OR major > 0'`

Two grep-anchored assertions catch (a) the structured pre-verdict line
and (b) the mechanical predicate wording. Both fail loudly if a
future edit demotes the count-tuple instruction or restores the prose
gate.

## 4. Scope boundaries

IN:
- `AGENT_PROMPTS.md` §5 — count-tuple injection + Decision-path
  predicate rewrite.
- `bin/agent-prompts-content-test.sh` — three new grep assertions.

OUT:
- Detective-mode post-dispatch transcript check (file ENG-XXX follow-up
  if path-B-on-(0,0) recurs after this fix).
- Changes to §3 implement prompt (covered by ENG-140 / ENG-141 line).
- Changes to `guards.sh` rejection counter behavior (ENG-138 landed).
- Path A (premise failure) wording stays untouched.

## 5. Risks / trade-offs

- **Prompt-only fix; agent compliance is not enforced at runtime.**
  This ticket tightens the prompt and adds grep-anchored content
  tests, but a non-compliant agent that still narrates a contradictory
  verdict has no automated guard catching it. A detective-mode
  transcript check is the natural follow-up; explicitly OUT of scope
  here so this lands quickly and unblocks the dispatch-loop tax that
  ENG-122 demonstrated.
- **Test brittleness on prompt copy edits.** The grep assertions pin
  literal phrases (`Findings: (critical=`, `mechanical: critical == 0
  AND major == 0`, `mechanical: critical > 0 OR major > 0`). Any
  reword of those exact strings will trip the test — that is the
  point. Future restructuring updates both the prompt and the test
  together.

## 6. Open questions

None — scope, format, and test surface are settled in §3.
