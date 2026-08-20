ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- ANSWER PROVENANCE AND "NOT KNOWN YET"
--
-- Two additions the downstream handoff needs, so a consumer can tell how
-- much weight an answer carries without asking a person.
--
-- 1. Where the answer came from, and whether it is settled.
--
--    Everything captured during a sales conversation is a starting point,
--    not a decision. Marking that explicitly is what lets the next stage
--    treat a rep's answer and a consultant's confirmation differently
--    instead of guessing from context.
--
--      answer_source  SALES_INTAKE  a rep, working the questionnaire
--                     AI_ASSIST     proposed by the assistant from a spoken
--                                   update -- still requires confirmation,
--                                   so the assistant cannot quietly turn a
--                                   verbal aside into an unreviewed fact
--                     CONSULTANT    entered by the implementation team
--      is_confirmed   0 provisional, 1 confirmed
--
--    Defaults are SALES_INTAKE / provisional, because that is what the
--    questionnaire produces and the safe assumption for anything else.
--
-- 2. "Not known yet" as a real answer.
--
--    Some values simply cannot be known during a sales call. Recording that
--    as a deliberate state is more useful downstream than a blank, which is
--    indistinguishable from "nobody got to it", or a guess, which is worse
--    than either.
--
--    This is NOT the same as is_skipped. Skipped means come back to it --
--    the AI Follow-Up chat chases those. Unknown means it was considered
--    and settled as not yet knowable, so it should stop being chased.
-- ============================================================================

ALTER TABLE insight_client_answers ADD (
    answer_source VARCHAR2(20)  DEFAULT 'SALES_INTAKE' NOT NULL,
    is_confirmed  NUMBER(1)     DEFAULT 0 NOT NULL,
    is_unknown    NUMBER(1)     DEFAULT 0 NOT NULL,
    confirmed_by  VARCHAR2(100),
    confirmed_at  TIMESTAMP WITH TIME ZONE
);

ALTER TABLE insight_client_answers ADD CONSTRAINT chk_insight_ans_source
    CHECK (answer_source IN ('SALES_INTAKE', 'AI_ASSIST', 'CONSULTANT'));

ALTER TABLE insight_client_answers ADD CONSTRAINT chk_insight_ans_confirmed
    CHECK (is_confirmed IN (0, 1));

ALTER TABLE insight_client_answers ADD CONSTRAINT chk_insight_ans_unknown
    CHECK (is_unknown IN (0, 1));

-- An answer cannot be both "not known yet" and carry a value: one of them
-- is wrong, and letting both through means a downstream reader has to
-- decide which to believe.
ALTER TABLE insight_client_answers ADD CONSTRAINT chk_insight_ans_unknown_blank
    CHECK (is_unknown = 0 OR answer_value IS NULL);

-- Finding everything still provisional is the common downstream question,
-- so index for it rather than scanning the client's whole answer set.
CREATE INDEX idx_insight_answers_provisional
    ON insight_client_answers (client_id, is_confirmed);

COMMENT ON COLUMN insight_client_answers.answer_source IS 'Who produced this answer: SALES_INTAKE, AI_ASSIST or CONSULTANT.';
COMMENT ON COLUMN insight_client_answers.is_confirmed IS '0 = provisional (default), 1 = confirmed by a consultant.';
COMMENT ON COLUMN insight_client_answers.is_unknown IS '1 = deliberately recorded as not yet knowable. Distinct from is_skipped, which means come back to it.';

COMMIT;
