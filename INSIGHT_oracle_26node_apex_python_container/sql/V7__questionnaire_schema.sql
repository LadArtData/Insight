ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- QUESTIONNAIRE BACKEND: SCHEMA (Clients, Questions, Answers)
-- Target Environment: Oracle Database 19c / 21c / 23c / Autonomous DB
-- This is the real backend for the client discovery questionnaire app
-- (INSIGHT_app.html) -- a SEPARATE feature from the 26-node EDL matrix
-- (insight_boards / insight_nodes_26 / pkg_insight_board_engine in
-- INSIGHT_01-06). Both deploy into the same ITERIA_AI schema per the
-- workspace convention described in INSIGHT_README.md, but nothing here
-- depends on or interacts with the EDL matrix objects.
--
-- Design: questions are metadata-driven (insight_questions), not hardcoded
-- columns, so new discovery modules can be added later as new rows instead
-- of schema changes. Answers are one row per (client, question) rather than
-- a JSON blob per client, so they're queryable and support the approval
-- workflow in INSIGHT_08. A consolidated "client sheet" view (INSIGHT_09)
-- presents all of it back as a single per-client record.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. TABLE: INSIGHT_QUESTIONS (metadata for every discovery question)
-- ----------------------------------------------------------------------------
CREATE TABLE insight_questions (
    question_id     VARCHAR2(20) PRIMARY KEY,          -- e.g. 'GL-004', 'QUAL-AP'
    module_code     VARCHAR2(10) NOT NULL,              -- 'INTAKE','GL','AP','AR','FA','CM', future modules...
    phase           NUMBER(1) NOT NULL,                 -- 1 = intake, 2 = scope qualifier, 3 = module discovery
    eyebrow         VARCHAR2(200) NOT NULL,              -- section label shown above the question
    question_text   VARCHAR2(1000) NOT NULL,
    answer_type     VARCHAR2(10) DEFAULT 'text' NOT NULL,-- 'text' or 'yn'
    is_required     NUMBER(1) DEFAULT 1 NOT NULL,
    is_locked       NUMBER(1) DEFAULT 0 NOT NULL,        -- e.g. QUAL-GL is always "Yes", not user-editable
    display_order   NUMBER(4) NOT NULL,
    is_active       NUMBER(1) DEFAULT 1 NOT NULL,        -- retire a question without deleting its answer history
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_insight_q_phase CHECK (phase IN (1, 2, 3)),
    CONSTRAINT chk_insight_q_answer_type CHECK (answer_type IN ('text', 'yn')),
    CONSTRAINT chk_insight_q_required CHECK (is_required IN (0, 1)),
    CONSTRAINT chk_insight_q_locked CHECK (is_locked IN (0, 1)),
    CONSTRAINT chk_insight_q_active CHECK (is_active IN (0, 1))
);
CREATE INDEX idx_insight_q_module ON insight_questions (module_code, phase, display_order);

COMMENT ON TABLE insight_questions IS 'Metadata for every discovery question, current and future modules. Adding a question is a new row, not a schema change.';

-- ----------------------------------------------------------------------------
-- 2. TABLE: INSIGHT_CLIENTS (one row per client engagement)
-- ----------------------------------------------------------------------------
CREATE TABLE insight_clients (
    client_id       VARCHAR2(40) PRIMARY KEY,            -- app-generated id, matches the front end's currentClient.id
    company_name    VARCHAR2(300) NOT NULL,
    primary_contact VARCHAR2(300),
    status          VARCHAR2(20) DEFAULT 'ACTIVE' NOT NULL,
    created_by      VARCHAR2(100),                       -- consultant who started the intake
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_insight_client_status CHECK (status IN ('ACTIVE', 'ARCHIVED'))
);
CREATE INDEX idx_insight_clients_status ON insight_clients (status, updated_at DESC);

COMMENT ON TABLE insight_clients IS 'One row per client engagement. Row-level access control (which consultant/team sees which clients) is enforced against this table -- see INSIGHT_README.md for the VPD note.';

CREATE OR REPLACE TRIGGER trg_insight_clients_updated
BEFORE UPDATE ON insight_clients
FOR EACH ROW
BEGIN
    :NEW.updated_at := CURRENT_TIMESTAMP;
END;
/

-- ----------------------------------------------------------------------------
-- 3. TABLE: INSIGHT_CLIENT_ANSWERS (one row per client-question answer)
-- ----------------------------------------------------------------------------
CREATE TABLE insight_client_answers (
    client_id       VARCHAR2(40) NOT NULL,
    question_id     VARCHAR2(20) NOT NULL,
    answer_value    CLOB,                                -- CLOB, not VARCHAR2: some answers can be long free text
    answered_by     VARCHAR2(100),
    answered_at     TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
    is_skipped      NUMBER(1) DEFAULT 0 NOT NULL,         -- matches the front end's "Skip for now" -- an open gap for AI Follow-Up
    CONSTRAINT pk_insight_client_answers PRIMARY KEY (client_id, question_id),
    CONSTRAINT fk_insight_answers_client FOREIGN KEY (client_id) REFERENCES insight_clients(client_id) ON DELETE CASCADE,
    CONSTRAINT fk_insight_answers_question FOREIGN KEY (question_id) REFERENCES insight_questions(question_id),
    CONSTRAINT chk_insight_answers_skipped CHECK (is_skipped IN (0, 1))
);
CREATE INDEX idx_insight_answers_question ON insight_client_answers (question_id);
CREATE INDEX idx_insight_answers_skipped ON insight_client_answers (client_id, is_skipped);

COMMENT ON TABLE insight_client_answers IS 'One row per (client, question) answer. This is the direct read path for Maverick/implementation -- always the current, approved value. Proposed edits go through insight_answer_change_requests (INSIGHT_08) instead of writing here directly once the approval workflow is enforced.';
