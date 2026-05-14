# Security & threat model

This document explains what the harness can do, what an attacker
controlling various inputs could do, and what's not yet hardened. For
the README summary, see
[Security and threat model](../README.md#security-and-threat-model).

> The harness is alpha and explicitly designed for **solo developers
> running on trusted hardware against their own projects**. If you're
> evaluating it for any harder threat model — multi-user hosts, shared
> infrastructure, untrusted contributors — **stop.** This is not the
> right tool yet.

## Trust boundary

The host machine is fully trusted. The harness runs as your user,
reads/writes your home directory, and operates a long-lived `claude`
subscription session. Anyone with shell access to the host can:

- Trigger arbitrary `claude -p` dispatches (subject to the global mutex).
- Read every secret in `$HARNESS_CONFIG_DIR` (mode `0600`, but readable
  by the same user).
- Write to `$TARGET_REPO` and push commits under the bot's GitHub
  identity.

There is no privilege separation between the harness and the operator
shell. If you don't trust the host, don't run the harness.

## What the bot has access to

| Resource | Scope | Lives at |
|---|---|---|
| Linear GraphQL | Full workspace (the personal API key is workspace-scoped) | `$HARNESS_CONFIG_DIR/secrets.env::LINEAR_API_KEY` |
| GitHub repo write | The bot user has the access you grant it (PR creation, branch push); recommend Code Owner-restricted main | `$HARNESS_CONFIG_DIR/secrets.env::GH_APP_ID` + `GH_APP_PRIVATE_KEY_PATH` |
| GitHub App | Per-repo Installation ID; permissions = Contents/PRs/Issues/Metadata | `$HARNESS_CONFIG_DIR/github-app.pem` (mode `0600`) |
| Claude subscription | Anonymous to the harness; the host's logged-in session is used | OS-level Claude credentials |
| Local filesystem | Anywhere your user can write — primarily `$TARGET_REPO`, `$HARNESS_STATE_DIR`, `$HARNESS_CONFIG_DIR` | — |
| Slack webhook (optional) | One channel; one-way (write only) | `$HARNESS_CONFIG_DIR/secrets.env::PIPELINE_SLACK_WEBHOOK_URL` |

## Attack surfaces

### A1. Linear issue body — prompt injection

**Threat**: A malicious issue body contains text that manipulates the
agent into doing something out-of-scope, exfiltrating data, or
producing a malicious PR.

**Reality today**: The harness reads Linear issue bodies as the
primary spec source. `bin/render-prompt.sh` includes the issue body in
the brainstorm and plan prompts. If you accept issues from untrusted
sources (e.g., an open Linear board), they can inject instructions.

**Mitigations in place**:
- **Scope-check post-stage**: dirty paths outside the per-stage
  allowlist trigger SEVERE halt → operator review.
- **Implement-stage transcript assertion**: agent invoking `gh pr create`
  is blocked at the dispatch level.
- **Allowed-tools list**: agents can only run a closed list of CLIs
  (no `curl`, no `nc`, no `wget` in any stage's base list).
- **Operator review of brainstorm + plan + PR**: every stage produces
  a docs-or-PR artifact before the next stage's agent sees it. A
  malicious brainstorm becomes visible to you before it costs more than
  one stage's worth of compute.

**Mitigations NOT in place**:
- No content-filtering on issue bodies.
- No detection of prompt-injection patterns.
- No "trust score" per issue author.

**Recommended posture**: file your own issues. Don't accept Linear
issue submissions from untrusted parties without reviewing each
brainstorm output before letting the planning stage proceed.

### A2. Compromised target dependency

**Threat**: A malicious dependency from any package ecosystem (cargo, bun, pip, go) in the target repo's
build runs in the agent's worktree, with full write access to that
worktree, the target's `.pipeline-config/`, and (transitively) the
host filesystem under your user.

**Reality today**: The agent runs your target's package-manager
commands (e.g. `cargo build`, `bun install`, `pip install`,
`go build`) with the worktree as CWD. Any post-install script in
any dependency executes in your shell context.

**Mitigations in place**:
- The worktree is per-issue, not the operator's main checkout (ENG-67
  invariant) — but the worktree shares the filesystem with everything
  else under your user.

**Mitigations NOT in place**:
- No supply-chain isolation. The agent's package-manager invocations
  (e.g. `cargo build`, `bun install`, `pip install`, `go build`)
  can run malicious build scripts.
- No sandbox / firejail / Docker isolation around dispatches.

**Recommended posture**: pin dependencies in the target repo. Audit
new dependencies before merging. Treat the harness as having the same
threat exposure as your normal local development environment — because
it does.

### A3. Compromised GitHub credential

**Threat**: An attacker steals the GitHub App private key
(`$HARNESS_CONFIG_DIR/github-app.pem`) and uses it to push to your
repos directly, bypassing the harness.

**Reality today**: The key is `chmod 0600`. Anyone who can read your
home directory as your user can copy it.

**Mitigations in place**:
- Branch protection on `main` requires PR review; the build agent's
  P2 gate requires a non-bot Code Owner approval.
- Post-merge CI runs (the harness doesn't disable them).

**Mitigations NOT in place**:
- The GitHub App permissions are write-broad (Contents: Read+Write).
  A scoped-down App that can only PUSH-NOT-FORCE-PUSH would be
  stronger.
- No detection of out-of-band pushes (the bot pushing without going
  through the harness).

**Recommended posture**: rotate the App private key periodically.
Watch the bot user's PR activity for surprises. Set up GitHub branch
protection ruleset that requires PRs (not direct pushes) for *all*
identities, including your bot.

### A4. Compromised Linear credential

**Threat**: An attacker steals `LINEAR_API_KEY` and uses it to
manipulate issues, comments, or labels in your Linear workspace.

**Reality today**: The key is `chmod 0600`. Linear personal API keys
are workspace-scoped — there's no per-project scoping available in
Linear's API.

**Mitigations in place**:
- The orchestrator only acts on issues in the configured project (via
  `linear-ids.json` cache). A compromised key has full workspace write
  but the harness itself won't act outside its configured project.

**Mitigations NOT in place**:
- A compromised key bypasses the harness entirely. The attacker can
  call Linear's API directly.

**Recommended posture**: rotate the Linear API key periodically.
Audit your Linear webhook log for unexpected API usage.

### A5. Misconfigured project pointer

**Threat**: An operator runs `setup.sh` against project A, then later
re-points the harness at project B without refreshing
`linear-ids.json`. The cache still contains project A's UUIDs, so
every Linear write goes to project A — possibly a different team's
workspace.

**Reality today**: `linear-ids.json` is regenerated only on explicit
`bash bin/linear.sh refresh-cache`. The orchestrator does not validate
the cache against the current `config.json::linear.project_id`.

**Mitigations in place**:
- `setup.sh validate` re-runs the cache build + sanity check.

**Mitigations NOT in place**:
- No automatic cache invalidation when `config.json` changes.
- No safety check that the cache and config agree before each
  dispatch.

**Recommended posture**: don't repoint the harness without running
`setup.sh validate`. If you must, run `bash bin/linear.sh refresh-cache`
explicitly.

### A6. Runaway cost loop

**Threat**: A bug causes the harness to re-dispatch the same stage
infinitely, burning subscription compute (or, on metered API,
literal money).

**Reality today**: The global breaker (3 consecutive failures →
`paused=true`) catches infrastructure failures but not "agent halts
itself successfully every tick." A halt-and-resume loop where each
halt is "successful" can in principle re-dispatch every 5 min.

**Mitigations in place**:
- Per-issue `.consecutive-failures` counter (ENG-69) — same issue
  failing N times in a row trips the per-issue circuit.
- Per-stage dispatch timeout (ENG-65) — bounds worst-case spend per
  dispatch.
- `external_signal_budget` (ENG-45) — bounded waits, eventual halt.

**Mitigations NOT in place**:
- No global cost rate limit. A bug that flaps "halt, resume, halt"
  every 5 min could burn through ~$5–$15/hour for a long time before
  per-issue counters trip.

**Recommended posture**: glance at `events.jsonl` periodically. The
retrospective surfaces this in its weekly PR. Set up a calendar
reminder to read those PRs.

### A7. State directory tampering

**Threat**: An attacker (or a buggy script) modifies
`$PROJECT_STATE_DIR/<ident>/issue-state.json` to lie about what stage
an issue is in or what policy applies.

**Reality today**: Files in `$PROJECT_STATE_DIR` are mode `0644`
(directories `0755`) by default. Any process running as your user can
read or write them.

**Mitigations in place**:
- `issue-state.json` includes a `pipeline_content_hash` (sha256 over
  `bin/**`, `config.json`, `AGENT_PROMPTS.md`) which is recomputed on
  every poll. If the hash differs from current, the policy decision
  is recomputed from scratch.
- Linear is the canonical source of `stage:*` labels; on-disk state
  is authoritative only for the failure-policy details.

**Mitigations NOT in place**:
- No HMAC or signature on state files.
- No tamper-detection.

**Recommended posture**: state files are local-only and survive tampering
relatively gracefully (the next tick recomputes from Linear). Don't
treat them as a security boundary.

## Secrets layout

```
$HARNESS_CONFIG_DIR/                 (mode 0700)
├── secrets.env                       (mode 0600)
│   ├── LINEAR_API_KEY               # Linear personal API key
│   ├── GH_APP_ID                    # GitHub App numeric ID
│   ├── GH_APP_PRIVATE_KEY_PATH      # absolute path to .pem
│   └── PIPELINE_SLACK_WEBHOOK_URL   # optional
└── github-app.pem                    (mode 0600)

$TARGET_REPO/.pipeline-config/
└── .env.local                        (gitignored, mode 0600)
    └── GH_APP_INSTALLATION_ID       # not secret, but per-target
```

- `secrets.env` is `chmod 0600`. `setup.sh` enforces this on write.
- `$HARNESS_CONFIG_DIR` itself is `chmod 0700`.
- `.pipeline-config/` is `.gitignore`d in target repos by convention,
  but the harness doesn't enforce this — verify in your target repo's
  `.gitignore` before committing.

## Hardening recommendations (post-alpha)

These are not implemented today, listed in priority order:

1. **Issue-author allowlist.** Configure which Linear issue authors
   trigger dispatch. Reject dispatches on issues filed by anyone
   outside the allowlist.
2. **Allowed-Linear-projects allowlist.** A configured list of project
   UUIDs the harness is allowed to act on. Validate against
   `linear-ids.json` cache and against the current dispatch's
   resolved IDs at dispatch time.
3. **Cost rate limit.** Per-hour and per-day caps on cumulative
   dispatch cost; exceeding the cap trips the breaker.
4. **GitHub App permission scoping.** Narrow Contents access from
   Read+Write to PR-only via a custom permission set. (Currently
   broader because the bot needs to create branches.)
5. **Worktree sandbox.** Run agent dispatches in `firejail` or a
   container with a read-only mount of `$HARNESS_CONFIG_DIR` and
   network restrictions.
6. **Tamper-detection on state files.** HMAC `issue-state.json` so a
   manual edit fails validation on the next tick.

If you have time and energy to contribute any of these, PRs welcome.
File a Linear issue first so the brainstorm agent can produce a spec.

## Incident response

If you suspect compromise:

1. **Immediately**: pause the orchestrator.
   ```bash
   jq '.orchestrator.paused = true' \
     "$TARGET_REPO/.pipeline-config/state.local.json" | \
     sponge "$TARGET_REPO/.pipeline-config/state.local.json"
   ```
2. **Rotate credentials**:
   - Linear: Settings → API → revoke and regenerate `LINEAR_API_KEY`.
     Update `$HARNESS_CONFIG_DIR/secrets.env`.
   - GitHub App: Apps → your App → Generate new private key.
     Replace `$HARNESS_CONFIG_DIR/github-app.pem`.
   - Slack webhook: Slack → app config → revoke and create new URL.
3. **Audit recent activity**:
   - Linear: Settings → API → review recent calls.
   - GitHub: bot user's recent activity feed; the bot's PR list.
   - Local: `$PROJECT_STATE_DIR/metrics/events.jsonl` for the last
     N hours; `bash bin/status.sh` for current state.
4. **Resume only after audit clean**.
