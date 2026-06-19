# Build & Operations (open-core)

> Captures the **repo, distribution, install/setup, run modes, auth, and the open-core seam** for the
> redesigned harness. Grounded in the commercial vision (`~/code/SDLC SaaS Product.md`) and GOAL-INSTALL
> (control-loop §10). The redesigned `twinning-harness` is the **free OSS execution core**; a separate
> commercial **SaaS Control Plane** plugs in around it. This doc defines the core's shape so the plane
> is a clean plug-in, never a fork. Status: draft 2026-06-20.

---

## 1. Repo + the leaves `[DECIDED — operator 2026-06-20]`

- **New repo** (greenfield TS product). `twinning-harness` was always the internal codename; the OSS
  core gets its own repo, name, CI, and release process — *not* built inside `~/code/twinning-harness`.
- **Do NOT vendor the leaves.** Instead **port them authoritatively** into the new codebase: the prompt
  assets (`AGENT_PROMPTS.md` content) are copied in as first-class assets; the leaf *logic*
  (`render-prompt` extraction, the `dispatch.sh` invocation, `scope-check`'s diff) is reimplemented in
  TS as needed. The new repo is **self-contained** — no `leaves/` sidecar, no shell-out to the old repo.
  - *Reconciliation:* this supersedes the cutover-convenience "shell out to `dispatch.sh`" in
    minimal-loop §3 — the dispatch invocation becomes native TS. (The §3a *disambiguation* and the
    structured-output story are unaffected; only the seam moves from bash-shell-out to in-process.)
- **The old repo stays live** through the 1–2 week rollback window (§9.4 #7), then is decommissioned.
- `docs/redesign/` moves to the new repo as the product's design docs (the current branch keeps history).

## 2. The open-core boundary (what's CORE vs the PLANE)

From the commercial blueprint (SaaS doc §6). The **core is self-sufficient and free**; the plane is the
paid layer that removes organisational/financial/social friction.

| SDLC stage | OSS core (`twinning-harness`) | Commercial plane ("Control Plane") |
|---|---|---|
| Ideas → Tickets | execute a *structured* ticket (own design stage for rough tickets) | the **Autonomous PM**: messy idea → atomised, machine-readable tickets |
| Tickets → SDLC | **our substrate** — design→implement→verify→review→merge loop, worktrees, bounded cycles | guardrail/budget panel, escalation routing, **parallel fleet** |
| SDLC → Measure | verify telemetry hooks exist; local test runs | ephemeral-env preview sync |
| Measure → Report | per-ticket execution summary to terminal/JSON | persona-filtered weekly drill-down dashboards |
| Report → Learn | raw `learned-rules/` dump (the retrospective) | retro portal + profile compaction/auto-update |

**Everything we've specced (schema / control-loop / projector / minimal-loop) IS the core's
"Tickets → SDLC" engine.** The plane never reaches inside it — it talks through the stable contracts in §5.

## 3. Distribution + run modes

The fleet/CI use-cases mean the core ships **more than a launchd daemon**:

- **Distribution:** a single self-contained **binary** (Homebrew tap + GitHub release), a **GitHub
  Action**, and a **container image**. All three wrap the same core.
- **Run modes:**
  - **`harness setup <repo>`** — the probe: discover the project-profile, discover/ask the checks-system,
    create+migrate the DB, refresh the Linear id-cache + projection labels, and (for daemon mode) render
    + bootstrap the launchd plist. Idempotent. *This is the developer hook* (download → setup → an
    instantly-useful profile).
  - **`harness daemon`** — persistent local (launchd `KeepAlive`), watches the SQLite queue, K-concurrency,
    one DB / all projects (CL-1). The **solo-dev / local-team** mode.
  - **`harness run <ticket>`** — a **one-shot headless runner**: execute ONE ticket to PR-ready (or merge)
    and exit, emitting telemetry. The **CI / cloud / fleet primitive** — the SaaS spins up N of these in
    parallel. Ephemeral per-run SQLite (the journal still gives in-run crash-resume); the durable output
    is the **git branch + the telemetry**.
  - **management CLI:** `status` · `inbox` (resume/`--after-fix`/abandon) · `config` · `pause`/`resume` ·
    `logs` · `uninstall`.
- **Upgrade:** replace the binary; `migrate()` self-applies schema migrations on next start.

## 4. Auth + config (re-thought for both audiences)

**Auth — TWO modes** (a change from the local-only "subscription session, never an API key"):
- **Subscription session** — local dev; cheapest for an individual; the OSS adoption hook.
- **`ANTHROPIC_API_KEY`** — **required for headless** (the GitHub Action, the cloud fleet): an interactive
  subscription session can't run unattended. The core must support both and pick by context.
- **Linear + GitHub creds** — the dev's own (OSS) or centrally managed/injected (SaaS).

**Config — now FOUR tiers** (the SaaS's primary control lever is the *per-ticket* tier):

| Tier | Holds | Set by |
|---|---|---|
| **per-ticket** `twinning_config` block (in the Linear ticket) | `max_loop_cycles`, `strictness`, `test_command`, `target_branch` | **the SaaS** (or a solo dev by hand) |
| workspace `config.json` (per project) | budgets, models, gates, checks-system | operator |
| project-profile | stack truth (build/test/tools/layout/kinds) | discovered; SaaS may auto-update |
| binary defaults | the cutover defaults (minimal-loop §4) | shipped |

Precedence: **ticket > workspace > profile > default**. The harness **reads the ticket's config block**
so the plane can set per-ticket budgets/strictness without touching the binary. The vision's
*N-cycles* and *strictness* map directly onto our **K_DISTINCT** and **review block-threshold**.

## 5. The open-core seam — stable contracts the plane plugs into `[BUILD THESE STABLE]`

The plane integrates *only* through these. Treat them as the public API surface (versioned, documented):

1. **Linear ticket contract (input).** The harness reads: the `twinning_config` metadata block, the AC
   checklist, the target-context-files list, and the `Ready for Agent` state as the trigger. (A solo dev
   writes these by hand *or* uses the harness's own design stage; the SaaS writes them automatically.)
2. **The profile artifact.** Canonical stack truth (`profile.md`). The plane reads/compacts/auto-updates
   it; the core reads it. Keep its schema stable.
3. **Telemetry / state (output).** The SQLite DB (readable) + a documented **telemetry export** — the
   metrics the dashboards need (cycle count, unit cost per ticket, autonomous-fix ratio, first-time CI
   pass rate, escalation reasons). Our `dispatch` / `metric_event` / `event_log` / `ground_truth_signal`
   already hold this data; expose it cleanly + emit a per-ticket terminal/JSON summary.
4. **(Later) a programmatic API.** The vision mentions "feeds into the harness API." At OSS cutover the
   artifact contracts (1–3) suffice; a thin REST/IPC API is a later addition for tighter coupling.

## 6. Implications to thread into the spec (flag, don't redesign now)

- **Pre-scoped tickets skip/short the design stage.** A SaaS-fed ticket already carries the plan
  (context-files + AC + config). The design phase then *validates + decomposes* rather than running full
  brainstorm+plan — a third track alongside fast/full (call it **pre-scoped**). Solo-dev rough ticket →
  full design; SaaS ticket → execute. (Extends C1/C2.)
- **Per-ticket budget/strictness** = the vision's N-cycles/strictness → our K_DISTINCT / block-threshold,
  sourced from the ticket config block (§4).
- **Headless runner mode** ⇒ the durable-execution model spans **ephemeral per-run SQLite** (runner) and
  the **persistent daemon DB** (local) — both must work; the journal semantics are identical, only the
  DB lifetime differs.
- **Telemetry is first-class**, not an afterthought — it's a paid-product input, so the per-ticket
  summary + the export schema get designed deliberately.

## 7. Status

Repo + no-vendor are **DECIDED**. The open-core boundary, run modes, dual-auth, and the four-tier config
follow from the commercial vision and are **proposed** here. The §6 implications are **flagged** for a
later spec pass (they touch C1/C2 and the durable-execution model). The §5 seam is the **build
priority** — get those three contracts stable early so the plane never has to fork the core.
