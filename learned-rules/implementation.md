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
