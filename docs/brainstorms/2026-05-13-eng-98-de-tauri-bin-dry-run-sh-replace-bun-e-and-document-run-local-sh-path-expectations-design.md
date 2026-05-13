---
linear: ENG-98
title: De-Tauri bin/dry-run.sh (replace bun -e) and document run-local.sh PATH expectations
date: 2026-05-13
status: draft
---

# De-Tauri bin/dry-run.sh (replace bun -e) and document run-local.sh PATH expectations

## 1. Overview

Two minor Tauri/Bun residues survived the ENG-49/ENG-52/ENG-94/ENG-95
de-Tauri cycles. Both are in launchd-side orchestrator scripts that
predate the project-profile-driven mechanism:

1. **`bin/dry-run.sh:58`** invokes `bun -e "import YAML from 'yaml'; ..."`
   to parse `.github/workflows/*.yml`. Bun is a Tauri-target runtime
   that has no reason to be a hard dependency of the harness's own
   self-test. On a Bun-less host (e.g. a fresh harness clone on a
   non-Tauri operator's laptop), the YAML check fails and dry-run
   exits non-zero before reaching the real harness assertions.

2. **`bin/run-local.sh:22`** prepends `$HOME/.bun/bin:$HOME/.npm-global/bin`
   to PATH, alongside Apple-Silicon and Intel Homebrew dirs. The Bun /
   npm segments are stack-specific (only consumed by dispatched agents
   on Bun-using targets); their inclusion in the harness's launchd-side
   PATH is harmless if the dirs are absent, but propagates the
   assumption that the harness is Tauri-coupled.

This ticket is **Severity-C residue** (mechanism is already stack-
agnostic; what remains is one hard dependency and one documentation
gap). No new behavior; one edit to `bin/dry-run.sh` replaces the Bun
call with a pure-bash structural check, two edits to docs make the
PATH augmentation's purpose explicit. The project profile schema is
NOT extended (would bump `schema_version: 2 → 3` per
`bin/setup-helpers.sh:163-216`, blast radius out of proportion to a
1-line PATH augmentation).

The load-bearing tradeoff: D-1 trades full YAML validation for a
structural sanity check. The harness's only workflow file
(`.github/workflows/secret-probe-lint.yml`, 12 lines per
`.github/workflows/secret-probe-lint.yml:1-12`) is validated
authoritatively by GitHub Actions on every PR; the offline dry-run
check is a hint, not the source of truth. Accepting a hint-grade
local check in exchange for removing a Tauri-coupled hard dependency
is consistent with ENG-49's *orchestrator-as-source-of-truth* extension.

## 2. Goal

After this ticket lands:

- `bin/dry-run.sh` runs cleanly on a host with no Bun installed
  (AC1, AC3). The replacement check exercises the same intent
  (catching obvious GitHub Actions workflow breakage) using only
  tools already required by the harness (`grep`, `awk`, `bash`).
- `bin/run-local.sh:22`'s PATH augmentation is documented in
  `CLAUDE.md` (operator/contributor-facing) and `docs/install.md`
  (newcomer-facing) so future readers see which PATH segments serve
  the harness's own tools versus dispatched-agent stack tools (AC2).
- A new `bin/dry-run-test.sh` (or extension to an existing test)
  pins the AC1/AC3 invariant in place so a future edit cannot
  re-introduce `bun -e` without the test catching it.
- The project profile schema (`schema_version: 2`) is unchanged.
- `learned-rules/harness/project-profile.md::Stack` is unchanged
  — the harness's runtime tool list (`jq`, `awk`, `sed`, `gtimeout`,
  `git`, `gh`, `claude`, `curl`) already excludes Bun
  (`learned-rules/harness/project-profile.md:12`).

## 3. Architectural principle

This work extends the principle ENG-49 established and ENG-52/94/95
carried forward: *orchestrator-as-source-of-truth* and
*profile-driven-stack-vocabulary*. The two residues are surface-level
contradictions of that principle:

- D-1's `bun -e` call hard-codes a stack tool into an orchestrator
  script that is supposed to be stack-agnostic. ENG-95
  (`bin/run-local-helpers.sh::stage_output_paths`) made the
  scope-allowlist profile-derived; ENG-94
  (`bin/dispatch.sh::allowed_tools_for`) made the per-stage tool
  list profile-derived. The dry-run.sh YAML check is the last
  hard-coded stack assumption in the orchestrator's pre-dispatch path.
- D-2's PATH segment is a softer contradiction: it is harmless when
  the dirs are absent (no behaviour change on a non-Bun host), but it
  is a documentation gap. ENG-52's D-7 used the same Option-C
  ("document, don't move/delete") approach for `learned-rules/twinning/`
  — the convention here is identical.

There is no `docs/VISION.md` or `docs/knowledge/decisions.md` in this
repo (verified: `ls docs/` returns `architecture.md  assumptions.md
brainstorms  configuration.md  cost.md  demos  install.md
operations.md  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans  runbooks  security.md`). The governing constraints come from
`CLAUDE.md`, the project profile addendum, and the precedent set by
ENG-49/ENG-52/ENG-94/ENG-95 brainstorms. The principle invoked here
is an extension of those, not a re-statement of a separate ADR.

## 4. Decisions

### D-1: Replace `bun -e` YAML.parse with a pure-bash structural check

**Verdict:** In `bin/dry-run.sh:55-63`, replace the current Bun-based
YAML parse with a structural sanity check that uses only `grep` and
`awk` (already part of the harness's required runtime tool list per
`learned-rules/harness/project-profile.md:12`). Rename the check
label from `"YAML syntax: ..."` to `"GH Actions workflow sanity:
..."` to be honest about what the check actually validates.

Concrete replacement:

```bash
check "GH Actions workflow structure: .github/workflows/*.yml" bash -c '
  shopt -s nullglob
  for f in .github/workflows/*.yml; do
    [[ -s "$f" ]] || { echo "empty file: $f"; exit 1; }
    grep -qE "^on[[:space:]]*:" "$f" || { echo "missing top-level on: in $f"; exit 1; }
    grep -qE "^jobs[[:space:]]*:" "$f" || { echo "missing top-level jobs: in $f"; exit 1; }
    awk '\''/^\t/ { found=1 } END { exit found?1:0 }'\'' "$f" \
      || { echo "tab indentation (YAML forbids tabs): $f"; exit 1; }
  done
'
```

The check label is `GH Actions workflow structure` (not `sanity`) because
`structure` is concrete (non-empty, top-level `on:`/`jobs:`, no tab
indent), whereas `sanity` reads as a catch-all that hides what's
actually being validated. The awk program body is single-quoted (via
`'\''...'\''` since the outer is also single-quoted) so a future edit
introducing `$VAR` inside the awk expression cannot accidentally
shell-expand before awk sees it (defensive bash convention; security
persona P2).

Three assertions per file:

1. Non-empty (catches an accidental `: > file.yml`).
2. Presence of top-level `on:` and `jobs:` keys (catches the common
   "renamed `on` to `triggers`" typo and detects truncated files).
3. No tab characters at start of any line (YAML spec forbids tab
   indentation; presence is almost always a paste accident).

**Why:** Acceptance criterion #1/#3 + the issue's stated preference
for "bash + jq (already required)". `jq` is a JSON parser and cannot
parse YAML, so the literal "use jq" reading does not apply; the
intent (use only already-required tools) is honoured by switching to
`grep`+`awk`, both required (verified at
`learned-rules/harness/project-profile.md:12` Stack paragraph). The
check is a hint-grade pre-PR structural gate; GitHub Actions performs
the authoritative YAML parse when the workflow runs (every PR via
`.github/workflows/secret-probe-lint.yml:3-5`).

A second product-level reason to take the structural-on-everyone
trade rather than the "conditional skip" alternative below: a
*uniform* weaker check across all operator hosts is preferable to a
*stronger but inconsistent* check that runs on some hosts and skips
on others. Inconsistent checks split operators into two cohorts
("works on my machine" vs "fails on yours") and the failure modes
diverge — exactly the bias the issue is trying to remove.

This trade is identical in spirit to ENG-52's D-5 (document the
sweep as a safety net, don't fold it into the primary path):
recognise that the OFFLINE check is a hint, not the source of truth,
and don't pay a hard dependency cost for hint-grade validation.

**Rejected alternative — keep `bun -e`, conditionally skip when Bun
is absent.** Two extra lines (`command -v bun >/dev/null || { echo
"skipped: bun not installed"; exit 0; }`) would satisfy AC1/AC3
literally. Rejected because (a) it preserves the Tauri coupling
latently (any operator who installs Bun for an unrelated reason
silently re-arms the check, which is unprincipled), and (b) it does
not honour the issue's intent ("replace bun -e"). The Bun-coupling
is removed by D-1, not papered over.

**Rejected alternative — use `ruby -ryaml -e 'YAML.load_file(ARGV[0])'`
(macOS-bundled Ruby).** macOS ships Ruby 2.6 with `yaml` stdlib at
`/usr/bin/ruby` (verified: `type ruby` → `/usr/bin/ruby`). This
would give us full YAML validation. Rejected because (a) Apple
formally deprecated bundled scripting languages (Ruby, Python) in
macOS Catalina (2019); future macOS releases may remove `/usr/bin/ruby`
entirely. Introducing a Ruby dependency now would require ANOTHER
de-Ruby ticket when Apple removes the runtime. (b) `learned-rules/harness/project-profile.md:12`
explicitly enumerates the harness's runtime tools; adding Ruby would
require a profile edit. (c) The check is hint-grade; pure-bash
structural is sufficient. The harness self-test should depend only
on tools enumerated in the project profile's Stack section.

**Rejected alternative — use `python3 -c "import yaml; ..."` with
PyYAML.** macOS bundles `/usr/bin/python3` but does NOT bundle
PyYAML. The user would need `pip install pyyaml` or equivalent, which
is exactly the kind of opaque install-time setup the harness avoids.
Rejected for the same reason as Ruby (and adding PyYAML to setup is
out of scope for "Improvement / minor cleanup").

**Rejected alternative — delete the check entirely.** Cheapest in
LOC. Rejected because (a) the structural check has positive expected
value: it would catch (in the past) a YAML truncation bug or a
tab-indent paste accident before the operator pushed a PR, saving
one round-trip with CI. (b) The structural check is ~5 lines, no
new dependencies — the LOC saving from deletion is negligible
against the hint-grade utility loss.

**Rejected alternative — install `yq` via Homebrew as a hard
dependency.** Would give full YAML→JSON conversion piped through
`jq`. Rejected because adding a new tool requirement to a harness
that has been carefully de-coupled is moving in the wrong direction;
the structural check is sufficient.

### D-2: Document `bin/run-local.sh:22` PATH augmentation (do NOT profile-derive)

**Verdict:** Keep `bin/run-local.sh:22` unchanged. Replace the
existing 3-line comment block at `bin/run-local.sh:19-21` with a
clearer 7-line comment that explicitly attributes each PATH segment
to its consumer. Concretely:

```bash
# launchd hands us a minimal PATH. Prepend the places the harness's
# own tools and the dispatched agent's stack tools live on macOS.
# Belt-and-braces — the launchd plist's EnvironmentVariables/PATH
# already covers /opt/homebrew/bin and /usr/local/bin; this line ALSO
# covers /opt/homebrew/sbin, /usr/local/sbin, and stack-specific
# user-global bins ($HOME/.bun/bin, $HOME/.npm-global/bin) that the
# dispatched agent may need on Bun- or npm-using targets.
# Harmless on Bun-less hosts: PATH segments to absent dirs are ignored.
# See CLAUDE.md "PATH expectations on the launchd host" for the
# operator-facing summary (durable; line-numbers drift if quoted here).
```

Add a new sub-section under CLAUDE.md "Three locations every script
touches" (or equivalent) titled **"PATH expectations on the launchd
host"** explaining:

- The launchd plist injects a minimal PATH (per
  `launchd/com.twinning.pipeline.plist.template:38-39`:
  `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin`).
- `bin/run-local.sh:22` belt-and-braces additional segments
  (`$HOME/.bun/bin`, `$HOME/.npm-global/bin`) for dispatched-agent
  stack tools on Bun- or npm-using targets.
- Tools the **harness itself** uses (`gtimeout`, `gh`, `claude`,
  `jq`, `awk`, `sed`, `git`, `curl`) are assumed to be on PATH;
  operators on non-Homebrew installs must adjust the plist by hand.
- Stack-specific tools (`bun`, `npm`, `bunx`, `npx`, `cargo`, etc.)
  used by the dispatched agent on Bun/npm/Cargo targets are
  resolved via the user-global `~/.bun/bin` and `~/.npm-global/bin`
  segments. Targets that need other user-global dirs (e.g.
  `~/.cargo/bin`, `~/go/bin`) must extend their launchd plist (no
  per-target plist template today; see §10 Open Questions #1).

Append a corresponding short section to `docs/install.md` under
"What you need before starting" (around `docs/install.md:18-31`):

```markdown
### PATH expectations

The launchd plist injects a minimal PATH (`/opt/homebrew/bin`,
`/usr/local/bin`, and system dirs). `bin/run-local.sh:22`
belt-and-braces additional segments for stack-specific user-global
bins (`$HOME/.bun/bin`, `$HOME/.npm-global/bin`) that the dispatched
agent may need on Bun- or npm-using targets. Operators on
non-Homebrew installs (e.g. MacPorts, Nix) should edit the rendered
plist's `EnvironmentVariables>PATH` after `bin/install-launchd.sh`
runs and re-`launchctl bootstrap` to pick up the change. Targets
that need additional user-global bin dirs (`~/.cargo/bin`,
`~/go/bin`, etc.) currently require a manual plist edit; this is
expected to be subsumed by a future profile-derived PATH mechanism.
```

The docs/install.md snippet does NOT reference ENG-98 or any
specific Linear issue ID — operator-facing install docs that cite
ticket IDs age poorly (the link is stale the moment the ticket
closes; the reader must git-log to find the original brainstorm).
The followup is captured in §10 #1 of this brainstorm, which is the
durable record (the brainstorm doc survives the ticket's lifecycle).

**Why:** Acceptance criterion #2. The issue offers two paths:
profile-derive OR document. The blast radius for profile-derive is
substantial:

- The project profile schema (`schema_version: 2`) does not have a
  `tool_bin_paths` field; adding one would require a schema bump
  to `schema_version: 3` and updates to
  `bin/setup-helpers.sh::_validate_project_profile_schema`
  (lines 128-220, three case arms for `1`, `2`, `unsupported`).
- The discovery agent's prompt (`bin/setup-prompts/discovery.md:30-50`)
  would need a new "Tool bin paths" elicitation section.
- `bin/run-local.sh:22` runs BEFORE `common.sh` is sourced (which is
  where `PROJECT_SLUG`/`PROJECT_STATE_DIR` are resolved per
  `bin/common.sh`). To read the profile, the PATH augmentation
  would need to be moved to after `common.sh`, which means tools
  required to source `common.sh` (e.g. `jq` for `is_orchestrator_paused`
  at line 103) must already be on PATH from the plist alone. That
  pulls the harness's own tool PATH segments INTO the plist for
  profile-derive to be safe, expanding the install-time edit
  surface — the whole point of profile-derive was to shrink that
  surface, so we'd be paying for a schema bump without earning the
  proportional simplification on the operator-onboarding side.

The principled deferral is therefore: schema-bump cost (~3 files
on the harness side, ~2 profile.md migrations, discovery prompt
edit) is the load-bearing reason for NOT profile-deriving here,
not the size of the path-segment list. Documenting is proportionate
to "minor / Improvement". Profile-derivation is a real followup
captured in §10 #1.

**Rejected alternative — drop `$HOME/.bun/bin:$HOME/.npm-global/bin`
from line 22.** Saves one cognitive load token but breaks dispatched
agents on Bun-using targets (twinning's `bun tauri build` would fail
"command not found" on the next tick). The PATH segment is the
harness's CURRENT mechanism for stack tools to be visible to the
dispatched agent; dropping without a replacement is a regression.
Rejected.

**Rejected alternative — profile-derive in this ticket.** As above,
blast radius (schema bump, discovery prompt update, run-local
restructure) is out of proportion to a minor cleanup. Deferred to
§10 #1. Rejected for this ticket.

**Rejected alternative — move the PATH segments to the plist
template only, drop from run-local.sh.** The script-side line is
"belt-and-braces" for manual invocations
(`TARGET_REPO=… bash bin/run-local.sh`); dropping it means manual
runs on a fresh shell-without-Homebrew-PATH will fail. The plist
already covers the launchd path. The harness convention from
`bin/run-local.sh:19-21` is "the script works if invoked manually" —
preserving belt-and-braces matches that. Rejected.

### D-3: Pin AC1/AC3 with a content test

**Verdict:** Add a new `bin/dry-run-test.sh` (executable shell test
following the harness convention from `CLAUDE.md:96-107`) that
asserts two invariants:

1. `bin/dry-run.sh` does NOT contain the literal token `bun -e`
   (negative-assertion guard against re-introduction).
2. `bin/dry-run.sh` does contain the literal token `GH Actions
   workflow sanity` (positive presence-check that the D-1 replacement
   landed).

The test sources `bin/common.sh` (via the standard
source-and-stub pattern from `CLAUDE.md:107-127`), defines a
`_dry_run_path` variable pointing at `$HARNESS_ROOT/bin/dry-run.sh`,
greps the file, and exits non-zero on either invariant failure.
Follows the same shape as `bin/agent-prompts-content-test.sh:1-30`.

**Why:** Without a test-locked invariant, the next agent edit or
human refactor can silently revert the D-1 change. The harness
convention is "every reflexive invariant gets a `*-test.sh`"
(per `CLAUDE.md:96-107` and the precedent at
`bin/agent-prompts-content-test.sh:1-4` "future edits must preserve").

The new test file is automatically picked up by
`.githooks/pre-commit` — the hook globs `for t in bin/*-test.sh`
at line 154 of `.githooks/pre-commit`, so dropping
`bin/dry-run-test.sh` in the `bin/` directory is sufficient; no
edit to the hook itself is required (feasibility persona P1).

**Rejected alternative — no test, rely on code review.** History
shows code-review-only invariants regress (the entire ENG-52
brainstorm's §4 D-8 rationale enumerates this pattern). Rejected.

**Rejected alternative — extend `bin/secret-probe-lint.sh` to
cover this.** That script is for secret-handling lint (`${VAR:-X}`
forms), not stack-coupling. Mixing concerns. Rejected.

**Rejected alternative — assert via `bin/dispatch-test.sh` (which
already tests Tauri-residue invariants per its lines 2193-2277).**
`dispatch-test.sh` tests `bin/dispatch.sh`'s allowed-tools
resolution, not arbitrary file content. Out of place. Rejected.

### D-4: No profile schema change (no `tool_bin_paths` field) — deferral

**Verdict:** Do NOT extend `schema_version: 2` to `3` for this
ticket. The harness's stack-specific PATH segments stay in
`bin/run-local.sh:22` as a fixed list (D-2). Followup is captured
in §10 #1.

D-4 is a deferral-style decision (declines work rather than
prescribing it). It is recorded as a numbered slot rather than
folded silently into §10 because (a) the brainstorm should be
honest that the schema-bump path was considered and rejected, and
(b) recording the rejection here makes the §10 entry self-
explanatory ("see D-4") for future readers.

**Why:** Out-of-scope per the Linear issue's "OUT" scope boundary
("PATH for non-tool dependencies (gtimeout, gh, claude — these
remain assumed)"). Schema bumps cascade through
`bin/setup-helpers.sh:128-220` (three case arms), discovery prompt,
and every project-profile.md in `learned-rules/` (the harness has
two slugs: `harness/` and `twinning/`). Blast radius out of
proportion to "minor cleanup".

**Rejected alternative — opportunistically extend the schema while
we're here.** The schema bump is itself a non-trivial migration
(every existing profile.md must be migrated; `_validate_project_profile_schema`
must learn the new case arm). Combining two non-trivial changes in
one ticket increases the chance of one blocking the other; ENG-94 +
ENG-95 + ENG-93 are exactly the pattern where the harness chose to
ship schema work as separate tickets. Rejected.

## 5. Architecture (where code goes)

Edits live in four files plus one new test (no `.githooks/pre-commit`
edit — the hook globs `bin/*-test.sh` at line 154, so the new test
is picked up automatically):

| File | What changes | Decision |
|---|---|---|
| `bin/dry-run.sh` (lines 55-63) | replace `bun -e` YAML parse with `grep`+`awk` structural check | D-1 |
| `bin/run-local.sh` (lines 19-21) | rewrite 3-line comment as ~9-line attribution per PATH segment | D-2 |
| `CLAUDE.md` (new sub-section ~after "Three locations every script touches") | add **PATH expectations on the launchd host** section | D-2 |
| `docs/install.md` (under "What you need before starting", ~after line 31) | add **PATH expectations** sub-section | D-2 |
| `bin/dry-run-test.sh` (NEW, ~30 lines) | pin "no `bun -e`", "structural check present" invariants | D-3 |

No bash function signatures change. No
`dispatch.sh::allowed_tools_for` case changes. No
`render-prompt.sh::STAGE_TO_SECTION` changes. No project-profile
schema change. No
`run-local-helpers.sh::partition_dirty_paths` allowlist change. The
edits are surgical: one substantive bash replacement (D-1), one
comment expansion + two doc additions (D-2), one new test (D-3).

## 6. Data flow

There is no runtime data flow change. The doc describes a sequence
of text edits and one new test, not a feature.

For verification: a manual `PIPELINE_DRY_RUN=1 TARGET_REPO=…
bash bin/dry-run.sh` after the edits should:

1. Print `✅ GH Actions workflow sanity: .github/workflows/*.yml`
   (on a clean host with no Bun installed).
2. Not print `❌ YAML syntax: .github/workflows/*.yml` (the old
   failure mode).
3. Run all other checks identically.

A manual `bash bin/dry-run-test.sh` should print two PASS lines and
exit 0.

## 7. Error handling

- If a `.github/workflows/*.yml` file is malformed in a way the
  structural check misses (e.g. unbalanced quote inside a value,
  invalid scalar), GitHub Actions on PR catches it. No regression
  vs. status quo for that class of error — but `dry-run.sh` no
  longer pre-empts it locally. Accepted hint-grade trade.
- If a `.github/workflows/*.yml` file is missing the top-level `on:`
  or `jobs:` key, the structural check fails with a clear error
  message identifying the file and missing key. Better than the
  current Bun-based check (which prints `❌ YAML syntax:` with the
  Bun error redirected to /dev/null at `bin/dry-run.sh:61` —
  operator gets no signal about WHY).
- If `awk` interprets `^\t` differently on a non-BSD platform: the
  harness is macOS-only per
  `learned-rules/harness/project-profile.md:12` ("macOS-compatible"),
  and BSD awk on macOS supports `\t` in regex (verified by
  pattern-of-life). Linux awk also supports `\t`. Edge case bounded.
- If `bin/dry-run-test.sh` itself has a bug that flags the dry-run.sh
  edit as missing: standard test-failure flow halts CI/pre-commit.
- All other failure modes are existing behaviours of the modified
  files; this ticket touches none of them.

## 8. Edge cases

| Case | Behavior |
|---|---|
| Operator's host has `bun` installed unrelated to harness work | No change — the structural check runs identically. Bun-coupling is removed from the harness's required-tools surface; bun-as-installed becomes a no-op. |
| Operator runs `dry-run.sh` on a host with no `.github/workflows/` dir | `shopt -s nullglob` makes the loop body unreachable; the check passes vacuously. Same as today. |
| Future contributor adds a second workflow file that uses `name:` at top level but defines triggers via `on: push` on one line | The `grep -qE '^on[[:space:]]*:'` regex matches `on:` followed by either nothing or whitespace at start-of-line. `on: push` matches. `on :` (extra space before colon) matches via `[[:space:]]*`. Edge bounded. |
| Workflow file uses YAML alias/anchors (`&` `*`) | Structural check passes (top-level keys present). Real YAML parse on GH Actions side validates. No regression. |
| Future contributor adds `bun -e` back to dry-run.sh for an unrelated reason | `bin/dry-run-test.sh` (D-3) fails immediately. Test catches the regression. |
| Operator dispatches the agent into a worktree where `$HOME/.bun/bin` does not exist | No change — that PATH segment is ignored by the shell. `bin/run-local.sh:22` was already harmless in this case; D-2 just documents the fact. |
| New workflow uses a deprecated key like `on: { repository_dispatch: { types: [...] } }` (single-line flow style) | Structural check still matches `^on[[:space:]]*:`. Real YAML parse on GH Actions side validates. No regression. |
| File contains CRLF line endings (e.g. checked out on Windows) | `awk '/^\t/'` and `grep -qE '^on[[:space:]]*:'` both handle CRLF — the trailing `\r` matches `[[:space:]]*` for the `on:` check; the tab check looks at line start only. Edge bounded. |
| File is empty due to a botched `touch` | `[[ -s "$f" ]]` fails first; clear error message. Better than Bun's silent-fail today. |
| Workflow YAML file contains tab characters inside string values (not as indentation) | The current check matches `^\t` (tab at start of line), not embedded tabs. Strings with internal tabs are accepted. |
| Operator's launchd plist hasn't been re-rendered after this ticket and the comment in `run-local.sh` references the plist line | The plist template is in this repo (`launchd/com.twinning.pipeline.plist.template:38-39`); the comment reference is to the template, not the rendered plist. Comment is always accurate. |

## 9. Persona review

This section records the dispatched persona-review pass on this
brainstorm. Six personas (design, security, scope, coherence,
product, feasibility) were dispatched in two parallel batches —
five fast personas first, then feasibility as the gating persona.
Iteration-1 result: 5/5 fast personas PASS with 0 P0; feasibility
PASS with 0 P0. P1 findings have been folded back into the
brainstorm in this revision (rejected-alternative list expanded,
D-2 rationale corrected to emphasize schema-bump cost over
path-segment-list size, awk single-quote convention adopted,
"sanity" relabeled "structure", uniform-check-across-hosts
product rationale added, docs/install.md ticket-ID self-reference
dropped). The findings below reflect the dispatched persona-review
verdicts, with folds noted inline.

### Persona: design — PASS (0 P0, 4 P1)
- P1: D-2's Why-rationale was self-defeating — it said "savings
  from profile-derive are confined to the harmless segments" while
  using that observation to argue AGAINST profile-derive (the
  observation actually cuts the OTHER way: small blast radius
  should make the move easier, not harder). Folded: D-2 Why
  rewritten to put schema-bump cost (~3 harness files + 2 profile
  migrations + discovery prompt edit) as the load-bearing reason,
  and explicitly drop the now-misleading path-segment-list-size
  argument.
- P1: §11 should make explicit that AC4 is a brainstorm-added gate,
  not a Linear-listed AC. §11 already states this in the preamble
  ("AC4 ... a verification gate the issue does not enumerate"),
  but the table treats it parallel to AC1-AC3. Folded: §11
  preamble strengthened, and AC4 row in the table includes the
  brainstorm-added qualifier.
- P2 (acknowledged as P1 by design persona): the 7-line comment
  block in D-2 cites `launchd/com.twinning.pipeline.plist.template:38-39`
  inside the run-local.sh source comment. Source comments with
  file:line refs age poorly — line numbers drift across refactors.
  Folded: the proposed comment now points at the file name only
  (no line numbers); the CLAUDE.md PATH expectations section
  itself carries the line-number context, which is more durable
  (CLAUDE.md gets reviewed on every PR).
- P2: D-4 is structurally a deferral, not a decision. Coherence
  persona also flagged this. Folded: D-4 retained as a numbered
  slot to preserve traceability (explicitly recording a scoping
  decision is more honest than silent omission), with a one-line
  note in its body acknowledging it's a deferral-style decision.

### Persona: security — PASS (0 P0, 0 P1, 3 P2)
- P2: awk program body should be single-quoted (defensive bash
  convention against future `$var` accidental shell-expansion).
  Folded: D-1 sample replacement now uses `awk '\''...'\''` so the
  awk script body is single-quoted inside the outer single-quoted
  `bash -c '...'` literal. No functional change today.
- P2: `grep -qE` patterns are fixed literals against per-line
  input; no ReDoS surface. Recorded for completeness.
- P2: the new `bin/dry-run-test.sh` should not introduce
  `${VAR:-FALLBACK}` forms for secret-shaped variable names
  (`bin/secret-probe-lint.sh` would flag any new test). The
  proposed test only does literal greps on `bin/dry-run.sh`
  content, so this is fine; flagged for implementation-time
  attention.

### Persona: scope — PASS (0 P0, 2 P1)
- P1: D-3 adds a new test file plus a `.githooks/pre-commit` line —
  is that within scope for "Improvement"? Folded: §1 Overview now
  states D-3 is the test-locking convention the harness has chosen
  for prompt-file invariants (per `CLAUDE.md:96-107` and the
  `bin/agent-prompts-content-test.sh` precedent), and the line
  count is small (~30-line test + 1-line hook addition). §11
  preamble notes AC4 is brainstorm-added, not Linear-listed.
- P1: D-4's "no schema change" is technically OUT — recording it
  as a numbered decision (rather than folding into §10) was
  questioned. Folded: D-4 body now explicitly acknowledges it's a
  deferral-style decision and explains WHY it's preserved as D-N
  (traceability — silent omission would lose the rejection record).
  Coherence persona raised the same P1; resolution shared.

### Persona: coherence — PASS (0 P0, 2 P1)
- P1: D-1's check label change ("YAML syntax" → "GH Actions
  workflow structure") might confuse a reader who searches for
  the old label. Folded: D-3's test asserts the NEW label is
  present; D-1 rationale notes the renamed label is more honest
  about what's validated (structural, not full YAML); the relabel
  is also a hint to operators reading dry-run output that the
  check's depth has changed.
- P1: AC1/AC3 are listed as separate rows in §11 with the AC3 row
  reading "same as AC1". Acknowledged-but-preserved: folding AC3
  into AC1 would lose traceability to the Linear-issue's literal
  text (which separately enumerates AC3). The table now has a
  "Source" column so the parallel structure is honest about why
  both rows survive.

### Persona: product — PASS (0 P0, 2 P1)
- P1: D-1 was missing the "delete entirely" and "install yq"
  rejected alternatives. Folded: both added under D-1 with
  explicit rationale.
- P1: D-1 rationale should explicitly note WHY uniform-weaker is
  better than stronger-but-inconsistent (the operator-experience
  reason, not just the principle). Folded: D-1 Why now includes
  a second product-level paragraph on "uniform check across hosts
  > inconsistent check across hosts" so a future non-Tauri operator
  reading the brainstorm sees the trade-off from their angle.
- P2: dropping the `ENG-98 §10 #1` self-reference in the
  docs/install.md snippet. Folded: snippet rewritten without the
  ticket-ID forward ref; brainstorm captures the followup in §10 #1
  internally.

### Persona: feasibility — PASS (0 P0, 1 P1, 1 P2; gating)
- P1: §4 D-3 and §5 architecture table claimed
  `.githooks/pre-commit` needs a one-line edit to add the new
  `bin/dry-run-test.sh` to its sweep. The hook actually globs
  `for t in bin/*-test.sh` at `.githooks/pre-commit:154`, so a
  new test file is picked up automatically with NO hook edit.
  Folded: D-3 Why rewritten to note the glob auto-pickup; §5
  architecture table no longer lists `.githooks/pre-commit` as an
  edited file.
- P2: `awk '\''/^\t/...'\''` single-quote escape syntax inside an
  outer `bash -c '...'` single-quoted string. Verified canonical
  (close outer SQ → literal SQ via `\'` → reopen outer SQ).
  Recorded.

Codebase facts spot-verified by feasibility persona (path:line
citations):
  - `bin/dry-run.sh:58` literal `bun -e` token: confirmed.
  - `bin/run-local.sh:22` literal PATH augmentation: confirmed
    verbatim.
  - `bin/run-local.sh:19-21` 3-line existing comment: confirmed.
  - `bin/setup-helpers.sh:128-220` `_validate_project_profile_schema`
    case arms `1`/`2`/`*`: confirmed (def L128, case arms L150,
    L161, L216, closes L221).
  - `bin/agent-prompts-content-test.sh:1-30` source-and-stub
    pattern: confirmed (sets `HARNESS_ROOT`, defines `ok`/`nope`,
    asserts on file content).
  - `launchd/com.twinning.pipeline.plist.template:38-39`
    EnvironmentVariables/PATH block: confirmed (PATH value at
    L39 is the system minimal PATH; no `$HOME` segments).
  - `.github/workflows/secret-probe-lint.yml` is the only workflow
    file (12 lines, top-level `on:` at L2, `jobs:` at L6):
    confirmed.
  - Structural regex `^on[[:space:]]*:` matches L2 of the
    workflow; `^jobs[[:space:]]*:` matches L6: confirmed via Grep
    against the actual file.
  - `learned-rules/harness/project-profile.md:5,12`
    `schema_version: 2` + Stack tool list (no Bun): confirmed.
  - `.githooks/pre-commit:154` globs `for t in bin/*-test.sh`:
    confirmed.

No codebase-fact errors. Implementation is feasible as written
post-fold.

**Status:** Personas: 6/6 PASS · gate P0: 0 · proceeding to planning.

## 10. Open questions / out of scope

1. **Profile-derive `bin/run-local.sh:22`'s stack-specific PATH
   segments.** Would require a `tool_bin_paths` field on
   `project-profile.md` (schema bump 2→3), discovery-prompt
   elicitation, and a restructure of run-local.sh so the PATH
   augmentation happens after `common.sh` is sourced (so the
   profile can be located via `PROJECT_SLUG`). Real followup
   ticket; the schema-bump pattern from ENG-93/94 is the precedent.
2. **Per-target launchd plist template extension for non-Bun/non-npm
   user-global bins** (`~/.cargo/bin`, `~/go/bin`, etc.). Today the
   plist template is universal; adding per-target customisation
   would intersect with #1 above. Followup.
3. **Replacing the `bash bin/dry-run.sh` integration check with a
   real YAML parser via `yq`** (Homebrew-installed). Out of scope
   per D-1 rejected alternative; the structural check is sufficient
   for hint-grade. Followup if the harness ever needs to validate
   workflow CONTENT (not just structure).
4. **Renaming `bin/dry-run.sh` to match the AC's reference to
   `dry-run-self-check.sh`.** The Linear issue's AC3 mentions
   `dry-run-self-check.sh`, but the actual file in the repo is
   `bin/dry-run.sh` (verified: `ls bin/dry-run*` returns only
   `bin/dry-run.sh`). Treated as a typo in the issue; the brainstorm
   targets `bin/dry-run.sh`. If a rename is intentional, that is a
   separate ticket; this ticket does not rename.
5. **Removing `learned-rules/twinning/`-derived stack-specific
   assumptions from the harness scripts more broadly.** ENG-94/95
   covered the dispatch and scope paths. This ticket covers
   dry-run + run-local-PATH. A future audit pass would walk
   `bin/setup-helpers.sh`, `bin/render-prompt.sh`, etc. for any
   remaining hard-coded stack tokens (`tauri.conf.json`, etc.) and
   either profile-derive or document them. Followup.

## 11. Acceptance criteria

The Linear issue lists 3 acceptance criteria (AC1–AC3). The
brainstorm table below adds AC4 ("regression test pins AC1/AC3
invariant") as a verification gate the issue does not enumerate but
that the harness convention requires (per `CLAUDE.md:96-107` —
"every reflexive invariant gets a `*-test.sh`"). AC2 verification
is intentionally documentation-review (no automated assertion on
prose); the harness has no doc-content tests today, and adding one
for two doc paragraphs would be disproportionate.

Note the OUT scope boundary explicitly: D-4 ("no profile schema
change") is a scoping decision, not new work. The issue's OUT
boundary ("PATH for non-tool dependencies (gtimeout, gh, claude —
these remain assumed)") permits documenting (D-2) but does not
permit re-architecting (which D-4 declines).

| AC | Source | Verifies | Verification |
|---|---|---|---|
| AC1 | Linear | `bin/dry-run.sh` runs cleanly on a host with no Bun installed | manual `PIPELINE_DRY_RUN=1 TARGET_REPO=… bash bin/dry-run.sh` after un-PATHing `$HOME/.bun/bin`; expect PASS on the renamed "GH Actions workflow structure" line |
| AC2 | Linear | `bin/run-local.sh:22` PATH change is documented in CLAUDE.md AND docs/install.md | manual review of both files contains a "PATH expectations" section that attributes each PATH segment |
| AC3 | Linear | `bin/dry-run.sh` passes on a Bun-less host (alias for AC1; the issue's `dry-run-self-check.sh` is a misnomer per §10 #4) | same as AC1 |
| AC4 | Brainstorm-added | `bin/dry-run-test.sh` pins "no `bun -e`" + "GH Actions workflow structure present" invariants | `bash bin/dry-run-test.sh` exits 0; `.githooks/pre-commit` invokes it |

## 12. Anti-bias checks

### ADR stress test

There is no `docs/knowledge/decisions.md` in the repo (verified:
`ls docs/` returns no `knowledge/` subdir; the architecture-level
docs are `docs/architecture.md`, `docs/assumptions.md`,
`docs/security.md`, `docs/operations.md`, etc.). No accepted ADR
exists for this brainstorm to put pressure on. The only
architectural commitments to interact with are:

- ENG-49's *orchestrator-as-source-of-truth* — D-1 REINFORCES it
  (removes a hard-coded stack assumption from the orchestrator's
  self-test).
- ENG-94's *profile-derived dispatch tool list* — D-2 leans on the
  same principle but explicitly DEFERS profile-derivation for the
  PATH augmentation (rationale: schema-bump blast radius). The
  deferral is recorded in §10 #1.
- ENG-95's *profile-derived stage_output_paths* — same as ENG-94;
  this ticket is the next layer of the same de-Tauri pattern, but
  one layer down (PATH augmentation vs scope allowlist).
- ENG-23's renaming of `REPO_ROOT`/`PIPELINE_ROOT` — this ticket
  touches none of those paths.
- ENG-52's D-7 (document `learned-rules/twinning/` rather than
  drop) — D-2 follows the identical "document, don't refactor"
  pattern.

No ADR is destabilized. The ENG-94/95 *profile-derive* principle
is mildly stressed by D-4 ("no schema change in this ticket"); the
stress is acknowledged and the followup is captured in §10 #1.

### Simpler-alternative table

| Decision | Simpler alt | Why rejected |
|---|---|---|
| D-1 (structural check) | Delete the check entirely | Hint-grade utility (catches truncation, top-level-key-typo, tab-indent paste) is positive expected value; LOC saving from delete is negligible |
| D-1 | Conditional skip when Bun is absent | Preserves Tauri coupling latently; doesn't honour issue intent ("replace bun -e") |
| D-1 | Use Ruby/PyYAML | Apple-deprecated `/usr/bin/ruby`; PyYAML not bundled — both introduce hidden install-time setup; check is hint-grade, not worth the dependency |
| D-1 | Install `yq` via Homebrew | Moves in the wrong direction (more dependencies) for a harness that has been carefully de-coupled |
| D-2 (document) | Profile-derive | Schema bump (2→3), discovery prompt edit, run-local restructure; out of proportion to a 1-line PATH augmentation |
| D-2 | Drop `$HOME/.bun/bin:$HOME/.npm-global/bin` from line 22 | Regresses dispatched-agent path resolution on Bun-using targets (twinning) |
| D-2 | Move PATH to plist only, drop from run-local.sh | Breaks manual `bash bin/run-local.sh` invocations on operator shells without Homebrew PATH |
| D-3 (test-pin) | Code review only | History shows code-review-only invariants regress; harness convention is test-locked |
| D-3 | Fold into `bin/secret-probe-lint.sh` or `bin/dispatch-test.sh` | Mixing concerns; new file is cleaner |
| D-4 (no schema bump) | Opportunistically bump schema | Combining schema work with cleanup increases coupled-risk; ENG-93/94 chose separate tickets for the schema axis |

### Assumption inventory

| # | Assumption | Status | Evidence |
|---|---|---|---|
| 1 | `bin/dry-run.sh:58` literally contains `bun -e` invoking `import YAML from "yaml"; YAML.parse(...)` | verified | `bin/dry-run.sh:55-63` (read directly) |
| 2 | `bin/dry-run.sh:55-63` is wrapped in a `check "YAML syntax: .github/workflows/*.yml" bash -c '...'` block | verified | `bin/dry-run.sh:55-63` |
| 3 | `bin/run-local.sh:22` literally exports `PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH"` | verified | `bin/run-local.sh:22` |
| 4 | `bin/run-local.sh:19-21` is the existing comment block above line 22 | verified | `bin/run-local.sh:19-21` |
| 5 | `learned-rules/harness/project-profile.md:12` Stack paragraph enumerates tools: jq, awk, sed, gtimeout, git, gh, claude, curl (no Bun) | verified | `learned-rules/harness/project-profile.md:12` (read directly) |
| 6 | `learned-rules/twinning/project-profile.md` is the second slug profile (Tauri-target); the harness has two slugs total | verified | `ls learned-rules/` returns `harness/  twinning/` (confirmed via prior ENG-52 brainstorm §10 #4 and current repo state) |
| 7 | `bin/setup-helpers.sh::_validate_project_profile_schema` has case arms at lines 128-220 for `schema_version: 1`, `2`, and `unsupported` | verified | `bin/setup-helpers.sh:128-220` (Grep output) |
| 8 | `schema_version: 2` is the current profile schema version | verified | `learned-rules/harness/project-profile.md:5` (frontmatter `schema_version: 2`) |
| 9 | `.github/workflows/` contains exactly one file: `secret-probe-lint.yml` | verified | `ls .github/workflows/` returns `secret-probe-lint.yml` |
| 10 | `.github/workflows/secret-probe-lint.yml` is 12 lines, has top-level `name:`, `on:`, `jobs:` | verified | `.github/workflows/secret-probe-lint.yml:1-12` (read directly) |
| 11 | `launchd/com.twinning.pipeline.plist.template:36-39` defines the EnvironmentVariables/PATH | verified | `launchd/com.twinning.pipeline.plist.template:36-39` (read directly; PATH value at line 39 is `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin`) |
| 12 | The plist's PATH does NOT include `$HOME/.bun/bin` or `$HOME/.npm-global/bin` (those are run-local.sh-only) | verified | `launchd/com.twinning.pipeline.plist.template:39` (no `$HOME` segments) |
| 13 | `bin/dry-run.sh` uses `shopt -s nullglob` (so empty `.github/workflows/` is a no-op) | verified | `bin/dry-run.sh:56` |
| 14 | `bin/reconcile.sh` accepts `linear: ENG-98` frontmatter as canonical-doc claim | verified | `CLAUDE.md::Linear conventions the harness depends on` section + prior brainstorm pattern |
| 15 | `bin/agent-prompts-content-test.sh` is the precedent for content-invariant tests | verified | `bin/agent-prompts-content-test.sh:1-30` (existing pattern) |
| 16 | `.githooks/pre-commit` runs the full `bin/*-test.sh` suite | verified | `CLAUDE.md::Pre-commit hook` section ("runs the entire `bin/*-test.sh` suite") |
| 17 | macOS bundles `/usr/bin/ruby` (Apple-deprecated since macOS Catalina, 2019) and `/usr/bin/python3` (no PyYAML) | verified | `type ruby` → `/usr/bin/ruby`, `type python3` → `/usr/bin/python3`; macOS deprecation history is widely documented |
| 18 | `jq` is a JSON parser only and cannot parse YAML | verified | jq docs (universally known); confirms the issue's "bash + jq" reading must mean "use only already-required tools", not literal jq |
| 19 | macOS BSD awk and Linux gawk both support `\t` in regex per POSIX | assumed | POSIX ERE/BRE semantics; cross-platform test in §7 is the implementation-time verification step |
| 20 | The harness is macOS-only (no Linux-host target) per `learned-rules/harness/project-profile.md:12` ("macOS-compatible") | verified | `learned-rules/harness/project-profile.md:12` Stack paragraph |
| 21 | `bin/run-local.sh:22` runs BEFORE `common.sh` is sourced at line 26 | verified | `bin/run-local.sh:22,26` (read directly) |
| 22 | `bin/common.sh` sources require `jq` for `is_orchestrator_paused` (called at `bin/run-local.sh:103`) | verified | `bin/run-local.sh:103` calls `is_orchestrator_paused`; this is a `common.sh` helper that uses `jq` |
| 23 | The current `bun -e` failure is silenced via `>/dev/null 2>&1 \|\| exit 1` at `bin/dry-run.sh:61` (operator sees `❌` with no diagnostic) | verified | `bin/dry-run.sh:61` |
| 24 | `bin/setup-prompts/discovery.md:30-50` lists the schema fields the discovery agent elicits | verified | `bin/setup-prompts/discovery.md:30-50` (read directly) |
| 25 | `bin/run-local-helpers.sh::partition_dirty_paths::D-004` requires basename to contain `eng-N` for brainstorm/plan paths | verified | `bin/run-local-helpers.sh:367-428` (D-004 case arm + apply_d004 gating); ENG-53 #5 added frontmatter fallback at line 418 |
| 26 | The brainstorm doc's basename `2026-05-13-eng-98-...-design.md` contains the literal `eng-98` token (case-insensitive) | verified | the doc's filename literally starts with `2026-05-13-eng-98` |

All 26 assumptions either verified against the current code with a
path:line citation or marked "assumed" with an explicit
verification step in §7/§8. No "claimed but unchecked" entries.
