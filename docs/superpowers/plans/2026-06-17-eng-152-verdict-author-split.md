# ENG-152: Split agent self-claim from orchestrator verdict — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make only orchestrator-authored verdicts authoritative — agents emit an informational `stage-completion-claim`, the orchestrator emits/republishes `verdict … author=orchestrator`, and the reader trusts only the stamped form.

**Architecture:** Embed an `author=orchestrator` token *inside the marker body* (parsed by the existing generic `parse_pipeline_marker` — NOT Linear's comment-author field). Three layers: (1) **schema** registers a new `verdict_authors` enum + `author` attribute and a new `stage-completion-claim` event; (2) **writers** — every orchestrator verdict-emit site stamps `author=orchestrator` (hard-coded printfs append the token; the one CLI-driven site is auto-stamped by `cmd_event_verdict`), and a new `_orchestrator_republish_verdict` helper re-emits the agent's claim as an authoritative verdict on the pass/wait paths; (3) **reader** — `find_fresh_verdict`/`find_fresh_wait_verdict` reject any verdict lacking `author=orchestrator`, guarded by a **D-007 legacy fallback** so in-flight pre-cutover issues still flow.

**Tech Stack:** Bash 3.2 (host constraint), `jq`, the harness's own test harness (`bin/*-test.sh`, sourced with `PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key`), `bin/pipeline-events.json` registry + `bin/generate-vocabulary-doc.sh`.

## Global Constraints

- **Bash 3.2 compatibility.** Host `/bin/bash` is 3.2.57. No `local -A`, no `${var,,}`/`${var^^}`. Scope `local LC_ALL=C` around any `${var//pat/repl}` on multi-KB strings (UTF-8 substitution hang). [[bash32-utf8-substitution-hang]]
- **Land by hand, do NOT dispatch via the pipeline.** This rewrites the verdict protocol the running pipeline depends on — a self-hosting bootstrap hazard. Build on a branch off current `origin/main`, run the gate locally, open one PR, merge by hand, deploy. [[qa-payload-fix-is-eng203-not-prompt]]
- **No `add-or-update-comment`.** ENG-150 retired it. All Linear writes use `bash bin/linear.sh add-comment`.
- **Pre-commit gate must be green before every commit.** `bash .githooks/pre-commit` runs the full suite (~30s+); a red gate on main blocks all work. Confirm green on a clean main first. [[pre-commit-gate-red-blocks-agents]]
- **TDD.** Failing test first, minimal impl, green, commit. Frequent commits.
- **Marker shape (canonical):**
  - Agent: `<!-- pipeline: stage-completion-claim result=<r> stage=<s>[ target=<t>][ reason=<rsn>] -->`
  - Orchestrator: `<!-- pipeline: verdict result=<r> author=orchestrator[ stage=<s>][ target=<t>][ reason=<rsn>] -->`

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `bin/pipeline-events.json` | Closed-vocabulary registry | Add `verdict_authors` enum; flip `verdict` to orchestrator-lane + `author` required/registered; add `stage-completion-claim` event |
| `bin/pipeline.sh` | Event emit + validate | Dispatch new event; `cmd_event_verdict` die-on-agent + auto-stamp; new `cmd_event_stage_completion_claim` |
| `bin/verdict-handler.sh` | Authoritative reader | D-007 fallback + strict-author filter in `find_fresh_verdict` (both branches) + `find_fresh_wait_verdict`; stamp `_vh_protocol_violation` |
| `bin/run-stage.sh` | Orchestrator halt/wait writers + detective + republish | Stamp 8 printfs; add agent-verdict envelope assertion; add `_orchestrator_republish_verdict` + 2 wire-ins |
| `bin/classify-failure.sh` | Failure-classification halt writer | Stamp 1 printf |
| `AGENT_PROMPTS.md` | Stage agent instructions | Flip per-stage verdict emits → stage-completion-claim; rewrite §0 protocol preamble |
| `docs/pipeline-vocabulary.md` | Generated vocab doc | Regenerate from registry |
| `bin/pipeline-test.sh`, `bin/verdict-handler-test.sh`, `bin/run-stage-test.sh`, `bin/verdict-adversarial-test.sh`, `bin/agent-prompts-content-test.sh`, `bin/classify-failure-test.sh` | Tests | New fixtures + mechanical grep updates |

---

### Task 1: Schema — register `verdict_authors`, flip `verdict`, add `stage-completion-claim`

**Files:**
- Modify: `bin/pipeline-events.json` (top-level enums ~line 7; `verdict` event 97-135; insert new event after 135)
- Test: `bin/pipeline-test.sh`

**Interfaces:**
- Produces: `verdict` event with `writer_lane:"orchestrator"`, `required:["result","author"]`, `field_registry.author:"verdict_authors"`; new `stage-completion-claim` event with `writer_lane:"agent"`, `required:["result","stage"]`, **`field_registry_by_arm.pass.reason:"pass_reasons"`** (closes the ENG-191 `ship-with-deferred-majors` gap the old design predated).

- [ ] **Step 1: Write failing test** — append to `bin/pipeline-test.sh` (near the ENG-112 schema block):

```bash
# PE-152-1: verdict event is orchestrator-lane and requires author
ev="$(jq -c '.events.verdict.linear_comment' bin/pipeline-events.json)"
[[ "$(jq -r '.writer_lane' <<<"$ev")" == "orchestrator" ]] || { echo "FAIL PE-152-1 writer_lane"; exit 1; }
jq -e '.required | index("author")' <<<"$ev" >/dev/null || { echo "FAIL PE-152-1 required author"; exit 1; }
[[ "$(jq -r '.field_registry.author' <<<"$ev")" == "verdict_authors" ]] || { echo "FAIL PE-152-1 registry author"; exit 1; }
# PE-152-2: verdict_authors enum
jq -e '.verdict_authors == ["orchestrator"]' bin/pipeline-events.json >/dev/null || { echo "FAIL PE-152-2 enum"; exit 1; }
# PE-152-3: stage-completion-claim event exists, agent-lane, pass arm accepts pass_reasons
scc="$(jq -c '.events["stage-completion-claim"].linear_comment' bin/pipeline-events.json)"
[[ "$(jq -r '.writer_lane' <<<"$scc")" == "agent" ]] || { echo "FAIL PE-152-3 lane"; exit 1; }
jq -e '.required == ["result","stage"]' <<<"$scc" >/dev/null || { echo "FAIL PE-152-3 required"; exit 1; }
[[ "$(jq -r '.field_registry_by_arm.pass.reason' <<<"$scc")" == "pass_reasons" ]] || { echo "FAIL PE-152-3 pass-reason arm"; exit 1; }
echo "PASS PE-152-1..3"
```

- [ ] **Step 2: Run, verify FAIL** — `bash bin/pipeline-test.sh` → fails on PE-152-1 (`writer_lane == agent`).

- [ ] **Step 3: Edit `bin/pipeline-events.json`.** (a) After `verdict_results` array, add:
```json
  "verdict_authors": [
    "orchestrator"
  ],
```
(b) In `events.verdict.linear_comment`: set `"writer_lane": "orchestrator"`, `"required": ["result", "author"]`, update `body_shape` to include ` author=<author>` after `result=<result>`, and add `"author": "verdict_authors"` to `field_registry`. **Keep** the existing `field_registry_by_arm` (pass/fail/pivot) and `dedup_sig_by_arm`. (c) After the `verdict` event's closing brace, insert the `stage-completion-claim` event:
```json
    "stage-completion-claim": {
      "linear_comment": {
        "body_shape": "<!-- pipeline: stage-completion-claim result=<result> stage=<stage>[ target=<target>][ reason=<reason>] -->",
        "writer_lane": "agent",
        "required": ["result", "stage"],
        "required_by_arm": {
          "pass":  [],
          "fail":  ["target"],
          "halt":  ["reason"],
          "wait":  ["reason"],
          "pivot": ["target"]
        },
        "field_registry": {
          "result": "verdict_results",
          "stage":  "stages",
          "target": "fail_targets|pivot_targets",
          "reason": "halt_reasons|wait_reasons"
        },
        "field_registry_by_arm": {
          "fail":  { "reason": "fail_reasons" },
          "pass":  { "reason": "pass_reasons" },
          "pivot": { "target": "pivot_targets", "reason": "pivot_reasons" }
        },
        "dedup_sig_by_arm": {
          "pass": null, "fail": null, "halt": null, "wait": null, "pivot": null
        }
      }
    },
```

- [ ] **Step 4: Run, verify PASS** — `bash bin/pipeline-test.sh` → `PASS PE-152-1..3`; also confirm `jq . bin/pipeline-events.json >/dev/null` (valid JSON).

- [ ] **Step 5: Commit** — `git add bin/pipeline-events.json bin/pipeline-test.sh && git commit -m "feat(ENG-152): registry — verdict_authors enum, orchestrator-lane verdict, stage-completion-claim event"`

---

### Task 2: `pipeline.sh` — emit machinery

**Files:**
- Modify: `bin/pipeline.sh` (`cmd_event` dispatch ~69; `cmd_event_verdict` 266-306; insert `cmd_event_stage_completion_claim` after it)
- Test: `bin/pipeline-test.sh`

**Interfaces:**
- Consumes: registry from Task 1; `PIPELINE_WRITER` env (`agent` in dispatch subprocess, default `orchestrator`).
- Produces: `pipeline.sh event <issue> stage-completion-claim <result> [--stage…]`; `cmd_event_verdict` dies under `PIPELINE_WRITER=agent` and auto-adds `author=orchestrator`.

- [ ] **Step 1: Write failing test** — append to `bin/pipeline-test.sh`:

```bash
# PE-152-4: agent calling verdict dies with redirect message
out="$(PIPELINE_WRITER=agent PIPELINE_DRY_RUN=1 bash bin/pipeline.sh event ENG-1 verdict pass --stage qa 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"stage-completion-claim"* ]] || { echo "FAIL PE-152-4 (rc=$rc): $out"; exit 1; }
# PE-152-5: orchestrator verdict auto-stamps author=orchestrator
out="$(PIPELINE_WRITER=orchestrator PIPELINE_DRY_RUN=1 bash bin/pipeline.sh event ENG-1 verdict pass --stage qa 2>&1)"
[[ "$out" == *"author=orchestrator"* && "$out" == *"verdict result=pass"* ]] || { echo "FAIL PE-152-5: $out"; exit 1; }
# PE-152-6: agent stage-completion-claim renders, no author field
out="$(PIPELINE_WRITER=agent PIPELINE_DRY_RUN=1 bash bin/pipeline.sh event ENG-1 stage-completion-claim pass --stage qa 2>&1)"
[[ "$out" == *"stage-completion-claim result=pass"* && "$out" == *"stage=qa"* && "$out" != *"author="* ]] || { echo "FAIL PE-152-6: $out"; exit 1; }
echo "PASS PE-152-4..6"
```

- [ ] **Step 2: Run, verify FAIL** — `bash bin/pipeline-test.sh` (PE-152-4 fails: agent verdict currently only warns).

- [ ] **Step 3: Edit `bin/pipeline.sh`.** (a) In `cmd_event`'s `case`, add arm `stage-completion-claim) cmd_event_stage_completion_claim "$issue" "$@" ;;` and add it to the allowed-list in the `*)` die message. (b) In `cmd_event_verdict`, immediately after the usage guard, add the lane fence + auto-stamp:
```bash
  # ENG-152: verdict is the orchestrator-only lane. Agents emit stage-completion-claim.
  if [[ "${PIPELINE_WRITER:-orchestrator}" == "agent" ]]; then
    die "cmd_event_verdict invoked under PIPELINE_WRITER=agent — agents emit stage-completion-claim, not verdict. See AGENT_PROMPTS.md §0 Verdict-marker protocol."
  fi
```
Then, after the `args=(…)` array is built and before `_validate_event_payload`, add:
```bash
  args+=("author=orchestrator")
```
Remove the now-obsolete warning-only `if [[ "$PIPELINE_WRITER" != "agent" ]]; then log "warning: …verdict…"; fi` block (the lane meaning inverted). (c) Add the new function (mirror `cmd_event_verdict`'s arg-parse, but no author, warn if writer≠agent):
```bash
# cmd_event_stage_completion_claim <issue> <result> [--stage X] [--target Y] [--reason Z]
# ENG-152: agent self-claim lane. dispatch.sh sets PIPELINE_WRITER=agent.
cmd_event_stage_completion_claim() {
  local issue="$1"; shift
  local result="${1:-}"; shift || true
  [[ -n "$issue" && -n "$result" ]] || die "event stage-completion-claim: usage: <issue> <result> [args]"
  local stage="" target="" reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage)  stage="${2:-}"; shift 2 ;;
      --target) target="${2:-}"; shift 2 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      *) die "event stage-completion-claim: unknown flag '$1'" ;;
    esac
  done
  local args=("result=$result")
  [[ -n "$stage" ]]  && args+=("stage=$stage")
  [[ -n "$target" ]] && args+=("target=$target")
  [[ -n "$reason" ]] && args+=("reason=$reason")
  _validate_event_payload stage-completion-claim "$result" "${args[@]}"
  local body; body="$(_render_body stage-completion-claim "${args[@]}")"
  if [[ "${PIPELINE_WRITER:-orchestrator}" != "agent" ]]; then
    log "warning: PIPELINE_WRITER=${PIPELINE_WRITER:-orchestrator} writing a stage-completion-claim (lane mismatch — set PIPELINE_WRITER=agent to suppress)"
  fi
  if [[ "${PIPELINE_DRY_RUN:-}" == "1" ]]; then
    printf '[DRY_RUN] would post on %s: %s\n' "$issue" "$body" >&2; return 0
  fi
  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
}
```

- [ ] **Step 4: Run, verify PASS** — `bash bin/pipeline-test.sh` → `PASS PE-152-4..6` (and PE-152-1..3 still pass).

- [ ] **Step 5: Commit** — `git add bin/pipeline.sh bin/pipeline-test.sh && git commit -m "feat(ENG-152): pipeline.sh — verdict lane-fence + author auto-stamp, cmd_event_stage_completion_claim"`

---

### Task 3: `verdict-handler.sh` — strict-author reader with D-007 fallback

**Files:**
- Modify: `bin/verdict-handler.sh` (`_vh_protocol_violation` ~52-56; `find_fresh_verdict` 156-252; `find_fresh_wait_verdict`)
- Test: `bin/verdict-handler-test.sh`

**Interfaces:**
- Consumes: `parse_pipeline_marker` JSON now carries `.author` for stamped verdicts.
- Produces: `find_fresh_verdict` ignores `stage-completion-claim` and any `verdict` lacking `author=orchestrator` — **but only when strict mode is engaged** (a claim marker OR any `author=` verdict exists on the issue); else legacy behavior.

- [ ] **Step 1: Write failing test** — append to `bin/verdict-handler-test.sh` (use the file's existing comment-fixture stub pattern for `linear.sh get-comments`):

```bash
# ENG-152-A: agent self-claim + orchestrator verdict in same dispatch → orchestrator wins
# Fixture comments (current dispatch id ENG-9-d0001): an agent stage-completion-claim pass,
# then an orchestrator verdict pass author=orchestrator. Reader must return the verdict, not the claim.
# (Build the get-comments stub to emit both, each with <!-- meta: dispatch id=ENG-9-d0001 … -->.)
fresh="$(find_fresh_verdict ENG-9)"
[[ "$(jq -r '.event.author' <<<"$fresh")" == "orchestrator" ]] || { echo "FAIL ENG-152-A author"; exit 1; }
[[ "$(jq -r '.marker' <<<"$fresh")" == "pipeline-stage-summary" ]] || { echo "FAIL ENG-152-A marker"; exit 1; }
# ENG-152-B: ONLY an agent claim present (no orchestrator verdict) → reader returns empty (claim never authoritative)
fresh="$(find_fresh_verdict ENG-10)"
[[ -z "$fresh" ]] || { echo "FAIL ENG-152-B: claim leaked as verdict: $fresh"; exit 1; }
# ENG-152-C: D-007 legacy — only an UNSTAMPED verdict, no claim markers anywhere → still accepted
fresh="$(find_fresh_verdict ENG-11)"
[[ "$(jq -r '.marker' <<<"$fresh")" == "pipeline-stage-summary" ]] || { echo "FAIL ENG-152-C legacy fallback"; exit 1; }
echo "PASS ENG-152-A..C"
```
(Construct three `get-comments` fixtures per the test file's existing stubbing convention — ENG-9 = claim + stamped verdict; ENG-10 = claim only; ENG-11 = bare `verdict result=pass stage=qa` with a transition before it, no `author=`, no claim marker.)

- [ ] **Step 2: Run, verify FAIL** — `bash bin/verdict-handler-test.sh` (ENG-152-B fails: the claim is parsed as `event != verdict` already, so actually verify B passes for the right reason and A/C drive the change; if A already returns the claim because claims aren't `verdict` events, the failing assertion is C's fallback + A's author requirement once strict mode added).

- [ ] **Step 3: Edit `bin/verdict-handler.sh`.** (a) `_vh_protocol_violation` (line 55): change the printf body to `<!-- pipeline: verdict result=halt author=orchestrator reason=protocol-violation -->` (keep the existing `add-comment` call at line 56). (b) In `find_fresh_verdict`, after `_has_any_marker` is computed and before `local fresh_ts=""`, add the D-007 gate:
```bash
  # ENG-152: D-007 fallback. Strict-author mode engages when EITHER a
  # stage-completion-claim marker exists OR any author= verdict already
  # exists. Legacy issues (neither) fall through to the unstamped path.
  local _strict_author=0
  if grep -qF '<!-- pipeline: stage-completion-claim ' <<<"$comments" \
     || grep -qE '<!-- pipeline: verdict [^>]*author=' <<<"$comments"; then
    _strict_author=1
  fi
```
Then in **both** verdict-selection loops (the strict-id branch ~line 199 and the legacy-timestamp branch ~line 240), immediately after the `[[ … .result == "wait" ]] && continue` line, add:
```bash
      if (( _strict_author == 1 )); then
        [[ "$(jq -r '.author // ""' <<<"$ev")" != "orchestrator" ]] && continue
      fi
```
(c) Apply the same `_strict_author` computation + filter inside `find_fresh_wait_verdict`'s verdict loop.

- [ ] **Step 4: Run, verify PASS** — `bash bin/verdict-handler-test.sh` → `PASS ENG-152-A..C` plus all pre-existing cases green.

- [ ] **Step 5: Commit** — `git add bin/verdict-handler.sh bin/verdict-handler-test.sh && git commit -m "feat(ENG-152): verdict-handler strict-author filter + D-007 legacy fallback"`

---

### Task 4: Stamp all hard-coded orchestrator halt printfs

**Files:**
- Modify: `bin/run-stage.sh` (lines 773, 1125, 1290, 1391, 1433, 1473, 2147, 2726), `bin/classify-failure.sh` (177). (`verdict-handler.sh:55` already done in Task 3; `run-stage.sh:1674` dynamic site already auto-stamped by Task 2.)
- Test: `bin/run-stage-test.sh`, `bin/verdict-adversarial-test.sh`, `bin/classify-failure-test.sh`

**Interfaces:**
- Produces: every orchestrator-authored verdict body on disk carries ` author=orchestrator` between `result=halt` and `reason=`.

- [ ] **Step 1: Write failing test** — append to `bin/run-stage-test.sh`:
```bash
# ENG-152-STAMP: no orchestrator verdict printf may omit author=orchestrator
bad="$(grep -nE "pipeline: verdict result=(halt|pass|fail|wait)" bin/run-stage.sh bin/classify-failure.sh bin/verdict-handler.sh \
  | grep -v "author=orchestrator" | grep -v "stage-completion-claim" || true)"
[[ -z "$bad" ]] || { echo "FAIL ENG-152-STAMP unstamped verdict printf(s):"; echo "$bad"; exit 1; }
echo "PASS ENG-152-STAMP"
```

- [ ] **Step 2: Run, verify FAIL** — `bash bin/run-stage-test.sh` lists the 8 run-stage + 1 classify unstamped lines.

- [ ] **Step 3: Edit each printf.** For each listed site, insert ` author=orchestrator` immediately after `result=halt` (e.g. `result=halt reason=scope-violation` → `result=halt author=orchestrator reason=scope-violation`). The 9 sites: `run-stage.sh` 773, 1125, 1290, 1391, 1433, 1473, 2147, 2726; `classify-failure.sh` 177. Use exact-string Edits per line (the printf format strings are unique).

- [ ] **Step 4: Run, verify PASS** — `bash bin/run-stage-test.sh` → `PASS ENG-152-STAMP`. Also re-run `bin/verdict-adversarial-test.sh` and `bin/classify-failure-test.sh`; fix any grep-anchor assertions that pinned the old unstamped body (mechanical: add `author=orchestrator` to the expected string).

- [ ] **Step 5: Commit** — `git add bin/run-stage.sh bin/classify-failure.sh bin/run-stage-test.sh bin/verdict-adversarial-test.sh bin/classify-failure-test.sh && git commit -m "feat(ENG-152): stamp author=orchestrator on all orchestrator halt verdicts (incl. ENG-156/190/117/118 sites)"`

---

### Task 5: Envelope detective — halt on agent-authored `pipeline: verdict`

**Files:**
- Modify: `bin/run-stage.sh::_validate_dispatch_envelope` (~1047-1131)
- Test: `bin/run-stage-test.sh`

**Interfaces:**
- Consumes: `assert_no_tool_invocation "$sidecar" "<pattern>"` (existing helper).
- Produces: a new violation `agent-verdict-body:…` → existing rc=29 halt path.

- [ ] **Step 1: Write failing test** — add a fixture in `bin/run-stage-test.sh` that writes a transcript sidecar containing a tool_use command with `<!-- pipeline: verdict ` and asserts `_validate_dispatch_envelope` returns 29. (Mirror the existing envelope-detective fixtures, e.g. the `mcp__plugin_linear` one.)

- [ ] **Step 2: Run, verify FAIL** — the new fixture returns 0 (no detection yet).

- [ ] **Step 3: Edit `_validate_dispatch_envelope`.** Add a `_viol_agent_verdict` local; after the existing `wget` assertion block, add:
```bash
  # ENG-152: an agent hand-crafting a verdict body via Write/Edit/echo bypasses
  # the cmd_event_verdict lane-fence. The trailing space excludes the
  # stage-completion-claim event (agents emit that legitimately) and the
  # legacy hyphenated `pipeline: verdict-` shape.
  if _viol_agent_verdict="$(assert_no_tool_invocation "$sidecar" "<!-- pipeline: verdict ")"; then
    :
  else
    violations+=("agent-verdict-body:${_viol_agent_verdict}")
  fi
```
(No change to the halt body/exit path — it already sanitizes + posts rc=29. Stamp that halt body's `result=halt` with `author=orchestrator` if not already covered by Task 4's line 1125 edit — it is.)

- [ ] **Step 4: Run, verify PASS** — `bash bin/run-stage-test.sh` (new fixture returns 29; existing envelope fixtures still green).

- [ ] **Step 5: Commit** — `git add bin/run-stage.sh bin/run-stage-test.sh && git commit -m "feat(ENG-152): envelope detective halts on agent-authored pipeline:verdict body"`

---

### Task 6: `_orchestrator_republish_verdict` + wire-ins

**Files:**
- Modify: `bin/run-stage.sh` (add helper near `_post_dispatch_apply_halt` ~594; wire-in #1 before `verdict_handler "$ident" "$vh_stage"` at 3177; wire-in #2 at the wait path ~2845)
- Test: `bin/run-stage-test.sh`

**Interfaces:**
- Consumes: `current_dispatch_id`, `parse_pipeline_marker`, `pipeline.sh event … verdict`.
- Produces: after a dispatch whose agent posted a `stage-completion-claim` for the current dispatch_id, an authoritative `verdict … author=orchestrator` mirroring it. No-op when no current-dispatch claim exists (legacy path).

- [ ] **Step 1: Write failing test** — add `bin/run-stage-test.sh` fixtures (PR1: claim pass→republished verdict pass author=orchestrator; PR2: claim fail --target implementing→republished verdict fail; PR3: no claim→no-op/no verdict written; PR4: claim wait --reason awaiting-ci→republished verdict wait). Stub `linear.sh get-comments` to return the claim and assert the `pipeline.sh event … verdict` invocation (capture via the test's command-capture stub / `PIPELINE_DRY_RUN`).

- [ ] **Step 2: Run, verify FAIL** — function undefined.

- [ ] **Step 3: Add the helper** (adapted to current main):
```bash
# ENG-152 (D-005): orchestrator pass/wait-republish. Reads the latest
# stage-completion-claim for the current dispatch_id and re-emits it as an
# authoritative verdict author=orchestrator via the schema-driven CLI, so
# find_fresh_verdict's strict-author filter has something to consume.
# No-op when the issue carries no current-dispatch claim (legacy → D-007).
_orchestrator_republish_verdict() {
  local PIPELINE_WRITER=orchestrator; export PIPELINE_WRITER
  local ident="$1" stage="$2"
  local comments curr_id claim_body ev result target reason
  curr_id="$(current_dispatch_id "$ident" 2>/dev/null || printf '')"
  [[ -n "$curr_id" ]] || return 0
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$ident" 2>/dev/null || printf '[]')"
  [[ "$comments" == "[]" || -z "$comments" ]] && return 0
  claim_body="$(jq -r --arg id "$curr_id" '
    [.[] | select(.body | contains("<!-- pipeline: stage-completion-claim "))
         | select(.body | contains("<!-- meta: dispatch id="+$id))]
    | sort_by(.createdAt) | last | .body // ""' <<<"$comments" 2>/dev/null || printf '')"
  [[ -z "$claim_body" || "$claim_body" == "null" ]] && return 0
  ev="$(parse_pipeline_marker "$claim_body" 2>/dev/null || true)"
  [[ -z "$ev" ]] && return 0
  [[ "$(jq -r '.event' <<<"$ev")" != "stage-completion-claim" ]] && return 0
  result="$(jq -r '.result // ""' <<<"$ev")"
  target="$(jq -r '.target // ""' <<<"$ev")"
  reason="$(jq -r '.reason // ""' <<<"$ev")"
  [[ -z "$result" ]] && return 0
  local flags=()
  [[ -n "$stage" ]]  && flags+=(--stage "$stage")
  [[ -n "$target" ]] && flags+=(--target "$target")
  [[ -n "$reason" ]] && flags+=(--reason "$reason")
  PIPELINE_WRITER=orchestrator bash "$SCRIPT_DIR/pipeline.sh" event "$ident" verdict "$result" ${flags[@]+"${flags[@]}"} \
    || log "verdict-republish: failed for $ident (non-fatal — verdict_handler falls back to protocol-violation)"
}
```

- [ ] **Step 4: Wire in.** (a) Immediately before `verdict_handler "$ident" "$vh_stage"` (line ~3177): `_orchestrator_republish_verdict "$ident" "$vh_stage"`. (b) At the wait path, immediately before `log "stage $stage wait on $ident (reason=$_wait_reason)"` (line ~2845): `_orchestrator_republish_verdict "$ident" "$stage"`.

- [ ] **Step 5: Run, verify PASS** — `bash bin/run-stage-test.sh` → republish fixtures green.

- [ ] **Step 6: Commit** — `git add bin/run-stage.sh bin/run-stage-test.sh && git commit -m "feat(ENG-152): _orchestrator_republish_verdict + pass/wait wire-ins"`

---

### Task 7: `AGENT_PROMPTS.md` — flip agent emits to `stage-completion-claim` + §0 preamble

**Files:**
- Modify: `AGENT_PROMPTS.md` (per-stage emit lines listed below; §0 preamble 49-97)
- Test: `bin/agent-prompts-content-test.sh`

**Interfaces:**
- Produces: every agent verdict-emit command becomes `bash bin/pipeline.sh event {issue_id} stage-completion-claim <result> --stage <s> [--target …][--reason …]`. **Verify the fence-count invariant is preserved** — do not add/remove column-0 ``` fences (render-prompt.sh dies if a section's fence count ≠ 2).

- [ ] **Step 1: Write failing test** — extend `bin/agent-prompts-content-test.sh`:
```bash
# ENG-152: agents must emit stage-completion-claim, never bare verdict
viol="$(grep -nE 'pipeline\.sh event \{issue_id\} verdict ' AGENT_PROMPTS.md || true)"
[[ -z "$viol" ]] || { echo "FAIL ENG-152 prompt still emits verdict:"; echo "$viol"; exit 1; }
grep -qE 'stage-completion-claim pass --stage brainstorming' AGENT_PROMPTS.md || { echo "FAIL ENG-152 brainstorm claim"; exit 1; }
grep -qE 'stage-completion-claim pass --stage reviewing --reason ship-with-deferred-majors' AGENT_PROMPTS.md || { echo "FAIL ENG-152 review path-D claim"; exit 1; }
echo "PASS ENG-152 prompt-flip"
```

- [ ] **Step 2: Run, verify FAIL.**

- [ ] **Step 3: Edit `AGENT_PROMPTS.md`.** Replace each emit command. The argument shape maps `verdict pass --stage X` → `stage-completion-claim pass --stage X`; `verdict fail --target Y` → `stage-completion-claim fail --stage <current-stage> --target Y` (the claim event requires `stage`); `verdict halt --reason Z` → `stage-completion-claim halt --stage <current-stage> --reason Z`; `verdict wait --reason Z` → `stage-completion-claim wait --stage <current-stage> --reason Z`; review Path-D → `stage-completion-claim pass --stage reviewing --reason ship-with-deferred-majors`. Sites (verify line numbers at edit time — they shift as you edit): brainstorm 354/358; plan 718/722/726; implement 1115/1119/1123; ui 1317/1321/1325; review 1635/1653/1667/1696/1824/1828/1832/1836/1840; qa 2165/2169/2173; build 2241/2288/2450/2454/2458. Then rewrite the §0 "Verdict-marker protocol" preamble (49-97) to: agents post `stage-completion-claim` (informational, never authoritative); the orchestrator owns `verdict … author=orchestrator`; hand-crafting a `<!-- pipeline: verdict -->` body is a dispatch-envelope violation that halts.

- [ ] **Step 4: Run, verify PASS** — `bash bin/agent-prompts-content-test.sh` → green. Then **smoke `render-prompt.sh`** for every stage to confirm fence invariant intact:
```bash
for s in brainstorming planning implementing ui reviewing qa building released; do
  TARGET_REPO=/tmp PIPELINE_DRY_RUN=1 bash bin/render-prompt.sh "$s" >/dev/null 2>&1 \
    || { echo "FAIL render-prompt $s (fence-count?)"; exit 1; }
done; echo "render-prompt OK"
```

- [ ] **Step 5: Commit** — `git add AGENT_PROMPTS.md bin/agent-prompts-content-test.sh && git commit -m "feat(ENG-152): flip AGENT_PROMPTS emits to stage-completion-claim + §0 protocol rewrite"`

---

### Task 8: Regenerate `docs/pipeline-vocabulary.md`

**Files:**
- Modify: `docs/pipeline-vocabulary.md` (generated)
- Test: `bin/pipeline-test.sh` (existing ENG-112 roundtrip assertions B-009/B-010)

- [ ] **Step 1:** Run `bash bin/generate-vocabulary-doc.sh`.
- [ ] **Step 2:** `git diff docs/pipeline-vocabulary.md` — confirm it now documents the `stage-completion-claim` event and the `verdict.author` attribute. **If `verdict_authors` is absent**, the generator's registry-array list is hard-coded — extend `bin/generate-vocabulary-doc.sh` to include `verdict_authors`, re-run, and add it to the commit.
- [ ] **Step 3:** Run `bash bin/pipeline-test.sh` — the ENG-112 roundtrip assertion must pass against the regenerated doc.
- [ ] **Step 4: Commit** — `git add docs/pipeline-vocabulary.md bin/generate-vocabulary-doc.sh && git commit -m "docs(ENG-152): regenerate pipeline-vocabulary for stage-completion-claim + verdict.author"`

---

### Task 9: Full gate + land by hand

- [ ] **Step 1:** `bash .githooks/pre-commit` → must be **all green** (0 failed; known-broken SKIPs OK). Fix any cross-test fallout (likely a few more grep anchors in `pipeline-test.sh`/`run-stage-test.sh` pinning the old verdict body — mechanical `author=orchestrator` additions).
- [ ] **Step 2:** Manually re-read the diff of the 11 write sites and the two readers — confirm every authoritative verdict path is stamped and the strict filter engages only under D-007.
- [ ] **Step 3:** Push the branch; open ONE PR titled `fix(eng-152): split agent self-claim from orchestrator verdict (author=orchestrator)`. Body: link the 5 acceptance criteria → tasks; call out the 5 newly-covered write sites vs the stale branch; note D-007 cutover behavior (first post-deploy dispatch per in-flight issue migrates).
- [ ] **Step 4:** After human approval + merge, **deploy** (the running pipeline picks up `bin/**` on next tick via `pipeline_content_hash`). Watch the first post-deploy dispatch per active issue for a clean transition (D-007 fallback covers the one-cycle migration).

---

### Task 10: Linear + branch cleanup (operational)

- [ ] Move ENG-152 out of the bogus `stage:brainstorming` state: it is mid-flight by hand now. Remove `pipeline:halted` only at merge time via `bash bin/pipeline.sh decide ENG-152 --action abandon` is **wrong** — instead, since we land by hand, drive Linear manually: on merge, set status Done and strip `stage:*`/`pipeline:halted` (label edits additively via `bin/linear.sh remove-label`, never `save_issue`). [[linear-edit-without-save-issue]]
- [ ] Delete the stale `origin/fix/eng-152-…-orchestrator` branch after the new PR merges (keep until then as design reference).
- [ ] Post a closing comment on ENG-152 noting the fresh-impl supersedes the stale branch, linking the merged PR.

## Self-Review

**Spec coverage (5 ACs):** AC1 (agent verdict → envelope halt) → Task 5. AC2 (`find_fresh_verdict` ignores claims + unstamped verdicts) → Task 3. AC3 (AGENT_PROMPTS document `stage-completion-claim`) → Task 7. AC4 (regression fixture: claim + verdict same dispatch, orchestrator wins) → Task 3 ENG-152-A. AC5 (vocab documents event + attribute) → Task 8. ✅ All covered.

**Beyond-spec necessities surfaced by the audit:** 5 new write sites (Task 4), the `stage-completion-claim` pass-arm `pass_reasons` gap (Task 1), the republish helper for the dynamic + claim paths (Task 6), render-prompt fence smoke (Task 7). These are not in the 2026-05-19 design and are the reason a fresh impl beats a rebase.

**Placeholder scan:** none — every step has concrete code or exact edit targets. Line numbers are flagged as "verify at edit time" where edits shift them.

**Type/name consistency:** `_orchestrator_republish_verdict(ident, stage)`, `cmd_event_stage_completion_claim`, `verdict_authors`, `author=orchestrator`, `_strict_author` used consistently across tasks.
