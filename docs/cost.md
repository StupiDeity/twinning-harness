# Cost expectations

Honest disclosure on what running the harness costs. For the README
summary, see [Cost expectations](../README.md#cost-expectations).

> Numbers below are from my own usage during 2026-Q2 against a Claude
> Opus subscription. They are approximate, vary by stack and ticket
> shape, and will drift as model pricing and subscription tier limits
> change.

For most readers, the relevant currency is **tokens**, not dollars —
subscription users pay flat monthly and consume a token budget against
a 5-hour rolling window. Token counts are visible in every Linear
stage-summary comment as `in X.Yk · out Y.Yk · cache ZZ%`. This
document leads with tokens; dollar figures are secondary cross-reference
for metered-API users.

## Subscription vs metered API

The harness deliberately runs `claude -p` against the **logged-in
subscription session** on the host. `ANTHROPIC_API_KEY` must NOT be
set; if it is, the harness will refuse to dispatch.

| Mode | Rate-limit unit | What you watch | Visible "spend" |
|---|---|---|---|
| Subscription (default) | Tokens consumed against a 5-hour rolling window, plus tier-dependent weekly caps. Cached tokens are discounted but not free. | Output tokens + cache-read volume per stage; sustained throughput across 5-hour windows | Token counts in stage-summary cost lines (`in / out / cache`) and `usage-<stage>.json`. Dollar estimates are derived from public pricing, not actual billing. |
| Metered API | Dollars per token — separate rates for input, output, cache-read, cache-creation. | Cumulative dollar spend per ticket / per week | Real billing in your Anthropic console |

If you want metered pricing, change the `claude` CLI to use an API key
and unset the subscription session. **The harness is not designed for
this** — the per-host counting semaphore (default cap 2) + 5-minute tick
is calibrated against subscription rate limits, and you'll see throughput
throttle on the API without any benefit.

The rest of this document treats subscription mode as the baseline.

### How tokens map to subscription quota

Anthropic counts subscription consumption with cache-aware weighting —
output tokens dominate cost, cache-read tokens count at a steep
discount (typically ~10% of input), and the harness's prompt-caching
discipline keeps the bulk of input tokens cached.

For ballpark mental math:

- **Output tokens** drive ~70–80% of the effective subscription weight.
- **Cache-read tokens** are typically 95–99% of total volume but
  contribute proportionally little to the 5-hour cap.
- **New input tokens** are usually <5% of any dispatch and irrelevant
  to budget.

So when you see `out 33k · cache 99%` in a stage summary, the
subscription impact is closer to "33k weighted tokens" than to the
~1.5M raw total volume.

## Per-stage token and cost ranges

From a sample of ~80 stage dispatches across the harness's own ENG-N
tickets:

| Stage | p50 output | p90 output | Cache hit (typical) | Cost p50 / p90 |
|---|---|---|---|---|
| brainstorming | ~25k | ~50k | 95–99% | $1.20 / $4.80 |
| planning | ~20k | ~40k | 95–98% | $0.80 / $2.40 |
| implementing | ~20k | ~50k | 95–98% | $2.50 / $7.50 |
| ui | ~3k (no-op) – ~20k (active) | ~30k | 95–97% | $0.10 / $3.20 |
| reviewing | ~10k | ~30k | 96–99% | $0.50 / $1.40 |
| qa | ~15k | ~35k | 95–99% | $1.00 / $3.50 |
| building | ~5k | ~15k | 98–99% | $0.20 / $0.60 |
| released | ~3k | ~10k | 98–99% | $0.10 / $0.30 |

The 90th-percentile column is a closer match for "feature with one
realistic recovery." The p50 column matches the boring happy-path runs
like ENG-83.

Reference points from the demo transcripts (visible in
`docs/demos/eng-59-thread.md` and `eng-83-thread.md`):

| Stage | Demo run | `in / out / cache` | Cost |
|---|---|---|---|
| brainstorming | ENG-59 (1st pass) | `0.1k / 33.4k / 99%` | $4.29 |
| brainstorming | ENG-83 (clean) | `0.0k / 46.1k / 97%` | $4.38 |
| planning | ENG-59 | `4.8k / 34.0k / 98%` | $6.95 |
| planning | ENG-83 | `1.4k / 36.5k / 98%` | $4.89 |
| implementing | ENG-59 (2nd attempt, post-resume) | `0.2k / 15.0k / 97%` | $1.96 |
| ui | ENG-59 (no-op pass-through) | `0.0k / 2.8k / 95%` | $0.59 |
| qa | ENG-59 | `0.1k / 22.7k / 99%` | $5.27 |
| building | ENG-59 | `0.0k / 6.2k / 99%` | $0.91 |

These specific runs all came in at or above p50 for their stages —
ENG-59 was a halt-and-resume narrative, ENG-83 was an architecturally
heavier brainstorm than typical. Treat the demo numbers as upper-mid
range, not as p50.

### What drives the variance

1. **Diff size.** `implementing` output tokens scale roughly linearly
   with the number of lines the agent writes — every modified line
   appears in the agent's context window for re-reading.
2. **Iteration count.** Brainstorm and planning may iterate up to 2
   times under persona-review pressure (ENG-65 cap). Each iteration
   approximately doubles output tokens AND blows away some of the cache
   gains.
3. **Halt-and-resume.** Each halt + recovery cycle re-dispatches at
   least one stage. Output tokens for the second attempt are typically
   60–80% of the first, since cache is warm and the agent's context is
   smaller.
4. **Cache hit rate.** The harness uses prompt caching aggressively;
   a warm cache turns a $4 dispatch into a ~$1.40 dispatch *and* keeps
   the same dispatch from chewing through 5-hour cap headroom. Cold
   cache happens on the first dispatch in a 5-minute window after a
   long idle, or when the prompt itself changes (e.g., after a
   `learned-rules/` PR merges).

## Per-issue token trajectories

A typical small ticket (1-day developer-equivalent — a focused bug fix
or a small feature with one acceptance criterion):

```
Stage          out tokens   cache    cost
─────────────────────────────────────────
brainstorming   25k          ~98%   $1.20
planning        20k          ~98%   $0.80
implementing    20k          ~97%   $2.50
ui               3k          ~95%   $0.10  (no-op pass-through)
reviewing       10k          ~98%   $0.50
qa              15k          ~98%   $1.00
building         5k          ~99%   $0.20
released         3k          ~99%   $0.10
─────────────────────────────────────────
                ~101k out                $6.40
```

A complex feature with one halt-and-resume cycle:

```
Stage                 out tokens   cache    cost
────────────────────────────────────────────────────────
brainstorming          50k          ~96%   $4.80   (persona iteration to converge)
planning               40k          ~97%   $2.40
implementing (1st)     45k          ~96%   $7.50
implementing (2nd)     30k          ~98%   $4.20   (cache warm, smaller delta)
ui                     25k          ~96%   $3.00
reviewing              25k          ~97%   $1.40
qa                     35k          ~98%   $3.50
building (wait, ×2)     0k          —      $0.20   (entry-conditions skips dispatch)
building (merge)       12k          ~99%   $0.60
released                8k          ~99%   $0.30
────────────────────────────────────────────────────────
                      ~270k out                   $27.90
```

Output token totals per issue:
- **Small ticket**: ~100k output tokens.
- **Complex feature with one recovery**: ~250–300k output tokens.

Cache-read total volume per issue is typically 50–150× the output
total — a complex issue may move 15–40M cache-read tokens. These
contribute much less to the 5-hour cap than raw counts suggest, but
they're not free.

## Monthly budget projections

The retrospective adds ~30–60k output tokens per week (~$2–$5)
regardless of throughput.

| Throughput | Issues / week | Output / week | Output / month | Cost / month |
|---|---|---|---|---|
| Light | 2 small | ~250k | ~1M | $50–$80 |
| Moderate | 5 mixed | ~750k | ~3M | $130–$200 |
| Heavy | 10 mixed + 2 complex | ~2M | ~8M | $300–$450 |

Subscription users: compare against your tier's published 5-hour and
weekly caps. Anthropic publishes these per tier and they shift; check
the current limits at the Claude Code documentation. Heavy throughput
on a Pro subscription will hit the rolling cap; Max plans typically
absorb it cleanly.

The 5-minute tick is the natural rate-limiter — at most 12 dispatches
per hour from one project. Multi-project setups share the per-host
counting semaphore (default cap 2 via `orchestrator.max_concurrent_features`),
so throughput is bounded by the cap regardless of project count.

## Cost telemetry on disk

Every dispatch writes a usage file at
`$PROJECT_STATE_DIR/<ident>/usage-<stage>.json`:

```json
{
  "stage": "implementing",
  "cost_usd": 4.12,
  "input_tokens": 142000,
  "output_tokens": 8200,
  "cache_read_tokens": 380000,
  "cache_creation_tokens": 12000,
  "model": "claude-opus-4-7"
}
```

For subscription users, the load-bearing fields are:
- `output_tokens` — the dominant subscription-quota driver.
- `cache_read_tokens / (input_tokens + cache_read_tokens)` — the
  cache hit rate. >95% means the harness is doing its job.
- `cache_creation_tokens` — should be small and bursty; persistent
  high values mean the prompt is changing every dispatch (e.g., a
  bug in `learned-rules/` rendering).

When SIGTERM fires before a `result` event lands (dispatch timeout),
the renderer writes a partial file with `cost_usd: null` and
`partial: true`. The retrospective uses `partial: true` as the
discriminator for SIGTERM-captured runs.

### Aggregation queries

```bash
# Output tokens for one issue:
jq -r 'select(.issue=="ENG-5" and .event=="stage-end") | .output_tokens // 0' \
  "$PROJECT_STATE_DIR/metrics/events.jsonl" | awk '{s+=$1} END{print s}'

# Output tokens this week:
jq -r 'select(.event=="stage-end" and .ts >= "2026-05-05") | .output_tokens // 0' \
  "$PROJECT_STATE_DIR/metrics/events.jsonl" | awk '{s+=$1} END{print s}'

# Output tokens by stage, this month:
jq -r 'select(.event=="stage-end" and .ts >= "2026-05-01")
  | "\(.stage) \(.output_tokens // 0)"' \
  "$PROJECT_STATE_DIR/metrics/events.jsonl" \
  | awk '{s[$1]+=$2; c[$1]+=1} END{for(k in s) printf "%-15s %8d  (n=%d)\n", k, s[k], c[k]}'

# Cache hit rate by stage, this month:
jq -r 'select(.event=="stage-end" and .ts >= "2026-05-01")
  | "\(.stage) \(.cache_read_tokens // 0) \((.input_tokens // 0) + (.cache_read_tokens // 0))"' \
  "$PROJECT_STATE_DIR/metrics/events.jsonl" \
  | awk '{cr[$1]+=$2; tot[$1]+=$3} END{for(k in cr) printf "%-15s %.1f%%\n", k, 100*cr[k]/tot[k]}'

# Total cost for one issue (USD, for cross-reference):
jq -r 'select(.issue=="ENG-5" and .event=="stage-end") | .cost_usd // 0' \
  "$PROJECT_STATE_DIR/metrics/events.jsonl" | awk '{s+=$1} END{printf "$%.2f\n", s}'

# Rolling 5-hour output-token total (use this to predict cap pressure):
jq -r --arg cutoff "$(date -u -v-5H +%Y-%m-%dT%H:%M:%SZ)" \
  'select(.event=="stage-end" and .ts >= $cutoff) | .output_tokens // 0' \
  "$PROJECT_STATE_DIR/metrics/events.jsonl" | awk '{s+=$1} END{print s}'
```

## Optimization strategies

### Cap the timeout (ENG-65)

The default per-stage cap is 30 min (60 min for brainstorming/planning).
Tighter caps reduce worst-case spend on stalled agents, at the cost of
SIGTERM mid-iteration on legitimate work:

```json
{
  "orchestrator": {
    "dispatch_timeout_minutes": 20,
    "dispatch_timeout_minutes_per_stage": {
      "brainstorming": 30,
      "planning":      20
    }
  }
}
```

Trade-off: a 20-minute brainstorm cap will SIGTERM persona-review on
complex specs, which costs you a halt-and-resume cycle (one extra
dispatch ≈ 30k output tokens). For simple specs, the saving is
~30k output tokens (~$2–$3) per stalled-agent incident.

See [`configuration.md#orchestratordispatch_timeout_minutes_per_stage`](configuration.md#orchestratordispatch_timeout_minutes_per_stage)
for the full schema.

### Skip dispatches when not actionable (ENG-86)

The entry-conditions gate at build P2 saves ~5–8k output tokens per
tick (~$0.50) when no human approval is present. Already on by default
in the harness-self config:

```json
{
  "orchestrator": {
    "entry_conditions": {
      "building": [
        { "name": "pr-approved-by-non-bot", "type": "github-pr-review" }
      ]
    }
  }
}
```

For a typical issue stuck in build-wait for 24 hours (e.g., overnight
before you wake up to approve), this saves 12–24 dispatch invocations
× ~6k output tokens = **70–150k output tokens** ($6–$12 equivalent)
per pending PR.

### Tighten scope at the spec stage

The biggest cost lever is not config — it's writing better Linear
issues. Vague specs produce vague brainstorms (high output tokens, more
iterations) which produce wrong implementations (re-dispatch cost).
The [`LINEAR_ISSUE_TEMPLATE.md`](../LINEAR_ISSUE_TEMPLATE.md)'s
**Scope Boundaries** field is the highest-ROI thing to fill out — if
absent, the brainstorm agent gold-plates aggressively, producing 50k+
output tokens where 20k would have sufficed, then paying for the
gold-plating across every downstream stage.

A 10-minute spec edit can save ~50k output tokens (~$5–$10) per
issue.

### Pause unused projects

The 5-minute tick fires regardless of whether issues are ready. If
you have a project with no active work, set
`orchestrator.paused: true` in `state.local.json`. The launchd job
still fires every 5 min but exits in <1 second — zero token
consumption.

## When token usage surprises you

Open `$PROJECT_STATE_DIR/metrics/events.jsonl` and look for:

1. **Output-token outliers** — a stage that emitted 3× p90. Usually a
   malformed spec triggered persona-iteration, OR the agent went down
   a rabbit hole and the 30-min timeout caught it mid-explanation.
2. **Cache hit rate dropping below 95%** — a sign the prompt itself is
   churning. Check whether `learned-rules/` recently merged a PR (cache
   invalidates on prompt change), or whether `AGENT_PROMPTS.md` has
   been edited mid-week.
3. **Repeated re-dispatches of the same (issue, stage) pair** —
   indicates a halt-loop. Output tokens per re-dispatch typically
   compound. The retrospective should catch this; manually intervene
   by halting the issue with `--action abandon` if the spec is bad.
4. **`partial: true` runs** — SIGTERM-captured dispatches. The
   `output_tokens` field IS still populated on these (summed from
   per-message `assistant.message.usage.*` deltas) — so subscription
   quota usage is accurate even when `cost_usd` is null.
5. **Subscription cap hit warnings** in `claude` CLI output — the
   harness logs these to the per-stage transcript. If you see
   "rate-limited" errors clustered, check the rolling-5h-output query
   above and consider pausing.

The retrospective writes a weekly token-and-cost analysis as part of
its rule-update PR. If you're not reading those PRs, you're missing
the natural optimization signal — read them.
