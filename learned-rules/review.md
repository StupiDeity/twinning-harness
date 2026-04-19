# Learned Rules — Review Agent

> **Who writes:** Retrospective agent (from QA catches the review missed, and human overrides).
> **Who reads:** Review agent (appended to base prompt at dispatch time).
> **Format:** Each rule is a directive the agent must follow, with context on why.
> **Shelf life:** 60 days. If the problem hasn't recurred, the rule may be unnecessary.
> **Human checkpoint:** New rules require human approval before commit (see .pipeline/config.json).

---

<!-- Rules will be appended below by the retrospective agent. Format:

### Rule R-001: [short title]
**Added:** YYYY-MM-DD
**Expires:** YYYY-MM-DD (60 days from added)
**Last verified:** YYYY-MM-DD
**Source:** [what triggered this — QA catch that review missed, human override]
**Rule:** [the directive]
**Why:** [what went wrong without this rule]
**Evidence:** [link to PR/issue/commit that triggered this rule]

-->

### Rule R-001: Reject fixes that lack a traceable root-cause statement
**Added:** 2026-04-19
**Expires:** 2026-06-18
**Last verified:** 2026-04-19
**Source:** Claude Code usage analysis (2026-03-19 → 2026-04-17). Multiple bug-fix PRs landed without a stated root-cause analysis tying the code change to `path:line` evidence. Three recurring failure modes showed up downstream: wrong diagnosis (ENG-87 Google-count vs WhatsApp state), schema-vs-prompt confusion (planner eval), and a network-entitlement change that had to be reverted. See also implementation-agent Rule I-001.

**Rule:** Reject (request changes on) any bug-fix PR whose description does not contain: (1) the observed symptom, (2) the identified root cause with a `path:line` citation into the code or a quoted log excerpt, and (3) a statement that the fix addresses the cause rather than masking the symptom. For state-sync bugs the root cause must cite evidence from BOTH layers. A PR that changes logic in a provider-specific branch when the affected type is a shared trait/enum must be rejected unless it justifies why the shared layer cannot host the fix (see implementation Rule I-002).

**Why:** Without a stated root cause, the reviewer cannot distinguish a cause-addressing fix from a symptom-masking one; they look identical in the diff. Shipping symptom-masking fixes is the main driver of revert-and-re-fix cycles in the usage report.

**Evidence:** Claude Code Insights report, sections "Where Things Go Wrong" and "Impressive Things You Did → Root-Cause-First Debugging". Related tickets: ENG-87, ENG-88, planner eval session, network entitlement revert.

---

### Rule R-002: Audit for missed parallel code paths on state-sync fixes
**Added:** 2026-04-19
**Expires:** 2026-06-18
**Last verified:** 2026-04-19
**Source:** ENG-82 follow-up. Initial fix for WhatsApp source-state handling addressed the primary write path but missed the auto-resume code path, which continued to exhibit the bug. A separate fix had to ship after review.

**Rule:** For any PR that changes state-sync, recovery, or lifecycle logic (source state, session restart, reconcile, auto-resume, retry), the reviewer must verify the diff touches — or explicitly justifies not touching — every consumer of the same state. Required audit steps before approving: (1) grep the changed type/enum/field name across the repo, (2) enumerate each consumer call site in the review comment, (3) confirm each either is covered by the diff, is exercised by a new test, or has a stated reason why the fix does not apply to it. Approving without this enumeration is a rejection-worthy review.

**Why:** State-sync bugs usually manifest on multiple code paths (primary write + recovery + auto-resume) because those paths read or produce the same state. Fixing only the path named in the bug report creates a partial fix whose breakage pattern shifts rather than disappears, which is harder to debug than the original.

**Evidence:** Claude Code Insights report, section "Shortcut solutions that violate your architectural standards → missed auto-resume code path". ENG-82 fix + follow-up commits.

