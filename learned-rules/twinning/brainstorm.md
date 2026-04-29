# Learned Rules — Brainstorm Agent

> **Who writes:** Retrospective agent (from review rejections and human overrides).
> **Who reads:** Brainstorm agent (appended to base prompt at dispatch time).
> **Format:** Each rule is a directive the agent must follow, with context on why.
> **Shelf life:** 60 days. If the problem hasn't recurred, the rule may be unnecessary.
> **Human checkpoint:** New rules require human approval before commit (see .pipeline/config.json).

---

<!-- Rules will be appended below by the retrospective agent. Format:

### Rule B-001: [short title]
**Added:** YYYY-MM-DD
**Expires:** YYYY-MM-DD (60 days from added)
**Last verified:** YYYY-MM-DD
**Source:** [what triggered this — review rejection, human override, pattern analysis]
**Rule:** [the directive]
**Why:** [what went wrong without this rule]
**Evidence:** [link to PR/issue/commit that triggered this rule]

-->

### Rule B-001: Verify every named code artifact against the repo before asserting it exists
**Added:** 2026-04-17
**Expires:** 2026-06-16
**Last verified:** 2026-04-17
**Source:** Human review of ENG-5 brainstorm (docs/brainstorms/2026-04-17-improve-task-quality-design.md). The brainstorm self-review passed 4/5 personas but the feasibility persona validated against prior design docs rather than the Rust code, and shipped three codebase-fact errors:
- Called `EntityStore.find_by_name_and_type()`; actual name is `find_entity_by_name_and_type` at `crates/twinning-core/src/storage/mod.rs:149`.
- Called `EntityStore.get_entity_edges()`; no such method — edges live on a separate `EdgeStore` trait via `get_edges_for_entity(entity_id)` at `storage/mod.rs:160-179`.
- Claimed "SQL full-text search on evidence"; FTS5 is wired only for `episodic_fts` (`crates/twinning-storage/src/schema.rs:350-370`), not evidence. This conflicted with the doc's "No Schema Changes Required" claim.
- Referenced `run_incremental()` coordinator entrypoint; only `run_bootstrap` exists (`crates/twinning-pipeline/src/coordinator.rs:61`).

**Rule:** For every method, trait, module path, struct field, SQL table/column, SQL function, file path, crate, or coordinator entrypoint named in the brainstorm, open the current code and quote a `path:line` reference in the Assumption Inventory. Treat prior design docs as intent statements, never as proof of existence. If a referenced item does not exist, mark the assumption "assumed" and list the exact file that must be modified or created. Coordinator generic bounds (`<S: Trait1 + Trait2 + ...>`) must be enumerated explicitly — "follows the existing pattern" is not sufficient when adding a new trait dependency.

**Why:** Without this rule, feasibility review validates the brainstorm's internal consistency but not its contact with reality. Design docs describe past intent; they drift. Code is the only source of truth for method names, trait bounds, schema columns, and entrypoint signatures. A brainstorm that names non-existent methods will either fail at compile time (wasting a plan + implementation cycle) or silently be "fixed" by the implementation agent inventing different code than the brainstorm asked for.

**Evidence:** commit `d33dc2d chore(pipeline): brainstorm for ENG-5`; gaps surfaced in document-review pass dated 2026-04-17.

---

### Rule B-002: Declare Linear issue ownership via YAML frontmatter, not prose
**Added:** 2026-04-17
**Expires:** 2026-06-16
**Last verified:** 2026-04-17
**Source:** ENG-5 plan stage misfire. `reconcile.sh` used `grep -ril "\bENG-5\b"` over all plan docs, which matched `docs/plans/2026-04-17-pipeline-automated-harness.md` line 4 ("pick up a Linear issue (e.g. ENG-5)"). The plan stage emitted `outcome=linked` and skipped writing an ENG-5 plan. ENG-5 entered `stage:implementing` with no plan doc.

**Rule:** Every brainstorm and plan doc MUST begin with YAML frontmatter `---\nlinear: {ISSUE_ID}\n...\n---`. The reconcile step only treats a doc as a canonical claim on an issue when the ID appears in frontmatter or the first H1; prose mentions are ignored.

**Why:** Grep-over-body matches false-positive on any doc that incidentally mentions the issue ID (examples, cross-references, prior work). The reconcile result "link" silently prevents the plan agent from running, and the skip is invisible until the feature ships buggy.

**Evidence:** `.pipeline/bin/reconcile.sh` pre-patch; `docs/knowledge/pipeline-metrics.md` line `2026-04-17T10:15:50Z event=stage-end issue=ENG-5 stage=plan outcome=linked notes="doc=docs/plans/2026-04-17-pipeline-automated-harness.md"`. Fix in `.pipeline/bin/reconcile.sh` (frontmatter + H1 matcher).

---

### Rule B-003: Forbid `${SECRET:-FALLBACK}` and `${SECRET:+ALT}` env-probe forms against secret-named env vars
**Added:** 2026-04-28
**Expires:** 2026-06-27
**Last verified:** 2026-04-28
**Source:** Surfaced by ENG-45 UI stage's pre-flight env probe self-flag (`stage-summary-ui.md` line 17). The agent emitted `${LINEAR_API_KEY:+SET}${LINEAR_API_KEY:-UNSET}`; the `:-UNSET` half materialized the live key value into the local shell context. Same idiom anywhere that pipes its output to a durable destination (Linear comment, log file, argv list) would leak the secret.

**Rule:** Never write `${VAR:-FALLBACK}` or `${VAR:+ALTERNATE}` against env vars whose names match `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`. The canonical safe form for presence/emptiness checks is **single-dash, empty fallback**: `[[ -n "${VAR-}" ]]` and `[[ -z "${VAR-}" ]]`. For non-empty defaults in test code (mock keys etc.), use the **assign-default** form `: "${VAR:=default}"; export VAR` — `:=` does not match the lint regex (`:[\+\-]`) and has identical user-facing semantics. The lint `bin/secret-probe-lint.sh` (run by `bin/dry-run.sh` and `.github/workflows/secret-probe-lint.yml`) enforces this on every commit.

**Why:** `${VAR:-FALLBACK}` returns the variable's *value* when set, not the literal `FALLBACK`. So `echo "${KEY:-UNSET}"` prints the actual key when set. The `:+` half is unsafe when `ALTERNATE` references `$VAR` (e.g. `${KEY:+--auth=$KEY}`) — the value is materialized via the alternate string. Both halves of a presence-probe composition `${KEY:+SET}${KEY:-UNSET}` bite. Pattern recurs because it is a common training-data idiom for "include flag if set" / "default if unset"; prose-only guards (preamble rules) get forgotten — the lint is the structural defense.

**Evidence:** ENG-45 UI agent self-flag (Linear ENG-45 § stage-summary-ui.md line 17); ENG-46 issue (this rule's home); brainstorm at `docs/brainstorms/2026-04-28-agent-env-probe-pattern-secret-unset-leaks-key-values-into-agent-context-design.md`; lint at `bin/secret-probe-lint.sh`; preamble at `AGENT_PROMPTS.md "Secret-handling preamble (ENG-46)"`.
