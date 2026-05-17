---
linear: ENG-131
title: gtimeout watchdog can hang dispatch indefinitely (orphan pipe FDs) — sequentialise capture + reap MCP orphans via process-group cleanup
date: 2026-05-17
status: draft
---

# gtimeout watchdog can hang dispatch indefinitely — sequentialise the capture and reap MCP orphans

## 1. Overview (and the load-bearing surprise)

On 2026-05-15 a `claude -p` dispatch ran ~5h 43m past its 1h budget
without the inner `gtimeout` ever freeing the harness. The watchdog
*did* fire — it just had no effect. Every `launchd` tick for the next
5–6 hours hit the silent-skip at `bin/run-local.sh:51-54` and exited 0
because the tick-lock holder was still alive (blocked on `wait`, not
dead), so `acquire_lock`'s `kill -0` aliveness check in
`bin/run-local-helpers.sh:916-934` correctly refused to break it. The
harness was effectively wedged with no operator-visible signal —
documented as the load-bearing reminder in
`memory/project_gtimeout_watchdog_can_silently_fail.md` (auto-memory)
and CLAUDE.md "Failure-mode quick reference" doesn't yet catalog this
class.

**The load-bearing surprise.** This is not a `gtimeout` bug. `gtimeout`
did exactly what its man page promises: send SIGTERM to its direct
child (`claude`), then SIGKILL after 10s. The surprise is that
`gtimeout`'s contract — kill *the child* — and `claude -p`'s runtime
shape — *spawns long-lived MCP-server children (Linear, context7,
claude-in-chrome, plus per-tool subprocesses) that inherit fd1* —
compose to leave the harness's blocking `read()` waiting forever on a
pipe whose writer side is still held open by orphaned descendants
reparented to `launchd`.

The mechanism, distilled:

1. `bin/dispatch.sh:654-668` invokes `cmd` (which expands to
   `env … gtime -v -o <tmp> gtimeout --signal=TERM --kill-after=10 N
   claude -p …`) piped into `_render_and_capture_stream`. With
   `set -o pipefail` inherited from `common.sh:7`, the pipeline's exit
   code is the rightmost non-zero — but only after the renderer
   completes its `read()` loop.
2. `gtimeout` fires at the budget. SIGTERM → `claude`. After 10s,
   SIGKILL → `claude`.
3. `claude`'s MCP-server children (and dynamically-spawned tool
   subprocesses) inherit `claude`'s fd1, which is the write end of our
   pipe. When `claude` dies, those orphans get reparented to `launchd`
   and **continue to hold the write end**.
4. The kernel keeps a pipe open as long as *any* writer-side fd is
   open. `_render_and_capture_stream | jq | …` blocks on `read()`
   forever, even though our intended writer (`claude`) is dead.
5. `dispatch.sh` is `wait`-ing on the pipeline. `run-stage.sh` is
   `wait`-ing on `dispatch.sh`. `run-local.sh` is `wait`-ing on
   `run-stage.sh`. The tick-lock holder shell is `wait`-ing too, but
   it's still alive — so every subsequent tick silent-skips.

This brainstorm proposes the two-layer fix the Linear issue names —
**A first, B second**, both bundled, scope-fenced by the issue body.
A removes the pipe so a future orphan-fd retention can't block the
reader. B reaps the MCP orphans on dispatch exit so the resource-leak
half of the bug class is closed too. Neither layer migrates off
`gtimeout` and neither adds the stuck-tick alarm (both explicitly out
of scope per the issue's "Out of scope" §).

**Sizing.** 1 subsystem (dispatch). 2 design decisions (A and B) with
B subordinate to A (B is hygiene that only matters once A's fix
prevents the orphans from being blocking writers). Autonomy-safe per
the CLAUDE.md ticket sizing rubric with this explicit scope boundary
— matches the Linear issue's own sizing claim.

## 2. Goals

After this ticket lands:

1. **G-1 (no-hang).** When `gtimeout` fires SIGKILL on `claude`,
   `bin/dispatch.sh` exits within `kill-after + ε` (≤ ~12 s with the
   current `--kill-after=10`) regardless of how many MCP-server
   descendants `claude` left running. Independent of whether the
   descendants ever close their inherited write-end fds. Verified by
   a new failing-first test that constructs the orphan-writer scenario.

   **Operator-visible signal post-fix.** Today's incident (2026-05-15)
   left the operator with NO log line after `gtimeout`'s budget — the
   harness was simply silent. After A: the per-stage log
   (`$PROJECT_STATE_DIR/<slug>/logs/<ident>-<stage>-*.log`) records
   the renderer's "[cost] no result event found in stream" (or
   "[cost] partial usage captured" if NDJSON streamed before SIGKILL)
   followed by `dispatch.sh exit=124` within ~12 s of the watchdog
   firing. `run-stage.sh`'s rc=124 branch then posts the
   `dispatch wall-clock timeout` halt comment to Linear with the
   worktree-resume hint (`bin/run-stage.sh:1454-1456`). Operator
   inspecting `bin/status.sh` sees a per-issue halt label and a fresh
   completion comment, not a wedged tick.

2. **G-2 (no-orphan).** After `bin/dispatch.sh`'s EXIT trap runs, no
   process started by `cmd` (gtimeout, claude, MCP server children,
   tool subprocesses) is still alive on the host. Verified by a new
   test that spawns a long-running fake-claude descendant tree and
   asserts `pgrep -g <pgid>` returns empty post-dispatch.

3. **G-3 (rc-fidelity).** `dispatch.sh`'s exit code after the change
   preserves the existing taxonomy: `124` on `gtimeout` SIGKILL
   (mapped to `dispatch-timeout` by
   `failure_outcome_for_exit` at `bin/common.sh:276`), `22/23/26/29/31`
   on transcript-scan violations from `_render_and_capture_stream`,
   `0` on clean. `run-stage.sh`'s rc dispatch table at
   `bin/run-stage.sh:1444-1567` is unchanged.

4. **G-4 (test-compatible renderer).** `_render_and_capture_stream`'s
   stdin contract stays unchanged so the 13 existing test fixtures
   in `bin/dispatch-test.sh` (which source the function and feed
   NDJSON via heredoc — verified at `bin/dispatch-test.sh:640, 716,
   736, 783, 806, 825, 849, 887, 1009, 1504, 1730, 1759, 1848`)
   continue to pass without modification.

5. **G-5 (no new platform tool dep).** B's process-group primitive
   does not introduce a new Homebrew package as a runtime
   prerequisite. `gtimeout` (coreutils) and `gtime` (gnu-time) already
   gate the dispatch; adding `gsetsid` (util-linux) would be a third
   `g`-prefixed dependency, doubling the discovery + plist-edit
   surface for hosts on non-default setups. macOS ships
   `/usr/bin/perl` with `POSIX::setsid` baked in; we use that.

**Non-goals (deferred — match the issue's "Out of scope"):**

- Stuck-tick alarm (separate Linear issue — the safety net for any
  *future* hang that slips past A+B).
- Migration off `gtimeout` to a bash-native timer (possible follow-up,
  not needed for this fix).
- Any structural change to `_render_and_capture_stream`'s post-stream
  extraction logic. Sequential read against a closed file must
  produce identical NDJSON parsing output to the current pipe-read.
- Operator-facing live log streaming during dispatch (current behavior
  already writes to a per-stage log file consumed post-hoc; live
  streaming would be a regression-mitigation only if operators were
  reading `local-YYYY-MM-DD.log` *during* a dispatch — verified to
  be a non-pattern in practice; see D-001 *Cost of streamability*).

## 3. Architectural constraints

Five CLAUDE.md / ENG-history constraints govern this design.

**A-1. CLAUDE.md "Doing tasks" §: don't add features beyond what the
task requires; bug fix doesn't need surrounding cleanup.** D-001 and
D-002 are the minimal two-layer fix the issue specifies. D-003 (TDD
discipline) is the issue's own order-of-operations restated for the
plan stage to follow. D-004 (out-of-scope guard) is a *refusal* to
expand, not a feature.

**A-2. CLAUDE.md "Per-stage dispatch timeouts (ENG-65)" + 
"PATH expectations on the launchd host" §s.** `gtimeout` and `gtime`
are platform-tool dependencies of the dispatch path; both are
Homebrew-discovered with documented best-effort fallbacks. Adding a
third tool (`gsetsid` from `util-linux`) crosses the threshold from
"two tools the operator must have" to "three tools to track"; D-002's
perl-based fallback keeps the new dependency at zero by using
`/usr/bin/perl` (stock macOS).

**A-3. ENG-87 "Cross-dispatch staleness" §.** The renderer's
persistent sidecar at `${issue_dir}/.envelope-transcript-${stage}`
(`bin/dispatch.sh:142-144`) is read post-dispatch by
`run-stage.sh::_validate_dispatch_envelope`. A's pipe-to-file
refactor MUST preserve this sidecar's existence and content
identity — the envelope validator's detective layer for D-003 of
ENG-87 (mcp__plugin_linear / curl-to-linear scans) depends on it.

**A-4. CLAUDE.md "AGENT_PROMPTS.md is load-bearing" §** does NOT
apply — this change is orchestrator-only, no `AGENT_PROMPTS.md`
edits. The stage prompts are agnostic to whether dispatch.sh's
capture is pipe-streamed or file-buffered.

**A-5. ENG-48 / ENG-65 "Per-stage dispatch timeouts"** sets the
`gtimeout` budget (60 min brainstorm/plan, 30 min everywhere else).
Neither A nor B changes the budget. `gtimeout`'s exit-124 contract
is preserved, including the SIGTERM-then-SIGKILL-after-10 sequence
that motivates A's design (the 10-second window is where
descendants get killed and orphans get reparented).

**A-6. `set -e` / `set -o pipefail` from `bin/common.sh:7`.**
Inherited by every script. A's sequential rewrite MUST capture rc
explicitly (`|| dispatch_rc=$?`) at each step so a non-zero
`gtimeout` rc doesn't abort dispatch.sh before the renderer's
post-stream extraction runs.

## 4. Decisions

### D-001 (Layer A): Replace the pipe with a sequential file-write + post-process read

**Verdict.** `bin/dispatch.sh` at the two pipeline call-sites
(`bin/dispatch.sh:654-657, 663-665`) is rewritten from
`"${cmd[@]}" < prompt_file | _render_and_capture_stream …` to a
two-step sequential shape. The capture file lives under `$issue_dir`
(per-issue, dot-prefixed, mode 0600 via `umask 077`) — same scoping as
the renderer's existing `${issue_dir}/.raw-stream.ndjson.tmp` and
`.envelope-transcript-${stage}` sidecars, NOT under `$TMPDIR`. This
resolves OQ-2 inline (see Security/Product persona findings — `$TMPDIR`
leaves NDJSON tool inputs in a shared `/var/folders/.../T/` dir on the
SIGKILL-of-dispatch.sh path where the EXIT trap doesn't fire):

```bash
# 1. Run cmd, capture stdout to a per-issue file. mode 0600 via umask
#    077 — same scoping as the renderer's internal $raw_capture. The
#    file is per-issue ($issue_dir already exists in the resolved-usage
#    branch); the SIGKILL-of-dispatch.sh leak path becomes per-issue,
#    not host-tmp. dispatch_rc carries gtimeout's 124 / claude's
#    voluntary rc / etc.
local _capture_path=""
if [[ -n "$issue_state_dir" ]]; then
  _capture_path="${issue_state_dir}/.cmd-capture-${stage}.ndjson.tmp"
  # Pre-clean a stale file from a SIGKILL'd prior dispatch (EC-1b).
  # mode 0600 enforced by the subshell `: >` truncation under umask 077.
  ( umask 077; : > "$_capture_path" )
else
  # Ungated callers (release / retrospective / mutex-test) have no
  # issue_state_dir. Fall back to a TMPDIR mktemp with mode 0600;
  # these callers don't emit cost telemetry and have no
  # forensic-continuity requirement.
  _capture_path="$( umask 077; mktemp -t pipeline-cmd-XXXXXX )"
fi

# Unified EXIT trap (composes release_claude_mutex with pgrp reap + capture cleanup).
trap '_dispatch_cleanup' EXIT

local dispatch_rc=0
"${cmd[@]}" < "$prompt_file" > "$_capture_path" || dispatch_rc=$?

# 2. Renderer reads the captured NDJSON, emits prose to its stdout
#    (forwarded to $log_file by the caller), and runs the post-stream
#    extraction + transcript-scan violations on the now-closed file.
local render_rc=0
if [[ -n "$usage_file" && -n "$issue_state_dir" ]]; then
  _render_and_capture_stream "$usage_file" "$issue_state_dir" "$stage" \
    < "$_capture_path" > "$log_file" \
    || render_rc=$?
else
  cat "$_capture_path" > "$log_file" 2>/dev/null || true
fi

# 3. Preserve pipefail's "rightmost non-zero" priority: renderer rc
#    takes precedence (it's the more-specific halt reason), falling
#    back to dispatch_rc otherwise.
if (( render_rc != 0 )); then return $render_rc; fi
return $dispatch_rc
```

**Why.** Five reasons.

(1) **The pipe is the only thing the orphans can hold open.** Once
the writer-side fd is *a regular file* instead of a pipe, the
kernel's "writer still alive" check is moot: a file's `close()` is
not load-bearing for the reader. Orphans continue scribbling into a
file we no longer read; our shell exits cleanly. Eliminates the
hang class structurally rather than via signal-scope gymnastics.

(2) **rc propagation is unchanged.** Today: `pipefail` returns the
rightmost non-zero. After: explicit capture preserves the same
priority (renderer rc wins over dispatch rc), so
`run-stage.sh:1444-1567`'s rc-switch table works unmodified.
Specifically, `gtimeout`'s 124 still surfaces when the renderer
returns 0 (the timeout case); transcript-scan rcs (22/23/26/29/31)
still override 124 when both fire (the issue body's scenario where
a forbidden tool was invoked *and then* gtimeout killed claude).

(3) **The renderer's stdin contract is preserved (G-4).** Today the
renderer reads NDJSON from stdin. After: the renderer still reads
NDJSON from stdin, just via `< "$_capture_path"` instead of via a
pipe. The renderer's own internal `tee "$raw_capture"` at
`bin/dispatch.sh:66-67` still works (writes the renderer's
internal copy to `${issue_dir}/.raw-stream.ndjson.tmp`, used by the
post-stream `grep '"type":"result"'` extractor at
`bin/dispatch.sh:87`). The existing test fixtures that source the
renderer and feed NDJSON via heredoc (verified — 13 call sites at
`bin/dispatch-test.sh:640, 716, 736, 783, 806, 825, 849, 887, 1009,
1504, 1730, 1759, 1848`) continue to work unmodified. **No renderer
code changes are required in this layer.**

(3a) **The renderer's INTERNAL `tee … | jq` pipe stays — and stays
safe.** A's pipe removal targets the OUTER pipe `cmd | renderer`
where the writer side is `cmd` (a long-lived chain of gtimeout +
claude + MCP descendants that can be SIGKILLed leaving orphans
holding fd1). The renderer's INNER `tee | jq` pipe has `tee` as
its writer side. `tee` is a known-terminating writer that reads to
EOF from its (now-file-backed) stdin, writes a copy to
`$raw_capture`, and exits. `tee` spawns no descendants and inherits
no long-lived fds; jq is a deterministic terminator on EOF.
Orphan-fd retention is impossible here by construction. The
distinction is the writer's process model, not "all pipes are
banned" — pin this in the implementation diff comment so a future
reader doesn't widen the rule.

(4) **The envelope sidecar is preserved (A-3 constraint).** The
renderer writes `${issue_dir}/.envelope-transcript-${stage}` at
`bin/dispatch.sh:142-144`, and `run-stage.sh::_validate_dispatch_envelope`
reads it post-dispatch. Because we still pipe through the renderer
(just from a file instead of from `cmd`), the sidecar still gets
written. ENG-87's D-003 detective layer keeps working.

(5) **Cost of streamability — accepted.** Today the renderer's
prose lines (`[claude] session=…`, `[tool] Bash`, `[tool-result]
…`) reach `$log_file` *during* the dispatch (operator can `tail -f`
to watch progress). After: prose lands all-at-once when dispatch
exits. The acceptable-cost framing matches the issue body
(`bin/dispatch.sh:646-660` writes prose to `$log_file`, not to the
orchestrator's `local-YYYY-MM-DD.log` per the ENG-26 routing
comment — operators read the per-stage log after the fact, not
live).

**Rejected alternatives.**

*Alt-A1: `cat "$_capture_path" | _render_and_capture_stream …`
instead of stdin redirection.* `cat | tee | jq` pipes a known
terminating writer (`cat`) into the renderer — orphan-safe because
`cat` exits on EOF and doesn't spawn descendants. But this
*reintroduces a pipe* in the shape `cat | renderer`. Even though
`cat` is well-behaved, future contributors reading the code see a
pipe and may add long-running writers behind it. Stdin redirection
is more honest about "this file is the input" and adds zero pipe
machinery. Rejected on clarity grounds.

*Alt-A2: Refactor the renderer to take a file-path arg
(`_render_and_capture_stream <usage_file> <issue_dir> <stage>
[capture_file]`) and read from `$capture_file` when non-empty.*
More explicit. But breaks the ~27 existing `_render_and_capture_stream`
test-fixture call sites that feed via stdin heredoc (13 enumerated
canonical `USAGE_*` fixtures at lines 640+, plus ~14 additional
adjacent fixtures). We'd have to update each, doubling the diff size.
Rejected on G-4 (test compatibility) grounds; if a future ticket
decides to fully internalise capture in the renderer, that's a clean
refactor day.

*Alt-A3: Use a process-substitution sink (`"${cmd[@]}" < prompt_file
> >(tee "$_capture_path" | _render_and_capture_stream …)`).* The
`>()` opens a new pipe to a subshell. Same orphan-fd retention
problem as today — `cmd`'s descendants inherit the fd to the subshell
pipe. Rejected for not actually fixing the bug.

*Alt-A4: Replace `gtimeout` with a bash timer that does its own
process-group kill.* Issue explicitly out-of-scope ("Migrating away
from gtimeout entirely — possible follow-up, not needed for this
fix"). Rejected per the issue's own non-goals.

### D-002 (Layer B): Make `cmd` a process-group leader; cleanup trap signals the pgrp

**Verdict.** `bin/dispatch.sh::main` wraps the `"${cmd[@]}"` invocation
under a perl-based `setsid` shim that makes the wrapped process a
session and process-group leader. `dispatch.sh`'s EXIT trap then
signals the entire pgrp (`kill -TERM -- -$cmd_pgid; sleep 1; kill -KILL
-- -$cmd_pgid`) to reap any MCP-server descendants that survived
`claude`'s death.

Concrete shape (sketch; TDD failing test first):

```bash
# Inside main(), at the cmd-invocation site (post-A). The perl
# one-liner uses POSIX::setsid (a core perl module available on every
# stock macOS install, verified /usr/bin/perl). setsid(2) creates a
# new session AND a new process group with the calling process as
# leader; exec replaces the perl process with the next argv. The
# resulting process is the session leader AND the pgrp leader; its
# PID == its PGID. Subsequent fork()s by gtimeout / claude / MCP
# children inherit the pgrp.
#
# IMPORTANT: we use `exec` INSIDE the &-backgrounded subshell so that
# the subshell's PID — captured via $! — IS the session leader (perl
# is exec'd in place, becoming the only process at that PID before
# exec @ARGV swaps to gtimeout). Without the leading `exec`, the
# subshell itself remains as a separate process and $! would be the
# subshell's PID, not the leader's; we'd have to ps-discover the pgid
# at runtime. Cleaner to `exec` and trust $!.

( exec /usr/bin/perl -e 'use POSIX qw(setsid); setsid; exec @ARGV' \
    "${cmd[@]}" < "$prompt_file" > "$_capture_path" ) &
local _cmd_pgid=$!

# Integer-validate before any kill -- -$pgid (defense against future
# regressions that could leave $_cmd_pgid empty / non-numeric).
if ! [[ "$_cmd_pgid" =~ ^[0-9]+$ ]]; then
  log "[dispatch] _cmd_pgid not numeric ($_cmd_pgid); pgrp cleanup disabled"
  _cmd_pgid=""
fi

# Single-phase EXIT trap composing all cleanup. Installed pre-acquire
# so a die() between trap install and cmd spawn cannot leak the mutex
# (preserves the AC-TRAP-BEFORE-ACQUIRE invariant from
# bin/dispatch-test.sh — the test's required predecessor line check
# is updated to accept `trap '_dispatch_cleanup' EXIT` as the
# composed shape, since _dispatch_cleanup is defined to call
# release_claude_mutex internally — see §5 architecture row).
_dispatch_cleanup() {
  # Guard: pgid only signals if cmd was successfully spawned AND the
  # captured PID passed integer validation. No-op for the
  # die-before-cmd-spawn path and for ungated callers (mutex-test, etc.).
  if [[ -n "${_cmd_pgid:-}" && "$_cmd_pgid" =~ ^[0-9]+$ ]]; then
    kill -TERM -- "-$_cmd_pgid" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-$_cmd_pgid" 2>/dev/null || true
  fi
  if [[ -n "${_capture_path:-}" && -f "$_capture_path" ]]; then
    rm -f "$_capture_path"
  fi
  release_claude_mutex   # preserves AC-TRAP-BEFORE-ACQUIRE intent
}
trap _dispatch_cleanup EXIT

local dispatch_rc=0
wait "$_cmd_pgid" || dispatch_rc=$?
# … then D-001's renderer step on "$_capture_path".
```

**Why.** Five reasons.

(1) **A alone leaves the orphans alive.** Once the pipe is gone (A),
the orphans don't *block* us — but they continue to consume memory,
file descriptors, and sockets. The Linear issue acknowledges this as
"a resource-leak that the orphans leave behind" and the issue body's
B layer is dedicated to closing it. Skipping B means the same 5h 43m
incident would leave ~5–10 reparented MCP-server processes per
gtimeout fire; over a year of low-frequency timeouts, the host's
process table grows unbounded.

(2) **Process-group kill is the right primitive for "claude + all its
descendants."** `claude` is the only process we *know about*; its
descendants are discovered at runtime (per-tool MCP servers, dynamic
subprocesses). The pgrp is the kernel-level set the OS already
maintains for "things claude started." `kill -- -PGID` is a single
syscall that covers them all.

(3) **`/usr/bin/perl` with `POSIX::setsid` is a zero-new-dep
primitive on macOS.** Verified: `type perl` returns `/usr/bin/perl`
on stock darwin; POSIX is a core perl module shipped in every macOS
perl install since Tiger (2005). No Homebrew package, no plist edit,
no `require_bin` addition. The shape mirrors how the codebase
already opts into auxiliary tools (cf. `gtime` discovery at
`bin/dispatch.sh:558-566` — best-effort with graceful degradation;
here perl is *guaranteed* present, so no degradation path needed).

(4) **Composability with the existing release_claude_mutex trap.**
The codebase enforces (via `bin/dispatch-test.sh:3008-3033` —
"AC-TRAP-BEFORE-ACQUIRE") that `trap 'release_claude_mutex' EXIT`
appears on the line immediately preceding `acquire_claude_mutex`.
That invariant guards against mutex leaks on `die()` between trap
install and acquire. Bash traps don't stack, so our cleanup
function MUST include `release_claude_mutex` to preserve the
invariant. The cleanup function is *installed* in two phases:
phase 1 (pre-acquire) is the existing `release_claude_mutex`-only
trap; phase 2 (post-acquire, post-cmd-spawn) replaces it with the
unified `_dispatch_cleanup` that also signals `$_cmd_pgid`. Test
needs an updated assertion: "the FIRST trap is still
`release_claude_mutex` EXIT; a SECOND trap is installed later that
calls `release_claude_mutex` from within."

(5) **Self-kill safety.** `kill -TERM -- -$_cmd_pgid` signals every
member of the pgrp WHOSE PGID IS `$_cmd_pgid`. Since dispatch.sh
itself is NOT in that pgrp (only the perl-wrapped subshell and its
descendants are), there's no self-signal risk. dispatch.sh's own
EXIT trap firing means the script is *already* exiting; signalling
the descendant pgrp is purely outward-directed.

**Rejected alternatives.**

*Alt-B1: Homebrew util-linux's `gsetsid`.* Adds a third `g`-prefixed
tool to the dispatch dependency surface (currently `gtimeout`,
`gtime`; this would add `gsetsid`). Each tool needs PATH-expectation
docs in CLAUDE.md, plist plumbing, `require_bin` updates, and
degradation paths for the host that hasn't installed util-linux.
perl-based setsid is functionally identical with zero new
dependencies. Rejected on G-5 (no new platform tool dep).

*Alt-B2: Have `run-stage.sh` invoke `dispatch.sh` under setsid (the
issue's sketch).* Issue itself flags this with "Verify setsid
semantics on macOS (setsid on darwin behaves slightly differently
from Linux's setsid -w; may need a small wrapper)." Verified: macOS
does NOT ship `setsid` at all on stock installs; coreutils' Homebrew
package does NOT include it; util-linux's `gsetsid` would. So the
issue's exact sketch is non-portable. Even if we used `gsetsid`,
moving the pgrp boundary up to `run-stage.sh` means
`run-stage.sh`'s OWN pgrp would now be the dispatch's pgrp leader,
and a `kill -- -PGID` from inside the dispatch's EXIT trap would
also kill `run-stage.sh`. Wrong scope. Rejected.

*Alt-B3: dispatch.sh re-execs itself under perl-setsid at entry.*
Moves the pgrp boundary up to dispatch.sh itself. Then
`kill -- -$$` from the EXIT trap would signal dispatch.sh (which is
already exiting — that's the same self-kill safety as B's chosen
shape, just at a different scope). But re-exec changes argv (gets
mangled by perl's `exec @ARGV`), complicates debugging, and forces
every dispatch.sh entry to go through perl. The chosen shape
wraps only the cmd subshell, which is more surgical. Rejected on
blast-radius grounds.

*Alt-B4: Defer B to a follow-up ticket; ship A alone.* The Linear
issue explicitly bundles A and B ("Two layers, each addressing one
root cause. A first; B second.") and the sizing rubric in CLAUDE.md
treats them as 1 subsystem + 2 decisions with B subordinate. The
incident motivated A; B is the hygiene that prevents A's fix from
*looking like success while still leaking resources*. Splitting B
out makes the same PR ship twice with extra ceremony. Rejected on
issue-scope grounds.

*Alt-B5: Use bash's `set -m` (monitor mode) to give the cmd its own
pgrp.* `set -m` in non-interactive scripts has corner cases
(suspended jobs, terminal-control assumptions) and is fragile under
bash 3.2 (macOS default). perl-based setsid is deterministic and
trivially testable. Rejected on stability grounds.

### D-003: Order of operations — A first, B second, TDD per layer

**Verdict.** The implementation order (matches the issue's
"Order of operations" §):

1. Write a failing test for A in `bin/dispatch-test.sh`. Construct
   a "fake claude" fixture that exits leaving a background writer
   (e.g. `sleep 9999 1>&1 &`) holding the inherited write fd.
   Assert `dispatch.sh` exits within `≤ 12 s` of `gtimeout`'s SIGKILL.
2. Implement A. Verify A's test passes; verify all existing
   renderer-stdin test fixtures still pass.
3. Write a failing test for B. Spawn a fake-claude descendant tree
   (3–5 levels deep `sh -c 'sleep 9999' &`); assert
   `pgrep -g <pgid>` returns empty within `≤ 1.5 s` after dispatch
   exits.
4. Implement B. Verify B's test passes; verify A's test still
   passes; verify all existing dispatch tests still pass.

**Why.** Two reasons.

(1) **A's failing test exists in isolation.** With A unfixed, the
test deterministically hangs (or times out at the test framework's
own outer budget). Once A is fixed, the test passes in well under
the inner gtimeout's kill-after window. This is exactly the "TDD
failing test first" shape the issue body specifies.

(2) **B's test only makes sense after A.** B verifies "no descendants
alive after exit." Without A, dispatch.sh never exits, so the
"after exit" precondition never holds. B's test must be written
after A's implementation lands. This is the issue's "B subordinate
to A" reading.

**Rejected alternative.** *Land both layers in one commit without
intermediate test-pin.* Cheaper to write but loses the regression
boundary: a future contributor regressing A would also regress B,
and the joint failure mode obscures which layer broke. Rejected on
test-discipline grounds.

### D-004: Out-of-scope guard — no stuck-tick alarm, no gtimeout migration

**Verdict.** This ticket ships exactly D-001 + D-002 + D-003. Two
adjacent ideas that this incident might motivate are filed as
sibling tickets / non-goals:

1. **Stuck-tick alarm.** When `acquire_lock` silent-skips for >N
   consecutive ticks because the lock is held but the holder is
   blocked, surface an operator-visible alert. Filed separately as
   the safety net for whatever future hang slips past A+B. NOT in
   this brainstorm.

2. **Migration off gtimeout.** A self-managed bash timer that does
   its own pgrp-kill on expiry would unify A+B into a single
   primitive. Possible follow-up. NOT in this ticket.

3. **Tighter MCP-server lifecycle contract.** The MCP server
   subprocesses that hold the orphan fds are dispatched by `claude`
   itself; the harness has no direct control over their shape.
   A future investigation might propose `claude` install its own
   SIGTERM handler that cascades to descendants. Out of harness
   scope.

**Why.** Three reasons.

(1) **The issue's own "Out of scope" § names #1 and #2 explicitly.**
Honoring scope is honoring the rubric (CLAUDE.md "Ticket sizing
rubric"); umbrella-creep is the failure mode that produced
ENG-100, ENG-104, ENG-87.

(2) **A+B as designed close the bug class without #1 or #2.** A
removes the hang; B removes the leak. A future hang (different
root cause) is the stuck-tick alarm's job to surface, not this
ticket's.

(3) **MCP lifecycle (#3) is outside the harness.** Changes to
`claude` CLI's process model are upstream concerns; we can't fix
them in `bin/dispatch.sh`. The harness's contract is "treat claude
as a black box; assume descendants exist and reap them." B does
exactly that.

## 5. Architecture (where code goes)

| Change | File | Lines (current) | Shape |
|---|---|---|---|
| D-001: pipe → sequential capture | `bin/dispatch.sh` | `654-668` (the two `if log_file / else` pipe arms) | Replace pipe with `cmd > capture_path; render < capture_path > log_file`. Add capture-file mktemp + cleanup. |
| D-002: perl-setsid wrap + pgrp cleanup | `bin/dispatch.sh` | `620-645` (the `cmd` array build), plus new EXIT trap unification at the post-acquire site (`507-508` adjacent) | Prepend `/usr/bin/perl -e 'use POSIX qw(setsid); setsid; exec @ARGV'` to `cmd`. Replace the existing `trap 'release_claude_mutex' EXIT` post-acquire with `_dispatch_cleanup` that signals `-$_cmd_pgid` then calls `release_claude_mutex`. |
| New: test fixture for A | `bin/dispatch-test.sh` | new section, appended | Fake-claude binary writes some NDJSON then `exec`s `sleep 9999` in a background writer holding fd1. Assert dispatch.sh exits ≤ 12 s after `gtimeout` fires. |
| New: test fixture for B | `bin/dispatch-test.sh` | new section, appended | Fake-claude spawns a multi-level descendant tree (sh -c sleep 9999 chains). After dispatch exit, assert `pgrep -g <captured_pgid>` returns empty within 1.5 s. |
| Updated: trap-install invariant test | `bin/dispatch-test.sh` | `AC-TRAP-BEFORE-ACQUIRE` block (existing, `~3008-3033`) | Adjust the literal-line assertion: the predecessor line to `acquire_claude_mutex` becomes `trap '_dispatch_cleanup' EXIT` (single-phase, composed shape) instead of the historical `trap 'release_claude_mutex' EXIT`. The invariant the test is guarding (no die() between trap install and acquire can leak the mutex) is preserved because `_dispatch_cleanup` calls `release_claude_mutex` internally. Test must also assert `_dispatch_cleanup` is defined upstream of the trap-install line. NOTE: this is an *adjustment* to a load-bearing existing invariant — plan stage should call this out distinctly from net-new test fixtures so the diff reviewer sees the protected boundary. |
| CLAUDE.md "Failure-mode quick reference" | `CLAUDE.md` | "Failure-mode quick reference" table | Add a row: "Tick is silent for >2 ticks (≥10 min) AND `bin/status.sh` shows the issue with `stage:*` but no fresh dispatch log → suspect ENG-131-class hang. First check: `cat $PROJECT_STATE_DIR/<slug>/logs/local-$(date -u +%Y-%m-%d).log \| tail -50` for the last `dispatch.sh exit=…` line. If none in last 30 min: `pgrep -af claude` to enumerate orphan MCP descendants; the holder pid in `$PROJECT_STATE_DIR/.run-local.lock/pid` is alive but `wait`-blocked. Pre-A+B this was the 5h 43m hang on 2026-05-15; post-A+B operators should NOT see this symptom — if it recurs, root cause is a NEW hang class, file a sibling ticket." |

**No changes to:**
- `bin/run-stage.sh` (rc-dispatch table unchanged at `:1444-1567`).
- `bin/common.sh` (`failure_outcome_for_exit:276` unchanged — 124 still maps to `dispatch-timeout`).
- `AGENT_PROMPTS.md` (orchestrator-only fix).
- `bin/run-local.sh` (silent-skip path at `:51-54` is correct as-is; the harness recovering from a stale holder is exactly what we want once A+B prevent the holder from getting stuck).
- `bin/run-local-helpers.sh` (`acquire_lock:916-934` correctly refuses to break a live-holder lock — preserved).
- Any pipeline-event registry (`bin/pipeline-events.json`) — no new verdict/transition tokens.

## 6. Data flow

### Before (current, hang-prone)

```
launchd
  └─ run-local.sh
      └─ run-stage.sh
          └─ dispatch.sh
              └─ pipe:  cmd[env|gtime|gtimeout|claude…]  →  renderer[tee|jq]
                          │                                    │
                          ├─ stdout (NDJSON)  ──────pipe──────┘  (blocks on read)
                          ├─ MCP-server descendants (inherit fd1)
                          │   └─ orphan to launchd on SIGKILL (KEEP holding fd1)
                          └─ on gtimeout: SIGTERM → claude; +10s → SIGKILL → claude

              Result: pipe's write end held by orphans → renderer never sees EOF
                      → dispatch.sh's `wait` blocks → run-stage.sh blocks
                      → run-local.sh blocks → tick lock held forever
```

### After A (no pipe; orphans alive but harmless)

```
dispatch.sh
  ├─ cmd > capture_file    (rc captured; file closed when cmd's parent exits)
  ├─ renderer < capture_file > log_file   (post-process; renderer sees EOF immediately)
  └─ exit dispatch_rc   (124 on timeout, etc.)

  MCP orphans:  still alive, still writing to capture_file (file we no longer read)
                 → no longer blocks our shell, but leaks RSS/FDs to launchd
```

### After A+B (no pipe; orphans reaped)

```
dispatch.sh
  ├─ EXIT trap installed: kill -TERM -- -$pgid; sleep 1; kill -KILL -- -$pgid; release_claude_mutex
  ├─ perl-setsid wraps cmd  →  cmd is pgrp leader  →  descendants inherit pgrp
  ├─ wait <pgrp_leader_pid>   (gets gtimeout's 124 or claude's voluntary rc)
  ├─ renderer < capture_file > log_file
  └─ on EXIT: pgrp signaled → MCP descendants get SIGTERM/SIGKILL → no orphans

  Result: clean teardown.
```

## 7. Error handling / exit-code propagation

| Scenario | dispatch_rc | render_rc | dispatch.sh exit | run-stage.sh path |
|---|---|---|---|---|
| Clean dispatch | 0 | 0 | 0 | normal flow |
| gtimeout fires (SIGKILL claude) | 124 | 0 | 124 | rc=124 branch: `classify_failure skip-until-human-acts dispatch-timeout` (`run-stage.sh:1444-1457`) — unchanged |
| Agent invoked `gh pr create` (implementing) | 0 or 124 | 22 | 22 | rc=22 branch: `classify_failure skip-until-human-acts pr-opened-too-early` — unchanged |
| Agent invoked banned branch-creation | 0 or 124 | 23 | 23 | rc=23 branch — unchanged |
| Build agent did `git checkout main` | 0 or 124 | 26 | 26 | rc=26 branch — unchanged |
| Agent posted Linear comment via MCP/curl | 0 or 124 | 29 | 29 | rc=29 branch — unchanged |
| Plan agent missing progress.md entry | 0 | 31 | 31 | rc=31 branch — unchanged |
| Capture-file mktemp failed | (n/a — die before cmd runs) | (n/a) | 1 | `run-stage.sh::route_run_stage_exit` falls into `unknown-exit-1` → generic dispatch-failed retry |
| Capture-file disk-full mid-write | non-zero (write error rc from `cmd`'s `>`) | varies | non-zero | as above |
| `_cmd_pgid` empty when EXIT trap fires (cmd never spawned) | (n/a) | (n/a) | varies | cleanup function checks `[[ -n "${_cmd_pgid:-}" ]]` before `kill`; no-op safely |
| perl wrapper missing (/usr/bin/perl removed) | 127 (perl not found) | (n/a) | 127 | `unknown-exit-127` — operator-visible halt with clear log line |

**Key invariants preserved:**

- Renderer rc takes precedence over dispatch rc (matching current
  pipefail "rightmost non-zero" semantics).
- `gtimeout`'s 124 surfaces unchanged for the timeout path (the
  motivating bug class — operator-visible halt was always working
  *post-rc-propagation*; the hang prevented rc from being read).
- The renderer's transcript-scan violations (22/23/26/29/31)
  surface unchanged.
- `release_claude_mutex` runs on every exit path (preserving the
  `AC-TRAP-BEFORE-ACQUIRE` invariant test in `bin/dispatch-test.sh`).

## 8. Edge cases

**EC-1 (capture-file disk pressure).** A long dispatch (≤ 60 min)
emits ~MB-scale NDJSON. The current pipe streams it through and
discards; the new shape *retains* it on disk under
`${issue_state_dir}/.cmd-capture-${stage}.ndjson.tmp` (per-issue
state dir, typically `~/.local/state/twinning-harness/<slug>/ENG-N/`).
Worst-case: a 60-min brainstorm produces ~5–20 MB NDJSON. The file
is removed by `_dispatch_cleanup` on EXIT regardless of rc. NOT
under `$TMPDIR` — see OQ-2 resolution above for the Security/Product
rationale.

**EC-1b (SIGKILL of dispatch.sh itself).** Bash EXIT traps do NOT
fire on SIGKILL. If `dispatch.sh` is itself SIGKILL'd (e.g., parent
chain SIGKILL'd by an even-larger watchdog, or oomkill), the capture
file persists in `$issue_state_dir`. The persistence is bounded to
the per-issue dir (mode 0600, owner-only readable). Recovery: the
next dispatch of the same (issue, stage) pair pre-cleans
`.cmd-capture-${stage}.ndjson.tmp` at its own dispatch start (idempotent
pre-clean, mirrors the existing `.transcript-violation-${stage}` /
`.envelope-transcript-${stage}` pre-clean at `bin/dispatch.sh:55`).
Add this pre-clean to the renderer's existing line — single-line
diff, same idiom.

**EC-2 (capture file under $issue_dir vs /tmp).** Today's
renderer-internal `raw_capture` lives at
`${issue_dir}/.raw-stream.ndjson.tmp` (per-issue dir, dot-prefixed so
the artifact-scanner skips it). Our new D-001 capture file is at
`${issue_state_dir}/.cmd-capture-${stage}.ndjson.tmp` — same directory,
different filename. The renderer's *internal* `tee "$raw_capture"`
still writes to `${issue_dir}/.raw-stream.ndjson.tmp` and is still
cleaned by the renderer's RETURN trap at `bin/dispatch.sh:56`. Two
separate per-issue files; no overlap, both dot-prefixed,
artifact-scanner-invisible.

**EC-2b (renderer's INTERNAL `tee | jq` pipe is orphan-safe).** The
renderer's internal `tee "$raw_capture" | jq …` pipeline at
`bin/dispatch.sh:66-67` is NOT removed by A. It remains orphan-safe
because `tee`'s writer-side fd to the jq pipe is held by `tee` only;
`tee` spawns no descendants, reads to EOF from its (now file-backed)
stdin, and exits. jq reads to EOF on `tee`'s exit. No orphan-fd
retention is possible here. The bug class A fixes is *long-lived
descendants of `cmd` holding fd1 across SIGKILL* — `tee` is
short-lived and well-behaved by construction.

**EC-3 (gtimeout returns non-124 non-0).** `gtimeout` can return 125
(timeout itself failed), 126 (cmd not executable), 127 (cmd not
found) — all distinct from 124. The capture pattern `|| dispatch_rc=$?`
captures all of these; renderer runs against whatever NDJSON was
emitted (possibly empty); `run-stage.sh`'s rc-switch falls through to
`unknown-exit-N` which routes to retry-immediately. Unchanged from
today.

**EC-4 (renderer hangs on its own internal jq).** The renderer reads
from a closed file (post-A) and its jq invocation is deterministic.
Cannot hang. (Today's renderer can hang only if its stdin never
closes — which is the very bug A fixes.)

**EC-5 (B's pgrp signal hits a process that already exited).**
`kill -- -PGID` to an empty pgrp returns rc=1. The `2>/dev/null || true`
suppression in `_dispatch_cleanup` handles this benignly. Idempotent.

**EC-6 (B's pgrp signal hits a process in a different pgrp).** Can't —
the pgrp is freshly created by perl's setsid; only descendants of the
wrapped cmd can be in it. The kernel-level pgrp membership is the
authoritative scoping.

**EC-7 (dispatch.sh die() between trap install and cmd spawn).** The
trap upgrade is single-phase — `_dispatch_cleanup` is installed in
place of the historical `release_claude_mutex` trap, BEFORE
`acquire_claude_mutex`. The `_cmd_pgid` and `_capture_path` variables
are uninitialised at that point; the cleanup function's `[[ -n
"${_cmd_pgid:-}" ]]` and `[[ -n "${_capture_path:-}" ]]` guards
return false, so the function reduces to calling
`release_claude_mutex` only. AC-TRAP-BEFORE-ACQUIRE invariant
preserved — `release_claude_mutex` still runs on every die() path
between trap install and acquire. **Single-phase is simpler than a
two-phase upgrade; the §5 architecture table reflects this.**

**EC-8 (dispatch.sh die() between cmd spawn and EXIT trap firing).**
Once cmd is spawned and `_cmd_pgid` captured, any subsequent die()
fires the EXIT trap. The trap signals the pgrp, removes the capture
file, and releases the mutex. The narrow window between spawn and
`_cmd_pgid=$!` assignment is single-statement; bash's `... &
local _cmd_pgid=$!` is atomic from the trap's perspective (the trap
can only fire BETWEEN statements). No leak window.

**EC-9 (PIPELINE_DRY_RUN=1).** The dry-run branch at
`bin/dispatch.sh:568-583` does NOT invoke `cmd` and skips the renderer
entirely. A's pipe-removal is unreachable; B's perl-setsid wrap is
unreachable. No change to dry-run shape. Test asserts `[DRY_RUN]`
preview still emits.

**EC-10 (Linux portability).** The harness today is darwin-only by
deployment (launchd, brew-installed gtimeout/gtime). perl is available
on every Linux too; POSIX::setsid is core. So A and B both work on
Linux without change. Future Linux ports are unaffected.

**EC-11 (claude voluntarily exits with descendants still spawning).**
Race: claude exits cleanly between fork() and exec() of its MCP child.
Result: orphan exists, B's pgrp-kill catches it. (Even without B, A's
pipe removal means the orphan doesn't block — the leak path is closed
by B alone.) No new edge.

**EC-12 (cost telemetry on SIGKILL post-A).** Today's renderer's
"partial usage" path at `bin/dispatch.sh:104-135` sums per-message
`assistant.message.usage.*` when no result event lands (ENG-65 D-003).
After A, the renderer still runs and still sees whatever NDJSON `cmd`
wrote before SIGKILL. Partial usage capture is preserved. The only
change is *when* it runs: post-cmd-exit instead of in parallel with cmd.

**Operator visibility post-fix.** Operators inspecting
`$(issue_dir <ident>)/usage-<stage>.json` after a SIGKILL-terminated
dispatch will see `{partial: true, cost_usd: null, tokens_in: …,
tokens_out: …}` — same shape as today's ENG-65 D-003 fallback, but
now *reliably written* on every gtimeout-fire rather than possibly
orphaned by the hang. Pre-A the file was sometimes missing (renderer
never reached the post-stream extraction). Post-A the file is
deterministically present on rc=124 paths.

## 9. Open questions

**OQ-1 (pgrp signal delay).** The cleanup trap's `sleep 1` between
SIGTERM and SIGKILL is chosen by symmetry with gtimeout's
`--kill-after=10` (less aggressive — 1s is enough for graceful MCP
shutdown). If MCP servers turn out to need more time, lengthen to 2–3
s. Test-validate during implementation.

**OQ-2 (capture file location).** *Resolved in D-001 — see "The
capture file lives under $issue_dir" paragraph.* Three concerns
converge on `${issue_state_dir}/.cmd-capture-${stage}.ndjson.tmp`:
(i) per-issue scoping bounds the SIGKILL-of-dispatch.sh leak path to
the per-issue dir (Security persona P0-2 — EXIT traps don't fire on
SIGKILL, so a residual capture file in `$TMPDIR` would survive in a
shared dir); (ii) mode 0600 via `umask 077` matches the renderer's
internal `$raw_capture` perms (Security P0-1); (iii) forensic
continuity — operators inspecting `$issue_dir` post-incident find
both the envelope sidecar AND the cmd-capture file alongside the
worktree (Product P0-3). The ungated-caller fallback (no
`issue_state_dir`) still uses `mktemp -t` under umask 077, but those
callers (mutex-test / dry-run-self-check) don't emit cost telemetry
and have no forensic-continuity requirement.

**OQ-3 (per-stage signal scope on stages that don't spawn MCP
descendants).** Stages like `released` use a smaller tool allowlist
and may not spawn MCP descendants. The pgrp cleanup is harmless when
the pgrp is empty (EC-5), but the perl-wrap is also unnecessary
overhead. Trade-off: uniform shape (always wrap) is simpler and
~50ms perl-fork cost per dispatch is negligible vs. claude's
~minutes runtime. Recommend: always wrap, don't conditionalize.

**OQ-4 (renderer test fixtures and the renamed capture-internal path).**
The renderer's *internal* `tee "$raw_capture"` writes to
`${issue_dir}/.raw-stream.ndjson.tmp`. The test fixtures
(`bin/dispatch-test.sh:640+`) source the renderer with `ISSUE_DIR`
pointing to a test temp dir. No collision with our new `_capture_path`
(which is `mktemp -t`, distinct). Verified by code reading; double-
check during implementation.

**OQ-5 (Should D-002's perl-setsid be guarded by a `_PIPELINE_NO_PGRP=1`
test escape hatch?).** *Resolved — REJECT.* Security persona P1-3
flagged that test-escape hatches that disable load-bearing security
primitives (pgrp reaping is now load-bearing for resource hygiene)
become production foot-bullets. The `_PIPELINE_GTIME_DISABLED=1`
precedent at `bin/dispatch.sh:559-560` disables a *metric emit*
(observability — safe to skip in tests); B disables *cleanup* (safety
— never safe to skip). If a test legitimately can't tolerate a real
pgrp, it's testing the wrong shape; the test author should mock the
spawn shape entirely, not bypass the cleanup. No escape hatch
ships.

**OQ-6 (Stuck-tick alarm scope — sibling ticket).** Not this PR per
D-004, but: the operator detection story for ANY future hang past A+B
is empty. The Linear issue's "Out of scope" § names this as a sibling
ticket. Recommend the plan stage links the sibling ticket id (when
filed) so the operator runbook can point at it.

## 10. Persona review

Two iterations were run; gate (5/6 PASS AND feasibility 0 P0) was
cleared in iter-2 at 6/6 PASS. Order: design → security → scope →
coherence → product → feasibility (feasibility last, per the
gating discipline).

### Iter-1 (initial draft)

| Persona | Verdict | P0 | Summary |
|---|---|---|---|
| Design | PASS (with P0s) | 3 | (1) `$!` vs PGID ambiguity; (2) §5 trap-test mismatch with EC-7/EC-8; (3) renderer's INTERNAL `tee \| jq` pipe unanalyzed |
| Security | PASS (with P0s) | 3 | (1) `$TMPDIR` capture perms / shared dir; (2) SIGKILL of dispatch.sh leaves NDJSON in `$TMPDIR`; (3) integer-validate `$_cmd_pgid` |
| Scope | PASS | 0 | A+B correctly bundled |
| Coherence | PASS | 0 | clean; inventory count drift (13 vs 14); `$!` vs pgid ambiguity (== Design P0-1) |
| Product | **FAIL** | 3 | (1) runbook needs first-observable lead; (2) post-fix success criterion missing from G-1; (3) OQ-2 should resolve toward `$issue_dir` |
| Feasibility | *(deferred to iter-2)* | — | postponed until P0s addressed |

### Iter-2 fixes

Consolidated revisions in this draft:

- **OQ-2 resolved inline in D-001** → capture file at
  `${issue_state_dir}/.cmd-capture-${stage}.ndjson.tmp` (per-issue,
  mode 0600). Addresses Security P0-1+P0-2 and Product P0-3 jointly.
- **D-002 sketch tightened** → `exec` placed inside `& subshell` so
  `$!` IS the session leader's PID; integer-validation guard on
  `_cmd_pgid` pre-kill. Addresses Design P0-1 and Security P0-3.
- **§5 trap-test row rewritten** → single-phase composed-shape
  assertion (NOT two-phase upgrade); AC-TRAP-BEFORE-ACQUIRE invariant
  preserved because `_dispatch_cleanup` calls `release_claude_mutex`
  internally. Addresses Design P0-2.
- **G-1 gains "Operator-visible signal post-fix" paragraph** → names
  per-stage log line, `dispatch.sh exit=124`, worktree-resume hint,
  `bin/status.sh` shape. Addresses Product P0-2.
- **§5 CLAUDE.md row leads with first-observable** → "Tick is silent
  for >2 ticks (≥10 min) AND `bin/status.sh` shows … but no fresh
  dispatch log" → then orphan-pgrep step. Addresses Product P0-1.
- **EC-2b added** → renderer's internal `tee | jq` pinned as
  orphan-safe by writer-process-model analysis (`tee` is
  short-lived; spawns no descendants). Addresses Design P0-3.
- **EC-1b added** → SIGKILL-of-dispatch.sh leak path bounded to
  per-issue dir; idempotent pre-clean at next dispatch start.
  Addresses Security P0-2.
- **EC-12 gains "Operator visibility post-fix"** → partial usage
  capture deterministically present on rc=124 paths.
- **OQ-5 resolved REJECT** → no `_PIPELINE_NO_PGRP=1` escape hatch
  for safety primitives. Addresses Security P1-3.
- **Inventory count corrected** → 13 enumerated canonical `USAGE_*`
  fixtures of ~27 total `_render_and_capture_stream` test sites.
  Addresses Coherence P1-2 and Feasibility P1-2.
- **`common.sh:17` → `common.sh:7`** (3 sites). Addresses
  Feasibility P1-1.

### Iter-2 verdicts

| Persona | Verdict | P0 |
|---|---|---|
| Design | PASS (iter-1, P0s addressed) | 0 remaining |
| Security | PASS (iter-1, P0s addressed) | 0 remaining |
| Scope | PASS (iter-1) | 0 |
| Coherence | PASS (iter-1, P1s addressed) | 0 |
| **Product** | **PASS (iter-2 re-review)** | **0** |
| **Feasibility** | **PASS** | **0** |

**Gate decision.** 6/6 PASS · feasibility 0 P0 · proceeding to planning.

### Residual P1s carried into planning

These are minor and intentional — plan stage absorbs them, not this
brainstorm:

- Plan stage enumerates "all `_render_and_capture_stream` test
  fixture sites" rather than pinning a count.
- §5 CLAUDE.md row prose is dense; plan stage may split into a
  multi-line bullet runbook for skimmability.
- G-1 post-fix log-line shape (literal `dispatch.sh exit=124` grep
  target) — plan stage pins the literal log shape if useful.
- OQ-6 sibling stuck-tick alarm — plan stage links the sibling
  ticket id (when filed) so the CLAUDE.md row's "if recurs" branch
  has a concrete pointer.

## 11. Assumption inventory

Every named line/function/file in this doc, verified or assumed:

| # | Claim | Status | Evidence |
|---|---|---|---|
| 1 | `bin/dispatch.sh:654-668` is the pipe call-site | **verified** | Read `bin/dispatch.sh:646-669` — the `if [[ -n "$log_file" ]]` arms invoke `"${cmd[@]}" < "$prompt_file" \| _render_and_capture_stream …` |
| 2 | `bin/dispatch.sh:620-645` is the `cmd` array build | **verified** | Read `bin/dispatch.sh:620-645` — `local cmd=(env … gtimeout … claude -p …)` |
| 3 | `bin/dispatch.sh:558-566` is the `gtime` discovery best-effort | **verified** | Read in current file — `command -v gtime` with graceful degradation |
| 4 | `_render_and_capture_stream`'s `tee` is at `bin/dispatch.sh:66-67` | **verified** | Read in current file |
| 5 | renderer's post-stream extractor reads `$raw_capture` at `bin/dispatch.sh:87-135` | **verified** | Read in current file |
| 6 | renderer's envelope sidecar write is `bin/dispatch.sh:142-144` | **verified** | Read in current file |
| 7 | `bin/dispatch.sh:507-508` installs `trap 'release_claude_mutex' EXIT` pre-acquire | **verified** | Read — "Install the release trap BEFORE the acquire so a die() between the two cannot leak the slot" |
| 8 | `bin/run-stage.sh:1441-1442` is the dispatch invocation site | **verified** | Read — `PIPELINE_ISSUE_ID="$ident" PIPELINE_DISPATCH_MODEL="$resolved_model" bash "$SCRIPT_DIR/dispatch.sh" …` |
| 9 | `bin/run-stage.sh:1444-1457` handles rc=124 with `classify_failure skip-until-human-acts` | **verified** | Read |
| 10 | `bin/run-stage.sh:1444-1567` is the full rc-switch table | **verified** | grep `dispatch_rc ==` in current file shows 22/23/26/29/31 branches |
| 11 | `bin/common.sh:276` maps 124 → `dispatch-timeout` | **verified** | grep `124)` in current file |
| 12 | `bin/run-local.sh:51-54` is the silent-skip path | **verified** | Read |
| 13 | `bin/run-local-helpers.sh:916-934` is `acquire_lock` with `kill -0` aliveness | **verified** | Read |
| 14 | `bin/dispatch-test.sh::AC-TRAP-BEFORE-ACQUIRE` pins trap-before-acquire invariant at lines ~3008-3033 | **verified** | grep `AC-TRAP-BEFORE-ACQUIRE` in current file |
| 15 | Existing renderer-stdin test fixtures in `bin/dispatch-test.sh` (~27 total `_render_and_capture_stream` call sites; the 13 canonical `USAGE_*` fixtures enumerated explicitly cover the ENG-26 cost-extractor pins) | **verified — pattern, not exact count** | Feasibility persona caught brainstorm's count drift; plan stage enumerates the full set instead of pinning a number |
| 16 | `setsid` is NOT on stock darwin | **verified** | `type setsid` returned "setsid not found" on this host |
| 17 | `/usr/bin/perl` is on stock darwin | **verified** | `type perl` returned `/usr/bin/perl` |
| 18 | `POSIX::setsid` is a core perl module | **assumed** (high confidence — POSIX has been bundled with perl since 5.0/1994 and ships with macOS perl by default) | Tested live perl invocation requires perl-exec permission not granted in dispatch context; will verify at implementation time as a precondition probe in the new test fixture |
| 19 | gtimeout's SIGTERM goes only to direct child, not descendants | **verified** | `man gtimeout` semantics; consistent with the 2026-05-15 incident behavior documented in the Linear issue body |
| 20 | MCP-server children inherit `claude`'s fd1 | **assumed** (industry-standard fork+exec inheritance; consistent with the observed symptom) | The 5h+ hang on 2026-05-15 is the strongest evidence; the alternative (fd1 NOT inherited) would not produce the observed reader-blocking behavior |
| 21 | `set -o pipefail` is set in `bin/common.sh:7` | **verified** | Read `bin/common.sh:7` — `set -euo pipefail` |
| 22 | `failure_outcome_for_exit` taxonomy doesn't need a new code | **verified** | A+B preserve existing rc taxonomy (124, 22/23/26/29/31, 0) |
| 23 | `AGENT_PROMPTS.md` does NOT need changes | **verified** | No prompt-level invariants are affected; orchestrator-only fix |
| 24 | `bin/pipeline-events.json` does NOT need new tokens | **verified** | No new verdict/transition tokens are introduced |
| 25 | The persistent envelope sidecar at `${issue_dir}/.envelope-transcript-${stage}` is preserved | **verified** | Renderer still writes it at `bin/dispatch.sh:142-144`; A doesn't bypass the renderer, only changes how data reaches it |
| 26 | Renderer's RETURN trap at `bin/dispatch.sh:56` removes the *internal* `$raw_capture` — distinct from our new `$_capture_path` | **verified** | Read line 56; the renderer's `raw_capture` is `${issue_dir}/.raw-stream.ndjson.tmp` |
| 27 | The existing `release_claude_mutex` invocation invariant (AC-TRAP-BEFORE-ACQUIRE) requires trap install on the line immediately preceding `acquire_claude_mutex` | **verified** | Read `bin/dispatch-test.sh::AC-TRAP-BEFORE-ACQUIRE` — pins the literal-line check |
| 28 | Bash 3.2 traps don't stack (second `trap … EXIT` replaces first) | **verified** | Documented bash behavior; cited verbatim in `bin/run-local.sh:56-58` |
| 29 | macOS `mktemp -t` writes under `$TMPDIR` (typically `/var/folders/.../T/`) | **verified** (standard darwin BSD mktemp behavior) | `man mktemp` on macOS |
| 30 | The Linear issue line refs (`bin/dispatch.sh:577-590`, `519-561`; `bin/run-local-helpers.sh:889-907`) are slightly stale vs. current code | **verified** | Issue's `:577-590` (pipeline shape) is currently at `:654-668`; `:519-561` (gtimeout invocation) overlaps with `:620-645` cmd-array build; `run-local-helpers.sh:889-907` ⊂ `:916-934` acquire_lock body. The DESCRIBED mechanisms are correct; only line numbers drifted between issue-filing and now. Brainstorm uses current line refs. |

**Assumed items requiring implementation-time verification:**

- Item 18 (`POSIX::setsid` available) — first thing the new test fixture should do is `perl -e 'use POSIX qw(setsid); print "ok\n"'` and bail early if unavailable. If somehow missing on a host, fall back to Homebrew gsetsid as Alt-B1 (would re-open the new-dependency cost, but is achievable).
- Item 20 (fd1 inheritance) — the failing test for A directly demonstrates this by spawning a background writer holding the inherited fd. If the test passes pre-A (i.e., the hang doesn't reproduce), the bug-class hypothesis is wrong and we need to re-investigate.
