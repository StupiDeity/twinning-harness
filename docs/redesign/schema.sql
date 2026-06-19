-- ============================================================================
-- Twinning Harness — Redesign SQLite Schema  (CUTOVER SUBSTRATE)
-- ----------------------------------------------------------------------------
-- Artifact for §9.4 checklist #1 of ~/code/harness-redesign-brainstorm.md.
-- Single transactional Source-of-Truth (design move 2). Replaces the current
-- 3-medium state machine: Linear labels + Linear comments + per-issue JSON.
--
-- SCOPE (hard boundary, per §9.1 + §10):
--   IN : everything run-local / poll / run-stage reconstruct each tick today —
--        per-ticket state, work-unit decomposition (C1), the durable step
--        journal + signals (B1/B3), dispatch records, ground-truth signals (A1),
--        the control-event log (the durable replacement for Linear markers),
--        telemetry, and the Linear/GitHub one-way projection (move 2 / §9.4 #4).
--   OUT: the UGL / supervisor / memory-RAG tables (§5.8, E1/E2). Those are
--        post-cutover increments I-C/I-D. A forward-compatible STUB is sketched
--        (commented, NOT created) at the end so we don't paint into a corner.
--
-- INVARIANT (B2): only the daemon writes this DB. Workers return results; the
--   daemon journals them. Single-writer by construction ⇒ two-authoritative-
--   writers (ENG-217) is impossible. WAL gives concurrent readers (status cmd).
--
-- CONVENTIONS (decisions — see brainstorm §12 for rationale):
--   * Timestamps   : STORED as TEXT, ISO-8601 UTC ('YYYY-MM-DDTHH:MM:SSZ') — one
--                    canonical internal form; lexically sortable; sqlite3-CLI
--                    debuggable. DISPLAY converts UTC -> the operator's LOCAL
--                    timezone at render time (status CLI, Slack, logs). Storage is
--                    never local-tz; tz-conversion is a display-layer concern only.
--   * Enums        : CHECK constraints (SQLite has no native ENUM).
--   * Booleans     : INTEGER 0/1 with CHECK.
--   * JSON columns  : TEXT, guarded by json_valid() where load-bearing (json1).
--   * Keys         : surrogate INTEGER PRIMARY KEY (rowid alias) + natural
--                    UNIQUE() business keys. Harness is MULTI-PROJECT, so every
--                    business key is scoped by project_id.
-- ============================================================================

PRAGMA journal_mode = WAL;        -- persistent; single-writer + concurrent readers
PRAGMA foreign_keys = ON;         -- per-connection: the daemon MUST set this each open
PRAGMA busy_timeout = 5000;       -- per-connection hint

-- ----------------------------------------------------------------------------
-- schema_meta — migration version marker
-- ----------------------------------------------------------------------------
CREATE TABLE schema_meta (
    version     INTEGER NOT NULL,
    applied_at  TEXT    NOT NULL,
    note        TEXT
);
INSERT INTO schema_meta (version, applied_at, note)
VALUES (1, strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'initial cutover substrate');

-- ============================================================================
-- §A  PROJECT + TICKET   (replaces issue-state.json + stage:* / pipeline:* labels)
-- ============================================================================

-- project — per-PROJECT_SLUG namespace (the harness runs many targets).
CREATE TABLE project (
    id              INTEGER PRIMARY KEY,
    slug            TEXT    NOT NULL UNIQUE,          -- PROJECT_SLUG (frozen at setup)
    target_repo     TEXT    NOT NULL,                 -- absolute path on host
    default_branch  TEXT    NOT NULL DEFAULT 'main',
    linear_team_key TEXT,                             -- e.g. 'ENG'
    config_json     TEXT CHECK (config_json IS NULL OR json_valid(config_json)),
    paused          INTEGER NOT NULL DEFAULT 0 CHECK (paused IN (0,1)),  -- global breaker
    created_at      TEXT    NOT NULL,
    updated_at      TEXT    NOT NULL
);

-- ticket — the per-ticket SoT row. One row per Linear issue under harness control.
--   `stage`  is the pipeline POSITION (new C1 lifecycle), authoritative; the
--            Linear `stage:*` label is a projection of it (§F).
--   `status` is the lifecycle disposition, separated from stage (the legacy
--            model conflated them into stage:X + pipeline:halted labels).
--   `policy` is the skip-dance policy ported verbatim from issue-state.json;
--            the `pipeline:skip-until-*` labels are projections of it.
CREATE TABLE ticket (
    id                    INTEGER PRIMARY KEY,
    project_id            INTEGER NOT NULL REFERENCES project(id),
    ident                 TEXT    NOT NULL,                  -- 'ENG-5'
    linear_issue_uuid     TEXT,                              -- resolved lazily; for projection
    title                 TEXT,

    -- Branch shape (load-bearing — branch-name.sh re-derives prefix from type_label).
    type_label            TEXT CHECK (type_label IN ('Bug','Feature','Improvement')),
    branch_prefix         TEXT CHECK (branch_prefix IN ('fix','feat')),  -- Bug->fix else feat
    branch_name           TEXT,                              -- 'feat/ENG-5-slug' (empty pre-implement)
    branch_head_sha       TEXT,

    -- Pipeline position + disposition.
    -- CLEAN BREAK (operator 2026-06-19): the new C1 lifecycle is the vocab from day
    -- one — NOT the legacy gerund stages. Migration surface is tiny: only the handful
    -- of In-Progress / In-Review tickets are hand-mapped at import; Backlog tickets
    -- carry no harness stage yet, so nothing to translate. Implement decomposes into
    -- work_unit rows (kind-tagged); UI is a frontend work-unit + a visual verify
    -- check-type, never a stage.
    stage                 TEXT NOT NULL CHECK (stage IN (
                              'design',      -- brainstorm + plan fused
                              'implement',   -- decomposes into work_unit dispatches
                              'verify',      -- ground-truth verify (build/tests/scope)
                              'review',      -- independent cold-context reviewer (A4)
                              'merge',       -- human-gated (D2)
                              'released')),  -- terminal; post-merge release watch
    status                TEXT NOT NULL DEFAULT 'active' CHECK (status IN (
                              'active','halted','waiting','abandoned','done')),
    track                 TEXT CHECK (track IN ('fast','full')),         -- C2 sizing rubric

    -- Failure / skip state (ported from issue-state.json verbatim).
    policy                TEXT CHECK (policy IN (
                              'retry-immediately','skip-until-code-changes',
                              'skip-until-human-acts','none')),
    reason                TEXT,                              -- last failure prose
    exit_code             INTEGER,
    exit_subcode          INTEGER,
    retry_count           INTEGER NOT NULL DEFAULT 0,        -- same-evidence retry counter
    recorded_at           TEXT,                              -- when last failure recorded

    -- Evidence (issue-state.json::evidence{} — drives auto-resume from skip).
    pipeline_content_hash TEXT,                              -- sha256(bin/** + config + prompts)
    -- (branch_head_sha above doubles as evidence.branch_head_sha)

    -- Dispatch allocator (issue-state.json::current_dispatch_*; monotonic, never resets).
    current_dispatch_seq  INTEGER NOT NULL DEFAULT 0,
    current_dispatch_id   TEXT,                              -- 'ENG-5-d0003'

    -- Linear projection mirror (read-only view of what we last projected).
    linear_state          TEXT,                              -- 'Todo'/'In Progress'/...
    priority              INTEGER,

    created_at            TEXT NOT NULL,
    updated_at            TEXT NOT NULL,

    UNIQUE (project_id, ident)
);
CREATE INDEX idx_ticket_ready ON ticket (project_id, status, stage);

-- ============================================================================
-- §B  WORK-UNIT DECOMPOSITION   (C1 — plan splits a ticket into focused units)
-- ============================================================================
-- Each work-unit is its OWN dispatch with kind-appropriate tools + clean context.
-- UI is NOT a stage: it is a frontend work-unit (kind) + a visual verify check-type.
-- Backend-only ticket = 1 unit = 1 dispatch (no waste).
CREATE TABLE work_unit (
    id                INTEGER PRIMARY KEY,
    ticket_id         INTEGER NOT NULL REFERENCES ticket(id) ON DELETE CASCADE,
    seq               INTEGER NOT NULL,                  -- order within the ticket
    kind              TEXT    NOT NULL,                  -- OPEN vocab from project-profile
                                                         -- stack ('backend'/'frontend'/'data'
                                                         -- /'infra'/'test'/'docs'/...). NOT a
                                                         -- CHECK enum — stack-agnostic (de-webs ENG-167).
    title             TEXT,
    description       TEXT,

    -- A3 advisory scope: the plan's declared files_to_touch (reviewer judges expansion,
    -- NOT a hard gate — kills the ENG-194 catch-22).
    files_to_touch    TEXT CHECK (files_to_touch IS NULL OR json_valid(files_to_touch)),

    -- A1 test gate: behavioral ⇒ test required; non-behavioral exempt (design classifies).
    behavioral        INTEGER NOT NULL DEFAULT 1 CHECK (behavioral IN (0,1)),
    test_plan         TEXT,                              -- realized as a real test by verify

    -- C3 verify: which ground-truth check-types this unit needs.
    verify_check_types TEXT CHECK (verify_check_types IS NULL OR json_valid(verify_check_types)),
                                                         -- e.g. ["unit","integration","visual","playwright"]

    depends_on        TEXT CHECK (depends_on IS NULL OR json_valid(depends_on)),  -- [seq,...]
    status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN (
                          'pending','implementing','verifying','verified','blocked','merged')),
    created_at        TEXT NOT NULL,
    updated_at        TEXT NOT NULL,

    UNIQUE (ticket_id, seq)
);
CREATE INDEX idx_work_unit_ticket ON work_unit (ticket_id, status);

-- ============================================================================
-- §C  DURABLE EXECUTION   (B1/B3 — the step journal + signals; the core)
-- ============================================================================
-- Canonical durable-execution pattern. A WORKFLOW = a ticket (long-running).
-- A STEP that already ran returns its recorded result on replay (deterministic
-- replay keyed by step_key). Crash mid-step resumes at that step. External
-- side-effects carry an idempotency_key checked before re-execution.

CREATE TABLE workflow_step (
    id              INTEGER PRIMARY KEY,
    ticket_id       INTEGER NOT NULL REFERENCES ticket(id) ON DELETE CASCADE,
    work_unit_id    INTEGER REFERENCES work_unit(id) ON DELETE CASCADE,  -- nullable: ticket-level steps
    seq             INTEGER NOT NULL,                  -- monotonic within the workflow
    step_key        TEXT    NOT NULL,                  -- deterministic name (replay dedup anchor)
    step_type       TEXT    NOT NULL,                  -- 'dispatch'/'verify'/'project'/
                                                       -- 'await_signal'/'transition'/'compensate'/...
    status          TEXT    NOT NULL DEFAULT 'pending' CHECK (status IN (
                        'pending','running','succeeded','failed','compensated')),
    attempt         INTEGER NOT NULL DEFAULT 0,        -- retry count at the step layer

    -- B3 exactly-once: side-effecting steps set an idempotency_key; the daemon
    -- checks did-this-already-happen before replay. Partial-unique (NULLs allowed).
    idempotency_key TEXT,

    input_json      TEXT CHECK (input_json  IS NULL OR json_valid(input_json)),
    result_json     TEXT CHECK (result_json IS NULL OR json_valid(result_json)),  -- returned on replay
    error_json      TEXT CHECK (error_json  IS NULL OR json_valid(error_json)),

    await_signal_id INTEGER REFERENCES signal(id),     -- set when step parks on a durable wait
    started_at      TEXT,
    ended_at        TEXT,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,

    UNIQUE (ticket_id, step_key)                       -- determinism: one row per logical step
);
CREATE UNIQUE INDEX idx_step_idempotency
    ON workflow_step (idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX idx_step_runnable ON workflow_step (ticket_id, status, seq);

-- signal — durable signals / human-waits (B1 "durable human-waits").
-- Replaces wait-<stage>.json + soft-pending parking + the build approval gate.
-- A step awaits a signal; the signal flips pending->delivered out-of-band
-- (operator action, CI webhook, reviewer verdict); replay resumes the step.
CREATE TABLE signal (
    id              INTEGER PRIMARY KEY,
    ticket_id       INTEGER NOT NULL REFERENCES ticket(id) ON DELETE CASCADE,
    signal_type     TEXT    NOT NULL,                  -- 'human_merge_approval'/'human_plan_approval'
                                                       -- /'human_resume'/'external_ci'/'external_review'
    status          TEXT    NOT NULL DEFAULT 'pending' CHECK (status IN (
                        'pending','delivered','consumed')),
    -- Wait-budget fields ported from wait-<stage>.json (external_signal_budget).
    reason          TEXT,                              -- 'awaiting-approval'/'awaiting-ci'
    attempts        INTEGER NOT NULL DEFAULT 0,
    max_attempts    INTEGER,
    first_attempt_at TEXT,
    last_attempt_at  TEXT,

    payload_json    TEXT CHECK (payload_json IS NULL OR json_valid(payload_json)),
    idempotency_key TEXT,                              -- dedup duplicate deliveries
    requested_at    TEXT NOT NULL,
    delivered_at    TEXT,
    consumed_at     TEXT
);
CREATE UNIQUE INDEX idx_signal_idempotency
    ON signal (idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX idx_signal_pending ON signal (ticket_id, status);

-- ============================================================================
-- §D  DISPATCH RECORDS   (replaces dispatch_history.jsonl + usage-*.json)
-- ============================================================================
-- One row per `claude -p` invocation. Forensic + control. The agent-invocation
-- step (§C step_type='dispatch') links here.
CREATE TABLE dispatch (
    id                      INTEGER PRIMARY KEY,
    ticket_id               INTEGER NOT NULL REFERENCES ticket(id) ON DELETE CASCADE,
    work_unit_id            INTEGER REFERENCES work_unit(id) ON DELETE SET NULL,
    step_id                 INTEGER REFERENCES workflow_step(id) ON DELETE SET NULL,

    dispatch_id             TEXT    NOT NULL,           -- 'ENG-5-d0003'
    seq                     INTEGER NOT NULL,           -- 3
    predecessor_dispatch_id TEXT,                       -- 'ENG-5-d0002' or NULL on d0001
    stage                   TEXT,                       -- pipeline stage at dispatch time
    kind                    TEXT,                       -- work-unit kind (NULL for ticket-level)
    model                   TEXT,                       -- 'claude-opus-4-7' (resolved)
    effort                  TEXT,
    trigger                 TEXT,                       -- 'transition'/'retry'/'escalation'/'resume'

    -- Outcome (failure_outcome_for_exit taxonomy — common.sh).
    outcome                 TEXT,                       -- 'clean-success'/'dispatch-failed'/
                                                        -- 'dispatch-timeout'/'guards-tripped'/...
    exit_code               INTEGER,
    exit_subcode            INTEGER,
    verdict_emitted         TEXT CHECK (verdict_emitted IS NULL OR verdict_emitted IN (
                                'pass','fail','halt','wait','pivot')),
    verdict_target          TEXT,

    -- Provenance snapshot (the dispatch_history start-row fields).
    branch                  TEXT,
    branch_head_sha         TEXT,
    pipeline_content_hash   TEXT,
    worktree_path           TEXT,
    transcript_path         TEXT,

    -- Timing + usage (usage-<stage>.json; cost_usd NULL + partial=1 on SIGTERM).
    started_at              TEXT,
    ended_at                TEXT,
    duration_ms             INTEGER,
    tokens_in               INTEGER,
    tokens_out              INTEGER,
    cache_read              INTEGER,
    cache_create            INTEGER,
    cost_usd                REAL,
    partial                 INTEGER NOT NULL DEFAULT 0 CHECK (partial IN (0,1)),

    envelope_json           TEXT CHECK (envelope_json IS NULL OR json_valid(envelope_json)),
    created_at              TEXT NOT NULL,

    UNIQUE (ticket_id, dispatch_id)
);
CREATE INDEX idx_dispatch_ticket ON dispatch (ticket_id, seq);

-- ============================================================================
-- §E  CONTROL-EVENT LOG   (durable replacement for state-driving Linear markers)
-- ============================================================================
-- The verdict / transition / decision markers (bin/pipeline-events.json) are
-- TODAY Linear comments that DRIVE control flow. In the new model they are rows
-- here (authoritative); Linear comments become a projection (§F). Guard counters
-- (review_rejection / implement_rejection / qa_rejection) DERIVE from this table
-- (see v_rejection_counts) instead of being re-grepped from Linear each tick.
CREATE TABLE pipeline_event (
    id           INTEGER PRIMARY KEY,
    ticket_id    INTEGER NOT NULL REFERENCES ticket(id) ON DELETE CASCADE,
    seq          INTEGER NOT NULL,                      -- monotonic per ticket (ordering/freshness)
    kind         TEXT NOT NULL CHECK (kind IN ('verdict','transition','decision')),
    author       TEXT CHECK (author IN ('orchestrator','operator','supervisor')),
    dispatch_id  TEXT,                                  -- freshness anchor (ENG-87 D-005 contract)

    -- verdict: result + (stage|target|reason)
    result       TEXT CHECK (result IS NULL OR result IN ('pass','fail','halt','wait','pivot')),
    stage        TEXT,
    target       TEXT,                                  -- fail/pivot target stage
    reason       TEXT,                                  -- halt_reasons / wait_reasons / pivot reason

    -- transition: from -> to
    from_stage   TEXT,
    to_stage     TEXT,

    -- decision (operator): action + gate
    action       TEXT CHECK (action IS NULL OR action IN ('continue','approve','abandon')),
    gate         TEXT CHECK (gate IS NULL OR gate IN ('scope','build-cap')),

    payload_json TEXT CHECK (payload_json IS NULL OR json_valid(payload_json)),
    created_at   TEXT NOT NULL,

    UNIQUE (ticket_id, seq)
);
CREATE INDEX idx_event_ticket_kind ON pipeline_event (ticket_id, kind, seq);

-- metric_event — telemetry (replaces $PROJECT_STATE_DIR/metrics/events.jsonl).
-- Forensic / north-star metrics; NOT control flow.
CREATE TABLE metric_event (
    id           INTEGER PRIMARY KEY,
    project_id   INTEGER NOT NULL REFERENCES project(id),
    ticket_id    INTEGER REFERENCES ticket(id) ON DELETE SET NULL,
    ts           TEXT NOT NULL,
    event        TEXT NOT NULL,                         -- 'stage-start'/'stage-end'/'human-decision'/...
    stage        TEXT,
    outcome      TEXT,                                  -- failure_outcome taxonomy
    duration_ms  INTEGER,
    dispatch_id  TEXT,
    tokens_in    INTEGER,
    tokens_out   INTEGER,
    cache_read   INTEGER,
    cache_create INTEGER,
    cost_usd     REAL,
    model        TEXT,
    notes        TEXT                                   -- space-separated k=v or free text (as today)
);
CREATE INDEX idx_metric_ts ON metric_event (project_id, ts);

-- ============================================================================
-- §F  GROUND-TRUTH VERIFICATION   (A1/A2 — move 5; replaces self-report grading)
-- ============================================================================
-- Objective + EXTERNAL to the agent. Layered: build -> tests -> diff⊆scope (advisory)
-- -> independent reviewer -> CI green (required check = merge arbiter).
CREATE TABLE ground_truth_signal (
    id              INTEGER PRIMARY KEY,
    ticket_id       INTEGER NOT NULL REFERENCES ticket(id) ON DELETE CASCADE,
    work_unit_id    INTEGER REFERENCES work_unit(id) ON DELETE CASCADE,
    dispatch_id     TEXT,                               -- the verify dispatch that produced it
    signal_type     TEXT NOT NULL CHECK (signal_type IN (
                        'build','test','scope_diff','reviewer','ci')),
    result          TEXT NOT NULL CHECK (result IN ('pass','fail','error')),
    is_authoritative INTEGER NOT NULL DEFAULT 0 CHECK (is_authoritative IN (0,1)),  -- CI = merge arbiter
    command         TEXT,                               -- project-profile command run (A1/F4)
    detail_json     TEXT CHECK (detail_json IS NULL OR json_valid(detail_json)),
                                                        -- {tests_passed,tests_failed} / {paths:[...]}
                                                        -- / {check_name,url,conclusion}
    measured_at     TEXT NOT NULL
);
CREATE INDEX idx_gts_ticket ON ground_truth_signal (ticket_id, signal_type, measured_at);

-- review_finding — the independent reviewer's output (A2). Mirrors the real
-- review-ledger fields (review-ledger-schema.sh) so the reviewer leaf can emit
-- content-only and the daemon owns the envelope. First-class (not buried in JSON)
-- because the loop iterates over open blocking findings.
CREATE TABLE review_finding (
    id                          INTEGER PRIMARY KEY,
    ticket_id                   INTEGER NOT NULL REFERENCES ticket(id) ON DELETE CASCADE,
    work_unit_id                INTEGER REFERENCES work_unit(id) ON DELETE CASCADE,
    dispatch_id                 TEXT,                   -- the reviewing dispatch
    iteration                   INTEGER,
    finding_class_key           TEXT,                   -- '<dimension>:<scope-anchor>:<concept-slug>'
    cold_severity               TEXT CHECK (cold_severity        IN ('critical','major','minor','nit')),
    adjudicated_severity        TEXT CHECK (adjudicated_severity IN ('critical','major','minor','nit')),
    decision                    TEXT CHECK (decision IN ('carry','stabilise','defer-candidate','block')),
    blocks_ship                 INTEGER CHECK (blocks_ship IN (0,1)),  -- mandatory when adj∈{major,critical}
    ship_classification_rationale TEXT,
    decision_factors_json       TEXT CHECK (decision_factors_json IS NULL OR json_valid(decision_factors_json)),
                                                        -- {in_changed_code,is_regression,user_visible,
                                                        --  reversible_post_ship,has_workaround}
    rationale                   TEXT,
    target_path                 TEXT,
    status                      TEXT NOT NULL DEFAULT 'open' CHECK (status IN (
                                    'open','fixed','deferred','wont-fix')),
    created_at                  TEXT NOT NULL
);
CREATE INDEX idx_finding_open ON review_finding (ticket_id, status, blocks_ship);

-- ============================================================================
-- §G  LINEAR / GITHUB PROJECTION   (move 2 / §9.4 #4 — one-way, idempotent)
-- ============================================================================
-- NO code path reads Linear/GitHub to decide control flow. All outward writes
-- go through ONE projector that drains the transactional outbox idempotently.

-- linear_id_cache — the linear-ids.json cache, moved into the SoT for the projector.
CREATE TABLE linear_id_cache (
    id          INTEGER PRIMARY KEY,
    project_id  INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    entity_type TEXT NOT NULL CHECK (entity_type IN ('team','project','state','label')),
    name        TEXT NOT NULL,                          -- 'Todo' / 'stage:implementing' / 'Bug'
    uuid        TEXT NOT NULL,
    refreshed_at TEXT NOT NULL,
    UNIQUE (project_id, entity_type, name)
);

-- projection_state — current projected snapshot per ticket per target (high-water mark).
CREATE TABLE projection_state (
    id                     INTEGER PRIMARY KEY,
    ticket_id              INTEGER NOT NULL REFERENCES ticket(id) ON DELETE CASCADE,
    target                 TEXT NOT NULL CHECK (target IN ('linear','github')),
    projected_stage_label  TEXT,                        -- last 'stage:*' set
    projected_status_labels_json TEXT CHECK (projected_status_labels_json IS NULL
                                             OR json_valid(projected_status_labels_json)),
    projected_linear_state TEXT,                        -- 'In Progress'/...
    last_projected_event_seq INTEGER NOT NULL DEFAULT 0,-- pipeline_event.seq high-water mark
    last_projected_at      TEXT,
    UNIQUE (ticket_id, target)
);

-- projection_outbox — transactional outbox. A SoT write + its outbox row commit
-- in the SAME transaction; the projector drains pending rows, applies them
-- idempotently (idempotency_key), and marks sent. Crash-safe + exactly-once (B3).
CREATE TABLE projection_outbox (
    id              INTEGER PRIMARY KEY,
    ticket_id       INTEGER NOT NULL REFERENCES ticket(id) ON DELETE CASCADE,
    target          TEXT NOT NULL CHECK (target IN ('linear','github')),
    op              TEXT NOT NULL,                       -- 'set_labels'/'add_comment'/'set_state'
                                                         -- /'pr_create'/'pr_merge'/...
    payload_json    TEXT CHECK (payload_json IS NULL OR json_valid(payload_json)),
    idempotency_key TEXT NOT NULL UNIQUE,
    status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN (
                        'pending','sent','failed','skipped')),
    attempts        INTEGER NOT NULL DEFAULT 0,
    response_ref    TEXT,                                -- Linear comment id / PR url
    error           TEXT,
    created_at      TEXT NOT NULL,
    sent_at         TEXT
);
CREATE INDEX idx_outbox_pending ON projection_outbox (status, created_at);

-- ============================================================================
-- §H  DERIVED VIEWS  (convenience; guard counters + pick-ready, derived not stored)
-- ============================================================================

-- Rejection counters since the last operator-resume, per stage-class. Replaces
-- guards.sh re-grepping Linear comments each tick (implement/review/qa_rejection).
CREATE VIEW v_rejection_counts AS
SELECT
    e.ticket_id,
    e.target AS reject_target,
    COUNT(*) AS rejections_since_resume
FROM pipeline_event e
WHERE e.kind = 'verdict' AND e.result = 'fail'
  AND e.seq > COALESCE((
        SELECT MAX(d.seq) FROM pipeline_event d
        WHERE d.ticket_id = e.ticket_id
          AND d.kind = 'decision' AND d.action = 'continue'), 0)
GROUP BY e.ticket_id, e.target;

-- Tickets the daemon may pick this tick (active, not parked on an undelivered signal).
CREATE VIEW v_ready_tickets AS
SELECT t.*
FROM ticket t
JOIN project p ON p.id = t.project_id
WHERE p.paused = 0
  AND t.status = 'active'
  AND NOT EXISTS (
        SELECT 1 FROM signal s
        WHERE s.ticket_id = t.id AND s.status = 'pending');

-- ============================================================================
-- §X  DEFERRED — UGL / SUPERVISOR / MEMORY (post-cutover I-C/I-D; §5.8, E1/E2)
-- ----------------------------------------------------------------------------
-- NOT created at cutover. Sketched for forward-compatibility only so the
-- substrate doesn't paint into a corner. E2 (decision_class / action_surface
-- vocabularies) is still OPEN — the CHECK enums below are placeholders to be
-- enumerated from the 41-code taxonomy before the UGL increment.
--
-- CREATE TABLE memory_record (              -- §5.8.5 index keys
--     id                 INTEGER PRIMARY KEY,
--     scope_level        TEXT CHECK (scope_level IN ('global','project','ticket-class','code-area','ticket')),
--     project_id         INTEGER REFERENCES project(id),
--     ticket_id          INTEGER REFERENCES ticket(id),     -- only for scope_level='ticket'
--     stage              TEXT,
--     decision_class     TEXT,    -- [E2 OPEN] ~6 classes from the taxonomy
--     action_surface     TEXT,    -- [E2 OPEN] supervisor's closed verb set
--     code_locus         TEXT,
--     provenance         TEXT CHECK (provenance IN ('human','retro','supervisor')),  -- human > retro > supervisor
--     outcome            TEXT CHECK (outcome IN ('resolved','recurred','unknown')),
--     confidence         REAL,
--     context_fingerprint TEXT,   -- ≈ pipeline_content_hash; relevance decays on substrate change
--     supersedes         INTEGER REFERENCES memory_record(id),
--     situation          TEXT,    -- model-written narrative
--     decision           TEXT,    -- model-written
--     action             TEXT,    -- model-written
--     rationale          TEXT,    -- model-written
--     embedding          BLOB,    -- E1: brute-force cosine while small -> sqlite-vec when it grows
--     created_at         TEXT NOT NULL,
--     last_confirmed_at  TEXT
-- );
-- CREATE TABLE supervisor_decision (        -- §5.4 decision record (links memory -> outcome)
--     id INTEGER PRIMARY KEY, ticket_id INTEGER REFERENCES ticket(id),
--     trace_ref TEXT, memory_record_id INTEGER REFERENCES memory_record(id),
--     classification TEXT, action_taken TEXT, authorization TEXT,
--     outcome TEXT CHECK (outcome IN ('resolved','escalated','recurred')),
--     confidence REAL, model TEXT, created_at TEXT NOT NULL
-- );
-- ============================================================================
