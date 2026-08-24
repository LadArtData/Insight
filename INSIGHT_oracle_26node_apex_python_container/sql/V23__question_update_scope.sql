ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;
-- ============================================================================
-- WHICH QUESTIONS ARE ASKED AGAIN
--
-- Intake and update are different conversations. Intake collects everything
-- needed to produce a configuration. An update happens later, when something
-- about the client has changed and a new configuration is needed -- and
-- walking a consultant back through the whole deck to change one thing is
-- how a tool stops being used.
--
-- So each question says whether it is asked again:
--
--   1  revisited on an update (the default)
--   0  asked once, at intake
--
-- The test is not "could this ever change" -- almost anything could. It is
-- "would changing this be an update, or a re-implementation?" A ledger's
-- currency, a chart of accounts structure and an accounting calendar are
-- decided once and changing one is a project. How many years of history to
-- convert is meaningless a second time: the conversion already happened.
--
-- Not asking is the lossy direction, so the default is 1 and the doubtful
-- cases are 1 too. A consultant can skip a question they do not need; they
-- cannot answer one they are never shown.
--
-- 0 does NOT mean frozen. Every answer stays editable on the client
-- information screen, where changing one is a deliberate act that raises a
-- change request. It means the question is not put in front of someone
-- again, one at a time, in a flow about something else.
-- ============================================================================

ALTER TABLE insight_questions ADD (
    ask_on_update NUMBER(1) DEFAULT 1 NOT NULL
);

ALTER TABLE insight_questions ADD CONSTRAINT chk_insight_q_ask_on_update
    CHECK (ask_on_update IN (0, 1));

COMMENT ON COLUMN insight_questions.ask_on_update IS '1 = asked again when a client is updated (default). 0 = asked once at intake; still editable on the client screen, just not re-asked.';

-- The values themselves are seeded by V24, generated from
-- questions/insight_questions.json. Splitting them keeps this migration to
-- one job: every question keeps the default of 1 until V24 says otherwise,
-- which is the safe state to be in between the two.

COMMIT;
