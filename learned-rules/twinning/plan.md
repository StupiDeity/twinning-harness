# Learned Rules — Plan Agent

> **Who writes:** Retrospective agent (from implementation rework and review rejections).
> **Who reads:** Plan agent (appended to base prompt at dispatch time).
> **Format:** Each rule is a directive the agent must follow, with context on why.
> **Shelf life:** 60 days. If the problem hasn't recurred, the rule may be unnecessary.
> **Human checkpoint:** New rules require human approval before commit (see .pipeline/config.json).

---

<!-- Rules will be appended below by the retrospective agent. Format:

### Rule P-001: [short title]
**Added:** YYYY-MM-DD
**Expires:** YYYY-MM-DD (60 days from added)
**Last verified:** YYYY-MM-DD
**Source:** [what triggered this — review rejection, implementation rework, pattern analysis]
**Rule:** [the directive]
**Why:** [what went wrong without this rule]
**Evidence:** [link to PR/issue/commit that triggered this rule]

-->

### Rule P-001: Plan doc MUST start with `linear: {ISSUE_ID}` frontmatter
**Added:** 2026-04-17
**Expires:** 2026-06-16
**Last verified:** 2026-04-17
**Source:** ENG-5 plan stage misfire — see brainstorm rule B-002 for the full incident.

**Rule:** Every plan doc MUST begin with YAML frontmatter containing `linear: {issue_id}` on its own line. File naming convention: `docs/plans/{date}-{issue_id_lower}-{slug}.md` (e.g., `2026-04-17-eng-5-improve-task-quality.md`). The `reconcile.sh` canonical-match step requires frontmatter; the filename convention is a secondary signal.

**Why:** Without frontmatter, the reconcile step either false-positive-links to an unrelated doc that happens to mention the issue ID, or false-negative-proceeds and writes a duplicate. Either way the pipeline advances to a downstream stage with the wrong artifact.

**Evidence:** `.pipeline/bin/reconcile.sh` fix; metrics log `2026-04-17T10:15:50Z ... stage=plan outcome=linked notes="doc=docs/plans/2026-04-17-pipeline-automated-harness.md"` (false link to harness plan).

### Rule P-002: Enumerate every trait bound and signature change explicitly
**Added:** 2026-04-17
**Expires:** 2026-06-16
**Last verified:** 2026-04-17
**Source:** ENG-5 brainstorm introduced `entity_store: &dyn EntityStore` into `run_bootstrap`/`run_incremental` and described it as "following the existing pattern." The existing bound is `S: EvidenceStore + TaskStore + UserIdentityStore + Send + Sync`; adding EntityStore + EdgeStore (edges live on a separate trait) is a breaking change at every call site, and `run_incremental` doesn't exist. The `Storage` super-trait in `crates/twinning-core/src/storage/mod.rs:229-232` does NOT include EntityStore.

**Rule:** For any plan that adds a trait bound, widens a generic parameter, or changes a coordinator entrypoint signature, the plan MUST enumerate: (1) the current bound (quoted from code), (2) the new bound, (3) every call site that passes the bound-affected argument. If the plan says "follows the existing pattern," that phrase must be followed by an exact code excerpt showing the pattern.

**Why:** "Follows the existing pattern" hides refactors. Plans that gloss over signature changes create implementation churn when the agent discovers, mid-task, that the call sites need updates the plan didn't list.

**Evidence:** ENG-5 brainstorm ADR-006; `crates/twinning-pipeline/src/coordinator.rs:61`; `crates/twinning-core/src/storage/mod.rs:229-232`.
