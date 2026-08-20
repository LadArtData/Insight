ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- TYPED ANSWERS
--
-- V7 allowed only 'text' and 'yn'. Every question was therefore a free-text
-- box, including the ones asking "how many" -- so a count could be answered
-- with prose, or with nothing resembling a number at all.
--
-- Adds: number, currency, email, phone. The front end renders and validates
-- against these, and the seed in V12 assigns them.
--
-- Note this is a constraint change only. Existing answer_value stays CLOB:
-- storing a count as text keeps the answers table uniform and lets an
-- answer carry a qualifier ("~40, mid-year") without a schema change. The
-- type governs what the UI accepts, not how the value is stored.
-- ============================================================================

ALTER TABLE insight_questions DROP CONSTRAINT chk_insight_q_answer_type;

ALTER TABLE insight_questions ADD CONSTRAINT chk_insight_q_answer_type
    CHECK (answer_type IN ('text', 'yn', 'number', 'currency', 'email', 'phone'));

COMMIT;
