---
linear: ENG-27
title: Wire Playwright MCP into ui and qa stages
date: 2026-06-12
status: draft
---

# ENG-27 — Wire Playwright MCP into ui and qa stages

**Type:** `Feature` · **Subsystems touched:** dispatch (`bin/dispatch.sh`, new `mcp/playwright.json`) + agent prompts (`AGENT_PROMPTS.md` §4 / §6, new `{artifacts_dir}` resolver) + tests (subordinate) · **Status:** design draft

## 1. Overview

The ui and qa stage agents have no browser access today. They run `claude -p` with a fixed `--allowed-tools` list whose Bash patterns cover git, jq, awk, gh, and the harness's own helper scripts — nothing that drives a browser. So an agent verifying a frontend change can read source, run unit tests, and inspect the diff, but cannot prove that the rendered UI actually works end-to-end. The Anthropic harness-design articles cited in the issue describe browser-MCP-driven evaluation as the single largest observable quality lift for any UI-touching task: a verifier that has actually loaded the page and screenshotted it catches a class of regressions (broken routes, blank states, console errors) that no diff-based reviewer reaches.

This brainstorm proposes the harness-side wiring for that capability. Microsoft's `@playwright/mcp` server is added as an MCP child of the `claude -p` invocation **only when stage ∈ {ui, qa}** and the target opts in. The MCP server runs headless Chromium per dispatch, isolated context. The agent calls `mcp__playwright__*` tools to navigate and screenshot; screenshots persist under `$issue_dir/artifacts/` (outside the worktree, so the scope sweep does not see them); the stage summary references the screenshots by relative path so the operator can grep the per-issue state directory for visual evidence after a stage runs. The decision-set the issue ships pre-decided (use `@playwright/mcp@latest`, ui+qa only, MCP config at `$HARNESS_ROOT/mcp/playwright.json`, opt-out via `config.json::mcp.playwright.enabled = false` default true, headless chromium with viewport 1280x800, browser install at setup time) constrains the design surface significantly — this brainstorm fills in the load-bearing details those decisions did not specify and surfaces the tradeoffs at each composition site.

The change touches three subsystems (dispatch, agent prompts, tests) where tests are clearly subordinate to the dispatch wiring. Per CLAUDE.md's ticket-sizing rubric this lands at 2 subsystems with one subordinate → autonomy-safe; the scope boundary is explicit (no `init.sh` dev-server work, no visual regression diffing, no cross-browser, no auth-protected sites — all listed in the issue's Out-of-scope section).

## 2. Architecture

```
bin/run-stage.sh
  └─ render-prompt.sh
       ├─ {artifacts_dir} → $(issue_dir <issue>)/artifacts/        [NEW resolver]
       └─ append AGENT_PROMPTS.md §4 / §6 instructions to call
          mcp__playwright__* and persist screenshots under {artifacts_dir}/
  └─ mkdir -p $(issue_dir <issue>)/artifacts/                       [NEW pre-dispatch step]
  └─ dispatch.sh ui|qa
       └─ allowed_tools_for(stage)
            └─ if stage ∈ {ui,qa} and config.mcp.playwright.enabled != false:
                 append `mcp__playwright__*` to --allowed-tools     [NEW gate]
       └─ if stage ∈ {ui,qa} and config.mcp.playwright.enabled != false
              and NOT PIPELINE_DRY_RUN:
            cmd+=(--mcp-config "$HARNESS_ROOT/mcp/playwright.json") [NEW gate]
       └─ existing --add-dir "$issue_state_dir" already widens
          claude's sandbox so screenshots written to {artifacts_dir}/
          (which is inside $issue_state_dir) succeed without
          additional plumbing.
```

The MCP server runs as a child process of `claude -p` (per Claude CLI MCP semantics — `--mcp-config` causes the CLI to spawn each declared server via the server's `command` + `args`). For `@playwright/mcp`, that means `npx -y @playwright/mcp@latest <args>` runs per dispatch, the MCP server loads Chromium, the agent issues `mcp__playwright__*` tool calls, and the server terminates when `claude -p` exits. There is no harness-side process management for the MCP child.

The composition order in `bin/dispatch.sh::allowed_tools_for` becomes **base + profile-derived + extras + mcp** (left-to-right). Empty segments elide. The new MCP segment is added at the rightmost position because:

- It is computed from a separate config key (`config.mcp.playwright.enabled`) that is conceptually orthogonal to the existing tool composition tiers.
- Per the existing ENG-94 contract documented at `bin/dispatch.sh:557-572`, claude's matcher is order-insensitive — placement is for log readability only. Putting MCP last clusters the MCP-specific concern at one site without disturbing the well-understood ENG-94 ordering.

The single source of truth for the gate is `_dispatch_mcp_enabled_for(stage)` returning truthy iff stage ∈ {ui,qa} AND `config.json::mcp.playwright.enabled != false` (default true). Both the `--allowed-tools` MCP-wildcard append and the `--mcp-config` argv append read from the same helper, so it is impossible for the toolset to disagree with the config-file presence. This mirrors the ENG-94 contract for `_dispatch_tools_from_profile`: one helper, two callsites, deterministic agreement.

## 3. Decisions

Decisions 1–14 are listed in the Linear issue as "do not relitigate." The decisions below are the load-bearing details those did not specify.

### D-1. Place the MCP gate behind one helper, not two

**Decision.** Introduce `_dispatch_mcp_enabled_for(stage)` in `bin/dispatch.sh` that returns truthy iff stage ∈ {ui, qa} AND `config.json::mcp.playwright.enabled != false`. Both the `--allowed-tools` MCP-wildcard append and the `--mcp-config` argv splice gate on this single predicate. Profile-derived tools and operator-curated extras (`config.json::dispatch.tools.<stage>[]`) compose orthogonally per the ENG-94 left-to-right order; the MCP segment slots at the rightmost position.

**Rationale.** The architecture invariant we are preserving is *the toolset cannot diverge from the MCP config presence*. If `mcp__playwright__*` is in the allowed-tools list but `--mcp-config` is missing, the agent's tool calls fail at the MCP-resolver layer with a confusing "no such tool" error. If `--mcp-config` is passed but `mcp__playwright__*` is missing from the allowlist, the agent sees the server but cannot call it and produces sandbox denials. Both shapes are pure footguns. One helper, two callsites is the structurally simplest way to keep them in sync; the ENG-94 `_dispatch_tools_from_profile` precedent shows the harness already uses this pattern.

**Anchor.** CLAUDE.md "When wiring a new script" section: *"Per-stage allowed tool lists are centralized in `dispatch.sh::allowed_tools_for`. New stages must add a case there."* — extending the same chokepoint discipline to per-stage MCP toggles keeps the dispatch-time tool surface understandable from a single function.

**Rejected alternative.** Inline the gate at both callsites with duplicated `case "$stage" in ui|qa) ... esac` + `jq` reads. Rejected because (a) it duplicates the config-read shape (two jq invocations per dispatch instead of one), (b) it splits the invariant across two sites which a future maintainer can desync without noticing, (c) test surface doubles.

### D-2. Add `mcp__playwright__*` via wildcard, not enumerated tools

**Decision.** Use `mcp__playwright__*` as a single wildcard entry in the allowed-tools composition rather than enumerating individual tools like `mcp__playwright__browser_navigate`, `mcp__playwright__browser_take_screenshot`, etc.

**Rationale.** Issue decision #5 pre-decided wildcard. Verifying the rationale:

- The `@playwright/mcp` server's tool surface is the upstream's responsibility; pinning the harness's allowlist to a frozen enumeration creates a maintenance burden every time the upstream adds a tool.
- The "Tool allowlist & probing" preamble in CLAUDE.md warns about the allowlist-parser wildcard pitfall *specifically for Bash patterns* (`Bash(<prefix>:*)` literal-match). MCP tool names are NOT Bash patterns — they use the `mcp__<server>__<tool>` shape with `*` as a true glob at the tool-name boundary (verified by the existing harness pattern `Agent` tool allowlist and operator-curated extras for non-Bash tools — see `bin/dispatch.sh:549` where the `ui` stage already allow-lists the un-suffixed `Agent` tool literal). The Bash-pattern caveat does not apply here.

**Risk.** A future malicious `@playwright/mcp` release could ship a tool like `mcp__playwright__execute_shell` that escapes the browser sandbox. Mitigation: `npx -y @playwright/mcp@latest` floats at install time per issue decision #1; the operator inspects what gets installed via npm audit / lockfile review. Pinning to a specific version is a follow-up ticket the issue's Out-of-scope section implicitly defers.

**Rejected alternative.** Enumerated tools list (`mcp__playwright__browser_navigate, mcp__playwright__browser_take_screenshot, mcp__playwright__browser_click, ...`). Rejected: requires reading the live MCP server's tool list at this brainstorm-write time (the agent can read the server's runtime tool-emit but the brainstorm cannot), and creates an upstream-coupled maintenance task for every server release.

### D-3. Agent-passed screenshot paths, not per-dispatch templated MCP config

**Decision.** The MCP config file (`mcp/playwright.json`) is a static template checked into the harness repo. Each agent passes the screenshot output path via the `mcp__playwright__browser_take_screenshot` tool call's argument (`filename` or equivalent — the upstream tool name; the agent reads the canonical name from its tool-discovery output, not from this brainstorm). The agent's prompt instructs it to always pass `{artifacts_dir}/<descriptive-name>.png` (where `{artifacts_dir}` is the new resolver = `$(issue_dir <issue>)/artifacts/`).

**Rationale.** The alternative (generate `mcp/playwright.json` per-dispatch with the artifacts_dir templated into the server's `--output-dir` arg, if such an arg exists) adds an orchestrator-side `mktemp` + `jq` + cleanup dance every dispatch. The agent-discipline path costs one mandatory prompt instruction. Per CLAUDE.md "Doing tasks" guidance — *"Don't add features, refactor, or introduce abstractions beyond what the task requires"* — the templated path is a premature abstraction.

**Failure mode.** Agent forgets to pass `{artifacts_dir}` and screenshots land somewhere else (likely the agent's CWD, which is the per-issue worktree). Result: scope sweep (`partition_dirty_paths`, `bin/run-local-helpers.sh:562`) sees the `.png` files at the worktree root. For ui/qa stages, `stage_output_paths` falls through to the profile-derived `## File layout` list + always-include lockfile catalog; a `.png` at the root would be classified as `self-leak` and trip the per-issue halt path. **This is the correct failure mode**: the screenshot location discipline is enforced post-dispatch by the existing scope gate, no new gate needed. The agent's prompt should call this out so the failure mode is predictable.

**Rejected alternative.** Per-dispatch template of `mcp/playwright.json` with the artifacts_dir spliced in. Rejected for premature-abstraction reasons above; could be revisited if the agent-discipline failure mode shows up empirically.

### D-4. `{artifacts_dir}` as a new PROMPT_RESOLVERS entry

**Decision.** Add `artifacts_dir=_resolve_artifacts_dir` to `bin/render-prompt.sh::PROMPT_RESOLVERS` (line 40). Resolver returns `$(issue_dir <issue>)/artifacts/`. Bind `_RENDER_ARTIFACTS_DIR` in `main()` alongside the other `_RENDER_*` globals (around line 555). Add to `_write_rendered_paths_sidecar` (around line 97) so the post-dispatch sandbox-denial detective (ENG-156) can match denied paths against the contract surface.

`bin/run-stage.sh` (the per-issue dispatch driver) gains a `mkdir -p "$(issue_dir <ident>)/artifacts/"` line, sited alongside the existing per-issue mkdir surface near the dispatch invocation (around `bin/run-stage.sh:1800` where `PIPELINE_ISSUE_ID` is exported). This mirrors `bin/dispatch.sh:601` (`mkdir -p "$issue_state_dir"`) but lives at the run-stage layer because artifacts/ is a per-issue convention, not a dispatch-level invariant — keeping it next to other per-issue mkdir calls keeps the dispatch layer stack-and-feature-agnostic. The directory is empty when present; the agent populates it.

**Rationale.** The render-prompt resolver registry is the contract surface for prompt tokens; bypassing it (e.g. by hardcoding the path in the AGENT_PROMPTS.md body) would break the render-time unknown-token validator at `bin/render-prompt.sh:421` (which `die`s on unregistered tokens) and the ENG-156 sandbox-denial detective's contract-matching surface. Adding the resolver costs ~6 lines across `render-prompt.sh` and the sidecar writer; it is the canonical way to introduce a new path-shaped token.

**Anchor.** ENG-87 "Per-medium primitives" §: *"Prompt tokens → resolver registry + render-time validator"*. ENG-156 D-004: *"persist the map of path-shaped resolver tokens → resolved values to `$(issue_dir <issue>)/.rendered-paths-<stage>`"*. Both invariants force the registry path; ad-hoc string interpolation is structurally disallowed.

**Rejected alternative.** Hardcode `$HARNESS_STATE_DIR/<slug>/<issue>/artifacts/` in the AGENT_PROMPTS.md body. Rejected: render-prompt's resolver validator (`bin/render-prompt.sh:421`) dies on unregistered tokens, and absolute paths in prompts violate the multi-project isolation contract (`$HARNESS_STATE_DIR` is host-global; prompts must compose via the resolver-aware path helpers).

### D-5. PIPELINE_DRY_RUN short-circuits the MCP flags

**Decision.** The dry-run early-return at `bin/dispatch.sh:668-687` runs *before* the `cmd` argv build site. So the `--mcp-config` splice (gated on `_dispatch_mcp_enabled_for(stage)` AND `PIPELINE_DRY_RUN != 1`) is automatically skipped in dry-run mode. The allowed-tools-list MCP-wildcard append is *not* skipped — dry-run still echoes the full `--allowed-tools` argv so the test harness can grep for `mcp__playwright__*` presence on the ui/qa path. The asymmetry is the existing dry-run contract (it prints what would be invoked; it never claims the run actually happened).

**Rationale.** Issue decision #9 pre-decided this for `--mcp-config` (the agent never actually runs in dry-run, so no MCP child should spawn). The allowed-tools wildcard appearing in the dry-run argv echo is the test signal that the gate is wired; suppressing it in dry-run would hide regressions in the wiring smoke test.

**Anchor.** Existing dry-run shape at `bin/dispatch.sh:668-687`: dry-run logs the would-be argv but does not execute it. Spawning a Playwright MCP child in dry-run would (a) materialize npm cache state on disk, (b) load Chromium, (c) violate the "dry-run is side-effect-free" contract that operators rely on.

**Rejected alternative.** Skip both `--mcp-config` AND `mcp__playwright__*` in dry-run. Rejected: the wiring test (`bin/dispatch-test.sh` extension) wants to assert the allowed-tools shape includes the MCP wildcard on the ui/qa path; suppressing it in dry-run leaves the test no observable signal.

### D-6. Setup-time `playwright install chromium` via new `phase_playwright_install`

**Decision.** Add a new phase `playwright-install` to `bin/setup.sh::ALL_PHASES` (currently at line 723), slotted between `validate` (phase 11) and `launchd` (phase 12). The phase invokes `npx playwright install chromium` and fails loud (`die` with the install hint) if the install fails. `is_playwright_install_done` returns 0 iff `npx playwright install --dry-run chromium` exits 0 (the upstream `--dry-run` flag exits 0 when nothing would be downloaded, non-zero otherwise).

**Rationale.** Issue decision #6 pre-decided "Browser install during `bin/setup.sh` via `npx playwright install chromium`. Fail loudly if missing." The placement after `validate` (which checks shell tool presence + config-key shape) and before `launchd` (which the operator most-naturally treats as "kick the daemons on, we're done") matches the existing setup mental model. Per CLAUDE.md "Per-target dispatch.tools extras and profile-derived tools" pattern, setup-time onboarding is the canonical place to install host dependencies the dispatch path will assume present.

**Caveat for the harness-self target.** The harness has no UI; ui and qa stage prompts already document the no-UI pass-through path (AGENT_PROMPTS.md §4 line 1053: *"If the project has no frontend ... this stage is a pass-through"*). Per issue decision #12, the agent decides not to invoke browser tools when the profile's Stack section says so. But the setup phase still runs `npx playwright install chromium` even on the harness-self target — wasted disk (~250 MB) but no functional harm. Defensible because the same harness binary will drive ui-bearing targets next, and a conditional install based on the profile would couple setup to the profile-content-parse, adding complexity for a one-time disk cost.

**Rejected alternative.** Defer install to first-dispatch (lazy install). Rejected: shifts a ~30s download to the dispatch wall-clock budget, increases the chance of a `dispatch-timeout` halt for a transient network failure, and conflates "infrastructure missing" with "agent stuck" failure modes.

**Rejected alternative #2.** Make the install conditional on profile's Stack section containing "frontend" / "UI" / similar. Rejected: requires `bin/setup.sh::phase_playwright_install` to read and parse the profile, coupling setup to profile-content semantics. Profile reads today are dispatch-side only. The disk cost is ~250 MB once per host (chromium is host-global, shared across projects). Worth it.

### D-7. AGENT_PROMPTS.md instructions: browser verification as a per-stage gate, not a per-component checklist add-on

**Decision.** Update AGENT_PROMPTS.md §4 (UI) and §6 (QA) with two prompt-body insertions each:

- **UI (§4, after the existing "Per-component UX checklist" at line 1106):** Add a new MANDATORY block titled "Browser verification (per-route gate)". The block:
  - Lists the trigger predicate: "the profile's Stack section names a frontend layer AND the plan's Frontend Tasks are not 'N/A' AND your work touched at least one route or component".
  - Describes the workflow: start the dev server in the background per the profile's "Build & test gates" Integration/E2E command; wait for the URL to respond (HTTP 200 on a /); call `mcp__playwright__browser_navigate` to the entry route; call `mcp__playwright__browser_take_screenshot` and pass `{artifacts_dir}/ui-<route>-<state>.png`; repeat for each changed route × {default, loading-if-applicable, error-if-applicable} state.
  - Lists the failure shape: if the dev server fails to come up or the page returns a console error / network failure, halt with `verdict halt --reason smoke-failed`.
  - Reference screenshots from the stage-summary by relative path: `artifacts/ui-<route>-<state>.png` (so the operator's grep recipe — "find me the screenshot for ENG-N's ui dispatch" — resolves at the per-issue state dir).
- **QA (§6, between §3 "Coverage audit" and §4 "Regression-intent audit" at line 1620):** Add a new MANDATORY §3.5 "End-to-end verification (browser)". Same predicate (profile + plan + diff names a user-visible route); same workflow but scoped to "verify the acceptance criteria render as expected per the plan's Failure Mode → Test Map rows that name user-visible behavior". Screenshot persistence path identical.

**Rationale.** Per the issue's reference to *"the article reports browser-MCP-driven evaluation as the single biggest quality lift for any UI-touching task"* — the lift requires the agent be *told* to navigate and screenshot. Bolting the instruction onto the existing per-component UX checklist (which is an 8-item rubric scored per component) would conflate the rubric with the gate; the gate is a hard precondition, the checklist is a per-component quality score. Separating them keeps the rubric's meaning intact.

**Anchor.** ENG-77 "Stage summary file — overwrite-on-every-dispatch contract" preamble: stage-summary files are the durable record of what the dispatch did. Adding screenshot references to those files makes the visual evidence durable across loopbacks (review → implement re-runs see the prior ui dispatch's screenshots without re-running them).

**Failure mode if predicate misjudged.** Agent runs browser verification on a docs-only PR (no route changed). Cost: ~5s extra wall-clock (server start + one screenshot) and one .png file in `artifacts/`. Not a correctness issue; the prompt frames the predicate clearly enough that this is low-probability.

**Negative-signal contract.** Per D-10, the stage-summary MUST carry exactly one of three `Browser verification:` lines (performed / skipped / failed) regardless of which path the agent took — so the operator can grep completion comments for `Browser verification: skipped · reason=` and see how often each reason fires.

**Rejected alternative.** Make browser verification optional ("invoke if useful"). Rejected: the article's claim is that *forcing* the verifier to navigate is the quality lift; "optional" reproduces today's failure mode where the agent self-talks-through-correctness and never opens a browser.

### D-8. `PLAYWRIGHT_HEADFUL=1` runtime override → second checked-in config file

**Decision.** Two checked-in MCP config files: `mcp/playwright.json` (default, headless) and `mcp/playwright-headful.json` (headful sibling). The dispatch-time selector is a plain `if`:

```bash
local mcp_cfg="$HARNESS_ROOT/mcp/playwright.json"
[[ "${PLAYWRIGHT_HEADFUL-}" == "1" ]] && mcp_cfg="$HARNESS_ROOT/mcp/playwright-headful.json"
cmd+=(--mcp-config "$mcp_cfg")
```

No `mktemp`, no `jq`, no per-dispatch templating, no EXIT-trap-vs-MCP-child race. Both files are auditable in git; the operator running `PLAYWRIGHT_HEADFUL=1 bash bin/run-stage.sh ...` can read what the override actually changes by diffing the two files.

**Rationale.** Issue decision #10 pre-decided the override but did NOT specify the implementation mechanism. A second static file is structurally the simplest expression of "two modes, env var picks." It avoids: (a) adding a new mktemp+cleanup code path to `bin/dispatch.sh`, (b) the cleanup-ordering race the prior brainstorm draft flagged as OQ-3, (c) any scope expansion beyond issue decisions #4 (headless config) and #10 (override mechanism). Iteration 1 scope-persona-P0 forced this revision; the original per-dispatch-templating draft silently expanded scope beyond what decision #10 required.

**Anchor.** CLAUDE.md "Common commands" § already documents `PIPELINE_DRY_RUN=1` — a shell-set env var that flips orchestrator behavior. `PLAYWRIGHT_HEADFUL=1` mirrors that idiom. The "two static files, env-var-selected" pattern also matches `launchd/com.twinning.pipeline.plist.template` (template + render — but with rendering at setup time, not per-dispatch). Here both files are fully rendered upfront, simpler still.

**Rejected alternative.** Per-dispatch `mktemp` + `jq` rewrite of the static config (the iteration-1 draft). Rejected: cleanup-ordering race against the MCP child reading the config file, adds a new failure mode (`jq` exit + temp file detection), and is materially more complex than "second file." Scope-persona-iteration-1 correctly flagged this as scope expansion.

**Rejected alternative #2.** Bake both headless and headful into one static config; agent picks at tool-call time. Rejected: `@playwright/mcp` (per Microsoft's docs surface) sets headless via a server-start CLI arg, not a per-tool-call parameter — switching modes requires a server restart, which is mode-per-server-start, not mode-per-tool-call.

### D-9. Screenshot Linear-attachment path explicitly out of scope

**Decision.** This ticket does NOT add Linear-comment-attachment of screenshots. The stage-summary references screenshots by relative path under `artifacts/`; the operator looks them up locally under `$(issue_dir <issue>)/artifacts/`. A future follow-up ticket may extend `bin/linear.sh` with an attachment-upload subcommand and have the agent attach key screenshots to the completion comment, but that is structurally a different change (new `linear.sh` verb, new chokepoint discipline for binary uploads, new lane-fence rules for attachments).

**Rationale.** Iteration 1 product-persona-P0a flagged the operator UX gap: a Linear comment reference to `artifacts/ui-home-default.png` requires the operator to SSH-and-grep to see the actual evidence. The right answer to that gap is uploading to Linear — but doing it here would expand scope beyond the issue's explicit "Persist screenshot artifacts to `$issue_dir/artifacts/` and reference them from stage-summary." statement (issue body, Goal §3). The decision *explicitly* defers it rather than silently accepting the UX cost. Operators running ui/qa for the first time will see the cliff; the file path in the stage-summary at least tells them where to look. The follow-up ticket is the structural fix.

**Anchor.** Issue Goal §3 explicitly says "reference them from stage-summary" — file-path reference is the issue's spec. Issue Out-of-scope lists "Visual regression / pixel diff" but does not preclude Linear attachment; the brainstorm chooses to defer attachment to a follow-up because (a) it is multi-subsystem work (linear.sh + bin/dispatch / agent prompts + Linear attachment lifecycle), per CLAUDE.md's "Ticket sizing rubric — 3+ subsystems → split before filing."

**Rejected alternative.** Add `bash bin/linear.sh attach-image` here. Rejected: extends Linear write surface (new chokepoint shape: binary upload via `prepare_attachment_upload` + `create_attachment_from_upload`), new lane-fence logic for binary uploads (the agent's body-only marker injection assumes text content), and a new failure mode (Linear API attachment-upload rate-limit / size-limit). All three are independent design decisions; per the ticket-sizing rubric (CLAUDE.md), they belong in their own ticket.

**Cost flagged for follow-up.** A separate ticket should extend `bin/linear.sh` with an `attach-image <issue> <path> [--alt <text>]` subcommand and update AGENT_PROMPTS.md §4/§6 to attach the most-important screenshot per dispatch (e.g. one per route × default-state, capped at N=3) to the completion comment. That ticket inherits ENG-87's dispatch-id chokepoint contract for the attached-image comment's `<!-- meta: dispatch id=... -->` marker.

### D-10. Browser-verification negative-signal: stage-summary always carries a one-line outcome

**Decision.** Update AGENT_PROMPTS.md §4 and §6 so the stage-summary Notes section MUST carry exactly one of:

- `Browser verification: performed · routes=<list> · screenshots=<count> · path=artifacts/`
- `Browser verification: skipped · reason=<no-frontend|docs-only-diff|profile-no-e2e-command|no-route-changed>`
- `Browser verification: failed · reason=<dev-server-not-up|navigation-error|screenshot-error> · details=<one-line>`

The operator reading the Linear completion comment sees one of these lines unconditionally. "Performed" is the lift; "skipped" is the gate-fired-and-correctly-bypassed signal; "failed" is the halt path. There is no silent fourth case.

**Rationale.** Iteration 1 product-persona-P0b flagged that the original D-7 wording let the agent skip browser verification with no operator-visible signal — indistinguishable from the agent forgetting the gate exists. A required negative-signal line restores observability: the operator can grep the per-stage completion comments for `Browser verification: skipped · reason=` and see how often each reason fires, and a missing line on a ui/qa dispatch is itself a P0 protocol-violation (caught at brainstorm-review time or by a transcript detective in a future iteration).

**Anchor.** CLAUDE.md "Defense-in-depth" § says: *"prefer a transcript-based assertion ... over a post-dispatch state check."* This D-10 line is a stage-summary contract (text-based), not a transcript assertion — but it parallels the existing per-stage contracts (e.g. QA's `verdict-qa.json` schema with mandatory `dimensions[]`). The mechanism for enforcement in v1 is the AGENT_PROMPTS.md MANDATORY language + the persona-review gate at brainstorm/review time. A future iteration may add `bin/run-stage.sh::_validate_browser_verification` detective that greps the stage-summary file for the required line and halts with a new `browser-verification-missing` reason if absent.

**Rejected alternative.** Soft-prompt the agent ("please mention browser verification if you did it"). Rejected: the iteration-1 product-persona-P0b critique stands — soft pressure on a busy day produces silent skips. The MANDATORY framing + persona-review gate is the load-bearing mechanism.

**Rejected alternative #2.** Add the detective in this ticket. Rejected on scope (a new run-stage.sh detective is implementing-stage work that this brainstorm shouldn't pre-specify; the AGENT_PROMPTS.md MANDATORY contract + the stage-summary's existing chokepoint discipline is enough for v1).

## 4. Data Flow

```
1. Setup phase (one-time per host)
   bin/setup.sh <target> playwright-install
     └─ npx playwright install chromium
          └─ writes to ~/Library/Caches/ms-playwright/chromium-*/

2. Tick (every 5 min, ui or qa dispatch ready)
   bin/run-local.sh
     └─ bin/run-stage.sh ENG-N ui
          ├─ mkdir -p $(issue_dir ENG-N)/artifacts/                [NEW]
          ├─ render-prompt.sh ui ENG-N
          │     └─ {artifacts_dir} → $(issue_dir ENG-N)/artifacts/  [NEW resolver]
          │     └─ AGENT_PROMPTS.md §4 body emits MANDATORY browser-
          │        verification block referencing {artifacts_dir}
          └─ bin/dispatch.sh ui <prompt> <log>
                ├─ tools = base + profile + extras
                ├─ if _dispatch_mcp_enabled_for(ui):
                │     tools += "mcp__playwright__*"                 [NEW]
                ├─ (PIPELINE_DRY_RUN early-return short-circuits below)
                ├─ cmd = [env, gtime?, gtimeout, claude -p, ...,
                │         --add-dir $issue_state_dir,
                │         --setting-sources project,local,
                │         --disable-slash-commands,
                │         --disallowed-tools, --allowed-tools]
                ├─ if _dispatch_mcp_enabled_for(ui) and not DRY_RUN: [NEW]
                │     if PLAYWRIGHT_HEADFUL=1:
                │       cmd += [--mcp-config $HARNESS_ROOT/mcp/playwright-headful.json]
                │     else:
                │       cmd += [--mcp-config $HARNESS_ROOT/mcp/playwright.json]
                └─ exec claude -p
                     └─ MCP child: npx -y @playwright/mcp@latest [args]
                          └─ Chromium loads headless
                     └─ agent calls mcp__playwright__browser_navigate(url)
                     └─ agent calls mcp__playwright__browser_take_screenshot(
                          filename="$(issue_dir ENG-N)/artifacts/ui-home-default.png")

3. Post-dispatch sweep
   bin/run-local.sh::partition_dirty_paths
     └─ $issue_dir/artifacts/*.png is OUTSIDE the worktree
        → not visible to git status --porcelain
        → never enters partition_dirty_paths
        → no scope-check halt

4. Stage summary refers to screenshots by relative path
   stage-summary-ui.md notes section:
     "Verification screenshots: artifacts/ui-home-default.png,
      artifacts/ui-home-error.png"
   orchestrator posts the summary as completion/ui/ENG-N → Linear
   operator clicks comment, sees the relative paths, looks them up in
   $(issue_dir ENG-N)/artifacts/ via the worktree-resume helper.
```

## 5. Error Handling

| Failure | Detection | Effect |
|---|---|---|
| `mcp/playwright.json` absent at dispatch time when MCP enabled | `_dispatch_mcp_enabled_for(stage)` returns truthy but `[[ -f "$HARNESS_ROOT/mcp/playwright.json" ]]` fails | `die "dispatch: mcp/playwright.json missing; commit the file or set config.mcp.playwright.enabled=false"`. Hard fail because this is a setup-time invariant; silent fallback would mask a half-installed harness. |
| `npx -y @playwright/mcp@latest` fails to install / spawn (no network, npm down) | MCP child exits before agent's first tool call | Claude CLI surfaces the MCP child failure as a stream-json error event; agent's tool calls return errors. Agent halts with `verdict halt --reason agent-blocked` per existing protocol. Per-issue halt, not breaker trip. |
| Chromium binary missing at runtime (host wiped cache) | First `mcp__playwright__browser_navigate` call fails with "browser not installed" error from Playwright | Same as above — agent halts `agent-blocked`. Operator remediation: re-run `bash bin/setup.sh <target>` (the `playwright-install` phase is idempotent). |
| Agent forgets to pass `{artifacts_dir}/...` for screenshot path | Screenshot lands in agent CWD = per-issue worktree | Post-dispatch `partition_dirty_paths` sees `.png` at worktree root → classified as `self-leak` (NEW untracked path) → hard fail per `bin/run-local.sh` self-leak gate. This is the correct failure mode; the agent's prompt explicitly anchors the path. |
| Dev server fails to come up | Agent's HTTP probe (curl / wget against expected URL) returns non-200 within timeout | Agent halts with `verdict halt --reason smoke-failed` per AGENT_PROMPTS.md §4 block. Halt comment includes the dev-server log tail. |
| Multiple concurrent ui/qa dispatches (K=2) load multiple Chromium instances | Memory pressure observable via `bin/status.sh` resource baseline | Bounded by `orchestrator.max_concurrent_features` (default 2). Two Chromium processes ≈ 200-400 MB RSS — within laptop budget. If too high, operator drops `CLAUDE_MAX_CONCURRENT=1`. |
| `PLAYWRIGHT_HEADFUL=1` set but `mcp/playwright-headful.json` missing | `[[ -f ]]` check fails for the selected config path | `die "dispatch: mcp/playwright-headful.json missing despite PLAYWRIGHT_HEADFUL=1"`. Operator commits the file or unsets the env var. |
| Stale Chromium left over from prior crash | Visible as orphan `chromium` processes via `pgrep` | The MCP server's `--isolated` flag scopes browser context per-server-process. Orphan cleanup is a host-housekeeping concern, not a harness invariant. Document in operator-mental-model.md. |

The failure-taxonomy table at `docs/architecture.md#failure-taxonomy` does not need a new exit code — every browser-driven failure routes through existing `agent-blocked` (rc=20) or `smoke-failed` halt reasons. The `failure_outcome_for_exit` switch (`bin/common.sh`) is unchanged.

## 6. Edge Cases

- **Target without UI (harness-self).** Profile's Stack section says "no frontend" → agent's existing pass-through path (AGENT_PROMPTS.md §4 line 1053) fires before browser verification block. MCP server still spawns (`--mcp-config` was passed) but the agent makes zero `mcp__playwright__*` calls and exits cleanly. Wasted: ~1s startup, ~50 MB ephemeral RSS. Acceptable — the alternative (orchestrator decides whether to pass `--mcp-config` based on profile content) couples dispatch to profile semantics, which the ENG-94 / ENG-96 boundary explicitly avoids.

- **Stage transitions on the same issue (ui then qa).** Each dispatch is a fresh `claude -p` invocation per ENG-87 dispatch-id contract. Each gets a fresh MCP child. Screenshots from the ui dispatch accumulate under `$(issue_dir ENG-N)/artifacts/`; the qa dispatch's screenshots append (different filenames). The orchestrator's `_clear_current_stage_slots` (per CLAUDE.md "Cross-dispatch staleness contract") clears the *current stage's* stage-summary; other stages' files (including artifacts/) are preserved. So the qa agent can read the ui agent's screenshot collection if it wants (for cross-checking). No cleanup needed across the ui→qa transition.

- **Cross-dispatch persistence of artifacts/.** Unlike `.scratch/` (which `clean_scratch_residue` removes at tick end per `bin/run-local-helpers.sh:339`), `artifacts/` is not in the worktree — it lives at `$(issue_dir ENG-N)/artifacts/` which is sibling of the worktree. The tick-end cleanup never touches it. Artifacts persist for the full lifetime of the issue's state directory; they are removed only when `bin/cleanup-worktrees.sh` (or its successor) removes the entire `$(issue_dir ENG-N)`. This is intentional — the visual evidence trail outlasts individual dispatches.

- **PIPELINE_DRY_RUN=1.** Per D-5: `--mcp-config` skipped (no MCP child spawned), but `mcp__playwright__*` still appears in the dry-run echoed argv. Operator running a dry-run sees the would-be allowed-tools, can grep `mcp__playwright__\*` to confirm the gate fired.

- **Slack-host MCP servers from `~/.claude/mcp.json`.** The existing isolation flag `--setting-sources project,local` (per `bin/dispatch.sh:757`) already skips `~/.claude`. So operator-installed MCP servers don't leak in. Our `--mcp-config` is additive on top of that; no `--strict-mcp-config` needed.

- **First-run npm cache cold.** `npx -y @playwright/mcp@latest` downloads the package on first run. Subsequent runs hit the npm cache. Concern: the launchd plist's PATH includes Homebrew + system but not `$HOME/.npm` — but `npx` runs from Homebrew Node, which writes to `~/.npm` regardless of PATH. The first dispatch incurs ~10s download wall-clock; the dispatch timeout for ui/qa is 30 min, so this is comfortably within budget.

- **Floating `@latest`.** Issue decision #1 floats. A future @playwright/mcp release could break the wildcard tool surface or change config-arg shape. Mitigation: the dispatch wiring smoke test asserts a stable invariant (the `--mcp-config <path>` argv segment, the `mcp__playwright__*` allowlist entry); a wire break shows up at test time. Pinning to a specific version is a follow-up.

- **Adversarial filenames in agent-passed screenshot paths.** Agent could pass `filename=../../../etc/passwd.png`. The MCP server is supposed to constrain this; we are trusting the upstream. The damage surface is bounded by the agent's `--add-dir` widening — `$issue_state_dir` is the only writable path outside the worktree CWD, and the agent already has full read access there. So a path-traversal at the screenshot tool wouldn't grant new privileges. Document in security.md as a known trust boundary; flag for upstream review if `@playwright/mcp` doesn't constrain.

- **Dev-server start when profile names no dev-server command.** Agent should *not* attempt to start a server; per the AGENT_PROMPTS.md block, the predicate is "the profile names an Integration/E2E command". If absent, the browser verification block is skipped. The agent's prompt must explicitly model this fallthrough.

- **Headful mode on launchd host (no display).** `PLAYWRIGHT_HEADFUL=1` set on a headless server makes Playwright fail with "no DISPLAY". Operator's responsibility — the override is for local debug only; the launchd plist never sets it.

## 7. Open Questions

1. **Tool-name verification.** This brainstorm references `mcp__playwright__browser_navigate` and `mcp__playwright__browser_take_screenshot` as plausible names but does not verify them against the live `@playwright/mcp` server. The implementer should run the server once locally, inspect its tool-listing output (Claude CLI emits MCP tool catalogs on first connect), and update AGENT_PROMPTS.md with the exact tool names and required arguments. Wildcard `mcp__playwright__*` in the allowlist makes the harness-side wiring tool-name-agnostic; the prompt body is the only thing that needs verified names.

2. **`@playwright/mcp` args contract.** The brainstorm assumes the upstream supports `--headless`, `--browser chromium`, `--viewport-size 1280,800`, `--isolated` as CLI args (or equivalents). Need to verify against the upstream README. If the actual arg shape differs (e.g. config-file-only, no CLI args), the `mcp/playwright.json` shape adapts.

3. **Disk-cost telemetry for screenshots.** Each PNG is ~50-200 KB. A heavy ui dispatch could write 10-20 PNGs (~3 MB). Over an issue's lifecycle (10s of dispatches), an issue could accumulate ~50 MB under `artifacts/`. Issue decision #11 defers cost guards; flag for the P0b telemetry follow-up to also instrument artifact byte-counts.

4. **Test coverage of the per-target opt-out.** The wiring test (`bin/dispatch-test.sh` extension) should assert all four cells: stage ∈ {ui, qa} × `config.mcp.playwright.enabled` ∈ {missing, true, false} × `PIPELINE_DRY_RUN` ∈ {0, 1}. Missing-config defaults to true per issue decision #3; false fully suppresses; true with dry-run only suppresses `--mcp-config`.

5. **The `mcp__` allowlist grammar.** D-2 asserts `mcp__playwright__*` works as a wildcard. Verification deferred: the existing harness has zero `mcp__*` entries in any allowlist today (verified via grep over `bin/dispatch.sh`), so this is the first MCP entry the matcher will see. If claude's matcher does NOT treat `*` as a glob on the MCP-tool side, we fall back to an enumerated list (regenerated from a smoke-run against the live server). Implementer to verify before relying on the wildcard.

OQ-3 in iteration 1 (cleanup race for the per-dispatch `mktemp` template) is **resolved** by D-8's revision to a second checked-in config file. OQ-5 in iteration 1 (`--strict-mcp-config`) is **resolved** in §8 ADR-stress-test (not needed in v1; revisit if test surface shows MCP leak).

## 8. ADR stress test

This brainstorm puts pressure on three accepted architectural invariants. None require overturning; the cost is flagged:

- **ENG-87 dispatch-id contract.** The new MCP child process is a peer of `claude -p`, spawned under it. The MCP child does NOT post Linear comments — all Linear writes still flow through `bash bin/linear.sh` per ENG-87's chokepoint contract. Screenshots are filesystem artifacts; the only Linear surface they touch is the stage-summary's relative-path reference, which still routes through the chokepoint. **No ADR pressure.**

- **ENG-67 worktree-only dispatch.** Screenshots land in `$issue_dir/artifacts/`, OUTSIDE the worktree. The agent reaches this path via the existing `--add-dir "$issue_state_dir"` widening (ENG-155 D-001). **Cost flagged:** any future tightening of the `--add-dir` shape (e.g. restricting it to specific subdirs of `$issue_state_dir`) must explicitly preserve write access to `artifacts/`. Document the new constraint at `docs/architecture.md` post-implement.

- **ENG-94 profile-driven tools.** The MCP toolset (`mcp__playwright__*`) composes orthogonally to the profile-derived `Bash(...)` patterns. The composition order is **base + profile + extras + mcp**, with MCP at the rightmost position. **Cost flagged:** future maintainers reading `allowed_tools_for` will see four composition tiers instead of three. The brainstorm explicitly anchors the MCP tier at a separate config namespace (`config.mcp.playwright.enabled`) rather than reusing the profile's `## Tool allowlist` section — this is intentional (the profile section is for shell patterns; MCP wildcards are a structurally different surface). Document the divergence at `bin/dispatch.sh:526` (function header comment) when implementing.

- **ENG-48 isolation envelope.** The existing `--setting-sources project,local` flag (`bin/dispatch.sh:757`) skips `~/.claude` to prevent operator-installed plugins / MCP from leaking in. Our `--mcp-config <path>` is additive on top of this. **Confirmed safe:** the `<path>` is checked into the harness repo, auditable, and the `_dispatch_mcp_enabled_for` predicate is the single gate. No `--strict-mcp-config` needed in v1 (could be added if the test surface shows any leak; flagged as OQ-5).

## 9. Assumption Inventory

Every named symbol the brainstorm references, verified against the current code:

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A-1 | `bin/dispatch.sh::allowed_tools_for` is the chokepoint for per-stage tool composition; ui at line 549, qa at line 551. | **verified** | `bin/dispatch.sh:526-573` quoted in §1 of the file read; the `ui` and `qa` case arms are at lines 549 and 551. |
| A-2 | `bin/dispatch.sh::main` builds `cmd` argv via env→gtime→gtimeout→claude→flags between lines 724-761; isolation block at 756-761. | **verified** | `bin/dispatch.sh:724-761`. |
| A-3 | `bin/dispatch.sh:668-687` short-circuits in `PIPELINE_DRY_RUN=1` BEFORE the cmd argv build, so any post-668 splice never fires in dry-run. | **verified** | `bin/dispatch.sh:668-687`. |
| A-4 | `bin/dispatch.sh:753-755` adds `--add-dir "$issue_state_dir"` when `PIPELINE_ISSUE_ID` is set, widening claude's sandbox to the per-issue state dir (ENG-155). | **verified** | `bin/dispatch.sh:753-755`. |
| A-5 | `bin/common.sh::issue_dir` returns `$PROJECT_STATE_DIR/$issue`. | **verified** | `bin/common.sh:68-72`. |
| A-6 | `bin/render-prompt.sh::PROMPT_RESOLVERS` is a literal-string registry of token→resolver-fn pairs; render-time validator dies on unregistered tokens at line 421. | **verified** | `bin/render-prompt.sh:40-58` (registry) and `bin/render-prompt.sh:421` (validator quoted as `die "render-prompt: unknown token '$t' in source — register a resolver in PROMPT_RESOLVERS"`). |
| A-7 | `bin/render-prompt.sh::_write_rendered_paths_sidecar` enumerates path-shaped resolver tokens at lines 89-120 for the ENG-156 sandbox-denial detective; closed allowlist per D-004. | **verified** | `bin/render-prompt.sh:89-120`. |
| A-8 | `bin/setup.sh::ALL_PHASES` is the linear phase list at line 723; new phase added with corresponding `phase_<name>` and `is_<name>_done` functions. | **verified** | `bin/setup.sh:723-744`. |
| A-9 | `bin/run-local-helpers.sh::stage_output_paths` for ui/qa falls through to the implementing case at line 470, which reads the profile's `## File layout` section + always-include catalog. | **verified** | `bin/run-local-helpers.sh:459-498`. |
| A-10 | `AGENT_PROMPTS.md §4` (UI Agent) is at line 1048; §6 (QA Agent) is at line 1522; both bodies are fenced ``` blocks per render-prompt.sh's extraction contract. | **verified** | `AGENT_PROMPTS.md:1048,1522` (section headers); `bin/render-prompt.sh::lookup_section` reads them. |
| A-11 | `claude -p` accepts `--mcp-config <configs...>` as a CLI arg (space-separated paths or JSON strings); validated against `claude --help` output. | **verified** | `claude --help` output shows `--mcp-config <configs...>`. |
| A-12 | `--strict-mcp-config` is also a real CLI arg ("Only use MCP servers from --mcp-config, ignoring all other MCP configurations"). | **verified** | `claude --help` output. |
| A-13 | `@playwright/mcp` is the Microsoft-official package name, invokable via `npx -y @playwright/mcp@latest`. | **assumed** | Issue decision #1 asserts it; not verified against npm registry from the brainstorm. Implementer verifies at install time. |
| A-14 | `@playwright/mcp` tool names follow the `mcp__playwright__<tool>` convention claude-CLI applies to MCP servers. | **assumed** | Claude-CLI MCP-tool naming convention is standard but not version-pinned. Implementer verifies via dry-run server inspection. |
| A-15 | `npx playwright install chromium` is the canonical install command and `npx playwright install --dry-run chromium` exits 0 iff already installed. | **assumed** | Per upstream Playwright docs; verify against current Playwright version at implement time. |
| A-16 | `npx playwright install` writes to `~/Library/Caches/ms-playwright/` on macOS. | **assumed** | Per Playwright's default cache location for macOS; verify by inspection on the host. |
| A-17 | The `_dispatch_cleanup` EXIT trap at `bin/dispatch.sh:607` runs before exec exits — extending it to remove a `mktemp` file is safe. | **verified** | `bin/dispatch.sh:607` installs the trap pre-acquire; the trap fires on EXIT (set -e or normal). |
| A-18 | `bin/run-stage.sh:1800` exports `PIPELINE_ISSUE_ID` into dispatch.sh's environment, which is what gates the `--add-dir` and `issue_state_dir` resolution. | **verified** | `bin/run-stage.sh:1800-1802`. |
| A-19 | `partition_dirty_paths` (`bin/run-local-helpers.sh:562`) is the sweep that classifies new untracked paths; it operates on `git status --porcelain` output from the worktree, so files outside the worktree are invisible to it. | **verified** | `bin/run-local-helpers.sh:303-332` documents the visibility rule for `.scratch/` (gitignored) which is the same invisibility mechanism for paths-outside-worktree. |
| A-20 | The harness's `learned-rules/harness/project-profile.md` Stack section names no frontend — the harness has no UI, so the agent's pass-through path fires. | **verified** | Profile content quoted in the prompt addendum: *"Bash 3.2+ orchestration scripts ... The repo contains no application code"*. |

## 10. Simpler alternatives summary

Documented in §3 for each decision; collected here:

- **D-1 alternative**: inline the MCP gate at both callsites with duplicated jq+case. Rejected: duplicates the invariant.
- **D-2 alternative**: enumerated MCP tool list. Rejected: upstream-version coupling.
- **D-3 alternative**: per-dispatch templated MCP config. Rejected: premature abstraction; static + agent-discipline is simpler.
- **D-4 alternative**: hardcode artifacts path in AGENT_PROMPTS.md. Rejected: render-time validator dies on unregistered tokens.
- **D-5 alternative**: skip both `--mcp-config` AND `mcp__playwright__*` in dry-run. Rejected: removes test signal.
- **D-6 alternative**: lazy install at first-dispatch. Rejected: conflates infrastructure failure with agent failure.
- **D-6 alternative #2**: conditional install based on profile content. Rejected: couples setup to profile semantics.
- **D-7 alternative**: optional ("invoke if useful") browser verification. Rejected: defeats the article's quality-lift claim.
- **D-8 alternative** (iteration 1 draft): per-dispatch `mktemp`+`jq` rewriting of `mcp/playwright.json`. **Rejected in iteration 2** on scope-persona-P0 grounds: silently expanded scope beyond decision #10's "override via env var", added a cleanup-ordering race, materially more complex than a second checked-in config file.
- **D-8 alternative #2**: bake both headless/headful into one config, agent picks at tool-call time. Rejected: `@playwright/mcp` headless mode is set at server-start, not per-tool-call.
- **D-9 alternative**: extend `bin/linear.sh` with `attach-image` and post screenshots as Linear-comment attachments. Rejected on scope (3+ subsystem change per CLAUDE.md's ticket-sizing rubric); the operator-UX cliff is acknowledged and the cost is explicitly flagged for a follow-up ticket.
- **D-10 alternative**: soft-prompt the agent ("mention browser verification if you did it"). Rejected: soft pressure on a busy day produces silent skips; iteration-1 product-persona-P0b critique stands.
- **D-10 alternative #2**: add `bin/run-stage.sh::_validate_browser_verification` detective in this ticket. Rejected on scope (a new run-stage detective is implement-stage work).

## 11. Files likely to change (per AC #4 + verified)

- **New:** `mcp/playwright.json` at `$HARNESS_ROOT/mcp/playwright.json`. Static config (headless): `{"mcpServers": {"playwright": {"command": "npx", "args": ["-y", "@playwright/mcp@latest", <browser/headless/viewport/isolated args TBD by OQ-2>]}}}`.
- **New:** `mcp/playwright-headful.json` at `$HARNESS_ROOT/mcp/playwright-headful.json`. Static config (headful debug sibling, per D-8): same shape as `playwright.json` with the headless flag flipped.
- **`bin/dispatch.sh`** — (a) new `_dispatch_mcp_enabled_for(stage)` helper, (b) splice `mcp__playwright__*` in `allowed_tools_for()` for ui/qa when enabled, (c) splice `--mcp-config <path>` in `main()` between the isolation block and the close of `cmd`, gated on the predicate AND not-dry-run, (d) the path argument is `$HARNESS_ROOT/mcp/playwright-headful.json` when `PLAYWRIGHT_HEADFUL=1`, else `$HARNESS_ROOT/mcp/playwright.json` (per D-8 — no `mktemp`/`jq` rewrite needed).
- **`bin/setup.sh`** — (a) `phase_playwright_install` + `is_playwright_install_done` functions, (b) insert `playwright-install` into `ALL_PHASES` between `validate` and `launchd`.
- **`AGENT_PROMPTS.md`** — (a) update §4 (UI Agent) with the browser-verification MANDATORY block per D-7, (b) update §6 (QA Agent) with the §3.5 end-to-end-verification block per D-7. Both blocks use `{artifacts_dir}` token.
- **`bin/render-prompt.sh`** — (a) add `artifacts_dir=_resolve_artifacts_dir` to `PROMPT_RESOLVERS` (line 40), (b) implement `_resolve_artifacts_dir` to return `$(issue_dir "$issue_id")/artifacts/`, (c) bind `_RENDER_ARTIFACTS_DIR` in `main()` around line 555, (d) add `artifacts_dir` line to `_write_rendered_paths_sidecar` enumeration (around line 102).
- **`bin/run-stage.sh`** — `mkdir -p "$(issue_dir <ident>)/artifacts/"` before dispatch (sibling of the existing mkdir for `$issue_state_dir` at `bin/dispatch.sh:601`; doing it at run-stage avoids dispatch needing to know about artifacts/ as a directory shape).
- **New test:** extend `bin/dispatch-test.sh` (or new `bin/dispatch-playwright-test.sh`) with a smoke test asserting:
  - ui/qa + config absent/true → dry-run argv contains `mcp__playwright__*` in allowed-tools but NO `--mcp-config`.
  - ui/qa + config false → dry-run argv contains neither.
  - non-ui/non-qa stage + config true → dry-run argv contains neither.
  - ui/qa + config true + non-dry-run (via stubbed `claude` capturing argv) → both present.
- **(out of scope)** `docs/architecture.md` post-implement update flagged for the ADR-stress-test costs (ENG-67 add-dir constraint preservation, ENG-94 four-tier composition).

## 12. Persona review

Six personas ran in the canonical order (design → security → scope → coherence → product → feasibility). Final outcomes after iteration 2:

| Persona | Iter 1 | Iter 2 | Final P0 | Final P1 |
|---|---|---|---|---|
| design | PASS | (not re-run; PASS unchanged) | 0 | 3 |
| security | PASS | (not re-run; PASS unchanged) | 0 | 3 |
| scope | **FAIL** (1 P0) | PASS | 0 | 1 |
| coherence | PASS | (not re-run; PASS unchanged) | 0 | 4 |
| product | **FAIL** (2 P0) | PASS | 0 | 3 |
| feasibility | PASS (0 P0) | (not re-run; gating) | **0** | 2 |

**Gate verdict:** 6/6 PASS, feasibility 0 P0. Brainstorm-stage gate cleared. Proceeding to planning.

### Iteration 1 P0 findings (resolved in iter 2)

- **scope P0 — D-8 templating contradicted decisions #4/#10.** Resolved by D-8 revision: replaced per-dispatch `mktemp`+`jq` rewrite with a second checked-in static config file (`mcp/playwright-headful.json`). Resolution preserved the issue's "override via env var" semantic without introducing per-dispatch templating, cleanup-ordering races, or the new failure modes the iteration-1 draft would have shipped.
- **product P0a — operator never sees a screenshot without SSH-and-grep ritual.** Resolved by new D-9: explicitly defers Linear-attachment of screenshots to a follow-up ticket with rationale (3+ subsystem change per CLAUDE.md's ticket-sizing rubric). The deferral is named, not silent.
- **product P0b — agent-skipped-vs-agent-forgot invisible to operator.** Resolved by new D-10: stage-summary MUST carry exactly one of three structured `Browser verification: performed | skipped | failed · reason=<token>` lines. Operator can grep completion comments for skip/fail reason tokens.

### Iteration 2 P1 findings (logged for follow-up; not gating)

- **scope P1 (iter 2):** D-10 mandates a stage-summary line even on the no-UI pass-through path; issue decision #12 ("if no UI, agent decides not to invoke") didn't explicitly require an outcome line. Considered within the spirit of #14; flagged for the planning stage to confirm.
- **product P1 (iter 2) — D-9 follow-up not tracked.** No follow-up ticket identifier filed; deferral is in prose only. Planning stage should file the `linear.sh attach-image` follow-up ticket and reference it in the plan's acceptance criteria.
- **product P1 (iter 2) — D-10 reason-token granularity.** `profile-no-e2e-command` and a separate "no-dev-server-command" condition would collapse into one token. Planning stage should split or document the collapse.
- **product P1 (iter 2) — operator screenshot-lookup recipe absent.** `$(issue_dir ENG-N)/artifacts/` path resolves via project slug + issue id; the brainstorm names the path but not a one-line recipe. Planning stage may add `bin/status.sh` enhancement (or a runbook entry) to surface artifacts inline.
- **design P1s (iter 1):** composition-order documentation, D-3 self-leak halt blast radius, D-8 cleanup-race (D-8 P1 resolved by iter-2 revision).
- **security P1s (iter 1):** path-traversal trust delegated to upstream; `@latest` floating supply chain; quoting discipline on `PLAYWRIGHT_HEADFUL=1` path (D-8 P1 resolved by iter-2 revision — the second-file approach eliminates the `jq`+`mktemp` shell context).
- **coherence P1s (iter 1):** D-4 line-anchor cross-file conflation (FIXED in iter 2); ENG-94 subrange anchor; OQ-5 resolved-in-§8 (FIXED in iter 2 — OQs §7 updated); §6 stage-summary preservation justification.
- **feasibility P1s (iter 1):** `_RENDER_*` global binding site 14-line span; AGENT_PROMPTS.md:1620 phrasing off-by-one (within range).

Persona reports (full text) are not in-tree; they live in the dispatching agent's transcript at `$PROJECT_STATE_DIR/harness/logs/ENG-27-brainstorming-*.log` (the orchestrator's per-stage transcript captures sub-agent dispatches with full output, per ENG-156 / ENG-26 telemetry).
