# Learned Rules — Implementation Agent

> **Who writes:** Retrospective agent (from review rejections, QA failures, and human overrides).
> **Who reads:** Implementation agent (appended to base prompt at dispatch time).
> **Format:** Each rule is a directive the agent must follow, with context on why.
> **Shelf life:** 60 days. If the problem hasn't recurred, the rule may be unnecessary.
> **Human checkpoint:** New rules require human approval before commit (see .pipeline/config.json).

---

<!-- Rules will be appended below by the retrospective agent. Format:

### Rule I-001: [short title]
**Added:** YYYY-MM-DD
**Expires:** YYYY-MM-DD (60 days from added)
**Last verified:** YYYY-MM-DD
**Source:** [what triggered this — review rejection, QA failure, human override]
**Rule:** [the directive]
**Why:** [what went wrong without this rule]
**Evidence:** [link to PR/issue/commit that triggered this rule]

-->

### Rule I-001: Produce a root-cause analysis before any bug-fix edit
**Added:** 2026-04-19
**Expires:** 2026-06-18
**Last verified:** 2026-04-19
**Source:** Claude Code usage analysis (2026-03-19 → 2026-04-17, 833 messages across 51 sessions). Three separate bug-fix sessions started patching before confirming the actual cause:
- ENG-87: changed Google account counting logic; real bug was WhatsApp frontend/backend state inconsistency. Required a user-driven revert.
- ENG-88: shipped a fix that missed the `search_evidence` code path, requiring a follow-up.
- Planner prompt optimization: iterated on prompt wording before discovering the real issue was a JSON schema `strict` mode constraint producing empty args.

**Rule:** Before editing any source file for a bug fix, write a root-cause analysis to the implementation-agent output containing: (1) the observed symptom quoted from the issue/logs, (2) the top 3 candidate causes ranked by likelihood, (3) the `path:line` evidence in code or logs that confirms the top cause, (4) the minimal fix that addresses the cause — not the symptom. If the bug involves state sync between two layers (e.g. Rust ↔ Svelte, frontend ↔ backend, sidecar ↔ app), the analysis must quote evidence from both layers before any edit. A fix that cannot point to `path:line` evidence is speculative; surface that explicitly and stop.

**Why:** Without this rule, implementation defaults to pattern-matching the issue title against the nearest plausible code and patching there. Symptoms and causes diverge in state-sync bugs because both layers compile and pass type checks while still being out of sync. The fix that "makes the symptom go away" in layer A often leaves the underlying bug in layer B, producing immediate regressions or silent drift that QA only catches after shipping.

**Evidence:** Claude Code Insights report, sections "Where Things Go Wrong → Premature fixes before root-cause verification" and "New Ways to Use Claude Code → Force root-cause diagnosis before code changes". Specific tickets: ENG-87, ENG-88, planner eval session.

---

### Rule I-002: No provider-specific hacks when a general interface fix applies
**Added:** 2026-04-19
**Expires:** 2026-06-18
**Last verified:** 2026-04-19
**Source:** ENG-82. First implementation was a WhatsApp-specific special case inside shared source-state handling. Human interrupted and demanded an interface-conforming solution that applied uniformly across providers (Chrome, Slack, WhatsApp). The first attempt also missed the auto-resume code path and required a follow-up fix.

**Rule:** When a bug surfaces via one provider (WhatsApp, Chrome, Slack, etc.) but the affected code is a shared trait/interface/enum consumed by multiple providers, the fix must go in the shared layer, not a per-provider branch. Before writing any `if provider == "whatsapp"`-style special case, enumerate every other call site of the shared abstraction (grep the trait or enum name) and demonstrate in the output that the fix still behaves correctly for each. For state-sync fixes specifically, audit `auto_resume`, reconcile, restart, and recovery code paths that consume the same state — a fix that handles only the primary write path is incomplete.

**Why:** Type-specific hacks silently encode the assumption that only one provider hits the bug. They accumulate into a pile of parallel `if` branches that diverge over time and bypass the abstraction's guarantees. They also hide missed code paths (auto-resume, recovery) because the author only tested the primary flow.

**Evidence:** Claude Code Insights report, section "Shortcut solutions that violate your architectural standards"; ENG-82 commit history (user rejection of first attempt, follow-up fix for auto-resume path).

---

### Rule I-003: Never introduce OS-level credential or permission prompts
**Added:** 2026-04-19
**Expires:** 2026-06-18
**Last verified:** 2026-04-19
**Source:** macOS app launch fix session. Claude shipped a fix that triggered a Keychain password dialog and dismissed it as "expected behavior" despite prior user instruction to avoid scary prompts. Required revert to the original keyring-free approach.

**Rule:** Do not introduce or retain code paths that trigger Keychain, macOS password prompts, permission dialogs, or equivalent OS-level UI from the user. Default to file-based storage (e.g. the project's encrypted `credentials.json` under the app data dir). If a credential store change is being proposed, explicitly state in the implementation-agent output: (1) which OS prompt the change could trigger, (2) under what conditions, (3) the file-based alternative considered and why it was rejected. If no alternative is viable, stop and flag for human decision — do not proceed.

**Why:** OS-level prompts break the desktop app's UX contract with the user. They appear untrusted on first launch, escalate support burden, and cannot be unwound once shipped without a data migration. Dismissing a prompt as "expected" after the user has explicitly said to avoid them is a high-signal friction event worth hard-coding against.

**Evidence:** Claude Code Insights report, fun-ending section and `docs/knowledge/`-captured memory (`feedback_no_user_facing_prompts.md`). macOS app launch revert commit range.

